# Installable macOS runtime artifacts

The manual `installable-runtime-macos-arm64` target builds the canonical local
installer's complete default target list through `scripts/dune-local.sh build`
with the same default profile, including TUI, deployment preflight,
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

Use an independently trusted checkout at the exact candidate commit. Obtain it
through your trusted repository remote, independently of the downloaded bundle.
Run the verifier from that checkout, never from the download. From the download
directory, safely extract into a new directory and verify against the trusted
Git objects and the independently read workflow head, run and attempt:

```sh
candidate_repo=/absolute/path/to/independently-trusted-candidate-checkout
python3 "$candidate_repo/scripts/ci/runtime-install-artifact.py" extract \
  --trusted-repo "$candidate_repo" --archive installable-runtime.tar.gz \
  --directory runtime --source FULL_SOURCE_SHA --workflow-head FULL_WORKFLOW_SHA \
  --run-id RUN_ID --attempt ATTEMPT
```

The extraction operation preflights every archive member before writing any:
it rejects links, traversal, absolute paths, duplicate members, special files,
unsafe permissions and an existing destination. It creates regular files itself
and preserves their executable permissions. It never calls `tar -x` or executes
code from the download. Failed verification preserves the extracted evidence.

Verification requires the trusted checkout's HEAD to equal the candidate and
checks its source files against that commit's Git blobs and modes. The receipt's
source tree must equal the actual Git tree; all bundled installer, preflight and
verifier bytes and Git modes must match before any installer query. Only the
validated trusted installer's `--print-build-targets` query runs. Results state
`trusted_candidate_installer_queried=true`, `downloaded_code_executed=false` and
`candidate_binaries_executed=false`. Querying source is not a native runtime
behavior measurement. To verify an already extracted directory, use the same
trusted verifier's `verify` operation with `--trusted-repo` and the same identities.

The receipt and outer `SHA256SUMS` are downloaded records, not independent source
authority. Continue to require the independently observed successful GitHub run;
source-file binding alone does not prove that native binaries were built in it.
Verification rejects missing, changed, extra or nonregular files and lost
executable permissions. After it succeeds, the existing canonical installer and
browser refresh procedures apply, with an explicit workspace base path:

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
