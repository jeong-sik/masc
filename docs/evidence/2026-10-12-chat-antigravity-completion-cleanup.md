# Antigravity completion observer cleanup

Base: `76b2d7b9612a677209530e31000f854e74ee0495`.

Native ownership retires before completion observation, preventing reentrant
completion. Previously an observer exception skipped ContentBlockStop, and the
terminal sweep could not repair it because the identity was already Closed.

The completion observer now runs under Fun.protect. Its finally closes the
content block under Eio cancellation protection. The observer's exception or
cancellation is not swallowed. Normal completion retains outcome-before-stop
ordering required by the chat stream bridge. No successful tool outcome is
synthesized on observer failure.

Validation: syntax-only parsing and whitespace checks passed. No behavioral
execution, build, CI, formal approval, installation or screenshot is claimed.
An explicitly throwing stop callback can still replace an earlier exception
through Fun.protect; ordinary non-cancellation stream callback failures are
caught by the existing emit wrapper. Review must evaluate this boundary.

PR publication for the preceding continuation chain encountered DNS resolution
failure twice before any mutation. Installed masc-tui reports build commit
c0ed3b7b05a04d5843e37e49efd0f3012460cfbf, not these source changes. Overall runtime
and UI proof remains incomplete.
