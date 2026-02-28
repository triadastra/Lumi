//
//  MCPToolHandlers.swift
//  LumiAgent
//
//  Created by Lumi Agent on 2026-02-18.
//
//  Real implementations for all MCP tool handlers
//

#if os(macOS)
import Foundation
import AppKit
import PDFKit

// MARK: - Path Helpers

private func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

// MARK: - File System Tools

enum FileSystemTools {
    static func createDirectory(path: String) async throws -> String {
        let expanded = expandPath(path)
        try FileManager.default.createDirectory(
            atPath: expanded,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return "Directory created: \(expanded)"
    }

    static func deleteFile(path: String) async throws -> String {
        let expanded = expandPath(path)
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }
        try FileManager.default.removeItem(atPath: expanded)
        return "Deleted: \(expanded)"
    }

    static func moveFile(source: String, destination: String) async throws -> String {
        let src = expandPath(source), dst = expandPath(destination)
        guard FileManager.default.fileExists(atPath: src) else {
            throw ToolError.fileNotFound(src)
        }
        try FileManager.default.moveItem(atPath: src, toPath: dst)
        return "Moved \(src) → \(dst)"
    }

    static func copyFile(source: String, destination: String) async throws -> String {
        let src = expandPath(source), dst = expandPath(destination)
        guard FileManager.default.fileExists(atPath: src) else {
            throw ToolError.fileNotFound(src)
        }
        try FileManager.default.copyItem(atPath: src, toPath: dst)
        return "Copied \(src) → \(dst)"
    }

    static func searchFiles(directory: String, pattern: String) async throws -> String {
        let directory = expandPath(directory)
        let enumerator = FileManager.default.enumerator(atPath: directory)
        var matches: [String] = []
        while let file = enumerator?.nextObject() as? String {
            if file.range(of: pattern, options: .regularExpression) != nil {
                matches.append((directory as NSString).appendingPathComponent(file))
            }
        }
        if matches.isEmpty {
            return "No files matching '\(pattern)' found in \(directory)"
        }
        return matches.joined(separator: "\n")
    }

    static func getFileInfo(path: String) async throws -> String {
        let path = expandPath(path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw ToolError.fileNotFound(path)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = attrs[.size] as? Int ?? 0
        let created = attrs[.creationDate] as? Date
        let modified = attrs[.modificationDate] as? Date
        let fileType = attrs[.type] as? FileAttributeType
        let posixPerms = attrs[.posixPermissions] as? Int ?? 0

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium

        let typeStr: String
        if fileType == .typeDirectory {
            typeStr = "Directory"
        } else if fileType == .typeSymbolicLink {
            typeStr = "Symbolic Link"
        } else {
            typeStr = "File"
        }

        let permsStr = String(posixPerms, radix: 8)

        var lines = [
            "Path: \(path)",
            "Type: \(typeStr)",
            "Size: \(size) bytes (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))",
            "Permissions: \(permsStr)"
        ]
        if let c = created { lines.append("Created: \(formatter.string(from: c))") }
        if let m = modified { lines.append("Modified: \(formatter.string(from: m))") }
        return lines.joined(separator: "\n")
    }

    static func appendToFile(path: String, content: String) async throws -> String {
        let path = expandPath(path)
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            let fileHandle = try FileHandle(forWritingTo: url)
            defer { fileHandle.closeFile() }
            fileHandle.seekToEndOfFile()
            if let data = content.data(using: .utf8) {
                fileHandle.write(data)
            }
        } else {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return "Appended to \(path)"
    }
}

// MARK: - System Tools

enum SystemTools {
    static func getCurrentDatetime() async throws -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .long
        return formatter.string(from: Date())
    }

    static func getSystemInfo() async throws -> String {
        let info = ProcessInfo.processInfo
        let totalRAM = Int64(info.physicalMemory)
        let ramStr = ByteCountFormatter.string(fromByteCount: totalRAM, countStyle: .memory)

        var lines = [
            "Hostname: \(info.hostName)",
            "OS Version: \(info.operatingSystemVersionString)",
            "CPU Cores (logical): \(info.processorCount)",
            "Active Processors: \(info.activeProcessorCount)",
            "Physical Memory: \(ramStr)",
            "Process ID: \(info.processIdentifier)",
            "Uptime: \(Int(info.systemUptime)) seconds"
        ]

        // Try sysctl for CPU brand string
        let executor = ProcessExecutor()
        let cpuResult = try? await executor.execute(
            command: "sysctl",
            arguments: ["-n", "machdep.cpu.brand_string"]
        )
        if let cpuBrand = cpuResult?.output?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cpuBrand.isEmpty {
            lines.insert("CPU: \(cpuBrand)", at: 2)
        }

        return lines.joined(separator: "\n")
    }

    static func listRunningProcesses() async throws -> String {
        let executor = ProcessExecutor()
        // Use /bin/ps directly to avoid env lookup issues with sorting
        let result = try await executor.execute(
            command: "ps",
            arguments: ["aux", "-r"]
        )
        if result.success, let output = result.output {
            let lines = output.components(separatedBy: "\n")
            // Header + top 20 processes
            let selected = Array(lines.prefix(21))
            return selected.joined(separator: "\n")
        } else {
            throw ToolError.commandFailed(result.error ?? "ps failed")
        }
    }

