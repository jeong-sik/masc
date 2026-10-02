# RC 36994367072 behavioral repair

## Scope and source

User-requested repair of [failed job 110797616721](https://github.com/jeong-sik/masc/actions/runs/36994367072/job/110797616721).
Base: `b9968002e46a4d170d44ea43111a69a49c084477`, PR #40842.
The job reported eleven failed suites. This change does not exclude suites or increase timeouts.

## Repairs

| Failed suite | Cause and correction |
| --- | --- |
| `test_candle_appraiser_transport` | HTTP 400 is an execution rejection, not invalid output. Check the exact error constructor, durable code and evidence classification. |
| `test_keeper_librarian_cancellation` | Registry list projections omit input payloads. Use the existing hydrated Librarian-pass reader; keep both terminal-outcome assertions. |
| `test_tui_librarian_absorb_gate` | Its cancellation executable prerequisite is the preceding failure. No independent TUI repair inferred. |
| `test_tui_keeper_portrait_pty` | Product defect: Item reads required admin-only public Candle fields although the account endpoint permits read-state access. Require current Keeper presence instead, retaining workspace identity, response generation, selected Keeper and strict account decoding. |
| `test_tui_home_failure_task_pty` | Exit the recovered composer before q; give exact authority outcomes sufficient viewport width and expect the active request-checker's refusal. |
| `test_tui_home_queue_identity_pty` | Identity withdrawal intentionally cancels the old reader. Observe fixture settlement and retained queue instead of requiring a withdrawn reply; verify original request ID and one recovery admission. |
| `test_tui_keyboard_general_pty` | Palette-targeted alpha chat returns to the preserved beta roster cursor. |
| `test_tui_keyboard_overview_pty` | Check beta's own scroll indicator instead of alpha's document length. |
| `test_tui_keyboard_input-fusion-history` | Wait for the historical entry, not merely the asynchronous surface title, before Enter. |
| `test_tui_remote_workspace_history_pty` | Workspace withdrawal already returns to the roster. Avoid an extra Escape and inspect an already-rendered Channels tab. |
| `test_tui_tool_results_pty` | Wait for the authority follow-up Dashboard bundle before counting observer-driven reads. Keep exact +1, replay suppression and compact-mode assertions. |

## Verification performed

The native replay binary came from artifact `11221209060` of the failed run:
`runtime-probe-linux-x64-b9968002e46a4d170d44ea43111a69a49c084477-attempt-1`.
Manifest commit matches the base above. Verified TUI SHA-256:
`32ae18021c8db2417e678fb0b3848f190285fd9866dd8a1765b86be97d6063db`.

- Reproduced both Home failures and the observer result-count failure against this binary.
- `python3 test/test_tui_home_failure_task_pty.py /tmp/masc-runtime/masc_tui.exe`: PASS, all four scenarios.
- `python3 test/test_tui_home_queue_identity_pty.py /tmp/masc-runtime/masc_tui.exe`: PASS, one scenario.
- Focused `keeper_detail_overscroll_interaction`, `chat_visibility_modes_interaction`, `run_fusion_history_regression`, and `connector_workspace_withdrawal`: PASS on the same binary.
- Focused `run_observer_results`: PASS on the same binary.
- Python parsing and `git diff --check`: PASS.
- Independent source review covered backend classification/registry fixes, Home authority scenarios, Item permission boundaries and navigation fixtures; no unresolved P0/P1/P2 findings in those scopes.

These are synthetic fixture results on the old compiled product. They do not prove the new Item code compiles or executes. Backend OCaml changes require new-head CI. No local Dune build was run under the repository execution protocol.

## Required release evidence

Explicitly run `release-candidate.yml` on the final repair head. All compile, behavioral and installation jobs must succeed for that exact SHA. Obtain independent exact-head Release approval citing that completed run, inspect stack/base/current review state, then perform normal integration/tag/publication. No tag, release publication, deployment, or production data modification is established by this record.
