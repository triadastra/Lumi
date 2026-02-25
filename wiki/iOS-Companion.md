# iOS Companion

## Overview

The iOS app is a full companion to the Mac app. It provides a mobile chat interface with streaming responses, Bonjour-based Mac discovery and pairing, remote Mac control, and data sync. It runs on iOS 18.0 or later and is built from the same Swift Package as the Mac app.

## iOS App Structure

The iOS app uses a four-tab `TabView`:

| Tab | Content |
|---|---|
| **Agents** | List of all agents with search, create, delete, and star (primary) |
| **Chat** | Conversation list and chat view with streaming message bubbles |
| **Remote** | Mac discovery and remote control panel |
| **Settings** | API keys for all providers, Ollama URL, About |

## Pairing with a Mac

Pairing uses Bonjour over the local network. Both devices must be on the same Wi-Fi network.

**On Mac**: the Bonjour server (`MacRemoteServer`) starts automatically at launch and advertises `_lumiagent._tcp` on port 47285. The **Devices** pane in the Mac app shows server status and connected clients.

**On iOS**: open the **Remote** tab. The app browses for `_lumiagent._tcp` services and displays discovered Macs. Tap a Mac to connect.

**Approval**: the first connection from an iOS device triggers an approval prompt in the Mac app's **Devices** pane. The Mac user must accept before the connection is established. Subsequent connections from the same device are approved automatically.

## USB Detection

When an iPhone is connected to a Mac via USB cable, Lumi detects it using IOKit (`IOUSBDeviceClassName`, Apple Vendor ID `0x05AC`). The **Devices** pane on Mac shows a USB indicator, and `AppState.isUSBDeviceConnected` is set to `true`. This is informational — the actual communication still uses the TCP/Bonjour channel.

## Remote Control

Once connected, the iOS Remote tab exposes:

| Action | What it does |
|---|---|
| **Ping** | Verify the connection is alive; shows round-trip time |
| **Sync Now** | Pull agent data, conversations, automations, and API keys from the Mac |
| **Screenshot** | Request and display a JPEG screenshot from the Mac |
| **Set Volume** | Set Mac output volume to 25%, 50%, or 100% |
| **Run Shell** | Send an arbitrary shell command and display the output |

Screenshots are displayed inline in the Remote tab after capture.

## Wire Protocol

The TCP connection uses a simple framing protocol: a 4-byte big-endian integer length prefix followed by UTF-8 JSON. Both sides use `NWConnection` (Network framework).

Commands are JSON objects with a `command` field and optional parameters. Responses include a `success` flag and command-specific payload.

## Data Sync

**Sync Now** pulls the following files from the Mac to iOS:
- `agents.json` — all agent configurations
- `conversations.json` — all conversation history
- `automations.json` — all automation rules
- `sync_settings.json` — UserDefaults snapshot
- `sync_api_keys.json` — API key snapshot

After sync, the iOS app's `AppState` is populated with the Mac's data. This is a one-way pull — iOS does not push changes back to the Mac.

## iOS Chat

The iOS chat interface (`iOSChatView`) is feature-equivalent to the macOS `ChatView`:
- Streaming message bubbles with animated typing indicator (three dots) while the model is generating
- Auto-scroll to the latest message
- Markdown rendering in message bubbles
- Voice input button (Whisper transcription)
- Image attachments for vision-capable models
- Tool call records shown inline

The AI provider calls are made directly from iOS using the API keys synced from Mac (or entered directly in **Settings → API Keys** on iOS). The iOS app does not route AI requests through the Mac.

## iOS Settings

**Settings → API Keys** on iOS stores keys in `UserDefaults` on the device, independent of the Mac. Syncing from Mac overwrites these with the Mac's keys. Available settings:

- OpenAI, Anthropic, Gemini, Qwen API keys
- Ollama base URL
- About / version information
