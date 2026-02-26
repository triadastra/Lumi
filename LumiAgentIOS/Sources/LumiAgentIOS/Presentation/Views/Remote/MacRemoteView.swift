//
//  MacRemoteView.swift
//  LumiAgentIOS
//
//  Remote control panel for a connected macOS LumiAgent instance.
//  Covers: brightness, volume, media, screenshot, keyboard, apps, AppleScript.
//

import SwiftUI

// MARK: - Mac Remote View (Root)

public struct MacRemoteView: View {

    @State private var vm = MacRemoteViewModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if vm.connectedDevice == nil {
                    DeviceListView(vm: vm)
                } else {
                    RemoteControlPanel(vm: vm)
                }
            }
            .navigationTitle("Mac Remote")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if vm.connectedDevice != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            vm.disconnect()
                        } label: {
                            Text("Disconnect")
                                .font(.subheadline.bold())
                                .foregroundColor(.red)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .onAppear { vm.startBrowsing() }
        .onDisappear { vm.stopBrowsing() }
    }
}

// MARK: - Device List

private struct DeviceListView: View {
    @Bindable var vm: MacRemoteViewModel

    var body: some View {
        VStack(spacing: 0) {
            if vm.discoveredDevices.isEmpty {
                EmptyDiscoveryView(isBrowsing: vm.isBrowsing, error: vm.browsingError)
            } else {
                List(vm.discoveredDevices) { device in
                    DeviceRow(device: device, isConnecting: vm.isConnecting) {
                        vm.connect(to: device)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = vm.connectionError {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                        .font(.footnote.bold())
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .foregroundStyle(.red)
            }
        }
    }
}

private struct EmptyDiscoveryView: View {
    let isBrowsing: Bool
    let error: String?

    var body: some View {
        VStack(spacing: 24) {
            if let error {
                ZStack {
                    Circle().fill(.red.opacity(0.1)).frame(width: 100, height: 100)
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.red.gradient)
                }
                Text("Discovery Error")
                    .font(.title3.bold())
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if isBrowsing {
                VStack(spacing: 32) {
                    ProgressView()
                        .controlSize(.large)
                    VStack(spacing: 8) {
                        Text("Scanning for Mac devices…")
                            .font(.headline)
                        Text("Make sure LumiAgent is running on your Mac\nand both devices are on the same network.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    Button {
                        vm.stopBrowsing()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            vm.startBrowsing()
                        }
                    } label: {
                        Label("Scan Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            } else {
                ZStack {
                    Circle().fill(.blue.opacity(0.1)).frame(width: 100, height: 100)
                    Image(systemName: "desktopcomputer.and.arrow.down")
                        .font(.system(size: 48))
                        .foregroundStyle(.blue.gradient)
                }
                Text("No Macs Found")
                    .font(.title3.bold())
                Text("Start LumiAgent on your Mac and ensure\nboth devices share the same Wi-Fi.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                Button {
                    vm.stopBrowsing()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        vm.startBrowsing()
                    }
                } label: {
                    Label("Retry Discovery", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DeviceRow: View {
    let device: MacDevice
    let isConnecting: Bool
    let onConnect: () -> Void

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(.blue.opacity(0.1)).frame(width: 40, height: 40)
                    Image(systemName: "desktopcomputer")
                        .font(.headline)
                        .foregroundStyle(.blue.gradient)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(device.connectionState.displayText)
                        .font(.subheadline)
                        .foregroundStyle(device.connectionState == .connected ? .green : .secondary)
                }
                Spacer()
                if isConnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.bold())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 8)
        }
        .disabled(isConnecting)
    }
}

// MARK: - Remote Control Panel

private struct RemoteControlPanel: View {
    @Bindable var vm: MacRemoteViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Connection banner
                ConnectedBanner(deviceName: vm.connectedDevice?.name ?? "Mac",
                                result: vm.syncStatus ?? vm.lastCommandResult,
                                syncProgress: vm.syncProgress,
                                isBusy: vm.isBusy || (vm.syncStatus != nil && vm.syncProgress == 0))

                RemoteHealthCard(vm: vm)
                RemoteBrightnessCard(vm: vm)
                RemoteVolumeCard(vm: vm)
                RemoteMediaCard(vm: vm)
                RemoteScreenCard(vm: vm)
                RemoteKeyboardCard(vm: vm)
                RemoteAppsCard(vm: vm)
                RemoteScriptCard(vm: vm)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        // Sheets
        .sheet(isPresented: $vm.isShowingTypeTextSheet) {
            TypeTextSheet(vm: vm)
        }
        .sheet(isPresented: $vm.isShowingAppleScriptSheet) {
            AppleScriptSheet(vm: vm)
        }
        .sheet(isPresented: $vm.isShowingShellSheet) {
            ShellSheet(vm: vm)
        }
        .sheet(isPresented: $vm.isShowingOpenAppSheet) {
            OpenAppSheet(vm: vm)
        }
    }
}

// MARK: - Connected Banner

private struct ConnectedBanner: View {
    let deviceName: String
    let result: String?
    let syncProgress: Double
    let isBusy: Bool

    var body: some View {
        LumiCard {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(.green.opacity(0.1)).frame(width: 40, height: 40)
                    Image(systemName: "wifi.circle.fill")
                        .foregroundStyle(.green.gradient)
                        .font(.title3)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connected to \(deviceName)")
                        .font(.headline)
                    if let result {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if syncProgress > 0 && syncProgress < 1.0 {
                        ProgressView(value: syncProgress)
                            .tint(.green)
                            .scaleEffect(x: 1, y: 0.5, anchor: .center)
                            .padding(.top, 2)
                    }
                }
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        // Use a trigger to run autoSyncFromMac
                        NotificationCenter.default.post(name: Notification.Name("lumi.triggerSync"), object: nil)
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
    }
}

// MARK: - Remote Health Card

private struct RemoteHealthCard: View {
    @Bindable var vm: MacRemoteViewModel

    var body: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("Health Sync", systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(.pink.gradient)

                Text("Send your iPhone's Apple Health data to your Mac's Health panel for AI analysis.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Button {
                    vm.pushHealthToMac()
                } label: {
                    HStack {
                        Image(systemName: "heart.text.square.fill")
                        Text("Sync Health Data to Mac")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.pink.opacity(0.1))
                    .foregroundStyle(.pink)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(vm.isBusy)
            }
        }
    }
}

// MARK: - Remote Brightness Card

private struct RemoteBrightnessCard: View {
    @Bindable var vm: MacRemoteViewModel

    var body: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("Mac Brightness", systemImage: "sun.max.fill")
                    .font(.headline)
                    .foregroundStyle(.yellow.gradient)

                HStack(spacing: 16) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                    Slider(value: $vm.remoteBrightness, in: 0...1, step: 0.05) { editing in
                        if !editing { vm.setRemoteBrightness(vm.remoteBrightness) }
                    }
                    .tint(.yellow)
                    Image(systemName: "sun.max").foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Text(String(format: "%.0f%%", vm.remoteBrightness * 100))
                        .font(.system(.footnote, design: .rounded))
                        .fontWeight(.bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.yellow.opacity(0.1))
                        .clipShape(Capsule())
                        .foregroundStyle(.yellow)
                }
            }
        }
    }
}

// MARK: - Remote Volume Card

private struct RemoteVolumeCard: View {
    @Bindable var vm: MacRemoteViewModel

