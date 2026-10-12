# Actual Eio receipt scheduling and cancellation

Current production source head: `3adb9c5cd12955a598fc767e66ca5b5e632d8bfa`.
This is evidence-only continuation; production source is unchanged.

## Executed command

```
python3 docs/evidence/2026-10-12-tool-receipt-real-eio/run.py .
```

The OCaml 5.5.1 interpreter loads installed eio_main bytecode and runs actual
Eio_main.run, Fiber.both, Promise waits, yield, Cancel.sub/cancel/check and
Switch cancellation protection. It loads the entire production receipt,
Eio_guard and Execution_context source with #use/#mod_use. A thin Fs_compat
forwarder delegates its context query to the actual Execution_context module;
it introduces no simulated context decision. External Agent Core hook types,
execution joins and Ids remain explicit doubles. No Dune build was run.

## Results

Four current-source scenarios passed, process exit 0:

- A separate fiber commits C while held notification A waits on a promise:
  observer order is A,B,C.
- A separate fiber commits B while immediate A waits: observer order is A,B.
- The original post-hook cancels its real Eio context after a committed join.
  The production Eio_guard's actual switch-release cleanup still delivers
  one receipt, including a real yield in notify; cancellation propagates.
- The receipt observer cancels itself after queuing B. The cancellation
  propagates and a later C drains B,C without replaying attempted A.

The saved final GREEN log measured 0.246521 seconds for interpreter startup
and all scenarios. The initial successful run measured 0.311067 seconds.
No timing threshold is used as acceptance.

The same final harness was run against exact receipt source from parent
`7943e34d8760152de4ed8907295da3d25596bafa`, while retaining the same real guard
and context source. RED returned exit 2: held mode passed but immediate
observer order was B,A, contradicting commit order. Source hashes, artifact
hashes, selected installed package bytecode hashes, logs and runner are stored
here. Package archive hashes identify installed files, not a complete dynamic
load trace or release toolchain manifest.

## Boundaries

This upgrades earlier synchronous cancellation/scheduling doubles to actual
Eio fiber and cancellation execution on one domain. It does not prove real
Agent Core schemas, durable execution joins, full integration typing, raw
multidomain safety, actual HTTP effects, live provider/Keeper behavior,
installed TUI/dashboard screens, CI, formal approval or merge. It does not
invent acknowledgement for the notification interrupted before returning.
