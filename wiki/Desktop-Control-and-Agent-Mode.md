# Desktop Control and Agent Mode

## Overview

Agent Mode enables a set of screen-control tools that let an agent interact with the Mac desktop visually: take screenshots, move the mouse, click, scroll, type text, and press key combinations. Combined with the standard shell and file tools, an agent in Agent Mode can perform nearly any task a human user can do at the keyboard.

Desktop control requires the **Accessibility** and **Screen Recording** permissions granted in System Settings. Without them, the tools will fail at runtime.

## Enabling Agent Mode

Agent Mode is a per-conversation toggle in the `ChatView` toolbar. When disabled, screen-control tools are excluded from the tool definitions sent to the AI. The AI cannot call them even if the agent's `enabledTools` list would otherwise permit it.

When Agent Mode is enabled:
- A visual overlay appears in the corner of the screen as a reminder that the agent can see and interact with the desktop
- All screen-control tools become available
- The conversation is marked accordingly in the UI

## Available Tools in Agent Mode

| Tool | What it does |
|---|---|
| `screenshot` | Captures a JPEG of the current screen (max 1440px wide, quality 0.82) |
| `click_mouse` | Clicks at given (x, y) screen coordinates |
| `scroll_mouse` | Scrolls at given coordinates by a delta amount |
| `type_text` | Types a string character by character via CGEvent |
| `press_key` | Presses a key combination (e.g. `cmd+c`, `escape`, `return`) |
| `open_application` | Opens an app by display name or bundle ID |

The agent typically starts by calling `screenshot` to observe the current screen state, then takes actions, then screenshots again to verify the result.

## Screen Capture Implementation

`ScreenCapture.swift` provides two capture paths:

**Full screen**: calls `/usr/sbin/screencapture -x -t jpg` as a subprocess, then reads the resulting JPEG. The image is resized via `CGContext` if wider than the configured maximum.

**Window capture**: uses `CGWindowListCopyWindowInfo` to find the frontmost non-Lumi window by name, then `CGWindowListCreateImage` to capture it directly without writing to disk.

Captured images are returned as `Data` (JPEG bytes) and can be attached to a message for vision-capable models.

## Mouse and Keyboard Control

Mouse events use `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)` via CoreGraphics. Keyboard events use `CGEvent(keyboardEventSource:virtualKey:keyDown:)`. All events are posted to the HID event tap.

Key mapping (string → `CGKeyCode`) covers standard keys, function keys, arrow keys, and common modifier combinations parsed from strings like `"cmd+shift+t"`.

## AppleScript

The `run_applescript` tool (risk level: critical) executes arbitrary AppleScript via `NSAppleScript`. It is the most powerful automation tool available and can control any scriptable app. It requires the Automation permission and is only auto-approved if the agent's `autoApproveThreshold` is set to `.critical`.

## iWork Context Detection

When a Quick Action or text-assist hotkey fires while Pages, Numbers, or Keynote is the frontmost app, Lumi detects this and runs an AppleScript to extract the document title and a content sample. This gives the agent context about the open document before it begins writing or editing.

## Safety Considerations

- Desktop control tools have risk level `.high`; they will not run automatically if `autoApproveThreshold` is `.low` or `.medium`
- The visual overlay makes it obvious when an agent is in control
- Use `enabledTools` to exclude screen-control tools entirely from an agent that doesn't need them
- The shell command blacklist still applies to `run_shell_command` even in Agent Mode
