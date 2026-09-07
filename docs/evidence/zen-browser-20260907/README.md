# Zen Browser 1.22b observations

The official macOS universal release asset was downloaded from zen-browser/desktop tag 1.22b. Its SHA-256 matched the GitHub asset digest: 39dd0fc40523ffe4749c3e977e10fd6c9005d6d11285421899114dadbbbfdd9b. Tests used an explicitly selected Zen binary and a disposable headless profile, never an operator profile.

## Actual behavior

The unchanged browser extension interaction implementation filled a local input, clicked a local button, scrolled y=640, captured PNG, and rejected changed URL, ambiguous selector, disabled input and invalid numeric text while preserving the numeric value 42. The first complete open/load/actions/capture sequence took 146 ms. The later native-metadata probe completed that sequence in 120 ms. These timings are not isolated action latency.

A unique, temporary native host manifest under the standard macOS Mozilla/NativeMessagingHosts directory returned an authenticated-by-random-hostname probe echo to Zen. Only the probe's owned files were removed after execution; the production MASC host manifest was not touched.

Zen runtime.getBrowserInfo() returned name Firefox, engine version 155.0.1, and an explicit zen.version field equal to 1.22b. Therefore browser name alone cannot identify Zen. Connection routing must use an opaque client identity; display branding can use the explicit Zen metadata.

The local app copy retained FinderInfo metadata and strict codesign verification reported that metadata as disallowed. The executable content digest was verified against the official release, but this record does not claim local codesign verification passed.

## Boundaries

These measurements exercise actual Zen extension and native messaging APIs. They do not yet verify the new browser.binary parser, connection-scoped MASC routing, a new MASC server/TUI executable, or a Keeper model turn. The screenshot is the actual PNG returned from the generated test page. No external service or production browser profile participated.

Sources: [Zen release](https://github.com/zen-browser/desktop/releases/tag/1.22b), [Zen build configuration](https://github.com/zen-browser/desktop/blob/1.22b/surfer.json), [Mozilla custom binary capability](https://developer.mozilla.org/en-US/docs/Web/WebDriver/Reference/Capabilities/firefoxOptions).
