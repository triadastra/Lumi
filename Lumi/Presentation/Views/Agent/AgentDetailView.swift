//
//  AgentDetailView.swift
//  LumiAgent
//
//  Created by Lumi Agent on 2026-02-18.
//

#if os(macOS)
import SwiftUI

// MARK: - Tool name formatter
private func formatToolName(_ name: String) -> String {
    name.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
}

struct AgentDetailView: View {
    let agent: Agent
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var isEditing = false
    @State private var draft: Agent
    @State private var showingDeleteConfirm = false

    init(agent: Agent) {
        self.agent = agent
        _draft = State(initialValue: agent)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if isEditing {
                    EditForm(draft: $draft)
                } else {
                    ReadOnlyView(agent: draft)
                }

                Spacer(minLength: 0)
            }
            .padding()
        }
        .navigationTitle(isEditing ? "Edit Agent" : draft.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isEditing {
                    Button("Cancel") {
                        draft = agent
                        isEditing = false
                    }
                    Button("Save") {
                        appState.updateAgent(draft)
                        isEditing = false
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        showingDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .foregroundColor(.red)
                    .help("Delete agent")

                    Button("Edit") {
                        draft = agent
                        isEditing = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .onChange(of: agent) {
            if !isEditing {
                draft = agent
            }
        }
        .confirmationDialog(
            "Delete \"\(agent.name)\"?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                appState.deleteAgent(id: agent.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }
}

// MARK: - Read-Only View

private struct ReadOnlyView: View {
    @EnvironmentObject var appState: AppState
    let agent: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    HStack(spacing: 8) {
                        Text(agent.name)
                            .font(.largeTitle)
                        
                        Button {
                            if appState.isDefaultAgent(agent.id) {
                                appState.setDefaultAgent(nil)
                            } else {
                                appState.setDefaultAgent(agent.id)
                            }
                        } label: {
                            Image(systemName: appState.isDefaultAgent(agent.id) ? "star.fill" : "star")
                                .foregroundStyle(appState.isDefaultAgent(agent.id) ? .yellow : .secondary)
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .help(appState.isDefaultAgent(agent.id) ? "Primary agent for global shortcuts" : "Set as primary agent for global shortcuts")
                    }
                    Text("Powered by \(agent.configuration.provider.rawValue)")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(status: agent.status)
            }

            Divider()

            // Configuration
            GroupBox("Configuration") {
                VStack(alignment: .leading, spacing: 12) {
                    ConfigRow(label: "Model", value: agent.configuration.model)
                    ConfigRow(
                        label: "Temperature",
                        value: String(format: "%.2f", agent.configuration.temperature ?? 0.7)
                    )
                    ConfigRow(label: "Max Tokens", value: "\(agent.configuration.maxTokens ?? 4096)")
                    if let prompt = agent.configuration.systemPrompt, !prompt.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("System Prompt")
                                .foregroundStyle(.secondary)
                            Text(prompt)
                                .font(.body)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            // Capabilities
            if !agent.capabilities.isEmpty {
                GroupBox("Capabilities") {
                    FlowLayout(spacing: 8) {
                        ForEach(agent.capabilities, id: \.self) { capability in
                            CapabilityBadge(capability: capability)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            // Security Policy
            GroupBox("Security Policy") {
                VStack(alignment: .leading, spacing: 12) {
                    ConfigRow(
                        label: "Allow Sudo",
                        value: agent.configuration.securityPolicy.allowSudo ? "Yes" : "No"
                    )
                    ConfigRow(
                        label: "Require Approval",
                        value: agent.configuration.securityPolicy.requireApproval ? "Yes" : "No"
                    )
                    ConfigRow(
                        label: "Max Execution Time",
                        value: "\(Int(agent.configuration.securityPolicy.maxExecutionTime))s"
                    )
                    ConfigRow(
                        label: "Auto-Approve Threshold",
                        value: agent.configuration.securityPolicy.autoApproveThreshold.displayName
                    )
                }
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Edit Form

private struct EditForm: View {
    @EnvironmentObject var appState: AppState
    @Binding var draft: Agent

    @State private var availableModels: [String] = []
    @State private var loadingModels = false
    @State private var ollamaUnreachable = false

    private func uniqueModels(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models.filter { seen.insert($0).inserted }
    }

    private var recommendedModelOptions: [String] {
        let available = uniqueModels(availableModels)
        let preferred = draft.configuration.provider.recommendedModels.filter { available.contains($0) }
        if !preferred.isEmpty {
            return preferred
        }
        return Array(available.prefix(3))
    }

    private var allModelOptions: [String] {
        uniqueModels(availableModels)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Basic Info
            GroupBox("Agent Details") {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledField("Name") {
                        TextField("Agent name", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledField("Provider") {
                        Picker("Provider", selection: $draft.configuration.provider) {
                            ForEach(AIProvider.allCases, id: \.self) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: draft.configuration.provider) {
                            draft.configuration.model =
                                AppConfig.defaultModels[draft.configuration.provider] ?? ""
                            ollamaUnreachable = false
                            fetchModels()
                        }
                    }

                    LabeledField("Model") {
                        HStack(spacing: 8) {
                            if loadingModels {
                                TextField("Model name", text: $draft.configuration.model)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(true)
                                ProgressView().scaleEffect(0.7)
                            } else if !availableModels.isEmpty {
                                Picker("Model", selection: $draft.configuration.model) {
                                    Section("Recommended") {
                                        ForEach(recommendedModelOptions, id: \.self) { m in
                                            Text(m).tag(m)
                                        }
                                    }
                                    Section("All Models") {
                                        ForEach(allModelOptions, id: \.self) { m in
                                            Text(m).tag(m)
                                        }
                                    }
                                }
                                if draft.configuration.provider == .ollama {
                                    Button {
                                        fetchModels()
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .help("Refresh models from Ollama")
                                }
                            } else if ollamaUnreachable {
                                TextField("Model name", text: $draft.configuration.model)
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    fetchModels()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.orange)
                                .help("Ollama unreachable — tap to retry")
                            } else {
                                TextField("Model name", text: $draft.configuration.model)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        if ollamaUnreachable && !loadingModels {
                            HStack {
                                Text("Ollama unreachable.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                
                                Button {
                                    AIProviderRepository().launchOllama()
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

                    Toggle("Primary for Global Shortcuts", isOn: Binding(
                        get: { appState.isDefaultAgent(draft.id) },
                        set: { on in
                            if on { appState.setDefaultAgent(draft.id) }
                            else if appState.isDefaultAgent(draft.id) { appState.setDefaultAgent(nil) }
                        }
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            .onAppear { fetchModels() }

            // Generation Settings
            GroupBox("Generation Settings") {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledField("Temperature") {
                        HStack {
                            Slider(
                                value: Binding(
                                    get: { draft.configuration.temperature ?? 0.7 },
                                    set: { draft.configuration.temperature = $0 }
                                ),
                                in: 0...2,
                                step: 0.01
                            )
                            Text(String(format: "%.2f", draft.configuration.temperature ?? 0.7))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }

                    LabeledField("Max Tokens") {
                        TextField(
                            "4096",
                            text: Binding(
                                get: { "\(draft.configuration.maxTokens ?? 4096)" },
                                set: { draft.configuration.maxTokens = Int($0) ?? draft.configuration.maxTokens }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("System Prompt")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                        TextEditor(
                            text: Binding(
                                get: { draft.configuration.systemPrompt ?? "" },
                                set: { draft.configuration.systemPrompt = $0.isEmpty ? nil : $0 }
                            )
                        )
                        .font(.body)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.vertical, 8)
            }

            // Tools
            ToolsSection(draft: $draft)

            // Security Policy
            GroupBox("Security Policy") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Allow Sudo", isOn: $draft.configuration.securityPolicy.allowSudo)

                    Toggle(
                        "Require Approval for Risky Actions",
                        isOn: $draft.configuration.securityPolicy.requireApproval
                    )

                    LabeledField("Max Execution Time") {
                        HStack {
                            Slider(
                                value: $draft.configuration.securityPolicy.maxExecutionTime,
                                in: 10...600,
                                step: 10
                            )
                            Text("\(Int(draft.configuration.securityPolicy.maxExecutionTime))s")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }

                    LabeledField("Auto-Approve Threshold") {
                        Picker(
                            "Threshold",
                            selection: $draft.configuration.securityPolicy.autoApproveThreshold
                        ) {
                            ForEach([RiskLevel.low, .medium, .high, .critical], id: \.self) { level in
                                Text(level.displayName).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func fetchModels() {
        let provider = draft.configuration.provider
        guard provider == .ollama else {
            availableModels = provider.defaultModels
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
                let live = try await repo.getAvailableModels(provider: provider)
                await MainActor.run {
                    availableModels = live
                    ollamaUnreachable = live.isEmpty
                    if !live.contains(draft.configuration.model) {
                        draft.configuration.model = live.first ?? draft.configuration.model
                    }
                    loadingModels = false
                }
            } catch {
                await MainActor.run {
                    availableModels = []
                    ollamaUnreachable = true
                    loadingModels = false
                }
            }
        }
    }
}

// MARK: - Tools Section

private struct ToolsSection: View {
    @Binding var draft: Agent

    var allToolNames: [String] {
        ToolRegistry.shared.getAllTools().map(\.name).sorted()
    }

    var isAllEnabled: Bool {
        draft.configuration.enabledTools.isEmpty
    }

    // All tools grouped by category, categories sorted by displayName
    var groupedTools: [(category: ToolCategory, tools: [RegisteredTool])] {
        let all = ToolRegistry.shared.getAllTools()
        let grouped = Dictionary(grouping: all, by: \.category)
        return grouped
            .map { (category: $0.key, tools: $0.value.sorted(by: { $0.name < $1.name })) }
            .sorted(by: { $0.category.displayName < $1.category.displayName })
    }

    var body: some View {
        GroupBox("Tools") {
            VStack(alignment: .leading, spacing: 12) {
                if isAllEnabled {
                    // Banner
                    HStack {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundColor(.green)
                        Text("All tools enabled")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Customize") {
                            draft.configuration.enabledTools = allToolNames
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    // "Enable all" shortcut
                    HStack {
                        Spacer()
                        Button("Enable All") {
                            draft.configuration.enabledTools = []
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundColor(.secondary)
                    }

                    // Tool list grouped by category
                    ForEach(groupedTools, id: \.category.rawValue) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            // Category header
                            HStack(spacing: 6) {
                                Image(systemName: group.category.icon)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(group.category.displayName)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                            }
                            .padding(.top, 4)

                            ForEach(group.tools, id: \.name) { tool in
                                ToolToggleRow(tool: tool, draft: $draft)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Tool Toggle Row

private struct ToolToggleRow: View {
    let tool: RegisteredTool
    @Binding var draft: Agent

    var isEnabled: Bool {
        draft.configuration.enabledTools.contains(tool.name)
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isEnabled },
            set: { on in
                if on {
                    if !draft.configuration.enabledTools.contains(tool.name) {
                        draft.configuration.enabledTools.append(tool.name)
                    }
                } else {
                    draft.configuration.enabledTools.removeAll { $0 == tool.name }
                }
            }
        )) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatToolName(tool.name))
                        .fontWeight(.medium)
                    Text(tool.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                RiskBadge(level: tool.riskLevel)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: - Risk Badge

private struct RiskBadge: View {
    let level: RiskLevel

    var color: Color {
        switch level {
        case .low:      return .green
        case .medium:   return .orange
        case .high:     return .red
        case .critical: return .red
        }
    }

    var body: some View {
        Text(level.displayName)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Helpers

private struct LabeledField<Content: View>: View {
    let label: String
    let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            content()
        }
    }
}

struct ConfigRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

struct CapabilityBadge: View {
    let capability: AgentCapability

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: capability.icon)
            Text(capability.displayName)
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.1))
        .foregroundColor(.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - AgentCapability icon extension

private extension AgentCapability {
    var icon: String {
        switch self {
        case .fileOperations: return "doc.fill"
        case .webSearch: return "magnifyingglass"
        case .codeExecution: return "terminal.fill"
        case .systemCommands: return "command"
        case .databaseAccess: return "cylinder.fill"
        case .networkRequests: return "network"
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.frames[index].minX, y: bounds.minY + result.frames[index].minY), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var frames: [CGRect] = []
        var size: CGSize = .zero

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }

                frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: y + lineHeight)
        }
    }
}
#endif
