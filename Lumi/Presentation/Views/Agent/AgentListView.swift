//
//  AgentListView.swift
//  LumiAgent
//
//  Created by Lumi Agent on 2026-02-18.
//

#if os(macOS)
import SwiftUI

struct AgentListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(appState.agents, selection: $appState.selectedAgentId) { agent in
            AgentRowView(agent: agent)
                .tag(agent.id)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Agents")
        .toolbar {
            Button {
                appState.showingNewAgent = true
            } label: {
                Image(systemName: "plus")
            }
            .help("Create a new agent")
        }
        .overlay {
            if appState.agents.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "cpu")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No agents yet")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Button("Create Your First Agent") {
                        appState.showingNewAgent = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct AgentRowView: View {
    @EnvironmentObject var appState: AppState
    let agent: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(agent.name)
                    .font(.headline)
                if appState.isDefaultAgent(agent.id) {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                Spacer()
                StatusBadge(status: agent.status)
            }

            HStack(spacing: 4) {
                Image(systemName: providerIcon)
                    .foregroundStyle(.secondary)
                Text("Powered by \(agent.configuration.provider.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(agent.configuration.model)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var providerIcon: String {
        switch agent.configuration.provider {
        case .openai:    return "brain"
        case .anthropic: return "sparkles"
        case .gemini:    return "atom"
        case .ollama:    return "server.rack"
        }
    }
}

struct StatusBadge: View {
    let status: AgentStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .foregroundColor(.white)
            .clipShape(Capsule())
    }

    private var backgroundColor: Color {
        switch status {
        case .idle: return .gray
        case .running: return .green
        case .paused: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }
}
#endif
