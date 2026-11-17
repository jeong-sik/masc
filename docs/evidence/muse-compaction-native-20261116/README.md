# Native Muse compaction and durable-session reload

This is a **selected metadata derivative**, retained for the L2 continuity work.
[observations.json](observations.json) was extracted from the actual result and
111-record MSP wire in
`artifacts/continuity-native-20261116/echo-20261116T134949Z` in the shared main
checkout. Despite the directory's `echo-` prefix, this successful run used
**Meta, `muse-ember-1.0`, with the external model API enabled**.

The code under test was the installed native Muse executable, not a MASC build.
The handshake reports Muse **1.4.20**, a durable session, and macOS. The JSON
records the executable's SHA-256, the handshake schema fingerprints, and the
SHA-256 of the separately exported installed CLI `msp.d.ts`. These identify
different byte sequences; the schema export digest is not the handshake
fingerprint. No MASC candidate source head is certified by this native run.

The native process was launched as `muse serve --provider meta --preset
native-basic --disable-shell --disable-write --disable-request-user-input` in
an owned scratch workspace. The probe used the MSP sequence `initialize`,
`initialized`, `session/start`, three `turn/start` commands, `session/read`,
`session/compact`, `session/read`, `session/leave`, `session/resume`, and one
further `turn/start`. The probe's recorded source digest matches the source
read at retention. This bundle does not contain a public, credential-free
reproducer for the Meta run.

| Observation | Original wire lines | Retained result |
| --- | --- | --- |
| First three turns | 11/30, 32/50, 52/71 | Each accepted turn ID matches its `turn/completed`, `terminal=completed` |
| Before compaction | 73 | `turnCount=3`, last turn completed |
| Manual compaction | 74–78 | Accepted command, then completed compaction item with `outcome=compacted`, targeting that last turn |
| After compaction | 80 | `turnCount=1`, same session and same completed last turn |
| Leave | 81–85 | Matching leave command, `session/closed reason=leave`, `status=notLoaded`, then `outcome=released` |
| Resume | 86–88 | Same durable session and completed last turn, `turnCount=1` |
| Fourth turn | 91/109 | Accepted new turn ID matches its `terminal=completed` notification |

Turns two and three were acknowledged with `disposition=queued` and
`startedNewTurn=false`; their later matching completed terminals establish the
completion. Admission alone is not counted as completion.

Here, **cold resume means reloading an unloaded durable session after release**.
The installed schema says that `session/closed` unloads the session and that
`session/resume` reloads it. The observed `notLoaded` transition precedes the
resume. The same owned host process remained alive; no new-process, crash, or
server-restart recovery was tested.

Earlier attempts are retained as non-successful history in the JSON:

- Echo runs `132135Z` and `132455Z` each completed three turns, then received
  `-32030`, `commandRejected`, `compaction_unavailable`. The latter records
  `preset=native-basic`; the former does not record its preset. Neither is
  compaction or post-compaction resume evidence.
- The initial Meta run `133951Z` exited with code 3 before an initialize result
  or session start. Its private stderr identifies unreadable saved Meta
  credentials in macOS Keychain, OSStatus `-50`. The failure classification and
  original artifact digests are retained; its log text is excluded.

Only allowlisted protocol metadata, generated fixture IDs, line references,
and digests are retained. Prompts, message text, tool arguments/results,
authentication, private configuration, absolute home/workspace paths, and full
raw wire are excluded. `raw_artifacts` digests identify the **original private
bytes**, not this derivative JSON. Relative artifact locations refer to the
original shared checkout and are not committed public captures.

This proves that the native host can reduce its folded completed-turn count
while preserving the last completed turn identity, reload that session after
release, and complete another turn. It does not execute the MASC Muse adapter,
its continuity/held-System decisions, or its scripted-host regressions. It does
not establish semantic memory quality, absence of duplicate tool effects,
automatic mid-turn compaction, UI behavior, or long-running continuity. The
[earlier compacted-history bundle](../muse-compacted-turn-history-20261116/README.md)
contains separate copied-log and source-replay evidence with its own limits.

Retention checks: raw result/wire relations and hashes were checked directly;
JSON parsing and `git diff --check` passed. No new native turn, Dune build,
typecheck, Alcotest execution, or CI was run while retaining this bundle.
