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

The built-in public browser tools and authenticated HTTP
registration routes still use the built-in browser lane. They do not yet route
to this package. This package does not start Firefox, Chrome or Safari, transfer
profiles or publish browser artifacts. It accepts live-client traffic only when
a trusted host bridge sends it. It cannot replace the built-in browser in a live
workspace yet.

Input/output middleware validates tool contracts without calling an LLM. The
separately selectable LLM Exact Output broker still needs its scoped browser
integration. Follow the remaining integration in
[issue #44150](https://github.com/jeong-sik/masc/issues/44150).
