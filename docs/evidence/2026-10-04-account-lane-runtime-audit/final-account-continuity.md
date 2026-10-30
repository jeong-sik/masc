# Account continuity after merged review stacks

Original stack #41118 (ten PRs) and follow-up #41144 (six PRs) merged in
other sessions on 2026-10-04. This response session did not submit those merges.
The #41144 leaf merge `63a19a12a89dfbadf9eb91e30f20092b6f06238b` has the same
tree as its published `693c2b3c8decbf2770a606ff64bb46e8b981bcca` head.
Sixteen addressed original review threads were resolved after verifying that
integration. The remaining three findings are addressed in native stack #41150.

The new stack is based on main `61e0d3ad9e000ac0788dd1d5e3a826217bdc50ef`.
Integrated source before this evidence-only commit: `464d691df846f471714e18334c6edf725a70b131`.

| PR | Original finding | Correction |
| --- | --- | --- |
| #41146 | #41107 / 4176693842 | Reuse selected inline-auth HTTP providers through private typed provenance, revalidated against the locked connection and credential. Preserve operator settings; replacement keys stay separate. |
| #41148 | #41107 / 4176693855 | Saved Antigravity selection retains its original credential reference and declared timeout. The native discovery copy stays cleanup-owned; exact selected provider ID and existing model settings survive. |
| #41149 | #41107 / 4176693849 | Preserve the previously resolved wizard default when adding candidates. Handle standard, inline and dotted binding declarations without invalid duplicate headers; implicit model-set choices receive explicit overrides. |

## Executed checks and source review

- Inline-account unit: **58 native assertions passed** using the actual
  setup-spec implementation/interface and unchanged production source-selection
  excerpts. Schema/registry and private-file effects are stubbed; complete
  server and batch fixture suites were not executed.
- Saved-account unit: **48 actual Python adapter/account tests passed** again
  after replay, including real-shaped changed receipt paths, custom timeouts,
  save and cancellation cleanup. The compiled native producer-to-consumer-to-
  resolver regression was authored but skipped because a matching binary is
  absent; the native inventory projection regression was not run.
- Wizard editor: **55 native editor tests passed** using the complete production
  editor with installed Otoml/Alcotest; strict warning typecheck passed. Native
  output for six layouts passed strict Python tomllib parsing, including absent
  descendants inside inline ancestors. Six full batch regressions were authored
  but not executed. Replayed editor/batch files are byte-identical to the tested
  author unit at `549c43a79696352ab75129f19b52aec604b0c6b9`.
- Integrated source: fourteen changed OCaml/Python source files parsed; final
  wizard changes parsed again and diff whitespace passed. The only replay
  conflict joined independent test functions and both registrations.

Independent source review caught the first saved-account repair relying on an
unchanged native receipt path, inline/dotted table redefinition, and missing
inline descendants. A parent review also corrected the new binding context
expectation before publication. Final source reviews are separate from GitHub
approval; no self-approval or merge-guard bypass is authorized by these results.

## Remaining boundaries

The existing batch writer still refuses adding a model when the entire top-level
binding group is a sealed inline table (for example `account = {}` plus a model
set). The nested boolean helper can now edit that structure, but the separate
new-binding append path already failed for it before this change. This baseline
save-refusal limitation remains; this stack does not claim support for every
TOML declaration layout.

No local Dune/full build, newly linked complete server/TUI, actual account login,
PTY/browser end-to-end run, deployment or live runtime configuration mutation was
performed. The earlier 104 dashboard tests and CI run 37189789727 belong to the
previous merged source. Any new minimal CI result must name the final published
head; none of these focused results proves a complete TUI acceptance run.
