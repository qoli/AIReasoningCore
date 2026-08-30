# Architecture

## Product seam

The caller-facing seam is the AnyLanguageModel contract family. The package
defines no parallel inference protocol, session type, transcript or tool system.

```text
App
└── LanguageModelSession
    ├── PiAILanguageModel
    │   └── ProviderRuntime (pi-ai-swift)
    ├── AnyLanguageModel.Tool
    │   ├── HTTPTool
    │   ├── WebReadTool
    │   ├── ImageGenerationTool
    │   ├── DocumentTool
    │   ├── BrowserTool
    │   └── AssetManagementTool
    ├── ConversationStore
    └── AssetStore
```

`ProviderRuntime` is injected because a live runtime and a deterministic test
runtime are both real adapters. AIReasoningCore does not define another provider
interface around it.

## Ownership

- `PiAILanguageModel` maps `Transcript`, tools, schemas and generation options to
  pi-ai-swift DTOs, including output modality, reasoning effort, session and
  cache affinity, service tier, provider options, and native tool choice.
- Non-streaming provider tool calls are executed through the tools already owned
  by `LanguageModelSession`, then returned to the same provider conversation.
- `ConversationStore` atomically persists `Transcript` plus opaque provider state.
- `AssetStore` atomically persists generated images, files and browser snapshots.
- `BrowserOperator` is an app-supplied closure over the app-owned browser.

## Explicit failures

The runtime fails instead of substituting another behavior when:

- the transcript cannot be represented by pi-ai-swift;
- a provider response has the wrong provider/model identity;
- a tool name is unknown;
- a provider emits an asset without an `AssetStore`;
- streamed tool calls cannot be represented by AnyLanguageModel 0.9.0;
- a URL violates the configured policy;
- a document path escapes its configured root;
- a persisted schema version is unsupported.

## Excluded system

Coding sandbox behavior is outside this repository. The rewritten package does
not contain shell, git, build automation, CLI-agent drivers, iSH, root filesystems
or compatibility servers.
