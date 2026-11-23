# Exact-source native TUI proof

Use this explicit development check when a native terminal scenario requires
an executable from a particular source commit. It does not approve a PR, merge
a stack, install the operator's runtime or replace full Release/Tag checks.
No push, PR or scheduled trigger is added.

`pr-check.yml` accepts `native-tui-source-sha` (exactly 40 lowercase hexadecimal
characters) and `native-tui-scenario`:

| Scenario | Native build targets | Executed suites |
| --- | --- | --- |
| `detail-ownership` (default) | TUI, key-doc generator and 10 test executables | `v2_tui_tests` (`test_core_term`, `test_keymap_ui`, `test_protocol_net`, `test_server_config_roundtrip`, `test_store`, `test_screens_core`, `test_screens_ops`, `test_screens_domain`, `test_app`) plus `test_server_tui_v2_api` |
| `workspace-files` | TUI, key-doc generator, server and 11 test executables | `test_repo_git`, `test_workspace_file_confidentiality`, plus `v2_tui_tests` |
| `rich-workspace` | TUI, key-doc generator, server and 12 test executables | The `workspace-files` suites plus `test_lsp_position` |
| `rich-chat-workspace` | TUI, key-doc generator, server and 12 test executables | Same targets as `rich-workspace` (`test_repo_git`, `test_workspace_file_confidentiality`, `v2_tui_tests`, `test_lsp_position`) |
| `original-tool-result` | TUI, key-doc generator, server and 4 test executables | `test_keeper_tool_result_source`, `test_tool_output_washing_e2e`, `test_server_dashboard_http_keeper_tool_lookup`, `test_keymap_ui` |
| `code-references` | TUI, key-doc generator, server and 5 test executables | `test_lsp_workspace_pool`, `test_lsp_questions`, `test_lsp_message_router`, `test_lsp_process_manager`, `test_server_ide_lsp_proxy` |
| `resource-reading` | TUI, key-doc generator, server and 2 test executables | `test_screens_domain`, `test_protocol_net` |
| `addon-lifecycle` | TUI, key-doc generator, server, native Addon launcher and 2 test executables | `test_lane_addon_application`, `test_screens_domain` |
| `browser-lane` | TUI, key-doc generator, server, Browser Addon worker, native Addon launcher and 11 test executables | `test_browser_lane`, `test_browser_lane_watched_work`, `test_browser_addon_observation`, `test_browser_addon_tool`, `test_browser_ego_peer`, `test_browser_native_workflow`, `test_browser_addon_live_ego`, `test_browser_addon_wire`, `test_browser_selection`, `test_server_lane_inventory`, `test_keeper_vision_tool --browser-screenshot` |
| `source-readers` | TUI, key-doc generator, server and 4 test executables | Same targets as `original-tool-result` (`test_keeper_tool_result_source`, `test_tool_output_washing_e2e`, `test_server_dashboard_http_keeper_tool_lookup`, `test_keymap_ui`) |
| `code-drafts` | TUI, key-doc generator, server and 3 test executables | `test_workspace_file_confidentiality`, `test_keymap_ui`, `test_screens_core` |
| `tui-performance` | TUI, key-doc generator and 10 test executables | `v2_tui_tests` plus `test_server_tui_v2_api` |

The server target is `bin/main_eio.exe`; the TUI is `bin/masc_tui.exe`.
Every scenario also builds `bin/masc_tui_keys_doc_cli.exe`, the canonical key
reference generator, from the selected source. This adds no test suite.
Server and integration test targets live under `test/<suite>.exe`; TUI v2
suites live under `test/masc_tui_v2/` (`test_core_term.exe` and
`<layer>/<suite>.exe`) and `test/server_tui_v2_api/test_server_tui_v2_api.exe`.
Unknown scenarios are refused before source checkout and again before selecting
build targets. With no native source SHA, only the existing source/config/credential
checks run.

Use `rich-workspace` or `rich-chat-workspace` for a workspace, LSP-position and
full TUI v2 integration candidate. Both build the matching server and TUI and
run `test_repo_git`, `test_workspace_file_confidentiality`, all nine
`v2_tui_tests` suites, and `test_lsp_position`. They do not establish visible
terminal behavior; record live terminal checks separately against the same
source commit. For example:

```sh
gh workflow run pr-check.yml --repo jeong-sik/masc --ref WORKFLOW_REF \
  -f native-tui-source-sha=SOURCE_COMMIT_40_HEX \
  -f native-tui-scenario=rich-chat-workspace
```

Use `original-tool-result` or `source-readers` for the retained original-result
endpoint and its TUI keymap/UI consumer. Both run the three server
original-result suites (`test_keeper_tool_result_source`,
`test_tool_output_washing_e2e`, `test_server_dashboard_http_keeper_tool_lookup`)
plus `test_keymap_ui`, and package the matching server and TUI for separate
Keeper-result verification. These four suites do not run the five LSP suites,
real Pyright, complete producer stdout capture, or visible terminal/clipboard
behavior. The selected source must contain all four targets; a missing target
fails instead of reducing scope.

