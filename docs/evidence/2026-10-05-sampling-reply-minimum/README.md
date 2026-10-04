# Sampling reply envelope admission

Parent #40960 `41680bd6a2592ef7c490d3ec6302daef9633955f`; relates #41186.
A host-sampling refusal is returned as a JSON string. Even the empty string requires two bytes, but manifest admission and direct broker creation admitted a one-byte limit. Both boundaries now reject values below the actual minimum. Model-disabled manifest admission is unchanged. The broker interface documents this constraint; no provider limit or arbitrary runtime budget is introduced.

Two new native regressions failed against unchanged parent production code, then passed after the admission repair. The manifest rejects zero/one and accepts two; the direct broker rejects one/zero, accepts two, and its real out-of-observation callback returns an encoded two-byte refusal without invoking the provider. The existing oversized-retention case now uses the smallest admitted envelope (two rather than one); its no-provider-invocation assertion is unchanged.

Commands from this worktree:

```sh
opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_lane_addon_worker.exe
_build/default/test/test_lane_addon_worker.exe test lifecycle 0,1 --color=never
_build/default/test/test_lane_addon_worker.exe --color=never
```

The focused build passes. The final full worker suite passes all 30 cases, including existing recovery, encoded refusal, subprocess and cancellation cases. Subprocess tests use the existing hermetic Docker-control fixture, not real Docker isolation or provider execution. This is no full CI or release claim. The final binary/source and exact raw log hashes are below; no pre-repair executable hash was retained. The RED ran only the two new cases, not the full worker suite. Raw logs retain original whitespace.
