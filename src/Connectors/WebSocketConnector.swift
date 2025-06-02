import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class WebSocketConnector: Connector {
	private var onDisconnect: (@Sendable () -> Void)? = nil
	public let events: AsyncThrowingStream<ServerEvent, Error>

	private var task: Task<Void, Never>?
	private var webSocket: URLSessionWebSocketTask?
	private let stream: AsyncThrowingStream<ServerEvent, Error>.Continuation
	private let request: URLRequest

	private let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .convertToSnakeCase
		return encoder
	}()

	public init(request: URLRequest) {
		let (events, stream) = AsyncThrowingStream.makeStream(of: ServerEvent.self)
		self.events = events
		self.stream = stream
		self.request = request
	}

	public func connect(onDisconnect: (@Sendable () -> Void)?) async throws {
		self.onDisconnect = onDisconnect
		
		let webSocket = URLSession.shared.webSocketTask(with: request)
		self.webSocket = webSocket
		webSocket.resume()

		task = Task.detached { [webSocket, stream] in
			var isActive = true

			let decoder = JSONDecoder()
			decoder.keyDecodingStrategy = .convertFromSnakeCase

			while isActive, webSocket.closeCode == .invalid, !Task.isCancelled {
				guard webSocket.closeCode == .invalid else {
					stream.finish()
					isActive = false
					break
				}

				do {
					let message = try await webSocket.receive()

					guard case let .string(text) = message, let data = text.data(using: .utf8) else {
						stream.yield(error: RealtimeAPIError.invalidMessage)
						continue
					}

					try stream.yield(decoder.decode(ServerEvent.self, from: data))
				} catch {
					stream.yield(error: error)
					isActive = false
				}
			}

			webSocket.cancel(with: .goingAway, reason: nil)
            stream.finish()
            onDisconnect?()
		}
	}

	deinit {
		webSocket?.cancel(with: .goingAway, reason: nil)
		task?.cancel()
		stream.finish()
		onDisconnect?()
	}

	public func send(event: ClientEvent) async throws {
		guard let webSocket = webSocket else {
			throw RealtimeAPIError.invalidMessage // or create a more appropriate error
		}
		let message = try URLSessionWebSocketTask.Message.string(String(data: encoder.encode(event), encoding: .utf8)!)
		try await webSocket.send(message)
	}
}
