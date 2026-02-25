# Troubleshooting

## Hotkeys Not Working

**Symptom**: pressing `⌘L`, `⌥⌘L`, or the text-assist shortcuts does nothing.

**Cause**: hotkeys require the Accessibility permission to register with the system.

**Fix**:
1. Open **System Settings → Privacy & Security → Accessibility**
2. Ensure `LumiAgent` is in the list and its toggle is on
3. If the entry is missing, open **Settings → Permissions** in Lumi and click **Enable Full Access (Guided)**
4. If it still doesn't work after granting, quit and relaunch Lumi — accessibility grants sometimes require a restart of the app

---

## Screenshots / Agent Mode Not Working

**Symptom**: `screenshot` tool returns an error; Agent Mode appears to do nothing.

**Cause**: Screen Recording permission is required.

**Fix**:
1. Open **System Settings → Privacy & Security → Screen Recording**
2. Add `LumiAgent` and enable it
3. Relaunch Lumi (Screen Recording changes take effect only after restart)

---

## AppleScript / Automation Errors

**Symptom**: `run_applescript` or iWork tools fail with permission errors.

**Fix**:
1. Open **System Settings → Privacy & Security → Automation**
2. Expand `LumiAgent` and enable the apps it needs to control (Finder, Pages, Numbers, Keynote, System Events)

---

## Ollama Models Not Appearing

**Symptom**: the model dropdown in the agent editor is empty for Ollama.

**Causes and fixes**:
- Ollama is not running. Start it: `ollama serve`
- The base URL in **Settings → API Keys → Ollama URL** is wrong. Default is `http://127.0.0.1:11434`
- No models are installed. Pull one: `ollama pull llama3.2`
- The sandbox is blocking the connection. This should not happen with the default entitlements, but verify `NSAllowsArbitraryLoads` is `true` in `Info.plist`

---

## iOS App Cannot Discover Mac

**Symptom**: the **Remote** tab on iOS shows no Macs.

**Causes and fixes**:
- Mac and iPhone are on different networks or subnets. Both must be on the same local network
- The Mac's Bonjour server is not running. Check the **Devices** pane — it should show "Server Running" and the port (47285)
- Local Network permission on iOS was denied. Go to **iPhone Settings → Privacy & Security → Local Network** and enable `LumiAgent`
- Firewall on Mac is blocking port 47285. Open **System Settings → Network → Firewall** and add an exception, or turn off the firewall temporarily to test

---

## iOS Connection Stuck at "Connecting"

**Symptom**: iOS shows "Connecting…" but never connects.

**Fix**: on the Mac, open the **Devices** pane. There should be a pending approval request. Tap **Accept**. If there is no pending request, the connection attempt may have timed out — try again from iOS.

---

## Sync Not Updating iOS Data

**Symptom**: after tapping **Sync Now** on iOS, agent list or conversations are stale.

**Fix**:
- Ensure the connection is active (ping should succeed)
- Check that `~/Library/Application Support/LumiAgent/agents.json` exists and is not empty on the Mac
- If the file is missing, open Lumi on Mac — `AppState` writes the JSON files on first launch

---

## Agent Responses Are Cut Off

**Symptom**: the agent's message ends mid-sentence or is truncated.

**Cause**: the `maxTokens` value in the agent configuration is too low, or the provider's default limit was hit.

**Fix**: open the agent's edit form and increase `maxTokens`, or leave it blank to use the provider's default.

---

## Shell Command Rejected by Security Policy

**Symptom**: the agent reports that a command was blocked.

**Cause**: the command matched a pattern in `blacklistedCommands` or involves `sudo` when `allowSudo` is `false`.

**Fix**:
- If the command is legitimate, remove the matching pattern from `blacklistedCommands` in the agent's security policy
- If the command needs sudo, enable `allowSudo` in the agent's security policy (do this only if you trust the agent's prompts completely)

---

## Build Fails with Swift Compiler Errors

**Symptom**: `swift build` fails with errors about concurrency or actor isolation.

**Cause**: the project uses Swift 6.2 toolchain features. Older toolchains may fail.

**Fix**: check your Swift version with `swift --version`. It should be 6.2 or later. Install the latest Xcode or a Swift toolchain from [swift.org](https://swift.org/download/).

---

## App Crashes on Launch (Sandbox Violation)

**Symptom**: Lumi crashes immediately on launch with a sandbox violation in the console.

**Fix**: this usually means the app is not properly signed with the entitlements file.

```bash
codesign --force --deep --sign - \
         --entitlements Config/LumiAgent.entitlements \
         runable/LumiAgent.app
```

Then relaunch. For ad-hoc builds, use `run_app.sh` which handles this automatically.

---

## Voice Transcription Returns Empty

**Symptom**: after recording, the text field stays blank.

**Causes and fixes**:
- OpenAI API key is missing. Set it in **Settings → API Keys → OpenAI**
- Microphone permission was denied. Open **System Settings → Privacy & Security → Microphone** and enable `LumiAgent`
- Recording was too short. Whisper requires at least a few words to produce output
- Network is offline. Whisper transcription requires an internet connection
