# Installable macOS runtime artifacts

The manual `installable-runtime-macos-arm64` target builds the canonical local
installer's complete default target list, including TUI, deployment preflight,
SSH bootstrap and every browser Add-on program. The candidate must contain
`install-local-build.sh --print-build-targets` and the artifact packaging helper.
The separate `ego-runtime-macos-arm64` target builds only the server, browser
worker and launcher for focused experiments; it cannot feed a complete install.

Dispatch **Manual probe artifacts** with an explicit full source commit:

```sh
gh workflow run linux-x64-probe.yml --repo jeong-sik/masc --ref main \
  -f target=installable-runtime-macos-arm64 -f candidate_sha=FULL_SOURCE_SHA
```

Continue other work. At the next work boundary, read that run's actual status,
workflow head and attempt. A queued or failed build is not an installable result.
The workflow head may differ from the candidate source; retain both identities.
For a successful run, download its named artifact into a new directory:

```sh
gh run download RUN_ID --repo jeong-sik/masc \
  --name installable-runtime-macos-arm64-FULL_SOURCE_SHA-attempt-ATTEMPT \
  --dir artifacts/runtime-download/UNUSED_RUN
```

From the download directory, check the outer archive and extract into an empty
directory. The tar archive retains executable permissions that Actions ZIP
downloads discard. Then verify every member against the receipt and the
independently read source, workflow head, run and attempt:

```sh
shasum -a 256 -c SHA256SUMS
mkdir runtime
tar -xzf installable-runtime.tar.gz -C runtime
python3 runtime/scripts/ci/runtime-install-artifact.py verify \
  --directory runtime --source FULL_SOURCE_SHA --workflow-head FULL_WORKFLOW_SHA \
  --run-id RUN_ID --attempt ATTEMPT
```

Verification rejects missing, changed, extra or nonregular files and lost
executable permissions. The bundle contains the exact candidate's canonical
installer, its preflight gate and the `.exe` layout it requires. Install with
an explicit workspace base path; the existing preflight and browser refresh
procedures still apply:

```sh
bash runtime/scripts/install-local-build.sh --skip-build \
  --build-dir "$PWD/runtime/bin" --base-path /path/to/workspace --no-guest-shim
```

`--no-guest-shim` leaves an existing guest release shim in place; the artifact
does not contain a guest image or shim upgrade. The installer also accepts its
normal prefix and manifest directory options. A running server keeps its old
build until explicitly restarted. Verify the installed executable, process,
effective base path, Add-on generation and actual browser behavior separately.

The receipt binds source commit/tree, workflow/run identity, the installer's
build list, every payload hash and native dependency observations. It records
`installed=false`, `behavior_executed=false`, `release_verified=false` and
`relocatable_runtime_verified=false`: this is a native build artifact, not a
Release, an autonomous Keeper verdict or proof that Homebrew libraries exist on
another machine. Read `dependencies.txt` and preserve installation failures.