    var body: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Mac Volume", systemImage: vm.remoteIsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.headline)
                        .foregroundStyle(.blue.gradient)
                    Spacer()
                    Button {
                        vm.toggleRemoteMute()
                    } label: {
                        Image(systemName: vm.remoteIsMuted ? "speaker.slash.circle.fill" : "speaker.wave.2.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.blue)
                    }
                }

                HStack(spacing: 16) {
                    Image(systemName: "speaker").foregroundStyle(.secondary)
                    Slider(value: $vm.remoteVolume, in: 0...1, step: 0.05) { editing in
                        if !editing { vm.setRemoteVolume(vm.remoteVolume) }
                    }
                    .tint(.blue)
                    .disabled(vm.remoteIsMuted)
                    Image(systemName: "speaker.wave.3").foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Text(vm.remoteIsMuted ? "Muted" : String(format: "%.0f%%", vm.remoteVolume * 100))
                        .font(.system(.footnote, design: .rounded))
                        .fontWeight(.bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Capsule())
                        .foregroundStyle(.blue)
                }
            }
        }
    }
}

// MARK: - Remote Media Card

private struct RemoteMediaCard: View {
    @Bindable var vm: MacRemoteViewModel

    var body: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("Mac Media", systemImage: "music.note")
                    .font(.headline)
                    .foregroundStyle(.purple.gradient)

                if let title = vm.remoteNowPlayingTitle {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline).lineLimit(1)
                        if let artist = vm.remoteNowPlayingArtist {
                            Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack(spacing: 40) {
                    Button { vm.remotePrevious() } label: {
                        Image(systemName: "backward.fill").font(.title2)
                    }
                    Button { vm.remoteIsPlaying ? vm.remotePause() : vm.remotePlay() } label: {
                        Image(systemName: vm.remoteIsPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 52))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .foregroundStyle(.purple)
                    Button { vm.remoteNext() } label: {
                        Image(systemName: "forward.fill").font(.title2)
                    }
                    Spacer()
                    Button { vm.remoteGetNowPlaying() } label: {
                        Image(systemName: "info.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }
}

// MARK: - Remote Screen Card

private struct RemoteScreenCard: View {
    @Bindable var vm: MacRemoteViewModel

    var body: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("Mac Screen", systemImage: "camera.viewfinder")
                    .font(.headline)
                    .foregroundStyle(.indigo.gradient)

                if let screenshot = vm.lastScreenshot {
                    Image(uiImage: screenshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.secondary.opacity(0.2)))
                        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                }

                Button {
                    vm.takeRemoteScreenshot()
                } label: {
                    HStack {
                        Image(systemName: "camera.fill")
                        Text("Capture Now")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.indigo.opacity(0.1))
                    .foregroundStyle(.indigo)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(vm.isBusy)
            }
        }
    }
}

// MARK: - Remote Keyboard Card

private struct RemoteKeyboardCard: View {
    @Bindable var vm: MacRemoteViewModel

