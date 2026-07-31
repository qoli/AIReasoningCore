# Driver wire contracts

The Codex driver is pinned to the minimum verified CLI version 0.146.0 and uses
app-server JSON-RPC v2 over stdio. The checked fields are:

- `initialize` / `initialized`
- `thread/start` with `ephemeral: true`, `approvalPolicy: never` and
  `sandbox: read-only`
- `turn/start` with text or `localImage`, `outputSchema`, read-only
  `sandboxPolicy` and network disabled
- `item/agentMessage/delta`
- `turn/completed`
- `turn/interrupt`

Before starting app-server, the driver calls `codex mcp list --json` with the
same executable and environment, then adds an explicit
`mcp_servers."<name>".enabled=false` override for every configured server.
Malformed discovery output fails the generation. Shell, web search,
multi-agent, apps, plugins, browser and computer-use features are also
explicitly disabled.

The fixture notifications include all IDs required by the 0.146.0 generated
JSON schemas. Unknown notifications are ignored, while malformed required
messages, error responses, missing results and unexpected process termination
fail explicitly.

The Claude driver is pinned to 2.1.85 and uses bidirectional `stream-json` with
`--print --bare --no-session-persistence --disable-slash-commands
--strict-mcp-config --no-chrome --tools ""`. Text comes from partial
`content_block_delta` events. Structured output comes only from a successful
`result.structured_output`. Images are validated first and sent as base64
content blocks.

Recorded JSONL fixtures live under
`Tests/AIReasoningCoreTests/Fixtures`. Live authenticated tests are opt-in.
