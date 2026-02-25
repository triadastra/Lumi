//
//  AgentSpaceView.swift
//  LumiAgent
//
//  Conversation list sidebar for Agent Space.
//

#if os(macOS)
import SwiftUI

// MARK: - Agent Space View (conversation list column)

struct AgentSpaceView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingNewConversation = false
    
    private func isRegularConversation(_ conv: Conversation) -> Bool {
        (conv.title ?? "") != "Hotkey Space"
    }

    var dms: [Conversation] {
        appState.conversations.filter { !$0.isGroup && isRegularConversation($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var groups: [Conversation] {
        appState.conversations.filter { $0.isGroup && isRegularConversation($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var visibleConversationCount: Int {
        appState.conversations.filter(isRegularConversation).count
    }

    var body: some View {
        List(selection: $appState.selectedConversationId) {
            if !dms.isEmpty {
                Section("Direct Messages") {
                    ForEach(dms) { conv in
                        ConversationRow(conv: conv)
                            .tag(conv.id)
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            appState.deleteConversation(id: dms[i].id)
                        }
                    }
                }
            }

            if !groups.isEmpty {
                Section("Groups") {
                    ForEach(groups) { conv in
                        ConversationRow(conv: conv)
                            .tag(conv.id)
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            appState.deleteConversation(id: groups[i].id)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Agent Space")
        .toolbar {
            Button {
                showingNewConversation = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("New conversation")
        }
        .overlay {
            if visibleConversationCount == 0 {
                VStack(spacing: 16) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No conversations yet")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Button("Start a Conversation") {
                        showingNewConversation = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $showingNewConversation) {
            NewConversationView()
                .environmentObject(appState)
        }
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conv: Conversation
    @EnvironmentObject var appState: AppState

    var participants: [Agent] {
        appState.agents.filter { conv.participantIds.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Avatar stack
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(participants.first?.avatarColor ?? .gray)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text((participants.first?.name ?? "?").prefix(1))
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    )

                if conv.isGroup {
                    Circle()
                        .fill(participants.dropFirst().first?.avatarColor ?? .gray)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Text((participants.dropFirst().first?.name ?? "?").prefix(1))
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        )
                        .offset(x: 6, y: 6)
                }
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(conv.displayTitle(agents: appState.agents))
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let last = conv.lastMessage {
                    Text(last.content.isEmpty ? "…" : last.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("No messages")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if let last = conv.lastMessage {
                Text(last.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - New Conversation Sheet

struct NewConversationView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var searchText = ""
    @State private var selectedIds: Set<UUID> = []
    @State private var groupName = ""

    var filteredAgents: [Agent] {
        guard !searchText.isEmpty else { return appState.agents }
        return appState.agents.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var isGroup: Bool { selectedIds.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Text(isGroup ? "New Group" : "New Conversation")
                    .font(.headline)
                Spacer()
                Button(isGroup ? "Create Group" : "Open") {
                    create()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIds.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // Group name field (appears when 2+ selected)
            if isGroup {
                TextField("Group name (optional)", text: $groupName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search agents…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if appState.agents.isEmpty {
                Spacer()
                Text("No agents available.\nCreate an agent first.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filteredAgents) { agent in
                    HStack(spacing: 12) {
                        Image(systemName: selectedIds.contains(agent.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedIds.contains(agent.id) ? Color.accentColor : .secondary)
                            .font(.title3)

                        Circle()
                            .fill(agent.avatarColor)
                            .frame(width: 36, height: 36)
                            .overlay(
                                Text(agent.name.prefix(1))
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.name).font(.body)
                            Text("\(agent.configuration.provider.rawValue) · \(agent.configuration.model)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedIds.contains(agent.id) {
                            selectedIds.remove(agent.id)
                        } else {
                            selectedIds.insert(agent.id)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 420, height: 500)
    }

    private func create() {
        let ids = Array(selectedIds)
        if isGroup {
            _ = appState.createGroup(agentIds: ids, title: groupName.isEmpty ? nil : groupName)
        } else if let id = ids.first {
            _ = appState.createDM(agentId: id)
        }
    }
}
#endif
