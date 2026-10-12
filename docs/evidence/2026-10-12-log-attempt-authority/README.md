# Single runtime-attempt interpretation

Base 5c266fedcdbc19f7760a31dc1de2235c6b69e349.

The event log held its own attempt counter and tagged every entry after every
Runtime_attempt_started. It ignored the supplied attempt_index and the reducer's
same/older-attempt policy. Supplied indices 7,7,3,8 acquired log tags 1,2,3,4.
Transcript already owns attempt interpretation, including source/continuation
and terminal-state policy. Product consumers never used the log attempt counter
or entry tag; only test_tui_keeper_chat_log referenced them (bin/test search).

Remove the unused log counter/tag/accessor instead of duplicating reducer rules.
Log entries retain original delta, sequence and event time. Existing counter
fixture is replaced with raw explicit observation preservation; obsolete wire/
journal counter comparisons removed. Sequenced replay dedup/cursor unchanged.
No rendered behavior improvement or full all-provider correction is claimed by
this structural cleanup. Runtime attempt decisions remain in transcript.

## Direct bounded measurement

/tmp/masc-log-attempt-authority-20261012/{generate.py,parent.ml,current.ml,parent.log,current.log}.
Actual complete log add function and log declarations/constructor interpreted;
actual journal seq_is_after/replay_position_advance functions. Minimal Live
payload types (unrelated payloads unit), Ids source string shim and operation
state unit declaration; no full journal/event/reducer integration.
Parent exit2: duplicate attempt interpretation disagrees with supplied identity.
Current exit0: raw indices 7,7,3,8 preserved; duplicate seq refused without revision
change; cursor After_seq3 preserved. The parent mismatch checks redundant tags;
current validates remaining event-log contract, not reducer attempt correctness.

Three changed OCaml files syntax-only parse and diff check pass. Registered
fixtures updated but unexecuted. No full typecheck/build/CI/runtime/UI,
installation/formal approval/merge proof. Full user goal remains active.
