# PR #41119 model editor convergence and conflict repair

## 2026-10-07 repair onto main

The previous head `e9f1bb67e34fe2cbc007cbae4ff2a6acbe50d2b2` retained the
original parent history after #41102 and #41114 were squash-merged. Reconstruct
the child-only change against main `08d5f8950ebedd71bf1f5b57c10c429be292243e`,
using historical parent `399e0c572f7a25633d385e98c305bb0ebe68c8c2` to separate
the 13 child files from the already integrated parent work.
Then rebase the isolated repair onto main
`2af3af572c2b0b9e81b15d075aabdb0bb0615759`, including the subsequently merged
composer/navigation and workspace identity changes. The child patch applies
without further conflicts; source review must also cover the changed consumers.

Main's shared top-level configuration writer remains the owner. Its local
model/account/raw-editor caller reconciles typed unknown outcomes without
duplicating the preview or write. Preserve main's PTY close helper alongside
the restored Runtime roster scenario. Update the existing footer regression
for the two mode-specific `e` actions; its prior single-action assertion no
longer describes the feature. Keep the existing same-read revision assertion
in the account fixture without adding an equivalent duplicate.

This repair uses source review and whitespace checks only. No local build,
native test, PTY, CI, installed binary or live runtime validation is claimed
for this candidate. The execution records below belong to the older candidates
named in their sections and must not be used as current-head test results.

## Historical 2026-10-04 repair

Original head: `d4554daebf756d0ec803d4d37cdad933b36985d3`.
Integrated main: `6fc062feee7e33a271e09dc155d9feffee923704`.
Reviewed product-source commit: `a0332c0b871824faa9d3736867c716b6ba735565`.
REST #41119 has no native stack membership and targets main.

## Result

The old branch conflicted with the already merged account/Lane audit. It also
introduced a second model form and writer for a feature already owned by Config
Models. The final implementation keeps the shared `Masc_tui_model_form`, the
existing source reader and validated configuration commit path.

Runtime All `e` resolves the exact selected runtime ID through a fresh source
read, as Runtime detail and Standalone Lane settings already do. Context offers
272k, 500k, 750k, 1M and custom input. Custom text survives preset cycling; Copy
suggests a context-based name after preset selection until the operator edits
it. The source account, API model, binding controls, defaults and Lane order
remain governed by the existing shared form. Context is a binding-local request;
observed capability clamps remain visible through Runtime.

The shared raw save now accepts an optional source revision and checks it inside
the existing write lock before committing. Every TUI text/model/account editor
sends its same-read revision. Model/account forms also keep their opening
revision and refuse to apply stale fields to a newer source. Confirmed refusal
and unknown outcome are separate typed HTTP results. Lost, 5xx or unreadable
commit replies retain the draft and trigger Config/catalog/Runtime/Lanes reads;
they never automatically retry the write or claim it did not save.

The unused dedicated form, model-context API, independent resolved-snapshot
revision read and copy-table primitive are removed from this PR. The lower
setup changes already incorporated in main are retained at main's version.

## Review responses

| Finding | Resolution |
| --- | --- |
| P1 review 5404653175: duplicate form/writer | Reuse one shared model form and validated raw writer; retain the Runtime roster entry and presets. The former audit stack is already in main, which remains the base. |
| 4176556260: copied context overrides | Shared Copy writes the requested binding-local context, preserves operational controls, and leaves defaults/Lane order unchanged. Binding context takes precedence over provider/model declarations. |
| 4176556263: revision independent of snapshot | Remove that resolved revision path; use source text and revision from one raw observation, anchor it to the draft, and compare again inside the writer lock. |
| 4176556266: non-structural copy target | Remove the duplicate primitive; shared Copy checks parsed model IDs and scans structural lines for source subtrees. |
| 4176556269: unknown mutation outcomes | Typed saved/refused/unconfirmed results; unknown reloads affected readings and retains the original draft revision. |
| 4176556270: dotted/inline declarations | Shared form explicitly refuses unsupported declaration shapes before mutation and directs the operator to expand the source table. |

