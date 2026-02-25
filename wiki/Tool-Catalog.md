# Tool Catalog

The tool registry (`ToolRegistry.shared`) provides 60+ tools organized by category. Every tool has a name, description, risk level, and JSON-Schema parameter definition.

Tools are available to all agents by default. Restrict access per-agent using the `enabledTools` list in agent configuration. See [Agents and Configuration](Agents-and-Configuration) for details on per-agent tool control and the risk-level auto-approval threshold.

---

## Files

| Tool | Risk | Description |
|---|---|---|
| `read_file` | low | Read contents of a file |
| `write_file` | medium | Write or overwrite a file |
| `append_file` | medium | Append text to a file |
| `list_directory` | low | List files in a directory |
| `create_directory` | medium | Create a directory |
| `delete_file` | high | Delete a file or directory |
| `move_file` | medium | Move or rename a file |
| `copy_file` | medium | Copy a file |
| `get_file_info` | low | Get metadata for a file |
| `search_files` | low | Search for files by name or content pattern |

---

## Terminal

| Tool | Risk | Description |
|---|---|---|
| `run_shell_command` | high | Run a shell command and return stdout/stderr |
| `run_python_code` | high | Execute Python code in a subprocess |
| `run_node_code` | high | Execute JavaScript via Node.js in a subprocess |
| `run_applescript` | critical | Execute an AppleScript and return the result |

Shell commands are validated against the agent's security policy before execution. Blacklisted command substrings are rejected without running. `allowSudo` must be enabled for `sudo` commands.

---

## Screen Control

These tools require the Accessibility and Screen Recording permissions. They are excluded from the tool list when Agent Mode is disabled in a conversation.

| Tool | Risk | Description |
|---|---|---|
| `screenshot` | high | Capture a JPEG screenshot of the current screen |
| `click_mouse` | high | Click at (x, y) coordinates |
| `scroll_mouse` | high | Scroll at (x, y) by a given delta |
| `type_text` | high | Type a string using keyboard events |
| `press_key` | high | Press a key combination (e.g. `cmd+c`) |
| `open_application` | high | Open an application by name or bundle ID |

Coordinates are in screen points relative to the primary display origin.

---

## Web

| Tool | Risk | Description |
|---|---|---|
| `web_search` | medium | Search the web and return result summaries |
| `fetch_url` | medium | Fetch the content of a URL |
| `http_request` | medium | Make an HTTP request with custom method, headers, and body |

---

## Clipboard

| Tool | Risk | Description |
|---|---|---|
| `get_clipboard` | low | Read the current clipboard contents |
| `set_clipboard` | high | Write text to the clipboard |

---

## Git

| Tool | Risk | Description |
|---|---|---|
| `git_status` | low | Run `git status` in a directory |
| `git_log` | low | Run `git log` with configurable options |
| `git_diff` | low | Run `git diff` |
| `git_commit` | medium | Stage and commit changes |
| `git_branch` | low | List or create branches |

---

## Memory / Notes

| Tool | Risk | Description |
|---|---|---|
| `remember` | low | Store a key-value note for later recall |
| `recall` | low | Retrieve a stored note by key |
| `forget` | low | Delete a stored note |

Notes are persisted per-agent across conversations.

---

## System

| Tool | Risk | Description |
|---|---|---|
| `get_system_info` | low | CPU, memory, disk, OS version |
| `set_volume` | medium | Set system output volume (0–100) |
| `set_brightness` | medium | Set display brightness (0–100) |
| `get_battery_status` | low | Battery level and charging state |

---

## Agent Control

| Tool | Risk | Description |
|---|---|---|
| `update_self` | medium | Update the calling agent's own configuration (system prompt, model, temperature) |
| `delegate_to_agent` | medium | Send a task to another agent and return its response |

---

## iWork Integration

| Tool | Risk | Description |
|---|---|---|
| `iwork_write_text` | medium | Write text to a Pages/Numbers/Keynote document |
| `iwork_replace_text` | medium | Replace a specific string in an iWork document |
| `iwork_insert_after_anchor` | medium | Insert text after a named anchor in an iWork document |

These tools use AppleScript under the hood and require the Automation permission for Pages, Numbers, and Keynote.

---

## Desktop Control Without Agent Mode

When Agent Mode is disabled in a conversation, `get_tools_for_ai_without_desktop_control()` is used, which excludes all Screen Control tools. All other tool categories remain available.
