//
//  SettingsView.swift
//  LumiAgent
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Settings View

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountTab()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }

            APIKeysTab()
                .tabItem { Label("API Keys", systemImage: "key.fill") }

            #if os(macOS)
            PermissionsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield.fill") }
            #endif

            IntegrationsTab()
                .tabItem { Label("Integrations", systemImage: "slider.horizontal.3") }

            #if os(macOS)
            HotkeysTab()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            #endif

            SecurityTab()
                .tabItem { Label("Security", systemImage: "shield.fill") }

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle.fill") }
        }
        #if os(macOS)
        .frame(width: 560, height: 520)
        #endif
    }
}

extension Notification.Name {
    static let lumiGlobalHotkeysPreferenceChanged = Notification.Name("lumiGlobalHotkeysPreferenceChanged")
    static let lumiICloudStatusChanged = Notification.Name("lumiICloudStatusChanged")
}

// MARK: - Permissions Tab

#if os(macOS)
struct PermissionsTab: View {
    @StateObject private var permissionManager = SystemPermissionManager.shared
    @State private var timer: Timer?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("System Access")
                        .font(.headline)
                    Text("Lumi Agent requires these system-level permissions to control your Mac, see the screen, and manage files. macOS security requires you to enable these manually in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Quick Setup") {
                Button {
                    permissionManager.requestFullAccess()
                } label: {
                    Label("Enable Full Access (Guided)", systemImage: "shield.lefthalf.filled.badge.checkmark")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("Opens each required macOS privacy pane and triggers prompts where available. Review and enable Lumi Agent in each pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Accessibility") {
                PermissionRow(
                    title: "Mouse & Keyboard Control",
                    description: "Required for Agent Mode to interact with other apps.",
                    isGranted: permissionManager.isAccessibilityGranted,
                    onAction: { permissionManager.requestAccessibility() }
                )
            }

            Section("Screen Recording") {
                PermissionRow(
                    title: "Vision & Screenshots",
                    description: "Required for agents to see what's on your screen.",
                    isGranted: permissionManager.isScreenRecordingGranted,
                    onAction: { permissionManager.requestScreenRecording() }
                )
            }

            Section("Microphone & Camera") {
                PermissionRow(
                    title: "Microphone",
                    description: "Required for voice features and audio capture.",
                    isGranted: permissionManager.isMicrophoneGranted,
                    onAction: { permissionManager.requestMicrophone() }
                )

                PermissionRow(
                    title: "Camera",
                    description: "Required for camera-based features and visual inputs.",
                    isGranted: permissionManager.isCameraGranted,
                    onAction: { permissionManager.requestCamera() }
                )
            }

            Section("Automation & Input Monitoring") {
                ManualPermissionRow(
                    title: "Automation",
                    description: "Allows controlling other apps through Apple Events.",
                    onAction: { permissionManager.requestAutomation() }
                )

                ManualPermissionRow(
                    title: "Input Monitoring",
                    description: "Required for secure key and event monitoring workflows.",
                    onAction: { permissionManager.requestInputMonitoring() }
                )
            }

            Section("Full Disk Access") {
                PermissionRow(
                    title: "Filesystem Mastery",
                    description: "Allows agents to read and write files in restricted folders (Mail, Messages, etc.).",
                    isGranted: permissionManager.isFullDiskAccessGranted,
                    onAction: { permissionManager.requestFullDiskAccess() }
                )
            }

            Section("Privileged Helper") {
                PermissionRow(
                    title: "Sudo Helper",
                    description: "Enables root-level operations (sudo) without constant password prompts.",
                    isGranted: permissionManager.isHelperInstalled,
                    onAction: { permissionManager.installHelper() }
                )
            }

            Section {
                Button {
                    permissionManager.refreshAll()
                } label: {
                    Label("Check Status Again", systemImage: "arrow.clockwise")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            permissionManager.refreshAll()
            // Auto-refresh every 2 seconds while this tab is visible
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                Task { @MainActor in
                    permissionManager.refreshAll()
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let isGranted: Bool
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isGranted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: isGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(isGranted ? .green : .orange)
                    .font(.system(size: 16, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isGranted {
                Text("Enabled")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())
            } else {
                Button(action: onAction) {
                    Text("Grant Access")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ManualPermissionRow: View {
    let title: String
    let description: String
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: "gearshape.2.fill")
                    .foregroundStyle(.blue)
                    .font(.system(size: 16, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onAction) {
                Text("Open Settings")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
#endif

// MARK: - Account Tab

struct AccountTab: View {
    @AppStorage("account.name") private var accountName = ""
    @AppStorage("account.email") private var accountEmail = ""
    @AppStorage("account.joinedAt") private var joinedAt: Double = 0
    @AppStorage("preferences.newsletter") private var wantsUpdates = false
    @AppStorage("preferences.betaFeatures") private var betaFeatures = false
    
    private var joinedDate: Date? { joinedAt > 0 ? Date(timeIntervalSince1970: joinedAt) : nil }

    var body: some View {
        Form {
            Section("System Account") {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(accountName.isEmpty ? "Mac User" : accountName)
                            .font(.headline)
                        Text(accountEmail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let joinedDate {
                            Text("Linked " + joinedDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }

                Text("This app now defaults to your Mac account identity. Apple ID email is not directly readable by third-party apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preferences") {
                Toggle("Product updates by email", isOn: $wantsUpdates)
                Toggle("Early access to beta features", isOn: $betaFeatures)
            }
        }
        .formStyle(.grouped)
        .onAppear { loadSystemAccount() }
    }

    private func loadSystemAccount() {
        #if os(macOS)
        let systemName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let shortName = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        accountName = systemName.isEmpty ? (shortName.isEmpty ? "Mac User" : shortName) : systemName
        if shortName.isEmpty {
            accountEmail = "Apple ID email hidden by macOS"
        } else {
            accountEmail = "\(shortName)@local.mac"
        }
        #else
        if accountName.isEmpty { accountName = "User" }
        if accountEmail.isEmpty { accountEmail = "Apple ID email unavailable" }
        #endif

        if joinedAt == 0 {
            joinedAt = Date().timeIntervalSince1970
        }
    }
}

// MARK: - API Keys Tab

struct APIKeysTab: View {
    @AppStorage("settings.ollamaURL") private var ollamaURL = AppConfig.defaultOllamaURL

    // Input fields
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var geminiKey = ""
    @State private var qwenKey = ""
    @State private var braveKey = ""

    // Saved-flash state
    @State private var savedProvider: AIProvider? = nil
    @State private var braveKeySaved = false

    // Whether a key already exists
    @State private var hasKey: [AIProvider: Bool] = [:]
    @State private var hasBraveKey = false

    var body: some View {
        Form {
            apiKeySection(
                provider: .openai,
                icon: "brain", color: .green,
                title: "OpenAI",
                placeholder: "sk-…",
                key: $openAIKey
            )

            apiKeySection(
                provider: .anthropic,
                icon: "sparkles", color: .purple,
                title: "Anthropic",
                placeholder: "sk-ant-…",
                key: $anthropicKey
            )

            apiKeySection(
                provider: .gemini,
                icon: "atom", color: .blue,
                title: "Gemini (Google AI)",
                placeholder: "AIza…",
                key: $geminiKey
            )

            apiKeySection(
                provider: .qwen,
                icon: "cloud.fill", color: .cyan,
                title: "Aliyun Qwen",
                placeholder: "sk-…",
                key: $qwenKey
            )

            // Brave Search API
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.orange)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Brave Search")
                            .font(.headline)
                        Text(hasBraveKey ? "API key saved" : "No key stored — web_search uses DuckDuckGo fallback")
                            .font(.caption)
                            .foregroundStyle(hasBraveKey ? .green : .secondary)
                    }
                    Spacer()
                    if braveKeySaved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                            .transition(.opacity)
                    }
                }

                SecureField(hasBraveKey ? "Enter new key to replace…" : "BSA…", text: $braveKey)

                Button("Save Brave Search Key") {
                    UserDefaults.standard.set(braveKey, forKey: "settings.braveAPIKey")
                    braveKey = ""
                    hasBraveKey = true
                    braveKeySaved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { braveKeySaved = false }
                }
                .disabled(braveKey.isEmpty)
                .foregroundStyle(.secondary)

                Link("Get a free Brave Search API key →",
                     destination: URL(string: "https://brave.com/search/api/")!)
                    .font(.caption)
            }


            // Ollama — URL only, no key
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.title2)
                        .foregroundStyle(.orange)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ollama")
                            .font(.headline)
                        Text("Local server — no API key required")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Server URL") {
                    TextField("http://localhost:11434", text: $ollamaURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }

                Button("Reset to Default") {
                    ollamaURL = AppConfig.defaultOllamaURL
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loadKeyStatus() }
    }

    @ViewBuilder
    private func apiKeySection(
        provider: AIProvider,
        icon: String, color: Color,
        title: String,
        placeholder: String,
        key: Binding<String>
    ) -> some View {
        let stored = hasKey[provider] == true
        Section {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(stored ? "API key saved" : "No key stored")
                        .font(.caption)
                        .foregroundStyle(stored ? .green : .secondary)
                }
                Spacer()
                if savedProvider == provider {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                        .transition(.opacity)
                }
            }

            SecureField(stored ? "Enter new key to replace…" : placeholder, text: key)

            Button("Save \(title) Key") {
                save(key.wrappedValue, for: provider)
                key.wrappedValue = ""
                hasKey[provider] = true
                savedProvider = provider
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if savedProvider == provider { savedProvider = nil }
                }
            }
            .disabled(key.wrappedValue.isEmpty)
        }
    }

    private func loadKeyStatus() {
        let repo = AIProviderRepository()
        for provider in [AIProvider.openai, .anthropic, .gemini, .qwen] {
            hasKey[provider] = (try? repo.getAPIKey(for: provider)).flatMap { $0.isEmpty ? nil : $0 } != nil
        }
        let bk = UserDefaults.standard.string(forKey: "settings.braveAPIKey") ?? ""
        hasBraveKey = !bk.isEmpty
    }

    private func save(_ key: String, for provider: AIProvider) {
        let repo = AIProviderRepository()
        try? repo.setAPIKey(key, for: provider)
    }
}

// MARK: - Security Tab

struct IntegrationsTab: View {
    @AppStorage("settings.enableSystemServices") private var enableSystemServices = true
    @AppStorage("settings.enableGlobalHotkeys") private var enableGlobalHotkeys = true
    @AppStorage("settings.ollamaURL") private var ollamaURL = AppConfig.defaultOllamaURL

    @State private var ollamaStatus: Status = .checking
    @State private var modelCount = 0

    enum Status {
        case checking, online, offline
    }

    var body: some View {
        Form {
            Section("Ollama Local Server") {
                HStack(spacing: 12) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusText).font(.headline)
                        if ollamaStatus == .online {
                            Text("\(modelCount) models available").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(ollamaURL).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    if ollamaStatus == .offline {
                        Button {
                            AIProviderRepository().launchOllama()
                            checkStatus()
                        } label: {
                            Text("Launch Ollama")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.orange)
                    }
                    
                    Button {
                        checkStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(ollamaStatus == .checking)
                }
                
                if ollamaStatus == .offline {
                    Text("Lumi requires the Ollama server to be running for local agent tasks. If you just launched it, wait a few seconds and refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear { checkStatus() }

            Section("macOS Services") {
                Toggle("Enable Lumi Services", isOn: $enableSystemServices)
                Text("Adds Lumi actions to the macOS Services menu for selected text and safe desktop cleanup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Global Shortcuts") {
                Toggle("Enable Global Hotkeys", isOn: $enableGlobalHotkeys)
                    .onChange(of: enableGlobalHotkeys) {
                        NotificationCenter.default.post(name: .lumiGlobalHotkeysPreferenceChanged, object: nil)
                    }
                Text("When enabled, Lumi captures global shortcuts even while other apps are focused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch ollamaStatus {
        case .checking: return "Checking Ollama..."
        case .online:   return "Ollama is Online"
        case .offline:  return "Ollama is Offline"
        }
    }

    private var statusColor: Color {
        switch ollamaStatus {
        case .checking: return .gray
        case .online:   return .green
        case .offline:  return .red
        }
    }

    private func checkStatus() {
        ollamaStatus = .checking
        Task {
            let repo = AIProviderRepository()
            do {
                let models = try await repo.getAvailableModels(provider: .ollama)
                await MainActor.run {
                    self.modelCount = models.count
                    self.ollamaStatus = .online
                }
            } catch {
                await MainActor.run {
                    self.ollamaStatus = .offline
                }
            }
        }
    }
}

#if os(macOS)
struct HotkeysTab: View {
    @AppStorage("settings.enableGlobalHotkeys") private var enableGlobalHotkeys = true

    private let shortcuts: [(keys: String, action: String)] = [
        ("⌘L", "Open Agent Palette"),
        ("⌃L", "Open Agent Palette (secondary)"),
        ("⌥⌘L", "Open Quick Actions"),
        ("⌥⌘E", "Extend selected text"),
        ("⌥⌘G", "Correct grammar on selected text"),
        ("⌥⌘R", "Answer/do selected request")
    ]

    var body: some View {
        Form {
            Section("Status") {
                HStack {
                    Circle()
                        .fill(enableGlobalHotkeys ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(enableGlobalHotkeys ? "Global hotkeys enabled" : "Global hotkeys disabled")
                        .font(.system(size: 13, weight: .medium))
                }
            }

            Section("Shortcut Reference") {
                ForEach(shortcuts, id: \.keys) { row in
                    HStack {
                        Text(row.action)
                        Spacer()
                        Text(row.keys)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
#endif

struct SecurityTab: View {
    @AppStorage("settings.allowSudo") private var allowSudo = false
    @AppStorage("settings.autoApproveThreshold") private var thresholdRaw = RiskLevel.low.rawValue

    private var autoApproveThreshold: Binding<RiskLevel> {
        Binding(
            get: { RiskLevel(rawValue: thresholdRaw) ?? .low },
            set: { thresholdRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Default Security Policy") {
                Toggle("Allow Sudo Commands", isOn: $allowSudo)
                    .tint(.orange)

                if allowSudo {
                    Label("Sudo access enables privileged operations. Use with caution.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker("Risk Threshold", selection: autoApproveThreshold) {
                    ForEach([RiskLevel.low, .medium, .high, .critical], id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }

                Text("Operations above this risk level will require extra caution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Blocked Commands") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("These commands are always blocked regardless of agent settings:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(AppConfig.defaultSecurityPolicy.blacklistedCommands, id: \.self) { cmd in
                        Text(cmd)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.red.opacity(0.08))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About Tab

struct AboutTab: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // App icon + name
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 80, height: 80)

                        Image(systemName: "cpu")
                            .font(.system(size: 40, weight: .light))
                            .foregroundColor(.white)
                    }

                    VStack(spacing: 4) {
                        Text("Lumi Agent")
                            .font(.title)
                            .fontWeight(.semibold)
                        Text("Version \(AppConfig.version) (\(AppConfig.buildNumber))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("AI-powered agentic platform for macOS.\nChat with agents, build groups, automate tasks.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.callout)

                Divider()

                // Feature grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    FeatureCell(icon: "brain", color: .green, title: "OpenAI", detail: "GPT-4o & more")
                    FeatureCell(icon: "sparkles", color: .purple, title: "Anthropic", detail: "Claude models")
                    FeatureCell(icon: "atom", color: .blue, title: "Gemini", detail: "Google AI models")
                    FeatureCell(icon: "cloud.fill", color: .cyan, title: "Aliyun Qwen", detail: "Qwen series models")
                    FeatureCell(icon: "server.rack", color: .orange, title: "Ollama", detail: "Run locally")
                    FeatureCell(icon: "bubble.left.and.bubble.right.fill", color: .teal, title: "Agent Space", detail: "Chat & groups")
                    FeatureCell(icon: "shield.fill", color: .indigo, title: "Security", detail: "Approval flows")
                }

                Divider()

                Text("Built with SwiftUI · macOS 14+")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(28)
        }
    }
}

struct FeatureCell: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Info Row (kept for compatibility)

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }
}
