# Browser worker

This package runs `masc-browser-addon-worker` as a native Add-on. The installed
worker and `masc-native-addon-launcher` must be available on the server's PATH.
The host supplies the private socket, incarnation and message bound; package
bindings cannot choose them. Native execution uses a foreground process group
and durable resource claims. It is not a container sandbox.

The worker exports `browser_command` through ordinary Add-on discovery. The host
supplies verified caller context through the private control port. The package
selects `validate_input` and `validate_output`; an installation can override
`tool_hooks`, including `[]` to disable these optional checks. Identity,
incarnation, browser selection and command decoding remain mandatory.

Input arguments contain a `command` with `verb` and `args`, plus optional `lane`
and `clientId`. An unbound command can select an available browser automatically;
tab/document work repeats the returned selection. `page.read` with
`includeHtml = true` reads document source. The bundled browser skill describes
guarded input and partial-result handling.

The worker publishes connection observations through MCP. Its separate private
socket lets browser commands wait while client polls and results use other
connections. Runtime reads its running observation through that private channel,
independently of a waiting MCP command. Service handles name one original connection and cannot
follow a replacement installation. Detach confirms both process settlement and
socket cleanup before releasing that incarnation. Interrupted startup recovery
reads the socket allocation intent from the original native reservation.

Authenticated native-host HTTP routes forward polls, results and disconnects to
this Add-on. They use the served workspace's lane token, even when the process
environment points elsewhere. A new client can register only when one browser
Add-on is available. Its ID and full identity are durably bound to that original
worker under `<base-path>/.masc/browser-lane/registrations/`. Existing IDs are
never assigned to a replacement. A temporary observation failure returns
unavailable and requests an observation refresh; confirmed retirement tells the
host to open a fresh connection. There is no built-in queue fallback.

Install a declaration using the active configuration directory described in the
[TOML guide](../../docs/guides/lane-addon-toml.md), pointing `manifest_path` at
this package's actual absolute path or a path relative to that declaration:

```toml
id = "browser"
run_id = "browser-work"
manifest_path = "/absolute/path/to/masc/addons/browser/lane.toml"
tool_hooks = ["validate_input", "validate_output"]

[binding]
sources = []
```

The installed native host and browser extension/BiDi peer still need the same
workspace token. This package does not yet start Firefox, Chrome or Safari,
transfer profiles or publish browser artifacts. Built-in public tool routing,
Dashboard browser inventory and built-in startup still need to move to the
Add-on. This is not yet a complete operator-browser replacement.

Input/output middleware validates tool contracts without calling an LLM. The
separately selectable LLM Exact Output broker still needs its scoped browser
integration. Follow the remaining integration in
[issue #44150](https://github.com/jeong-sik/masc/issues/44150).