    static func openApplication(name: String) async throws -> String {
        // Sanitize: strip characters that could break the shell script
        let safe = name.replacingOccurrences(of: "\"", with: "")
                       .replacingOccurrences(of: "`", with: "")
                       .replacingOccurrences(of: "$", with: "")
                       .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strategy:
        // 1. open -a "name"          — exact bundle name (fastest)
        // 2. mdfind                  — Spotlight fuzzy search across all volumes
        // 3. find in common dirs     — /Applications, ~/Applications, /System/Applications
        let script = """
        set -e
        if open -a "\(safe)" 2>/dev/null; then
            echo "Opened \(safe)"
            exit 0
        fi
        APP=$(mdfind "kMDItemContentType == 'com.apple.application-bundle'" -name "\(safe)" 2>/dev/null | head -1)
        if [ -n "$APP" ]; then
            open "$APP"
            echo "Opened $APP"
            exit 0
        fi
        APP=$(find /Applications ~/Applications /System/Applications /System/Library/CoreServices -maxdepth 4 -iname "*\(safe)*.app" 2>/dev/null | head -1)
        if [ -n "$APP" ]; then
            open "$APP"
            echo "Opened $APP"
            exit 0
        fi
        echo "Could not find application: \(safe)" >&2
        exit 1
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ToolError.commandFailed(err.isEmpty ? "Could not open \(safe)" : err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func openURL(url: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "open \"\(url)\""]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            return "Opened URL: \(url)"
        } else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ToolError.commandFailed(err.isEmpty ? "Could not open \(url)" : err)
        }
    }
}

// MARK: - Network Tools

enum NetworkTools {
    static func fetchURL(url urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw ToolError.invalidURL(urlString)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "<binary data>"
        let truncated = body.count > 8000 ? String(body.prefix(8000)) + "\n...[truncated]" : body
        return "Status: \(statusCode)\n\n\(truncated)"
    }

    static func httpRequest(
        url urlString: String,
        method: String,
        headers: String?,
        body: String?
    ) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw ToolError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()

        // Parse headers JSON
        if let headersJSON = headers,
           let headersData = headersJSON.data(using: .utf8),
           let headersDict = try? JSONSerialization.jsonObject(with: headersData) as? [String: String] {
            for (key, value) in headersDict {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Set body
        if let body = body {
            request.httpBody = body.data(using: .utf8)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let responseHeaders = (response as? HTTPURLResponse)?.allHeaderFields as? [String: String] ?? [:]
        let responseBody = String(data: data, encoding: .utf8) ?? "<binary data>"
        let truncated = responseBody.count > 8000 ? String(responseBody.prefix(8000)) + "\n...[truncated]" : responseBody

        var result = "Status: \(statusCode)\n"
        result += "Headers: \(responseHeaders)\n\n"
        result += truncated
        return result
    }

    static func webSearch(query: String) async throws -> String {
        let braveKey = UserDefaults.standard.string(forKey: "settings.braveAPIKey") ?? ""
        if !braveKey.isEmpty {
            return try await braveSearch(query: query, apiKey: braveKey)
        }
        return try await duckDuckGoSearch(query: query)
    }

    private static func braveSearch(query: String, apiKey: String) async throws -> String {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.search.brave.com/res/v1/web/search?q=\(encoded)&count=10")
        else { throw ToolError.invalidURL(query) }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]], !results.isEmpty
        else { return "No Brave results found for: \(query)" }

        var output = "Search results for '\(query)':\n\n"
        for (i, r) in results.prefix(10).enumerated() {
            let title = r["title"] as? String ?? "No title"
            let url   = r["url"]   as? String ?? ""
            let desc  = r["description"] as? String ?? ""
            output += "\(i + 1). \(title)\n   \(url)\n   \(desc)\n\n"
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func duckDuckGoSearch(query: String) async throws -> String {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1")
        else { throw ToolError.invalidURL(query) }

        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "No results found for: \(query)"
        }

        var output = ""
        if let abstract = json["AbstractText"] as? String, !abstract.isEmpty {
            output += "Summary:\n\(abstract)\n\n"
        }
        if let related = json["RelatedTopics"] as? [[String: Any]] {
            let texts = related.compactMap { $0["Text"] as? String }.filter { !$0.isEmpty }.prefix(5)
            if !texts.isEmpty {
                output += "Related:\n" + texts.map { "- \($0)" }.joined(separator: "\n")
            }
        }
        return output.isEmpty ? "No results found for: \(query) — add a Brave API key in Settings for better results." : output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Git Tools

enum GitTools {
    static func status(directory: String) async throws -> String {
        let executor = ProcessExecutor()
        let workDir = URL(fileURLWithPath: directory)
        let result = try await executor.execute(
            command: "git",
            arguments: ["status"],
            workingDirectory: workDir
        )
        if result.success {
            return result.output ?? ""
        } else {
            throw ToolError.commandFailed(result.error ?? "git status failed")
        }
    }

    static func log(directory: String, limit: Int) async throws -> String {
        let executor = ProcessExecutor()
        let workDir = URL(fileURLWithPath: directory)
        let result = try await executor.execute(
            command: "git",
            arguments: ["log", "--oneline", "-\(limit)"],
            workingDirectory: workDir
        )
        if result.success {
            return result.output ?? ""
        } else {
            throw ToolError.commandFailed(result.error ?? "git log failed")
        }
    }

    static func diff(directory: String, staged: Bool) async throws -> String {
        let executor = ProcessExecutor()
        let workDir = URL(fileURLWithPath: directory)
        var args = ["diff"]
        if staged { args.append("--staged") }
        let result = try await executor.execute(
            command: "git",
            arguments: args,
            workingDirectory: workDir
        )
        if result.success {
            let output = result.output ?? ""
            return output.isEmpty ? "No changes" : output
        } else {
            throw ToolError.commandFailed(result.error ?? "git diff failed")
        }
    }

    static func commit(directory: String, message: String) async throws -> String {
        let executor = ProcessExecutor()
        let workDir = URL(fileURLWithPath: directory)

        // Stage all changes
        let addResult = try await executor.execute(
            command: "git",
            arguments: ["add", "-A"],
            workingDirectory: workDir
        )
        if !addResult.success {
            throw ToolError.commandFailed(addResult.error ?? "git add failed")
        }

        // Commit
        let commitResult = try await executor.execute(
            command: "git",
            arguments: ["commit", "-m", message],
            workingDirectory: workDir
        )
        if commitResult.success {
            return commitResult.output ?? "Committed successfully"
        } else {
            throw ToolError.commandFailed(commitResult.error ?? "git commit failed")
        }
    }

    static func branch(directory: String, create: String?) async throws -> String {
        let executor = ProcessExecutor()
        let workDir = URL(fileURLWithPath: directory)
        if let branchName = create {
            let result = try await executor.execute(
                command: "git",
                arguments: ["checkout", "-b", branchName],
                workingDirectory: workDir
            )
            if result.success {
                return result.output ?? "Branch '\(branchName)' created and checked out"
            } else {
                throw ToolError.commandFailed(result.error ?? "git branch failed")
            }
        } else {
            let result = try await executor.execute(
                command: "git",
                arguments: ["branch", "-a"],
                workingDirectory: workDir
            )
            if result.success {
                return result.output ?? ""
            } else {
                throw ToolError.commandFailed(result.error ?? "git branch failed")
            }
        }
    }

    static func clone(url: String, destination: String) async throws -> String {
        let executor = ProcessExecutor()
        let result = try await executor.execute(
            command: "git",
            arguments: ["clone", url, destination]
        )
        if result.success {
            return result.output ?? "Cloned \(url) to \(destination)"
        } else {
            throw ToolError.commandFailed(result.error ?? "git clone failed")
        }
    }
}

// MARK: - Data Tools

enum DataTools {
    static func searchInFile(path: String, pattern: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ToolError.fileNotFound(path)
        }
        let executor = ProcessExecutor()
        let result = try await executor.execute(
            command: "grep",
            arguments: ["-n", "-C", "2", pattern, path]
        )
        if result.success {
            let output = result.output ?? ""
            return output.isEmpty ? "No matches found for '\(pattern)' in \(path)" : output
        } else {
            // grep returns exit code 1 when no matches, which ProcessExecutor treats as failure
            return "No matches found for '\(pattern)' in \(path)"
        }
    }

    static func replaceInFile(path: String, search: String, replacement: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ToolError.fileNotFound(path)
        }
        let url = URL(fileURLWithPath: path)
        let content = try String(contentsOf: url, encoding: .utf8)
        let count = content.components(separatedBy: search).count - 1
        if count == 0 {
            return "Pattern '\(search)' not found in \(path)"
        }
        let newContent = content.replacingOccurrences(of: search, with: replacement)
        try newContent.write(to: url, atomically: true, encoding: .utf8)
        return "Replaced \(count) occurrence(s) of '\(search)' with '\(replacement)' in \(path)"
    }

    static func calculate(expression: String) async throws -> String {
        let executor = ProcessExecutor()
        let code = "import math; print(\(expression))"
        let result = try await executor.execute(
            command: "python3",
            arguments: ["-c", code]
        )
        if result.success {
            return result.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } else {
            throw ToolError.commandFailed(result.error ?? "Calculation failed")
        }
    }

    static func parseJSON(input: String) async throws -> String {
        guard let data = input.data(using: .utf8) else {
            throw ToolError.commandFailed("Invalid input string")
        }
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        let prettyData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        return String(data: prettyData, encoding: .utf8) ?? input
    }

    static func encodeBase64(input: String) async throws -> String {
        guard let data = input.data(using: .utf8) else {
            throw ToolError.commandFailed("Invalid input string")
        }
        return data.base64EncodedString()
    }

    static func decodeBase64(input: String) async throws -> String {
        guard let data = Data(base64Encoded: input),
              let decoded = String(data: data, encoding: .utf8) else {
            throw ToolError.commandFailed("Invalid Base64 input")
        }
        return decoded
    }

    static func countLines(path: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ToolError.fileNotFound(path)
        }
        let content = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        let count = content.components(separatedBy: "\n").count
        return "\(count) lines in \(path)"
    }
}

// MARK: - Clipboard Tools

enum ClipboardTools {
    @MainActor
    static func read() async throws -> String {
        let pb = NSPasteboard.general
        return pb.string(forType: .string) ?? ""
    }

    @MainActor
    static func write(content: String) async throws -> String {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(content, forType: .string)
        return "Written to clipboard: \(content.prefix(100))\(content.count > 100 ? "..." : "")"
    }
}

// MARK: - Media Tools

enum MediaTools {
    static func takeScreenshot(path: String) async throws -> String {
        let destination: String
        if path.isEmpty {
            destination = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/screenshot.png")
        } else {
            destination = path
        }
        let executor = ProcessExecutor()
        let result = try await executor.execute(
            command: "/usr/sbin/screencapture",
            arguments: ["-x", destination]
        )
        if result.success {
            return "Screenshot saved to \(destination)"
        } else {
            throw ToolError.commandFailed(result.error ?? "screencapture failed")
        }
    }
}

// MARK: - Code Tools

enum CodeTools {
    static func runPython(code: String) async throws -> String {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi_\(UUID().uuidString).py")
        try code.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let executor = ProcessExecutor()
        let result = try await executor.execute(
            command: "python3",
            arguments: [tmpFile.path]
        )
        if result.success {
            return result.output ?? ""
        } else {
            throw ToolError.commandFailed(result.error ?? "Python execution failed")
        }
    }

    static func runNode(code: String) async throws -> String {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi_\(UUID().uuidString).js")
        try code.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let executor = ProcessExecutor()
        let result = try await executor.execute(
            command: "node",
            arguments: [tmpFile.path]
        )
        if result.success {
            return result.output ?? ""
        } else {
            throw ToolError.commandFailed(result.error ?? "Node execution failed")
        }
    }
}

// MARK: - Memory Tools

enum MemoryTools {
    private static let prefix = "lumiagent.memory."

    static func save(key: String, value: String) async throws -> String {
        UserDefaults.standard.set(value, forKey: prefix + key)
        return "Saved '\(key)'"
    }

    static func read(key: String) async throws -> String {
        guard let value = UserDefaults.standard.string(forKey: prefix + key) else {
            return "Key '\(key)' not found in memory"
        }
        return value
    }

    static func list() async throws -> String {
        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
        if allKeys.isEmpty {
            return "No keys stored in memory"
        }
        return allKeys.joined(separator: "\n")
    }

    static func delete(key: String) async throws -> String {
        let fullKey = prefix + key
        guard UserDefaults.standard.object(forKey: fullKey) != nil else {
            return "Key '\(key)' not found in memory"
        }
        UserDefaults.standard.removeObject(forKey: fullKey)
        return "Deleted '\(key)' from memory"
    }
}

// MARK: - Bluetooth Tools

enum BluetoothTools {

    /// List all paired Bluetooth devices and their connection status.
    static func listDevices() async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "system_profiler SPBluetoothDataType 2>/dev/null"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return raw.isEmpty ? "No Bluetooth information available." : raw
    }

    /// Connect or disconnect a paired device by name or MAC address.
    /// Requires `blueutil` (brew install blueutil).
    static func connectDevice(device: String, action: String) async throws -> String {
        let act = action.lowercased()
        guard act == "connect" || act == "disconnect" else {
            throw ToolError.commandFailed("action must be 'connect' or 'disconnect'")
        }
        // Locate blueutil
        let which = try await shell("which blueutil 2>/dev/null || echo ''")
        let blueutilPath = which.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !blueutilPath.isEmpty else {
            return """
            blueutil is not installed. Install it with:
              brew install blueutil
            Then retry: bluetooth_connect device=\"\(device)\" action=\"\(action)\"
            """
        }
        let cmd = "\(blueutilPath) --\(act) \"\(device)\""
        let result = try await shell(cmd)
        return result.isEmpty ? "\(act.capitalized)ed \(device)" : result
    }

    /// Scan for discoverable nearby Bluetooth devices (10-second inquiry).
    /// Requires `blueutil` (brew install blueutil).
    static func scanDevices() async throws -> String {
        let which = try await shell("which blueutil 2>/dev/null || echo ''")
        let blueutilPath = which.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !blueutilPath.isEmpty else {
            return "blueutil is not installed. Install with: brew install blueutil"
        }
        let result = try await shell("\(blueutilPath) --inquiry --format new-json 2>/dev/null || \(blueutilPath) --inquiry")
        return result.isEmpty ? "No devices found nearby." : result
    }

    private static func shell(_ cmd: String) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", cmd]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Volume Tools

enum VolumeTools {

    static func getVolume() async throws -> String {
        let script = "get volume settings"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run(); proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "Volume settings: \(out)"
    }

    static func setVolume(level: Int) async throws -> String {
        let clamped = max(0, min(100, level))
        let script = "set volume output volume \(clamped)"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try proc.run(); proc.waitUntilExit()
        return "Volume set to \(clamped)%"
    }

    static func setMute(muted: Bool) async throws -> String {
        let script = muted
            ? "set volume with output muted"
            : "set volume without output muted"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try proc.run(); proc.waitUntilExit()
        return muted ? "Audio muted." : "Audio unmuted."
    }

    /// List all audio output devices.
    static func listAudioDevices() async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "system_profiler SPAudioDataType 2>/dev/null"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run(); proc.waitUntilExit()
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return raw.isEmpty ? "No audio device information available." : raw
    }

    /// Switch the system audio output device by name.
    /// Requires `SwitchAudioSource` (brew install switchaudio-osx).
    static func setOutputDevice(device: String) async throws -> String {
        let which = try? await shell("which SwitchAudioSource 2>/dev/null || echo ''")
        let tool = (which ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else {
            return """
            SwitchAudioSource is not installed. Install it with:
              brew install switchaudio-osx
            Then retry: set_audio_output device=\"\(device)\"
            Available devices can be found with: list_audio_devices
            """
        }
        let result = try await shell("\(tool) -s \"\(device)\"")
        return result.isEmpty ? "Switched audio output to \(device)" : result
    }

    private static func shell(_ cmd: String) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", cmd]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Media Control Tools

enum MediaControlTools {

    /// Play, pause, toggle, next, previous, or stop media in Spotify, Music, or any running player.
    static func control(action: String, app: String?) async throws -> String {
        let act = action.lowercased()

        // Determine which app to target
        let target: String
        if let a = app, !a.isEmpty {
            target = a
        } else {
            // Auto-detect: prefer Spotify, then Music, then any running media app
            let running = try? await shell(
                "osascript -e 'tell application \"System Events\" to get name of every process whose background only is false'"
            )
            let procs = running ?? ""
            if procs.contains("Spotify") { target = "Spotify" }
            else if procs.contains("Music") { target = "Music" }
            else if procs.contains("Podcasts") { target = "Podcasts" }
            else { target = "Music" }
        }

        let command: String
        switch act {
        case "play":          command = "tell application \"\(target)\" to play"
        case "pause":         command = "tell application \"\(target)\" to pause"
        case "toggle", "playpause":
            command = "tell application \"\(target)\" to playpause"
        case "next", "next track":
            command = "tell application \"\(target)\" to next track"
        case "previous", "prev", "previous track":
            command = "tell application \"\(target)\" to previous track"
        case "stop":          command = "tell application \"\(target)\" to stop"
        default:
            throw ToolError.commandFailed("Unknown action '\(action)'. Use: play, pause, toggle, next, previous, stop")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", command]
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return "\(act.capitalized) sent to \(target)."
    }

    private static func shell(_ cmd: String) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", cmd]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Screen Control Tools
// Requires Accessibility access: System Settings → Privacy & Security → Accessibility → LumiAgent

enum ScreenControlTools {

    // MARK: Screen Info

    static func getScreenInfo() async throws -> String {
        let info = await MainActor.run { () -> (Int, Int, Int, Int, String) in
            let frame = NSScreen.main?.frame ?? .init(x: 0, y: 0, width: 1440, height: 900)
            let loc = NSEvent.mouseLocation
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
            let cursorY = Int(frame.height) - Int(loc.y)
            return (Int(frame.width), Int(frame.height), Int(loc.x), cursorY, front)
        }
        return """
        Screen size: \(info.0)×\(info.1) (coordinates: top-left origin)
        Cursor position: (\(info.2), \(info.3))
        Frontmost app: \(info.4)
        """
    }

    // MARK: Mouse Control

    /// Convert tool coordinates (top-left origin, px from top-left of NSScreen.main) to
    /// global CGEvent coordinates (top-left origin of primary display, Y increases downward).
    ///
    /// CGEvent is NOT Quartz/NSScreen — it uses top-left origin.
    /// NSScreen uses bottom-left origin (Y upward, Cartesian).
    ///
    /// For a screen at NSScreen frame (ox, oy, w, h), a point (x, y) measured from its
    /// top-left corner maps to CGEvent global coords:
    ///   CGEvent.x = ox + x
    ///   CGEvent.y = primaryH - oy - h + y        (where primaryH = height of primary display)
    ///
    /// For the primary display (oy=0, h=primaryH): CGEvent.y = y — no flip, passes through.
    private static func toQuartzPoint(x: Double, y: Double, frame: CGRect) -> CGPoint {
        // Primary display always has NSScreen frame.origin = (0, 0).
        let primaryH = NSScreen.screens
            .first { $0.frame.origin.x == 0 && $0.frame.origin.y == 0 }
            .map { $0.frame.height }
            ?? frame.height
        return CGPoint(
            x: frame.origin.x + x,
            y: primaryH - frame.origin.y - frame.height + y
        )
    }

    /// Move mouse cursor. Coordinates: (0,0) = top-left of screen.
    static func moveMouse(x: Double, y: Double) async throws -> String {
        let frame = await MainActor.run { NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900) }
        let point = toQuartzPoint(x: x, y: y, frame: frame)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        return "Mouse moved to (\(Int(x)), \(Int(y)))"
    }

    /// Click at position. button: "left" or "right". clicks: 1 or 2 for double-click.
    static func clickMouse(x: Double, y: Double, button: String, clicks: Int) async throws -> String {
        let frame = await MainActor.run { NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900) }
        let point = toQuartzPoint(x: x, y: y, frame: frame)
        let isRight = button.lowercased() == "right"
        let btn: CGMouseButton = isRight ? .right : .left
        let downType: CGEventType = isRight ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = isRight ? .rightMouseUp : .leftMouseUp

        let count = max(1, min(clicks, 2))
        for clickState in 1...count {
            let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                               mouseCursorPosition: point, mouseButton: btn)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                             mouseCursorPosition: point, mouseButton: btn)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
        let clickWord = count == 2 ? "Double-clicked" : "Clicked"
        return "\(clickWord) \(button) button at (\(Int(x)), \(Int(y)))"
    }

    /// Scroll at position. Positive deltaY = scroll up, negative = scroll down.
    static func scrollMouse(x: Double, y: Double, deltaX: Int, deltaY: Int) async throws -> String {
        let frame = await MainActor.run { NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900) }
        let point = toQuartzPoint(x: x, y: y, frame: frame)
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: Int32(deltaY), wheel2: Int32(deltaX), wheel3: 0)
        event?.location = point
        event?.post(tap: .cghidEventTap)
        return "Scrolled at (\(Int(x)), \(Int(y))): deltaY=\(deltaY), deltaX=\(deltaX)"
    }

    // MARK: Keyboard Control

    /// Type a string of text using AppleScript's keystroke command.
    static func typeText(text: String) async throws -> String {
        let safe = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "System Events"
            keystroke "\(safe)"
        end tell
        """
        try await runAppleScript(script: script)
        return "Typed: \(text)"
    }

