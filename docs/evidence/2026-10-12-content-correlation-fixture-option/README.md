# Content-correlation fixture evidence option

Parent: `3a655900d8675420994025a7c798b62b9ccd45f8`.
Composite behavior base: `80dcf14c37cca139059d2252e53c189c98df9b00`.

PR #42605 received an initial hostile SOURCE_PASS, then separate review response
found SOURCE_HOLD P2: `Transcript.unreadable` returns `unreadable option`, but
its new fixture accessed `.count` directly. Syntax-only parsing did not detect
that type error. The parent HOLD remains part of the evidence.

Use Option.exists with an explicitly typed unreadable record. The assertion
requires an actual observation containing all three deliberately conflicting
events. Absence does not become success. Production behavior is unchanged.

Syntax-only fixture parse/diff check passed; the selected actual production
content/activity probe still passes. The registered fixture is unexecuted;
this is not full fixture typecheck or full pipeline/runtime/UI evidence.
