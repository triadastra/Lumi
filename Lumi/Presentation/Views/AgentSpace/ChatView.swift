//
//  ChatView.swift
//  LumiAgent
//
//  Chat interface with @mention routing and streaming responses.
//

#if os(macOS)
import SwiftUI

// MARK: - Chat View

struct ChatView: View {
    let conversationId: UUID
    @EnvironmentObject var appState: AppState
    @State private var inputText = ""
    @State private var agentModeActive = false
    @State private var desktopControlEnabled = false
    @State private var voiceModeEnabled = false
    @State private var lastSpokenMessageId: UUID?
    @StateObject private var voiceManager = OpenAIVoiceManager()

    var conversation: Conversation? {
        appState.conversations.first { $0.id == conversationId }
    }

    var participants: [Agent] {
        guard let conv = conversation else { return [] }
        return appState.agents.filter { conv.participantIds.contains($0.id) }
    }

    var body: some View {
        Group {
            if let conv = conversation {
                VStack(spacing: 0) {
                    chatHeader(conv: conv)
                    Divider()
                    messagesArea(conv: conv)
                    Divider()
                    MessageInputView(
                        text: $inputText,
                        agents: participants,
                        voiceModeEnabled: $voiceModeEnabled,
                        isRecordingVoice: voiceManager.isRecording,
                        isProcessingVoice: voiceManager.isProcessing,
                        voiceError: voiceManager.lastError,
                        onVoiceAction: handleVoiceAction,
                        onSend: sendMessage
                    )
                }
                .onAppear { loadSettings(for: conv) }
                .onChange(of: agentModeActive) { saveSettings(for: conv) }
                .onChange(of: desktopControlEnabled) { saveSettings(for: conv) }
                .onChange(of: conv.messages.count) {
                    handleVoicePlayback(for: conv)
                }
            } else {
                EmptyDetailView(message: "Conversation not found")
            }
        }
        .navigationTitle("")
    }

    // MARK: - Header

