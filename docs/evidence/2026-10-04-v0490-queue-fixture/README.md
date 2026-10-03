# Queue workspace fixture repair

The existing e4afdce8f0c4ba4cf02e4326ba423c4fe2207339 macOS ARM64 RC binary passed both queued_workspace_inputs cases with this fixture: workspace switch and MASC-root-only switch. Retained input is observed through NEXT 1 and its original text. Exact admission phases, no automatic resend, original payload, explicit resume and normal process exit are all checked by the existing scenario/harness.

The earlier fixture waited for a removed Queue (1 waiting) label. After correcting that, repeated Esc cleanup missed its assumed detail destination. Palette text also fails inside the composer. The final fixture arms global Ctrl-C and lets the harness confirm it; normal exit, Goodbye and terminal restoration checks remain.

This is two focused scenarios using an existing candidate binary, not a rebuilt child binary, Linux verification, full remote-history target or Full RC. Reproduce with the repository test module: queued_workspace_inputs(binary) and queued_workspace_inputs(binary, root_only=True). Raw PTY and command receipt are retained at /tmp/masc-queue-fixture-20261004/confirmed-exit/. Manifest binds source and binary SHA256.

Validation: Ruff and AST pass; pyright reports244 errors both before and after, with identical message/rule multisets. No new type diagnostics, but no clean typecheck claim. Independent review_board_live_authorization source review found no P0-P2 in the final delta. No product source, timeout or ownership assertions changed.
