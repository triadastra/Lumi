//
//  QuickActionPanelController.swift
//  LumiAgent
//
//  A glass morphism Quick Actions panel (⌥⌘L) centered on screen.
//  On action click, displays agent reply in a glass bubble at upper right corner.
//

import Combine

#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Panel subclass

/// Borderless panel that can become key so UI elements receive keyboard input.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Quick Action Types

// MARK: - App Detection

func isIWorkApp() -> Bool {
    let iworkBundleIds = [
        "com.apple.iWork.Pages",
        "com.apple.iWork.Numbers",
        "com.apple.iWork.Keynote",
        "com.apple.creativestudio.keynote",  // New Keynote from Apple Creator Studio
        "com.apple.Motion",
        "com.apple.finalcutpro",
        "com.apple.logicpro",
        "com.pixelmator.pixelmator-pro",
        "com.apple.compressor",
        "com.apple.MainStage",
    ]

    let workspace = NSWorkspace.shared
    if let frontmost = workspace.frontmostApplication {
        let bundleId = frontmost.bundleIdentifier ?? ""
        return iworkBundleIds.contains(bundleId)
    }
    return false
}

enum QuickActionType: String, CaseIterable {
    case analyzePage
    case thinkAndWrite
    case writeNew
    case cleanDesktop

    var icon: String {
        switch self {
        case .analyzePage:   return "eye.fill"
        case .thinkAndWrite: return "pencil.line"
        case .writeNew:      return "doc.badge.plus"
        case .cleanDesktop:  return "sparkles.rectangle.stack.fill"
        }
    }

    var label: String {
        switch self {
        case .analyzePage:   return "Analyze"
        case .thinkAndWrite: return "Write"
        case .writeNew:      return "New"
        case .cleanDesktop:  return "Clean Desktop"
        }
    }

    var prompt: String {
        switch self {
        case .analyzePage:
            return "Analyze the content and structure of what's currently displayed on the screen."
        case .thinkAndWrite:
            return "Review the content and proactively use tools (like AppleScript) to write or improve it."
        case .writeNew:
            return "Create and add new content that would be appropriate for this document."
        case .cleanDesktop:
            return "Safely organize loose files on the Desktop without deleting or moving important project folders."
        }
    }

    static var visibleCases: [QuickActionType] {
        // Only show "Write New" for iWork apps
        isIWorkApp() ? [.analyzePage, .thinkAndWrite, .writeNew, .cleanDesktop] : [.analyzePage, .thinkAndWrite, .cleanDesktop]
    }
}

// MARK: - Quick Action Panel Controller

final class QuickActionPanelController: NSObject {
    static let shared = QuickActionPanelController()

    private var panel: KeyablePanel?
    private var onAction: ((QuickActionType) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(onAction: @escaping (QuickActionType) -> Void) {
        guard panel == nil else { return }
        self.onAction = onAction
        createPanel()
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
            self?.onAction = nil
        }
    }

    func toggle(onAction: @escaping (QuickActionType) -> Void) {
        if isVisible {
            hide()
        } else {
            show(onAction: onAction)
        }
    }

    func triggerAction(_ type: QuickActionType) {
        onAction?(type)
        hide()
    }

    private func createPanel() {
        let panelWidth: CGFloat = 320
        let panelHeight: CGFloat = 280

        let view = QuickActionPanelView(controller: self)
        let hosting = NSHostingView(rootView: view)
        hosting.setFrameSize(NSSize(width: panelWidth, height: panelHeight))

        let p = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: panelWidth, height: panelHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentView = hosting
        p.level = .statusBar // High level
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.isMovableByWindowBackground = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false

        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let origin = NSPoint(
            x: sf.midX - panelWidth / 2,
            y: sf.midY - panelHeight / 2
        )
        p.setFrameOrigin(origin)
        p.alphaValue = 0
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }

        panel = p
    }
}

// MARK: - Agent Reply Bubble Model

class AgentReplyBubbleModel: NSObject, ObservableObject {

    @Published var text: String = ""
    @Published var userInput: String = ""
    @Published var toolCalls: [String] = []
    @Published var isStreaming = false
    @Published var conversationId: UUID?

    func addToolCall(_ toolName: String, args: [String: String]) {
        let argStr = args.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        DispatchQueue.main.async {
            self.toolCalls.append("🔧 \(toolName)(\(argStr))")
        }
    }
}

// MARK: - Agent Reply Bubble Controller

final class AgentReplyBubbleController: NSObject {
    static let shared = AgentReplyBubbleController()

    private var panel: KeyablePanel?
    private var bubbleModel: AgentReplyBubbleModel?
    private var hosting: NSHostingView<AgentReplyBubbleView>?

    var onSend: ((String, UUID) -> Void)?

