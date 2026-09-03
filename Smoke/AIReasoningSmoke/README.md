# AIReasoningCore iOS Smoke

This app has two deliberately separate verification surfaces:

- **Deterministic Smoke** verifies Native Tools and Interactive Tools on an iOS
  Simulator without credentials or paid traffic. It runs automatically and
  writes the displayed evidence to `Documents/SmokeReport.json`.
- **Live Provider Console** loads the pi-ai-swift catalog and lets a tester
  explicitly choose a provider, model, authorization method and generation
  options before making any network request.

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

## Live Provider Console

The live console uses `BuiltinProviderRuntime` directly from pi-ai-swift and
stores credentials in the app's device-only Keychain. The UI does not contain a
provider-specific runtime or fallback route. Catalog capabilities determine
which task can be accepted; an unsupported task fails before network traffic.

Available manual checks are:

- text streaming through `PiAILanguageModel` and `LanguageModelSession`;
- typed structured output with exact value validation;
- a real `echo(value:)` function call, including tool execution, continuation,
  and transcript preservation;
- image input from Photos or an explicitly generated local fixture;
- image output through the provider runtime, `ImageGenerationTool`, and
  `AssetStore`, followed by native image decoding.

Configuration includes model selection, API-key or OAuth authorization, an
optional base URL, credential metadata, token and temperature limits, reasoning
effort, cache retention, session ID, service tier, provider options, and native
tool-choice JSON. No live check runs on launch. Each button may consume provider
quota and must be pressed by the tester. Result rows exclude credentials,
authorization headers, and raw provider response bodies.

OAuth challenges support device codes, browser callbacks, and provider prompts.
The app opens the provider page and accepts either an app callback URL or a
callback URL pasted by the tester. Authorization can be cancelled or removed
without restarting the app. The smoke target registers pi-ai-swift's
`pi-ai-swift` callback scheme; loopback-only callbacks can still be pasted when
the browser cannot return directly to the app.

Run the complete build/install/launch/read-back gate from the repository root:

```sh
./Scripts/test-ios-smoke-simulator.sh
```

For visual inspection of the live console without sending traffic, launch the
built app with the `--live-provider` argument. Live success is intentionally not
part of the deterministic report because credentials, model availability,
quota, and provider service state are external acceptance gates.

The reasoning effort picker reads the selected model's catalog choices. Provider
or model changes reset the selection to Provider default (`nil`); Off is a
separate explicit selection when the runtime supports disabled reasoning.
