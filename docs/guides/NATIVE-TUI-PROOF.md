# Exact-source native TUI proof

Use this explicit development check when a native terminal scenario requires
an executable from a particular source commit. It does not approve a PR, merge
a stack, install the operator's runtime or replace full Release/Tag checks.
No push, PR or scheduled trigger is added.

`pr-check.yml` accepts `native-tui-source-sha` (exactly 40 lowercase hexadecimal
characters) and `native-tui-scenario`:

| Scenario | Native build targets | Executed suites |
| --- | --- | --- |
| `detail-ownership` (default) | TUI and the three test executables | `test_tui_detail_reading`, `test_tui_board_successor`, `test_tui_usage_scope` |
| `workspace-files` | TUI, server and the three test executables | `test_repo_git`, `test_tui_workspace_entries`, `test_workspace_file_confidentiality` |
| `rich-workspace` | TUI, server and the six test executables | The `workspace-files` suites plus `test_lsp_position`, `test_tui_music_launcher`, `test_tui_alphatex` |
| `rich-chat-workspace` | TUI, server and the seven test executables | The `rich-workspace` suites plus `test_tui_chat_call_reader` |
| `original-tool-result` | TUI, server and the four test executables | `test_keeper_tool_result_source`, `test_tool_output_washing_e2e`, `test_server_dashboard_http_keeper_tool_lookup`, `test_tui_chat_call_reader` |

The server target is `bin/main_eio.exe`; the TUI is `bin/masc_tui.exe`.
Each test target is `test/<suite>.exe`. Unknown scenarios are refused before
source checkout and again before selecting build targets. With no native source
SHA, only the existing source/config/credential checks run.

Use `rich-workspace` for a selected music and Code integration candidate. It
checks Unicode LSP positions, music child-process handoff and AlphaTex parsing
alongside file discovery and request ownership. It does not execute the Node
music package, play audio or establish visible terminal behavior; record those
checks separately against the same source commit.

Use `rich-chat-workspace` when the selected integration source also includes
chat original-call reading. It builds and runs `test_tui_chat_call_reader` in
addition to all six `rich-workspace` suites and packages the matching server.
The reader suite checks original execution selection, exact-response identity,
read ownership, retries, retained result/scroll state and terminal Enter intent;
it is not a visible-UI or actual Keeper tool-turn proof. A selected source
without that test target fails the build instead of falling back to the older
six-suite profile. For example:

```sh
gh workflow run pr-check.yml --repo jeong-sik/masc --ref WORKFLOW_REF \
  -f native-tui-source-sha=SOURCE_COMMIT_40_HEX \
  -f native-tui-scenario=rich-chat-workspace
```

Use `original-tool-result` for the retained original-result endpoint and its
TUI consumer. It checks exact execution/turn binding, owned trace reads and
mutation failures, byte paging and UTF8 reconstruction, the shared artifact
page bounds, actual HTTP Admin/workspace enforcement, and Reader ownership and
retained state. It packages the matching server and TUI for a separate actual
Keeper-result read. These four suites do not certify music/Code integration,
complete producer stdout capture, or visible UI behavior. The selected source
must contain all four targets; a missing target fails instead of reducing scope.

For a workspace file-finder candidate:

```sh
gh workflow run pr-check.yml --repo jeong-sik/masc --ref WORKFLOW_REF \
  -f native-tui-source-sha=SOURCE_COMMIT_40_HEX \
  -f native-tui-scenario=workspace-files
```

Replace both placeholders with the selected workflow ref and full feature
commit. Before the workflow changes reach main, select the reviewed CI branch
explicitly. Record the returned run identity. Continue independent work; do not
watch, wait for or repeatedly poll CI. At a real work boundary, read the actual
result. An accepted request or running job is not a passing result.

## Artifact and receipt

The artifact is named `tui-macos-arm64-<source SHA>-<run ID>`. It retains build
targets, logs, completed suite names, native dependency lists and `receipt.json`.
The TUI's embedded `--build-commit` must equal the selected source. The workspace
scenarios also check the server's `build-commit` and include it as `masc`, with
its own digest and dependency list. The receipt records source SHA, workflow
SHA, scenario and both binary digests; the existing TUI `sha256` field remains.
The default scenario records no server digest.

The workflow revision chooses the checks, while checkout and dependency setup
use the selected feature tree. Validate both identities before reusing the
artifact. A missing receipt, failed suite or partial artifact is not success.
These are native executables with the dynamic libraries listed in the artifact;
this is not a portable release package.

## Actual workspace behavior

Use a separate workspace, port and terminal. Keep the operator's server,
installation and drafts intact. Verify downloaded hashes and embedded commits,
then run the matching server and TUI against that same isolated workspace.
Do not pair a new TUI with an older server lacking its workspace endpoint and
call that a feature verdict.

For file discovery, observe Code Ctrl-P, filtering, selecting and opening a
file outside the current directory, and returning through Code history. Include
unavailable scopes and failed reads, checking that the original file and reading
state remain available. Record saved state, actual requests and manual terminal
captures separately from the build/suite receipt. Do not add screen wording,
layout, row-order or PTY assertion tests. The artifact receipt deliberately
leaves installed-runtime and visible-UI verification false.
