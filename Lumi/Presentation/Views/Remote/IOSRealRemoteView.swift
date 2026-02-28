#if os(iOS)
import SwiftUI
import Network
import Combine
import UIKit

struct IOSRemoteDevice: Identifiable, Equatable {
    enum State: Equatable {
        case discovered
        case connecting
        case connected
        case disconnected
        case failed(String)

        var text: String {
            switch self {
            case .discovered: return "Tap to connect"
            case .connecting: return "Connecting..."
            case .connected: return "Connected"
            case .disconnected: return "Disconnected"
            case .failed(let msg): return "Failed: \(msg)"
            }
        }
    }

    let id = UUID()
    let name: String
    let serviceName: String
    let endpoint: NWEndpoint
    var state: State = .discovered

    static func == (lhs: IOSRemoteDevice, rhs: IOSRemoteDevice) -> Bool {
        lhs.serviceName == rhs.serviceName && lhs.name == rhs.name
    }
}

private struct IOSRemoteCommand: Codable {
    let id: UUID
    let commandType: String
    let parameters: [String: String]

    init(type: String, parameters: [String: String] = [:]) {
        self.id = UUID()
        self.commandType = type
        self.parameters = parameters
    }
}

struct IOSRemoteResponse: Codable {
    let id: UUID
    let success: Bool
    let result: String
    let error: String?
    let imageData: String?
}

private enum IOSWireFrame {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

@MainActor
final class IOSBonjourDiscovery: ObservableObject {
    @Published private(set) var devices: [IOSRemoteDevice] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var error: String?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.lumi.ios.remote-discovery", qos: .utility)

    func start() {
        guard !isBrowsing else { return }
        error = nil
        isBrowsing = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_lumiagent._tcp", domain: nil)
        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(for: descriptor, using: params)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self, state] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.error = nil
                case .failed(let err):
                    self.error = err.localizedDescription
                    self.isBrowsing = false
                case .cancelled:
                    self.isBrowsing = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self, results] in
                guard let self else { return }
                var mapped: [IOSRemoteDevice] = []
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    let known = self.devices.first(where: { $0.serviceName == name })
                    let pretty = name
                        .replacingOccurrences(of: ".local.", with: "")
                        .replacingOccurrences(of: ".local", with: "")
                        .replacingOccurrences(of: "-", with: " ")
                    mapped.append(IOSRemoteDevice(
                        name: pretty,
                        serviceName: name,
                        endpoint: result.endpoint,
                        state: known?.state ?? .discovered
                    ))
                }
                self.devices = mapped
            }
        }

        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }
}

