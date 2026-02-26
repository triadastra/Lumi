//
//  AppState.swift
//  LumiAgent
//
//  Shared application state observable object.
//  macOS-only methods live in AppState+macOS.swift.
//

import SwiftUI
import Combine
import Foundation
#if os(macOS)
import AppKit
import Carbon.HIToolbox
import ApplicationServices
#endif

// MARK: - Screen Control Tool Names
// Tool names that imply active desktop control.
private let screenControlToolNames: Set<String> = [
    "open_application", "click_mouse", "scroll_mouse",
    "type_text", "press_key"
]

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    static weak var shared: AppState?

    // MARK: - Sidebar / Navigation
    @Published var selectedSidebarItem: SidebarItem = .agents
    @Published var selectedAgentId: UUID?
    @Published var agents: [Agent] = []
    @Published var showingNewAgent = false

    // MARK: - Persistent Default Agent
    @AppStorage("settings.defaultExteriorAgentId") private var defaultAgentIdString = ""

    var defaultExteriorAgentId: UUID? {
        get { UUID(uuidString: defaultAgentIdString) }
        set { defaultAgentIdString = newValue?.uuidString ?? "" }
    }

    func isDefaultAgent(_ id: UUID) -> Bool {
        defaultExteriorAgentId == id
    }

    func setDefaultAgent(_ id: UUID?) {
        defaultExteriorAgentId = id
    }

    // MARK: - Agent Space
    @Published var conversations: [Conversation] = [] {
        didSet { saveConversations() }
    }
    @Published var selectedConversationId: UUID?
    @AppStorage("settings.hotkeyConversationId") var hotkeyConversationIdString = ""

    // MARK: - Tool Call History
    @Published var toolCallHistory: [ToolCallRecord] = []
    @Published var selectedHistoryAgentId: UUID?

    // MARK: - Automations
    @Published var automations: [AutomationRule] = [] {
        didSet { saveAutomations() }
    }
    @Published var selectedAutomationId: UUID?

    // MARK: - Settings Navigation
    @Published var selectedSettingsSection: String? = "apiKeys"

    // MARK: - Health
    @Published var selectedHealthCategory: HealthCategory? = .activity

    // MARK: - Screen Control State
    @Published var isAgentControllingScreen = false
    private var screenControlCount = 0
    var screenControlTasks: [Task<Void, Never>] = []
    private var hotkeyRefreshObserver: NSObjectProtocol?
    @AppStorage("settings.enableGlobalHotkeys") var enableGlobalHotkeys = true

    // MARK: - Private Storage
    private let conversationsFileName = "conversations.json"
    private let automationsFileName   = "automations.json"

    #if os(macOS)
    var automationEngine: AutomationEngine?
    let remoteServer = MacRemoteServer.shared
    private let usbObserver = USBDeviceObserver.shared
    @Published var isUSBDeviceConnected: Bool = false
    #endif

    // MARK: - Init

    init() {
        Self.shared = self
        _ = DatabaseManager.shared
        
        loadAgents()
        loadConversations()
        loadAutomations()

        NotificationCenter.default.addObserver(
            forName: Notification.Name("lumi.dataRemoteUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.loadAgents()
                self?.loadConversations()
                self?.loadAutomations()
            }
        }
        
        #if os(macOS)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.setupGlobalHotkey()
            self.startAutomationEngine()
            
            self.usbObserver.onDeviceConnected = {
                print("[AppState] iPhone/iPad detected via USB. Ready for sync.")
                Task { @MainActor in
                    self.isUSBDeviceConnected = true
                }
            }
            self.usbObserver.onDeviceDisconnected = {
                print("[AppState] iPhone/iPad disconnected from USB.")
                Task { @MainActor in
                    self.isUSBDeviceConnected = false
                }
            }
            self.usbObserver.start()
            
            self.hotkeyRefreshObserver = NotificationCenter.default.addObserver(
                forName: .lumiGlobalHotkeysPreferenceChanged,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    AppState.shared?.refreshGlobalHotkeys()
                }
            }

        }
        #endif
    }

    // MARK: - Command Palette Message (Shared)

    func sendCommandPaletteMessage(text: String, agentId: UUID?) {
        let targetId = agentId ?? defaultExteriorAgentId ?? agents.first?.id
        guard let targetId, agents.contains(where: { $0.id == targetId }) else { return }

        let conv = createDM(agentId: targetId)
        sendMessage(text, in: conv.id, agentMode: true)

        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }

    // MARK: - Automation Management

    func createAutomation() {
        let rule = AutomationRule(agentId: agents.first?.id)
        automations.insert(rule, at: 0)
        selectedAutomationId = rule.id
    }

    func runAutomation(id: UUID) {
        guard let rule = automations.first(where: { $0.id == id }) else { return }
        #if os(macOS)
        automationEngine?.runManually(rule)
        #endif
    }

    func fireAutomation(_ rule: AutomationRule) {
        guard rule.isEnabled, let agentId = rule.agentId else { return }
        let prompt = rule.notes.isEmpty
            ? "Execute the automation titled: \"\(rule.title)\""
            : "Execute this automation task:\n\n\(rule.notes)"
        sendCommandPaletteMessage(text: prompt, agentId: agentId)
        if let idx = automations.firstIndex(where: { $0.id == rule.id }) {
            automations[idx].lastRunAt = Date()
        }
    }

    private func loadAutomations() {
        // Try migration from legacy UserDefaults if file doesn't exist
        do {
            let db = DatabaseManager.shared
            automations = try db.load([AutomationRule].self, from: automationsFileName, default: {
                if let legacyData = UserDefaults.standard.data(forKey: "lumiagent.automations"),
                   let legacy = try? JSONDecoder().decode([AutomationRule].self, from: legacyData) {
                    return legacy
                }
                return []
            }())
        } catch {
            print("Error loading automations: \(error)")
        }
    }

    private func saveAutomations() {
        try? DatabaseManager.shared.save(automations, to: automationsFileName)
    }

    // MARK: - Tool Call History

    func recordToolCall(agentId: UUID, agentName: String, toolName: String,
                        arguments: [String: String], result: String) {
        let success = !result.hasPrefix("Error:") && !result.hasPrefix("Tool not found:")
        toolCallHistory.insert(
            ToolCallRecord(agentId: agentId, agentName: agentName, toolName: toolName,
                           arguments: arguments, result: result, success: success),
            at: 0
        )
    }

    // MARK: - Screen Control

    func stopAgentControl() {
        screenControlTasks.forEach { $0.cancel() }
        screenControlTasks.removeAll()
        screenControlCount = 0
        isAgentControllingScreen = false
    }

    // MARK: - Agent Persistence

    private func loadAgents() {
        Task {
            let repo = AgentRepository()
            do {
                self.agents = try await repo.getAll()
            } catch {
                print("Error loading agents: \(error)")
            }
        }
    }

    func updateAgent(_ agent: Agent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[index] = agent
        }
        Task {
            let repo = AgentRepository()
            try? await repo.update(agent)
        }
    }

    func deleteAgent(id: UUID) {
        agents.removeAll { $0.id == id }
        if selectedAgentId == id { selectedAgentId = nil }
        Task {
            let repo = AgentRepository()
            try? await repo.delete(id: id)
        }
    }

    func applySelfUpdate(_ args: [String: String], agentId: UUID) -> String {
        guard let idx = agents.firstIndex(where: { $0.id == agentId }) else {
            return "Error: agent not found."
        }
        var updated = agents[idx]
        var changes: [String] = []

        if let name = args["name"], !name.isEmpty {
            updated.name = name
            changes.append("name → \"\(name)\"")
        }
        if let prompt = args["system_prompt"] {
            updated.configuration.systemPrompt = prompt.isEmpty ? nil : prompt
            changes.append("system prompt updated")
        }
        if let model = args["model"], !model.isEmpty {
            updated.configuration.model = model
            changes.append("model → \(model)")
        }
        if let tempStr = args["temperature"], let temp = Double(tempStr) {
            updated.configuration.temperature = max(0, min(2, temp))
            changes.append("temperature → \(temp)")
        }

        guard !changes.isEmpty else { return "No changes requested." }
        updated.updatedAt = Date()
        updateAgent(updated)
        return "Configuration updated: \(changes.joined(separator: ", "))."
    }

    // MARK: - Conversation Management

    private func loadConversations() {
        do {
            let db = DatabaseManager.shared
            conversations = try db.load([Conversation].self, from: conversationsFileName, default: {
                if let legacyData = UserDefaults.standard.data(forKey: "lumiagent.conversations"),
                   let legacy = try? JSONDecoder().decode([Conversation].self, from: legacyData) {
                    return legacy
                }
                return []
            }())
        } catch {
            print("Error loading conversations: \(error)")
        }
    }

    private func saveConversations() {
        try? DatabaseManager.shared.save(conversations, to: conversationsFileName)
    }

    @discardableResult
    func createDM(agentId: UUID) -> Conversation {
        if let existing = conversations.first(where: { !$0.isGroup && $0.participantIds == [agentId] }) {
            selectedConversationId = existing.id
            selectedSidebarItem = .agentSpace
            return existing
        }
        let conv = Conversation(participantIds: [agentId])
        conversations.insert(conv, at: 0)
        selectedConversationId = conv.id
        selectedSidebarItem = .agentSpace
        return conv
    }

    @discardableResult
    func createGroup(agentIds: [UUID], title: String?) -> Conversation {
        let conv = Conversation(title: title, participantIds: agentIds)
        conversations.insert(conv, at: 0)
        selectedConversationId = conv.id
        selectedSidebarItem = .agentSpace
        return conv
    }

    func deleteConversation(id: UUID) {
        conversations.removeAll { $0.id == id }
        if selectedConversationId == id { selectedConversationId = nil }
    }

    // MARK: - Messaging

    func sendMessage(_ text: String, in conversationId: UUID, agentMode: Bool = false, desktopControlEnabled: Bool = false) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else { return }

        let userMsg = SpaceMessage(role: .user, content: text)
        conversations[index].messages.append(userMsg)
        conversations[index].updatedAt = Date()

        let conv = conversations[index]
        let participants = agents.filter { conv.participantIds.contains($0.id) }

        let mentioned = participants.filter { text.contains("@\($0.name)") }
        let targets: [Agent] = mentioned.isEmpty ? participants : mentioned

        let task = Task { [weak self] in
            guard let self else { return }
            for agent in targets {
                guard !Task.isCancelled else { break }
                let freshHistory = conversations
                    .first(where: { $0.id == conversationId })?
                    .messages.filter { !$0.isStreaming } ?? []
                await streamResponse(from: agent, in: conversationId,
                                     history: freshHistory, agentMode: agentMode,
                                     desktopControlEnabled: desktopControlEnabled)
            }
        }
        screenControlTasks.append(task)
    }

    func streamResponse(
        from agent: Agent,
        in conversationId: UUID,
        history: [SpaceMessage],
        agentMode: Bool = false,
        desktopControlEnabled: Bool = false,
        delegationDepth: Int = 0,
        toolNameAllowlist: Set<String>? = nil
    ) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else { return }

        var didRaiseScreenControl = false
        defer {
            if didRaiseScreenControl {
                screenControlCount = max(0, screenControlCount - 1)
                if screenControlCount == 0 {
                    isAgentControllingScreen = false
                    screenControlTasks.removeAll { $0.isCancelled }
                }
            }
        }

        let placeholderId = UUID()
        conversations[index].messages.append(SpaceMessage(
            id: placeholderId, role: .agent, content: "",
            agentId: agent.id, isStreaming: true
        ))

        let convParticipants = agents.filter { conversations[index].participantIds.contains($0.id) }
        let isGroup = convParticipants.count > 1
        var aiMessages: [AIMessage] = history.compactMap { msg in
            if msg.role == .user {
                return AIMessage(role: .user, content: msg.content, imageData: msg.imageData)
            } else if let senderId = msg.agentId {
                if senderId == agent.id {
                    return AIMessage(role: .assistant, content: msg.content)
                } else if isGroup {
                    let senderName = agents.first { $0.id == senderId }?.name ?? "Agent"
                    return AIMessage(role: .user, content: "[\(senderName)]: \(msg.content)")
                }
            }
            return nil
        }

        let repo = AIProviderRepository()
        var tools: [AITool]
        #if os(macOS)
        if agentMode {
            if desktopControlEnabled {
                tools = ToolRegistry.shared.getToolsForAI()
            } else {
                tools = ToolRegistry.shared.getToolsForAIWithoutDesktopControl()
            }
        } else {
            tools = ToolRegistry.shared.getToolsForAI(enabledNames: agent.configuration.enabledTools)
        }
        if !tools.contains(where: { $0.name == "update_self" }),
           let selfTool = ToolRegistry.shared.getTool(named: "update_self") {
            tools.append(selfTool.toAITool())
        }
        #else
        tools = []
        #endif
        if let allowlist = toolNameAllowlist {
            tools = tools.filter { allowlist.contains($0.name) }
        }

        let effectiveSystemPrompt: String? = {
            var parts: [String] = []
            if agentMode {
                let modeDescription = desktopControlEnabled
                    ? "You have FULL autonomous control of the user's Mac — file system, web, shell, apps, and screen."
                    : "You have access to file system, web, shell, AppleScript, and screenshots. Desktop control (mouse, keyboard, app launching) is DISABLED."

                parts.append("""
                You are in Agent Mode. \(modeDescription)

                ═══ MULTI-STEP TASK EXECUTION ═══
                For any task that requires multiple steps (research → reason → write, open app → interact → verify, etc.):
                  1. PLAN silently: identify every step needed to fully complete the task.
                  2. EXECUTE each step immediately using the appropriate tool — do NOT narrate future steps, just do them.
                  3. CHAIN results: use the output of one tool as input to the next tool call.
                  4. ONLY give a final text response when EVERY step is 100% complete.
                  5. NEVER stop mid-task and ask the user to continue or do anything manually.

                EXAMPLE — "search for X, then write a report on the Desktop":
                  Step 1 → call web_search("X")
                  Step 2 → call web_search again for more detail if needed
                  Step 3 → call write_file(path: "/Users/<user>/Desktop/report.txt", content: <full report>)
                  Step 4 → respond: "Done — report saved to your Desktop."

                EXAMPLE — "open Safari and go to apple.com":
                  Step 1 → call open_application("Safari")
                  Step 2 → call run_applescript to navigate to the URL
                  Step 3 → respond with result.

                ═══ TOOL SELECTION GUIDE ═══
                • Research / web data   → web_search, fetch_url
                • Files on disk         → write_file, read_file, list_directory, create_directory
                • Shell / automation    → execute_command, run_applescript
                • Open apps / URLs      → open_application, open_url
                • Screen interaction    → get_screen_info, click_mouse, type_text, press_key, take_screenshot
                • Memory across turns   → memory_save, memory_read

                ═══ SCREEN CONTROL ═══
                • Screen origin is top-left (0,0). Coordinates are logical pixels (1:1 with screenshot).
                • When you receive a screenshot, look at the image carefully and read the EXACT pixel
                  position of the element — do NOT approximate or guess. State the pixel coords before clicking.

                PRIORITY ORDER for UI interaction:
                  1. run_applescript — interact by element name, no coordinates needed (most reliable)
                  2. JavaScript via AppleScript — for web browsers (never misses, not affected by zoom)
                  3. click_mouse — pixel click, last resort only

                AppleScript — native app UI:
                    tell application "AppName" to activate
                    delay 0.8
                    tell application "System Events"
                        tell process "AppName"
                            click button "Button Name" of window 1
                            set value of text field 1 of window 1 to "text"
                            key code 36  -- Return
                        end tell
                    end tell

                JavaScript via AppleScript — web browsers (ALWAYS prefer this over click_mouse in browsers):
                    -- Click a tab / link by text or selector:
                    tell application "Google Chrome"
                        tell active tab of front window
                            execute javascript "document.querySelector('a[href*=\\"/images\\"]').click()"
                        end tell
                    end tell
                    -- Or navigate directly (most reliable):
                    tell application "Google Chrome"
                        set URL of active tab of front window to "https://www.bing.com/images/search?q=cats"
                    end tell
                    -- Safari equivalent: execute javascript / set URL of current tab of front window

                ═══ WHEN AN ACTION FAILS ═══
                If a click or action doesn't produce the expected result:
                  1. NEVER repeat the identical click at "slightly adjusted" coordinates — that rarely works.
                  2. NEVER tell the user to click manually — try a different method instead.
                  3. For browser clicks that failed → switch to JavaScript or navigate by URL directly.
                  4. For native app clicks that failed → switch to System Events AppleScript by element name.
                  5. If still failing after 2 attempts → take_screenshot, re-read the full UI, pick a completely
                     different approach (e.g. keyboard shortcut, menu item, URL navigation).
                  6. Only after exhausting ALL automated approaches may you report that the action failed.

                ═══ SCREENSHOT POLICY ═══
                • Do NOT take screenshots by default after every step.
                • Only use take_screenshot when visual verification is required or when recovery/debugging needs fresh UI context.
                • If run_applescript/open_url already completes the task deterministically, finish without extra screenshot checks.

                ═══ ABSOLUTE RULES ═══
                1. NEVER tell the user to "manually" do anything — not clicking, typing, or any interaction.
                2. NEVER stop after one tool call and ask what to do next — keep executing until the full task is done.
                3. NEVER leave a task half-finished. If a step fails, try an alternative approach.
                4. Desktop path: use execute_command("echo $HOME") to get the user's home, then write to $HOME/Desktop/.
                """)

                if !desktopControlEnabled {
                    parts.append("""
                    ⚠️ DESKTOP CONTROL RESTRICTION ⚠️
                    The following tools are NOT available:
                    • click_mouse, scroll_mouse, move_mouse — no mouse control
                    • type_text, press_key — no keyboard input
                    • open_application — cannot launch apps

                    AVAILABLE ALTERNATIVES:
                    • take_screenshot — view the screen
                    • run_applescript — execute AppleScript for automation
                    • execute_command — run shell commands
                    • write_file, read_file — file operations
                    • web_search, fetch_url — web access

                    Use AppleScript (run_applescript) with System Events for sophisticated automation instead of mouse/keyboard clicks.
                    """)
                }
            }
            if isGroup {
                let others = convParticipants.filter { $0.id != agent.id }
                if !others.isEmpty {
                    let peerList = others.map { other -> String in
                        let role = other.configuration.systemPrompt
                            .flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
                            ?? "General assistant"
                        return "• \(other.name): \(role)"
                    }.joined(separator: "\n")
                    parts.append("""
                    You are \(agent.name). You are in a multi-agent group conversation. There is no leader — all agents are equal peers.

                    ═══ PARTICIPANTS ═══
                    \(peerList)
                    • You: \(agent.name)

                    Other agents' messages appear prefixed with [AgentName]: in the conversation.

                    ═══ HOW TO COLLABORATE ═══
                    Agents take turns — one completes their work fully, then hands off.
                    • READ FIRST: Before acting, read all previous messages to understand what has already been done.
                      Never duplicate or redo work a peer has already completed.
                    • ACT, DON'T OVERLAP: Do your part of the task using tools, then hand off cleanly.
                      Don't start something another agent is already doing or has just finished.
                    • HAND OFF with @AgentName: <clear instruction of what's left> — they will pick up exactly where you stopped.
                      Hand off to ONE agent at a time. Avoid mentioning multiple agents in one message unless
                      they truly need to act at the same time (which is rare).
                    • CONTINUE FREELY: After receiving a handoff, act on it. Then hand back or forward as needed.
                      The conversation can go back-and-forth as many times as the task requires.
                    • USE TOOLS at any point: search, write files, run code, control the screen, etc.
                    • FINISH: When everything is truly done, end your message with [eof].

                    ═══ SILENCE PROTOCOL ═══
                    • Not your turn, or nothing meaningful to add → respond with exactly: [eof] (hidden from user).
                    • Spoke your piece and want to hand off → say what you need, then end with [eof].
                    • Near exchange limit (20) → just finish the task yourself instead of delegating further.
                    """)
                }
            }
            if let base = agent.configuration.systemPrompt, !base.isEmpty { parts.append(base) }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }()

        func updatePlaceholder(_ text: String) {
            if let ci = conversations.firstIndex(where: { $0.id == conversationId }),
               let mi = conversations[ci].messages.firstIndex(where: { $0.id == placeholderId }) {
                conversations[ci].messages[mi].content = text
            }
            #if os(macOS)
            DispatchQueue.main.async {
                AgentReplyBubbleController.shared.updateText(text)
            }
            #endif
        }

        do {
            if tools.isEmpty {
                let stream = try await repo.sendMessageStream(
                    provider: agent.configuration.provider,
                    model: agent.configuration.model,
                    messages: aiMessages,
                    systemPrompt: effectiveSystemPrompt,
                    temperature: agent.configuration.temperature,
                    maxTokens: agent.configuration.maxTokens
                )
                var accumulated = ""
                for try await chunk in stream {
                    if let content = chunk.content, !content.isEmpty {
                        accumulated += content
                        updatePlaceholder(accumulated)
                    }
                }
            } else {
                var iteration = 0
                let maxIterations = agentMode ? 30 : 10
                var finalContent = ""
                while iteration < maxIterations {
                    iteration += 1

                    if Task.isCancelled {
                        updatePlaceholder(finalContent.isEmpty ? "Stopped." : finalContent)
                        break
                    }

                    let response = try await repo.sendMessage(
                        provider: agent.configuration.provider,
                        model: agent.configuration.model,
                        messages: aiMessages,
                        systemPrompt: effectiveSystemPrompt,
                        tools: tools,
                        temperature: agent.configuration.temperature,
                        maxTokens: agent.configuration.maxTokens
                    )

                    aiMessages.append(AIMessage(
                        role: .assistant,
                        content: response.content ?? "",
                        toolCalls: response.toolCalls
                    ))

                    if let content = response.content, !content.isEmpty {
                        finalContent += (finalContent.isEmpty ? "" : "\n\n") + content
                        updatePlaceholder(finalContent)
                    }

                    guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else { break }

                    let names = toolCalls.map { $0.name }.joined(separator: ", ")
                    finalContent += (finalContent.isEmpty ? "" : "\n\n") + "Running: \(names)…"
                    updatePlaceholder(finalContent)

                    var touchedScreen = false

                    for toolCall in toolCalls {
                        if Task.isCancelled { break }

                        let result: String
                        #if os(macOS)
                        DispatchQueue.main.async {
                            AgentReplyBubbleController.shared.addToolCall(toolCall.name, args: toolCall.arguments)
                        }
                        #endif

                        #if os(macOS)
                        if toolCall.name == "update_self" {
                            result = applySelfUpdate(toolCall.arguments, agentId: agent.id)
                        } else if let tool = ToolRegistry.shared.getTool(named: toolCall.name) {
                            do { result = try await tool.handler(toolCall.arguments) }
                            catch { result = "Error: \(error.localizedDescription)" }
                        } else {
                            result = "Tool not found: \(toolCall.name)"
                        }
                        #else
                        result = "Tools not available on this platform"
                        #endif
                        recordToolCall(agentId: agent.id, agentName: agent.name,
                                       toolName: toolCall.name, arguments: toolCall.arguments,
                                       result: result)
                        aiMessages.append(AIMessage(role: .tool, content: result, toolCallId: toolCall.id))

                        if screenControlToolNames.contains(toolCall.name) {
                            touchedScreen = true
                            if agentMode && !didRaiseScreenControl {
                                didRaiseScreenControl = true
                                screenControlCount += 1
                                isAgentControllingScreen = true
                            }
                        }
                    }

                    #if os(macOS)
                    if agentMode && touchedScreen && !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 900_000_000)

                        finalContent += (finalContent.isEmpty ? "" : "\n\n") + "📸 Capturing screen…"
                        updatePlaceholder(finalContent)

                        let (screen, displayID) = await MainActor.run { () -> (CGRect, UInt32) in
                            let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
                            let id = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                                .map { UInt32($0.uint32Value) } ?? CGMainDisplayID()
                            return (frame, id)
                        }
                        let screenW = Int(screen.width), screenH = Int(screen.height)
                        let jpeg = await Task.detached(priority: .userInitiated) {
                            captureScreenAsJPEG(maxWidth: 1440, displayID: displayID)
                        }.value
                        if let data = jpeg {
                            aiMessages.append(AIMessage(
                                role: .user,
                                content: "Here is the current screen state after your last actions. " +
                                         "Resolution: \(screenW)×\(screenH) logical px — coordinates are 1:1, " +
                                         "top-left origin (0,0). Use pixel positions from this image directly " +
                                         "with click_mouse — no scaling needed. " +
                                         "Identify every visible UI element and decide what to do next. " +
                                         "Tip: run_applescript can interact with UI elements by name " +
                                         "(click buttons, fill fields, choose menu items) without needing " +
                                         "pixel coordinates — prefer it when the app supports it.",
                                imageData: data
                            ))
                        }
                    }
                    #endif
                }
                if finalContent.isEmpty { updatePlaceholder("(no response)") }
            }
        } catch {
            updatePlaceholder("Error: \(error.localizedDescription)")
        }

        // Mark streaming done
        if let ci = conversations.firstIndex(where: { $0.id == conversationId }),
           let mi = conversations[ci].messages.firstIndex(where: { $0.id == placeholderId }) {
            conversations[ci].messages[mi].isStreaming = false
        }
        if let ci = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[ci].updatedAt = Date()
        }

        // Strip [eof] silence markers from group chats
        if isGroup,
           let ci = conversations.firstIndex(where: { $0.id == conversationId }),
           let mi = conversations[ci].messages.firstIndex(where: { $0.id == placeholderId }) {
            let raw = conversations[ci].messages[mi].content
            let cleaned = raw
                .replacingOccurrences(of: "[eof]", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                conversations[ci].messages.remove(at: mi)
                return
            } else if cleaned != raw {
                conversations[ci].messages[mi].content = cleaned
            }
        }

        // Agent-to-agent delegation
        if isGroup && delegationDepth < 20 && !Task.isCancelled,
           let ci = conversations.firstIndex(where: { $0.id == conversationId }),
           let mi = conversations[ci].messages.firstIndex(where: { $0.id == placeholderId }) {
            let agentResponse = conversations[ci].messages[mi].content
            let delegatedAgents = convParticipants.filter { other in
                other.id != agent.id &&
                agentResponse.range(of: "@\(other.name)", options: .caseInsensitive) != nil
            }
            if !delegatedAgents.isEmpty {
                for target in delegatedAgents {
                    guard !Task.isCancelled else { break }
                    let freshHistory = conversations
                        .first(where: { $0.id == conversationId })?
                        .messages.filter { !$0.isStreaming } ?? []
                    await streamResponse(
                        from: target,
                        in: conversationId,
                        history: freshHistory,
                        agentMode: agentMode,
                        delegationDepth: delegationDepth + 1
                    )
                }
            }
        }
    }
}

// MARK: - Sidebar Item

enum SidebarItem: String, CaseIterable, Identifiable {
    case agents      = "Agents"
    case agentSpace  = "Agent Space"
    case hotkeySpace = "Hotkey Space"
    case health      = "Health"
    case history     = "History"
    case automation  = "Automations"
    case devices     = "Paired Devices"
    case settings    = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .agents:      return "cpu"
        case .agentSpace:  return "bubble.left.and.bubble.right.fill"
        case .hotkeySpace: return "keyboard"
        case .health:      return "heart.fill"
        case .history:     return "clock.arrow.circlepath"
        case .automation:  return "bolt.horizontal"
        case .devices:     return "iphone"
        case .settings:    return "gear"
        }
    }
}
