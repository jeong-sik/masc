# LibrarianRead message accounting

`LibrarianRead.tla` checks whether a read position passes source messages without
accounting for them. The original atom/turn-boundary model keeps its writer,
restart, refused-line, progress and purge rules. The message-floor extension adds
an atomic publication abstraction with two messages in each atom. Two is a finite
exploration bound, not a product limit.

`readIds` means an atom was delivered in full. `readMessages` contains individual
successful deliveries. A durable unread record has its own globally unique atom
ID, message index, one named cause and evidence that every slot refused that
message. An atom is accounted for only when every message is delivered or has its
own valid record. A record never turns an omission into a successful delivery.
Source IDs abstract the exact trace/generation/coordinate/hash identity enforced
by the production codecs. Slot exhaustion and a cause witness are inputs from a
completed step; this model does not simulate provider requests or infer capacity.

The only authorized causes are `Context_overflow`, `Input_capacity` and
`Request_body_refused`. `Invalid_request`, `Refusal_body_not_received` and opaque
CLI failures cannot authorize an omission. Neither can a size cause before all
slots refused. The original eventual-actual-reading properties are unchanged;
recorded omissions do not satisfy those legacy liveness assertions.

This extension assumes final publication at the selected original atom boundary
succeeded. It does not prove volatile message processing, Memory disposition
composition, durable I/O recovery, request delivery, official-client sessions or
the runtime skip producer. Those remain part of issue #37850.

## Focused verification

On 2026-10-19 KST, Java 21 and the repository-selected local `tla2tools-1.8.0.jar`
completed all 19 configurations with one worker each. The actual JAR identifies
itself as TLC2 Version 2026.05.26.235334 (rev 4ba7d88); its SHA-256 is
`237332bdcc79a35c7d26efa7b82c77c85c2744591c5598673a8a45085ff2a4fb`.
No Dune build or CI run was performed for this specification change.

Use the installed JAR chosen by `scripts/tla-check.sh`, and run each
`specs/bug-models/LibrarianRead*.cfg` from the repository root:

```sh
java -XX:+UseParallelGC -Xmx2g -cp "$TLC_JAR" tlc2.TLC \
  -workers 1 -deadlock -noGenerateSpecTE -metadir "$TLC_STATES" \
  -config "$CFG" specs/bug-models/LibrarianRead.tla
```

`TLC_JAR` is the existing tool JAR, `CFG` is one concrete configuration and
`TLC_STATES` is a separate artifact directory for that execution. Normal configs
must exit 0 after complete exploration. Every `*-buggy.cfg` must fail its named
safety property (exit 12), or the original anywhere-live property (exit 13).
Parser, evaluator, tool and resource failures are not successful bug detection.
The repository harness discovers every negative config and explicitly includes
the new positive recorded-messages config; `specs/Makefile` discovers both sets.

| Configuration | Exit | Result |
| --- | ---: | --- |
| `LibrarianRead-buggy.cfg` | 12 | NoAtomPassedUnread |
| `LibrarianRead-first-refused-only-buggy.cfg` | 12 | NoAtomPassedUnread |
| `LibrarianRead-foreign-source-buggy.cfg` | 12 | NoAtomPassedUnread |
| `LibrarianRead-live-without-bad-lines.cfg` | 0 | complete, no violation |
| `LibrarianRead-one-record-for-atom-buggy.cfg` | 12 | NoAtomPassedUnread |
| `LibrarianRead-position-first-buggy.cfg` | 12 | NoAtomPassedUnread |
| `LibrarianRead-purge-split-buggy.cfg` | 12 | NoAtomPassedUnread |
| `LibrarianRead-purge-trim-anywhere-live-buggy.cfg` | 13 | EveryReachableAtomEventuallyRead (liveness) |
| `LibrarianRead-purge-trim-at-end-live.cfg` | 0 | complete, no violation |
| `LibrarianRead-purge-trim-at-end.cfg` | 0 | complete, no violation |
| `LibrarianRead-purge-trim-buggy.cfg` | 12 | NoAtomPassedUnread |
| `LibrarianRead-purge-trim-by-turns-buggy.cfg` | 12 | NoAtomPassedUnread |
| `LibrarianRead-purge-trim-counting-lines-buggy.cfg` | 12 | NoAtomPassedUnread |
| `LibrarianRead-recorded-messages.cfg` | 0 | complete, no violation |
| `LibrarianRead-stop-forever-live.cfg` | 0 | complete, no violation |
| `LibrarianRead-unexhausted-slots-buggy.cfg` | 12 | UnreadEvidenceTyped |
| `LibrarianRead-unknown-cause-buggy.cfg` | 12 | UnreadEvidenceTyped |
| `LibrarianRead-unrecorded-message-buggy.cfg` | 12 | NoAtomPassedUnread |
| `LibrarianRead.cfg` | 0 | complete, no violation |

The original clean model explored 496,181 distinct states. The new positive
recorded-messages model explored 63,629 distinct states (182,035 generated), with
an empty queue and maximum depth 18. A separate `-coverage 0` run completed the
same state graph and executed the unread-record publication expression, confirming
that its success was not caused by leaving the new path unreachable. All eight
pre-existing bug configurations and all five new mutants produced violations.
The new sibling mutant records only one omitted message: it still fails
`NoAtomPassedUnread`, so an atom-level record cannot cover its unread sibling.
