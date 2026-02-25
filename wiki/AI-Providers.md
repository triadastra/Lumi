# AI Providers

Lumi supports five AI providers through a unified interface. All providers support non-streaming and streaming chat, multi-turn history, tool/function calling, and image attachments (vision).

## Provider Overview

| Provider | Endpoint | Auth | Notes |
|---|---|---|---|
| OpenAI | `api.openai.com/v1/chat/completions` | Bearer token | Also used for Whisper and TTS |
| Anthropic | `api.anthropic.com/v1/messages` | `x-api-key` header | Claude 3/4 series |
| Google Gemini | `generativelanguage.googleapis.com/v1beta/…` | URL `?key=` param | Gemini 1.5/2.0 series |
| Alibaba Qwen | `dashscope.aliyuncs.com/…` | Bearer token | OpenAI-compatible endpoint |
| Ollama | `http://127.0.0.1:11434/api/chat` | None | Local models, no key needed |

## Configuration

API keys are stored in `UserDefaults` under `lumiagent.apikey.{provider}` and entered in **Settings → API Keys**.

For Ollama, configure the base URL in **Settings → API Keys** (default: `http://127.0.0.1:11434`). The model dropdown in the agent editor fetches the available model list live from the Ollama server.

## OpenAI

Set your key in **Settings → API Keys → OpenAI**.

Recommended models: `gpt-4o`, `gpt-4o-mini`, `o3`, `o4-mini`.

OpenAI is also the provider for:
- **Whisper** (`whisper-1`) — voice transcription
- **TTS** (`gpt-4o-mini-tts`, voice `alloy`) — spoken replies
- **Realtime API** — WebSocket-based voice activity detection

## Anthropic

Set your key in **Settings → API Keys → Anthropic**.

Recommended models: `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`.

Anthropic uses a different request format (not OpenAI-compatible). Tool definitions are translated automatically by `AIProviderRepository`.

## Google Gemini

Set your key in **Settings → API Keys → Gemini**.

Recommended models: `gemini-2.0-flash`, `gemini-2.0-pro`, `gemini-1.5-pro`.

Gemini uses its own `generateContent` API format. Tool definitions and message history are translated by `AIProviderRepository`.

## Alibaba Qwen

Set your key in **Settings → API Keys → Qwen**.

The DashScope endpoint is OpenAI-compatible, so the request format is identical to OpenAI. Recommended models: `qwen-max`, `qwen-plus`, `qwen-turbo`.

## Ollama

No key needed. Ollama must be running locally before creating an Ollama-backed agent.

```bash
ollama serve
```

The agent editor fetches the list of installed models from `http://127.0.0.1:11434/api/tags`. Pull models with `ollama pull <model>` before using them.

Ollama does not support vision (image attachments) for most models. Tool calling support depends on the model.

## Unified Message Format

All providers are normalized to a common type set:

- `AIMessage` — a single message with role (system / user / assistant / tool), content, optional tool call IDs, and optional image data
- `AIStreamChunk` — a streaming delta with optional text delta and optional tool call delta
- `AITool` / `AIToolParameters` / `AIToolProperty` — JSON Schema-style tool definition
- `AIResponse` — a complete response with content, tool calls, and token usage
- `ToolCall` — a resolved tool call with id, name, and arguments

The `AIProviderRepository` translates between these types and each provider's wire format.
