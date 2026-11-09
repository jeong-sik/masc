# Pinned opam binary cache

[Issue #50437](https://github.com/jeong-sik/masc/issues/50437) records four
type-check jobs that restored the switch cache, then failed before compilation
while downloading opam 2.5.0: curl returned HTTP 504 and the existing GitHub CLI
fallback also failed. The switch cache does not contain the opam executable.

The action now caches the release binary separately by version, OS and
architecture. Only a default-branch push whose checkout matches its event SHA
saves it. Manual candidate builds restore only, including dispatches started on
main. Reuse requires an executable that successfully reports exactly the pinned
version; a download must pass the same check before entering the cache. A cold
download failure still fails the job.

`observations.json` records 22 bootstrap cases and five cache-save policy cases
using the action's actual shell bodies with isolated command stubs. The exact
warm fixture makes zero download, fallback, repository refresh or switch
initialization calls. The cases also cover a cold cache, failed downloads,
invalid binaries, all four platform keys and the existing compiler contract.
These fixtures do not prove native release binary behavior, GitHub cache
restoration or runner CI success.

From the repository root, with Python, PyYAML and Bash installed:

```sh
python3 docs/evidence/2026-11-09-opam-binary-cache/reproduce.py
```

New results go under ignored `artifacts/opam-binary-cache/`. `--repo`,
`--baseline` and `--output` can select a checkout, the pre-change switch-policy
baseline and a fresh output directory. The baseline commit must be available
locally. The stubs use temporary paths and never change the installed opam root.

The observation manifest identifies the action and retained fixture by SHA-256.
The initial 20 cases were retained and seven review regressions were added.
Until a successful default-branch job seeds the binary cache, a miss still
requires a working release download.
