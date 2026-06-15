# RFC-0241 caller context

Companion evidence for RFC-0241 (external-attention store lifecycle: read-side
bound, retention, typed tail-dedup). Records the premise verification, live
measurements, and code survey so a reviewer can confirm the classification
without re-deriving it.

## Store location and shape

```
lib/keeper/keeper_external_attention.ml:11   attention_path = <base>/.masc/external_attention/<keeper>.jsonl
lib/keeper/keeper_external_attention.mli:131  ".mli: append-only and unbounded"
```

Mutators (all append-only, no rotation/prune):

- `record` → appends `Recorded` (`lib/keeper/keeper_external_attention.ml:486`)
- `claim_for_turn` / `mark_resolved` / `mark_ignored` → `append_many`
  (`lib/keeper/keeper_external_attention.ml:494-534`)

Rotation/prune survey (none):

```
$ rg -n "rotate|rotation|prune|max_bytes|max_size|truncate|compact" \
    lib/keeper/keeper_external_attention.ml lib/keeper/keeper_external_attention.mli
(no matches)
```

## Premise verification — growth (confirmed unbounded, currently small)

PR #21124 (`git show 1d757c1dd`) commit message, verbatim: "The store still
grows unbounded (no prune/retention) — that is a separate retention-policy
decision, deliberately out of scope here." So unbounded-by-construction is the
author's own statement, not an inference (contrast RFC-0238, which misattributed
a directory total to one file).

Live measurement. Running instance base path from process args:

```
$ ps -o command= -p <masc pid> | tr ' ' '\n' | grep base-path
--base-path=/Users/dancer/me
```

Only one store file exists on this host:

```
$ du -h /Users/dancer/me/.masc/external_attention/sangsu.jsonl
 12K	/Users/dancer/me/.masc/external_attention/sangsu.jsonl
$ wc -c < .../sangsu.jsonl   # 11146 (apparent bytes)
$ wc -l < .../sangsu.jsonl   # 17
$ rg -o '"event":"[a-z_]+"' .../sangsu.jsonl | sort | uniq -c
  11 "event":"recorded"
   6 "event":"resolved"
```

Derived rate (received_at span 1781191592 → 1781438452 = 246,859 s ≈ 2.86 d):

- 11,129 non-blank bytes / 2.86 d ≈ 3,895 B/day
- ~654 B/line, ~1,012 B/recorded-event (incl. its resolve)
- ~16.8 d to fill the 64 KiB dedup window; ~269 d to reach 1 MiB

Conclusion: premise correct in direction (no rotation exists), NOT in magnitude
(KB/day, not GB). RFC bounds it before it matters; risk scales with keeper count
× connector fan-in, not wall-clock.

## tail-dedup gap (file:line)

- `dedup_window_bytes = 64 * 1024` (`:31`) — perf knob leaked into correctness.
- `record` dedups only within the tail window (`:481-488`).
- `load_recent_events` parses bytes strictly between first/last newline; if the
  slice has fewer than two newlines it returns `[]` → no dedup → record always
  accepted (`:458-479`, specifically `:475-479`). Reachable when one serialized
  line ≥ ~64 KiB (large `content_preview`, which the gateway fills with raw
  Discord `content`, `lib/server/server_discord_in_process_gateway.ml:183`).
- Window-escape duplicate: a redelivery older than the 64 KiB tail re-appends.

## read-side cost gap

`pending_for_keeper` calls `load_events` (`:584`) → `fold_appended_lines ~from:0`
(`:401-416`), i.e. O(total file) on every keeper turn admission, even for a
fully-resolved keeper. #21124 bounded only the write path (`record`), not this
read. This is the cost that bites before disk size does.

## Lifecycle entry points (who calls what)

```
lib/server/server_discord_in_process_gateway.ml:160 record_external_attention → record
lib/server/server_discord_in_process_gateway.ml:207 mark_attention_resolved   → mark_resolved
```

## Boundary / RFC gate

No credential/identity/sandbox/operator-control surface touched. Related RFC:
RFC-0232 P5 (shared `Surface_ref`), unchanged by this RFC. Doc-only; no code in
this PR.