@MainActor
final class IOSMacRemoteClient: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var lastResult: String?
    @Published private(set) var lastScreenshot: UIImage?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.lumi.ios.remote-client", qos: .userInitiated)
    private var pending: [UUID: CheckedContinuation<IOSRemoteResponse, Error>] = [:]
    private var receiveBuffer = Data()
    private var connectionContinuation: CheckedContinuation<Void, Error>?

    func connect(to endpoint: NWEndpoint) async throws {
        if isConnected { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.connectionContinuation = continuation

            conn.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self, state] in
                    self?.handleStateUpdate(state)
                }
            }
            conn.start(queue: queue)

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await MainActor.run { [weak self] in
                    self?.handleTimeout()
                }
            }
        }
    }

    private func handleStateUpdate(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isConnected = true
            connectionContinuation?.resume()
            connectionContinuation = nil
            receiveLoop()
        case .waiting(let err):
            if connectionContinuation != nil {
                isConnected = false
                connectionContinuation?.resume(throwing: err)
                connectionContinuation = nil
                cancelPending(with: err)
            }
        case .failed(let err):
            isConnected = false
            connectionContinuation?.resume(throwing: err)
            connectionContinuation = nil
            cancelPending(with: err)
        case .cancelled:
            isConnected = false
            connectionContinuation?.resume(throwing: CancellationError())
            connectionContinuation = nil
        default:
            break
        }
    }

    private func handleTimeout() {
        guard let continuation = connectionContinuation else { return }
        let timeout = NSError(
            domain: "Remote",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Connection timed out. Check Wi-Fi and Mac pairing screen."]
        )
        connection?.cancel()
        connection = nil
        isConnected = false
        continuation.resume(throwing: timeout)
        connectionContinuation = nil
    }

    func connect(host: String, port: UInt16 = 47285) async throws {
        let target = NWEndpoint.Host(host)
        guard let p = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "Remote", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }
        try await connect(to: .hostPort(host: target, port: p))
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        cancelPending(with: CancellationError())
    }

    func send(_ type: String, parameters: [String: String] = [:], timeout: TimeInterval = 15) async throws -> IOSRemoteResponse {
        guard let connection, isConnected else {
            throw NSError(domain: "Remote", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }

        let cmd = IOSRemoteCommand(type: type, parameters: parameters)
        let frame = try IOSWireFrame.encode(cmd)

        return try await withCheckedThrowingContinuation { continuation in
            pending[cmd.id] = continuation
            connection.send(content: frame, completion: .contentProcessed { [weak self] err in
                if let err {
                    Task { @MainActor [weak self, err] in
                        self?.pending.removeValue(forKey: cmd.id)?.resume(throwing: err)
                    }
                }
            })

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await MainActor.run { [weak self] in
                    self?.pending.removeValue(forKey: cmd.id)?.resume(throwing: NSError(domain: "Remote", code: 2, userInfo: [NSLocalizedDescriptionKey: "Command timed out"]))
                }
            }
        }
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, err in
            Task { @MainActor [weak self, data, complete, err] in
                guard let self else { return }
                if let data {
                    self.receiveBuffer.append(data)
                    self.drainBuffer()
                }
                if let err {
                    self.isConnected = false
                    self.cancelPending(with: err)
                    return
                }
                if complete {
                    self.isConnected = false
                    self.cancelPending(with: NSError(domain: "Remote", code: 3, userInfo: [NSLocalizedDescriptionKey: "Connection closed"]))
                    return
                }
                self.receiveLoop()
            }
        }
    }

    private func drainBuffer() {
        // Defensive cap so corrupted streams cannot grow unbounded.
        if receiveBuffer.count > 16_777_216 {
            connection?.cancel()
            isConnected = false
            cancelPending(with: NSError(domain: "Remote", code: 10, userInfo: [NSLocalizedDescriptionKey: "Receive buffer overflow"]))
            receiveBuffer.removeAll(keepingCapacity: false)
            return
        }

        while true {
            guard receiveBuffer.count >= 4 else { break }
            let headerBytes = [UInt8](receiveBuffer.prefix(4))
            guard headerBytes.count == 4 else { break }

            let payloadLength =
                (Int(headerBytes[0]) << 24) |
                (Int(headerBytes[1]) << 16) |
                (Int(headerBytes[2]) << 8)  |
                Int(headerBytes[3])

            // Guard against malformed/corrupt frame lengths.
            if payloadLength < 0 || payloadLength > 8_388_608 {
                connection?.cancel()
                isConnected = false
                cancelPending(with: NSError(domain: "Remote", code: 9, userInfo: [NSLocalizedDescriptionKey: "Invalid frame length"]))
                receiveBuffer.removeAll(keepingCapacity: false)
                return
            }

            let total = 4 + payloadLength
            guard receiveBuffer.count >= total else { break }

            let start = receiveBuffer.startIndex
            let payload = Data(receiveBuffer[start + 4 ..< start + total])
            receiveBuffer.removeFirst(total)

            if let response = try? IOSWireFrame.decode(IOSRemoteResponse.self, from: payload) {
                if let imageData = response.imageData,
                   let decoded = Data(base64Encoded: imageData),
                   let image = UIImage(data: decoded) {
                    lastScreenshot = image
                }
                lastResult = response.success ? response.result : (response.error ?? "Command failed")
                pending.removeValue(forKey: response.id)?.resume(returning: response)
            }
        }
    }

    private func cancelPending(with error: Error) {
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
    }
}

@MainActor
final class IOSRealRemoteViewModel: ObservableObject {
    @Published private(set) var devices: [IOSRemoteDevice] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var connectedDevice: IOSRemoteDevice?
    @Published private(set) var isBusy = false
    @Published private(set) var isSyncing = false
    @Published private(set) var syncProgress: Double = 0
    @Published private(set) var syncDetail: String?
    @Published var status: String?
    @Published var shellCommand = ""
    @Published var directHost: String = UserDefaults.standard.string(forKey: "remote.directHost") ?? ""

