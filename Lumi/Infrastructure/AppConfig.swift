//
//  AppConfig.swift
//  LumiAgent
//
//  Created by Lumi Agent on 2026-02-18.
//
//  Application configuration and constants
//

import Foundation

// MARK: - App Config

enum AppConfig {
    // MARK: - Version

    static let version = "1.0.0"
    static let buildNumber = "1"

    // MARK: - Identifiers

    static let bundleIdentifier = "com.lumiagent.app"
    static let helperBundleIdentifier = "com.lumiagent.helper"

    // MARK: - Paths

    static let appName = "LumiAgent"
    static let databaseName = "lumi_agent.db"

    // MARK: - Limits

    static let maxExecutionTime: TimeInterval = 300 // 5 minutes
    static let maxIterations = 10
    static let defaultTimeout: TimeInterval = 60

    // MARK: - Security

    static let defaultSecurityPolicy = SecurityPolicy(
        allowSudo: false,
        requireApproval: true,
        whitelistedCommands: [],
        blacklistedCommands: [
            "rm -rf /",
            "dd if=/dev/zero",
            ":(){ :|:& };:",
            "chmod -R 777",
            "mkfs",
            "format"
        ],
        restrictedPaths: [
            "/System",
            "/Library",
            "/usr/bin",
            "/usr/sbin",
            "/bin",
            "/sbin"
        ],
        maxExecutionTime: 300,
        autoApproveThreshold: .low
    )

    // MARK: - AI Providers

    static let defaultOllamaURL = "http://127.0.0.1:11434"

    static let defaultModels: [AIProvider: String] = [
        .openai: "gpt-5.2",
        .anthropic: "claude-sonnet-4-20250514",
        .gemini: "gemini-2.5-flash",
        .qwen: "qwen-plus",
        .ollama: ""
    ]

    // MARK: - UI

    static let minWindowWidth: CGFloat = 1000
    static let minWindowHeight: CGFloat = 600
    static let sidebarMinWidth: CGFloat = 200
    static let contentMinWidth: CGFloat = 300
    static let detailMinWidth: CGFloat = 400
}
