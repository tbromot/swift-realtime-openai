@preconcurrency import WebRTC
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class WebRTCConnector: NSObject, Connector {
	enum WebRTCError: Error {
		case failedToCreateDataChannel
		case failedToCreatePeerConnection
		case badServerResponse
	}

	private var onDisconnect: (@Sendable () -> Void)? = nil
	public let events: AsyncThrowingStream<ServerEvent, Error>

	private var connection: RTCPeerConnection?
	private var dataChannel: RTCDataChannel?

	private let stream: AsyncThrowingStream<ServerEvent, Error>.Continuation
	private let request: URLRequest

	private static let factory: RTCPeerConnectionFactory = {
		RTCInitializeSSL()

		return RTCPeerConnectionFactory()
	}()

	private let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .convertToSnakeCase
		return encoder
	}()

	private let decoder: JSONDecoder = {
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		return decoder
	}()

	public init(request: URLRequest) {
		let (events, stream) = AsyncThrowingStream.makeStream(of: ServerEvent.self)
		self.events = events
		self.stream = stream
		self.request = request
		super.init()
	}

	public func connect(onDisconnect: (@Sendable () -> Void)?) async throws {
		self.onDisconnect = onDisconnect
		
		guard let connection = WebRTCConnector.factory.peerConnection(with: .init(), constraints: .init(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil) else {
			throw WebRTCError.failedToCreatePeerConnection
		}
		self.connection = connection
		connection.delegate = self

		let audioTrackSource = WebRTCConnector.factory.audioSource(with: nil)
		let audioTrack = WebRTCConnector.factory.audioTrack(with: audioTrackSource, trackId: "audio0")
		let mediaStream = WebRTCConnector.factory.mediaStream(withStreamId: "stream0")
		mediaStream.addAudioTrack(audioTrack)
		connection.add(audioTrack, streamIds: ["stream0"])

		guard let dataChannel = connection.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration()) else {
			throw WebRTCError.failedToCreateDataChannel
		}
		self.dataChannel = dataChannel
		dataChannel.delegate = self

		var request = self.request

		let offer = try await connection.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: [
			"OfferToReceiveAudio": "true",
			"googEchoCancellation": "true",
			"googAutoGainControl": "true",
			"googNoiseSuppression": "true",
			"googHighpassFilter": "true",
		]))
		try await connection.setLocalDescription(offer)

		request.httpBody = offer.sdp.data(using: .utf8)

		let (data, res) = try await URLSession.shared.data(for: request)
		guard let res = res as? HTTPURLResponse, res.statusCode == 201, let sdp = String(data: data, encoding: .utf8) else {
			throw WebRTCError.badServerResponse
		}

		try await connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
	}

	deinit {
		connection?.close()
		stream.finish()
		onDisconnect?()
	}

	public func send(event: ClientEvent) async throws {
		guard let dataChannel = dataChannel else {
			throw WebRTCError.failedToCreateDataChannel // or create a more appropriate error
		}
		try dataChannel.sendData(RTCDataBuffer(data: encoder.encode(event), isBinary: false))
	}
}

extension WebRTCConnector: RTCPeerConnectionDelegate {
	public func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {
		print("Connection state changed to \(connection?.signalingState ?? .closed)")
	}

	public func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {
		print("Media stream added.")
	}

	public func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {
		print("Media stream removed.")
	}

	public func peerConnectionShouldNegotiate(_: RTCPeerConnection) {
		print("Negotiating connection.")
	}

	public func peerConnection(_: RTCPeerConnection, didChange _: RTCIceConnectionState) {
		print("ICE connection state changed to \(connection?.iceConnectionState ?? .disconnected)")
	}

	public func peerConnection(_: RTCPeerConnection, didChange _: RTCIceGatheringState) {
		print("ICE gathering state changed to \(connection?.iceGatheringState ?? .new)")
	}

	public func peerConnection(_: RTCPeerConnection, didGenerate _: RTCIceCandidate) {
		print("ICE candidate generated.")
	}

	public func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {
		print("ICE candidate removed.")
	}

	public func peerConnection(_: RTCPeerConnection, didOpen _: RTCDataChannel) {
		print("Data channel opened.")
	}
}

extension WebRTCConnector: RTCDataChannelDelegate {
	public func dataChannel(_: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
		stream.yield(with: Result { try self.decoder.decode(ServerEvent.self, from: buffer.data) })
	}

	public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
		print("Data channel changed to \(dataChannel.readyState)")
	}
}