    let discovery = IOSBonjourDiscovery()
    let client = IOSMacRemoteClient()
    private var cancellables = Set<AnyCancellable>()
    private var continuousSyncTask: Task<Void, Never>?
    private var localChangeSyncTask: Task<Void, Never>?
    private var isSyncInFlight = false
    private var isApprovedSession = false
    private let syncFiles = [
        "agents.json",
        "conversations.json",
        "automations.json",
        "sync_settings.json",
        "sync_api_keys.json",
        "health_data.json"
    ]

    init() {
        discovery.$devices.receive(on: RunLoop.main).assign(to: &$devices)
        discovery.$isBrowsing.receive(on: RunLoop.main).assign(to: &$isBrowsing)

        client.$lastResult
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                if let value = $0 { self?.status = value }
            }
            .store(in: &cancellables)

        client.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if !connected, self.isApprovedSession {
                    self.status = "Connection lost"
                    self.endRemoteSession()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Notification.Name("lumi.localDataChanged"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleLocalChangeSync()
            }
            .store(in: &cancellables)
    }

    deinit {
        continuousSyncTask?.cancel()
        localChangeSyncTask?.cancel()
        Task { @MainActor in
            AppState.shared?.setRemoteMacBridge(isConnected: false, executor: nil)
        }
    }

    func start() { discovery.start() }
    func stop() { discovery.stop() }

    func connect(_ device: IOSRemoteDevice) {
        guard !isBusy else { return }
        isBusy = true
        status = "Connecting to \(device.name)..."

        Task {
            do {
                try await client.connect(to: device.endpoint)
                try await awaitApproval()
                connectedDevice = device
                status = "Connected to \(device.name)"
                beginRemoteSession()
                await syncBidirectional(showProgress: true)
            } catch {
                status = error.localizedDescription
                client.disconnect()
                endRemoteSession()
            }
            isBusy = false
        }
    }

    func connectDirect() {
        let host = directHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        guard !isBusy else { return }
        isBusy = true
        status = "Connecting directly to \(host)..."
        UserDefaults.standard.set(host, forKey: "remote.directHost")

        Task {
            do {
                try await client.connect(host: host, port: 47285)
                try await awaitApproval()
                connectedDevice = IOSRemoteDevice(
                    name: host,
                    serviceName: host,
                    endpoint: .hostPort(host: .init(host), port: .init(integerLiteral: 47285)),
                    state: .connected
                )
                status = "Connected to \(host)"
                beginRemoteSession()
                await syncBidirectional(showProgress: true)
            } catch {
                status = error.localizedDescription
                client.disconnect()
                endRemoteSession()
            }
            isBusy = false
        }
    }

