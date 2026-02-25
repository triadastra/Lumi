//
//  MacRemoteServer.swift
//  LumiAgent (macOS)
//
//  Listens for incoming iOS LumiAgent connections on the local network.
//  Advertises via Bonjour (_lumiagent._tcp) so the iOS app can discover
//  this Mac automatically using BonjourDiscovery.swift on the iOS side.
//
//  Wire protocol (same as iOS side):
//    [UInt32 big-endian length][UTF-8 JSON payload]
//
//  HOW TO START
//  ─────────────
//  Call MacRemoteServer.shared.start() from AppDelegate.applicationDidFinishLaunching(_:)
//
//  SANDBOX NOTE
//  ─────────────
//  If LumiAgent runs in an App Sandbox, add the "Incoming Connections (Server)"
//  entitlement (com.apple.security.network.server) to the entitlements file.
//

#if os(macOS)
import AppKit
import Foundation
import Network
import Combine

// MARK: - Mac Remote Server

/// Bonjour-advertised TCP server that accepts and dispatches remote commands from iOS.
@MainActor
public final class MacRemoteServer {

    // MARK: - Singleton

    public static let shared = MacRemoteServer()

    // MARK: - Constants

    static let serviceType = "_lumiagent._tcp"
    static let port: UInt16 = 47285

    // MARK: - State

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var connectedClients: [RemoteClientInfo] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var pairingCode: String = ""

    // MARK: - Private

    private var listener: NWListener?
    private var activeConnections: [UUID: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.lumiagent.server", qos: .userInitiated)
    private var pairedDeviceNames: Set<String> = []
    private let pairedDevicesKey = "lumi.remote.pairedDeviceNames"

    private init() {
        if let saved = UserDefaults.standard.array(forKey: pairedDevicesKey) as? [String] {
            pairedDeviceNames = Set(saved)
        }
        pairingCode = Self.generatePairingCode()
    }

    // MARK: - Start / Stop

    public func start() {
        if isRunning || listener != nil {
            print("[MacRemoteServer] Already running or starting...")
            return
        }

        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true // Crucial for discovery
            // Allow reusing the address if a previous process is still cleaning up
            params.allowLocalEndpointReuse = true 
            
            let listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: Self.port))

