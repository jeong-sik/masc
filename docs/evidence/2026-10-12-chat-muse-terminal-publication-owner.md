# Muse terminal publication ownership

Parent: `e434b24fafa217f7640462082dfbfe5850dcd363`.

The projection's MCP start publishes ContentBlockStart and argument snapshot
through callbacks that may yield. Previously a terminal callback could close
the route and publish MessageStop during the start callback, then the resumed
caller published the arguments after MessageStop. Held block draining and
MessageStart publication had the same terminal-overtaking boundary.

The existing terminal owner now has a closed state sum: live, closing with its
actual optional stop reason, and closed. The first finish request enters
closing immediately, so new MCP admission refuses. Publication waits until
all outstanding local batch owners retire. A batch includes message start and
held release, all passes of held block draining, a claimed MCP start plus
arguments, or a native start. Local identity tokens track only outstanding
callback batches; they are neither provider occurrence identities nor a
second terminal authority. Terminal cleanup retires routes before emitting
stops and MessageStop as before. Previously admitted calls retain their
receipt/finish authority.

Publication retirement uses Fun.protect; flushing pending terminal cleanup is
protected from inherited Eio cancellation. This does not guarantee delivery
when a callback explicitly raises cancellation or otherwise fails before
recording the current event. Such ambiguous callback delivery and cleanup
failure remain unverified; this change is not a durable retry queue.

Executed on 2026-10-12, all exit 0:

```
ocamlc -stop-after parsing lib/keeper/keeper_muse_runtime.mli
ocamlc -stop-after parsing lib/keeper/keeper_muse_runtime.ml
ocamlc -stop-after parsing test/test_keeper_muse_runtime.ml
git diff --check
```

These prove syntax and whitespace only. Registered protocol/state scenarios
inject terminal while a MCP block start, held block drain, MessageStart, and
native start callback is in progress. They verify each open protocol block
closes before terminal, arguments target an open block, and new admission
closes while an already-admitted batch finishes. A held second call queued
before terminal must drain before cleanup. Fixtures are **not executed**.
Typecheck/build/CI, actual HTTP effect measurements, installed runtime and
screen evidence remain unverified. No UI text/layout/row-order test was added.
