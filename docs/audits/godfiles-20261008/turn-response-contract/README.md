# Keeper turn response contract, 2026-10-09

Parent: `ae4af3e52e5965fc5e32629c4cb7dac699fe8627` (#41974).
Issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).

`Keeper_agent_run` combined turn orchestration and pure response text
normalization. The normalizer required `initial_messages` but explicitly ignored
it. Its caller supplied checkpoint history even though only the runtime result,
text and tool names influence this decision.

The pure unit now belongs to `Keeper_turn_response_contract`. Production and the
accept test suite call that owner directly. The ignored argument and the
`Keeper_agent_run.For_testing` forwarding export are deleted. No alias,
compatibility branch or new product field is introduced.

The moved function body equals the parent's after deleting the ignored label;
[extraction.json](extraction.json) records its SHA256. Provider dispatch,
original/resumed checkpoint history and post-turn persistence still receive their
history.

## Consumer checks

| Changed interface | Direct consumer | Executed result |
| --- | --- | --- |
| Response normalization | `run_turn` after provider result; accept suite | 43 passed |
| Muse source prompt assets | Muse runtime suite | 59 passed |

[checks.json](checks.json) records the commands and exit codes.
The full-tree `@check` build passed at this commit.

## Muse fixture preparation

Running a selected Muse case directly failed before normalization with
`missing required Antigravity prompt: keeper.antigravity.current_goal_label`.
[muse-before.log](muse-before.log) preserves that failure. Muse frames its start
prompt with shared Antigravity assets; its test runner did not register the source
prompt directory. It now uses `Masc_test_deps.source_path` and
`Prompt_registry.set_markdown_dir`, as the adjacent Claude runner does.
[muse.log](muse.log) records the full suite run.

## Scope

Full test suites other than the two above, CI, deployment and live runtime are
unverified here. Other orchestration, transcript admission, hook, trace and
checkpoint responsibilities remain pending.
