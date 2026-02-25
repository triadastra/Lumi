//
//  DatabaseManager.swift
//  LumiAgent
//
//  Created by Lumi Agent on 2026-02-18.
//

import Foundation
import Combine

// MARK: - Database Manager

/// File-backed storage manager used by repositories.
final class DatabaseManager {
    static let shared = DatabaseManager()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }()
    private let decoder = JSONDecoder()
    private let ioQueue = DispatchQueue(label: "com.lumiagent.storage", qos: .utility)
    private let baseURL: URL

    private init() {
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        let appFolder = appSupport.appendingPathComponent("LumiAgent", isDirectory: true)
        try? fileManager.createDirectory(at: appFolder, withIntermediateDirectories: true)
        baseURL = appFolder
    }

    private func fileURL(_ name: String) -> URL {
        baseURL.appendingPathComponent(name, isDirectory: false)
    }

    func load<T: Codable>(_ type: T.Type, from name: String, default defaultValue: @autoclosure () -> T) throws -> T {
        try ioQueue.sync {
            let url = fileURL(name)
            guard fileManager.fileExists(atPath: url.path) else {
                return defaultValue()
            }
            let data = try Data(contentsOf: url)
            return try decoder.decode(T.self, from: data)
        }
    }

    func save<T: Codable>(_ value: T, to name: String) throws {
        try ioQueue.sync {
            let url = fileURL(name)
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        }
    }
    
    /// Returns the raw data for a specific database file.
    func rawData(for name: String) -> Data? {
        try? Data(contentsOf: fileURL(name))
    }
}
