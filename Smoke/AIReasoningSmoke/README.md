# AIReasoningCore iOS Smoke

This app verifies the current Native Tools and Interactive Tools on a real iOS
Simulator runtime. It runs automatically on launch and shows the same evidence
that it writes to `Documents/SmokeReport.json`.

The deterministic suite covers:

- `HTTPTool` through a real `URLSession` with a local `URLProtocol` fixture;
- the complete `ProviderRuntime` → `PiAILanguageModel` →
  `LanguageModelSession` tool-call and provider-continuation loop;
- `WebReadTool` fetching and extracting static HTML;
- `DocumentTool` writing, listing, and reading UTF-8 files in the app sandbox;
- `ImageGenerationTool` through an injected deterministic generator, including
  valid PNG decoding and `AssetStore` persistence;
- `BrowserTool` through this app's visible, app-owned `WKWebView` adapter,
  including open, wait, read, type, click, and snapshot;
- `AssetManagementTool` listing and reading metadata for generated and browser
  snapshot assets.

The BrowserOperator target convention belongs to this smoke host:

- `open.target` selects the fixture (`smoke://interactive`);
- `read.target`, `type.target`, and `click.target` are CSS selectors;
- `type.value` is the replacement input value.

Passing this suite proves AIReasoningCore's tool interfaces and this concrete
iOS WebKit host work together. It does not prove a downstream app's independent
BrowserOperator, public Internet reachability, or live image generation. The
HTTP fixture performs no DNS/TCP/TLS traffic, and the image generator is an
injected deterministic adapter rather than a provider.

Run the complete build/install/launch/read-back gate from the repository root:

```sh
./Scripts/test-ios-smoke-simulator.sh
```