```sh
gh workflow run pr-check.yml --repo jeong-sik/masc --ref WORKFLOW_REF \
  -f native-tui-source-sha=SOURCE_COMMIT_40_HEX \
  -f native-tui-scenario=source-readers
```

Use `code-drafts` for a selected workspace-confidentiality and TUI core-screen
candidate. It runs `test_workspace_file_confidentiality`, `test_keymap_ui`, and
`test_screens_core`, and packages the matching server/TUI for separate editor/save
verification. These three suites do not establish visible terminal behavior,
real editor usability, or successful deployment. All three targets must exist
in the selected source; no missing suite is silently omitted.

```sh
gh workflow run pr-check.yml --repo jeong-sik/masc --ref WORKFLOW_REF \
  -f native-tui-source-sha=SOURCE_COMMIT_40_HEX \
  -f native-tui-scenario=code-drafts
```

Use `code-references` for a selected Code reference-readiness candidate. The
workspace-pool suite drives the real question API and transport with a controlled
Python LSP peer: exact URI/version analysis observations, cancellation and late
notifications, serialized reference queries, peer EOF isolation, blocked frame
writes and queued cancellation. Python 3 is required for that peer. The question
and router suites check result decoding; the process-manager suite checks child
lifecycle; the IDE proxy suite checks its workspace and protocol boundaries.
Building the matching server and TUI also checks their direct consumers. These
five suites do not run real Pyright, prove complete project indexing or verify
the visible reference picker. Run the selected pair against the actual language
server in an isolated workspace to establish those observations separately.

```sh
gh workflow run pr-check.yml --repo jeong-sik/masc --ref WORKFLOW_REF \
  -f native-tui-source-sha=SOURCE_COMMIT_40_HEX \
  -f native-tui-scenario=code-references
```

Use `resource-reading` for a domain-screen and protocol/network candidate. It
runs `test_screens_domain` and `test_protocol_net`, and packages the matching
server and TUI for separate API and terminal observations. These two suites do
not exercise a live terminal or establish a live report publication. Both
targets must exist in the selected source; a missing target fails rather than
reducing the scope.

```sh
gh workflow run pr-check.yml --repo jeong-sik/masc --ref WORKFLOW_REF \
  -f native-tui-source-sha=SOURCE_COMMIT_40_HEX \
  -f native-tui-scenario=resource-reading
```

Use `addon-lifecycle` for an Addon installation/worker observation candidate.
It runs `test_lane_addon_application` and `test_screens_domain`, and packages
the matching server, TUI, and native Addon launcher for separate On/Off/reconnect
observations. Passing these suites does not prove that a container, real model
or visible terminal executed. Both selected targets must exist; a missing target
fails instead of reducing scope.

```sh
gh workflow run pr-check.yml --repo jeong-sik/masc --ref WORKFLOW_REF \
  -f native-tui-source-sha=SOURCE_COMMIT_40_HEX \
  -f native-tui-scenario=addon-lifecycle
```

For the `workspace-files` scenario:

```sh
gh workflow run pr-check.yml --repo jeong-sik/masc --ref WORKFLOW_REF \
  -f native-tui-source-sha=SOURCE_COMMIT_40_HEX \
  -f native-tui-scenario=workspace-files
```

Use `browser-lane` for a selected Ego/Browser request and activity candidate.
It builds the matching TUI, server, Browser Addon worker and native launcher
together and runs the eleven named protocol/codec/routing/request-state suites.
The additional checks cover private client DTOs, worker-to-Ego process ownership,
Space selection/binding, exported inventory and stored screenshot context.
`test_keeper_vision_tool` runs only `--browser-screenshot`, not its full vision
suite. The invocation arguments are retained with the results.
The worker peer suites use controlled runners; they do not launch a real Ego
browser. The artifacts support a separate isolated real Keeper/UI probe of those
exact bytes. Successful compilation or component tests do not prove installation,
real Keeper execution or visible terminal/browser behavior.

```sh
gh workflow run pr-check.yml --repo jeong-sik/masc --ref WORKFLOW_REF \
  -f native-tui-source-sha=SOURCE_COMMIT_40_HEX \
  -f native-tui-scenario=browser-lane
```

Use `detail-ownership` (the default) or `tui-performance` to package the TUI
binary alone (no server binary) and run all nine `v2_tui_tests` suites plus
`test_server_tui_v2_api`.

Replace both placeholders with the selected workflow ref and full feature
commit. Before the workflow changes reach main, select the reviewed CI branch
explicitly. Record the returned run identity. Continue independent work; do not
watch, wait for or repeatedly poll CI. At a real work boundary, read the actual
result. An accepted request or running job is not a passing result.

## Artifact and receipt

