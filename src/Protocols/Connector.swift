import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol Connector {
	var events: AsyncThrowingStream<ServerEvent, Error> { get }
	var onDisconnect: (@Sendable () -> Void)? { get }

	init(connectingTo request: URLRequest) async throws

	func send(event: ClientEvent) async throws

	func onDisconnect(_ action: (@Sendable () -> Void)?)
}
