//
//  MacRemoteClient.swift
//  LumiAgentIOS
//
//  Manages the TCP connection to a single macOS LumiAgent remote server.
//  Commands are sent as length-prefixed JSON frames; responses are received the same way.
//
//  Wire protocol (identical on both sides):
//    [UInt32 big-endian length][UTF-8 JSON payload]
//
//  The macOS counterpart lives in:
//    LumiAgent/Infrastructure/Network/MacRemoteServer.swift
//

import Network
import Foundation
import Combine

// MARK: - Mac Remote Client

/// Connects to and sends commands to a macOS LumiAgent host.
@MainActor
public final class MacRemoteClient: ObservableObject {

    // MARK: - Published

    @Published public private(set) var state: MacDevice.ConnectionState = .disconnected
    @Published public private(set) var lastScreenshot: Data?
    @Published public private(set) var lastResult: String?
    @Published public private(set) var systemInfo: MacSystemInfo?

    // MARK: - Private

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.lumiagent.remote-client", qos: .userInitiated)
    /// In-flight command completions keyed by command UUID.
    private var pendingCommands: [UUID: CheckedContinuation<RemoteCommandResponse, Error>] = [:]
    /// Accumulated receive buffer for partial frames.
    private var receiveBuffer = Data()

    public init() {}

    // MARK: - Connect / Disconnect

    public func connect(to device: MacDevice) async throws {
        guard !state.isConnected else { return }
        state = .connecting

        let conn = NWConnection(to: device.endpoint, using: makeTCPParameters())
        self.connection = conn

        return try await withCheckedThrowingContinuation { continuation in
            conn.stateUpdateHandler = { [weak self] nwState in
                Task { @MainActor [weak self] in
                    self?.handleConnectionState(nwState, continuation: continuation)
                }
            }
            conn.start(queue: queue)
        }
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
        state = .disconnected
        cancelAllPending(with: CancellationError())
    }

    // MARK: - Send Command

