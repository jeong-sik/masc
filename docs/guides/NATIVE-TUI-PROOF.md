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
| `code-references` | TUI, server and the five test executables | `test_lsp_workspace_pool`, `test_lsp_questions`, `test_lsp_message_router`, `test_lsp_process_manager`, `test_server_ide_lsp_proxy` |
| `resource-reading` | TUI, server and the four test executables | `test_tui_published_reports`, `test_tui_resource_document_search`, `test_tui_resource_image_admission`, `test_tui_resource_images` |
| `addon-lifecycle` | TUI, server and the two test executables | `test_tui_lane_addons`, `test_lane_addon_application` |
| `source-readers` | TUI, server and the seven test executables | The four `original-tool-result` suites plus `test_tui_workspace_entries`, `test_tui_keys`, `test_tui_palette_matching` |
| `code-drafts` | TUI, server and the five test executables | `test_tui_code_draft`, `test_tui_workspace_entries`, `test_workspace_file_confidentiality`, `test_tui_keys`, `test_tui_palette_matching` |

The server target is `bin/main_eio.exe`; the TUI is `bin/masc_tui.exe`.
Every scenario also builds `bin/masc_tui_keys_doc_cli.exe`, the canonical key
reference generator, from the selected source. This adds no test suite.
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

Use `source-readers` when a selected candidate changes both retained original
tool-result reading and Code's captured file source. It runs the existing four
original-result suites and the three direct Code document consumers in one
native build. The workspace entries suite exercises source-byte preservation,
copy ownership and file navigation; the keys and palette suites exercise the
same document's search and symbol consumers. This includes the existing Reader
fixture compile checks without dispatching a second native build. It packages
the matching server/TUI and records all seven completed suite names in the
same receipt. It does not run the five LSP suites, real Pyright, music playback
or visible terminal/clipboard verification. A selected source lacking any
target fails instead of omitting that suite.

```sh
gh workflow run pr-check.yml --repo jeong-sik/masc --ref WORKFLOW_REF \
  -f native-tui-source-sha=SOURCE_COMMIT_40_HEX \
  -f native-tui-scenario=source-readers
```

Use `code-drafts` for a selected revision-bound Code editor/save candidate.
The draft suite checks exact candidate bytes, submitted-save ownership,
conflict and uncertain-write reconciliation, and the external editor's actual
temporary file and terminal handoff. The workspace entries suite checks paired
source/revision decoding, comparison-read ownership and deferred post-save
refresh. The confidentiality suite checks the server's save authorization,
workspace identity, revision conflicts and file confinement. The keys and
palette suites compile and exercise direct consumers of the revised document
payload. It packages the matching server/TUI for separate actual editor/save
verification. These five suites do not establish visible terminal behavior,
real editor usability, or successful deployment. All five targets must exist
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

Use `resource-reading` for a Resources report, body-search or image candidate.
The four suites check exact report revision requests and read ownership,
withdrawal and refusal, admitted original document search, logical search
position after scroll clamping, original multipart image admission and source
conservation. They check requests, stored state and decisions; they do not
assert screen wording, layout or row order. The matching server and TUI are
packaged for separate API and terminal observations. These suites do not
exercise the actual search keyboard loop, present images in a terminal or
establish a live report publication. All four targets must exist in the selected
source; a missing target fails rather than reducing the scope.

```sh
gh workflow run pr-check.yml --repo jeong-sik/masc --ref WORKFLOW_REF \
  -f native-tui-source-sha=SOURCE_COMMIT_40_HEX \
  -f native-tui-scenario=resource-reading
```

Use `addon-lifecycle` for an Addon installation/worker observation candidate.
The two existing suites cover TUI request/state ownership and host application
decisions. The selected TUI suite also contains existing presentation assertions;
this scenario adds no new screen wording, layout or row-order tests, and does not
classify that mixed suite as request/state-only proof. The matching server and
TUI are packaged for separate actual On/Off/reconnect observations. Passing these
suites does not prove that a container, real model or visible terminal executed.
Both selected targets must exist; a missing target fails instead of reducing scope.

```sh
gh workflow run pr-check.yml --repo jeong-sik/masc --ref WORKFLOW_REF \
  -f native-tui-source-sha=SOURCE_COMMIT_40_HEX \
  -f native-tui-scenario=addon-lifecycle
```

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
The TUI's embedded `--build-commit` must equal the selected source. The server-bearing
scenarios also check the server's `build-commit` and include it as `masc`, with
its own digest and dependency list. The receipt records source SHA, workflow
SHA, scenario and both binary digests; the existing TUI `sha256` field remains.
The default scenario records no server digest.

`key-reference.md` contains the key reference produced by that source's actual
generator. The receipt's `key_reference` records its artifact path, SHA-256 and
producer target; the surrounding source/workflow identities also apply to it.
Generation must succeed before a final receipt is written. A selected source
without the generator target fails instead of substituting another document.
This output can be used to update `docs/guides/TUI-KEYS.md` after checking the
source identity and digest. It does not establish visible key handling or compare
screen wording, layout or row order.

Every selected suite runs once even if an earlier suite fails. The workflow
retains each suite and log pipeline exit code in `test-results.tsv` and the
receipt. `executed_tests` includes completed failed suites as well as passing
ones; `behavior_passed` requires the complete selected list in order and zero
suite/log exit codes. A failed suite still fails the job.

After a successful build, exact-commit binary packaging also runs when a suite
fails, so the artifact can support further diagnosis without rebuilding. A
failed behavior receipt does not certify those binaries for installation or
turn the failed job into a passing check. Cancellation does not start packaging.

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
