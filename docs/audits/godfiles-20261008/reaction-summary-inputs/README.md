# Reaction summary inputs, 2026-10-09

Parent: `b7db02e79f1454b5bb3bfbd51068780654689113` (#42060).
Issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).

`summarize_rows` and `error_summary` accepted `limit` without reading it.
Remove those two internal parameters and their forwarding arguments. The public
`summary_for_keeper` and fleet API still pass the requested limit to
`Dated_jsonl.read_recent_result`, where it selects the rows to read. The public
interface, actual storage selection, summary JSON and cancellation propagation
are unchanged. This is a small cleanup of a previously identified Godfile,
not a new candidate or completion of its remaining responsibility audit.

Focused validation on the current parent and changed source:

- `opam exec -- dune build --root . -j 4 test/test_keeper_reaction_ledger.exe`:
  terminal exit 0.
- `_build/default/test/test_keeper_reaction_ledger.exe --color=never`:
  terminal exit 0, existing isolated ledger suite 31 cases passed,
  Alcotest run `K5QGS70R`. Covers durable writers, summary classification,
  quarantine, fleet projection and evidence/cache invalidation.
- `git diff --check`: terminal exit 0.

The checks do not establish provider execution, live Keeper/UI behavior,
installation, deployment, full CI or approval of the parent stack. No tests
were added to mirror this argument removal.

Validated SHA-256 identities:

| Input | SHA-256 |
| --- | --- |
| `lib/keeper/keeper_reaction_ledger.ml` | `b3fada80d5a03de53c8abd29cea0a91a6526adf6e7cc58c4af04585f9c951770` |
| `lib/keeper/keeper_reaction_ledger.mli` | `29f1d174a3ddde87d69d25a8e62a5c962f5ad82cde2281c3b32acbfeea3fa665` |
| `_build/default/test/test_keeper_reaction_ledger.exe` | `eb0a62e5e6735b6de273c16828941ecc8bf6812366a77358104b386458b1cc21` |
