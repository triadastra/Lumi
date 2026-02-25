# Hotkeys and Quick Actions

## Global Hotkeys

Lumi registers system-wide hotkeys using the Carbon HIToolbox (`RegisterEventHotKey`). These work in any app while Lumi is running in the background.

| Shortcut | Action |
|---|---|
| `⌘L` or `^L` | Open / close the command palette |
| `⌥⌘L` | Open / close the quick-action panel |
| `⌥⌘E` | Extend selected text |
| `⌥⌘G` | Grammar-fix selected text |
| `⌥⌘R` | Treat selected text as an instruction |

Hotkey registration requires the Accessibility permission. If Accessibility is not granted, hotkeys are silently skipped.

## Command Palette

The command palette is a floating overlay window (`CommandPaletteController`) that appears system-wide on `⌘L` / `^L`. It provides a text field for sending a message to the default agent without switching to Lumi's main window.

The palette opens as a borderless `NSPanel` that floats above all other windows. It dismisses when you press Escape, click outside, or submit a message.

## Quick-Action Panel

The quick-action panel (`QuickActionPanelController`) is opened with `⌥⌘L`. It presents four predefined actions:

| Action | What it does |
|---|---|
| **Analyze Page** | Proofread and fix the active document |
| **Think & Write** | Proactively edit and improve content |
| **Write New** | Review and enhance existing content |
| **Clean Desktop** | Safely organize Desktop files into categorized subfolders (uses a read-only tool subset — no deletions) |

When triggered, the panel detects which app is frontmost. For Pages, Numbers, or Keynote, it extracts document context via AppleScript before sending the prompt. For other apps, it may capture a screenshot for context if Agent Mode is enabled.

After the agent responds, a small floating reply bubble appears in the upper-right corner of the screen so you can continue the exchange without opening Lumi's main window.

## Text-Assist Hotkeys

Three hotkeys capture and rewrite text in whatever app you are using:

**`⌥⌘E` — Extend**: instructs the agent to continue writing from where the selected text ends, matching the existing tone and style.

**`⌥⌘G` — Grammar fix**: instructs the agent to correct grammar, punctuation, and spelling while preserving meaning.

**`⌥⌘R` — Do request**: treats the selected text as a natural-language instruction (e.g. "make this shorter" or "translate to French") and executes it.

### Text Capture Flow

1. Lumi first tries the macOS Accessibility API (`AXValue`) to read the selected text directly from the focused element
2. If that fails, it saves a sentinel value to the clipboard, sends `Cmd+C`, waits briefly, then reads back the clipboard — detecting if the copy succeeded by comparing against the sentinel
3. The captured text is sent to the agent with an action-specific system prompt

### Text Replace Flow

1. After the agent streams its response, Lumi tries `AXValue` write to replace the selection in the focused element
2. If that fails, it writes the result to the clipboard and sends `Cmd+V`

### iWork Awareness

When Pages, Numbers, or Keynote is frontmost, the text-assist pipeline uses dedicated iWork tools (`iwork_write_text`, `iwork_replace_text`) via AppleScript instead of the clipboard path, which gives more reliable placement within the document.

## macOS Services

Lumi registers four entries in the macOS Services menu (right-click → Services):

- **Lumi: Extend** — same as `⌥⌘E`
- **Lumi: Correct Grammar** — same as `⌥⌘G`
- **Lumi: Auto Resolve Text** — same as `⌥⌘R`
- **Lumi: Clean Desktop (Safe)** — same as the Clean Desktop quick action

Services are registered via `NSServices` with `NSServicesSendTypes: NSStringPboardType`. They appear in the Services submenu for any app that supports text selection.

## Toast Notifications

`HotkeyToastOverlay` shows a brief transient overlay when a hotkey fires, so you can see which action was triggered. The toast fades out automatically after a short delay.
