import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol Connector {
	var events: AsyncThrowingStream<ServerEvent, Error> { get }

	init(request: URLRequest)

	func connect(onDisconnect: (@Sendable () -> Void)?) async throws

	func send(event: ClientEvent) async throws
}
