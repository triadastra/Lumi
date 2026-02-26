//
//  iOSMainView.swift
//  LumiAgent
//
//  A polished, feature-complete iOS interface for LumiAgent.
//  Acts as a mobile command center for your AI agents and remote Mac control.
//

#if os(iOS)
import SwiftUI

// MARK: - Main Interface

struct iOSMainView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // 1. Agents List
            NavigationStack {
                iOSAgentListView()
            }
            .tabItem {
                Label("Agents", systemImage: "cpu")
            }
            .tag(0)

            // 2. Chat Space
            NavigationStack {
                iOSConversationsView()
            }
            .tabItem {
                Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .tag(1)

            // 3. Remote Control
            NavigationStack {
                iOSRemoteControlView()
            }
            .tabItem {
                Label("Remote", systemImage: "desktopcomputer")
            }
            .tag(2)

            // 4. Settings
            NavigationStack {
                iOSSettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(3)
        }
        .tint(.blue)
    }
}

// MARK: - Agent List

struct iOSAgentListView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingNewAgent = false
    @State private var searchText = ""

    var filteredAgents: [Agent] {
        if searchText.isEmpty { return appState.agents }
        return appState.agents.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if appState.agents.isEmpty {
                ContentUnavailableView {
                    Label("No Agents Yet", systemImage: "cpu")
                } description: {
                    Text("Create an AI agent to start automating tasks or chatting.")
                } actions: {
                    Button("Create First Agent") {
                        showingNewAgent = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else {
                List {
                    Section {
                        ForEach(filteredAgents) { agent in
                            NavigationLink(destination: iOSAgentDetailView(agent: agent)) {
                                HStack(spacing: 16) {
                                    Circle()
                                        .fill(agent.avatarColor.gradient)
                                        .frame(width: 50, height: 50)
                                        .overlay(
                                            Text(agent.name.prefix(1))
                                                .font(.title3)
                                                .fontWeight(.bold)
                                                .foregroundColor(.white)
                                        )
                                        .shadow(color: agent.avatarColor.opacity(0.3), radius: 4, x: 0, y: 2)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(agent.name)
                                            .font(.headline)
                                        Text("\(agent.configuration.provider.rawValue) · \(agent.configuration.model)")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if appState.isDefaultAgent(agent.id) {
                                        Image(systemName: "star.fill")
                                            .font(.caption)
                                            .foregroundStyle(.yellow)
                                            .padding(6)
                                            .background(Color.yellow.opacity(0.1))
                                            .clipShape(Circle())
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                        }
                        .onDelete(perform: deleteAgents)
                    } header: {
                        Text("My Agents")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                            .textCase(nil)
                    } footer: {
                        Text("The starred agent is your primary assistant for shortcuts.")
                            .padding(.top, 4)
                    }
                }
                .listStyle(.insetGrouped)
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search agents")
            }
        }
        .navigationTitle("Lumi Agents")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewAgent = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                }
            }
        }
        .sheet(isPresented: $showingNewAgent) {
            iOSNewAgentView()
        }
    }

    private func deleteAgents(at offsets: IndexSet) {
        for index in offsets {
            let id = filteredAgents[index].id
            appState.deleteAgent(id: id)
        }
    }
}

// MARK: - Agent Detail

struct iOSAgentDetailView: View {
    let agent: Agent
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    Circle()
                        .fill(agent.avatarColor.gradient)
                        .frame(width: 80, height: 80)
                        .overlay(
                            Text(agent.name.prefix(1))
                                .font(.system(size: 32, weight: .black))
                                .foregroundColor(.white)
                        )
                        .shadow(color: agent.avatarColor.opacity(0.4), radius: 8, x: 0, y: 4)

                    VStack(spacing: 4) {
                        Text(agent.name)
                            .font(.title.bold())
                        Text("Powered by \(agent.configuration.provider.rawValue)")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .listRowBackground(Color.clear)

            Section {
                HStack {
                    Button {
                        appState.createDM(agentId: agent.id)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "message.fill")
                                .font(.title2)
                            Text("Message")
                                .font(.caption.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)

                    Button {
                        if appState.isDefaultAgent(agent.id) {
                            appState.setDefaultAgent(nil)
                        } else {
                            appState.setDefaultAgent(agent.id)
                        }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: appState.isDefaultAgent(agent.id) ? "star.fill" : "star")
                                .font(.title2)
                            Text(appState.isDefaultAgent(agent.id) ? "Primary" : "Set Primary")
                                .font(.caption.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(appState.isDefaultAgent(agent.id) ? Color.yellow.opacity(0.1) : Color.gray.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appState.isDefaultAgent(agent.id) ? .yellow : .primary)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))

            Section("Settings") {
                LabeledContent {
                    Text(agent.configuration.model)
                        .foregroundStyle(.primary)
                } label: {
                    Label("Model", systemImage: "cube.fill")
                        .foregroundStyle(.secondary)
                }
                
                LabeledContent {
                    Text(String(format: "%.2f", agent.configuration.temperature ?? 0.7))
                        .foregroundStyle(.primary)
                } label: {
                    Label("Temperature", systemImage: "thermometer.medium")
                        .foregroundStyle(.secondary)
                }
            }

            if let prompt = agent.configuration.systemPrompt, !prompt.isEmpty {
                Section("System Prompt") {
                    Text(prompt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .padding(.vertical, 4)
                }
            }

            Section {
                Button(role: .destructive) {
                    appState.deleteAgent(id: agent.id)
                    dismiss()
                } label: {
                    Label("Delete Agent", systemImage: "trash")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Platform Constraints", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("Advanced tools like terminal commands, local file system mastery, and real-time screen control are only available on macOS. This mobile agent can chat and use web-based research tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Agent Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Conversations List

struct iOSConversationsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingNewChat = false

    var body: some View {
        Group {
            if appState.conversations.isEmpty {
                ContentUnavailableView {
                    Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start a new chat with one of your agents.")
                } actions: {
                    Button("Start First Chat") {
                        showingNewChat = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else {
                List {
                    ForEach(appState.conversations) { conversation in
                        NavigationLink(destination: iOSChatView(conversationId: conversation.id)) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(conversation.title ?? "Conversation")
                                        .font(.headline)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(conversation.updatedAt, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }

                                if let lastMsg = conversation.messages.last {
                                    Text(lastMsg.content)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .lineSpacing(2)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .onDelete(perform: deleteConversations)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Chat Space")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewChat = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.title3)
                }
            }
        }
        .sheet(isPresented: $showingNewChat) {
            iOSNewConversationView()
        }
    }

    private func deleteConversations(at offsets: IndexSet) {
        for index in offsets {
            let id = appState.conversations[index].id
            appState.deleteConversation(id: id)
        }
    }
}

// MARK: - Chat Interface

private let chatBottomID = "chatBottom"

struct iOSChatView: View {
    let conversationId: UUID
    @EnvironmentObject var appState: AppState
    @State private var inputText = ""

    var conversation: Conversation? {
        appState.conversations.first { $0.id == conversationId }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 20) {
                        if let conv = conversation {
                            if conv.messages.isEmpty {
                                VStack(spacing: 16) {
                                    Image(systemName: "bubble.left.and.bubble.right")
                                        .font(.system(size: 60))
                                        .foregroundStyle(.tertiary)
                                    Text("Start the conversation")
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 100)
                            } else {
                                ForEach(conv.messages) { message in
                                    iOSMessageBubble(message: message)
                                        .id(message.id)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id(chatBottomID)
                    }
                    .padding(.horizontal)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                }
                .onChange(of: conversation?.messages.count) {
                    withAnimation {
                        proxy.scrollTo(chatBottomID, anchor: .bottom)
                    }
                }
                .onChange(of: (conversation?.messages.last?.content.count ?? 0)) {
                    proxy.scrollTo(chatBottomID, anchor: .bottom)
                }
                .onAppear {
                    proxy.scrollTo(chatBottomID, anchor: .bottom)
                }
            }

            Divider()

            // Input Area
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    // Future: Add Image attachment for vision
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.blue)
                        .frame(width: 32, height: 32)
                        .background(Color.blue.opacity(0.14))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("iMessage", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .submitLabel(.send)
                        .onSubmit {
                            sendMessage()
                        }
                        .padding(.leading, 2)
                        .padding(.vertical, 6)

                    if canSend {
                        Button {
                            sendMessage()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.blue)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                    } label: {
                        EmptyView()
                    }
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(Color.black.opacity(0.04), lineWidth: 1)
                )
                .animation(.easeInOut(duration: 0.18), value: canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(uiColor: .systemBackground))
        }
        .navigationTitle(conversation?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if appState.isAgentControllingScreen {
                ToolbarItem(placement: .topBarTrailing) {
                    Label("Active on Mac", systemImage: "desktopcomputer")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        appState.sendMessage(text, in: conversationId, agentMode: false)
        inputText = ""
    }
}

struct iOSMessageBubble: View {
    let message: SpaceMessage
    @EnvironmentObject var appState: AppState

    var agent: Agent? {
        guard let id = message.agentId else { return nil }
        return appState.agents.first { $0.id == id }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if message.role == .agent {
                Circle()
                    .fill(agent?.avatarColor.gradient ?? Color.purple.gradient)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text(agent?.name.prefix(1) ?? "L")
                            .font(.system(size: 14, weight: .black))
                            .foregroundColor(.white)
                    )
                    .shadow(radius: 1)
            } else {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .agent {
                    Text(agent?.name ?? "Lumi Agent")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }

                Text(message.content)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(message.role == .user ? Color.blue.gradient : Color(uiColor: .secondarySystemBackground).gradient)
                    .foregroundColor(message.role == .user ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)

                if message.isStreaming {
                    HStack(spacing: 4) {
                        Circle().fill(.secondary).frame(width: 5, height: 5)
                        Circle().fill(.secondary).frame(width: 5, height: 5)
                        Circle().fill(.secondary).frame(width: 5, height: 5)
                    }
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .opacity(0.6)
                }
            }

            if message.role == .user {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.blue)
                    )
            } else {
                Spacer(minLength: 60)
            }
        }
    }
}

// MARK: - Remote Control

struct iOSRemoteControlView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        IOSRealRemoteControlView()
    }
}

// MARK: - Settings

struct iOSSettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("settings.syncHealth") private var syncHealth = false
    @State private var healthError: String?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    iOSAPIKeysView()
                } label: {
                    Label("Configure AI Providers", systemImage: "key.fill")
                        .foregroundStyle(.blue)
                }
            } header: {
                Text("Connection")
            }

            Section {
                Toggle(isOn: $syncHealth) {
                    Label("Sync Apple Health", systemImage: "heart.fill")
                }
                .tint(.red)
                .onChange(of: syncHealth) {
                    if syncHealth {
                        Task {
                            do {
                                try await IOSHealthKitManager.shared.requestAuthorization()
                                healthError = nil
                            } catch {
                                healthError = error.localizedDescription
                                syncHealth = false
                            }
                        }
                    }
                }

                if syncHealth {
                    Button {
                        Task {
                            do {
                                try await IOSHealthKitManager.shared.requestAuthorization()
                                healthError = nil
                            } catch {
                                healthError = error.localizedDescription
                            }
                        }
                    } label: {
                        Text("Update Health Permissions")
                            .font(.footnote)
                    }
                }

                if let healthError {
                    Text(healthError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("When enabled, your steps, heart rate, sleep, and other health metrics will sync to your Mac for AI analysis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Health & Wellness")
            }

            Section {
                HStack {
                    Label("Version", systemImage: "info.circle")
                    Spacer()
                    Text(AppConfig.version)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Build", systemImage: "hammer.fill")
                    Spacer()
                    Text(AppConfig.buildNumber)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("About")
            }

            Section {
                Link(destination: URL(string: "https://github.com/Lumicake/Agent-Lumi")!) {
                    Label("GitHub Repository", systemImage: "link")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
    }
}

struct iOSAPIKeysView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("settings.ollamaURL") private var ollamaURL = AppConfig.defaultOllamaURL

    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var geminiKey = ""
    @State private var qwenKey = ""

    var body: some View {
        Form {
            Section {
                SecureField("sk-...", text: $openAIKey)
                Button("Save OpenAI Key") { saveKey(openAIKey, for: .openai) }
                    .disabled(openAIKey.isEmpty)
            } header: {
                Label("OpenAI", systemImage: "sparkles")
            }

            Section {
                SecureField("sk-ant-...", text: $anthropicKey)
                Button("Save Anthropic Key") { saveKey(anthropicKey, for: .anthropic) }
                    .disabled(anthropicKey.isEmpty)
            } header: {
                Label("Anthropic", systemImage: "bird")
            }

            Section {
                SecureField("Key...", text: $geminiKey)
                Button("Save Gemini Key") { saveKey(geminiKey, for: .gemini) }
                    .disabled(geminiKey.isEmpty)
            } header: {
                Label("Google Gemini", systemImage: "moon.stars.fill")
            }

            Section {
                SecureField("sk-...", text: $qwenKey)
                Button("Save Aliyun Qwen Key") { saveKey(qwenKey, for: .qwen) }
                    .disabled(qwenKey.isEmpty)
            } header: {
                Label("Aliyun Qwen", systemImage: "cloud.fill")
            }

            Section {
                TextField("http://127.0.0.1:11434", text: $ollamaURL)
                Text("Ensure your local server is reachable from this device. Use your Mac's IP address if running on device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Ollama (Local AI)", systemImage: "laptopcomputer")
            }
        }
        .navigationTitle("API Keys")
    }

    private func saveKey(_ key: String, for provider: AIProvider) {
        let repo = AIProviderRepository()
        try? repo.setAPIKey(key, for: provider)
    }
}

// MARK: - New Agent / Conversation (Sheets)

struct iOSNewAgentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var name = ""
    @State private var provider: AIProvider = .openai
    @State private var model = ""
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent Identity") {
                    TextField("Agent Name", text: $name)
                }

                Section("Intelligence") {
                    Picker("Provider", selection: $provider) {
                        ForEach(AIProvider.allCases, id: \.self) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .onChange(of: provider) {
                        model = provider.defaultModels.first ?? ""
                    }

                    TextField("Model Name", text: $model)
                }

                Section("Personality & Instructions") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle("New Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createAgent()
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .disabled(name.isEmpty || model.isEmpty)
                }
            }
        }
        .onAppear {
            if model.isEmpty {
                model = provider.defaultModels.first ?? ""
            }
        }
    }

    private func createAgent() {
        let agent = Agent(
            name: name,
            configuration: AgentConfiguration(
                provider: provider,
                model: model,
                systemPrompt: prompt.isEmpty ? nil : prompt
            )
        )
        appState.agents.append(agent)
        Task {
            let repo = AgentRepository()
            try? await repo.update(agent)
            NotificationCenter.default.post(
                name: Notification.Name("lumi.localDataChanged"),
                object: "agents.json"
            )
        }
    }
}

struct iOSNewConversationView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var selectedAgentIds: Set<UUID> = []
    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Group Info") {
                    TextField("Title (Optional)", text: $title)
                }

                Section("Select Participants") {
                    if appState.agents.isEmpty {
                        Text("No agents available. Create one first.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.agents) { agent in
                            Toggle(isOn: Binding(
                                get: { selectedAgentIds.contains(agent.id) },
                                set: { isOn in
                                    if isOn { selectedAgentIds.insert(agent.id) }
                                    else { selectedAgentIds.remove(agent.id) }
                                }
                            )) {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(agent.avatarColor.gradient)
                                        .frame(width: 32, height: 32)
                                        .overlay(
                                            Text(agent.name.prefix(1))
                                                .font(.caption.bold())
                                                .foregroundColor(.white)
                                        )
                                    Text(agent.name)
                                        .font(.body)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        createConversation()
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .disabled(selectedAgentIds.isEmpty)
                }
            }
        }
    }

    private func createConversation() {
        let agentIds = Array(selectedAgentIds)
        if agentIds.count == 1 {
            appState.createDM(agentId: agentIds[0])
        } else {
            appState.createGroup(agentIds: agentIds, title: title.isEmpty ? nil : title)
        }
    }
}

#endif
