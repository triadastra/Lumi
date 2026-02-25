//
//  MacRemoteViewModel.swift
//  LumiAgentIOS
//
//  ViewModel for the Mac Remote Control tab.
//  Manages Bonjour discovery, connection lifecycle, and command dispatch.
//

import SwiftUI
import Network
import Combine

// MARK: - Mac Remote ViewModel

@MainActor
@Observable
public final class MacRemoteViewModel {

    // MARK: - Discovery

    public private(set) var discoveredDevices: [MacDevice] = []
    public private(set) var isBrowsing: Bool = false
    public private(set) var browsingError: String?

    // MARK: - Connection

    public private(set) var connectedDevice: MacDevice?
    public private(set) var connectionError: String?
    public private(set) var isConnecting: Bool = false

    // MARK: - Remote state (mirrored from Mac)

    public private(set) var remoteBrightness: Double = 0.5
    public private(set) var remoteVolume: Double = 0.5
    public private(set) var remoteIsMuted: Bool = false
    public private(set) var remoteIsPlaying: Bool = false
    public private(set) var remoteNowPlayingTitle: String?
    public private(set) var remoteNowPlayingArtist: String?
    public private(set) var lastScreenshot: UIImage?
    public private(set) var lastCommandResult: String?
    public private(set) var isBusy: Bool = false

    // MARK: - AppleScript sheet

    public var appleScriptText: String = ""
    public var isShowingAppleScriptSheet: Bool = false

    // MARK: - Shell command sheet

    public var shellCommandText: String = ""
    public var isShowingShellSheet: Bool = false

    // MARK: - Type text sheet

    public var typeTextInput: String = ""
    public var isShowingTypeTextSheet: Bool = false

    // MARK: - Open app sheet

    public var openAppName: String = ""
    public var isShowingOpenAppSheet: Bool = false

    // MARK: - Private

    private let discovery = BonjourDiscovery()
    private let client = MacRemoteClient()
    private var cancellables = Set<AnyCancellable>()

    public init() {
        bindDiscovery()
        bindClient()
    }

    // MARK: - Bindings

    private func bindDiscovery() {
        discovery.$discoveredDevices.receive(on: RunLoop.main).sink { [weak self] devices in
            self?.discoveredDevices = devices
        }.store(in: &cancellables)

        discovery.$isBrowsing.receive(on: RunLoop.main).sink { [weak self] val in
            self?.isBrowsing = val
        }.store(in: &cancellables)

        discovery.$browsingError.receive(on: RunLoop.main).sink { [weak self] val in
            self?.browsingError = val
        }.store(in: &cancellables)
    }

    private func bindClient() {
        client.$lastScreenshot.receive(on: RunLoop.main).sink { [weak self] data in
            guard let data else { return }
            self?.lastScreenshot = UIImage(data: data)
        }.store(in: &cancellables)

        client.$lastResult.receive(on: RunLoop.main).sink { [weak self] val in
            self?.lastCommandResult = val
        }.store(in: &cancellables)
    }

    // MARK: - Discovery

    public func startBrowsing() {
        discovery.startBrowsing()
    }

    public func stopBrowsing() {
        discovery.stopBrowsing()
    }

    // MARK: - Connection

    public func connect(to device: MacDevice) {
        guard !isConnecting else { return }
        isConnecting = true
        connectionError = nil

        Task {
            do {
                try await client.connect(to: device)
                connectedDevice = device
                connectionError = nil
                
                // 1. Initial State Refresh
                await refreshRemoteState()
                
                // 2. Peer-to-Peer Auto Sync (Pull from Mac)
                await autoSyncFromMac()
                
            } catch {
                connectionError = error.localizedDescription
            }
            isConnecting = false
        }
    }

    private func autoSyncFromMac() async {
        guard connectedDevice != nil else { return }
        
        let files = ["agents.json", "conversations.json", "automations.json"]
        for file in files {
            do {
                let data = try await client.pullSyncData(file: file)
                // Save to local iOS app storage
                let url = baseURL().appendingPathComponent(file)
                try data.write(to: url, options: .atomic)
                print("✅ Synced \(file) from Mac")
            } catch {
                print("⚠️ Failed to sync \(file): \(error.localizedDescription)")
            }
        }
        
        // Notify local app state to reload (assuming it exists on iOS side)
        // If AppState is shared, it will reload from these files on next access.
    }

    private func baseURL() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let docs = paths[0]
        let lumi = docs.appendingPathComponent("LumiAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: lumi, withIntermediateDirectories: true)
        return lumi
    }

    public func disconnect() {
        client.disconnect()
        connectedDevice = nil
        lastScreenshot = nil
        lastCommandResult = nil
    }

    // MARK: - Remote State Refresh

    public func refreshRemoteState() async {
        guard client.state.isConnected else { return }
        // Ping first
        if let pong = try? await client.ping(), pong.success {
            lastCommandResult = "Connected"
        }
    }

