//
//  MainWindow.swift
//  LumiAgent
//
//  Created by Lumi Agent on 2026-02-18.
//
//  Main window with three-column navigation
//

#if os(macOS)
import SwiftUI
import UserNotifications

// MARK: - Visual Effect View

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Main Window

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @StateObject var executionEngine = AgentExecutionEngine()

    var body: some View {
        NavigationSplitView {
            // Sidebar
            SidebarView()
                .frame(minWidth: 200)
        } content: {
            // Content (list view)
            ContentListView()
                .frame(minWidth: 300)
        } detail: {
            // Detail view
            DetailView()
                .frame(minWidth: 400)
        }
        .navigationTitle("Lumi Agent")
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .overlay(Color.black.opacity(0.08))
                .ignoresSafeArea()
        )
        .toolbar {
            if appState.selectedSidebarItem == .agentSpace {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await executionEngine.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!executionEngine.isExecuting)
                    .help("Stop the running agent process")
                    .keyboardShortcut(".", modifiers: .command)
                }
            }
        }
        .sheet(isPresented: $appState.showingNewAgent) {
            NewAgentView()
                .environmentObject(appState)
                .frame(minWidth: 500, minHeight: 400)
        }
        .environmentObject(executionEngine)
        .focusedSceneValue(\.executionEngine, executionEngine)
        .onChange(of: appState.remoteServer.pendingApprovals.count) { oldCount, newCount in
            if newCount > oldCount, let req = appState.remoteServer.pendingApprovals.last {
                // Auto-navigate to the Devices tab so the user sees the approval prompt
                appState.selectedSidebarItem = .devices
                appState.selectedDeviceId = nil
                // Bring the window to front
                NSApp.activate(ignoringOtherApps: true)
                NSApp.requestUserAttention(.criticalRequest)
                // Show a system notification via UNUserNotificationCenter
                let content = UNMutableNotificationContent()
                content.title = "Device Connection Request"
                content.body = "\(req.name) wants to connect to this Mac"
                content.sound = .default
                let request = UNNotificationRequest(identifier: req.id.uuidString, content: content, trigger: nil)
                Task {
                    try? await UNUserNotificationCenter.current().add(request)
                }
            }
        }
    }

    func executeCurrentAgent() async {
        guard let agentId = appState.selectedAgentId,
              let agent = appState.agents.first(where: { $0.id == agentId }) else {
            return
        }

        // TODO: Get user prompt from UI
        let userPrompt = "Hello, please help me with a task"

        do {
            try await executionEngine.execute(agent: agent, userPrompt: userPrompt)
        } catch {
            print("Execution error: \(error)")
        }
    }
}

// MARK: - Sidebar View

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(selection: $appState.selectedSidebarItem) {
            ForEach(SidebarItem.allCases) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.vertical, 6)
                    .tag(item)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Content List View

struct ContentListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.selectedSidebarItem {
            case .agents:
                AgentListView()
            case .agentSpace:
                AgentSpaceView()
            case .hotkeySpace:
                HotkeySpaceListView()
            case .health:
                HealthListView()
            case .history:
                ToolHistoryListView()
            case .automation:
                AutomationListView()
            case .devices:
                DevicesListView()
            case .settings:
                SettingsListView()
            }
        }
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Detail View

struct DetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var executionEngine: AgentExecutionEngine

    var body: some View {
        Group {
            switch appState.selectedSidebarItem {
            case .agents:
                if let agentId = appState.selectedAgentId,
                   let agent = appState.agents.first(where: { $0.id == agentId }) {
                    AgentDetailView(agent: agent)
                } else {
                    EmptyDetailView(message: "Select an agent")
                }
            case .agentSpace:
                if let convId = appState.selectedConversationId {
                    ChatView(conversationId: convId)
                } else {
                    EmptyDetailView(message: "Select or start a conversation")
                }
            case .hotkeySpace:
                HotkeySpaceDetailView()
            case .health:
                HealthDetailView()
            case .history:
                if let agentId = appState.selectedHistoryAgentId {
                    ToolHistoryDetailView(agentId: agentId)
                } else {
                    EmptyDetailView(message: "Select an agent to view tool history")
                }
            case .automation:
                AutomationDetailView()
            case .devices:
                DevicesDetailView()
            case .settings:
                SettingsDetailView()
            }
        }
    }
}

// MARK: - Empty Detail View

struct EmptyDetailView: View {
    let message: String

