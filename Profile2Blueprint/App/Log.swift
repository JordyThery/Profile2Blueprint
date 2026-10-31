import Foundation
import OSLog

nonisolated enum Log {
    static let subsystem = "be.jordythery.profile2blueprint"
    static let app = Logger(subsystem: subsystem, category: "app")
}
