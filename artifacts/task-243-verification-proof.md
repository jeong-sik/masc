# task-243 verification proof

## Scope

The current PR head already contains the requested trailing `unit` on
`Keeper_continuation_channel.discord`, the JSON decoder call, and the direct
call sites. This worktree adds only the missing test build plumbing needed to
compile and run the affected publisher tests:

- `test/keeper_continuation_delivery_publisher/dune` links
  `masc.keeper_runtime` for both publisher test executables.
- The five affected `Result.fold ~error:fail` uses are made explicit
  `(fun error -> fail error)` for the current Alcotest labelled `fail`
  type.

## Verification

Build invocations (all successful):

```text
bash scripts/dune-local.sh build --build-dir _build-task243 \
  test/keeper_continuation_channel/test_keeper_continuation_channel.exe \
  test/keeper_continuation_delivery_intent/test_keeper_continuation_delivery_intent.exe \
  test/keeper_continuation_delivery_intent/test_keeper_continuation_delivery_origin.exe \
  test/keeper_continuation_delivery_publisher/test_keeper_continuation_delivery_publisher.exe \
  test/keeper_continuation_delivery_publisher/test_keeper_continuation_delivery_conformance.exe

bash scripts/dune-local.sh build --build-dir _build-task243 \
  test/test_keeper_owner.exe test/test_keeper_surface_post.exe \
  test/test_fusion_wake.exe test/test_fusion_delivery_obligation.exe \
  test/test_keeper_event_queue.exe test/test_keeper_connector_attention_wake.exe
```

Passed focused executions:

- `test_keeper_continuation_channel`: all tests passed.
- `test_keeper_continuation_delivery_intent`: ok.
- `test_keeper_continuation_delivery_origin`: ok.
- `test_keeper_continuation_delivery_publisher`: 7 tests passed.
- `test_keeper_continuation_delivery_conformance`: 5 tests passed.
- `test_keeper_owner`: 36 tests passed.
- `test_keeper_surface_post`: 19 tests passed.
- `test_fusion_wake`: 14 tests passed.
- `test_fusion_delivery_obligation`: 6 tests passed.
- `test_keeper_connector_attention_wake`: 5 tests passed.

The `test_keeper_event_queue` executable compiled, but its full legacy run
stops at an unrelated pre-existing duplicate pending-source snapshot assertion
in `test/test_keeper_event_queue.ml:1703`; the preceding connector-route
assertions complete. No `discord` call-site compile error occurs.

Static search of `lib` and `test` found every direct
`Keeper_continuation_channel.discord` call and the local channel-test
`discord` calls with the required trailing `()`. `git diff --check`
passes.
