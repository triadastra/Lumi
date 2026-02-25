# Getting Started

## Requirements

- macOS 15.0 or later
- Swift 6.2 toolchain (ships with Xcode 16+)
- At least one AI provider API key, or Ollama running locally
- iOS 18.0 or later for the companion app (optional)

## Install

```bash
git clone https://github.com/Lumicake/Agent-Lumi.git
cd Agent-Lumi
./run_app.sh
```

`run_app.sh` builds the project, assembles the `.app` bundle in `runable/LumiAgent.app`, signs it, and opens it. On first run, macOS will ask for the privacy permissions described below.

## Grant macOS Permissions

Lumi needs several macOS privacy grants to use its full feature set. Open **Settings → Permissions** and click **Enable Full Access (Guided)**, which opens each relevant System Settings pane in sequence.

| Permission | Required for |
|---|---|
| Accessibility | Mouse/keyboard control, text assist hotkeys, reading UI elements |
| Screen Recording | Screenshots, window capture, Agent Mode vision |
| Automation | AppleScript execution against other apps |
| Microphone | Voice transcription |
| Local Network | Bonjour server for iOS pairing |

Each permission is optional if you don't use that feature. Accessibility and Screen Recording are needed for any desktop-control tool.

## Add API Keys

Open **Settings → API Keys** and enter keys for the providers you want to use:

- **OpenAI** — used for GPT models, Whisper transcription, and TTS
- **Anthropic** — Claude models
- **Google Gemini** — Gemini models
- **Alibaba Qwen** — Qwen models via DashScope
- **Ollama** — no key needed; configure the base URL (default: `http://127.0.0.1:11434`)

Keys are stored in `UserDefaults` on your Mac and synced to iOS on request.

## Create Your First Agent

1. Click **New Agent** (`⌘N`) in the sidebar
2. Give the agent a name
3. Select a provider and model
4. Optionally write a system prompt describing the agent's role
5. Adjust the tool set — by default all tools are available; restrict by listing specific tool names in **Enabled Tools**
6. Set a security policy if desired (see [Security and Permissions](Security-and-Permissions))
7. Save

## Start a Conversation

1. Select **Agent Space** in the sidebar
2. Click **New Conversation** and choose your agent
3. Type a message and press Return
4. Lumi streams the response and, if the agent calls tools, shows each tool call and its result inline

## What to Try First

- Ask the agent to list files in a directory
- Ask it to write a short script and run it
- Enable **Agent Mode** in a conversation and ask it to take a screenshot
- Open the quick-action panel (`⌥⌘L`) in any app and try **Analyze Page** with a document open in Pages
