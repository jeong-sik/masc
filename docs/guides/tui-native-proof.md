# Manual native TUI artifact

Use this check when an actual macOS arm64 executable is needed to verify a TUI
change. It does not run automatically on PRs or pushes, replace independent
source review, or establish a Release verdict.

## Dispatch

Choose the exact source commit and the branch containing the proof workflow:

```bash
gh workflow run pr-check.yml --repo jeong-sik/masc --ref WORKFLOW_BRANCH \
  -f native-tui-source-sha=SOURCE_SHA
```

Replace `SOURCE_SHA` with 40 lowercase hexadecimal characters. The source tree
must include the named targets below and the existing toolchain/pinning actions.
An empty `native-tui-source-sha` runs only the existing source/config checks.

The native job builds these four targets:

```text
bin/masc_tui.exe
test/test_tui_detail_reading.exe
test/test_tui_board_successor.exe
test/test_tui_usage_scope.exe
```

It runs the three test executables, verifies `--build-commit` against the source
SHA, and checks `--help`. It does not run all tests or assert screen contents.
Continue useful work after dispatch; inspect the result at a work boundary.

## Download and inspect

Use the run URL returned by dispatch to obtain `RUN_ID`. Once the run has
completed, inspect its actual conclusion and download the matching artifact:

```bash
gh run view RUN_ID --repo jeong-sik/masc
gh run download RUN_ID --repo jeong-sik/masc \
  --name tui-macos-arm64-SOURCE_SHA-RUN_ID --dir PROOF_DIR
cat PROOF_DIR/receipt.json
cat PROOF_DIR/native-dependencies.txt
shasum -a 256 PROOF_DIR/masc-tui
chmod +x PROOF_DIR/masc-tui
PROOF_DIR/masc-tui --build-commit
```

The receipt binds source SHA, workflow SHA, binary hash, explicit build targets
and successfully completed suites. Failed runs can upload partial logs without
a binary or final receipt; an uploaded artifact alone is not a passing check.
`build-targets.txt`, `executed-tests.txt` and per-suite logs show the actual scope.

## Exercise separately

This artifact is a native executable, not a relocatable installer. Its dynamic
dependencies may refer to Homebrew paths or versions on the builder. Inspect
`native-dependencies.txt` and the local loader result before using it. Missing
libraries are a packaging/runtime limitation, not proof of a TUI behavior defect.

Use a separate terminal and the downloaded executable to preserve any active
chat input in the installed TUI:

```bash
PROOF_DIR/masc-tui --base-path BASE_PATH --port PORT
```

Replace `BASE_PATH` and `PORT` with the intended runtime identity, then verify
the connected workspace. Record the exact binary hash/source SHA and the
interactions actually observed, including resize and return navigation for
changed readers. Do not infer visible behavior from backend logs or a passing
state test. The workflow receipt leaves `installed_runtime_verified` and
`visible_ui_verified` false; preserve that original receipt and record subsequent
observations separately. This check neither replaces the installed binary nor
restarts the server.