    var body: some View {
        VStack {
            Image(systemName: "sidebar.right")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Hotkey Space

struct HotkeySpaceListView: View {
    @EnvironmentObject var appState: AppState

    private var hotkeyConversation: Conversation? {
        appState.conversations.first { ($0.title ?? "") == "Hotkey Space" }
    }

    var body: some View {
        Group {
            if let conv = hotkeyConversation {
                List(selection: $appState.selectedConversationId) {
                    Label(conv.title ?? "Hotkey Space", systemImage: "keyboard")
                        .tag(conv.id)
                }
                .navigationTitle("Hotkey Space")
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("No hotkey conversation yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Use ⌥⌘E / ⌥⌘G / ⌥⌘R to create streamed hotkey actions.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct HotkeySpaceDetailView: View {
    @EnvironmentObject var appState: AppState

    private var hotkeyConversationId: UUID? {
        appState.conversations.first { ($0.title ?? "") == "Hotkey Space" }?.id
    }

    var body: some View {
        if let convId = hotkeyConversationId {
            ChatView(conversationId: convId)
        } else {
            EmptyDetailView(message: "Use a global hotkey to start Hotkey Space.")
        }
    }
}

// MARK: - Tool History List View

private struct AgentHistoryEntry: Identifiable {
    let id: UUID      // agentId
    let agent: Agent?
    let name: String
    let records: [ToolCallRecord]
}

struct ToolHistoryListView: View {
    @EnvironmentObject var appState: AppState

    /// Agents that have at least one tool call, sorted by most recent call
    private var activeAgents: [AgentHistoryEntry] {
        let grouped = Dictionary(grouping: appState.toolCallHistory, by: \.agentId)
        return grouped
            .map { (agentId, records) in
                AgentHistoryEntry(
                    id: agentId,
                    agent: appState.agents.first { $0.id == agentId },
                    name: records.first?.agentName ?? "Unknown Agent",
                    records: records
                )
            }
            .sorted { ($0.records.first?.timestamp ?? .distantPast) > ($1.records.first?.timestamp ?? .distantPast) }
    }

    var body: some View {
        if appState.toolCallHistory.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No tool calls yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Tool calls made by agents will appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $appState.selectedHistoryAgentId) {
                ForEach(activeAgents) { entry in
                    AgentHistoryRow(entry: entry)
                        .tag(entry.id)
                }
            }
            .navigationTitle("History")
        }
    }
}

private struct AgentHistoryRow: View {
    let entry: AgentHistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(entry.agent?.avatarColor ?? Color.gray)
                .frame(width: 32, height: 32)
                .overlay(
                    Text(entry.name.prefix(1))
                        .font(.caption).fontWeight(.bold).foregroundColor(.white)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.callout).fontWeight(.medium)
                if let latest = entry.records.first {
                    Text(latest.toolName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(entry.records.count)")
                    .font(.caption2).fontWeight(.semibold)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
                if let latest = entry.records.first {
                    Text(latest.timestamp, style: .relative)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Tool History Detail View

struct ToolHistoryDetailView: View {
    let agentId: UUID
    @EnvironmentObject var appState: AppState

    private var agent: Agent? {
        appState.agents.first { $0.id == agentId }
    }

    private var records: [ToolCallRecord] {
        appState.toolCallHistory.filter { $0.agentId == agentId }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Circle()
                    .fill(agent?.avatarColor ?? .gray)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text((records.first?.agentName ?? "?").prefix(1))
                            .font(.callout)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(records.first?.agentName ?? "Agent")
                        .font(.headline)
                    Text("\(records.count) tool call\(records.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    appState.toolCallHistory.removeAll { $0.agentId == agentId }
                    appState.selectedHistoryAgentId = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(records) { record in
                        ToolCallRow(record: record)
                        Divider().padding(.leading, 52)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Tool Call Row

struct ToolCallRow: View {
    let record: ToolCallRecord
    @State private var expanded = false

    private var toolIcon: String {
        switch record.toolName {
        case let n where n.contains("file") || n.contains("read") || n.contains("write")
                      || n.contains("directory") || n.contains("delete") || n.contains("copy")
                      || n.contains("move") || n.contains("append"): return "doc.fill"
        case let n where n.contains("command") || n.contains("execute"): return "terminal.fill"
        case let n where n.contains("search") || n.contains("web"): return "magnifyingglass"
        case let n where n.contains("mouse") || n.contains("click") || n.contains("scroll")
                      || n.contains("type") || n.contains("key") || n.contains("screen")
                      || n.contains("applescript"): return "cursorarrow.motionlines"
        case let n where n.contains("git"): return "arrow.triangle.branch"
        case let n where n.contains("http") || n.contains("url") || n.contains("fetch"): return "network"
        case let n where n.contains("screenshot"): return "camera.fill"
        case let n where n.contains("clipboard"): return "clipboard.fill"
        case let n where n.contains("memory"): return "memorychip"
        case let n where n.contains("python") || n.contains("node"): return "chevron.left.forwardslash.chevron.right"
        case "update_self": return "person.crop.circle.badge.checkmark"
        default: return "wrench.fill"
        }
    }

    private var argsSummary: String {
        record.arguments
            .sorted { $0.key < $1.key }
            .prefix(2)
            .map { "\($0.key): \($0.value.prefix(40))" }
            .joined(separator: "  ·  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    // Tool icon
                    ZStack {
                        Circle()
                            .fill(record.success ? Color.accentColor.opacity(0.12) : Color.red.opacity(0.1))
                            .frame(width: 32, height: 32)
                        Image(systemName: toolIcon)
                            .font(.caption)
                            .foregroundStyle(record.success ? Color.accentColor : Color.red)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(record.toolName)
                                .font(.callout)
                                .fontWeight(.medium)
                            Spacer()
                            Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(record.success ? .green : .red)
                            Text(record.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if !argsSummary.isEmpty {
                            Text(argsSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !record.arguments.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Arguments")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            ForEach(record.arguments.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(k)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 100, alignment: .leading)
                                    Text(v)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Result")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(record.result)
                            .font(.caption.monospaced())
                            .foregroundStyle(record.success ? Color.primary : Color.red)
                            .textSelection(.enabled)
                            .lineLimit(10)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.05))
            }
        }
    }
}

// MARK: - Automation Views

struct AutomationListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.automations.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No automations yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Create an automation to let agents act on triggers automatically.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("New Automation") { appState.createAutomation() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.automations, selection: $appState.selectedAutomationId) { rule in
                    AutomationRow(rule: rule)
                        .tag(rule.id)
                }
                .navigationTitle("Automations")
                .toolbar {
                    ToolbarItem {
                        Button { appState.createAutomation() } label: {
                            Label("New", systemImage: "plus")
                        }
                    }
                }
            }
        }
    }
}

private struct AutomationRow: View {
    let rule: AutomationRule

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(rule.isEnabled ? 0.15 : 0.05))
                    .frame(width: 32, height: 32)
                Image(systemName: rule.trigger.icon)
                    .font(.caption)
                    .foregroundStyle(rule.isEnabled ? Color.accentColor : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.title)
                    .font(.callout).fontWeight(.medium)
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                Text(rule.trigger.displayName)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !rule.isEnabled {
                Text("Off")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

struct AutomationDetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let id = appState.selectedAutomationId,
           let index = appState.automations.firstIndex(where: { $0.id == id }) {
            AutomationEditorView(
                rule: $appState.automations[index],
                onDelete: {
                    appState.automations.remove(at: index)
                    appState.selectedAutomationId = nil
                },
                onRun: { appState.runAutomation(id: id) }
            )
        } else {
            EmptyDetailView(message: "Select an automation")
        }
    }
}

private struct AutomationEditorView: View {
    @Binding var rule: AutomationRule
    let onDelete: () -> Void
    let onRun: () -> Void
    @EnvironmentObject var appState: AppState

    // Local state for trigger picker sub-fields
    @State private var triggerType: TriggerType = .manual
    @State private var schedHour: Int = 9
    @State private var schedMinute: Int = 0
    @State private var schedRepeat: RepeatSchedule = .daily
    @State private var appName: String = ""
    @State private var deviceName: String = ""
    @State private var ssid: String = ""

    enum TriggerType: String, CaseIterable, Identifiable {
        case manual              = "Manual"
        case scheduled           = "Scheduled"
        case appLaunched         = "App Launched"
        case appQuit             = "App Quit"
        case bluetoothConnected  = "Bluetooth Connected"
        case bluetoothDisconnected = "Bluetooth Disconnected"
        case wifiConnected       = "Wi-Fi Connected"
        case powerPlugged        = "Power Plugged In"
        case powerUnplugged      = "Power Unplugged"
        case screenUnlocked      = "Screen Unlocked"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Title
                TextField("Automation title", text: $rule.title)
                    .font(.title2).fontWeight(.semibold)
                    .textFieldStyle(.plain)

                Divider()

                // Notes (freeform, Apple-Notes style)
                VStack(alignment: .leading, spacing: 6) {
                    Text("TASK")
                        .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                    ZStack(alignment: .topLeading) {
                        if rule.notes.isEmpty {
                            Text("Describe what the agent should do…\nExample: Search for today's top tech news and write a summary to my Desktop.")
                                .font(.body).foregroundStyle(.tertiary)
                                .padding(.horizontal, 10).padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $rule.notes)
                            .font(.body)
                            .frame(minHeight: 180)
                            .padding(4)
                            .scrollContentBackground(.hidden)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.07))
                    )
                }

                Divider()

                // Trigger picker
                VStack(alignment: .leading, spacing: 10) {
                    Text("TRIGGER")
                        .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)

                    Picker("Trigger", selection: $triggerType) {
                        ForEach(TriggerType.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: triggerType) { _, _ in syncTriggerFromUI() }

                    // Context-specific fields
                    switch triggerType {
                    case .scheduled:
                        HStack(spacing: 16) {
                            Stepper("Hour: \(schedHour)", value: $schedHour, in: 0...23)
                                .onChange(of: schedHour) { _, _ in syncTriggerFromUI() }
                            Stepper("Min: \(String(format: "%02d", schedMinute))",
                                    value: $schedMinute, in: 0...59, step: 5)
                                .onChange(of: schedMinute) { _, _ in syncTriggerFromUI() }
                        }
                        Picker("Repeat", selection: $schedRepeat) {
                            ForEach(RepeatSchedule.allCases) { s in
                                Text(s.rawValue).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: schedRepeat) { _, _ in syncTriggerFromUI() }

                    case .appLaunched, .appQuit:
                        TextField("App name (e.g. Safari)", text: $appName)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: appName) { _, _ in syncTriggerFromUI() }

                    case .bluetoothConnected, .bluetoothDisconnected:
                        TextField("Device name (e.g. AirPods Pro)", text: $deviceName)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: deviceName) { _, _ in syncTriggerFromUI() }

                    case .wifiConnected:
                        TextField("Network name (SSID)", text: $ssid)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: ssid) { _, _ in syncTriggerFromUI() }

                    default:
                        EmptyView()
                    }
                }

                Divider()

                // Agent picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("AGENT")
                        .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                    Picker("Agent", selection: $rule.agentId) {
                        Text("None").tag(Optional<UUID>.none)
                        ForEach(appState.agents) { agent in
                            Text(agent.name).tag(Optional(agent.id))
                        }
                    }
                    .pickerStyle(.menu)
                }

                Divider()

                // Enable + Run + Delete
                HStack {
                    Toggle("Enabled", isOn: $rule.isEnabled)
                        .toggleStyle(.switch)
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.borderless).foregroundStyle(.red)
                    Button(action: onRun) {
                        Label("Run Now", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                    Text("Always runs in Agent Mode")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let last = rule.lastRunAt {
                    Text("Last run: \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(20)
        }
        .onAppear { syncUIFromTrigger() }
    }

    private func syncUIFromTrigger() {
        switch rule.trigger {
        case .manual:
            triggerType = .manual
        case .scheduled(let h, let m, let s):
            triggerType = .scheduled; schedHour = h; schedMinute = m; schedRepeat = s
        case .appLaunched(let n):
            triggerType = .appLaunched; appName = n
        case .appQuit(let n):
            triggerType = .appQuit; appName = n
        case .bluetoothConnected(let d):
            triggerType = .bluetoothConnected; deviceName = d
        case .bluetoothDisconnected(let d):
            triggerType = .bluetoothDisconnected; deviceName = d
        case .wifiConnected(let s):
            triggerType = .wifiConnected; ssid = s
        case .powerPlugged:
            triggerType = .powerPlugged
        case .powerUnplugged:
            triggerType = .powerUnplugged
        case .screenUnlocked:
            triggerType = .screenUnlocked
        }
    }

    private func syncTriggerFromUI() {
        switch triggerType {
        case .manual:              rule.trigger = .manual
        case .scheduled:           rule.trigger = .scheduled(hour: schedHour, minute: schedMinute, schedule: schedRepeat)
        case .appLaunched:         rule.trigger = .appLaunched(name: appName)
        case .appQuit:             rule.trigger = .appQuit(name: appName)
        case .bluetoothConnected:  rule.trigger = .bluetoothConnected(deviceName: deviceName)
        case .bluetoothDisconnected: rule.trigger = .bluetoothDisconnected(deviceName: deviceName)
        case .wifiConnected:       rule.trigger = .wifiConnected(ssid: ssid)
        case .powerPlugged:        rule.trigger = .powerPlugged
        case .powerUnplugged:      rule.trigger = .powerUnplugged
        case .screenUnlocked:      rule.trigger = .screenUnlocked
        }
    }
}

// MARK: - Settings List + Detail Views

struct SettingsListView: View {
    @EnvironmentObject var appState: AppState

    private let sections: [(title: String, icon: String, id: String)] = [
        ("Account", "person.crop.circle", "account"),
        ("API Keys", "key.fill", "apiKeys"),
        ("Permissions", "lock.shield.fill", "permissions"),
        ("Integrations", "slider.horizontal.3", "integrations"),
        ("Hotkeys", "keyboard", "hotkeys"),
        ("Security", "shield.fill", "security"),
        ("About", "info.circle.fill", "about"),
    ]

    var body: some View {
        List(sections, id: \.id, selection: $appState.selectedSettingsSection) { section in
            Label(section.title, systemImage: section.icon)
                .tag(section.id)
        }
        .navigationTitle("Settings")
    }
}

struct SettingsDetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        switch appState.selectedSettingsSection {
        case "account":
            AccountTab()
        case "apiKeys":
            APIKeysTab()
        case "permissions":
            PermissionsTab()
        case "integrations":
            IntegrationsTab()
        case "hotkeys":
            HotkeysTab()
        case "security":
            SecurityTab()
        case "about":
            AboutTab()
        default:
            EmptyDetailView(message: "Select a setting")
        }
    }
}

// MARK: - New Agent View

struct NewAgentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var name: String = ""
    @State private var provider: AIProvider = .ollama
    @State private var model: String = AppConfig.defaultModels[.ollama] ?? ""
    @State private var availableModels: [String] = []
    @State private var loadingModels = false
    @State private var ollamaUnreachable = false
    @FocusState private var focusedField: Field?

    enum Field { case name }

    var body: some View {
        Form {
            Section("Agent Details") {
                TextField("Name", text: $name)
                    .focused($focusedField, equals: .name)

                Picker("Provider", selection: $provider) {
                    ForEach(AIProvider.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .onChange(of: provider) {
                    model = AppConfig.defaultModels[provider] ?? ""
                    ollamaUnreachable = false
                    fetchModels()
                }

                HStack(spacing: 8) {
                    if loadingModels {
                        TextField("Model", text: $model)
                            .disabled(true)
                        ProgressView().scaleEffect(0.7)
                    } else if !availableModels.isEmpty {
                        Picker("Model", selection: $model) {
                            ForEach(availableModels, id: \.self) { m in
                                Text(m).tag(m)
                            }
                        }
                        if provider == .ollama {
                            Button {
                                fetchModels()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Refresh models from Ollama")
                        }
                    } else if provider == .ollama && ollamaUnreachable {
                        TextField("Model", text: $model)
                        Button {
                            fetchModels()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.orange)
                        .help("Ollama unreachable — tap to retry")
                    } else {
                        TextField("Model", text: $model)
                    }
                }
                
                if provider == .ollama && ollamaUnreachable && !loadingModels {
                    HStack {
                        Text("Ollama server not reachable.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        
                        Button {
                            AIProviderRepository().launchOllama()
                            // Small delay to let it start, then retry
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                fetchModels()
                            }
                        } label: {
                            Text("Launch Ollama")
                                .font(.caption).fontWeight(.bold)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.orange)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Create") {
                    createAgent()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || (provider == .ollama && availableModels.isEmpty && model.isEmpty))
            }
            .padding()
        }
        .padding()
        .frame(width: 500, height: 300)
        .onAppear {
            focusedField = .name
            fetchModels()
        }
    }

    private func fetchModels() {
        let currentProvider = provider
        guard currentProvider == .ollama else {
            availableModels = currentProvider.defaultModels
            ollamaUnreachable = false
            return
        }
        
        // For Ollama: always fetch live — never show preset list
        availableModels = []
        ollamaUnreachable = false
        loadingModels = true
        
        Task {
            let repo = AIProviderRepository()
            do {
                let live = try await repo.getAvailableModels(provider: .ollama)
                await MainActor.run {
                    self.availableModels = live
                    self.ollamaUnreachable = live.isEmpty
                    if !live.isEmpty && !live.contains(model) {
                        self.model = live.first ?? model
                    }
                    self.loadingModels = false
                }
            } catch {
                await MainActor.run {
                    self.ollamaUnreachable = true
                    self.loadingModels = false
                }
            }
        }
    }

    private func createAgent() {
        let agent = Agent(
            name: name,
            configuration: AgentConfiguration(
                provider: provider,
                model: model
            )
        )
        appState.agents.append(agent)

        // Save to database
        Task {
            let repo = AgentRepository()
            try? await repo.create(agent)
        }
    }
}
#endif
