# Zen Browser 1.22b observations

The official macOS universal release asset was downloaded from zen-browser/desktop tag 1.22b. Its SHA-256 matched the GitHub asset digest: 39dd0fc40523ffe4749c3e977e10fd6c9005d6d11285421899114dadbbbfdd9b. Tests used an explicitly selected Zen binary and a disposable headless profile, never an operator profile.

## Actual behavior

The unchanged browser extension interaction implementation filled a local input, clicked a local button, scrolled y=640, captured PNG, and rejected changed URL, ambiguous selector, disabled input and invalid numeric text while preserving the numeric value 42. The first complete open/load/actions/capture sequence took 146 ms. The later native-metadata probe completed that sequence in 120 ms. These timings are not isolated action latency.

A unique, temporary native host manifest under the standard macOS Mozilla/NativeMessagingHosts directory returned a matching probe echo to Zen through a manifest allowing only the proof extension. Only the probe's owned files were removed after execution; the production MASC host manifest was not touched.

Zen runtime.getBrowserInfo() returned name Firefox, engine version 155.0.1, and an explicit zen.version field equal to 1.22b. Therefore browser name alone cannot identify Zen. Connection routing must use an opaque client identity; display branding can use the explicit Zen metadata.

The local app copy retained FinderInfo metadata and strict codesign verification reported that metadata as disallowed. The downloaded release DMG digest was verified against the official asset digest, but this record does not claim local codesign verification passed.

## MASC and OCaml native host measurement

A second test connected actual Zen through the CI-built OCaml native host to an isolated MASC server. The source was `df69a3d94492d5618976b7ad43f8a5eb34d795a3`; artifact run and both binary SHA-256 digests are in [native-ocaml.json](native-ocaml.json). These binaries contain image capture and BrowserInteract, before the connection-routing changes.

Requests crossed MASC HTTP/MCP, the OCaml native host, and the actual browser extension. After fill, click, and scroll, a fresh MASC text read confirmed the input-event value `Typed through OCaml`, button text `Clicked through OCaml`, and scroll position 640. A final screenshot returned the [visible result](zen-via-ocaml.png).

| Operation | Client-observed time |
| --- | ---: |
| Initial text read | 24.2 ms |
| Fill | 8.6 ms |
| Click | 6.6 ms |
| Scroll | 6.2 ms |
| PNG capture | 20.7 ms |

This is one local sample per operation, including transport overhead, not a comparative benchmark. The PNG is 40,883 bytes. A generated local fixture and disposable headless profile were used; no external account participated.

## Boundaries

The measurements exercise actual Zen, the browser extension, and the image/control MASC server and OCaml host binaries. They do not verify `browser.binary` through a new runtime, simultaneous-client routing, the updated TUI binary, or a Keeper model turn. The screenshot is the actual PNG returned from the generated test page. No external service or production browser profile participated.

Sources: [Zen release](https://github.com/zen-browser/desktop/releases/tag/1.22b), [Zen build configuration](https://github.com/zen-browser/desktop/blob/1.22b/surfer.json), [Mozilla custom binary capability](https://developer.mozilla.org/en-US/docs/Web/WebDriver/Reference/Capabilities/firefoxOptions).
