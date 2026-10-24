# Native HTTP receiver fixture initialization

Native run `40097972974`, exact head
`1eef45b69f395b1819537c116c7df839023da110`, built and executed the seven
requested suites. The HTTP receiver suite passed its first five cases.
Its three-request case passed every Goal ID/revision/measurement assertion
and every first-request-only other-world assertion, then failed its real
Task/Goal link assertion. The actual bundled callback logged:

```
tool keeper_task_create failed: MASC not initialized.
```

The test had created only the `.masc` directory. The canonical Task writer
calls `ensure_initialized` before it writes the backlog. `Workspace.init`
creates workspace state and the initial backlog; the multi-request fixture
also binds its producer session through that real initializer. The single
request cases now use the same initialized workspace without a session.

The repair changes the test setup only. Task creation still uses the actual
bundled tool, and the authoritative one-Task Goal-link assertion is retained.
Before that assertion, the test prints the actual correlated ToolResult,
checks its typed success outcome and confirms `ok=true` and the requested
Goal ID in the returned payload. A later failed callback can no longer hide
behind the deterministic peer's final "Task recorded" response.

The remaining suites passed at the original native head:

| Suite | Tests |
| --- | ---: |
| `test_keeper_prompt_capture` | 9 |
| `test_turn_record` | 41 |
| `test_keeper_context_layers` | 11 |
| `test_keeper_next_request_forecast` | 31 |
| `test_keeper_official_client_host` | 85 |
| `test_keeper_context_observation_projection` | 13 |

The inspected clean native log is
`/tmp/masc-goal-retention-native-failed-clean.log`, SHA256
`9d7c04df28ecb0d80e1a792df3be5427759c93ce854ddb3c1510cd36c6bbdae0`.
The whole native run remains FAIL. Product context delivery passed the
receiver assertions; successful real Task persistence in this fixture is
still unverified until the corrected HTTP receiver suite runs natively.

Local validation of this repair: OCaml parser and `git diff --check` passed.
No local Dune build or native execution was performed. The next targeted
check is `test_keeper_direct_goal_provider_wire` at the integrated repair
head; no product file changed in this follow-up.