    private let shortcuts: [(label: String, key: String, mods: String)] = [
        ("⌘Space", "space", "command"),
        ("⌘C", "c", "command"),
        ("⌘V", "v", "command"),
        ("⌘Z", "z", "command"),
        ("⌘W", "w", "command"),
        ("⌘Q", "q", "command"),
        ("⌘Tab", "tab", "command"),
        ("Escape", "escape", ""),
        ("Return", "return", ""),
        ("⌘⇧3", "3", "command,shift"),
        ("⌘⇧4", "4", "command,shift"),
    ]

    var body: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Keyboard", systemImage: "keyboard")
                        .font(.headline)
                        .foregroundStyle(.orange.gradient)
                    Spacer()
                    Button {
                        vm.isShowingTypeTextSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "text.cursor")
                            Text("Type Text")
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(Capsule())
                    }
                    .foregroundStyle(.orange)
                }

                // Quick-key grid
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 10) {
                    ForEach(shortcuts, id: \.label) { shortcut in
                        Button(shortcut.label) {
                            vm.pressKey(shortcut.key, modifiers: shortcut.mods)
                        }
                        .font(.system(.caption, design: .monospaced).bold())
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Remote Apps Card

private struct RemoteAppsCard: View {
    @Bindable var vm: MacRemoteViewModel

    private let commonApps = ["Safari", "Finder", "Terminal", "Mail", "Music",
                               "System Settings", "Messages", "Calendar", "Notes"]

    var body: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Apps", systemImage: "app.badge")
                        .font(.headline)
                        .foregroundStyle(.pink.gradient)
                    Spacer()
                    Button {
                        vm.isShowingOpenAppSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.pink)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 10) {
                    ForEach(commonApps, id: \.self) { app in
                        Button(app) {
                            vm.openAppName = app
                            vm.sendOpenApp()
                        }
                        .font(.caption.bold())
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Remote Script Card

private struct RemoteScriptCard: View {
    @Bindable var vm: MacRemoteViewModel

    var body: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("Automation", systemImage: "applescript")
                    .font(.headline)
                    .foregroundStyle(.teal.gradient)

                HStack(spacing: 16) {
                    Button {
                        vm.isShowingAppleScriptSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "applescript.fill")
                            Text("AppleScript")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.teal.opacity(0.1))
                        .foregroundStyle(.teal)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)

                    Button {
                        vm.isShowingShellSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "terminal.fill")
                            Text("Shell")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.gray.opacity(0.1))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Sheets

private struct TypeTextSheet: View {
    @Bindable var vm: MacRemoteViewModel
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextEditor(text: $vm.typeTextInput)
                    .focused($focused)
                    .frame(minHeight: 160)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                
                VStack(alignment: .leading, spacing: 8) {
                    Label("Direct Input", systemImage: "keyboard")
                        .font(.headline)
                    Text("Text will be typed into the focused app on your Mac.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Spacer()
            }
            .padding(20)
            .navigationTitle("Type Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { vm.isShowingTypeTextSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { vm.sendTypeText() }
                        .fontWeight(.bold)
                        .disabled(vm.typeTextInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct AppleScriptSheet: View {
    @Bindable var vm: MacRemoteViewModel
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextEditor(text: $vm.appleScriptText)
                    .focused($focused)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 240)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                
                VStack(alignment: .leading, spacing: 8) {
                    Label("Remote Execution", systemImage: "applescript")
                        .font(.headline)
                    Text("Script runs on your Mac. Output appears in the result banner.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Spacer()
            }
            .padding(20)
            .navigationTitle("AppleScript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { vm.isShowingAppleScriptSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { vm.runAppleScript() }
                        .fontWeight(.bold)
                        .disabled(vm.appleScriptText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct ShellSheet: View {
    @Bindable var vm: MacRemoteViewModel
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("Command (e.g. ls ~/Desktop)", text: $vm.shellCommandText)
                    .focused($focused)
                    .font(.system(.body, design: .monospaced))
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                
                VStack(alignment: .leading, spacing: 8) {
                    Label("Terminal", systemImage: "terminal")
                        .font(.headline)
                    Text("Runs on your Mac via /bin/bash. Output is returned as the result.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Spacer()
            }
            .padding(20)
            .navigationTitle("Shell Command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { vm.isShowingShellSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { vm.runShellCommand() }
                        .fontWeight(.bold)
                        .disabled(vm.shellCommandText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

private struct OpenAppSheet: View {
    @Bindable var vm: MacRemoteViewModel
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("App name (e.g. Xcode, TextEdit)", text: $vm.openAppName)
                    .focused($focused)
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .autocorrectionDisabled()
                
                VStack(alignment: .leading, spacing: 8) {
                    Label("Application", systemImage: "app.badge")
                        .font(.headline)
                    Text("Opens the named application on your Mac.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Spacer()
            }
            .padding(20)
            .navigationTitle("Open Application")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { vm.isShowingOpenAppSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") { vm.sendOpenApp() }
                        .fontWeight(.bold)
                        .disabled(vm.openAppName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
