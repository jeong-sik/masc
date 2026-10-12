# Exposed Thinking bytes after piece closure

Base `db880140cbf02574aad9d0c72124e35d6ac47163`.

The exact content tombstone prevented repeated observed metadata from reopening a closed piece, but actual late Thinking bytes still activated reasoning progress. Targeted parent `keeper-stream.test.ts` selection `-t 'closed thinking while retaining'` exited1: both direct and autonomous lanes failed, expected waiting but received thinking (137 skipped).

The shared atomic Thinking writer now consults current exact generation/scope/block content metadata before changing activity. Closed or channel-conflicting occurrences retain exposed bytes as trace observations without reactivating progress. Unknown piece metadata does not erase actual exposed bytes; existing response admission remains responsible for their authority. A genuinely newer response retires old occurrence state and can reason normally with the reused block index.

Final stream suite `vitest run src/keeper-stream.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1`: exit0, 139 tests, 821ms. Two new cases execute actual direct buffered publication and autonomous journal projection, preserving late exposed text and permitting a newer response to resume. `tsc --noEmit`: exit0. `git diff --check`: exit0.

Synthetic event data exercises production state code; no live provider, installed application, actual browser/screenshot, build or CI proof. TUI counterpart audit and broader provider/runtime validation remain pending.
