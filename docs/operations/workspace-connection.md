# Workspace HTTP connection

MASC stores the selected HTTP port in `<base-path>/.masc/config/connection.toml`
as the integer `server.http_port`. This is a desired endpoint, not evidence that
a server, model or sandbox is ready. Setup records the selected port, and the
server records it after binding its listener. Unrelated TOML fields and comments
remain intact.

`--port` overrides `MASC_HTTP_PORT`; that existing environment setting overrides
the workspace record. With none supplied, MASC uses its standard HTTP port.
Malformed explicit values or a malformed workspace setting produce an error;
an explicit valid override can still connect while the file is repaired.

Bare `masc`, `masc-tui` and `masc setup` resolve the workspace first and then its
port. The setup journey validates a replacement workspace before inspecting its
server. Saved-history resume inspects the owner: a same-version owner opens
without repeating model choices, while older or unrelated owners retain the
existing explicit selection/restart flow.

`masc workspace-connection --base-path PATH` reports the resolved desired port
with `readiness: not_checked`. Adding `--port PORT --save` records an explicitly
selected endpoint. A failed durable save reports that the port must be supplied
again; it does not falsely report server failure or guest readiness.