The artifact is named `tui-macos-arm64-<source SHA>-<run ID>`. It retains build
targets, logs, completed suite names, native dependency lists and `receipt.json`.
The TUI's embedded `--build-commit` must equal the selected source. The server-bearing
scenarios also check the server's `build-commit` and include it as `masc`, with
its own digest and dependency list. The receipt records source SHA, workflow
SHA, scenario and both binary digests; the existing TUI `sha256` field remains.
The default scenario records no server digest.

The `addon-lifecycle` and `browser-lane` scenarios also build `bin/masc_native_addon_launcher.exe`
from the selected source and packages it as `masc-native-addon-launcher` with
`launcher-native-dependencies.txt`. The receipt's `native_addon_launcher`
records its path, SHA-256 and producer target; it is null for other scenarios.
`browser-lane` additionally packages `masc-browser-addon-worker` and
`browser-worker-native-dependencies.txt`. Its `browser_addon_worker` receipt
records the worker's path, SHA-256 and producer target, and is null otherwise.
This executable has no build-commit command: its source identity comes from
the exact-source build targets and receipt, not an embedded commit check.
Put this verified artifact directory on the isolated server's PATH so native
worker observation uses the candidate launcher rather than copying an installed
one of unknown build source. This does not install an operator runtime or prove
that a worker launched; actual lifecycle observations remain separate.

`key-reference.md` contains the key reference produced by that source's actual
generator. The receipt's `key_reference` records its artifact path, SHA-256 and
producer target; the surrounding source/workflow identities also apply to it.
Generation must succeed before a final receipt is written. A selected source
without the generator target fails instead of substituting another document.
It is the readable key reference for that source; no copy is committed. It does
not establish visible key handling or compare screen wording, layout or row
order.

Every selected suite runs once even if an earlier suite fails. The workflow
retains each suite and log pipeline exit code in `test-results.tsv` and the
receipt. `executed_tests` includes completed failed suites as well as passing
ones; `behavior_passed` requires the complete selected list in order and zero
suite/log exit codes. A failed suite still fails the job. `test-invocations.jsonl`
records each actual suite's argument array. The receipt includes both
`test_invocations` and `expected_invocations`; `behavior_passed` also requires
their exact ordered equality. A narrow screenshot check cannot be reported as
the whole vision suite.

After a successful build, exact-commit binary packaging also runs when a suite
fails, so the artifact can support further diagnosis without rebuilding. A
failed behavior receipt does not certify those binaries for installation or
turn the failed job into a passing check. Cancellation does not start packaging.

The workflow revision chooses the checks, while checkout and dependency setup
use the selected feature tree. Validate both identities before reusing the
artifact. A missing receipt, failed suite or partial artifact is not success.
These are native executables with the dynamic libraries listed in the artifact;
this is not a portable release package.

Once the selected run has completed, inspect its conclusion and download the
artifact for that source and run:

```bash
PROOF_DIR=artifacts/native-tui-proof-RUN_ID
gh run view RUN_ID --repo jeong-sik/masc
gh run download RUN_ID --repo jeong-sik/masc \
  --name tui-macos-arm64-SOURCE_SHA-RUN_ID --dir "$PROOF_DIR"
cat "$PROOF_DIR/receipt.json"
cat "$PROOF_DIR/native-dependencies.txt"
shasum -a 256 "$PROOF_DIR/masc-tui"
chmod +x "$PROOF_DIR/masc-tui"
"$PROOF_DIR/masc-tui" --build-commit
```

Replace `RUN_ID` and `SOURCE_SHA` with the selected identities. Compare the
downloaded hash and embedded commit with the receipt and selected source. Inspect
the dependency list and local loader result before using the executable;
dependencies may refer to Homebrew paths or versions on the builder. Keep the
original receipt and record subsequent workspace observations separately.

For a server-bearing scenario, also verify the packaged server before using it:

```bash
cat "$PROOF_DIR/server-native-dependencies.txt"
shasum -a 256 "$PROOF_DIR/masc"
chmod +x "$PROOF_DIR/masc"
"$PROOF_DIR/masc" build-commit
```

Compare its hash with `receipt.json`'s `server_sha256` and its embedded commit
with the selected `SOURCE_SHA`. Check its dependency list and local loader result
as well. A missing server or server digest in a server-bearing scenario is an
incomplete artifact. The default scenario packages only the TUI.

## Actual workspace behavior

Use a separate workspace, port and terminal. Keep the operator's server,
installation and drafts intact. Verify downloaded hashes and embedded commits,
then run the matching server and TUI against that same isolated workspace.
Do not pair a new TUI with an older server lacking its workspace endpoint and
call that a feature verdict.

Once the verified matching server is running on the isolated workspace and port,
launch the downloaded TUI in a separate terminal:

```bash
"$PROOF_DIR/masc-tui" --base-path BASE_PATH --port PORT
```

Replace `BASE_PATH` and `PORT` with that isolated server's workspace and port,
then verify the connected workspace before exercising the changed behavior.

Record saved state, actual requests and manual terminal captures separately
from the build/suite receipt. Do not add screen wording, layout, row-order or
PTY assertion tests. The artifact receipt deliberately leaves installed-runtime
and visible-UI verification false.
