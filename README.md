<img width="64" height="64" alt="icon_32x32@2x" src="https://github.com/user-attachments/assets/fd72077f-0790-47cf-a22b-a7345ee53806" />
## Lumi Agent


A macOS-first AI agent platform with tool execution, desktop automation, and an iOS companion app.

Agents can read and write files, run shell commands, search the web, control the desktop, execute code, and chain tool calls autonomously. The iOS app pairs over Wi-Fi or USB to provide a mobile chat interface and remote Mac control.
<img width="1112" height="764" alt="Screenshot 2026-02-25 at 10 44 24 PM" src="https://github.com/user-attachments/assets/6a6784ee-ad2e-4597-b888-6582e93155d9" />

---

## Features

**Agent execution**
- Create and configure multiple agents backed by any supported AI provider
- Streaming agentic loop: AI plans → calls tools → feeds results back → repeats until done
- 60+ built-in tools across files, shell, web, git, clipboard, screen control, memory, and system
- Per-agent security policy: risk thresholds, command blacklist, sudo toggle, auto-approve level
<img width="1112" height="764" alt="Screenshot 2026-02-25 at 10 45 56 PM" src="https://github.com/user-attachments/assets/7aeb50c5-e4dc-43a0-85d9-ddeaa6ffb25f" />

**macOS integration**
- Global hotkeys for a command palette and quick-action panel, available in any app
- Text-assist hotkeys to rewrite, extend, or grammar-correct selected text in any app
- macOS Services integration (right-click menu)
- Automation rules triggered by app launch, schedule, Bluetooth, screen unlock, and more
- Optional desktop control: mouse, keyboard, screenshots, AppleScript
<img width="1112" height="764" alt="Screenshot 2026-02-25 at 10 48 47 PM" src="https://github.com/user-attachments/assets/3641b2f7-1e5b-4121-bbec-3e5b66eaa7d7" />


**iOS companion**
- Full chat interface with streaming responses
- Bonjour discovery and TCP pairing with the Mac
- USB device detection via IOKit
- Remote Mac control: screenshots, shell commands, volume
- Syncs agents, conversations, automations, and API keys from Mac
<img width="1112" height="764" alt="Screenshot 2026-02-25 at 10 47 09 PM" src="https://github.com/user-attachments/assets/e465de38-bc70-48b0-8486-4a71276042ae" />

**Voice**
- Push-to-talk transcription via OpenAI Whisper
- Realtime voice activity detection (WebSocket VAD)
- Text-to-speech replies via OpenAI TTS

**AI providers**
- OpenAI (GPT-4o, o3, etc.)
- Anthropic (Claude 3/4 series)
- Google Gemini
- Alibaba Qwen
- Ollama (local models, auto-fetches model list)

---

## Safety Notice

Depending on enabled tools and security settings, an agent can read and write files, run shell commands, control UI elements, and execute AppleScript. Review **Settings → Security** and your per-agent security policy before enabling elevated capabilities. Restrict tools on a per-agent basis using the `enabledTools` list in agent configuration.

---

## Requirements

- macOS 15.0 or later (primary platform)
- iOS 18.0 or later (companion app)
- Swift 6.2 toolchain
- API key for at least one cloud provider, or Ollama running locally

---

## Build and Run (Native Without Xcode - macOS Only)

```bash
git clone https://github.com/triadastra/Lumi.git
cd Lumi
./build_unsigned_dmg.sh
```

## Build and Distribute (iOS and macOS)

```bash
git clone https://github.com/triadastra/Lumi.git
```
Then open this project with Xcode > Run. Pair up with your other devices.

---

## First Run

1. Open **Settings → API Keys** and enter keys for the providers you want to use
2. Open **Settings → Permissions** and click **Enable Full Access (Guided)** to complete the required macOS privacy grants (Accessibility, Screen Recording, Automation)
3. Create your first agent with a name, provider, model, and system prompt
4. Open **Agent Space**, start a conversation, and send a message

---

## Global Hotkeys

| Shortcut | Action |
|---|---|
| `⌘L` or `^L` | Open command palette |
| `⌥⌘L` | Open quick-action panel |
| `⌥⌘E` | Extend selected text with AI |
| `⌥⌘G` | Grammar-fix selected text |
| `⌥⌘R` | Treat selection as an instruction |
| `⌘,` | Open Settings |
| `⌘N` | New agent |

Hotkeys work system-wide. The command palette and quick-action panel are floating overlays that remain accessible in any app.

---

## Project Structure

```
Lumi/
├── App/              # Entry point, AppState, hotkeys, automation engine
├── Domain/           # Models, repository protocols, tool registry, agent execution
├── Data/             # AI provider repository, agent repository, database manager
├── Infrastructure/   # Audio, network (Bonjour server, USB), screen capture, security
└── Presentation/     # SwiftUI views organized by feature
```

---

## Documentation

Full documentation is in the [wiki](wiki/).

- [Getting Started](wiki/Getting-Started.md)
- [Architecture](wiki/Architecture.md)
- [Agents and Configuration](wiki/Agents-and-Configuration.md)
- [AI Providers](wiki/AI-Providers.md)
- [Tool Catalog](wiki/Tool-Catalog.md)
- [Desktop Control and Agent Mode](wiki/Desktop-Control-and-Agent-Mode.md)
- [Hotkeys and Quick Actions](wiki/Hotkeys-and-Quick-Actions.md)
- [iOS Companion](wiki/iOS-Companion.md)
- [Automation](wiki/Automation.md)
- [Voice](wiki/Voice.md)
- [Security and Permissions](wiki/Security-and-Permissions.md)
- [Building and Deployment](wiki/Building-and-Deployment.md)
- [Troubleshooting](wiki/Troubleshooting.md)

---

## Contributing

PRs are welcome. Keep changes focused and include clear validation steps.

## License

See [LICENSE](LICENSE).
