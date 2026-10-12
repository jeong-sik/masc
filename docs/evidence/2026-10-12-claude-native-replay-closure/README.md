# Claude native occurrence replay closure

Base: `dc1b3d274c1aca89907484e3f1a3036acc2e6311`.

Claude callback deleted native occurrence identity after completion and observed
native action before claiming/emitting its block. Unlike Codex/Antigravity,
completed or active start replay could notify action again; finish-before-start
left no fence, and synchronous action observer reentry could lose completion.

Use a callback-local closed sum Native_block_open index / Native_block_closed.
Claim and emit a new block before notifying its action; known active/closed
identity starts do not reemit/renotify. Retire ownership before completion hook
and preserve closure even if the start was absent. Progress requires open state.
Raw trace recording is unchanged. Identity-absent observations retain prior
unbound block behavior; no identity is invented and no time/counter gate added.
The map lifetime remains the callback lifetime, not a global provider deduper.

## Direct bounded probe

Artifacts `/tmp/masc-claude-native-replay-20261012/{generate.py,parent.ml,current.ml,parent.log,current.log}`.

Interpreted actual native-start/progress/finish arms and complete exact-action,
valid-identity and call-id helpers. Minimal provider/event types and callback
container; raw tracing is a no-op sink, cancellation protection an identity
wrapper (does not prove Eio cancellation). Callback counters record actual
emitted starts/stops and observer calls. Native-task arm excluded; no full
provider callback, network, bridge, journal or reducer executed.

Parent exit2: completed identity reopened or renotified.
Current exit0: four sequences pass: start/finish/replayed start/late progress;
finish-before-start; duplicate active start; action observer synchronously
reenters with completion. Each known occurrence owns at most one start/action
and completion; progress only while open. This is protocol state measurement,
not wording/layout or UI snapshot testing.

Changed production file syntax-only parse and diff check pass. No full
fixture/typecheck/build/CI/provider runtime/UI/installation/formal approval/merge
proof. Combined bridge/reducer and all-runtime goal verification remain pending.
