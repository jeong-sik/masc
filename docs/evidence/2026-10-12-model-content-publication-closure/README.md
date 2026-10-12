# Content closure across reactive publication

Base `ffe29b473d7396540fba9596f7e1b14406e0e19d`.

The live metadata handler checked its occurrence before committing buffered Thinking. A real Preact signals observer then published a closed tombstone for that same occurrence, keeping response and target ownership unchanged. The final metadata updater overwrote the newer tombstone with observed, reopening the piece.

Executed targeted parent test `-t 'content closure published'`: exit1, one failed and135 skipped, expected ended but received observed. Synthetic metadata and observer data execute real buffering/signals/publication; not a provider incident.

Revalidate current channel, closed state and duplicate observation inside the atomic occurrence update. Preserve a closure or channel conflict that arrived during effects. Earlier exposed reasoning remains in the trace. No new ownership registry, epoch or text matching is added.

Final `vitest run src/keeper-stream.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1`: exit0, 137 tests, 846ms, with reactive closure and channel-conflict scenarios. Final `tsc --noEmit`: exit0. `git diff --check`: exit0.

Original source-response HOLD remains at `/tmp/masc-dashboard-model-content-response-20261012/report.md` in the local review workspace. Stored occurrence/tombstone parity remains pending. No build, CI, installation, provider, browser or screenshot validation.
