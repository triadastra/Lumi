//
//  Agent.swift
//  LumiAgent
//
//  Created by Lumi Agent on 2026-02-18.
//

import Foundation
import SwiftUI

// MARK: - Agent

/// Represents an AI agent with configuration and capabilities
struct Agent: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var configuration: AgentConfiguration
    var capabilities: [AgentCapability]
    var status: AgentStatus
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        configuration: AgentConfiguration,
        capabilities: [AgentCapability] = [],
        status: AgentStatus = .idle,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.configuration = configuration
        self.capabilities = capabilities
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Agent {
    /// Stable avatar color derived from the agent UUID.
    var avatarColor: Color {
        let palette: [Color] = [
            .blue, .purple, .pink, .orange, .green, .teal, .indigo, .red
        ]

        // Use a stable FNV-1a hash over UUID bytes.
        let uuid = id.uuid
        let hash: UInt64 = withUnsafeBytes(of: uuid) { raw in
            var value: UInt64 = 1469598103934665603
            for byte in raw {
                value ^= UInt64(byte)
                value &*= 1099511628211
            }
            return value
        }

        return palette[Int(hash % UInt64(palette.count))]
    }
}

// MARK: - Agent Configuration

/// Configuration for an AI agent
struct AgentConfiguration: Codable, Equatable {
    var provider: AIProvider
    var model: String
    var systemPrompt: String?
    var temperature: Double?
    var maxTokens: Int?
    var enabledTools: [String]
    var securityPolicy: SecurityPolicy

    init(
        provider: AIProvider,
        model: String,
        systemPrompt: String? = nil,
        temperature: Double? = 0.7,
        maxTokens: Int? = 4096,
        enabledTools: [String] = [],
        securityPolicy: SecurityPolicy = SecurityPolicy()
    ) {
        self.provider = provider
        self.model = model
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.enabledTools = enabledTools
        self.securityPolicy = securityPolicy
    }
}

// MARK: - AI Provider

/// Supported AI providers
enum AIProvider: String, Codable, CaseIterable {
    case openai = "OpenAI"
    case anthropic = "Anthropic"
    case gemini = "Gemini"
    case qwen = "Aliyun Qwen"
    case ollama = "Ollama"

    var recommendedModels: [String] {
        switch self {
        case .openai:
            return [
                "gpt-5.2",
                "gpt-5-mini",
                "gpt-4.1"
            ]
        case .anthropic:
            return [
                "claude-sonnet-4-20250514",
                "claude-opus-4-1-20250805",
                "claude-3-5-haiku-latest"
            ]
        case .gemini:
            return [
                "gemini-2.5-flash",
                "gemini-2.5-pro",
                "gemini-3.1-pro-preview"
            ]
        case .qwen:
            return [
                "qwen-plus",
                "qwen-flash",
                "qwen3-max"
            ]
        case .ollama:
            return [
                "qwen2.5:7b",
                "llama3.2:3b",
                "deepseek-r1:8b"
            ]
        }
    }

    var allModels: [String] {
        switch self {
        case .openai:
            return [
                "gpt-5.2",
                "gpt-5.2-pro",
                "gpt-5",
                "gpt-5-mini",
                "gpt-5-nano",
                "gpt-4.1",
                "gpt-4.1-mini",
                "gpt-4.1-nano",
                "o3",
                "o4-mini",
                "gpt-4o",
                "gpt-4o-mini",
                "gpt-4-turbo"
            ]
        case .anthropic:
            return [
                "claude-opus-4-1-20250805",
                "claude-opus-4-20250514",
                "claude-sonnet-4-20250514",
                "claude-3-7-sonnet-20250219",
                "claude-3-5-sonnet-20241022",
                "claude-3-5-haiku-20241022",
                "claude-3-haiku-20240307",
                "claude-opus-4-1",
                "claude-opus-4-0",
                "claude-sonnet-4-0",
                "claude-3-7-sonnet-latest",
                "claude-3-5-haiku-latest"
            ]
        case .gemini:
            return [
                "gemini-3.1-pro-preview",
                "gemini-3.1-pro-preview-customtools",
                "gemini-3-flash-preview",
                "gemini-2.5-pro",
                "gemini-2.5-flash",
                "gemini-2.5-flash-lite",
                "gemini-2.0-flash",
                "gemini-2.0-flash-lite"
            ]
        case .qwen:
            return [
                "qwen-plus",
                "qwen-plus-latest",
                "qwen-max",
                "qwen-max-latest",
                "qwen-flash",
                "qwen-turbo",
                "qwen-turbo-latest",
                "qwen3-max",
                "qwen3-max-preview",
                "qwen3-coder-plus",
                "qwen3-coder-flash"
            ]
        case .ollama:
            return []
        }
    }

    var defaultModels: [String] {
        allModels
    }
}

// MARK: - Agent Capability

/// Capabilities that an agent can have
enum AgentCapability: String, Codable, CaseIterable {
    case fileOperations = "file_operations"
    case webSearch = "web_search"
    case codeExecution = "code_execution"
    case systemCommands = "system_commands"
    case databaseAccess = "database_access"
    case networkRequests = "network_requests"

    var displayName: String {
        switch self {
        case .fileOperations: return "File Operations"
        case .webSearch: return "Web Search"
        case .codeExecution: return "Code Execution"
        case .systemCommands: return "System Commands"
        case .databaseAccess: return "Database Access"
        case .networkRequests: return "Network Requests"
        }
    }

    var requiresApproval: Bool {
        switch self {
        case .fileOperations, .systemCommands, .databaseAccess:
            return true
        case .webSearch, .codeExecution, .networkRequests:
            return false
        }
    }
}

// MARK: - Agent Status

/// Current status of an agent
enum AgentStatus: String, Codable {
    case idle
    case running
    case paused
    case error
    case stopped

    var displayName: String {
        rawValue.capitalized
    }
}

// MARK: - Security Policy

/// Security policy for agent operations
struct SecurityPolicy: Codable, Equatable {
    var allowSudo: Bool
    var requireApproval: Bool
    var whitelistedCommands: [String]
    var blacklistedCommands: [String]
    var restrictedPaths: [String]
    var maxExecutionTime: TimeInterval // seconds
    var autoApproveThreshold: RiskLevel

    init(
        allowSudo: Bool = false,
        requireApproval: Bool = true,
        whitelistedCommands: [String] = [],
        blacklistedCommands: [String] = ["rm -rf /", "dd if=/dev/zero", ":(){ :|:& };:"],
        restrictedPaths: [String] = ["/System", "/Library", "/usr", "/bin", "/sbin"],
        maxExecutionTime: TimeInterval = 300,
        autoApproveThreshold: RiskLevel = .low
    ) {
        self.allowSudo = allowSudo
        self.requireApproval = requireApproval
        self.whitelistedCommands = whitelistedCommands
        self.blacklistedCommands = blacklistedCommands
        self.restrictedPaths = restrictedPaths
        self.maxExecutionTime = maxExecutionTime
        self.autoApproveThreshold = autoApproveThreshold
    }
}

// MARK: - Risk Level

/// Risk level for operations
enum RiskLevel: String, Codable, Comparable, CaseIterable {
    case low
    case medium
    case high
    case critical

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        let order: [RiskLevel] = [.low, .medium, .high, .critical]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs) else {
            return false
        }
        return lhsIndex < rhsIndex
    }

    var displayName: String {
        rawValue.capitalized
    }

    var color: String {
        switch self {
        case .low: return "green"
        case .medium: return "yellow"
        case .high: return "orange"
        case .critical: return "red"
        }
    }
}