    private func awaitApproval() async throws {
        var approved = false
        for _ in 0..<60 {
            let ping = try await client.send(
                "ping",
                parameters: ["device_name": UIDevice.current.name],
                timeout: 5
            )
            if ping.success {
                approved = true
                break
            }

            let errorText = ping.error ?? "Connection refused"
            status = errorText
            if errorText.localizedCaseInsensitiveContains("awaiting approval") {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            throw NSError(domain: "Remote", code: 7, userInfo: [NSLocalizedDescriptionKey: errorText])
        }

        guard approved else {
            throw NSError(
                domain: "Remote",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Approval timed out. Accept the request on Mac and try again."]
            )
        }
    }

    func disconnect() {
        endRemoteSession()
        client.disconnect()
        connectedDevice = nil
        status = "Disconnected"
    }

    func ping() {
        run("ping", parameters: ["device_name": UIDevice.current.name], timeout: 5)
    }

    func screenshot() {
        run("screenshot", timeout: 30)
    }

    func setVolume(_ percent: Int) {
        run("set_volume", parameters: ["level": String(percent)])
    }

    func runShell() {
        let cmd = shellCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        run("run_shell_command", parameters: ["command": cmd], timeout: 30)
        shellCommand = ""
    }

    func syncNow() {
        guard connectedDevice != nil else {
            status = "Not connected"
            return
        }
        Task { await syncBidirectional(showProgress: true) }
    }

    private func syncBidirectional(showProgress: Bool) async {
        guard connectedDevice != nil, isApprovedSession else { return }
        guard !isSyncInFlight else { return }
        isSyncInFlight = true
        defer { isSyncInFlight = false }

        #if os(iOS)
        if UserDefaults.standard.bool(forKey: "settings.syncHealth") {
            await IOSHealthKitManager.shared.prefetchAndCacheSync()
        }
        #endif

        // PRE-FLIGHT CHECK: Skip the whole sync if both sides are up to date for all files.
        var anyUpdateNeeded = false
        for file in syncFiles {
            let localData = localSyncData(for: file)
            let localMax = localData.flatMap { maxTimestamp(in: $0) } ?? .distantPast
            
            do {
                let response = try await client.send("get_sync_data", parameters: ["file": file], timeout: 10)
                if response.success {
                    let iso = ISO8601DateFormatter()
                    var remoteMax: Date = .distantPast
                    if let resultStr = response.result.components(separatedBy: "|").first(where: { $0.hasPrefix("updatedAt:") }) {
                        let ts = resultStr.replacingOccurrences(of: "updatedAt:", with: "")
                        remoteMax = iso.date(from: ts) ?? .distantPast
                    }
                    if remoteMax != localMax {
                        anyUpdateNeeded = true
                        break
                    }
                } else {
                    // If Mac doesn't have it but we do, we need to push.
                    if localData != nil {
                        anyUpdateNeeded = true
                        break
                    }
                }
            } catch {
                // If we can't check, assume update is needed or let it fail later.
                anyUpdateNeeded = true
                break
            }
        }

        if !anyUpdateNeeded {
            print("[Sync] Skipping sync - all files are up to date.")
            if showProgress {
                status = "Up to date"
                isSyncing = false
            }
            return
        }

        let totalSteps = Double(syncFiles.count * 2)
        var completedSteps = 0.0
        func step(_ detail: String? = nil) {
            completedSteps += 1
            if showProgress {
                if let detail { syncDetail = detail }
                syncProgress = min(1.0, completedSteps / max(totalSteps, 1))
            }
        }

        if showProgress {
            isSyncing = true
            syncProgress = 0
            syncDetail = "Preparing Wi-Fi sync..."
            status = "Syncing..."
        }

        // Push local changes from iPhone to Mac first.
        for file in syncFiles {
            do {
                if showProgress {
                    syncDetail = "Uploading \(friendlyFileName(file))..."
                }
                
                guard let localData = localSyncData(for: file) else {
                    step()
                    continue
                }

                let response = try await client.send(
                    "push_sync_data",
                    parameters: ["file": file, "data": localData.base64EncodedString()],
                    timeout: 25
                )
                if !response.success {
                    // Stale data error from Mac is expected if Mac was updated in parallel
                    print("[Sync] Upload result for \(file): \(response.result)")
                }
            } catch {
                status = "Sync upload error: \(error.localizedDescription)"
            }
            step()
        }

        // Pull latest data from Mac to iPhone.
        for file in syncFiles {
            do {
                if shouldSkipPull(for: file) {
                    step()
                    continue
                }
                if showProgress {
                    syncDetail = "Downloading \(friendlyFileName(file))..."
                }
                let response = try await client.send("get_sync_data", parameters: ["file": file], timeout: 20)
                guard response.success,
                      let b64 = response.imageData,
                      let data = Data(base64Encoded: b64) else {
                    step()
                    continue
                }

                // CONFLICT RESOLUTION: Skip pulling if local is newer
                if ["agents.json", "conversations.json", "automations.json"].contains(file) {
                    if let localData = localSyncData(for: file) {
                        let localMax = maxTimestamp(in: localData)
                        let remoteMax = maxTimestamp(in: data)
                        
                        if localMax > remoteMax {
                            print("[Sync] Skipping download of \(file) - iPhone is newer (Local: \(localMax), Remote: \(remoteMax))")
                            step()
                            continue
                        }
                    }
                }

                try await applyPulledData(data, for: file)
            } catch {
                status = "Sync download error: \(error.localizedDescription)"
            }
            step()
        }

        NotificationCenter.default.post(name: Notification.Name("lumi.dataRemoteUpdated"), object: nil)

        if showProgress {
            status = "Sync complete"
            syncDetail = "Wi-Fi sync complete"
            isSyncing = false
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                syncDetail = nil
                syncProgress = 0
            }
        }
    }

