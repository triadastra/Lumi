#if os(iOS)
import SwiftUI
import Combine

@MainActor
final class IOSHealthDashboardViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var isAuthorized = false
    @Published var error: String?
    @Published var selectedCategory: HealthCategory = .activity
    @Published var syncData = HealthSyncData()
    @Published var analysisResults: [HealthCategory: String] = [:]
    @Published var analyzingCategory: HealthCategory?
    @Published var lastExportURL: URL?

    private let manager = IOSHealthKitManager.shared

    var hasAnyMetrics: Bool {
        !syncData.activity.isEmpty ||
        !syncData.heart.isEmpty ||
        !syncData.body.isEmpty ||
        !syncData.sleep.isEmpty ||
        !syncData.workouts.isEmpty ||
        !syncData.vitals.isEmpty
    }

    func metrics(for category: HealthCategory) -> [HealthMetric] {
        switch category {
        case .activity:
            return syncData.activity.map(mapDTO)
        case .heart:
            return syncData.heart.map(mapDTO)
        case .body:
            return syncData.body.map(mapDTO)
        case .sleep:
            return syncData.sleep.map(mapDTO)
        case .workouts:
            return syncData.workouts.map(mapDTO)
        case .vitals:
            return syncData.vitals.map(mapDTO)
        }
    }

    func load(notifySync: Bool = false) async {
        isLoading = true
        error = nil

        await manager.prefetchAndCacheSync()
        isAuthorized = manager.isAuthorized

        if let payload = manager.cachedOrPersistedSyncData(),
           let decoded = try? JSONDecoder().decode(HealthSyncData.self, from: payload) {
            syncData = decoded
        } else {
            syncData = HealthSyncData()
        }

        if notifySync {
            NotificationCenter.default.post(
                name: Notification.Name("lumi.localDataChanged"),
                object: "health_data.json"
            )
        }

        isLoading = false
    }

    func requestAuthorization() async {
        do {
            try await manager.requestAuthorization()
            isAuthorized = true
            await load(notifySync: true)
        } catch {
            isAuthorized = false
            self.error = error.localizedDescription
        }
    }

    func exportJSONSnapshot() async {
        do {
            let url = try await manager.exportSyncSnapshotToDocuments()
            lastExportURL = url
            NotificationCenter.default.post(
                name: Notification.Name("lumi.localDataChanged"),
                object: "health_data.json"
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    func analyze(category: HealthCategory, preferredAgent: Agent?) async {
        analyzingCategory = category
        defer { analyzingCategory = nil }

        let categoryMetrics = metrics(for: category)
        guard !categoryMetrics.isEmpty else {
            analysisResults[category] = "No health data available for \(category.rawValue)."
            return
        }

        let dataLines = categoryMetrics.map { metric in
            let unitPart = metric.unit.isEmpty ? "" : " \(metric.unit)"
            return "- \(metric.name): \(metric.value)\(unitPart)"
        }.joined(separator: "\n")

        let weeklyLines = categoryMetrics
            .filter { !$0.weeklyData.isEmpty }
            .map { metric in
                let points = metric.weeklyData
                    .map { "\($0.label): \(Int($0.value))" }
                    .joined(separator: ", ")
                return "- \(metric.name): \(points)"
            }
            .joined(separator: "\n")

        let prompt = """
        You are a health and wellness coach. Analyze this Apple Health data and give practical, non-generic guidance.

        Category: \(category.rawValue)
        Date: \(Date().formatted(date: .long, time: .omitted))

        Metrics:
        \(dataLines)

        Weekly trends:
        \(weeklyLines.isEmpty ? "None" : weeklyLines)

        Provide:
        1) Brief interpretation
        2) What's going well
        3) Specific improvements
        4) One concrete goal for this week

        Keep this concise and include a reminder to consult a medical professional for health concerns.
        """

        let repo = AIProviderRepository()
        do {
            let (provider, model) = try await resolveProviderAndModel(repo: repo, preferredAgent: preferredAgent)
            let response = try await repo.sendMessage(
                provider: provider,
                model: model,
                messages: [AIMessage(role: .user, content: prompt)],
                systemPrompt: "You are a helpful health and wellness coach.",
                tools: nil,
                temperature: 0.7,
                maxTokens: 800
            )
            analysisResults[category] = response.content ?? "No analysis generated."
        } catch {
            analysisResults[category] = "Analysis failed: \(error.localizedDescription)"
        }
    }

    private func resolveProviderAndModel(repo: AIProviderRepository, preferredAgent: Agent?) async throws -> (AIProvider, String) {
        if let agent = preferredAgent {
            return (agent.configuration.provider, agent.configuration.model)
        }
        if let key = try repo.getAPIKey(for: .openai), !key.isEmpty {
            return (.openai, "gpt-5-mini")
        }
        if let key = try repo.getAPIKey(for: .anthropic), !key.isEmpty {
            return (.anthropic, "claude-3-5-haiku-latest")
        }
        if let key = try repo.getAPIKey(for: .gemini), !key.isEmpty {
            return (.gemini, "gemini-2.5-flash")
        }
        if let key = try repo.getAPIKey(for: .qwen), !key.isEmpty {
            return (.qwen, "qwen-plus")
        }

        // Fallback to the first local Ollama model if available.
        let models = try await repo.getAvailableModels(provider: .ollama)
        if let first = models.first {
            return (.ollama, first)
        }

        throw NSError(
            domain: "HealthAnalysis",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No AI provider configured. Add an API key in Settings."]
        )
    }

    private func mapDTO(_ dto: HealthMetricDTO) -> HealthMetric {
        let mappedColor: Color
        switch dto.colorName.lowercased() {
        case "green": mappedColor = .green
        case "orange": mappedColor = .orange
        case "yellow": mappedColor = .yellow
        case "mint": mappedColor = .mint
        case "teal": mappedColor = .teal
        case "red": mappedColor = .red
        case "pink": mappedColor = .pink
        case "purple": mappedColor = .purple
        case "blue": mappedColor = .blue
        case "cyan": mappedColor = .cyan
        case "indigo": mappedColor = .indigo
        case "gray": mappedColor = .gray
        default: mappedColor = .primary
        }

        return HealthMetric(
            name: dto.name,
            value: dto.value,
            unit: dto.unit,
            icon: dto.icon,
            color: mappedColor,
            date: dto.date,
            weeklyData: dto.weeklyData.map { ($0.label, $0.value) }
        )
    }
}

struct IOSHealthDashboardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = IOSHealthDashboardViewModel()

    private var preferredAgent: Agent? {
        if let defaultId = appState.defaultExteriorAgentId,
           let agent = appState.agents.first(where: { $0.id == defaultId }) {
            return agent
        }
        return appState.agents.first
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: vm.isAuthorized ? "heart.fill" : "heart.slash")
                        .foregroundStyle(vm.isAuthorized ? .red : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.isAuthorized ? "Health access ready" : "Health access required")
                            .font(.subheadline.bold())
                        if vm.hasAnyMetrics {
                            Text("Last updated \(vm.syncData.updatedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No health metrics found yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !UserDefaults.standard.bool(forKey: "settings.syncHealth") {
                    Text("Enable \"Sync Apple Health\" in Settings to send this JSON to your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let exportURL = vm.lastExportURL {
                    Text("Saved JSON: \(exportURL.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !vm.isAuthorized {
                Section {
                    Button {
                        Task { await vm.requestAuthorization() }
                    } label: {
                        Label("Grant Apple Health Access", systemImage: "heart.text.square.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section {
                Picker("Category", selection: $vm.selectedCategory) {
                    ForEach(HealthCategory.allCases) { category in
                        Label(category.rawValue, systemImage: category.icon).tag(category)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(vm.selectedCategory.rawValue) {
                if vm.isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading metrics...")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    let metrics = vm.metrics(for: vm.selectedCategory)
                    if metrics.isEmpty {
                        Text("No metrics available for \(vm.selectedCategory.rawValue).")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(metrics) { metric in
                            IOSHealthMetricRow(metric: metric)
                        }
                    }
                }
            }

            Section("AI Insight") {
                Button {
                    Task { await vm.analyze(category: vm.selectedCategory, preferredAgent: preferredAgent) }
                } label: {
                    if vm.analyzingCategory == vm.selectedCategory {
                        HStack {
                            ProgressView()
                            Text("Analyzing...")
                        }
                    } else {
                        Label("Analyze This Category", systemImage: "sparkles")
                    }
                }
                .disabled(vm.isLoading || vm.metrics(for: vm.selectedCategory).isEmpty || vm.analyzingCategory != nil)

                if let insight = vm.analysisResults[vm.selectedCategory], !insight.isEmpty {
                    Text(insight)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineSpacing(3)
                    Button(role: .destructive) {
                        vm.analysisResults.removeValue(forKey: vm.selectedCategory)
                    } label: {
                        Label("Clear Insight", systemImage: "trash")
                    }
                }
            }

            if let error = vm.error {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Health")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await vm.exportJSONSnapshot() }
                } label: {
                    Label("Export JSON", systemImage: "square.and.arrow.down")
                }
                .disabled(vm.isLoading)

                Button {
                    Task { await vm.load(notifySync: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(vm.isLoading)
            }
        }
        .task {
            await vm.load(notifySync: false)
        }
    }
}

private struct IOSHealthMetricRow: View {
    let metric: HealthMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: metric.icon)
                    .foregroundStyle(metric.color)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(metric.value)
                            .font(.headline)
                            .foregroundStyle(metric.color)
                        if !metric.unit.isEmpty {
                            Text(metric.unit)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }

            if !metric.weeklyData.isEmpty {
                IOSHealthMiniBars(data: metric.weeklyData, color: metric.color)
                    .frame(height: 26)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct IOSHealthMiniBars: View {
    let data: [(label: String, value: Double)]
    let color: Color

    private var maxValue: Double {
        max(data.map(\.value).max() ?? 1, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(data.indices, id: \.self) { index in
                let item = data[index]
                let ratio = item.value / maxValue
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index == data.count - 1 ? color : color.opacity(0.35))
                    .frame(height: max(2, CGFloat(ratio) * 26))
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
#endif
