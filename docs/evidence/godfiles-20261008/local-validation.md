# Operator-requested local validation

Source head: `4a08c8a2bee6862297cae4a2cc3db00d231b854b`.
Environment: macOS arm64; OCaml 5.5.1; Dune 3.24.1; opam switch 5.5.1.

The operator explicitly requested checking a local build in this session.
That request takes precedence over the external-coding-session default in
`docs/constitution.xml`. It authorizes these focused local checks; it does not
change repository policy or create a periodic build schedule.

| Check | Result | Measured duration | Artifact |
| --- | --- | --- | --- |
| `opam exec -- dune build -j 4 lib/masc.cmxa lib/dated_jsonl/dated_jsonl.cmxa` | Exit 0 | 95.636 seconds | [local-build.log](local-build.log) |
| `opam exec -- dune exec -j 4 test/test_keeper_chat_store.exe -- test row_kind` | Exit 0; 3 tests passed | 84.552 seconds including executable preparation; tests 0.015 seconds | [local-chat-kind.log](local-chat-kind.log) |

The row-kind group checks transport-failure roundtripping, omitted-kind
utterance semantics, and invalid-kind rejection without acknowledging pending
input. The invalid-kind scenario covers unknown, empty and whitespace labels,
and integer, null and boolean values; the strict reader also refuses each row.
Every other group in that executable was explicitly skipped.

This proves compilation of the named library targets and those three tests on
the combined source head. It does not prove isolated compilation of every PR,
all chat behaviors, UI/runtime integration, release CI, independent GitHub
approval, merge, or deployment. The earlier `validation.log` remains a historical
parse-only receipt; this later receipt records the additional authorized checks.

## Follow-up on the kind contract

The writer omits `kind` for `Utterance`; the reader therefore treats absence as
utterance. `role` and `kind` are separate fields in the in-memory product. These
are current contracts, beyond the unknown-value defect repaired in #41871.
Review writer/reader/consumer combinations before changing the schema. In
particular, trace which roles can legitimately carry transport failure, and
whether explicit wire classification and a role-specific sum type would remove
impossible combinations. Renaming the field alone does not establish that.

Continue the full Godfile campaign. These successful checks do not close the
71 production candidates still pending semantic review in the baseline inventory.