            // Advertise via Bonjour
            let hostname = ProcessInfo.processInfo.hostName
                .components(separatedBy: ".").first ?? "LumiAgent-Mac"
            listener.service = NWListener.Service(
                name: hostname,
                type: Self.serviceType,
                domain: nil
            )

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection)
                }
            }

            self.listener = listener
            listener.start(queue: queue)
            print("[MacRemoteServer] Starting on port \(Self.port), advertising as '\(hostname)'...")
        } catch {
            lastError = error.localizedDescription
            isRunning = false
            print("[MacRemoteServer] Failed to initialize listener: \(error)")
        }
    }

    public func stop() {
        print("[MacRemoteServer] Stopping...")
        listener?.cancel()
        listener = nil
        activeConnections.values.forEach { $0.cancel() }
        activeConnections.removeAll()
        connectedClients.removeAll()
        isRunning = false
        print("[MacRemoteServer] Stopped")
    }

    public func regeneratePairingCode() {
        pairingCode = Self.generatePairingCode()
    }

    public func clearPairedDevices() {
        pairedDeviceNames.removeAll()
        persistPairedDevices()
    }

    // MARK: - Listener State

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            lastError = nil
            print("[MacRemoteServer] Ready and advertising via Bonjour")
        case .failed(let error):
            lastError = error.localizedDescription
            isRunning = false
            listener?.cancel()
            listener = nil
            print("[MacRemoteServer] Listener failed: \(error)")
        case .cancelled:
            isRunning = false
            listener = nil
        default:
            break
        }
    }

    // MARK: - Accept Connection

    private func accept(_ connection: NWConnection) {
        let connectionID = UUID()
        activeConnections[connectionID] = connection
        
        let clientInfo = RemoteClientInfo(
            id: connectionID,
            name: "iPhone", // Initial placeholder
            address: "\(connection.endpoint)",
            connectedAt: Date()
        )
        connectedClients.append(clientInfo)

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                if case .cancelled = state {
                    self?.removeConnection(id: connectionID)
                } else if case .failed = state {
                    self?.removeConnection(id: connectionID)
                }
            }
        }

        connection.start(queue: queue)
        print("[MacRemoteServer] Client connected: \(connection.endpoint). Total: \(activeConnections.count)")

        receiveNext(on: connection, bufferBox: BufferBox(), id: connectionID)
    }

    private func removeConnection(id: UUID) {
        activeConnections.removeValue(forKey: id)
        connectedClients.removeAll { $0.id == id }
        print("[MacRemoteServer] Client disconnected. Remaining: \(activeConnections.count)")
    }

    // MARK: - Receive Loop

    private func receiveNext(on connection: NWConnection, bufferBox: BufferBox, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data {
                bufferBox.buffer.append(data)
                Task { @MainActor [weak self] in
                    await self?.drainBuffer(bufferBox.buffer, connection: connection, id: id)
                    bufferBox.buffer = Data()
                }
            }
            if error != nil || isComplete { return }
            Task { @MainActor [weak self] in
                self?.receiveNext(on: connection, bufferBox: bufferBox, id: id)
            }
        }
    }

    // MARK: - Frame parsing

    private func drainBuffer(_ data: Data, connection: NWConnection, id: UUID) async {
        var buffer = data
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            }
            let totalNeeded = 4 + Int(length)
            guard buffer.count >= totalNeeded else { break }

            let payload = buffer.subdata(in: 4..<totalNeeded)
            buffer.removeFirst(totalNeeded)

            if let command = try? JSONDecoder().decode(RemoteCommandMessage.self, from: payload) {
                // If ping, we might update device name if provided
                if command.commandType == "ping", let deviceName = command.parameters["device_name"] {
                    updateClientName(id: id, name: deviceName)
                }
                
                let response = await execute(command)
                if let frame = try? encodeResponse(response) {
                    connection.send(content: frame, completion: .contentProcessed { _ in })
                }
            }
        }
    }

    private func updateClientName(id: UUID, name: String) {
        if let idx = connectedClients.firstIndex(where: { $0.id == id }) {
            connectedClients[idx].name = name
        }
    }

    // MARK: - Command Execution

    private func execute(_ command: RemoteCommandMessage) async -> RemoteResponseMessage {
        let id = command.id
        let params = command.parameters

        do {
            switch command.commandType {

            // ── Ping ──────────────────────────────────────────────────────────────
            case "ping":
                let deviceName = params["device_name"] ?? "Unknown iPhone"
                let suppliedCode = params["pair_code"] ?? ""
                let isKnown = pairedDeviceNames.contains(deviceName)
                let isCodeValid = suppliedCode == pairingCode && !suppliedCode.isEmpty
                if !isKnown && !isCodeValid {
                    return RemoteResponseMessage(
                        id: id,
                        success: false,
                        result: "",
                        error: "Pairing required. Enter the code shown on your Mac."
                    )
                }
                if !isKnown {
                    pairedDeviceNames.insert(deviceName)
                    persistPairedDevices()
                    pairingCode = Self.generatePairingCode()
                }
                return RemoteResponseMessage(id: id, success: true, result: "pong")

            // ── Brightness ────────────────────────────────────────────────────────
            case "get_brightness":
                let level = try await runAppleScript("return (do shell script \"brightness -l | awk '/display/{getline; print $NF}'\")")
                return RemoteResponseMessage(id: id, success: true, result: level)

            case "set_brightness":
                let level = params["level"] ?? "0.5"
                try await runShell("brightness \(level)")
                return RemoteResponseMessage(id: id, success: true, result: "Brightness set to \(level)")

            // ── Volume ────────────────────────────────────────────────────────────
            case "get_volume":
                let vol = try await runAppleScript("output volume of (get volume settings)")
                return RemoteResponseMessage(id: id, success: true, result: vol)

            case "set_volume":
                let level = params["level"] ?? "50"
                try await runAppleScript("set volume output volume \(level)")
                return RemoteResponseMessage(id: id, success: true, result: "Volume set to \(level)%")

            case "set_mute":
                let muted = (params["muted"] ?? "false").lowercased() == "true"
                try await runAppleScript("set volume \(muted ? "with" : "without") output muted")
                return RemoteResponseMessage(id: id, success: true, result: muted ? "Muted" : "Unmuted")

            case "get_mute":
                let muted = try await runAppleScript("output muted of (get volume settings)")
                return RemoteResponseMessage(id: id, success: true, result: muted)

            // ── Media ─────────────────────────────────────────────────────────────
            case "media_play":
                try await runAppleScript("tell application \"Music\" to play")
                return RemoteResponseMessage(id: id, success: true, result: "Playing")

            case "media_pause":
                try await runAppleScript("tell application \"Music\" to pause")
                return RemoteResponseMessage(id: id, success: true, result: "Paused")

            case "media_toggle":
                try await runAppleScript("tell application \"Music\" to playpause")
                return RemoteResponseMessage(id: id, success: true, result: "Toggled")

            case "media_next":
                try await runAppleScript("tell application \"Music\" to next track")
                return RemoteResponseMessage(id: id, success: true, result: "Next track")

            case "media_previous":
                try await runAppleScript("tell application \"Music\" to previous track")
                return RemoteResponseMessage(id: id, success: true, result: "Previous track")

            case "media_stop":
                try await runAppleScript("tell application \"Music\" to stop")
                return RemoteResponseMessage(id: id, success: true, result: "Stopped")

            case "media_get_info":
                let info = try await runAppleScript("""
                    tell application "Music"
                        set t to name of current track
                        set a to artist of current track
                        set al to album of current track
                        set ps to player state
                        return "Title: " & t & "\nArtist: " & a & "\nAlbum: " & al & "\nPlaying: " & (ps is playing)
                    end tell
                    """)
                return RemoteResponseMessage(id: id, success: true, result: info)

            // ── Screenshot ────────────────────────────────────────────────────────
            case "screenshot":
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lumi_ios_remote_\(UUID().uuidString).png")
                defer { try? FileManager.default.removeItem(at: tmpURL) }

                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                proc.arguments = ["-x", "-m", tmpURL.path]
                try proc.run(); proc.waitUntilExit()

                guard proc.terminationStatus == 0,
                      let imageData = try? Data(contentsOf: tmpURL) else {
                    return RemoteResponseMessage(id: id, success: false, result: "", error: "Screenshot failed")
                }
                let b64 = imageData.base64EncodedString()
                return RemoteResponseMessage(id: id, success: true, result: "Screenshot captured", imageData: b64)

            // ── Screen Info ───────────────────────────────────────────────────────
            case "get_screen_info":
                let w = Int(NSScreen.main?.frame.width ?? 0)
                let h = Int(NSScreen.main?.frame.height ?? 0)
                return RemoteResponseMessage(id: id, success: true,
                                             result: "Width: \(w)\nHeight: \(h)")

            // ── Type Text ─────────────────────────────────────────────────────────
            case "type_text":
                let text = params["text"] ?? ""
                let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                               .replacingOccurrences(of: "\"", with: "\\\"")
                try await runAppleScript("""
                    tell application "System Events"
                        keystroke "\(escaped)"
                    end tell
                    """)
                return RemoteResponseMessage(id: id, success: true, result: "Typed: \(text.prefix(40))")

            // ── Press Key ─────────────────────────────────────────────────────────
            case "press_key":
                let key      = params["key"] ?? "return"
                let modStr   = params["modifiers"] ?? ""
                let mods     = buildModifiers(from: modStr)
                let script = mods.isEmpty
                    ? "tell application \"System Events\" to key code \(keyCode(for: key))"
                    : "tell application \"System Events\" to key code \(keyCode(for: key)) using {\(mods)}"
                try await runAppleScript(script)
                return RemoteResponseMessage(id: id, success: true, result: "Pressed \(key)")

            // ── Open App ──────────────────────────────────────────────────────────
            case "open_application":
                let name = params["name"] ?? ""
                try await runAppleScript("tell application \"\(name)\" to activate")
                return RemoteResponseMessage(id: id, success: true, result: "Opened \(name)")

            // ── Launch URL ────────────────────────────────────────────────────────
            case "launch_url":
                let url = params["url"] ?? ""
                try await runShell("open \"\(url)\"")
                return RemoteResponseMessage(id: id, success: true, result: "Opened \(url)")

            // ── List Running Apps ─────────────────────────────────────────────────
            case "list_running_apps":
                let apps = try await runAppleScript("""
                    set appList to ""
                    tell application "System Events"
                        set procList to name of every process where visible is true
                        repeat with p in procList
                            set appList to appList & p & "\n"
                        end repeat
                    end tell
                    return appList
                    """)
                return RemoteResponseMessage(id: id, success: true, result: apps)

            // ── Quit App ──────────────────────────────────────────────────────────
            case "quit_application":
                let name = params["name"] ?? ""
                try await runAppleScript("tell application \"\(name)\" to quit")
                return RemoteResponseMessage(id: id, success: true, result: "Quit \(name)")

            // ── AppleScript ───────────────────────────────────────────────────────
            case "run_applescript":
                let script = params["script"] ?? ""
                let result = try await runAppleScript(script)
                return RemoteResponseMessage(id: id, success: true, result: result)

            // ── Shell ─────────────────────────────────────────────────────────────
            case "run_shell_command":
                let cmd = params["command"] ?? ""
                let result = try await runShell(cmd)
                return RemoteResponseMessage(id: id, success: true, result: result)

            // ── System Info ───────────────────────────────────────────────────────
            case "get_system_info":
                let info = """
                    Hostname: \(ProcessInfo.processInfo.hostName)
                    OS: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
                    CPUs: \(ProcessInfo.processInfo.processorCount)
                    RAM: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB
                    """
                return RemoteResponseMessage(id: id, success: true, result: info)

            // ── Send Notification ─────────────────────────────────────────────────
            case "send_notification":
                let title   = params["title"] ?? "LumiAgent"
                let message = params["message"] ?? ""
                let script = """
                    display notification "\(message)" with title "\(title)"
                    """
                try await runAppleScript(script)
                return RemoteResponseMessage(id: id, success: true, result: "Notification sent")

            // ── Disconnect ────────────────────────────────────────────────────────
            case "disconnect":
                return RemoteResponseMessage(id: id, success: true, result: "Goodbye")

            // ── Data Sync ─────────────────────────────────────────────────────────
            case "get_sync_data":
                let fileName = params["file"] ?? "agents.json"
                if let data = DatabaseManager.shared.rawData(for: fileName) {
                    let b64 = data.base64EncodedString()
                    return RemoteResponseMessage(id: id, success: true, result: "Sync data for \(fileName)", imageData: b64)
                } else {
                    return RemoteResponseMessage(id: id, success: false, result: "", error: "File \(fileName) not found")
                }

            case "push_sync_data":
                let fileName = params["file"] ?? "agents.json"
                guard let b64 = params["data"], let data = Data(base64Encoded: b64) else {
                    return RemoteResponseMessage(id: id, success: false, result: "", error: "Invalid sync data")
                }
                // Save to local database
                // Note: We use a simple save here. Repositories will reload on next access.
                try data.write(to: baseURL().appendingPathComponent(fileName), options: .atomic)
                
                // Notify AppState to reload if it's currently running
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Notification.Name("lumi.dataRemoteUpdated"), object: fileName)
                }
                
                return RemoteResponseMessage(id: id, success: true, result: "Synced \(fileName) to Mac")

            default:
                return RemoteResponseMessage(id: id, success: false, result: "",
                                             error: "Unknown command: \(command.commandType)")
            }
        } catch {
            return RemoteResponseMessage(id: id, success: false, result: "",
                                         error: error.localizedDescription)
        }
    }

    private func baseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("LumiAgent", isDirectory: true)
    }

    // MARK: - Execution Helpers

    @discardableResult
    private func runAppleScript(_ source: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                let result = script?.executeAndReturnError(&error)
                if let err = error {
                    let msg = err[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
                    continuation.resume(throwing: NSError(domain: "AppleScript", code: -1,
                                                         userInfo: [NSLocalizedDescriptionKey: msg]))
                } else {
                    continuation.resume(returning: result?.stringValue ?? "")
                }
            }
        }
    }

    @discardableResult
    private func runShell(_ command: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/bash")
                proc.arguments = ["-c", command]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Key Code Helpers

    private func keyCode(for key: String) -> Int {
        let map: [String: Int] = [
            "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51,
            "escape": 53, "command": 55, "shift": 56, "option": 58, "control": 59,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
            "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
            "f11": 103, "f12": 111,
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3,
            "g": 5, "h": 4, "i": 34, "j": 38, "k": 40, "l": 37,
            "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15,
            "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
            "y": 16, "z": 6,
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
            "6": 22, "7": 26, "8": 28, "9": 25
        ]
        return map[key.lowercased()] ?? 36
    }

    private func buildModifiers(from modString: String) -> String {
        let parts = modString.lowercased().components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var mods: [String] = []
        if parts.contains("command") { mods.append("command down") }
        if parts.contains("shift")   { mods.append("shift down") }
        if parts.contains("option")  { mods.append("option down") }
        if parts.contains("control") { mods.append("control down") }
        return mods.joined(separator: ", ")
    }

    // MARK: - Encode Response

    private func encodeResponse(_ response: RemoteResponseMessage) throws -> Data {
        let json = try JSONEncoder().encode(response)
        var length = UInt32(json.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        return frame
    }

    private func persistPairedDevices() {
        UserDefaults.standard.set(Array(pairedDeviceNames).sorted(), forKey: pairedDevicesKey)
    }

    private static func generatePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999999))
    }
}

// MARK: - Buffer Box

/// Reference type to share mutable buffer across async closures.
private final class BufferBox {
    var buffer = Data()
}

// MARK: - Wire Types (macOS-side mirror of iOS RemoteCommand)

// MARK: - Remote Client Info

public struct RemoteClientInfo: Codable, Identifiable {
    public let id: UUID
    public var name: String
    public let address: String
    public let connectedAt: Date
}

private struct RemoteCommandMessage: Codable {
    let id: UUID
    let commandType: String
    let parameters: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, commandType, parameters
    }
}

private struct RemoteResponseMessage: Codable {
    let id: UUID
    let success: Bool
    let result: String
    let error: String?
    let imageData: String?

    init(id: UUID, success: Bool, result: String, error: String? = nil, imageData: String? = nil) {
        self.id = id
        self.success = success
        self.result = result
        self.error = error
        self.imageData = imageData
    }
}
#endif
