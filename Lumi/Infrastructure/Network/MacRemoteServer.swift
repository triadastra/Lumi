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
import Darwin

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
    @Published public private(set) var pendingApprovals: [RemoteConnectionApproval] = []

    // MARK: - Private

    private var listener: NWListener?
    private var activeConnections: [UUID: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.lumiagent.server", qos: .userInitiated)
    private var approvedConnections: Set<UUID> = []
    private var rejectedConnections: Set<UUID> = []

    private init() {}

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
        approvedConnections.removeAll()
        rejectedConnections.removeAll()
        pendingApprovals.removeAll()
        isRunning = false
        print("[MacRemoteServer] Stopped")
    }

    public func approveConnection(_ id: UUID) {
        pendingApprovals.removeAll { $0.id == id }
        rejectedConnections.remove(id)
        approvedConnections.insert(id)
    }

    public func rejectConnection(_ id: UUID) {
        pendingApprovals.removeAll { $0.id == id }
        approvedConnections.remove(id)
        rejectedConnections.insert(id)
        activeConnections[id]?.cancel()
    }

    public func connectionHints() -> [String] {
        let port = String(Self.port)
        var hints: Set<String> = ["localhost:\(port)"]

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return Array(hints).sorted()
        }
        defer { freeifaddrs(ifaddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let flags = Int32(p.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp, !isLoopback, let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    let ip = String(cString: host)
                    hints.insert("\(ip):\(port)")
                }
            }
            cursor = p.pointee.ifa_next
        }

        return Array(hints).sorted()
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
        let endpointString = "\(connection.endpoint)"

        // Replace stale duplicate entries for the same network endpoint.
        if let stale = connectedClients.first(where: { $0.address == endpointString }) {
            activeConnections[stale.id]?.cancel()
            removeConnection(id: stale.id)
        }

        activeConnections[connectionID] = connection
        
        let clientInfo = RemoteClientInfo(
            id: connectionID,
            name: "iPhone", // Initial placeholder
            address: endpointString,
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
        pendingApprovals.removeAll { $0.id == id }
        approvedConnections.remove(id)
        rejectedConnections.remove(id)
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
                
                let response = await execute(command, from: id)
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

        // Keep one active row per device name to avoid list explosion on reconnects.
        let duplicates = connectedClients.filter { $0.name == name && $0.id != id }.map(\.id)
        for dup in duplicates {
            activeConnections[dup]?.cancel()
            removeConnection(id: dup)
        }
    }

    // MARK: - Command Execution

    private func execute(_ command: RemoteCommandMessage, from connectionID: UUID) async -> RemoteResponseMessage {
        let id = command.id
        let params = command.parameters

        do {
            switch command.commandType {

            // ── Ping ──────────────────────────────────────────────────────────────
            case "ping":
                let deviceName = params["device_name"] ?? "Unknown iPhone"
                updateClientName(id: connectionID, name: deviceName)

                if rejectedConnections.contains(connectionID) {
                    return RemoteResponseMessage(
                        id: id,
                        success: false,
                        result: "",
                        error: "Connection rejected by Mac."
                    )
                }

                if !approvedConnections.contains(connectionID) {
                    if !pendingApprovals.contains(where: { $0.id == connectionID }) {
                        let address = connectedClients.first(where: { $0.id == connectionID })?.address ?? ""
                        pendingApprovals.append(
                            RemoteConnectionApproval(
                                id: connectionID,
                                name: deviceName,
                                address: address,
                                requestedAt: Date()
                            )
                        )
                        NSApp.requestUserAttention(.criticalRequest)
                    }
                    return RemoteResponseMessage(
                        id: id,
                        success: false,
                        result: "",
                        error: "Awaiting approval on Mac. Please accept this connection."
                    )
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

            // ── Mouse ─────────────────────────────────────────────────────────────
            case "move_mouse":
                guard let x = Double(params["x"] ?? ""), let y = Double(params["y"] ?? "") else {
                    return RemoteResponseMessage(id: id, success: false, result: "", error: "Missing x/y for move_mouse")
                }
                try moveMouse(to: CGPoint(x: x, y: y))
                return RemoteResponseMessage(id: id, success: true, result: "Mouse moved to (\(Int(x)), \(Int(y)))")

            case "click_mouse":
                let buttonString = (params["button"] ?? "left").lowercased()
                let button: CGMouseButton = (buttonString == "right") ? .right : .left
                let point: CGPoint
                if let x = Double(params["x"] ?? ""), let y = Double(params["y"] ?? "") {
                    point = CGPoint(x: x, y: y)
                    try moveMouse(to: point)
                } else {
                    point = currentMouseLocation()
                }
                try clickMouse(at: point, button: button)
                return RemoteResponseMessage(id: id, success: true, result: "Mouse click \(buttonString)")

            case "scroll_mouse":
                let dx = Int32(params["delta_x"] ?? "0") ?? 0
                let dy = Int32(params["delta_y"] ?? "0") ?? Int32(params["delta"] ?? "0") ?? 0
                try scrollMouse(deltaX: dx, deltaY: dy)
                return RemoteResponseMessage(id: id, success: true, result: "Mouse scrolled (\(dx), \(dy))")

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
                if fileName == "sync_settings.json" {
                    let payload = exportedSettingsJSON()
                    let b64 = payload.base64EncodedString()
                    return RemoteResponseMessage(id: id, success: true, result: "Sync settings", imageData: b64)
                }
                if fileName == "sync_api_keys.json" {
                    let payload = exportedAPIKeysJSON()
                    let b64 = payload.base64EncodedString()
                    return RemoteResponseMessage(id: id, success: true, result: "Sync API keys", imageData: b64)
                }
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

    private func currentMouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func moveMouse(to point: CGPoint) throws {
        guard let move = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw NSError(domain: "Mouse", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create move event"])
        }
        move.post(tap: .cghidEventTap)
    }

    private func clickMouse(at point: CGPoint, button: CGMouseButton) throws {
        let downType: CGEventType = (button == .right) ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = (button == .right) ? .rightMouseUp : .leftMouseUp
        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
            throw NSError(domain: "Mouse", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create click event"])
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func scrollMouse(deltaX: Int32, deltaY: Int32) throws {
        guard let scroll = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else {
            throw NSError(domain: "Mouse", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create scroll event"])
        }
        scroll.post(tap: .cghidEventTap)
    }

    private func exportedSettingsJSON() -> Data {
        let keys = UserDefaults.standard.dictionaryRepresentation().keys
            .filter {
                $0.hasPrefix("settings.") ||
                $0.hasPrefix("account.") ||
                $0.hasPrefix("preferences.")
            }
            .sorted()

        var dict: [String: Any] = [:]
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key),
               JSONSerialization.isValidJSONObject([key: value]) {
                dict[key] = value
            }
        }
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    private func exportedAPIKeysJSON() -> Data {
        let keys = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("lumiagent.apikey.") }
            .sorted()
        var dict: [String: String] = [:]
        for key in keys {
            if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty {
                dict[key] = value
            }
        }
        return (try? JSONEncoder().encode(dict)) ?? Data()
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

public struct RemoteConnectionApproval: Identifiable {
    public let id: UUID
    public let name: String
    public let address: String
    public let requestedAt: Date
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
