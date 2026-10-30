# Local combined-candidate essential behavior — 2026-10-05

All 13 selected suites completed successfully with the unchanged canonical runner on local-only merge candidate `7e10a972db75e696448e128f495b650bb2d3c1bd`, tree `ea50994c383863092ec21d5868f353d31e08aa03`. Its exact parents are CI profile head `a549b6e0fb99ebf3792dbff2a3844fa9dd2ccf88` and current fixture head `d98f76c980a06f64e60fe209ccde44b376f2e256`. No additional main, public-interface, or Lane-chain changes were included. The candidate remains clean and local; Native Stack #41158 was not rewritten.

The ordered profile equals the CI worktree profile byte-for-byte: `release-essential-v1`, SHA-256 `70e088bf9a046c385ada20ac67069ee315491975ac37ccee38554b4048f0f93d`. The runner schedules both PTY aliases before native suites, so completion order differs from manifest order. All 13 unique completion names match the manifest exactly after removing the native `test/` path prefix.

## Execution

Resource-limited `opam exec --switch=5.5.1 -- scripts/dune-local.sh build` prebuilt `bin/masc_tui.exe` and the 11 selected native executables (handle 33714, exit 0). Then, from the candidate root:

```sh
OPAMSWITCH=5.5.1 DUNE_JOBS=2 \
CI_TEST_LOG_FILE=/tmp/release-essential-local-candidate.log \
bash scripts/run-release-behavior.sh
```

Canonical runner handle 32698 completed with exit 0. It ran the two forced PTY aliases and all 11 native suites using declared dependencies, per-stanza environments and working directories. The current remote-workspace fixture, including Ask and foreign/matching successor coverage, ran in full. The runner built its declared `main_eio.exe` dependency without any source repair.

[results.json](results.json) records every suite result/duration, both candidate parents, profile, commands, binary hashes and original log hashes. [prebuild.log](prebuild.log) and [runner.log](runner.log) preserve exact captured bytes. The canonical and redirected runner logs were byte-identical and are stored once. Candidate HEAD/tree/clean state, both binary hashes, ordered profile equality and all 13 exact completion lines were rechecked before copying. Log inspection found no credential values; key-related lines are blank test environment assignments or assertion labels. Local paths and synthetic fixture data remain unchanged. Raw EOF whitespace is preserved.

This is evidence only for the combined local candidate. It does not claim that either individual PR head passed this updated profile, hosted CI or RC passed, or production is qualified. Metadata/Home fixtures outside the selected profile and TerminalBench were not run as part of this qualification. Prior profile evidence remains historical.
