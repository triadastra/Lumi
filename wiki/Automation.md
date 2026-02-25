# Automation

## Overview

Automation rules let you trigger agent tasks automatically in response to system events, without opening Lumi or typing a message. Each rule binds a trigger event to an agent and a task description (the prompt the agent receives).

Rules are created and managed in the **Automation** section of the sidebar.

## Automation Rule Model

```
AutomationRule
├── id: UUID
├── trigger: AutomationTrigger
├── agentId: UUID?           (nil = use the default agent)
├── notes: String            (the task prompt sent to the agent)
├── isEnabled: Bool
└── lastRunAt: Date?
```

When a rule fires, the `notes` string is sent as the user message to the assigned agent. The agent responds using its normal tool-enabled agentic loop.

## Trigger Types

| Trigger | When it fires |
|---|---|
| `manual` | Only when explicitly triggered from the UI |
| `scheduled` | On a repeating schedule (see below) |
| `appLaunched` | When a specified app opens |
| `appQuit` | When a specified app quits |
| `bluetoothConnected` | When a named Bluetooth device connects |
| `bluetoothDisconnected` | When a named Bluetooth device disconnects |
| `wifiConnected` | When the Mac joins a Wi-Fi network |
| `powerPlugged` | When AC power is connected |
| `powerUnplugged` | When running on battery |
| `screenUnlocked` | When the login screen is dismissed |

## Scheduled Triggers

The `scheduled` trigger supports a `RepeatSchedule` with these intervals:
- `everyMinute`
- `everyHour`
- `everyDay`
- `everyWeek`

The schedule is checked by the automation engine's polling loop (every 15 seconds). If the current time is past the next scheduled run for a rule, the rule fires and `lastRunAt` is updated.

## AutomationEngine

`AutomationEngine` runs on macOS and monitors system events:

- **App launches / quits**: listens to `NSWorkspace.didLaunchApplicationNotification` and `NSWorkspace.didTerminateApplicationNotification`
- **Screen unlock**: listens to `NSWorkspace.screensDidWakeNotification`
- **Bluetooth**: polls `system_profiler SPBluetoothDataType -json` every 15 seconds and diffs connected device names
- **Power**: polls battery state every 15 seconds via `IOKit` (or `PMBatteryInfo` equivalent)
- **Schedule**: checked on the same 15-second polling interval

The engine is started when `AppState` initializes and continues until the app quits.

## Creating a Rule

1. Open **Automation** in the sidebar
2. Click **New Rule**
3. Choose a trigger type and configure its parameters (e.g. app name for `appLaunched`, device name for `bluetoothConnected`)
4. Select an agent to run
5. Write the task prompt in the **Notes** field — this is the message the agent receives
6. Enable the rule and save

## Manually Running a Rule

Select a rule in the list and click **Run Now**. This fires the agent immediately regardless of whether the trigger condition is met. Useful for testing.

## Rule History

`lastRunAt` shows the last time each rule fired. The tool call history in **History** (sidebar) shows the full tool-call audit log for any automation-triggered agent runs, attributed to the agent.

## Safety

Automation rules use the same agent execution pipeline as manual chat, including the agent's security policy and tool restrictions. If an automation rule assigns a high-risk task to an agent whose `autoApproveThreshold` is `.low`, those tool calls will require approval — even when no human is watching.

For fully autonomous background tasks, set the agent's `autoApproveThreshold` to `.high` or `.critical` only if you trust the prompts and tool set completely.
