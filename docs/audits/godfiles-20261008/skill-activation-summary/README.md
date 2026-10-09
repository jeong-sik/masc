# Skill activation summary ownership, 2026-10-09

Parent: `f4fd7e5ca4f4ff72f3e872da403a8ad140f14365` (#42087).
Issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).

The activation ledger mixed immutable evidence declarations and pure summary
projection with mutable revision memoization, strict codecs, replay, file locks
and durable writes. Canonical immutable activation and summary declarations now
belong to Dune-private `Keeper_skill_activation_types`. Pure total/scoped
summaries and their JSON projection belong to Dune-private
`Keeper_skill_activation_summary`.

The summary owner accepts only activation and rejection lists. It cannot receive
the ledger record or its mutable revision memo. Scoped summaries no longer copy
that record to summarize their selected evidence. One canonical rejection-ID
accessor is shared by summary and replay, rather than duplicated. Public ledger
summary functions resolve their immutable inputs at the existing API boundary.

The public ledger `.mli` is byte-identical, retaining private activation records,
private nonempty Task-ID sets, private revision strings and abstract ledger
values. Constructors, strict codec, revisions, event replay, locks, filesystem,
cache/cursor invalidation and mutation policy remain in the ledger. From
`validate_served_content` through the end, its source is byte-identical to the
parent; the mutable ledger declaration is also unchanged.

Root: 2,609 → 2,253 lines. Immutable types: 151 ML lines; pure summary: 223.
The scope selection/counting algorithm and order remain the same. This unit
does not establish a performance improvement or finish the codec/replay/storage
audit; repeated list scans remain a separate candidate for further analysis.

Focused build:
`opam exec -- dune build --root . -j 4 test/test_keeper_skill_activation_ledger.exe test/test_keeper_skill_activation_projection.exe`
completed with terminal exit 0.

Existing isolated consumer suites:

- From `test/`, `../_build/default/test/test_keeper_skill_activation_ledger.exe --color=never`:
  terminal exit 0, 35 cases passed, run `GQTVGN4R`, [ledger-test-cwd.log](ledger-test-cwd.log).
  Includes actual durable delivery/action chains, exact scope/runtime/reference
  counts, strict revision/codec identity, append replay, replacement and torn tails.
- `_build/default/test/test_keeper_skill_activation_projection.exe --color=never`:
  terminal exit 0, 10 cases passed, run `FSC5GEU2`, [projection.log](projection.log).
  Includes dashboard and chat-history exact evidence attachment and typed failures.
- Compiler API probes: normal public summary use compiled; private activation
  update, direct Task-ID-set creation and raw revision string each refused with
  its intended type error. See [api-probes/results.md](api-probes/results.md).
  This proves public type restrictions, not installed namespace exclusion.

Initial root-cwd ledger execution exited 1: 34 cases passed, but its shared
revision fixture was looked up under `fixtures/` relative to the root. The same
binary passed all 35 from the suite's `test/` directory. [ledger.log](ledger.log)
retains that first failure; it was not a product-code fix. Successful cases are
counted once, yielding 45 distinct existing cases. [source-sha256.json](source-sha256.json)
records 12 source/context identities and [extraction-comparison.json](extraction-comparison.json)
checks the stated declaration/body boundaries. No tests are added to mirror module placement.
Live Keeper/provider/UI, installation, deployment, full CI, whole-stack approval
and completion of the original 171-candidate campaign remain unverified.