    private func beginRemoteSession() {
        isApprovedSession = true
        AppState.shared?.setRemoteMacBridge(
            isConnected: true,
            executor: { [weak self] commandType, parameters, timeout in
                guard let self else {
                    throw NSError(domain: "Remote", code: 12, userInfo: [NSLocalizedDescriptionKey: "Remote session ended"])
                }
                return try await self.client.send(commandType, parameters: parameters, timeout: timeout)
            }
        )
        startContinuousSyncLoop()
    }

    private func endRemoteSession() {
        isApprovedSession = false
        continuousSyncTask?.cancel()
        continuousSyncTask = nil
        localChangeSyncTask?.cancel()
        localChangeSyncTask = nil
        AppState.shared?.setRemoteMacBridge(isConnected: false, executor: nil)
    }

    private func startContinuousSyncLoop() {
        continuousSyncTask?.cancel()
        continuousSyncTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard self.connectedDevice != nil, self.client.isConnected, self.isApprovedSession else { break }
                await self.syncBidirectional(showProgress: false)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func scheduleLocalChangeSync() {
        guard connectedDevice != nil, client.isConnected, isApprovedSession else { return }
        localChangeSyncTask?.cancel()
        localChangeSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self else { return }
            await self.syncBidirectional(showProgress: false)
        }
    }

    private func shouldSkipPull(for file: String) -> Bool {
        guard file == "conversations.json" else { return false }
        return AppState.shared?.conversations
            .contains(where: { conv in conv.messages.contains(where: \.isStreaming) }) == true
    }

    private struct SyncCollectionMetadata: Codable {
        let updatedAt: Date
    }

    private func maxTimestamp(in data: Data) -> Date {
        if let metadata = try? JSONDecoder().decode(SyncCollectionMetadata.self, from: data) {
            return metadata.updatedAt
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return .distantPast
        }
        return maxTimestamp(in: json)
    }

    private func maxTimestamp(in json: Any) -> Date {
        switch json {
        case let dict as [String: Any]:
            var timestamps: [Date] = []
            if let updated = dict["updatedAt"], let date = parseDateValue(updated) {
                timestamps.append(date)
            }
            if let items = dict["items"] {
                let nested = maxTimestamp(in: items)
                if nested > .distantPast {
                    timestamps.append(nested)
                }
            }
            return timestamps.max() ?? .distantPast
        case let array as [Any]:
            return array.map { maxTimestamp(in: $0) }.max() ?? .distantPast
        default:
            return .distantPast
        }
    }