    // MARK: - Remote Commands

    private func runCommand(_ block: @escaping () async throws -> RemoteCommandResponse) {
        guard client.state.isConnected else {
            connectionError = "Not connected to a Mac."
            return
        }
        isBusy = true
        lastCommandResult = nil
        Task {
            do {
                let response = try await block()
                lastCommandResult = response.success ? response.result : (response.error ?? "Command failed")
            } catch {
                lastCommandResult = "Error: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    // MARK: Brightness

    public func setRemoteBrightness(_ level: Double) {
        remoteBrightness = level
        runCommand { [weak self] in
            guard let self else { throw RemoteClientError.notConnected }
            return try await self.client.setBrightness(level)
        }
    }

    // MARK: Volume

    public func setRemoteVolume(_ level: Double) {
        remoteVolume = level
        runCommand { [weak self] in
            guard let self else { throw RemoteClientError.notConnected }
            return try await self.client.setVolume(level)
        }
    }

    public func toggleRemoteMute() {
        remoteIsMuted.toggle()
        let muted = remoteIsMuted
        runCommand { [weak self] in
            guard let self else { throw RemoteClientError.notConnected }
            return try await self.client.setMute(muted)
        }
    }

    // MARK: Media

    public func remotePlay() {
        runCommand { [weak self] in
            guard let self else { throw RemoteClientError.notConnected }
            return try await self.client.mediaPlay()
        }
    }
    public func remotePause() {
        runCommand { [weak self] in
            guard let self else { throw RemoteClientError.notConnected }
            return try await self.client.mediaPause()
        }
    }
    public func remoteNext() {
        runCommand { [weak self] in
            guard let self else { throw RemoteClientError.notConnected }
            return try await self.client.mediaNext()
        }
    }
    public func remotePrevious() {
        runCommand { [weak self] in
            guard let self else { throw RemoteClientError.notConnected }
            return try await self.client.mediaPrevious()
        }
    }

    public func remoteGetNowPlaying() {
        guard client.state.isConnected else { return }
        isBusy = true
        Task {
            if let resp = try? await client.mediaGetInfo(), resp.success {
                lastCommandResult = resp.result
                // Parse "Title: X | Artist: Y" format from macOS side
                parseNowPlaying(resp.result)
            }
            isBusy = false
        }
    }

    private func parseNowPlaying(_ text: String) {
        // Expects "Title: X\nArtist: Y\nAlbum: Z\nPlaying: true"
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let parts = line.components(separatedBy: ": ")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts.dropFirst().joined(separator: ": ").trimmingCharacters(in: .whitespaces)
            switch key.lowercased() {
            case "title":   remoteNowPlayingTitle = value
            case "artist":  remoteNowPlayingArtist = value
            case "playing": remoteIsPlaying = (value.lowercased() == "true")
            default: break
            }
        }
    }

    // MARK: Screenshot

    public func takeRemoteScreenshot() {
        guard client.state.isConnected else { return }
        isBusy = true
        Task {
            if let resp = try? await client.screenshot() {
                lastCommandResult = resp.success ? "Screenshot captured" : (resp.error ?? "Failed")
            }
            isBusy = false
        }
    }

    // MARK: Type Text

    public func sendTypeText() {
        let text = typeTextInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isShowingTypeTextSheet = false
        runCommand { [weak self] in
            guard let self else { throw RemoteClientError.notConnected }
            return try await self.client.typeText(text)
        }
        typeTextInput = ""
    }

    // MARK: Open App

    public func sendOpenApp() {
        let name = openAppName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isShowingOpenAppSheet = false
        runCommand { [weak self] in
            guard let self else { throw RemoteClientError.notConnected }
            return try await self.client.openApplication(name)
        }
        openAppName = ""
    }

    // MARK: AppleScript

    public func runAppleScript() {
        let script = appleScriptText.trimmingCharacters(in: .whitespaces)
        guard !script.isEmpty else { return }
        isShowingAppleScriptSheet = false
        runCommand { [weak self] in
            guard let self else { throw RemoteClientError.notConnected }
            return try await self.client.runAppleScript(script)
        }
    }

    // MARK: Shell

    public func runShellCommand() {
        let cmd = shellCommandText.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        isShowingShellSheet = false
        isBusy = true
        Task {
            let command = RemoteCommand(commandType: .runShellCommand, parameters: ["command": cmd])
            if let resp = try? await client.send(command) {
                lastCommandResult = resp.result
            }
            isBusy = false
        }
        shellCommandText = ""
    }

    // MARK: Common key shortcuts

    public func pressKey(_ key: String, modifiers: String = "") {
        runCommand { [weak self] in
            guard let self else { throw RemoteClientError.notConnected }
            return try await self.client.pressKey(key, modifiers: modifiers)
        }
    }
}
