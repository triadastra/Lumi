//
//  AgentExecutionEngine.swift
//  LumiAgent
//
//  Created by Lumi Agent on 2026-02-18.
//
//  Core orchestrator for agent execution - coordinates AI ↔ tool execution
//

#if os(macOS)
import Foundation
import Combine

// MARK: - Agent Execution Engine

/// Orchestrates agent lifecycle and coordinates AI ↔ tool execution
@MainActor
final class AgentExecutionEngine: ObservableObject {

    // MARK: - Published Properties

    @Published var currentSession: ExecutionSession?
    @Published var isExecuting: Bool = false
    @Published var executionOutput: String = ""

    // MARK: - Properties

    private let aiRepository: AIProviderRepositoryProtocol
    private let sessionRepository: SessionRepositoryProtocol
    private let authorizationManager: AuthorizationManager
    private let toolRegistry: ToolRegistry

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(
        aiRepository: AIProviderRepositoryProtocol? = nil,
        sessionRepository: SessionRepositoryProtocol? = nil,
        authorizationManager: AuthorizationManager? = nil,
        toolRegistry: ToolRegistry? = nil
    ) {
        self.aiRepository = aiRepository ?? AIProviderRepository()
        self.sessionRepository = sessionRepository ?? SessionRepository()
        self.authorizationManager = authorizationManager ?? .shared
        self.toolRegistry = toolRegistry ?? .shared
    }

    // MARK: - Execution

    /// Execute an agent with a user prompt
    func execute(
        agent: Agent,
        userPrompt: String
    ) async throws {
        guard !isExecuting else {
            throw ExecutionError.alreadyExecuting
        }

        isExecuting = true
        executionOutput = ""

        // Create new session
        let session = ExecutionSession(
            agentId: agent.id,
            userPrompt: userPrompt
        )
        currentSession = session

        do {
            try await sessionRepository.create(session)

            // Add initial step
            await addStep(.thinking, content: "Starting execution...")

            // Build conversation history
            var messages: [AIMessage] = [
                AIMessage(role: .user, content: userPrompt)
            ]

            // Get available tools
            let tools = toolRegistry.getToolsForAI(enabledNames: agent.configuration.enabledTools)

            // Execute agent loop
            try await executionLoop(
                agent: agent,
                session: session,
                messages: &messages,
                tools: tools
            )

            // Mark session as completed
            await completeSession(success: true)

        } catch {
            await completeSession(success: false, error: error)
            throw error
        }
    }

    /// Stop current execution
    func stop() async {
        guard isExecuting else { return }

        if var session = currentSession {
            session.status = .cancelled
            try? await sessionRepository.update(session)
        }

        isExecuting = false
        await addStep(.response, content: "Execution stopped by user")
    }

    // MARK: - Execution Loop

    private func executionLoop(
        agent: Agent,
        session: ExecutionSession,
        messages: inout [AIMessage],
        tools: [AITool]
    ) async throws {
        let maxIterations = 10
        var iteration = 0

        while iteration < maxIterations {
            iteration += 1

            // Send to AI
            await addStep(.thinking, content: "Thinking... (iteration \(iteration))")

            let response = try await aiRepository.sendMessage(
                provider: agent.configuration.provider,
                model: agent.configuration.model,
                messages: messages,
                systemPrompt: agent.configuration.systemPrompt,
                tools: tools,
                temperature: agent.configuration.temperature,
                maxTokens: agent.configuration.maxTokens
            )

            // Always record the full assistant turn (may include tool calls)
            messages.append(AIMessage(
                role: .assistant,
                content: response.content ?? "",
                toolCalls: response.toolCalls
            ))

            if let content = response.content, !content.isEmpty {
                await addStep(.response, content: content)
            }

            // If no tool calls we're done
            guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                break
            }

            // Process each tool call and append results to history
            for toolCall in toolCalls {
                try await processToolCall(
                    toolCall,
                    agent: agent,
                    session: session,
                    messages: &messages
                )
            }
        }

        if iteration >= maxIterations {
            await addStep(.error, content: "Maximum iterations reached")
        }
    }

    // MARK: - Tool Execution

    private func processToolCall(
        _ toolCall: ToolCall,
        agent: Agent,
        session: ExecutionSession,
        messages: inout [AIMessage]
    ) async throws {
        await addStep(.toolCall, content: "Calling tool: \(toolCall.name)")

        // Get tool from registry
        guard let tool = toolRegistry.getTool(named: toolCall.name) else {
            let error = "Tool not found: \(toolCall.name)"
            await addStep(.error, content: error)
            messages.append(AIMessage(
                role: .tool,
                content: error,
                toolCallId: toolCall.id
            ))
            return
        }

        // Execute tool
        do {
            let result = try await tool.handler(toolCall.arguments)
            await addStep(.toolResult, content: "Tool result: \(result)")
            messages.append(AIMessage(role: .tool, content: result, toolCallId: toolCall.id))
        } catch {
            let errorMessage = "Tool execution failed: \(error.localizedDescription)"
            await addStep(.error, content: errorMessage)
            messages.append(AIMessage(role: .tool, content: errorMessage, toolCallId: toolCall.id))
        }
    }

    // MARK: - Session Management

    private func addStep(
        _ type: ExecutionStepType,
        content: String
    ) async {
        guard var session = currentSession else { return }

        let step = ExecutionStep(
            type: type,
            content: content
        )

        session.steps.append(step)
        currentSession = session

        // Update output
        executionOutput += "\n[\(type.displayName)] \(content)"

        // Save to database
        try? await sessionRepository.update(session)
    }

    private func completeSession(
        success: Bool,
        error: Error? = nil
    ) async {
        guard var session = currentSession else { return }

        session.status = success ? .completed : .failed
        session.completedAt = Date()
        session.result = ExecutionResult(
            success: success,
            output: success ? executionOutput : nil,
            error: error?.localizedDescription
        )

        currentSession = session
        try? await sessionRepository.update(session)

        isExecuting = false

        if success {
            await addStep(.response, content: "✅ Execution completed successfully")
        } else {
            await addStep(.error, content: "❌ Execution failed: \(error?.localizedDescription ?? "Unknown error")")
        }
    }
}

// MARK: - Execution Error

enum ExecutionError: Error, LocalizedError {
    case alreadyExecuting
    case toolNotFound(String)
    case maxIterationsReached

    var errorDescription: String? {
        switch self {
        case .alreadyExecuting:
            return "Another execution is already in progress"
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .maxIterationsReached:
            return "Maximum execution iterations reached"
        }
    }
}
#endif
