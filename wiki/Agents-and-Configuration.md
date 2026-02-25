# Agents and Configuration

## Agent Model

Each agent is an independent entity with its own identity, provider, model, system prompt, tool set, and security policy. Agents are stored in `agents.json` and identified by UUID.

```
Agent
├── id: UUID
├── name: String
├── configuration: AgentConfiguration
├── capabilities: [AgentCapability]
├── status: AgentStatus   (idle / running / error)
├── createdAt: Date
└── updatedAt: Date
```

The avatar color shown in the sidebar is deterministically derived from the agent's UUID — it is always the same for a given agent and does not need to be stored.

## AgentConfiguration

```
AgentConfiguration
├── provider: AIProvider        (openai / anthropic / gemini / qwen / ollama)
├── model: String               (e.g. "gpt-4o", "claude-opus-4-6")
├── systemPrompt: String?
├── temperature: Double?        (0–2, default provider-specific)
├── maxTokens: Int?
├── enabledTools: [String]      (empty = all tools; non-empty = only listed tools)
└── securityPolicy: SecurityPolicy
```

## AgentCapability

Capabilities are informational tags that describe what an agent is configured to do. They are not enforced as access control — tool access is controlled by `enabledTools` and `SecurityPolicy`.

- `fileOperations`
- `webSearch`
- `codeExecution`
- `systemCommands`
- `databaseAccess`
- `networkRequests`

## SecurityPolicy

Every agent has a security policy that governs what tool calls it can make autonomously.

| Field | Type | Description |
|---|---|---|
| `allowSudo` | Bool | Whether `sudo` is permitted in shell commands |
| `requireApproval` | Bool | Prompt for user approval before executing any tool |
| `blacklistedCommands` | [String] | Shell command substrings that are always blocked |
| `restrictedPaths` | [String] | Filesystem paths the agent cannot write to |
| `maxExecutionTime` | TimeInterval | Per-tool-call timeout in seconds (default 300) |
| `autoApproveThreshold` | RiskLevel | Tools at or below this risk level run without approval |

**Default blacklisted commands**: `rm -rf /`, `dd if=/dev/zero`, `:(){ :|:& };:` (fork bomb), and similar destructive patterns.

**Default restricted paths**: `/System`, `/Library`, `/usr`, `/bin`, `/sbin`.

## Risk Levels

Every tool in the registry has a risk level. The security policy's `autoApproveThreshold` determines which tools run automatically:

| Level | Meaning |
|---|---|
| `.low` | Read-only, no side effects (e.g. `read_file`, `get_system_info`) |
| `.medium` | Writes or network calls with limited blast radius (e.g. `write_file`, `web_search`) |
| `.high` | Shell execution, clipboard write, mouse/keyboard control |
| `.critical` | AppleScript automation, sudo commands |

## Restricting Tools

Set `enabledTools` in agent configuration to a non-empty list of tool names to restrict the agent to only those tools. For example, an agent meant only to answer questions from web searches would have:

```json
"enabledTools": ["web_search", "fetch_url"]
```

See [Tool Catalog](Tool-Catalog) for all tool names.

## Creating and Editing Agents

On macOS, use **New Agent** (`⌘N`) or select an agent and click **Edit**. The edit form exposes all fields in `AgentConfiguration`. The Ollama model dropdown is populated live by querying the local Ollama server.

On iOS, agents are created and viewed in the **Agents** tab. The primary agent (starred) is used as the default for new conversations.

## Agent Deletion

Deleting an agent does not delete its conversations. Conversations that referenced the deleted agent retain their message history but can no longer send new messages to that agent.