    @ViewBuilder
    private func chatHeader(conv: Conversation) -> some View {
        HStack(spacing: 12) {
            participantAvatarStack
            VStack(alignment: .leading, spacing: 2) {
                Text(conv.displayTitle(agents: appState.agents))
                    .font(.headline)
                if conv.isGroup {
                    Text("\(participants.count) participants")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let agent = participants.first {
                    Text("\(agent.configuration.provider.rawValue) · \(agent.configuration.model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Agent Mode and Desktop Control — only available in DMs
            if !conv.isGroup {
                HStack(spacing: 8) {
                    AgentModeButton(isActive: $agentModeActive)
                    DesktopControlButton(
                        isEnabled: $desktopControlEnabled,
                        isAgentModeActive: agentModeActive
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var participantAvatarStack: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(participants.prefix(3).enumerated()), id: \.element.id) { index, agent in
                Circle()
                    .fill(agent.avatarColor)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text(agent.name.prefix(1))
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    )
                    .overlay(Circle().stroke(Color(.windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: CGFloat(index) * 20)
            }
        }
        .frame(width: CGFloat(min(participants.count, 3)) * 20 + 12, height: 32)
    }

    // MARK: - Messages

    @ViewBuilder
    private func messagesArea(conv: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if conv.messages.isEmpty {
                        emptyConversationHint(conv: conv)
                    } else {
                        ForEach(conv.messages) { msg in
                            MessageBubble(
                                message: msg,
                                agent: agentFor(msg),
                                allAgents: appState.agents
                            )
                            .id(msg.id)
                        }
                    }
                }
                .padding(.vertical, 16)
            }
            .onChange(of: conv.messages.count) {
                scrollToBottom(conv: conv, proxy: proxy)
            }
            .onAppear {
                scrollToBottom(conv: conv, proxy: proxy)
            }
        }
    }

    @ViewBuilder
    private func emptyConversationHint(conv: Conversation) -> some View {
        VStack(spacing: 12) {
            participantAvatarStack
            Text("Start a conversation with \(conv.displayTitle(agents: appState.agents))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if conv.isGroup {
                Text("Use @AgentName to direct a message to a specific participant.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 60)
        .padding(.horizontal, 40)
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        appState.sendMessage(text, in: conversationId, agentMode: agentModeActive, desktopControlEnabled: desktopControlEnabled)
    }

    private func agentFor(_ message: SpaceMessage) -> Agent? {
        guard let id = message.agentId else { return nil }
        return appState.agents.first { $0.id == id }
    }

    private func scrollToBottom(conv: Conversation, proxy: ScrollViewProxy) {
        guard let last = conv.messages.last else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func loadSettings(for conv: Conversation) {
        let agentModeKey = "agentMode_\(conv.id)"
        let desktopControlKey = "desktopControl_\(conv.id)"
        agentModeActive = UserDefaults.standard.bool(forKey: agentModeKey)
        desktopControlEnabled = UserDefaults.standard.bool(forKey: desktopControlKey)
    }

    private func saveSettings(for conv: Conversation) {
        let agentModeKey = "agentMode_\(conv.id)"
        let desktopControlKey = "desktopControl_\(conv.id)"
        UserDefaults.standard.set(agentModeActive, forKey: agentModeKey)
        UserDefaults.standard.set(desktopControlEnabled, forKey: desktopControlKey)
    }

    private func handleVoiceAction() {
        Task {
            guard !voiceManager.isRecording, !voiceManager.isProcessing else { return }
            do {
                let transcript = try await voiceManager.recordAndTranscribeAutomatically()
                guard !transcript.isEmpty else { return }
                inputText = transcript
                sendMessage()
            } catch {
                voiceManager.lastError = error.localizedDescription
            }
        }
    }

    private func handleVoicePlayback(for conv: Conversation) {
        guard voiceModeEnabled else { return }
        guard let message = conv.messages.last else { return }
        guard message.role == .agent else { return }
        guard !message.isStreaming else { return }
        guard message.id != lastSpokenMessageId else { return }

        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        lastSpokenMessageId = message.id
        Task {
            do {
                try await voiceManager.speak(text: content)
            } catch {
                voiceManager.lastError = error.localizedDescription
            }
        }
    }
}

// MARK: - Agent Mode Button

struct AgentModeButton: View {
    @Binding var isActive: Bool
    @State private var isPulsing = false

    var body: some View {
        Button {
            isActive.toggle()
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    if isActive {
                        Circle()
                            .fill(Color.red.opacity(0.3))
                            .frame(width: 18, height: 18)
                            .scaleEffect(isPulsing ? 1.4 : 1.0)
                            .opacity(isPulsing ? 0.0 : 0.6)
                            .animation(
                                .easeInOut(duration: 1.0).repeatForever(autoreverses: false),
                                value: isPulsing
                            )
                    }
                    Circle()
                        .fill(isActive ? Color.red : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                }
                Text("Agent Mode")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(isActive ? .red : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? Color.red.opacity(0.1) : Color.secondary.opacity(0.08))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isActive ? "Agent Mode active — agent can control your screen. Click to disable." : "Enable Agent Mode to give the agent screen control.")
        .onAppear { isPulsing = isActive }
        .onChange(of: isActive) { isPulsing = isActive }
    }
}

// MARK: - Desktop Control Button

struct DesktopControlButton: View {
    @Binding var isEnabled: Bool
    let isAgentModeActive: Bool

    var body: some View {
        Button {
            isEnabled.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 9, weight: .semibold))
                Text("Desktop")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(isEnabled ? .blue : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isEnabled ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.08))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isAgentModeActive)
        .opacity(isAgentModeActive ? 1.0 : 0.5)
        .help(
            !isAgentModeActive
                ? "Enable Agent Mode first to control desktop features."
                : (isEnabled ? "Desktop Control active — agent can use system tools. Click to disable." : "Enable Desktop Control to allow agent system tool usage.")
        )
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: SpaceMessage
    let agent: Agent?
    let allAgents: [Agent]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .agent {
                agentAvatar
                    .padding(.top, 18) // align with text below label

                VStack(alignment: .leading, spacing: 3) {
                    Text(agent?.name ?? "Agent")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    bubbleContent
                }
                Spacer(minLength: 80)
            } else {
                Spacer(minLength: 80)
                bubbleContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var agentAvatar: some View {
        let color = agent?.avatarColor ?? Color.gray
        Circle()
            .fill(color)
            .frame(width: 28, height: 28)
            .overlay(
                Text((agent?.name ?? "?").prefix(1))
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            )
    }

    @ViewBuilder
    private var bubbleContent: some View {
        let isUser = message.role == .user

        Group {
            if message.isStreaming && message.content.isEmpty {
                TypingIndicator()
            } else if isUser {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                MarkdownMessageView(text: message.content, agents: allAgents)
                    .textSelection(.enabled)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

struct TypingIndicator: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .scaleEffect(phase ? 1.0 : 0.5)
                    .opacity(phase ? 1.0 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: phase
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { phase = true }
    }
}

// MARK: - Message Input View

struct MessageInputView: View {
    @Binding var text: String
    let agents: [Agent]
    @Binding var voiceModeEnabled: Bool
    let isRecordingVoice: Bool
    let isProcessingVoice: Bool
    let voiceError: String?
    let onVoiceAction: () -> Void
    let onSend: () -> Void

    @State private var mentionQuery: String? = nil

    private var filteredAgents: [Agent] {
        guard let query = mentionQuery else { return [] }
        if query.isEmpty { return agents }
        return agents.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // @mention autocomplete popup
            if !filteredAgents.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredAgents) { agent in
                        Button {
                            insertMention(agent)
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(agent.avatarColor)
                                    .frame(width: 26, height: 26)
                                    .overlay(
                                        Text(agent.name.prefix(1))
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .foregroundColor(.white)
                                    )

                                VStack(alignment: .leading, spacing: 1) {
                                    Text("@\(agent.name)")
                                        .font(.callout)
                                        .fontWeight(.medium)
                                    Text(agent.configuration.model)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if agent.id != filteredAgents.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(.ultraThinMaterial)

                Divider()
            }

            // Input row
            HStack(alignment: .bottom, spacing: 10) {
                TextEditor(text: $text)
                    .frame(minHeight: 36, maxHeight: 100)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .onChange(of: text) {
                        updateMentionState()
                    }
                    .onKeyPress(.return) {
                        performSend()
                        return .handled
                    }

                Button {
                    voiceModeEnabled.toggle()
                } label: {
                    Image(systemName: voiceModeEnabled ? "waveform.circle.fill" : "waveform.circle")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(voiceModeEnabled ? Color.pink : Color.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Toggle vocal mode. When enabled, agent replies are spoken with OpenAI TTS.")
                .padding(.bottom, 6)

                Button(action: onVoiceAction) {
                    Image(systemName: isRecordingVoice ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(
                            isRecordingVoice
                                ? Color.red
                                : (isProcessingVoice ? Color.orange : Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isProcessingVoice)
                .help(
                    isRecordingVoice
                        ? "Listening... voice will auto-stop and send."
                        : "Start voice input (auto-stop + auto-send)."
                )
                .padding(.bottom, 4)

                Button(action: performSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if isRecordingVoice || isProcessingVoice || (voiceError?.isEmpty == false) {
                HStack(spacing: 6) {
                    Image(systemName: isRecordingVoice ? "waveform" : (isProcessingVoice ? "hourglass" : "exclamationmark.triangle.fill"))
                        .foregroundStyle(isRecordingVoice ? .red : (isProcessingVoice ? .orange : .orange))
                        .font(.caption)

                    Text(voiceStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
        .background(.ultraThinMaterial)
    }

    private var voiceStatusText: String {
        if isRecordingVoice { return "Listening... auto-stop and send enabled." }
        if isProcessingVoice { return "Transcribing with Whisper..." }
        return voiceError ?? ""
    }

    private func performSend() {
        guard canSend else { return }
        mentionQuery = nil
        onSend()
    }

    private func updateMentionState() {
        let parts = text.components(separatedBy: "@")
        if parts.count > 1, let last = parts.last, !last.contains(" "), !last.contains("\n") {
            mentionQuery = last
        } else {
            mentionQuery = nil
        }
    }

    private func insertMention(_ agent: Agent) {
        let parts = text.components(separatedBy: "@")
        guard parts.count > 1 else { return }
        let prefix = parts.dropLast().joined(separator: "@")
        text = prefix + "@\(agent.name) "
        mentionQuery = nil
    }
}
#endif
