# Redaction ownership and authored order

A native tool may finish while a model is still producing a Text or Thinking
block. Finalizing every text buffer at that tool observation exposes a secret
split around the observation. Each content index and typed channel therefore
owns a separate redactor, and a block stop closes only that index. Native
completion and progress callbacks do not finalize model text. Provider adapters
must supply their actual content boundaries as described in
[provider-content-boundaries.md](provider-content-boundaries.md).

Independent buffers alone are insufficient. An unfinished `Text0("first ")`
followed by `Text1("second\n")` would otherwise publish `second` before `first`.
Similarly, combining `Text A / Thinking R / Text B` into one released text string
would move B across R. The shared redactor queues the original authored chunks,
and attributes safe output using the actual replacement spans from
[redaction-source-spans.md](redaction-source-spans.md). Copied bytes remain at
their original chunk positions. A mask spanning chunks appears once at its first
source-byte owner. A UTF-8 codepoint split between chunks also belongs to its
first-byte owner, keeping every published string valid for the terminal.

A global FIFO controls authored Text/Thinking publication. A separate queue per
redactor tracks only chunks still awaiting attribution. Each attributed source
chunk leaves that queue once, even if its safe output must wait behind another
channel in the global FIFO. Later deltas do not rescan all completed chunks;
this matters because Keeper preview updates run under a shared mutex. Partial
safe prefixes of the front chunk can be published before that chunk completes.

Native observations and tool argument fields remain independently observable.
They do not imply that withheld model text ended. Model block stops wait behind
the corresponding authored content. Scope, attempt and request endings finish
remaining channels and preserve the old scope on released events. Exact
same-scope message-header replays cannot finalize text.

Typed model deltas also establish semantic index occupancy before their bytes
can be disclosed. If the provider omitted a content header, the redactor emits
a normalized Text/Thinking header at that first typed observation. Explicit
headers suppress this normalization. An empty typed delta still identifies its
channel, but the header adds neither speech nor an activity signal. The bridge
can therefore reject a later malformed tool claiming that withheld-text index.
This normalized header records observed content type, not an invented provider
wire event or a completed line.

An authoritative snapshot discards only its channel's unpublished delta tail;
it cannot release another channel's pending secret. Whole snapshot events keep
their own positions and are not coalesced by this layer. In particular a
snapshot-only model block's stop waits behind its snapshot. AGENT_CORE retains
ownership of normal text snapshot-to-delta reconciliation.

The existing per-channel unfinished-line bound still applies. The FIFO additionally
retains safe authored output that cannot yet pass an earlier unfinished chunk;
storage is linear in that deferred output. This is not a total-memory bound or
a disk-spooling implementation. No time, token or row cap discards content to
resolve that dependency. Long open-content lifetimes remain an operational
limitation to measure separately.

Focused fixtures cover native start/completion/progress between secret halves
through Scoped and autonomous journal paths, preview masking, overlapping
text/reasoning/arguments, same-scope headers, snapshot replacement and stops,
Unicode chunk splits, original A/R/B positions and long deferred output. These
are development fixtures; installed-runtime and real provider-session evidence
remain separate requirements.
