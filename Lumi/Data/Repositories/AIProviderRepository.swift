//
//  AIProviderRepository.swift
//  LumiAgent
//

import Foundation

// MARK: - AI Provider Repository

final class AIProviderRepository: AIProviderRepositoryProtocol {

    // MARK: - API Key Management
    // Keys are stored in UserDefaults.

    private func udKey(_ provider: AIProvider) -> String {
        "lumiagent.apikey.\(provider.rawValue)"
    }

    func setAPIKey(_ key: String, for provider: AIProvider) throws {
        UserDefaults.standard.set(key, forKey: udKey(provider))
    }

    func getAPIKey(for provider: AIProvider) throws -> String? {
        let value = UserDefaults.standard.string(forKey: udKey(provider))
        return value?.isEmpty == false ? value : nil
    }

    // MARK: - Protocol: sendMessage

    func sendMessage(
        provider: AIProvider,
        model: String,
        messages: [AIMessage],
        systemPrompt: String? = nil,
        tools: [AITool]? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) async throws -> AIResponse {
        let tools = tools ?? []
        switch provider {
        case .openai:
            return try await sendOpenAIMessage(model: model, messages: messages,
                systemPrompt: systemPrompt, tools: tools, temperature: temperature, maxTokens: maxTokens)
        case .anthropic:
            return try await sendAnthropicMessage(model: model, messages: messages,
                systemPrompt: systemPrompt, tools: tools, temperature: temperature, maxTokens: maxTokens)
        case .gemini:
            return try await sendGeminiMessage(model: model, messages: messages,
                systemPrompt: systemPrompt, tools: tools, temperature: temperature, maxTokens: maxTokens)
        case .ollama:
            return try await sendOllamaMessage(model: model, messages: messages,
                systemPrompt: systemPrompt, tools: tools, temperature: temperature)
        }
    }

    // MARK: - Protocol: sendMessageStream

    func sendMessageStream(
        provider: AIProvider,
        model: String,
        messages: [AIMessage],
        systemPrompt: String? = nil,
        tools: [AITool]? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        switch provider {
        case .openai:
            return try await sendOpenAIStream(model: model, messages: messages,
                systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens)
        case .anthropic:
            return try await sendAnthropicStream(model: model, messages: messages,
                systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens)
        case .gemini:
            return try await sendGeminiStream(model: model, messages: messages,
                systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens)
        case .ollama:
            return try await sendOllamaStream(model: model, messages: messages,
                systemPrompt: systemPrompt, temperature: temperature)
        }
    }

    // MARK: - Protocol: getAvailableModels

    func getAvailableModels(provider: AIProvider) async throws -> [String] {
        switch provider {
        case .openai:    return provider.defaultModels
        case .anthropic: return provider.defaultModels
        case .gemini:    return provider.defaultModels
        case .ollama:    return try await fetchOllamaModels()
        }
    }

    /// Attempt to launch the Ollama application on macOS
    func launchOllama() {
        #if os(macOS)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Ollama"]
        try? proc.run()
        #endif
    }

    // =========================================================================
    // MARK: - Message Building Helpers
    // =========================================================================

