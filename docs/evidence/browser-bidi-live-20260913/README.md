# Experimental BiDi live bridge

This archive separates a standalone BiDi pointer proof, two failed/incorrect
metadata cohorts, and the corrected fd441 native TUI → experimental Python bridge
run. Original reports and raw protocol records are unchanged. The corrected run
reports actual Firefox version/visibility and verified fd441 helper provenance.

One TUI drag traversed typed HTTP, native polling, an explicit numeric-tab to opaque
BiDi context map, and exactly one input.performActions. DOM events reported trusted
down/up and moved the card; the second same-URL context stayed unchanged. Before/after
PNGs are actual screenshot payloads matched against Kitty placements in native PTY
bytes. They are not reconstructed webpage screenshots from text.

This is an experimental Python bridge, not the production native peer, an extension
capability upgrade, an authenticated site/login proof, or a headed operator profile.
No Keeper/model, Slack, or full click/scroll workflow is covered. Stale rejection was
called directly on the bridge dispatcher, NOT through HTTP. Disconnect raw receipt
was not retained; no raw disconnect-proof claim is made. Cleanup outcomes are recorded
independently; Firefox SIGTERM is not represented as graceful exit 0.

Run `python3 audit.py` in any directory after extracting the full archive. The audit
joins HTTP/poll/BiDi routing, verifies one performed action, DOM trust and untouched
other context, native binary identities, PNG/PTY equality and checksums. The original
scripts remain inspection/reproduction references with owned environment prerequisites;
the audit itself starts no process. Profiles, native manifests, login/private credentials,
runtime config and large process/provider logs are excluded.
