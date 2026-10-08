# Keeper turn response contract, 2026-10-09

Parent: `8b1aee00d581a78de5764c36e27d9dcea6a441fd` (#41974).
Issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).

`Keeper_agent_run` combined turn orchestration and pure completion policy / text
normalization. The normalizer required `initial_messages` but explicitly ignored
it. Its caller supplied checkpoint history even though only the runtime result,
text, tool names and response policy influence this decision.

The 68-line pure unit now belongs to `Keeper_turn_response_contract`. Production
and four existing test suites call that owner directly. The ignored argument and
the two `Keeper_agent_run.For_testing` forwarding exports are deleted. No alias,
compatibility branch, duplicate policy or new product field is introduced.
The new interface documents actual inputs and typed outcomes before implementation.

`Keeper_agent_run.ml` changes from 2,649 to 2,575 lines. The moved function body
matches the parent after deletion of the ignored label and boundary whitespace;
[extraction.json](extraction.json) records its SHA256. Root also compared the
remaining orchestration body after just the declared removal and direct-call edits.
Provider dispatch, original/resumed checkpoint history and post-turn persistence
still receive their history. Their behavior is not inferred from line counts.

## Consumer checks

| Changed interface | Direct consumer / original behavior scenario | Executed result |
| --- | --- | --- |
| Turn completion policy | `run_turn` setup; wake-context policy scenario | 1 passed: missing observation, pending message, schedule delivery, Ask and Gate obligations |
| Response normalization | `run_turn` after provider result; accept suite cases 11-13 | 3 passed: explicit empty final versus absent/hidden/truncated/refused output, typed empty-response rejection, hidden reasoning and tool-only response |
| Response normalization | Claude adapter quiet-completion case 0 | 1 passed: explicit, absent, null, direct and failure variants |
| Response normalization | Muse adapter quiet-completion case 0 | 1 passed after fixture preparation repair: explicit versus missing final message |

[checks.json](checks.json) records exact commands, terminal exit codes and executable
hashes. The four directly affected executables built successfully. After the Muse
fixture correction, its executable was rebuilt successfully and its selected case
was rerun. Final results cover six executed cases; skipped cases are not counted.
The existing assertions and payload variants are preserved. No new tests mirror
module names or the extraction implementation.

## Reproduced fixture defect

Running the selected Muse case directly initially failed before normalization
with `missing required Antigravity prompt: keeper.antigravity.current_goal_label`.
[muse-before.log](muse-before.log) preserves that failure; whitespace-only
indentation on an empty diagnostic line is normalized in the stored log.
Muse frames its start
prompt with shared Antigravity assets; its test runner did not register the source
prompt directory. It now uses `Masc_test_deps.source_path` and
`Prompt_registry.set_markdown_dir`, as the adjacent Claude runner does.
[muse-after.log](muse-after.log) records the actual successful scripted-host case.
The repair neither replaces runtime prompts nor supplies fallback labels.

## Scope

[source-sha256.json](source-sha256.json) fingerprints all changed source and the
unchanged response/error helpers consulted for purity and semantics. The selected
Claude and Muse checks use temporary workspaces and scripted local clients. They
are adapter evidence, not live provider or deployed Keeper continuity proof.
Full suites, full builds, CI, deployment and live runtime are unverified here.
Other orchestration, transcript admission, hook, trace and checkpoint
responsibilities remain pending; this is a bounded partial repair in the original
171-candidate campaign.
