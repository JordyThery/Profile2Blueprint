import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Profile2Blueprint

private let base = URL(string: "https://us.api.jamfcloud.com")!
private let environmentID = "0f0e0d0c-0b0a-4000-8000-00000000abcd"
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

private func makeTokens(clock: TestClock = TestClock()) -> JamfPlatform.TokenProvider {
    JamfPlatform.TokenProvider(
        tokenURL: base.appending(path: "auth/token"),
        method: .apiClient(clientID: "client-123"),
        secret: { secretValue },
        recorder: RequestRecorder(session: MockURLProtocol.makeSession(), log: nil),
        now: { clock.now }
    )
}

/// JTKit's client as the app builds it (its allow-list and hints), with no
/// randomness in the waits, so they can be compared exactly.
private func makeClient(tokens: JamfPlatform.TokenProvider, sleeper: SleepRecorder = SleepRecorder()) throws -> JamfPlatform.Client {
    try JamfPlatform.Client(
        baseURL: base,
        scope: .environment(environmentID),
        tokens: tokens,
        recorder: RequestRecorder(session: MockURLProtocol.makeSession(), log: nil),
        permits: { RequestPolicy.isPermitted($0) },
        hints: RequestPolicy.hints(for:),
        sleep: { try await sleeper.sleep($0) },
        random: { 0 }
    )
}

@Suite("Networking", .serialized)
struct NetworkingTests {

    // MARK: Token provider (JTKit)

    @Test("Token request is a form-encoded client_credentials POST")
    func tokenRequestShape() async throws {
        MockURLProtocol.install { _ in .json(200, tokenJSON("tok-1")) }
        let token = try await makeTokens().token()

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

        #expect(try await tokens.token() == "tok-1")
        clock.advance(by: 600)
        #expect(try await tokens.token() == "tok-1")
        // 850 s in: within the 60 s refresh margin, so a new token is fetched.
        clock.advance(by: 250)
        #expect(try await tokens.token() == "tok-2")
        #expect(await tokens.signInCount == 2)
    }

    @Test("Concurrent callers share one token request")
    func tokenCoalescing() async throws {
        MockURLProtocol.install { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return .json(200, tokenJSON("shared"))
        }
        let tokens = makeTokens()

        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await tokens.token() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(values.count == 10)
        #expect(Set(values) == ["shared"])
        #expect(await tokens.signInCount == 1)
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test("Token endpoint errors surface OAuth error codes and never echo the secret")
    func tokenFailure() async throws {
        MockURLProtocol.install { _ in
            .json(401, #"{"error":"invalid_client","error_description":"Invalid client credentials","client_secret":"leaked"}"#)
        }
        do {
            _ = try await makeTokens().token()
            Issue.record("Expected failure")
        } catch let jtkitError as HTTPError {
            let report = ErrorReport(jtkitError)
            #expect(report.httpStatus == 401)
            #expect(report.title.hasPrefix("Sign-in failed"))
            #expect(report.details.contains("invalid_client: Invalid client credentials"))
            let shown = ([report.title] + report.details).joined(separator: "\n")
            #expect(!shown.contains(secretValue))
            #expect(!shown.contains("leaked"))
        }
    }

    // MARK: Client (JTKit, with the app's allow-list and errors)

    @Test("Requests carry bearer token and X-Environment-Id")
    func requestHeaders() async throws {
        MockURLProtocol.install { request in
            request.path == "/auth/token"
                ? .json(200, tokenJSON("tok-h"))
                : .json(200, pageJSON(page: 0, totalPages: 1, items: [1]))
        }
        let client = try makeClient(tokens: makeTokens())
        _ = try await client.deviceGroups()

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
        let groups = try await makeClient(tokens: makeTokens()).deviceGroups()

        #expect(groups.count == 1)
        #expect(apiCalls.value == 2)
        #expect(tokenCalls.value == 2)
        let auth = MockURLProtocol.requests.filter { $0.path != "/auth/token" }.map { $0.header("Authorization") }
        #expect(auth == ["Bearer tok-1", "Bearer tok-2"])
    }

    @Test("429 backs off (honoring Retry-After) and then succeeds")
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
        let groups = try await makeClient(tokens: makeTokens(), sleeper: sleeper).deviceGroups()

        #expect(groups.map(\.memberCount) == [7])
        // First wait from Retry-After, second from the doubling backoff (after attempt 2: 2 s, no randomness here).
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
        let client = try makeClient(tokens: makeTokens(), sleeper: sleeper)
        let error = await #expect(throws: JamfPlatform.APIError.self) { _ = try await client.deviceGroups() }
        #expect(error?.status == 429)
        #expect(sleeper.recorded.count == RetryRules.standard.maxAttempts - 1)
    }

    @Test("400 and 409 bodies show in JTKit's format: status, CODE (field): description, Trace ID",
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
            #expect(report.traceID == "3e3819a63ae0f231")
            #expect(report.title.contains("\(status)"))
            #expect(report.details.contains("INVALID_FIELD (name): Field name is required."))
            #expect(report.details.contains { $0.contains("3e3819a63ae0f231") })
        }
    }

    // MARK: Device groups

    @Test("Device groups follow every page; an RSQL filter is encoded strictly")
    func deviceGroupPagination() async throws {
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return .json(200, tokenJSON("tok")) }
            let page = Int(request.queryValue("page") ?? "") ?? -1
            let items = Array((page * 2 + 1)...(page * 2 + 2))
            return .json(200, pageJSON(page: page, totalPages: 3, items: items))
        }
        let client = try makeClient(tokens: makeTokens())
        let groups = try await client.deviceGroups(filter: #"deviceType=="COMPUTER""#, pageSize: 2)

        #expect(groups.map(\.name) == (1...6).map { "Group \($0)" })
        let apiRequests = MockURLProtocol.requests.filter { $0.path != "/auth/token" }
        #expect(apiRequests.compactMap { $0.queryValue("page") } == ["0", "1", "2"])
        #expect(apiRequests.allSatisfy { $0.queryValue("page-size") == "2" })
        #expect(apiRequests.allSatisfy { $0.queryValue("filter") == #"deviceType=="COMPUTER""# })
        // `=` and `"` inside the filter value must be percent-encoded on the wire.
        #expect(apiRequests[0].url.absoluteString.contains("filter=deviceType%3D%3D%22COMPUTER%22"))

        // The workspace's unfiltered load sends no filter parameter at all.
        MockURLProtocol.install { request in
            request.path == "/auth/token" ? .json(200, tokenJSON("tok")) : .json(200, pageJSON(page: 0, totalPages: 1, items: [1]))
        }
        _ = try await makeClient(tokens: makeTokens()).deviceGroups()
        let unfiltered = MockURLProtocol.requests.filter { $0.path != "/auth/token" }
        #expect(unfiltered.allSatisfy { $0.queryValue("filter") == nil })
    }

    @Test("Pagination stops at the safety limit")
    func paginationLimit() async throws {
        MockURLProtocol.install { request in
            request.path == "/auth/token"
                ? .json(200, tokenJSON("tok"))
                : .json(200, pageJSON(page: 0, totalPages: 99, items: [1]))
        }
        let client = try makeClient(tokens: makeTokens())
        let error = await #expect(throws: JamfPlatform.APIError.self) { _ = try await client.deviceGroups(pageSize: 1, maxPages: 3) }
        guard case .pageLimitReached(_, 3)? = error?.kind else { Issue.record("Got \(String(describing: error))"); return }
    }
}