    func show(initialText: String = "") {
        guard panel == nil else { return }
        createPanel(initialText: initialText)
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
            self?.bubbleModel = nil
            self?.hosting = nil
        }
    }

    func updateText(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.bubbleModel?.text = text
            self?.resizePanel()
        }
    }

    func addToolCall(_ toolName: String, args: [String: String]) {
        bubbleModel?.addToolCall(toolName, args: args)
        resizePanel()
    }

    func setConversationId(_ id: UUID) {
        DispatchQueue.main.async {
            self.bubbleModel?.conversationId = id
        }
    }

    func prepareForNewResponse() {
        DispatchQueue.main.async {
            self.bubbleModel?.text = ""
            self.bubbleModel?.toolCalls.removeAll()
            self.resizePanel()
        }
    }

    private func resizePanel() {
        guard let panel, let hosting else { return }

        // Calculate new height based on content
        let contentHeight = calculateContentHeight()
        let newHeight = min(contentHeight + 100, 600) // Max height 600px

        DispatchQueue.main.async {
            hosting.setFrameSize(NSSize(width: 360, height: newHeight))

            let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let newOrigin = NSPoint(
                x: screen.maxX - 360 - 16,
                y: screen.maxY - newHeight - 16
            )

            panel.setFrame(NSRect(origin: newOrigin, size: NSSize(width: 360, height: newHeight)), display: true)
        }
    }

    private func calculateContentHeight() -> CGFloat {
        guard let model = bubbleModel else { return 200 }

        let textHeight = CGFloat(max(40, model.text.count / 40 * 20))
        let toolCallsHeight = CGFloat(model.toolCalls.count * 20)

        return textHeight + toolCallsHeight + 60
    }

    private func createPanel(initialText: String) {
        let model = AgentReplyBubbleModel()
        model.text = initialText
        self.bubbleModel = model

        let bubbleView = AgentReplyBubbleView(model: model, controller: self)
        let hosting = NSHostingView(rootView: bubbleView)
        hosting.setFrameSize(NSSize(width: 360, height: 250))
        self.hosting = hosting

        let p = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 360, height: 250)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentView = hosting
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true

        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        // Upper right corner, with padding
        let origin = NSPoint(
            x: sf.maxX - 360 - 16,
            y: sf.maxY - 250 - 16
        )
        p.setFrameOrigin(origin)
        p.alphaValue = 0
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }

        panel = p
    }
}

// MARK: - Quick Action Panel View

struct QuickActionPanelView: View {
    let controller: QuickActionPanelController

    var body: some View {
        VStack(spacing: 0) {
            Text("Quick Actions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 16)
                .padding(.bottom, 12)

            ForEach(Array(QuickActionType.visibleCases.enumerated()), id: \.element) { index, action in
                if index > 0 {
                    Divider().padding(.horizontal, 16)
                }
                QuickActionButton(action: action) {
                    controller.triggerAction(action)
                }
            }

            Spacer(minLength: 8)
        }
        .frame(width: 320, height: 280)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

struct QuickActionButton: View {
    let action: QuickActionType
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: action.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isHovering ? .white : .accentColor)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isHovering ? Color.accentColor : Color.accentColor.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(action.prompt.prefix(45) + "...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
                    .padding(.horizontal, 8)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Agent Reply Bubble View

struct AgentReplyBubbleView: View {
    @ObservedObject var model: AgentReplyBubbleModel
    let controller: AgentReplyBubbleController?
    @StateObject private var voiceManager = OpenAIVoiceManager()
    @State private var vocalModeEnabled = false
    @State private var lastSpokenText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Lumi Agent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button(action: { AgentReplyBubbleController.shared.hide() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Main content scroll area
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // Agent message
                    MarkdownMessageView(text: model.text, agents: AppState.shared?.agents ?? [], fontSize: 11)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Tool calls stream
                    if !model.toolCalls.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.toolCalls, id: \.self) { toolCall in
                                Text(toolCall)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Divider()

            // Input field for user response
            HStack(spacing: 8) {
                TextField("Type response...", text: $model.userInput)
                    .font(.system(size: 11))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendUserInput() }

                Button {
                    vocalModeEnabled.toggle()
                } label: {
                    Image(systemName: vocalModeEnabled ? "waveform.circle.fill" : "waveform.circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(vocalModeEnabled ? Color.pink : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Toggle vocal mode (auto-speak replies).")

                Button(action: handleVoiceTap) {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            voiceManager.isRecording
                                ? Color.red
                                : (voiceManager.isProcessing ? Color.orange : Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .disabled(voiceManager.isProcessing || voiceManager.isRecording)
                .help(voiceManager.isRecording ? "Listening... auto-stop + auto-send." : "Start voice input (auto-stop + auto-send).")

                Button(action: { sendUserInput() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(model.userInput.isEmpty ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(model.userInput.isEmpty)
            }

            if voiceManager.isRecording || voiceManager.isProcessing || (voiceManager.lastError?.isEmpty == false) {
                HStack(spacing: 6) {
                    Image(systemName: voiceManager.isRecording ? "waveform" : (voiceManager.isProcessing ? "hourglass" : "exclamationmark.triangle.fill"))
                        .font(.caption)
                        .foregroundStyle(voiceManager.isRecording ? .red : .orange)
                    Text(voiceStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(12)
        .frame(minWidth: 360, maxWidth: 360, minHeight: 200, maxHeight: 600)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        )
        .onChange(of: model.text) { _, newValue in
            guard vocalModeEnabled else { return }
            let content = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }
            guard content != "Processing..." else { return }
            guard content != lastSpokenText else { return }
            lastSpokenText = content
            Task {
                try? await voiceManager.speak(text: content)
            }
        }
    }

    private func sendUserInput() {
        guard let convId = model.conversationId, !model.userInput.isEmpty else { return }
        controller?.onSend?(model.userInput, convId)
        model.userInput = ""
    }

    private func handleVoiceTap() {
        Task {
            guard !voiceManager.isRecording, !voiceManager.isProcessing else { return }
            if let transcript = try? await voiceManager.recordAndTranscribeAutomatically(),
               !transcript.isEmpty {
                model.userInput = transcript
                sendUserInput()
            }
        }
    }

    private var voiceStatusText: String {
        if voiceManager.isRecording { return "Listening... auto-stop enabled." }
        if voiceManager.isProcessing { return "Processing voice..." }
        return voiceManager.lastError ?? ""
    }
}
#endif