    /// Press a named key (e.g. "return", "tab", "escape", "a") with optional modifier keys.
    /// modifiers: comma-separated list of "command", "shift", "option", "control"
    static func pressKey(key: String, modifiers: String) async throws -> String {
        let mods = modifiers
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .compactMap { mod -> String? in
                switch mod {
                case "command", "cmd": return "command down"
                case "shift": return "shift down"
                case "option", "alt": return "option down"
                case "control", "ctrl": return "control down"
                case "": return nil
                default: return nil
                }
            }
        let code = keyNameToCode(key)
        let modStr = mods.isEmpty ? "" : " using {\(mods.joined(separator: ", "))}"
        let script = """
        tell application "System Events"
            key code \(code)\(modStr)
        end tell
        """
        try await runAppleScript(script: script)
        return "Pressed key: \(key)\(modifiers.isEmpty ? "" : " + \(modifiers)")"
    }

    // MARK: AppleScript

    /// Run arbitrary AppleScript and return the result.
    @discardableResult
    static func runAppleScript(script: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var errDict: NSDictionary?
                let appleScript = NSAppleScript(source: script)
                if let result = appleScript?.executeAndReturnError(&errDict) {
                    cont.resume(returning: result.stringValue ?? "(script completed, no return value)")
                } else {
                    let msg = errDict?["NSAppleScriptErrorMessage"] as? String
                        ?? "AppleScript execution failed"
                    cont.resume(throwing: ToolError.commandFailed(msg))
                }
            }
        }
    }

    // MARK: - iWork Tools (Pages, Numbers, Keynote)

    /// Write text to the active iWork document at the cursor position.
    static func iworkWriteText(text: String) async throws -> String {
        let safe = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let script = """
        tell application "System Events"
            tell process "Pages" to set frontmost to true
            keystroke "\(safe)"
        end tell
        """
        _ = try await runAppleScript(script: script)
        return "Text written to iWork document: \(text.prefix(100))"
    }

    /// Get information about the active iWork document (name, word count, etc).
    static func iworkGetDocumentInfo() async throws -> String {
        let script = """
        tell application "System Events"
            set frontmostApp to name of (first application process whose frontmost is true)
        end tell

        if frontmostApp contains "Pages" then
            tell application "Pages"
                if (count of documents) > 0 then
                    set activeDoc to document 1
                    set docName to name of activeDoc
                    return "Document: " & docName
                else
                    return "No active Pages document"
                end if
            end tell
        else if frontmostApp contains "Numbers" then
            tell application "Numbers"
                if (count of documents) > 0 then
                    set activeDoc to document 1
                    set docName to name of activeDoc
                    return "Spreadsheet: " & docName
                else
                    return "No active Numbers document"
                end if
            end tell
        else if frontmostApp contains "Keynote" then
            tell application "Keynote"
                if (count of presentations) > 0 then
                    set activePresentation to presentation 1
                    set docName to name of activePresentation
                    return "Presentation: " & docName
                else
                    return "No active Keynote presentation"
                end if
            end tell
        else
            return "No iWork app is currently active"
        end if
        """
        return try await runAppleScript(script: script)
    }

    /// Replace text in the active iWork document using find and replace.
    static func iworkReplaceText(findText: String, replaceText: String, allOccurrences: Bool = true) async throws -> String {
        let findSafe = findText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let replaceSafe = replaceText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "System Events"
            set frontmostApp to name of (first application process whose frontmost is true)
        end tell

        if frontmostApp contains "Pages" then
            tell application "Pages"
                activate
                tell application "System Events"
                    keystroke "f" using command down
                    delay 0.5
                    keystroke "\(findSafe)"
                    delay 0.3
                    key code 48 -- Tab to replace field
                    keystroke "\(replaceSafe)"
                    delay 0.2
                    \(allOccurrences ? "keystroke \"a\" using command down -- Replace All" : "keystroke \"&\" using command down -- Replace")
                    delay 0.3
                    key code 53 -- Escape to close find dialog
                end tell
                return "Text replaced in Pages document"
            end tell
        else
            return "Find and replace is only supported in Pages currently"
        end if
        """
        return try await runAppleScript(script: script)
    }

    /// Insert text at a specific position or after finding an anchor text in Pages/iWork.
    static func iworkInsertAfterAnchor(anchorText: String, newText: String) async throws -> String {
        let anchorSafe = anchorText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let newTextSafe = newText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        let script = """
        tell application "Pages"
            activate
            tell application "System Events"
                keystroke "f" using command down -- Open Find
                delay 0.5
                keystroke "\(anchorSafe)"
                delay 0.2
                key code 36 -- Return to find first occurrence
                delay 0.3
                key code 53 -- Escape to close find
                delay 0.2
                key code 124 -- Right arrow to go past anchor text
                delay 0.1
                key code 36 -- Enter a new line
                keystroke "\(newTextSafe)"
            end tell
        end tell
        """
        return try await runAppleScript(script: script)
    }

    // MARK: Key Code Lookup

    private static func keyNameToCode(_ name: String) -> Int {
        switch name.lowercased() {
        case "a": return 0;  case "s": return 1;  case "d": return 2;  case "f": return 3
        case "h": return 4;  case "g": return 5;  case "z": return 6;  case "x": return 7
        case "c": return 8;  case "v": return 9;  case "b": return 11; case "q": return 12
        case "w": return 13; case "e": return 14; case "r": return 15; case "y": return 16
        case "t": return 17; case "1": return 18; case "2": return 19; case "3": return 20
        case "4": return 21; case "6": return 22; case "5": return 23; case "=": return 24
        case "9": return 25; case "7": return 26; case "-": return 27; case "8": return 28
        case "0": return 29; case "o": return 31; case "u": return 32; case "i": return 34
        case "p": return 35; case "l": return 37; case "j": return 38; case "k": return 40
        case "n": return 45; case "m": return 46; case "return", "enter": return 36
        case "tab": return 48; case "space": return 49; case "delete", "backspace": return 51
        case "escape", "esc": return 53; case "left": return 123; case "right": return 124
        case "down": return 125; case "up": return 126; case "home": return 115
        case "end": return 119; case "pageup": return 116; case "pagedown": return 121
        case "f1": return 122; case "f2": return 120; case "f3": return 99; case "f4": return 118
        case "f5": return 96;  case "f6": return 97;  case "f7": return 98; case "f8": return 100
        default: return 36
        }
    }
}

// MARK: - Document Tools
// Read text from PDF, Word, PowerPoint, and other document formats.

enum DocumentTools {

    /// Extract text from a PDF using PDFKit (native macOS, no dependencies).
    static func readPDF(path: String) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }
        let url = URL(fileURLWithPath: expanded)
        guard let pdf = PDFDocument(url: url) else {
            throw ToolError.commandFailed("Could not open PDF: \(expanded). File may be corrupt or password-protected.")
        }
        var pages: [String] = []
        for i in 0..<pdf.pageCount {
            if let page = pdf.page(at: i),
               let text = page.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append("=== Page \(i + 1) ===\n\(text)")
            }
        }
        if pages.isEmpty {
            return "PDF has \(pdf.pageCount) page(s) but no extractable text. The PDF may be scanned/image-based — use take_screenshot or open it to view visually. Path: \(expanded)"
        }
        return "[PDF: \(expanded) — \(pdf.pageCount) page(s)]\n\n" + pages.joined(separator: "\n\n")
    }

    /// Extract text from Word, RTF, or ODT documents using macOS textutil (no dependencies).
    /// Supports: .doc, .docx, .rtf, .odt
    static func readWord(path: String) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }
        let ext = (expanded as NSString).pathExtension.lowercased()
        guard ["doc", "docx", "rtf", "odt"].contains(ext) else {
            throw ToolError.commandFailed("Expected .doc, .docx, .rtf, or .odt — got .\(ext). Use read_document for auto-detection.")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        proc.arguments = ["-convert", "txt", "-stdout", expanded]
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ToolError.commandFailed("textutil failed for \(expanded): \(err.isEmpty ? "unknown error" : err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "(Document is empty or contains no extractable text)"
            : "[\(ext.uppercased()): \(expanded)]\n\n\(trimmed)"
    }

    /// Extract text from PowerPoint (.pptx) by parsing its internal XML.
    /// Falls back to textutil for legacy .ppt.
    static func readPPT(path: String) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }
        let ext = (expanded as NSString).pathExtension.lowercased()
        guard ["pptx", "ppt"].contains(ext) else {
            throw ToolError.commandFailed("Expected .pptx or .ppt — got .\(ext). Use read_document for auto-detection.")
        }

        if ext == "pptx" {
            // PPTX is a ZIP archive — extract slide text from XML using Python
            let pythonCode = """
import zipfile, re, sys
path = sys.argv[1]
try:
    with zipfile.ZipFile(path) as z:
        slides = sorted([n for n in z.namelist() if n.startswith('ppt/slides/slide') and n.endswith('.xml')])
        if not slides:
            print('(No slides found in PPTX)')
            sys.exit(0)
        results = []
        for i, slide in enumerate(slides, 1):
            content = z.read(slide).decode('utf-8', errors='replace')
            texts = [t for t in re.findall(r'<a:t[^>]*>([^<]+)</a:t>', content) if t.strip()]
            if texts:
                results.append(f'=== Slide {i} ===')
                results.extend(texts)
        print('\\n'.join(results) if results else '(No text found in any slide)')
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
"""
            let tmpPy = FileManager.default.temporaryDirectory
                .appendingPathComponent("lumi_ppt_\(UUID().uuidString).py")
            try pythonCode.write(to: tmpPy, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmpPy) }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [tmpPy.path, expanded]
            let outPipe = Pipe(), errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            proc.waitUntilExit()

            let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if proc.terminationStatus != 0 {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw ToolError.commandFailed("Could not parse PPTX: \(err.isEmpty ? "unknown error" : err)")
            }
            return "[PPTX: \(expanded)]\n\n\(output.isEmpty ? "(No text content found)" : output)"
        } else {
            // Legacy .ppt binary format — try textutil as best effort
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            proc.arguments = ["-convert", "txt", "-stdout", expanded]
            let outPipe = Pipe(), errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            proc.waitUntilExit()
            let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if proc.terminationStatus == 0 && !output.isEmpty {
                return "[PPT (legacy): \(expanded)]\n\n\(output)"
            }
            throw ToolError.commandFailed(
                "Cannot extract text from legacy .ppt binary format at \(expanded). " +
                "Convert to .pptx first (open in Keynote/PowerPoint → Export as .pptx), then retry."
            )
        }
    }

    /// Smart document reader — auto-detects format by extension and extracts text.
    /// Handles PDF, Word (.doc/.docx/.rtf), PowerPoint (.pptx), plain text/code files,
    /// and attempts textutil conversion for other formats. Reports metadata for binaries.
    static func readDocument(path: String) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }
        let ext = (expanded as NSString).pathExtension.lowercased()

        switch ext {
        case "pdf":
            return try await readPDF(path: expanded)
        case "doc", "docx", "rtf", "odt":
            return try await readWord(path: expanded)
        case "pptx", "ppt":
            return try await readPPT(path: expanded)
        case "xlsx", "xls":
            return try await readExcel(path: expanded)
        case "csv", "tsv":
            let content = try String(contentsOfFile: expanded, encoding: .utf8)
            let preview = content.count > 20_000
                ? String(content.prefix(20_000)) + "\n...[truncated at 20,000 chars — file has \(content.count) chars total]"
                : content
            return "[\(ext.uppercased()): \(expanded)]\n\n\(preview)"
        case "pages", "numbers", "key":
            return try await readIWork(path: expanded, ext: ext)
        case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "svg", "ico":
            return try await readImageMetadata(path: expanded)
        case "txt", "md", "markdown", "json", "xml", "html", "htm",
             "yaml", "yml", "toml", "ini", "cfg", "conf", "log", "env",
             "swift", "py", "js", "ts", "tsx", "jsx", "java", "c", "cpp", "h", "hpp", "m", "mm",
             "sh", "bash", "zsh", "rb", "go", "rs", "kt", "kts", "cs", "php", "pl", "pm",
             "r", "R", "lua", "sql", "scala", "groovy", "gradle",
             "dart", "ex", "exs", "erl", "hrl", "hs", "ml", "mli", "fs", "fsx",
             "vue", "svelte", "astro", "sass", "scss", "less", "css", "styl",
             "makefile", "cmake", "dockerfile",
             "proto", "graphql", "gql", "wasm", "wat",
             "tex", "bib", "sty", "cls",
             "gitignore", "gitattributes", "editorconfig", "eslintrc", "prettierrc",
             "lock", "sum", "mod", "bazel", "bzl", "tf", "tfvars", "hcl",
             "plist", "strings", "storyboard", "xib", "entitlements", "pbxproj", "xcscheme",
             "patch", "diff":
            let content = try String(contentsOfFile: expanded, encoding: .utf8)
            let preview = content.count > 20_000
                ? String(content.prefix(20_000)) + "\n...[truncated at 20,000 chars — file has \(content.count) chars total]"
                : content
            return "[\(ext.uppercased()): \(expanded)]\n\n\(preview)"
        default:
            // Try textutil as a general-purpose converter (handles many Office formats)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            proc.arguments = ["-convert", "txt", "-stdout", expanded]
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()
            let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if proc.terminationStatus == 0 && !output.isEmpty {
                return "[.\(ext) via textutil: \(expanded)]\n\n\(output)"
            }
            // Last resort: try plain UTF-8 text
            if let text = try? String(contentsOfFile: expanded, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let preview = text.count > 20_000 ? String(text.prefix(20_000)) + "...[truncated]" : text
                return "[Plain text .\(ext): \(expanded)]\n\n\(preview)"
            }
            // Give up — report metadata only
            let attrs = try? FileManager.default.attributesOfItem(atPath: expanded)
            let size = attrs?[.size] as? Int ?? 0
            let fmt = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            return "Cannot extract text from .\(ext) file at \(expanded) (\(fmt)). " +
                   "The file is likely binary or uses a proprietary format. " +
                   "Use get_file_info for metadata, or open the file in its native application."
        }
    }

    /// Extract data from Excel spreadsheets (.xlsx, .xls) and CSV files.
    static func readExcel(path: String) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }
        let ext = (expanded as NSString).pathExtension.lowercased()

        if ext == "csv" {
            let content = try String(contentsOfFile: expanded, encoding: .utf8)
            let preview = content.count > 20_000
                ? String(content.prefix(20_000)) + "\n...[truncated at 20,000 chars]"
                : content
            return "[CSV: \(expanded)]\n\n\(preview)"
        }

        // Use Python to read xlsx/xls — openpyxl for xlsx, csv fallback for xls
        let pythonCode: String
        if ext == "xlsx" {
            pythonCode = """
import sys, os
path = sys.argv[1]
try:
    from openpyxl import load_workbook
    wb = load_workbook(path, read_only=True, data_only=True)
    results = []
    for sheet_name in wb.sheetnames:
        ws = wb[sheet_name]
        results.append(f"=== Sheet: {sheet_name} ===")
        row_count = 0
        for row in ws.iter_rows(values_only=True):
            cells = [str(c) if c is not None else "" for c in row]
            results.append("\\t".join(cells))
            row_count += 1
            if row_count >= 5000:
                results.append(f"...[truncated at 5000 rows]")
                break
    wb.close()
    print("\\n".join(results))
except ImportError:
    # Fallback: parse xlsx as zip with shared strings
    import zipfile, re
    try:
        with zipfile.ZipFile(path) as z:
            # Read shared strings
            strings = []
            if 'xl/sharedStrings.xml' in z.namelist():
                ss_xml = z.read('xl/sharedStrings.xml').decode('utf-8', errors='replace')
                strings = re.findall(r'<t[^>]*>([^<]+)</t>', ss_xml)
            # Read sheets
            sheet_files = sorted([n for n in z.namelist() if n.startswith('xl/worksheets/sheet') and n.endswith('.xml')])
            results = []
            for i, sf in enumerate(sheet_files, 1):
                results.append(f"=== Sheet {i} ===")
                content = z.read(sf).decode('utf-8', errors='replace')
                rows = re.findall(r'<row[^>]*>(.*?)</row>', content, re.DOTALL)
                for row in rows[:5000]:
                    cells = []
                    for cell in re.findall(r'<c[^>]*>(.*?)</c>', row, re.DOTALL):
                        val_match = re.search(r'<v>([^<]+)</v>', cell)
                        if val_match:
                            val = val_match.group(1)
                            # Check if it's a shared string reference
                            if 't="s"' in row or (val.isdigit() and int(val) < len(strings)):
                                try:
                                    cells.append(strings[int(val)])
                                except (IndexError, ValueError):
                                    cells.append(val)
                            else:
                                cells.append(val)
                        else:
                            cells.append("")
                    results.append("\\t".join(cells))
            print("\\n".join(results) if results else "(No data found)")
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
"""
        } else {
            // .xls — try Python csv module on the off chance, or use textutil
            pythonCode = """
import sys, subprocess
path = sys.argv[1]
try:
    result = subprocess.run(['/usr/bin/textutil', '-convert', 'txt', '-stdout', path],
                          capture_output=True, text=True, timeout=30)
    if result.returncode == 0 and result.stdout.strip():
        print(result.stdout.strip())
    else:
        # Try reading as raw text
        with open(path, 'rb') as f:
            data = f.read(50000)
        text = data.decode('utf-8', errors='replace')
        printable = ''.join(c if c.isprintable() or c in '\\n\\r\\t' else ' ' for c in text)
        if printable.strip():
            print(printable)
        else:
            print(f"Cannot extract text from legacy .xls file. Convert to .xlsx first.")
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
"""
        }

        let tmpPy = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi_excel_\(UUID().uuidString).py")
        try pythonCode.write(to: tmpPy, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpPy) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [tmpPy.path, expanded]
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if proc.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ToolError.commandFailed("Could not read \(ext.uppercased()): \(err.isEmpty ? "unknown error" : err)")
        }
        let preview = output.count > 20_000
            ? String(output.prefix(20_000)) + "\n...[truncated at 20,000 chars]"
            : output
        return "[\(ext.uppercased()): \(expanded)]\n\n\(preview.isEmpty ? "(No data found)" : preview)"
    }

    /// Read Apple iWork documents (.pages, .numbers, .key) by extracting from their package format.
    static func readIWork(path: String, ext: String) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }

        // First try textutil (works well for Pages documents)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        proc.arguments = ["-convert", "txt", "-stdout", expanded]
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if proc.terminationStatus == 0 && !output.isEmpty {
            let preview = output.count > 20_000
                ? String(output.prefix(20_000)) + "\n...[truncated at 20,000 chars]"
                : output
            return "[\(ext.uppercased()): \(expanded)]\n\n\(preview)"
        }

        // Fallback: try to extract text from the iWork package (it's a ZIP)
        let pythonCode = """
import zipfile, re, sys
path = sys.argv[1]
try:
    with zipfile.ZipFile(path) as z:
        # Look for any XML or text content inside
        texts = []
        for name in z.namelist():
            if name.endswith('.xml') or name.endswith('.txt'):
                try:
                    content = z.read(name).decode('utf-8', errors='replace')
                    # Extract text content from XML tags
                    found = re.findall(r'>([^<]{2,})<', content)
                    clean = [t.strip() for t in found if t.strip() and not t.strip().startswith('{')]
                    texts.extend(clean)
                except:
                    pass
        if texts:
            print('\\n'.join(texts[:2000]))
        else:
            print('(No extractable text found in iWork document)')
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
"""
        let tmpPy = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi_iwork_\(UUID().uuidString).py")
        try pythonCode.write(to: tmpPy, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpPy) }

        let proc2 = Process()
        proc2.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc2.arguments = [tmpPy.path, expanded]
        let outPipe2 = Pipe(), errPipe2 = Pipe()
        proc2.standardOutput = outPipe2
        proc2.standardError = errPipe2
        try proc2.run()
        proc2.waitUntilExit()

        let output2 = String(data: outPipe2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if proc2.terminationStatus != 0 {
            let err = String(data: errPipe2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ToolError.commandFailed("Could not read \(ext) document: \(err.isEmpty ? "unknown error" : err)")
        }
        return "[\(ext.uppercased()): \(expanded)]\n\n\(output2.isEmpty ? "(No extractable text)" : output2)"
    }

    /// Get image metadata (dimensions, format, color space, DPI, file size) using sips.
    static func readImageMetadata(path: String) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = ["-g", "all", expanded]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let attrs = try? FileManager.default.attributesOfItem(atPath: expanded)
        let size = attrs?[.size] as? Int ?? 0
        let fmt = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        let ext = (expanded as NSString).pathExtension.lowercased()

        var result = "[Image \(ext.uppercased()): \(expanded) (\(fmt))]\n\n"
        if !output.isEmpty {
            result += output
        } else {
            result += "(Could not read image metadata)"
        }
        result += "\n\nNote: This is an image file. Use take_screenshot to view what's on screen, or use Quick Look (open_quick_look) to preview it."
        return result
    }
}

// MARK: - Disk Tools

enum DiskTools {

    /// Analyze disk space: overall volume usage and the largest items in a given path.
    /// Defaults to the user's home directory if no path is provided.
    static func analyzeDiskSpace(path: String?) async throws -> String {
        let rawPath = path.flatMap { $0.isEmpty ? nil : $0 } ?? "~"
        let expanded = (rawPath as NSString).expandingTildeInPath
        // Escape double quotes in path for shell safety
        let safePath = expanded.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        echo "=== Disk Usage (All Volumes) ==="
        df -h 2>/dev/null
        echo ""
        echo "=== Target: \(safePath) ==="
        du -sh "\(safePath)" 2>/dev/null || echo "(cannot access path)"
        echo ""
        echo "=== Largest Items in \(safePath) (top 20) ==="
        du -sh "\(safePath)"/* 2>/dev/null | sort -rh | head -20
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? "Could not retrieve disk information." : output
    }
}

// MARK: - Window Management Tools

enum WindowTools {

    /// List all visible windows with their app, title, position, and size.
    static func listWindows() async throws -> String {
        let script = """
        tell application "System Events"
            set output to ""
            repeat with proc in (every process whose visible is true)
                set procName to name of proc
                try
                    repeat with win in (every window of proc)
                        set winName to name of win
                        set winPos to position of win
                        set winSz to size of win
                        set output to output & procName & " | " & winName & " | pos:(" & (item 1 of winPos) & "," & (item 2 of winPos) & ") size:(" & (item 1 of winSz) & "×" & (item 2 of winSz) & ")" & linefeed
                    end repeat
                end try
            end repeat
            return output
        end tell
        """
        let result = try await ScreenControlTools.runAppleScript(script: script)
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No visible windows found."
            : result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bring a window to front by app name and optional window title.
    static func focusWindow(app: String, title: String?) async throws -> String {
        let titleClause: String
        if let t = title, !t.isEmpty {
            let safe = t.replacingOccurrences(of: "\"", with: "\\\"")
            titleClause = "set index of (first window whose name contains \"\(safe)\") to 1"
        } else {
            titleClause = "set index of window 1 to 1"
        }
        let script = """
        tell application "\(app)" to activate
        delay 0.3
        tell application "System Events"
            tell process "\(app)"
                \(titleClause)
            end tell
        end tell
        """
        _ = try await ScreenControlTools.runAppleScript(script: script)
        return "Focused \(app)" + (title.map { " — \($0)" } ?? "")
    }

    /// Resize and/or move a window by app name.
    static func resizeWindow(app: String, x: Int?, y: Int?, width: Int?, height: Int?) async throws -> String {
        var commands: [String] = []
        if let x = x, let y = y {
            commands.append("set position of window 1 to {\(x), \(y)}")
        }
        if let w = width, let h = height {
            commands.append("set size of window 1 to {\(w), \(h)}")
        }
        guard !commands.isEmpty else {
            return "Provide at least position (x, y) or size (width, height)."
        }
        let script = """
        tell application "\(app)" to activate
        delay 0.3
        tell application "System Events"
            tell process "\(app)"
                \(commands.joined(separator: "\n                "))
            end tell
        end tell
        """
        _ = try await ScreenControlTools.runAppleScript(script: script)
        return "Resized/moved \(app) window."
    }

    /// Close the frontmost window of an app.
    static func closeWindow(app: String) async throws -> String {
        let script = """
        tell application "System Events"
            tell process "\(app)"
                if (count of windows) > 0 then
                    click button 1 of window 1
                end if
            end tell
        end tell
        """
        _ = try await ScreenControlTools.runAppleScript(script: script)
        return "Closed frontmost window of \(app)."
    }

    /// Quit an application gracefully.
    static func quitApplication(name: String) async throws -> String {
        let script = "tell application \"\(name)\" to quit"
        _ = try await ScreenControlTools.runAppleScript(script: script)
        return "Quit \(name)."
    }

    /// List all running GUI applications (not background processes).
    static func listRunningApps() async throws -> String {
        let script = """
        tell application "System Events"
            set appList to ""
            repeat with proc in (every process whose background only is false)
                set appList to appList & name of proc & linefeed
            end repeat
            return appList
        end tell
        """
        let result = try await ScreenControlTools.runAppleScript(script: script)
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No running GUI applications."
            : result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get the name of the frontmost application.
    static func getFrontmostApp() async throws -> String {
        let script = """
        tell application "System Events"
            return name of (first application process whose frontmost is true)
        end tell
        """
        return try await ScreenControlTools.runAppleScript(script: script)
    }
}

// MARK: - Notification Tools

enum NotificationTools {

    /// Send a macOS notification with title, subtitle, and message.
    static func sendNotification(title: String, subtitle: String?, message: String) async throws -> String {
        let subtitlePart = subtitle.map { " subtitle \"\($0)\"" } ?? ""
        let script = "display notification \"\(message)\"\(subtitlePart) with title \"\(title)\""
        _ = try await ScreenControlTools.runAppleScript(script: script)
        return "Notification sent: \(title)"
    }

    /// Set a timer that sends a notification after the specified number of seconds.
    static func setTimer(seconds: Int, message: String) async throws -> String {
        let clamped = max(1, min(seconds, 3600))
        let script = """
        delay \(clamped)
        display notification "\(message)" with title "Timer" sound name "Glass"
        """
        // Run asynchronously so we don't block
        Task.detached {
            _ = try? await ScreenControlTools.runAppleScript(script: script)
        }
        return "Timer set for \(clamped) second(s). You'll get a notification: \"\(message)\""
    }
}

// MARK: - Image Tools

enum ImageTools {

    /// Get image dimensions, format, color space, and file size using sips.
    static func getImageInfo(path: String) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = ["-g", "all", expanded]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? "Could not read image info for \(expanded)" : output
    }

    /// Resize an image using sips. Specify width and/or height in pixels.
    static func resizeImage(path: String, width: Int?, height: Int?, outputPath: String?) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }
        let dest: String
        if let o = outputPath, !o.isEmpty {
            dest = (o as NSString).expandingTildeInPath
            try? FileManager.default.copyItem(atPath: expanded, toPath: dest)
        } else {
            dest = expanded
        }
        var args: [String] = []
        if let w = width { args += ["--resampleWidth", "\(w)"] }
        if let h = height { args += ["--resampleHeight", "\(h)"] }
        guard !args.isEmpty else {
            return "Provide at least width or height."
        }
        args.append(dest)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return proc.terminationStatus == 0
            ? "Image resized: \(dest)"
            : "Failed to resize image."
    }

    /// Convert an image to a different format (png, jpeg, tiff, bmp, gif, pdf) using sips.
    static func convertImage(path: String, format: String, outputPath: String?) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }
        let fmt = format.lowercased()
        let validFormats = ["png", "jpeg", "tiff", "bmp", "gif", "pdf"]
        guard validFormats.contains(fmt) else {
            throw ToolError.commandFailed("Unsupported format '\(format)'. Use: \(validFormats.joined(separator: ", "))")
        }
        let ext = fmt == "jpeg" ? "jpg" : fmt
        let dest: String
        if let o = outputPath, !o.isEmpty {
            dest = (o as NSString).expandingTildeInPath
        } else {
            let base = (expanded as NSString).deletingPathExtension
            dest = "\(base).\(ext)"
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = ["-s", "format", fmt, expanded, "--out", dest]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return proc.terminationStatus == 0
            ? "Converted to \(fmt): \(dest)"
            : "Failed to convert image."
    }
}

// MARK: - Archive Tools

enum ArchiveTools {

    /// Create a zip archive from one or more files/directories.
    static func createArchive(sources: [String], outputPath: String) async throws -> String {
        let dest = (outputPath as NSString).expandingTildeInPath
        let expandedSources = sources.map { ($0 as NSString).expandingTildeInPath }
        for src in expandedSources {
            guard FileManager.default.fileExists(atPath: src) else {
                throw ToolError.fileNotFound(src)
            }
        }
        let quotedSources = expandedSources.map { "\"\($0)\"" }.joined(separator: " ")
        let cmd = "zip -r \"\(dest)\" \(quotedSources)"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", cmd]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return proc.terminationStatus == 0
            ? "Archive created: \(dest)"
            : "Failed to create archive."
    }

    /// Extract a zip, tar, tar.gz, or tar.bz2 archive.
    static func extractArchive(path: String, destination: String?) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }
        let dest = destination.map { ($0 as NSString).expandingTildeInPath }
            ?? (expanded as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)

        let ext = (expanded as NSString).pathExtension.lowercased()
        let cmd: String
        switch ext {
        case "zip":
            cmd = "unzip -o \"\(expanded)\" -d \"\(dest)\""
        case "gz", "tgz":
            cmd = "tar -xzf \"\(expanded)\" -C \"\(dest)\""
        case "bz2":
            cmd = "tar -xjf \"\(expanded)\" -C \"\(dest)\""
        case "tar":
            cmd = "tar -xf \"\(expanded)\" -C \"\(dest)\""
        case "xz":
            cmd = "tar -xJf \"\(expanded)\" -C \"\(dest)\""
        default:
            // Try as zip first, then tar
            cmd = "unzip -o \"\(expanded)\" -d \"\(dest)\" 2>/dev/null || tar -xf \"\(expanded)\" -C \"\(dest)\""
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", cmd]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return proc.terminationStatus == 0
            ? "Extracted to: \(dest)"
            : "Failed to extract archive. File may be corrupted or in an unsupported format."
    }
}

// MARK: - Network Info Tools

enum NetworkInfoTools {

    /// Get current Wi-Fi SSID, signal strength, and channel.
    static func getWifiInfo() async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", """
            /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I 2>/dev/null || \
            networksetup -getairportnetwork en0 2>/dev/null || \
            echo "Could not retrieve Wi-Fi info"
        """]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "No Wi-Fi info available."
    }

    /// Get all network interfaces with their IP addresses.
    static func getNetworkInterfaces() async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", """
            echo "=== Active Interfaces ==="
            ifconfig | grep -E '^[a-z]|inet ' | grep -v '127.0.0.1'
            echo ""
            echo "=== External IP ==="
            curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "(could not reach external IP service)"
            echo ""
            echo "=== DNS Servers ==="
            scutil --dns 2>/dev/null | grep 'nameserver' | head -5
        """]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "No network info available."
    }

    /// Ping a host and return latency results.
    static func pingHost(host: String, count: Int) async throws -> String {
        let safe = host.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "$", with: "")
        let c = max(1, min(count, 10))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/ping")
        proc.arguments = ["-c", "\(c)", safe]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Ping failed."
    }
}

// MARK: - Appearance Tools

enum AppearanceTools {

    /// Get current screen brightness (0–100).
    static func getBrightness() async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", """
            brightness=$(ioreg -c AppleBacklightDisplay 2>/dev/null | grep -i brightness | head -1 | grep -oE '[0-9]+' | tail -1)
            if [ -n "$brightness" ]; then
                echo "Screen brightness level: $brightness"
            else
                # Try alternative
                val=$(osascript -e 'tell application "System Events" to get value of slider 1 of group 1 of window "Control Center" of application process "ControlCenter"' 2>/dev/null)
                if [ -n "$val" ]; then echo "Screen brightness: $val"; else echo "Could not read brightness. This Mac may not support programmatic brightness reading."; fi
            fi
        """]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Could not read brightness."
    }

    /// Set screen brightness (0.0–1.0). Requires external tool or display hardware support.
    static func setBrightness(level: Double) async throws -> String {
        let clamped = max(0.0, min(1.0, level))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", """
            if command -v brightness &>/dev/null; then
                brightness \(clamped)
                echo "Brightness set to \(Int(clamped * 100))%"
            else
                osascript -e 'tell application "System Preferences" to quit' 2>/dev/null
                echo "Cannot set brightness programmatically without the 'brightness' CLI tool. Install with: brew install brightness"
            fi
        """]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Could not set brightness."
    }

    /// Get current appearance mode (light/dark).
    static func getAppearance() async throws -> String {
        let script = "tell application \"System Events\" to return dark mode of appearance preferences"
        let result = try await ScreenControlTools.runAppleScript(script: script)
        return result.lowercased().contains("true") ? "Dark Mode is ON" : "Dark Mode is OFF (Light Mode)"
    }

    /// Toggle between dark and light mode.
    static func setDarkMode(enabled: Bool) async throws -> String {
        let script = "tell application \"System Events\" to set dark mode of appearance preferences to \(enabled)"
        _ = try await ScreenControlTools.runAppleScript(script: script)
        return enabled ? "Dark Mode enabled." : "Light Mode enabled."
    }

    /// Set the desktop wallpaper.
    static func setWallpaper(path: String) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }
        let script = """
        tell application "System Events"
            tell every desktop
                set picture to "\(expanded)"
            end tell
        end tell
        """
        _ = try await ScreenControlTools.runAppleScript(script: script)
        return "Wallpaper set to: \(expanded)"
    }
}

// MARK: - Trash Tools

enum TrashTools {

    /// Move a file or directory to the Trash (safer than delete).
    static func moveToTrash(path: String) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }
        let script = """
        tell application "Finder"
            move POSIX file "\(expanded)" to trash
        end tell
        """
        _ = try await ScreenControlTools.runAppleScript(script: script)
        return "Moved to Trash: \(expanded)"
    }

    /// Empty the Trash.
    static func emptyTrash() async throws -> String {
        let script = """
        tell application "Finder"
            empty trash
        end tell
        """
        _ = try await ScreenControlTools.runAppleScript(script: script)
        return "Trash emptied."
    }
}

// MARK: - Speech Tools

enum SpeechTools {

    /// Speak text aloud using macOS text-to-speech.
    static func speakText(text: String, voice: String?) async throws -> String {
        var args = [text]
        if let v = voice, !v.isEmpty {
            args = ["-v", v] + args
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        // Don't wait — let it speak in the background
        Task.detached {
            proc.waitUntilExit()
        }
        return "Speaking: \"\(text.prefix(100))\"\(text.count > 100 ? "..." : "")"
    }

    /// List available TTS voices.
    static func listVoices() async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        proc.arguments = ["-v", "?"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "No voices found."
    }
}

// MARK: - Calendar Tools

enum CalendarTools {

    /// Get upcoming calendar events from the default Calendar app.
    static func getEvents(days: Int) async throws -> String {
        let d = max(1, min(days, 30))
        let script = """
        set today to current date
        set endDate to today + (\(d) * days)
        set output to ""
        tell application "Calendar"
            repeat with cal in calendars
                set calName to name of cal
                set evts to (every event of cal whose start date ≥ today and start date ≤ endDate)
                repeat with evt in evts
                    set evtName to summary of evt
                    set evtStart to start date of evt
                    set evtEnd to end date of evt
                    set output to output & calName & " | " & evtName & " | " & (evtStart as string) & " → " & (evtEnd as string) & linefeed
                end repeat
            end repeat
        end tell
        if output is "" then return "No events in the next \(d) day(s)."
        return output
        """
        return try await ScreenControlTools.runAppleScript(script: script)
    }

    /// Create a new calendar event.
    static func createEvent(title: String, startDate: String, endDate: String, calendar: String?, notes: String?) async throws -> String {
        let calClause = calendar.map { "set targetCal to calendar \"\($0)\"" }
            ?? "set targetCal to first calendar whose name is not \"\""
        let notesClause = notes.map { "set description of newEvent to \"\($0)\"" } ?? ""
        let script = """
        tell application "Calendar"
            \(calClause)
            set startD to date "\(startDate)"
            set endD to date "\(endDate)"
            set newEvent to make new event at end of events of targetCal with properties {summary:"\(title)", start date:startD, end date:endD}
            \(notesClause)
            return "Event created: \(title)"
        end tell
        """
        return try await ScreenControlTools.runAppleScript(script: script)
    }
}

// MARK: - Reminder Tools

enum ReminderTools {

    /// Get upcoming reminders.
    static func getReminders(list: String?) async throws -> String {
        let targetList = list.map { "list \"\($0)\"" } ?? "default list"
        let script = """
        tell application "Reminders"
            set output to ""
            set rems to (every reminder of \(targetList) whose completed is false)
            repeat with rem in rems
                set remName to name of rem
                set output to output & "• " & remName
                try
                    set dd to due date of rem
                    set output to output & " (due: " & (dd as string) & ")"
                end try
                set output to output & linefeed
            end repeat
            if output is "" then return "No incomplete reminders."
            return output
        end tell
        """
        return try await ScreenControlTools.runAppleScript(script: script)
    }

    /// Create a new reminder.
    static func createReminder(title: String, dueDate: String?, notes: String?, list: String?) async throws -> String {
        let duePart = dueDate.map { "set due date of newRem to date \"\($0)\"" } ?? ""
        let notesPart = notes.map { "set body of newRem to \"\($0)\"" } ?? ""
        let targetList = list.map { "list \"\($0)\"" } ?? "default list"
        let script = """
        tell application "Reminders"
            set newRem to make new reminder at end of \(targetList) with properties {name:"\(title)"}
            \(duePart)
            \(notesPart)
            return "Reminder created: \(title)"
        end tell
        """
        return try await ScreenControlTools.runAppleScript(script: script)
    }
}

// MARK: - Utility Tools

enum UtilityTools {

    /// Compute hash (MD5 or SHA-256) of a file.
    static func hashFile(path: String, algorithm: String) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }
        let algo = algorithm.lowercased()
        let cmd: String
        switch algo {
        case "md5":
            cmd = "md5 -q \"\(expanded)\""
        case "sha256", "sha-256":
            cmd = "shasum -a 256 \"\(expanded)\" | awk '{print $1}'"
        case "sha1", "sha-1":
            cmd = "shasum -a 1 \"\(expanded)\" | awk '{print $1}'"
        case "sha512", "sha-512":
            cmd = "shasum -a 512 \"\(expanded)\" | awk '{print $1}'"
        default:
            throw ToolError.commandFailed("Unsupported algorithm '\(algorithm)'. Use: md5, sha1, sha256, sha512")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", cmd]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        let hash = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return hash.isEmpty ? "Failed to compute hash." : "\(algo.uppercased()): \(hash)"
    }

    /// Search using Spotlight (mdfind).
    static func spotlightSearch(query: String, directory: String?) async throws -> String {
        let safe = query.replacingOccurrences(of: "\"", with: "\\\"")
        var args = ["-name", safe]
        if let dir = directory, !dir.isEmpty {
            args = ["-onlyin", (dir as NSString).expandingTildeInPath] + args
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if output.isEmpty {
            return "No Spotlight results for '\(query)'."
        }
        let lines = output.components(separatedBy: "\n")
        if lines.count > 30 {
            return lines.prefix(30).joined(separator: "\n") + "\n... and \(lines.count - 30) more results"
        }
        return output
    }

    /// Open a file in Quick Look preview.
    static func previewFile(path: String) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.fileNotFound(expanded)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        proc.arguments = ["-p", expanded]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        // Don't block — Quick Look opens as a separate window
        Task.detached { proc.waitUntilExit() }
        return "Quick Look preview opened for: \(expanded)"
    }

    /// Get battery status (level, charging state, time remaining).
    static func getBatteryInfo() async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "pmset -g batt 2>/dev/null"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? "Battery information not available (desktop Mac?)." : output
    }

    /// Get the current user's info (username, home directory, shell).
    static func getUserInfo() async throws -> String {
        let user = NSUserName()
        let home = NSHomeDirectory()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return """
        Username: \(user)
        Full name: \(NSFullUserName())
        Home directory: \(home)
        Shell: \(shell)
        """
    }

    /// List all menu bar items of the frontmost app (useful for automation).
    static func listMenuItems(app: String?) async throws -> String {
        let script: String
        if let a = app, !a.isEmpty {
            script = """
            tell application "System Events"
                tell process "\(a)"
                    set menuNames to ""
                    repeat with m in (every menu bar item of menu bar 1)
                        set menuNames to menuNames & name of m & ": "
                        try
                            repeat with mi in (every menu item of menu 1 of m)
                                set miName to name of mi
                                if miName is not missing value then
                                    set menuNames to menuNames & miName & ", "
                                end if
                            end repeat
                        end try
                        set menuNames to menuNames & linefeed
                    end repeat
                    return menuNames
                end tell
            end tell
            """
        } else {
            script = """
            tell application "System Events"
                set frontProc to first application process whose frontmost is true
                set procName to name of frontProc
                set menuNames to "App: " & procName & linefeed
                tell frontProc
                    repeat with m in (every menu bar item of menu bar 1)
                        set menuNames to menuNames & name of m & ": "
                        try
                            repeat with mi in (every menu item of menu 1 of m)
                                set miName to name of mi
                                if miName is not missing value then
                                    set menuNames to menuNames & miName & ", "
                                end if
                            end repeat
                        end try
                        set menuNames to menuNames & linefeed
                    end repeat
                end tell
                return menuNames
            end tell
            """
        }
        return try await ScreenControlTools.runAppleScript(script: script)
    }
}

#else
import Foundation

enum MCPToolHandlers {
    // Stubs
}
#endif
