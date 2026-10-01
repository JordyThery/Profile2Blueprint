import Foundation
import Testing
@testable import Profile2Blueprint

private let base = URL(string: "https://us.api.jamfcloud.com")!
private let environmentID = "e77c1408-10c8-4007-b177-abc9157fbcaa"
private let secretValue = "s3cr3t+with&specials="

private func tokenJSON(_ token: String, expiresIn: Int = 900) -> String {
    #"{"access_token":"\#(token)","expires_in":\#(expiresIn),"refresh_expires_in":0,"token_type":"Bearer","not-before-policy":0}"#
}

private func groupJSON(_ index: Int) -> String {
    #"{"id":"00000000-0000-0000-0000-\#(String(format: "%012d", index))","name":"Group \#(index)","description":"","deviceType":"COMPUTER","groupType":"STATIC","memberCount":\#(index)}"#
}

private func pageJSON(page: Int, totalPages: Int, items: [Int]) -> String {
    #"{"page":\#(page),"pageSize":\#(items.count),"totalCount":\#(totalPages * items.count),"totalPages":\#(totalPages),"hasNext":\#(page + 1 < totalPages),"hasPrevious":\#(page > 0),"results":[\#(items.map(groupJSON).joined(separator: ","))]}"#
}

private func makeTokens(clock: TestClock = TestClock()) -> TokenProvider {
    TokenProvider(
        tokenURL: base.appending(path: "auth/token"),
        clientID: "client-123",
        secret: { secretValue },
        session: MockURLProtocol.makeSession(),
        now: { clock.now }
    )
}

private func makeClient(tokens: TokenProvider, sleeper: SleepRecorder = SleepRecorder()) -> HTTPClient {
    HTTPClient(
        baseURL: base,
        environmentID: environmentID,
        tokens: tokens,
        session: MockURLProtocol.makeSession(),
        sleep: { try await sleeper.sleep($0) }
    )
}

@Suite("Networking", .serialized)
struct NetworkingTests {

    // MARK: TokenProvider

    @Test("Token request is a form-encoded client_credentials POST")
    func tokenRequestShape() async throws {
        MockURLProtocol.install { _ in .json(200, tokenJSON("tok-1")) }
        let token = try await makeTokens().validToken()

        #expect(token == "tok-1")
        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/auth/token")
        #expect(request.header("Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.bodyString.contains("grant_type=client_credentials"))
        #expect(request.bodyString.contains("client_id=client-123"))
        // `+`, `&` and `=` in the secret must be percent-encoded.
        #expect(request.bodyString.contains("client_secret=s3cr3t%2Bwith%26specials%3D"))
    }

    @Test("Cached token is reused until it nears expiry")
    func tokenCachingAndRefresh() async throws {
        let issued = Counter()
        MockURLProtocol.install { _ in
            .json(200, tokenJSON("tok-\(issued.next())", expiresIn: 900))
        }
        let clock = TestClock()
        let tokens = makeTokens(clock: clock)

        #expect(try await tokens.validToken() == "tok-1")
        clock.advance(by: 600)
        #expect(try await tokens.validToken() == "tok-1")
        // 850 s in: within the 60 s refresh margin, so a new token is fetched.
        clock.advance(by: 250)
        #expect(try await tokens.validToken() == "tok-2")
        #expect(await tokens.requestCount == 2)
    }

