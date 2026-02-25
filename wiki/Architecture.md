# Architecture

## Layer Overview

```
Presentation/     SwiftUI views, platform-specific overlays
     │
App/              AppState (central state), hotkey manager, automation engine
     │
Domain/           Models, repository protocols, tool registry, agent execution engine
     │
Data/             AI provider repository, agent repository, database manager
     │
Infrastructure/   Audio, network (Bonjour, USB), screen capture, security
```

The app is built as a Swift Package (SPM) with no Xcode project dependency for the build itself. A single `LumiAgent` executable target covers both macOS and iOS via `#if os(macOS)` / `#if os(iOS)` guards throughout.

## AppState

`AppState` is a `@MainActor final class ObservableObject` and the single source of truth for all runtime state. It is injected as an `@EnvironmentObject` into every view.

It holds:
- `agents: [Agent]` — all configured agents
- `conversations: [Conversation]` — all conversations with full message history
- `automations: [AutomationRule]` — all automation rules
- `toolCallHistory: [ToolCallRecord]` — audit log of every tool call
- Navigation state — selected sidebar item, selected agent/conversation IDs
- `remoteServer: MacRemoteServer` (macOS) — the Bonjour TCP server
- `isUSBDeviceConnected: Bool` — set by `USBDeviceObserver`

`AppState` owns the streaming agentic loop in `streamResponse()`. The loop:
1. Builds the message history for the current conversation
2. Calls `AIProviderRepository.sendMessageStream()` with tool definitions
3. If the model returns tool calls, dispatches each to `ToolRegistry`
4. Appends results to history and loops back to step 2
5. Continues until the model returns a plain text response
6. Streams text deltas into the conversation in real time

## Domain Layer

**Models** (`Domain/Models/`) define the core data types: `Agent`, `AgentConfiguration`, `Conversation`, `SpaceMessage`, `AutomationRule`, `ToolCallRecord`. All conform to `Codable` for JSON persistence and sync.

**Repository protocols** (`Domain/Repositories/`) define interfaces that the Data layer implements. This allows the presentation and domain layers to depend only on protocols, not concrete HTTP or file I/O code.

**ToolRegistry** (`Domain/Services/ToolRegistry.swift`) is a singleton that registers all tools at startup. Each `RegisteredTool` carries its name, description, category, risk level, JSON-Schema parameter definition, and an `async` handler closure. The registry exposes the tool list to the AI and dispatches execution.

**AgentExecutionEngine** (`Domain/Services/AgentExecutionEngine.swift`) is an `ObservableObject` that wraps a standalone agentic execution loop outside of a conversation context. Used for background automation runs.

## Data Layer

**AIProviderRepository** implements all five AI provider integrations behind a single protocol. Each provider has its own request/response format; the repository normalizes them into `AIMessage` / `AIStreamChunk` types that the domain layer uses uniformly.

**AgentRepository** wraps `DatabaseManager` for typed CRUD on `Agent` objects.

**DatabaseManager** (`Infrastructure/Database/DatabaseManager.swift`) persists data as JSON files in `~/Library/Application Support/LumiAgent/`:
- `agents.json`
- `conversations.json`
- `automations.json`
- `sync_settings.json` (UserDefaults snapshot for iOS sync)
- `sync_api_keys.json` (API key snapshot for iOS sync)

## Key Design Patterns

**@MainActor isolation** — all UI-touching code is annotated `@MainActor`. Background work (network, tool execution) runs on the cooperative thread pool and publishes results back to the main actor.

**AsyncThrowingStream** — streaming AI responses are modeled as `AsyncThrowingStream<AIStreamChunk, Error>` so callers can `for await` over deltas without callbacks.

**Platform gating** — `#if os(macOS)` / `#if os(iOS)` guards are used throughout. iOS stubs exist for macOS-only types so the same source compiles on both platforms.

**Singleton services** — `DatabaseManager.shared`, `MacRemoteServer.shared`, `ToolRegistry.shared`, `USBDeviceObserver.shared` are singletons because they manage system resources or shared state that must exist for the lifetime of the app.

**Repository pattern** — `AIProviderRepositoryProtocol` and `AgentRepositoryProtocol` abstract the data layer. Concrete implementations are injected at startup via `AppState`.

## Platform Split

| Feature | macOS | iOS |
|---|---|---|
| Tool execution | Full (60+ tools) | None (read-only companion) |
| Desktop control | Yes | No |
| Global hotkeys | Yes (Carbon HIToolbox) | No |
| Bonjour TCP server | Yes (`MacRemoteServer`) | No |
| Bonjour TCP client | No | Yes (`IOSBonjourDiscovery`) |
| USB device detection | Yes (IOKit) | No |
| Apple Health | Read (HealthKit) | Read (HealthKit) |
| Voice | Whisper + TTS + Realtime VAD | Whisper + TTS |
| AutomationEngine | Yes | No |
