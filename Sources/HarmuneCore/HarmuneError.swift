import Foundation

public struct HarmuneError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Codable, Sendable {
        case notAuthorized, noSubscription, network, unavailable, unsupported
        case invalidArgument, notFound, timeout, disconnected, `internal`
    }

    public var code: Code
    public var message: String
    public var recoverable: Bool

    public init(_ code: Code, _ message: String, recoverable: Bool = true) {
        self.code = code; self.message = message; self.recoverable = recoverable
    }

    public var description: String { "\(code.rawValue): \(message)" }

    public static func notFound(_ what: String) -> HarmuneError { .init(.notFound, "\(what) not found") }
    public static func unsupported(_ what: String) -> HarmuneError { .init(.unsupported, "\(what) is not supported") }
    public static func invalid(_ what: String) -> HarmuneError { .init(.invalidArgument, what) }
}