    @Test("Concurrent callers share one token request")
    func tokenCoalescing() async throws {
        MockURLProtocol.install { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return .json(200, tokenJSON("shared"))
        }
        let tokens = makeTokens()

        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await tokens.validToken() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(values.count == 10)
        #expect(Set(values) == ["shared"])
        #expect(await tokens.requestCount == 1)
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test("Token endpoint errors surface OAuth error codes and never echo the secret")
    func tokenFailure() async throws {
        MockURLProtocol.install { _ in
            .json(401, #"{"error":"invalid_client","error_description":"Invalid client credentials","client_secret":"leaked"}"#)
        }
        do {
            _ = try await makeTokens().validToken()
            Issue.record("Expected failure")
        } catch let error as APIError {
            let report = ErrorReport(error)
            #expect(report.httpStatus == 401)
            #expect(report.details.first?.code == "invalid_client")
            #expect(report.details.first?.description == "Invalid client credentials")
            #expect(!(report.title.contains(secretValue)))
            if case let .http(_, _, _, _, raw) = error {
                #expect(raw?.contains("leaked") == false)
            }
        }
    }

    // MARK: HTTPClient

    @Test("Requests carry bearer token and X-Environment-Id")
    func requestHeaders() async throws {
        MockURLProtocol.install { request in
            request.path == "/auth/token"
                ? .json(200, tokenJSON("tok-h"))
                : .json(200, pageJSON(page: 0, totalPages: 1, items: [1]))
        }
        let client = makeClient(tokens: makeTokens())
        _ = try await LiveDeviceGroupsAPI(client: client).computerGroups()

        let apiRequest = try #require(MockURLProtocol.requests.last)
        #expect(apiRequest.header("Authorization") == "Bearer tok-h")
        #expect(apiRequest.header("X-Environment-Id") == environmentID)
        #expect(apiRequest.path == "/device-groups/v1/device-groups")
    }

    @Test("401 triggers exactly one token refresh and retry")
    func unauthorizedRetry() async throws {
        let apiCalls = Counter()
        let tokenCalls = Counter()
        MockURLProtocol.install { request in
            if request.path == "/auth/token" {
                return .json(200, tokenJSON("tok-\(tokenCalls.next())"))
            }
            if apiCalls.next() == 1 {
                return .json(401, #"{"httpStatus":401,"traceId":"t1","errors":{"code":"UNAUTHORIZED","description":"expired"}}"#)
            }
            return .json(200, pageJSON(page: 0, totalPages: 1, items: [1]))
        }
        let groups = try await LiveDeviceGroupsAPI(client: makeClient(tokens: makeTokens())).computerGroups()

        #expect(groups.count == 1)
        #expect(apiCalls.value == 2)
        #expect(tokenCalls.value == 2)
        let auth = MockURLProtocol.requests.filter { $0.path != "/auth/token" }.map { $0.header("Authorization") }
        #expect(auth == ["Bearer tok-1", "Bearer tok-2"])
    }

    @Test("429 backs off (honouring Retry-After) and then succeeds")
    func rateLimitBackoff() async throws {
        let apiCalls = Counter()
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return .json(200, tokenJSON("tok")) }
            switch apiCalls.next() {
            case 1: return .json(429, #"{"httpStatus":429,"traceId":"r1","errors":{"code":"TOO_MANY_REQUESTS","description":"slow down"}}"#, headers: ["Retry-After": "2"])
            case 2: return .json(429, "{}")
            default: return .json(200, pageJSON(page: 0, totalPages: 1, items: [7]))
            }
        }
        let sleeper = SleepRecorder()
        let groups = try await LiveDeviceGroupsAPI(client: makeClient(tokens: makeTokens(), sleeper: sleeper)).computerGroups()

        #expect(groups.map(\.memberCount) == [7])
        // First wait from Retry-After, second from exponential backoff (attempt 1 → 2 s).
        #expect(sleeper.recorded == [.seconds(2), .seconds(2)])
    }

    @Test("429 gives up after the retry budget and reports the error")
    func rateLimitExhausted() async throws {
        MockURLProtocol.install { request in
            request.path == "/auth/token"
                ? .json(200, tokenJSON("tok"))
                : .json(429, #"{"httpStatus":429,"traceId":"r9","errors":{"code":"TOO_MANY_REQUESTS","description":"slow down"}}"#)
        }
        let sleeper = SleepRecorder()
        await #expect(throws: APIError.self) {
            _ = try await LiveDeviceGroupsAPI(client: makeClient(tokens: makeTokens(), sleeper: sleeper)).computerGroups()
        }
        #expect(sleeper.recorded.count == RetryPolicy().maxRetries)
    }

    @Test("400 and 409 bodies decode into httpStatus / code / field / description / traceId",
          arguments: [400, 409])
    func errorDecoding(status: Int) async throws {
        MockURLProtocol.install { request in
            request.path == "/auth/token"
                ? .json(200, tokenJSON("tok"))
                : .json(status, #"{"httpStatus":\#(status),"traceId":"3e3819a63ae0f231","errors":{"id":null,"code":"INVALID_FIELD","field":"name","description":"Field name is required."}}"#)
        }
        do {
            _ = try await makeClient(tokens: makeTokens()).send(HTTPRequest(path: "blueprints/v1/blueprints"))
            Issue.record("Expected failure")
        } catch {
            let report = ErrorReport(error)
            #expect(report.httpStatus == status)
            #expect(report.traceId == "3e3819a63ae0f231")
            #expect(report.details == [APIErrorDetail(code: "INVALID_FIELD", field: "name", description: "Field name is required.")])
        }
    }

    // MARK: Device groups

    @Test("Device groups follow every page with an RSQL COMPUTER filter")
    func deviceGroupPagination() async throws {
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return .json(200, tokenJSON("tok")) }
            let page = Int(request.queryValue("page") ?? "") ?? -1
            let items = Array((page * 2 + 1)...(page * 2 + 2))
            return .json(200, pageJSON(page: page, totalPages: 3, items: items))
        }
        let groups = try await LiveDeviceGroupsAPI(client: makeClient(tokens: makeTokens()), pageSize: 2).computerGroups()

        #expect(groups.map(\.name) == (1...6).map { "Group \($0)" })
        let apiRequests = MockURLProtocol.requests.filter { $0.path != "/auth/token" }
        #expect(apiRequests.compactMap { $0.queryValue("page") } == ["0", "1", "2"])
        #expect(apiRequests.allSatisfy { $0.queryValue("page-size") == "2" })
        #expect(apiRequests.allSatisfy { $0.queryValue("filter") == #"deviceType=="COMPUTER""# })
        // `=` and `"` inside the filter value must be percent-encoded on the wire.
        #expect(apiRequests[0].url.absoluteString.contains("filter=deviceType%3D%3D%22COMPUTER%22"))
    }

    @Test("Pagination stops at the safety limit")
    func paginationLimit() async throws {
        MockURLProtocol.install { request in
            request.path == "/auth/token"
                ? .json(200, tokenJSON("tok"))
                : .json(200, pageJSON(page: 0, totalPages: 99, items: [1]))
        }
        let api = LiveDeviceGroupsAPI(client: makeClient(tokens: makeTokens()), pageSize: 1, maxPages: 3)
        await #expect(throws: APIError.self) { _ = try await api.computerGroups() }
    }
}
