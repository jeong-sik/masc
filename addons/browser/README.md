# Browser worker

This package runs `masc-browser-addon-worker` as a native Add-on. The installed
worker and `masc-native-addon-launcher` must be available on the server's PATH.
The host supplies the private socket, incarnation and message bound; package
bindings cannot choose them. Native execution uses a foreground process group
and durable resource claims. It is not a container sandbox.

The worker publishes connection observations through MCP. Its separate private
socket lets browser commands wait while client polls and results use other
connections. Runtime service handles name one original connection and cannot
follow a replacement installation. Detach confirms both process settlement and
socket cleanup before releasing that incarnation. Interrupted startup recovery
reads the socket allocation intent from the original native reservation.

This is a transport foundation. The public browser tools and authenticated HTTP
registration routes still use the built-in browser lane. They do not yet route
to this package. This package does not start Firefox, Chrome or Safari, transfer
profiles or publish browser artifacts. It accepts live-client traffic only when
a trusted host bridge sends it. It cannot replace the built-in browser in a live
workspace yet.

Selectable input/output middleware and the LLM Exact Output broker must be wired
at that host bridge before this package becomes an operator browser option.
The current wire decoder checks identity and transport shape; it does not call
an LLM. Follow the remaining integration in
[issue #44150](https://github.com/jeong-sik/masc/issues/44150).