    private func parseDateValue(_ raw: Any) -> Date? {
        if let value = raw as? Double {
            return Date(timeIntervalSinceReferenceDate: value)
        }
        if let value = raw as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: value.doubleValue)
        }
        if let text = raw as? String {
            let iso = ISO8601DateFormatter()
            return iso.date(from: text)
        }
        return nil
    }

    private func applyPulledData(_ data: Data, for file: String) async throws {
        switch file {
        case "sync_settings.json":
            applySettingsFromJSON(data)
        case "sync_api_keys.json":
            applyAPIKeysFromJSON(data)
        case "health_data.json":
            let targetURL = localBaseURL().appendingPathComponent(file)
            try await Task.detached(priority: .utility) {
                try data.write(to: targetURL, options: .atomic)
            }.value
            #if os(iOS)
            IOSHealthKitManager.shared.updateCachedSyncData(data)
            #endif
        default:
            let targetURL = localBaseURL().appendingPathComponent(file)
            try await Task.detached(priority: .utility) {
                try data.write(to: targetURL, options: .atomic)
            }.value
        }
    }

    private func localSyncData(for file: String) -> Data? {
        switch file {
        case "sync_settings.json":
            return exportedSettingsJSON()
        case "sync_api_keys.json":
            return exportedAPIKeysJSON()
        case "health_data.json":
            #if os(iOS)
            if UserDefaults.standard.bool(forKey: "settings.syncHealth") {
                return IOSHealthKitManager.shared.cachedOrPersistedSyncData()
            }
            return nil
            #else
            let url = localBaseURL().appendingPathComponent(file)
            return try? Data(contentsOf: url)
            #endif
        default:
            let url = localBaseURL().appendingPathComponent(file)
            return try? Data(contentsOf: url)
        }
    }

    private func friendlyFileName(_ file: String) -> String {
        switch file {
        case "agents.json": return "Agents"
        case "conversations.json": return "Chats"
        case "automations.json": return "Automations"
        case "sync_settings.json": return "Settings"
        case "sync_api_keys.json": return "API Keys"
        case "health_data.json": return "Health Data"
        default: return file
        }
    }

    private func localBaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("LumiAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func applySettingsFromJSON(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (k, v) in obj {
            UserDefaults.standard.set(v, forKey: k)
        }
    }

    private func applyAPIKeysFromJSON(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        for (k, v) in obj {
            UserDefaults.standard.set(v, forKey: k)
        }
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

    private func run(_ type: String, parameters: [String: String] = [:], timeout: TimeInterval = 15) {
        guard connectedDevice != nil else {
            status = "Not connected"
            return
        }

        isBusy = true
        Task {
            do {
                _ = try await client.send(type, parameters: parameters, timeout: timeout)
            } catch {
                status = error.localizedDescription
                if !client.isConnected {
                    connectedDevice = nil
                    endRemoteSession()
                }
            }
            isBusy = false
        }
    }
}

struct IOSRealRemoteControlView: View {
    @StateObject private var vm = IOSRealRemoteViewModel()

    var body: some View {
        List {
            if vm.connectedDevice == nil {
                Section("Direct Connect (Cable/Port)") {
                    TextField("Host or IP (e.g. 192.168.2.10)", text: $vm.directHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Connect Direct") { vm.connectDirect() }
                        .disabled(vm.directHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isBusy)
                }

                Section {
                    if vm.devices.isEmpty {
                        HStack(spacing: 10) {
                            if vm.isBrowsing { ProgressView().controlSize(.small) }
                            Text(vm.isBrowsing ? "Scanning for Macs..." : "No Macs found")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(vm.devices) { device in
                            Button {
                                vm.connect(device)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(device.name).font(.headline)
                                        Text(device.state.text).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if vm.isBusy { ProgressView().controlSize(.small) }
                                }
                            }
                            .disabled(vm.isBusy)
                        }
                    }
                } header: {
                    Text("Nearby Devices")
                }
            } else {
                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(vm.connectedDevice?.name ?? "Mac").font(.headline)
                            Text("Connected").font(.caption).foregroundStyle(.green)
                        }
                        Spacer()
                        Button("Disconnect", role: .destructive) { vm.disconnect() }
                    }
                }

                Section("Quick Actions") {
                    Button("Ping") { vm.ping() }
                    Button("Sync Now") { vm.syncNow() }
                    Button("Take Screenshot") { vm.screenshot() }
                    HStack {
                        Button("Volume 25%") { vm.setVolume(25) }
                        Button("Volume 50%") { vm.setVolume(50) }
                        Button("Volume 100%") { vm.setVolume(100) }
                    }
                }

                Section("Run Shell Command") {
                    TextField("say hello", text: $vm.shellCommand)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Execute") { vm.runShell() }
                        .disabled(vm.shellCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isBusy)
                }

                if let image = vm.client.lastScreenshot {
                    Section("Latest Screenshot") {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }

            if let status = vm.status {
                Section("Status") {
                    MarkdownMessageView(text: status, agents: AppState.shared?.agents ?? [], fontSize: 11)
                        .foregroundStyle(.secondary)
                }
            }

            if vm.isSyncing || vm.syncProgress > 0 || vm.syncDetail != nil {
                Section("Wi-Fi Sync") {
                    if let detail = vm.syncDetail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: vm.syncProgress, total: 1.0)
                        .tint(.blue)
                    Text("\(Int(vm.syncProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Mac Remote")
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }
}
#endif