    /// Sends a command and awaits the response, with a default 15 s timeout.
    public func send(_ command: RemoteCommand, timeout: TimeInterval = 15) async throws -> RemoteCommandResponse {
        guard let conn = connection, state.isConnected else {
            throw RemoteClientError.notConnected
        }

        let frame = try WireFrame.encode(command)

        // Enqueue a continuation to be resumed when the response arrives.
        return try await withCheckedThrowingContinuation { continuation in
            pendingCommands[command.id] = continuation
            conn.send(content: frame, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    Task { @MainActor [weak self] in
                        self?.pendingCommands.removeValue(forKey: command.id)?.resume(throwing: error)
                    }
                }
            })
            // Timeout
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await MainActor.run {
                    if self?.pendingCommands[command.id] != nil {
                        self?.pendingCommands.removeValue(forKey: command.id)?
                            .resume(throwing: RemoteClientError.timeout)
                    }
                }
            }
        }
    }

    // MARK: - Connection State

    private func handleConnectionState(
        _ nwState: NWConnection.State,
        continuation: CheckedContinuation<Void, Error>?
    ) {
        switch nwState {
        case .ready:
            state = .connected
            continuation?.resume()
            startReceiving()
        case .failed(let error):
            state = .failed(error.localizedDescription)
            continuation?.resume(throwing: error)
            cancelAllPending(with: error)
        case .cancelled:
            state = .disconnected
            continuation?.resume(throwing: CancellationError())
        case .waiting(let error):
            // NWConnection is waiting for network; treat as failure for UX.
            state = .failed("Waiting: \(error.localizedDescription)")
        default:
            break
        }
    }

    // MARK: - Receive Loop

    private func startReceiving() {
        receiveLoop()
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data = data {
                    self.receiveBuffer.append(data)
                    self.drainBuffer()
                }
                if let error = error {
                    self.state = .failed(error.localizedDescription)
                    self.cancelAllPending(with: error)
                    return
                }
                if isComplete {
                    self.state = .disconnected
                    self.cancelAllPending(with: RemoteClientError.connectionClosed)
                    return
                }
                self.receiveLoop()
            }
        }
    }

    /// Parse complete frames from the accumulation buffer.
    private func drainBuffer() {
        while receiveBuffer.count >= 4 {
            let length = receiveBuffer.prefix(4).withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            }
            let totalNeeded = 4 + Int(length)
            guard receiveBuffer.count >= totalNeeded else { break }

            let payload = receiveBuffer.subdata(in: 4..<totalNeeded)
            receiveBuffer.removeFirst(totalNeeded)

            if let response = try? WireFrame.decode(RemoteCommandResponse.self, from: payload) {
                handleResponse(response)
            }
        }
    }

    private func handleResponse(_ response: RemoteCommandResponse) {
        // Screenshot data arrives as base64-encoded JPEG string.
        if let b64 = response.imageData, let data = Data(base64Encoded: b64) {
            lastScreenshot = data
        }
        lastResult = response.result
        pendingCommands.removeValue(forKey: response.id)?.resume(returning: response)
    }

    private func cancelAllPending(with error: Error) {
        for (_, continuation) in pendingCommands {
            continuation.resume(throwing: error)
        }
        pendingCommands.removeAll()
    }

    // MARK: - Helpers

    private func makeTCPParameters() -> NWParameters {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        return params
    }

    // MARK: - Convenience command builders

    public func setBrightness(_ level: Double) async throws -> RemoteCommandResponse {
        let cmd = RemoteCommand(commandType: .setBrightness, parameters: ["level": String(level)])
        return try await send(cmd)
    }

    public func setVolume(_ level: Double) async throws -> RemoteCommandResponse {
        let cmd = RemoteCommand(commandType: .setVolume, parameters: ["level": String(Int(level * 100))])
        return try await send(cmd)
    }

    public func setMute(_ muted: Bool) async throws -> RemoteCommandResponse {
        let cmd = RemoteCommand(commandType: .setMute, parameters: ["muted": muted ? "true" : "false"])
        return try await send(cmd)
    }

    public func mediaPlay() async throws -> RemoteCommandResponse {
        try await send(RemoteCommand(commandType: .mediaPlay))
    }

    public func mediaPause() async throws -> RemoteCommandResponse {
        try await send(RemoteCommand(commandType: .mediaPause))
    }

    public func mediaNext() async throws -> RemoteCommandResponse {
        try await send(RemoteCommand(commandType: .mediaNext))
    }

    public func mediaPrevious() async throws -> RemoteCommandResponse {
        try await send(RemoteCommand(commandType: .mediaPrevious))
    }

    public func mediaGetInfo() async throws -> RemoteCommandResponse {
        try await send(RemoteCommand(commandType: .mediaGetInfo))
    }

    public func screenshot() async throws -> RemoteCommandResponse {
        try await send(RemoteCommand(commandType: .screenshot), timeout: 30)
    }

    public func typeText(_ text: String) async throws -> RemoteCommandResponse {
        let cmd = RemoteCommand(commandType: .typeText, parameters: ["text": text])
        return try await send(cmd)
    }

    public func pressKey(_ key: String, modifiers: String = "") async throws -> RemoteCommandResponse {
        let cmd = RemoteCommand(commandType: .pressKey, parameters: ["key": key, "modifiers": modifiers])
        return try await send(cmd)
    }

    public func openApplication(_ name: String) async throws -> RemoteCommandResponse {
        let cmd = RemoteCommand(commandType: .openApplication, parameters: ["name": name])
        return try await send(cmd)
    }

    public func runAppleScript(_ script: String) async throws -> RemoteCommandResponse {
        let cmd = RemoteCommand(commandType: .runAppleScript, parameters: ["script": script])
        return try await send(cmd, timeout: 30)
    }

    public func getSystemInfo() async throws -> RemoteCommandResponse {
        try await send(RemoteCommand(commandType: .getSystemInfo))
    }

    public func ping() async throws -> RemoteCommandResponse {
        let deviceName = UIDevice.current.name
        let cmd = RemoteCommand(commandType: .ping, parameters: ["device_name": deviceName])
        return try await send(cmd, timeout: 5)
    }

    public func pullSyncData(file: String) async throws -> Data {
        let cmd = RemoteCommand(commandType: .getSyncData, parameters: ["file": file])
        let resp = try await send(cmd, timeout: 20)
        guard resp.success, let b64 = resp.imageData, let data = Data(base64Encoded: b64) else {
            throw RemoteClientError.decodingFailed
        }
        return data
    }

    public func pushSyncData(file: String, data: Data) async throws {
        let b64 = data.base64EncodedString()
        let cmd = RemoteCommand(commandType: .pushSyncData, parameters: ["file": file, "data": b64])
        let resp = try await send(cmd, timeout: 20)
        if !resp.success {
            throw RemoteClientError.decodingFailed
        }
    }

    deinit {
        connection?.cancel()
    }
}

// MARK: - Errors

public enum RemoteClientError: LocalizedError {
    case notConnected
    case timeout
    case connectionClosed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .notConnected:     return "Not connected to a Mac."
        case .timeout:          return "Command timed out."
        case .connectionClosed: return "Connection was closed."
        case .decodingFailed:   return "Failed to decode server response."
        }
    }
}
