# Security and Permissions

## macOS Privacy Permissions

Lumi requests the following macOS privacy entitlements. Each is optional — features that need a permission simply fail gracefully if it is not granted.

| Permission | System Settings pane | Required for |
|---|---|---|
| Accessibility | Privacy & Security → Accessibility | Hotkeys, text capture/replace, mouse/keyboard control |
| Screen Recording | Privacy & Security → Screen Recording | Screenshots, window capture, Agent Mode |
| Automation | Privacy & Security → Automation | AppleScript tools, iWork integration |
| Microphone | Privacy & Security → Microphone | Voice transcription, realtime VAD |
| Local Network | Privacy & Security → Local Network | Bonjour server, iOS pairing |

Use **Settings → Permissions → Enable Full Access (Guided)** to open each required pane in sequence.

## App Sandbox

Lumi runs in the macOS App Sandbox (`com.apple.security.app-sandbox = true`). Key sandbox entitlements enabled:

- `com.apple.security.network.client` — outbound network connections (AI APIs)
- `com.apple.security.network.server` — Bonjour TCP server for iOS
- `com.apple.security.automation.apple-events` — AppleScript execution
- `com.apple.security.files.user-selected.read-write` — file access for user-chosen files
- `com.apple.security.temporary-exception.apple-events` — targeted Apple Events

The sandbox restricts what the app can access by default. The entitlements file (`Config/LumiAgent.entitlements`) defines the full set.

`NSAppTransportSecurity` has `NSAllowsArbitraryLoads: true` to allow connections to local Ollama (`http://127.0.0.1:11434`) and non-HTTPS AI endpoints.

## Per-Agent Security Policy

Every agent has a `SecurityPolicy` that controls tool call execution. See [Agents and Configuration](Agents-and-Configuration) for the full field list. Key controls:

**`autoApproveThreshold`** — tools with risk level at or below this value run without asking. The recommended setting for general-purpose agents is `.medium`, which auto-approves reads and web searches but requires approval for shell execution and desktop control.

**`requireApproval`** — when `true`, every tool call prompts for approval regardless of risk level. Use this for agents that work with sensitive files or systems.

**`blacklistedCommands`** — a list of shell command substrings that are always rejected before execution. The default list covers known destructive patterns:
- `rm -rf /`
- `dd if=/dev/zero`
- `:(){ :|:& };:` (fork bomb)
- `mkfs`
- `format`

Add your own patterns here for any commands you never want an agent to run.

**`restrictedPaths`** — filesystem paths the agent cannot write to. Default: `/System`, `/Library`, `/usr`, `/bin`, `/sbin`. The check is a prefix match, so `/System` blocks `/System/Library/...` as well.

**`allowSudo`** — when `false` (default), any shell command containing `sudo` is rejected. Set to `true` only for agents that genuinely need to perform administrative tasks.

**`maxExecutionTime`** — individual tool call timeout in seconds. Default is 300 seconds (5 minutes). Long-running shell commands that exceed this are killed.

## Risk Levels

| Level | Typical tools |
|---|---|
| `.low` | `read_file`, `list_directory`, `get_system_info`, `git_status`, `recall` |
| `.medium` | `write_file`, `web_search`, `fetch_url`, `git_commit`, `set_volume` |
| `.high` | `run_shell_command`, `screenshot`, `click_mouse`, `type_text`, `set_clipboard` |
| `.critical` | `run_applescript` |

## Tool Call Audit Log

Every tool call is recorded in `ToolCallRecord` with:
- Agent name and ID
- Tool name and arguments
- Result (truncated if large)
- Timestamp and success flag

The audit log is visible in **History** in the sidebar. It persists across restarts and is stored in `conversations.json`.

## Privileged Helper (Future)

`LumiAgentHelper/` contains a stub for a privileged XPC helper daemon intended for operations that require root access outside the sandbox. The helper is not yet functional — the `executeCommand()` method is a placeholder. When implemented, it will use an XPC protocol to receive commands from the main app and execute them with elevated privileges, with the main app managing the authorization dialog.
