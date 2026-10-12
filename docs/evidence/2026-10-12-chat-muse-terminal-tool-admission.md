# Muse terminal MCP admission

Parent: `d69400c50e8db53184aa98e7d36bd2af7fe2c073`.

Muse's loopback MCP listener lives until the enclosing Eio switch closes.
Terminal observation and that switch shutdown are distinct boundaries. Its
call_tool callback previously always opened a projection block and entered
tool.call, even when the projection's existing terminal owner was closed.
This is source evidence of missing admission at a real asynchronous boundary,
not evidence of an observed live late effect.

The projection now returns the closed decision Admitted or Turn_closed from
the existing stream terminal owner. After terminal, it creates no routing
entry, block, text transition, or receipt binding. The MCP callback handles
Turn_closed with an unsuccessful tool response and no after-response effect;
it does not enter tool.call or its finish path. Admitted calls keep their
existing execution and protected receipt hooks. No second lifecycle owner,
word matching, time gate, or arbitrary count cap is introduced.

A call admitted before terminal can yield while its start is published, then
execute after terminal. This change does not revoke an admitted call or claim
to solve publication interleaving during that yield. The receipt entry for
such an admitted call remains until its actual finish; clearing presentation
routing does not erase that execution authority.

Executed on 2026-10-12, all exit 0:

```
ocamlc -stop-after parsing lib/keeper/keeper_muse_runtime.mli
ocamlc -stop-after parsing lib/keeper/keeper_muse_runtime.ml
ocamlc -stop-after parsing test/test_keeper_muse_runtime.ml
git diff --check
```

These prove syntax and whitespace only. The registered protocol/state fixture
checks the actual admission decisions across successful, failed, cancelled,
and unknown terminal closure with receipts installed, preserves finishing a
previously admitted call, and verifies no late block opens. It is **unexecuted**.
It exercises projection admission, not the real HTTP tool effect path.
Typecheck, build, CI, live effect counter, installed runtime, and UI screenshots
remain unverified. Reentrant content publication and cancellation during
terminal cleanup remain separate investigations.
