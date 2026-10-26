import Foundation
import OSLog

nonisolated enum Log {
    static let subsystem = "be.jordythery.profile2blueprint"
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let app = Logger(subsystem: subsystem, category: "app")
}
