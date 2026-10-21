# Related Addon worker owners at the same TOML path

Worklist G04 follow-up, [PR #44807](https://github.com/jeong-sik/masc/pull/44807). Source `c54fd2515c0901c63ebe19069153a7bf4d46e156`, base `ad6ca89213d57c9ac978e1f3e5704292c4334cf6`.

A changed installation ID at an existing TOML path left the other owner's cleanup failure out of its related connection detail. Dashboard and TUI now keep two disjoint read-only groups: workers with the selected installation ID, including renamed source paths, and other installation IDs at exactly the selected source path. Manual attachments relate only their original instance/incarnation. Neither null paths nor a shared title/run/package join unrelated workers.

Each group retains its actual owner, incarnation, revision, phase and completed-observation counters. The second group does not claim chronological order or become the selected installation's application, action target or execution authority. Existing pinned detail selection and retained-action refusal are unchanged. This does not claim the entire G04 lifecycle is visibly verified.

## Completed checks

```sh
cd dashboard
pnpm exec vitest run --config vitest.config.ts --no-file-parallelism --maxWorkers=1 \
  src/components/lane-addon-connection.test.ts \
  src/components/lane-installation-manager.test.ts \
  src/components/lane-addons-panel.test.ts
pnpm exec tsc --noEmit
```

Three Dashboard test files / 62 tests pass; TypeScript exits0. `dashboard-vitest.txt` retains the actual test output with trailing blank lines removed. `receipt.json` binds the five changed implementation/test blobs. Three changed OCaml ML/MLI files pass parser-only checks in `ocaml-parser.json`; this is not typing or execution.

Dashboard tests cover disjoint ID/path groups, same-ID file moves, unrelated same-name workers, manual attachments and a missing selected declaration not borrowing another ID's application. The added TUI test checks actual read-model membership and original incarnation/revision/failed-cleanup state; it adds no wording, layout or row-order assertions. These OCaml scenarios have not executed yet.

## Remaining evidence

Request only `test_tui_lane_addons` on the final frozen source for this changed direct consumer. Reusing the older G01 native artifact or its direct-consumer result would not test this new TUI read model. Dispatch acceptance, source approval, actual Dashboard/TUI observation, whole-stack integration and installed runtime are separate claims. No live operator server, profile or binary was replaced.
