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
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.error = nil
                case .failed(let err):
                    self?.error = err.localizedDescription
                    self?.isBrowsing = false
                case .cancelled:
                    self?.isBrowsing = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
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

    func connect(to endpoint: NWEndpoint) async throws {
        if isConnected { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            func finish(_ result: Result<Void, Error>) {
                guard !finished else { return }
                finished = true
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            conn.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isConnected = true
                        finish(.success(()))
                        self?.receiveLoop()
                    case .waiting(let err):
                        self?.isConnected = false
                        finish(.failure(err))
                        self?.cancelPending(with: err)
                    case .failed(let err):
                        self?.isConnected = false
                        finish(.failure(err))
                        self?.cancelPending(with: err)
                    case .cancelled:
                        self?.isConnected = false
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }
            }
            conn.start(queue: queue)

            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await MainActor.run {
                    guard !finished else { return }
                    let timeout = NSError(
                        domain: "Remote",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Connection timed out. Check Wi-Fi and Mac pairing screen."]
                    )
                    self.connection?.cancel()
                    self.connection = nil
                    self.isConnected = false
                    finish(.failure(timeout))
                }
            }
        }
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
                    Task { @MainActor in
                        self?.pending.removeValue(forKey: cmd.id)?.resume(throwing: err)
                    }
                }
            })

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await MainActor.run {
                    self?.pending.removeValue(forKey: cmd.id)?.resume(throwing: NSError(domain: "Remote", code: 2, userInfo: [NSLocalizedDescriptionKey: "Command timed out"]))
                }
            }
        }
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, err in
            Task { @MainActor in
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
        while receiveBuffer.count >= 4 {
            let length = receiveBuffer.prefix(4).withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            }
            let total = 4 + Int(length)
            guard receiveBuffer.count >= total else { break }

            let payload = receiveBuffer.subdata(in: 4..<total)
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
    @Published var status: String?
    @Published var shellCommand = ""
    @Published var directHost: String = UserDefaults.standard.string(forKey: "remote.directHost") ?? ""

    let discovery = IOSBonjourDiscovery()
    let client = IOSMacRemoteClient()
    private var cancellables = Set<AnyCancellable>()

    init() {
        discovery.$devices.receive(on: RunLoop.main).assign(to: &$devices)
        discovery.$isBrowsing.receive(on: RunLoop.main).assign(to: &$isBrowsing)

        client.$lastResult
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                if let value = $0 { self?.status = value }
            }
            .store(in: &cancellables)
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
                await autoSyncFromMac()
            } catch {
                status = error.localizedDescription
                client.disconnect()
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
                await autoSyncFromMac()
            } catch {
                status = error.localizedDescription
                client.disconnect()
            }
            isBusy = false
        }
    }

    private func awaitApproval() async throws {
        var approved = false
        for _ in 0..<20 {
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
        Task { await autoSyncFromMac() }
    }

    private func autoSyncFromMac() async {
        let files = [
            "agents.json",
            "conversations.json",
            "automations.json",
            "sync_settings.json",
            "sync_api_keys.json"
        ]

        status = "Syncing..."
        for file in files {
            do {
                let response = try await client.send("get_sync_data", parameters: ["file": file], timeout: 20)
                guard response.success,
                      let b64 = response.imageData,
                      let data = Data(base64Encoded: b64) else {
                    continue
                }

                switch file {
                case "sync_settings.json":
                    applySettingsFromJSON(data)
                case "sync_api_keys.json":
                    applyAPIKeysFromJSON(data)
                default:
                    try data.write(to: localBaseURL().appendingPathComponent(file), options: .atomic)
                }
            } catch {
                status = "Sync error: \(error.localizedDescription)"
            }
        }

        NotificationCenter.default.post(name: Notification.Name("lumi.dataRemoteUpdated"), object: nil)
        status = "Sync complete"
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
                    Text(status)
                        .font(.footnote)
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
