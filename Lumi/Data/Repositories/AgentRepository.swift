//
//  AgentRepository.swift
//  LumiAgent
//
//  Created by Lumi Agent on 2026-02-18.
//

import Foundation

// MARK: - Agent Repository

final class AgentRepository: AgentRepositoryProtocol {
    private let database: DatabaseManager
    private let fileName = "agents.json"

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    private func loadCollection() throws -> SyncCollection<Agent> {
        do {
            return try database.load(SyncCollection<Agent>.self, from: fileName, default: SyncCollection(items: []))
        } catch {
            // Migration: Try loading as old array format
            if let oldArray = try? database.load([Agent].self, from: fileName, default: []) {
                return SyncCollection(items: oldArray)
            }
            throw error
        }
    }

    func create(_ agent: Agent) async throws {
        var collection = try loadCollection()
        collection.items.removeAll { $0.id == agent.id }
        collection.items.append(agent)
        collection.updatedAt = Date()
        try database.save(collection, to: fileName)
    }

    func update(_ agent: Agent) async throws {
        var collection = try loadCollection()
        guard let index = collection.items.firstIndex(where: { $0.id == agent.id }) else { return }
        var updated = agent
        updated.updatedAt = Date()
        collection.items[index] = updated
        collection.updatedAt = Date()
        try database.save(collection, to: fileName)
    }

    func delete(id: UUID) async throws {
        var collection = try loadCollection()
        collection.items.removeAll { $0.id == id }
        collection.updatedAt = Date()
        try database.save(collection, to: fileName)
    }

    func get(id: UUID) async throws -> Agent? {
        let collection = try loadCollection()
        return collection.items.first { $0.id == id }
    }

    func getAll() async throws -> [Agent] {
        let collection = try loadCollection()
        return collection.items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func getByStatus(_ status: AgentStatus) async throws -> [Agent] {
        let collection = try loadCollection()
        return collection.items
            .filter { $0.status == status }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