    /// OpenAI / Ollama message format (role-content pairs, tool role supported)
    private func openAIMessages(from messages: [AIMessage], systemPrompt: String?) -> [[String: Any]] {
        var result: [[String: Any]] = []
        if let sys = systemPrompt, !sys.isEmpty {
            result.append(["role": "system", "content": sys])
        }
        for msg in messages {
            switch msg.role {
            case .system:
                break
            case .user:
                if let imgData = msg.imageData {
                    // Vision message: content is an array of text + image_url blocks
                    var parts: [[String: Any]] = []
                    if !msg.content.isEmpty {
                        parts.append(["type": "text", "text": msg.content])
                    }
                    let b64 = imgData.base64EncodedString()
                    parts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:image/jpeg;base64,\(b64)", "detail": "high"]
                    ])
                    result.append(["role": "user", "content": parts])
                } else {
                    result.append(["role": "user", "content": msg.content])
                }
            case .assistant:
                if let tcs = msg.toolCalls, !tcs.isEmpty {
                    var m: [String: Any] = ["role": "assistant"]
                    m["content"] = msg.content.isEmpty ? NSNull() : (msg.content as Any)
                    m["tool_calls"] = tcs.map { tc -> [String: Any] in
                        ["id": tc.id, "type": "function",
                         "function": ["name": tc.name, "arguments": encodeArgs(tc.arguments)] as [String: Any]]
                    }
                    result.append(m)
                } else {
                    result.append(["role": "assistant", "content": msg.content])
                }
            case .tool:
                result.append([
                    "role": "tool",
                    "tool_call_id": msg.toolCallId ?? "",
                    "content": msg.content
                ])
            }
        }
        return result
    }

    /// Anthropic message format (content blocks, tool results grouped into user turn)
    private func anthropicMessages(from messages: [AIMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var i = 0
        while i < messages.count {
            let msg = messages[i]
            switch msg.role {
            case .system:
                i += 1
            case .user:
                if let imgData = msg.imageData {
                    // Vision message: content array with image block + text block
                    let b64 = imgData.base64EncodedString()
                    var parts: [[String: Any]] = [
                        ["type": "image",
                         "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]]
                    ]
                    if !msg.content.isEmpty {
                        parts.append(["type": "text", "text": msg.content])
                    }
                    result.append(["role": "user", "content": parts])
                } else {
                    result.append(["role": "user", "content": msg.content])
                }
                i += 1
            case .assistant:
                if let tcs = msg.toolCalls, !tcs.isEmpty {
                    var parts: [[String: Any]] = []
                    if !msg.content.isEmpty {
                        parts.append(["type": "text", "text": msg.content])
                    }
                    for tc in tcs {
                        parts.append(["type": "tool_use", "id": tc.id,
                                      "name": tc.name, "input": tc.arguments])
                    }
                    result.append(["role": "assistant", "content": parts])
                } else {
                    result.append(["role": "assistant", "content": msg.content])
                }
                i += 1
            case .tool:
                // Collect consecutive tool results into one user turn
                var toolResults: [[String: Any]] = []
                while i < messages.count && messages[i].role == .tool {
                    let t = messages[i]
                    toolResults.append(["type": "tool_result",
                                        "tool_use_id": t.toolCallId ?? "",
                                        "content": t.content])
                    i += 1
                }
                result.append(["role": "user", "content": toolResults])
            }
        }
        return result
    }

    /// Gemini contents format (functionCall / functionResponse parts)
    private func geminiContents(from messages: [AIMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for msg in messages {
            switch msg.role {
            case .system: continue
            case .user:
                if let imgData = msg.imageData {
                    // Vision message: text part + inlineData part
                    var parts: [[String: Any]] = []
                    if !msg.content.isEmpty {
                        parts.append(["text": msg.content])
                    }
                    let b64 = imgData.base64EncodedString()
                    parts.append(["inlineData": ["mimeType": "image/jpeg", "data": b64]])
                    result.append(["role": "user", "parts": parts])
                } else {
                    result.append(["role": "user", "parts": [["text": msg.content]]])
                }
            case .assistant:
                if let tcs = msg.toolCalls, !tcs.isEmpty {
                    var parts: [[String: Any]] = []
                    if !msg.content.isEmpty { parts.append(["text": msg.content]) }
                    for tc in tcs {
                        parts.append(["functionCall": ["name": tc.name, "args": tc.arguments]])
                    }
                    result.append(["role": "model", "parts": parts])
                } else {
                    result.append(["role": "model", "parts": [["text": msg.content]]])
                }
            case .tool:
                // For Gemini, toolCallId stores the function name (set when parsing responses)
                result.append(["role": "user", "parts": [[
                    "functionResponse": [
                        "name": msg.toolCallId ?? "",
                        "response": ["result": msg.content]
                    ]
                ]]])
            }
        }
        return result
    }

    // =========================================================================
    // MARK: - Tool Definition Serializers
    // =========================================================================

    private func openAIToolDefs(_ tools: [AITool]) -> [[String: Any]] {
        tools.map { t in
            ["type": "function",
             "function": ["name": t.name, "description": t.description,
                          "parameters": t.parameters.asDictionary] as [String: Any]]
        }
    }

    private func anthropicToolDefs(_ tools: [AITool]) -> [[String: Any]] {
        tools.map { t in
            ["name": t.name, "description": t.description,
             "input_schema": t.parameters.asDictionary]
        }
    }

    private func geminiToolDefs(_ tools: [AITool]) -> [[String: Any]] {
        guard !tools.isEmpty else { return [] }
        return [["functionDeclarations": tools.map { t in
            ["name": t.name, "description": t.description,
             "parameters": t.parameters.asDictionary]
        }]]
    }

    // =========================================================================
    // MARK: - Argument Helpers
    // =========================================================================

    private func encodeArgs(_ args: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    private func decodeArgs(_ jsonStr: String) -> [String: String] {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj.compactMapValues { $0 is NSNull ? nil : "\($0)" }
    }

    private func toArgStrings(_ dict: [String: Any]) -> [String: String] {
        dict.compactMapValues { $0 is NSNull ? nil : "\($0)" }
    }

    // =========================================================================
    // MARK: - OpenAI
    // =========================================================================

    private func sendOpenAIMessage(
        model: String, messages: [AIMessage],
        systemPrompt: String?, tools: [AITool], temperature: Double?, maxTokens: Int?
    ) async throws -> AIResponse {
        let req = try openAIRequest(model: model, messages: messages,
            systemPrompt: systemPrompt, tools: tools,
            temperature: temperature, maxTokens: maxTokens, stream: false)
        let (data, response) = try await URLSession.shared.data(for: req)
        try checkHTTP(response, data: data, provider: "OpenAI")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any]
        else { throw AIProviderError.invalidResponse }

        let content = message["content"] as? String

        // Parse tool calls from response
        var toolCalls: [ToolCall]? = nil
        if let raw = message["tool_calls"] as? [[String: Any]] {
            let parsed = raw.compactMap { tc -> ToolCall? in
                guard let id  = tc["id"] as? String,
                      let fn  = tc["function"] as? [String: Any],
                      let nm  = fn["name"] as? String,
                      let ars = fn["arguments"] as? String
                else { return nil }
                return ToolCall(id: id, name: nm, arguments: decodeArgs(ars))
            }
            toolCalls = parsed.isEmpty ? nil : parsed
        }

        return AIResponse(
            id: json["id"] as? String ?? UUID().uuidString,
            content: content,
            toolCalls: toolCalls,
            finishReason: first["finish_reason"] as? String ?? "stop",
            usage: openAIUsage(json)
        )
    }

    private func sendOpenAIStream(
        model: String, messages: [AIMessage],
        systemPrompt: String?, temperature: Double?, maxTokens: Int?
    ) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        let req = try openAIRequest(model: model, messages: messages,
            systemPrompt: systemPrompt, tools: [],
            temperature: temperature, maxTokens: maxTokens, stream: true)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    try checkHTTP(response, data: nil, provider: "OpenAI")

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let first = choices.first
                        else { continue }

                        let delta = first["delta"] as? [String: Any]
                        let content = delta?["content"] as? String
                        let finishReason = first["finish_reason"] as? String

                        if content != nil || finishReason != nil {
                            continuation.yield(AIStreamChunk(
                                id: json["id"] as? String ?? UUID().uuidString,
                                content: content,
                                toolCallChunk: nil,
                                finishReason: finishReason,
                                done: finishReason != nil
                            ))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func openAIRequest(
        model: String, messages: [AIMessage], systemPrompt: String?,
        tools: [AITool], temperature: Double?, maxTokens: Int?, stream: Bool
    ) throws -> URLRequest {
        guard let apiKey = try getAPIKey(for: .openai), !apiKey.isEmpty else {
            throw AIProviderError.apiKeyNotFound
        }
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw AIProviderError.networkError
        }

        let chatMessages = openAIMessages(from: messages, systemPrompt: systemPrompt)
        var body: [String: Any] = ["model": model, "messages": chatMessages, "stream": stream]
        // o-series and newer models (o1, o3, gpt-5…) use max_completion_tokens
        let usesCompletionTokens = model.hasPrefix("o1") || model.hasPrefix("o3")
            || model.hasPrefix("o4") || model.hasPrefix("gpt-5")
        if let t = temperature, !usesCompletionTokens { body["temperature"] = t }
        if let m = maxTokens {
            body[usesCompletionTokens ? "max_completion_tokens" : "max_tokens"] = m
        }
        if !tools.isEmpty {
            body["tools"] = openAIToolDefs(tools)
            body["tool_choice"] = "auto"
        }

        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func openAIUsage(_ json: [String: Any]) -> AIUsage? {
        guard let u = json["usage"] as? [String: Any],
              let p = u["prompt_tokens"] as? Int,
              let c = u["completion_tokens"] as? Int else { return nil }
        return AIUsage(promptTokens: p, completionTokens: c, totalTokens: p + c)
    }

    // =========================================================================
    // MARK: - Anthropic
    // =========================================================================

    private func sendAnthropicMessage(
        model: String, messages: [AIMessage],
        systemPrompt: String?, tools: [AITool], temperature: Double?, maxTokens: Int?
    ) async throws -> AIResponse {
        let req = try anthropicRequest(model: model, messages: messages,
            systemPrompt: systemPrompt, tools: tools,
            temperature: temperature, maxTokens: maxTokens, stream: false)
        let (data, response) = try await URLSession.shared.data(for: req)
        try checkHTTP(response, data: data, provider: "Anthropic")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]]
        else { throw AIProviderError.invalidResponse }

        var textContent: String? = nil
        var toolCalls: [ToolCall] = []

        for block in contentBlocks {
            switch block["type"] as? String {
            case "text":
                textContent = block["text"] as? String
            case "tool_use":
                guard let id    = block["id"] as? String,
                      let name  = block["name"] as? String,
                      let input = block["input"] as? [String: Any]
                else { continue }
                toolCalls.append(ToolCall(id: id, name: name, arguments: toArgStrings(input)))
            default:
                break
            }
        }

        return AIResponse(
            id: json["id"] as? String ?? UUID().uuidString,
            content: textContent,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            finishReason: json["stop_reason"] as? String ?? "end_turn",
            usage: anthropicUsage(json)
        )
    }

    private func sendAnthropicStream(
        model: String, messages: [AIMessage],
        systemPrompt: String?, temperature: Double?, maxTokens: Int?
    ) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        let req = try anthropicRequest(model: model, messages: messages,
            systemPrompt: systemPrompt, tools: [],
            temperature: temperature, maxTokens: maxTokens, stream: true)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    try checkHTTP(response, data: nil, provider: "Anthropic")

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = json["type"] as? String
                        else { continue }

                        switch type {
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any],
                               delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String {
                                continuation.yield(AIStreamChunk(
                                    id: UUID().uuidString, content: text,
                                    toolCallChunk: nil, finishReason: nil, done: false))
                            }
                        case "message_delta":
                            if let delta = json["delta"] as? [String: Any],
                               let stopReason = delta["stop_reason"] as? String {
                                continuation.yield(AIStreamChunk(
                                    id: UUID().uuidString, content: nil,
                                    toolCallChunk: nil, finishReason: stopReason, done: true))
                            }
                        case "message_stop":
                            continuation.finish()
                            return
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func anthropicRequest(
        model: String, messages: [AIMessage], systemPrompt: String?,
        tools: [AITool], temperature: Double?, maxTokens: Int?, stream: Bool
    ) throws -> URLRequest {
        guard let apiKey = try getAPIKey(for: .anthropic), !apiKey.isEmpty else {
            throw AIProviderError.apiKeyNotFound
        }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AIProviderError.networkError
        }

        let chatMessages = anthropicMessages(from: messages)
        var body: [String: Any] = [
            "model": model,
            "messages": chatMessages,
            "max_tokens": maxTokens ?? 4096,
            "stream": stream
        ]
        if let systemPrompt, !systemPrompt.isEmpty { body["system"] = systemPrompt }
        if let t = temperature { body["temperature"] = t }
        if !tools.isEmpty      { body["tools"] = anthropicToolDefs(tools) }

        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func anthropicUsage(_ json: [String: Any]) -> AIUsage? {
        guard let u = json["usage"] as? [String: Any],
              let i = u["input_tokens"] as? Int,
              let o = u["output_tokens"] as? Int else { return nil }
        return AIUsage(promptTokens: i, completionTokens: o, totalTokens: i + o)
    }

    // =========================================================================
    // MARK: - Gemini
    // =========================================================================

    private func sendGeminiMessage(
        model: String, messages: [AIMessage],
        systemPrompt: String?, tools: [AITool], temperature: Double?, maxTokens: Int?
    ) async throws -> AIResponse {
        let req = try geminiRequest(model: model, messages: messages,
            systemPrompt: systemPrompt, tools: tools,
            temperature: temperature, maxTokens: maxTokens, stream: false)
        let (data, response) = try await URLSession.shared.data(for: req)
        try checkHTTP(response, data: data, provider: "Gemini")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else { throw AIProviderError.invalidResponse }

        var textContent: String? = nil
        var toolCalls: [ToolCall] = []

        for part in parts {
            if let text = part["text"] as? String {
                textContent = (textContent ?? "") + text
            } else if let fc = part["functionCall"] as? [String: Any],
                      let name = fc["name"] as? String {
                let args = fc["args"] as? [String: Any] ?? [:]
                // Use name as the ID — Gemini has no unique call IDs
                toolCalls.append(ToolCall(id: name, name: name, arguments: toArgStrings(args)))
            }
        }

        return AIResponse(
            id: UUID().uuidString,
            content: textContent,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            finishReason: first["finishReason"] as? String ?? "STOP",
            usage: geminiUsage(json)
        )
    }

    private func sendGeminiStream(
        model: String, messages: [AIMessage],
        systemPrompt: String?, temperature: Double?, maxTokens: Int?
    ) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        let req = try geminiRequest(model: model, messages: messages,
            systemPrompt: systemPrompt, tools: [],
            temperature: temperature, maxTokens: maxTokens, stream: true)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    try checkHTTP(response, data: nil, provider: "Gemini")

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let candidates = json["candidates"] as? [[String: Any]],
                              let first = candidates.first,
                              let content = first["content"] as? [String: Any],
                              let parts = content["parts"] as? [[String: Any]],
                              let text = parts.first?["text"] as? String
                        else { continue }

                        let finishReason = first["finishReason"] as? String
                        let done = finishReason != nil && finishReason != "NONE"

                        continuation.yield(AIStreamChunk(
                            id: UUID().uuidString,
                            content: text.isEmpty ? nil : text,
                            toolCallChunk: nil,
                            finishReason: done ? finishReason : nil,
                            done: done
                        ))

                        if done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func geminiRequest(
        model: String, messages: [AIMessage], systemPrompt: String?,
        tools: [AITool], temperature: Double?, maxTokens: Int?, stream: Bool
    ) throws -> URLRequest {
        guard let apiKey = try getAPIKey(for: .gemini), !apiKey.isEmpty else {
            throw AIProviderError.apiKeyNotFound
        }

        let endpoint = stream ? "streamGenerateContent" : "generateContent"
        var urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):\(endpoint)?key=\(apiKey)"
        if stream { urlStr += "&alt=sse" }

        guard let url = URL(string: urlStr) else { throw AIProviderError.networkError }

        let contents = geminiContents(from: messages)
        var body: [String: Any] = ["contents": contents]
        if let systemPrompt, !systemPrompt.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemPrompt]]]
        }
        if !tools.isEmpty { body["tools"] = geminiToolDefs(tools) }
        var genConfig: [String: Any] = [:]
        if let t = temperature { genConfig["temperature"] = t }
        if let m = maxTokens  { genConfig["maxOutputTokens"] = m }
        if !genConfig.isEmpty { body["generationConfig"] = genConfig }

        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func geminiUsage(_ json: [String: Any]) -> AIUsage? {
        guard let meta = json["usageMetadata"] as? [String: Any],
              let p = meta["promptTokenCount"] as? Int,
              let c = meta["candidatesTokenCount"] as? Int else { return nil }
        return AIUsage(promptTokens: p, completionTokens: c, totalTokens: p + c)
    }

    // =========================================================================
    // MARK: - Ollama
    // =========================================================================

    private func sendOllamaMessage(
        model: String, messages: [AIMessage],
        systemPrompt: String?, tools: [AITool], temperature: Double?
    ) async throws -> AIResponse {
        let req = try ollamaRequest(model: model, messages: messages,
            systemPrompt: systemPrompt, tools: tools, temperature: temperature, stream: false)
        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIProviderError.providerError("Ollama HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any]
        else { throw AIProviderError.invalidResponse }

        let content = message["content"] as? String

        // Parse tool calls (Ollama uses OpenAI-compatible format)
        var toolCalls: [ToolCall]? = nil
        if let raw = message["tool_calls"] as? [[String: Any]] {
            let parsed = raw.compactMap { tc -> ToolCall? in
                guard let fn   = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String
                else { return nil }
                let id = tc["id"] as? String ?? UUID().uuidString
                let args: [String: String]
                if let d = fn["arguments"] as? [String: Any] {
                    args = toArgStrings(d)
                } else if let s = fn["arguments"] as? String {
                    args = decodeArgs(s)
                } else {
                    args = [:]
                }
                return ToolCall(id: id, name: name, arguments: args)
            }
            toolCalls = parsed.isEmpty ? nil : parsed
        }

        return AIResponse(
            id: UUID().uuidString,
            content: content?.isEmpty == false ? content : nil,
            toolCalls: toolCalls,
            finishReason: json["done_reason"] as? String ?? "stop",
            usage: ollamaUsage(json)
        )
    }

    private func sendOllamaStream(
        model: String, messages: [AIMessage],
        systemPrompt: String?, temperature: Double?
    ) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        let req = try ollamaRequest(model: model, messages: messages,
            systemPrompt: systemPrompt, tools: [], temperature: temperature, stream: true)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)

                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        continuation.finish(throwing: AIProviderError.providerError(
                            "Ollama HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
                        return
                    }

                    for try await line in bytes.lines {
                        guard !line.isEmpty,
                              let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        let done = json["done"] as? Bool ?? false
                        let content = (json["message"] as? [String: Any])?["content"] as? String

                        continuation.yield(AIStreamChunk(
                            id: UUID().uuidString, content: content, toolCallChunk: nil,
                            finishReason: done ? (json["done_reason"] as? String ?? "stop") : nil,
                            done: done
                        ))

                        if done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private var ollamaBaseURL: String {
        UserDefaults.standard.string(forKey: "settings.ollamaURL") ?? AppConfig.defaultOllamaURL
    }

    private func ollamaRequest(
        model: String, messages: [AIMessage], systemPrompt: String?,
        tools: [AITool], temperature: Double?, stream: Bool
    ) throws -> URLRequest {
        let urlStr = ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/api/chat"
        guard let url = URL(string: urlStr) else { throw AIProviderError.networkError }

        let chatMessages = openAIMessages(from: messages, systemPrompt: systemPrompt)
        var body: [String: Any] = ["model": model, "messages": chatMessages, "stream": stream]
        if let t = temperature { body["options"] = ["temperature": t] }
        if !tools.isEmpty      { body["tools"] = openAIToolDefs(tools) }

        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func fetchOllamaModels() async throws -> [String] {
        let urlStr = ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/api/tags"
        guard let url = URL(string: urlStr) else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    private func ollamaUsage(_ json: [String: Any]) -> AIUsage? {
        guard let p = json["prompt_eval_count"] as? Int,
              let c = json["eval_count"] as? Int else { return nil }
        return AIUsage(promptTokens: p, completionTokens: c, totalTokens: p + c)
    }

    // =========================================================================
    // MARK: - Shared Helpers
    // =========================================================================

    private func checkHTTP(_ response: URLResponse, data: Data?, provider: String) throws {
        guard let http = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        switch http.statusCode {
        case 200: return
        case 401: throw AIProviderError.apiKeyNotFound
        case 429: throw AIProviderError.rateLimitExceeded
        default:
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw AIProviderError.providerError("\(provider) HTTP \(http.statusCode): \(body.prefix(200))")
        }
    }
}

// MARK: - AI Provider Error

enum AIProviderError: Error, LocalizedError {
    case apiKeyNotFound
    case invalidResponse
    case networkError
    case rateLimitExceeded
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .apiKeyNotFound:       return "API key not found. Add it in Settings → API Keys."
        case .invalidResponse:      return "Unexpected response from the AI provider."
        case .networkError:         return "Could not connect to the AI provider."
        case .rateLimitExceeded:    return "Rate limit exceeded. Please try again later."
        case .providerError(let m): return m
        }
    }
}
