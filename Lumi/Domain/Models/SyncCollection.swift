//
//  SyncCollection.swift
//  LumiAgent
//

import Foundation

/// A wrapper for a collection of items that tracks the last modification time
/// of the entire collection, including deletions.
struct SyncCollection<T: Codable>: Codable {
    var items: [T]
    var updatedAt: Date

    init(items: [T], updatedAt: Date = Date()) {
        self.items = items
        self.updatedAt = updatedAt
    }
}