## Historical executed verification

- **2 native focused form tests passed** using the actual key/render prefix and
  real row definition, text layout and line editor. Full apply/outer TUI are
  excluded from that execution.
- **4 native raw-body parser/status tests passed** using actual parser and SHA
  predicate excerpts, with only Runtime error constructors supplied separately.
- **27 native save-boundary assertions passed** using actual HTTP outcome/body/
  receipt mapping, revision guard and shared save excerpts plus the complete
  real receipt module. Transport/status decoding, workspace and refresh effects
  are stubbed; this is not a complete server/TUI execution.
- Changed OCaml/Python source syntax and diff whitespace passed. Independent
  source reviews covered the form/entry scope, server CAS scope and client save
  scope separately; the parent reviewed their composed diff and corrected the
  PTY guard's preview path before freezing.

Authored but not executed: full shared-form apply regression; stale raw-save
preservation of disk/runtime cache/registry; full account-form tests; three PTY
scenarios covering roster entry, stale form/reopen and lost-commit-reply recovery.
Fixture construction and AST checks do not count as PTY execution.

No local Dune/full build, full typecheck, native server/TUI acceptance, live
configuration change, merge or release is claimed. Original PR test counts are
historical and do not certify this rewritten scope. Any manual CI result must
name the final published head separately from these focused checks.

## Historical convergence onto required raw-save CAS

The sections above describe historical source/stub checks at the earlier
candidate; their unexecuted list is not the current integration status.
Current local integration is based on child
`fdf1f9c53084743e954cc91baf5e0c817d9c22f6` with real merge parent #41114
`1e2a84ff85337b2c6e441b52b37177ae99c788ff`.

The parent Runtime writer, HTTP client, server raw routes, Web editor and CAS
regressions are retained without an optional-revision path. The duplicate
`save_config_text_checked` and optional parser/test surface are removed.
Model/account forms retain their opening revision and reject a different fresh
source before applying fields; saves then use the parent's mandatory locked CAS.
Unknown replies retain the form/revision and reconcile Config, catalog, Runtime
and Lanes. No automatic resend is introduced.

Actual current focused wrapper build passed for both native form test targets
and the TUI executable. Native suites passed: 11 model and 22 account tests.
Actual account PTY passed both stale/reopen and committed-but-lost-reply flows;
Runtime All roster Edit/Copy/preset/cancel/no-POST PTY passed; the parent's raw
config draft recovery PTY also passed against the current TUI. Binary SHA-256:
`eef9d9c4d311891dab3056d47f8d493dbf0edb0cdeef1862f3a5da4bb2ddbe48`.

The initial native builds exposed missing direct Astring, Toml_line_editor and
Llm_provider dependencies in the existing model-form test stanza; all three
actual direct dependencies are now declared. Roster fixture repairs preserve
functional assertions: request a genuine initial resize, assert the real All
roster's five IDs rather than a clipped tab caption, supply the required float
TOML deadline, and await changed frames before checking cancellation state
rather than requiring unchanged chrome to be emitted again.

Logs: `/tmp/pr41119-focused-build4.log`, `/tmp/pr41119-native-forms.log`,
`/tmp/pr41119-account-pty.log`, `/tmp/pr41119-roster-pty6.log`, and
`/tmp/pr41119-raw-draft-pty.log`. Ruff passed for both changed Python files.
Pyright reports 14 existing lane-fixture object-shape diagnostics; the complete
file/rule/message multiset equals the unchanged parent's baseline. The two new
roster diagnostics were corrected with explicit fixture shape checks; the
account fixture has no diagnostics. Baseline/current logs:
`/tmp/pr41119-parent-lane-pyright.json` and `/tmp/pr41119-pyright-final.json`.
No full suite, current browser, deployed runtime, release or GitHub mutation is
claimed by this local integration. Historical evidence stays pinned separately.
