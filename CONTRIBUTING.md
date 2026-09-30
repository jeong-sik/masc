<p align="center">
  <img src="docs/assets/candle.svg" width="88" alt="MASC Keeper">
</p>

# Contributing to MASC

[First contribution](docs/guides/CONTRIBUTOR-WORKFLOW.md#1-make-a-first-contribution) · [AI sessions](docs/guides/CONTRIBUTOR-WORKFLOW.md#2-start-an-ai-development-session) · [Source map](#where-things-are) · [한국어 안내](docs/guides/CONTRIBUTOR-WORKFLOW.ko.md)

Start here when changing MASC. You can contribute documentation without an
OCaml toolchain, report a reproducible problem, or change a feature with evidence.

The [repository strategy and contributor workflow](docs/guides/CONTRIBUTOR-WORKFLOW.md)
([한국어](docs/guides/CONTRIBUTOR-WORKFLOW.ko.md)) covers first contributions, AI
sessions, Issue/Goal/Task/Board coordination, CI, review and handoff. Outside
contributors can use a fork and public GitHub issues/PRs; private MASC access is
not required to contribute.

| Who is doing the work? | Start and validation path |
|---|---|
| Human contributor | Read the workflow, choose an issue, use a separate branch/worktree; local focused checks are available below |
| External AI coding session | Read [AGENTS.md](AGENTS.md) and the full [constitution](docs/constitution.xml) first; no local Dune builds or CI wait loops |
| Keeper development lane | Read the task contract and lane instructions; distinguish local observations, independent source review and full Release/Tag CI |

> [!NOTE]
> `execution_protocol` in the constitution owns coding-agent workflow where it
> overrides the local-build guidance here. Keeper runtime prompts are separate.

## Choose a contribution

Start with a reproducible behavior gap, an incorrect instruction or a useful
example. [The reliable-change roadmap](docs/RELIABLE-CHANGE-ROADMAP.md) describes
current improvement goals; it is not a promise that every proposed feature fits.

| What you found | Next step |
|---|---|
| Bug | Search issues and all PR states, reproduce on current source, then open/link an issue with expected and observed behavior |
| Documentation gap | Identify the incorrect instruction and its source; a small docs PR is a useful first contribution |
| New capability or architecture | Explain the user scenario and discuss the proposal in an issue before broad implementation |
| Setup question | Use an inquiry issue with platform, version and redacted error output; do not assume it is a defect |

See the workflow's [first contribution](docs/guides/CONTRIBUTOR-WORKFLOW.md#1-make-a-first-contribution)
for fork setup and its [source map](docs/guides/CONTRIBUTOR-WORKFLOW.md#find-the-source-before-editing)
for where to start reading. Use the issue taxonomy below when filing an issue.
AI-assisted contributions are welcome; the author is responsible for understanding
the result and distinguishing actual checks from generated claims.

## Local development for human contributors

Install the [source prerequisites](README.md#from-source) first.

```bash
git clone https://github.com/jeong-sik/masc.git
cd masc
git config core.hooksPath .githooks       # pre-commit and pre-push guards

opam init --bare                         # initialize a fresh opam installation
opam switch create . ocaml-base-compiler.5.5.1 --no-install
eval "$(opam env)"
scripts/opam-pin-external-deps.sh         # pin external OCaml dependencies
opam install ./masc.opam --deps-only --locked --with-test

scripts/dune-local.sh build @default      # build
scripts/dune-local.sh exec test/test_keeper_meta_json_config_toml_only.exe
mkdir -p "$HOME/masc-dev"
env -u MASC_CONFIG_DIR scripts/run-local.sh --target-dir "$HOME/masc-dev" --port 9234
```

Use an unused port in the launch command; `9234` is an example. The local launcher
clears an inherited `MASC_CONFIG_DIR` for this command so config resolves under
the separate target directory. It does not seed checked-in Keeper manifests by
default; existing configuration in the target directory still applies. Browser access additionally needs the
dashboard build described in README.

`scripts/dune-local.sh` wraps Dune for a machine where several agents build at
once: it serializes Dune inside one worktree, defaults concurrency to
`DUNE_JOBS` or 2, injects `--root`, and refuses a toolchain that does not
match `dune-project`. `MASC_DUNE_DRY_RUN=1` prints the command instead of
running it.

The hooks: `pre-commit` skips the `dune build` type-check for a commit that
only touches docs and assets; `pre-push` refuses a push that adds Dune trace
dumps, because those carry the environment. Code commits invoke a local Dune
build through pre-commit. External AI sessions must use the
[commit boundary procedure](docs/guides/CONTRIBUTOR-WORKFLOW.md#2-start-an-ai-development-session)
when these hooks are active.

## Where things are

```text
bin/
├── main_eio.ml                  server, CLI subcommands, and the hand-over to the TUI
├── main_stdio_eio.ml            stdio MCP entry point
├── masc_tui.ml                  TUI entry point; masc_tui_*.ml are its modules
├── masc_exec_shim.ml            the shim a remote_ssh endpoint runs
└── ...                          SSH bootstrap, browser host, cost and trace tools, probes

lib/                             subsystem modules and libraries
├── keeper/                      Keeper runtime, turn loop, tools, chat channels
├── server/                      HTTP routes, MCP transport, sidecars, gateways
├── workspace/                   tasks, claims, goals, board, verification
├── runtime/, runtime_model/     provider catalog, lanes, assignments
├── gate/, keeper_approval/      approval lanes and the Gate queue
├── exec/, exec_ssh_protocol/, egress_proxy/   sandboxes, the SSH lane, egress policy
├── dashboard/                   read models the SPA consumes
├── lsp_client/                  the language-server client behind the Code view
└── tui_decode.ml                server payload decoding shared with the TUI

packages/                        embedded Agent Core
dashboard/                       TypeScript + Preact SPA
config/                          seeds embedded into the binary: runtime.toml, prompts, tools/*.toml
docs/                            manuals, runbooks, docs/spec, docs/rfc
scripts/                         build, install, local operations; scripts/ci/ holds the lint suite
test/                            Alcotest suites, PTY scenarios and fixtures
```

## Code style

- OCaml 5.x with Eio, direct style. No `Unix.sleepf` and no Lwt; use
  `Eio.Time.sleep`.
- Typed variants and records for runtime contracts. No `Obj.magic`.
- `Result.t` over exceptions for recoverable errors.
- `Eio.Switch.on_release` over nested `Fun.protect` for cleanup.
- Pure functions extracted from IO when that keeps the change simpler.
- No string or substring matching to decide control flow, and no numeric
  budgets or weights as Keeper control gates. `docs/constitution.xml` lists
  the rest.

No CI job runs `ocamlformat`. `.ocamlformat` sets `disable = true` repo-wide
until a migration RFC decides on a reformat (RFC-0010), so `dune fmt` is a
no-op for OCaml today; match the style of the code around your change.

## Tests

Tests are Alcotest suites under `test/`, registered through `test/dune` and
`test/stanzas/*.inc`. Pure functions are tested without mocks. IO paths run
against integration harnesses when the service they need is configured.

```bash
scripts/dune-local.sh exec test/<test-name>.exe   # one suite
scripts/dune-local.sh build @default              # build only
make check-memory-leak                            # Valgrind over server start, initialize, tools/list
```

`make check-memory-leak` needs `dune`, `curl`, `python3`, and `valgrind`, and
fails on definite, indirect, or possible leaks.
`bash scripts/check-memory-leak.sh --skip-build --keep-artifacts` reuses a
built binary.

## What CI runs

CI is manual and review comes first. Ordinary stacked PRs use independent
function, logic and code-cleanliness reviews; approve when no P0/P1/P2 issue
remains and collect P3 issues for later. There is no PR/push/nightly CI.

`pr-check.yml` provides explicit syntax/configuration/credential checks in a
two-minute job. `ci.yml` builds only Core for the bottom of a stack, also
within two minutes. At `release/vX.Y.Z`, `release-candidate.yml` runs the full
compile, typecheck, behavior and installation cycle. Tag publication waits
for full checks and tests. See [the workflow](docs/CI-REVIEW-WORKFLOW.md).

## Commits

Conventional commits, in English:

```
feat(tui): show the sandbox image a keeper resolved
fix(keeper): keep a rejected max_tokens response out of the checkpoint
refactor(server): move sidecar routes behind one table
test(gate): pin the external-services lane default
docs: describe the TUI as the front door
chore: bump version to 0.34.0
```

## Pull requests

1. Create a stack: the bottom PR targets `main`; each later PR targets the
   preceding stack branch.
2. Review the changed feature against its contract and concrete risks. Check
   documentation claims and links against source; add behavior tests where useful.
3. Review from independent perspectives. Request only minimal manual checks
   before release; do not wait or poll for CI. Full verification belongs to
   the Release/Tag boundary.
4. Open a **draft** pull request linked to at least one issue. The template
   asks for `Summary`, `Product impact`, `Evidence`, `Direct evidence`,
   `Review evidence`, and `Linked issue`. Fill them, and leave the two
   checklists unchecked with a reason when they do not apply.
5. `Product impact` names the surface: the TUI, the MCP workspace, the Keeper
   runtime, the dashboard, or none/internal.
6. `Review evidence` records a cross-model review when the repo or a reviewer
   asks for one: which model reviewed, and why a fallback was used if one was.
7. A changelog entry goes in `changelog.d/<PR number>.md`, not in
   `CHANGELOG.md`: `### Added`, `### Changed`, `### Fixed`, `### Removed` (or
   another heading `changelog.d/README.md` lists), then English bullets that
   each cite the pull request as `#<number>`. Two pull requests never write
   the same file, so one merge does not make the others conflict. The release
   bump folds the fragments into `CHANGELOG.md`. Entries already under
   `## [Unreleased]` stay where they are.
8. Follow the [review and integration procedure](docs/guides/CONTRIBUTOR-WORKFLOW.md#5-review-and-integrate).
   Ordinary stacks use current-head independent source review; Release/Tag PRs
   additionally require full CI. Never push to a merged PR branch.
9. For work tracked by a MASC Task, submit typed evidence when ready to verify.
   `artifact:<producer-root-relative-path>` snapshots a bounded file at
   submission; `note:<text>` carries narrative evidence. The current tool
   schema also supports frozen `board:` and `fusion:` references. Public URLs in notes can be fetched by the verifier, but prose
   alone is not a file snapshot. Save volatile evidence as an artifact. Submission
   moves the task to awaiting_verification; completion requires the authority's verdict.

## Review decisions and integration

Review function, logic and code cleanliness on the current head. Approve when
no P0, P1 or P2 issue remains; collect P3 findings for later. An author or a
session that pushed the PR cannot independently approve it. State actual evidence
and unverified behavior separately.

The ordinary source-review verdict uses actual values:

```text
verdict: PASS|FAIL head: <40-character-current-SHA> by: <Keeper-name>
```

`APPROVE` goes through `scripts/review/approve-guard.sh`; its `--check` mode
checks review eligibility.

Capture the base SHA and complete diff identity **before source review** and
keep them with the reviewed head and evidence. Run these commands from the repository
checkout with authenticated `gh`, Git, Python 3 and `jq` available. The diff helper
fetches missing exact objects using `gh` credentials without interactive prompts.

```bash
# Set repo and pr to the pull request being reviewed.
snapshot=$(gh api "repos/$repo/pulls/$pr")
head=$(printf '%s' "$snapshot" | jq -r '.head.sha')
review_base=$(printf '%s' "$snapshot" | jq -r '.base.sha')
review_diff=$(python3 scripts/review/review-diff.py \
  --repo "$repo" --base "$review_base" --head "$head")
# Read the complete diff and its source context, then write review-body.md.
scripts/review/approve-guard.sh --repo "$repo" --pr "$pr" --head "$head" \
  --review-base "$review_base" --review-diff "$review_diff" --body review-body.md
```

Publishing requires `--body`, `--review-base` and `--review-diff`. The guard rejects
scope changes during admission. If the change differs, review it again and capture
new evidence; do not refresh the digest merely to approve unreviewed changes.
Release verdicts additionally cite `run: <full-CI-run-id>` for completed full
verification of that head. Read current reviews and comments before integration;
blocking reviews and later FAIL/HOLD decisions take precedence. Land stacks bottom
first and re-review changes to base and head. See [the workflow](docs/CI-REVIEW-WORKFLOW.md)
for admission through the review and merge scripts. A source approval does not
claim that a build or runtime check ran.

## Issues

Issue classification comes from a `masc-triage` block in the issue body, and
nothing else. Labels are a projection of that block, applied by the
`Issue Taxonomy` workflow. The vocabulary is `.github/issue-taxonomy.json`; a
value that is not in that file does not exist.

````text
```masc-triage
kind: defect
area: turn
impact: breaks-continuity
root: silent
must-do: true
```
````

Axes:

- `kind` (required, exactly one): `defect` implementation breaks its contract,
  `gap` the contract or wiring is absent, `capability` a new surface,
  `erosion` dead code or stale artifacts to delete, `inquiry` not yet known to
  be a defect.
- `area` (required, exactly one): `turn` `continuity` `collab` `goal-task`
  `verification` `tools` `runtime` `transport` `dashboard` `connector`
  `observability` `persistence` `ci`.
- `impact` (required, exactly one), and this order is the priority order:
  `breaks-continuity` turns stop or memory does not carry across them,
  `breaks-collab` keepers stop reaching each other or output lands where
  nobody reads it, `blinds-operator` it runs but nobody can see it,
  `degrades` friction, performance, or accuracy, `internal` development flow
  only.
- `root` (optional, zero or more): `ssot` `silent` `string` `variant`
  `boundary` `telemetry` `det` `ndt`.
- `must-do` (optional): `true` when this breaks the product promise right now.

Pick `impact` from what the issue breaks in the product, not from how severe
the issue claims to be. The product fails when turns stop, when a keeper
cannot recall its own last ten turns, when keepers stop talking to each
other, or when output lands somewhere nobody reads.

`gh issue create` uses the same block, so the web form and the CLI produce one
shape and one parser. Do not edit labels by hand; edit the block and the
workflow reconciles them. `APPLY=1 bash scripts/sync-issue-labels.sh`
reconciles repository labels with the vocabulary file.

When reporting a bug, include the OCaml version, the OS and version, steps to
reproduce, expected versus actual behaviour, and the relevant log
(`start-masc.sh` output or the harness output).

## Releases

- The active line is pre-1.0: `0.y.0` opens a user-visible train, `0.y.z`
  stabilizes it.
- `v2.*` tags are history and do not define the active line.
- After a train bump lands on `main`, publish its tag before opening the next
  one: after merging `0.33.0`, tag `v0.33.0` before opening `0.34.0`.
- Run `bash scripts/check-version-truth.sh` before a release review and request
  the full Release/Tag verification described in the CI workflow.
- `scripts/bump-version.sh` runs `python3 scripts/changelog-fragments.py
  assemble`, which folds `changelog.d/*.md` into `## [Unreleased]` and
  deletes them; move those entries into the version section before tagging.
- Release evidence follows [`docs/RELEASE-EVIDENCE.md`](docs/RELEASE-EVIDENCE.md).

## Architecture notes

### OCaml 5.x and Eio

OCaml with Eio is the current stack, not a general recommendation. It is used
because it has worked for this project and most runtime code already has that
shape.

- `Switch.run` scopes fiber lifetime; release resources when the switch exits.
- Compile-time checks catch record and variant drift before runtime.
- The server builds as a native binary.
- Eio is direct style; do not introduce Lwt-style control flow.

### State storage

- Runtime state is filesystem-first under `<base-path>/.masc/`.
- State files are JSON or JSONL where practical, so an operator can read them.
- A binary install does not need the OCaml toolchain. Keeper turns still need
  their model access and sandbox prerequisites. Graph and vector integrations
  exist for specific workflows.
- A change that stops reading a state file's existing rows is a hard cut. The
  code does not read or convert the old shape. The pull request's changelog
  fragment has a `### Fresh state required` entry that names the file and says
  whether to delete or rewrite it, and the load error names the file path.

### Runtime assignment

- Runtime order is controlled by `runtime.toml` at the resolved config root.
- A missing or invalid `runtime.toml` is a configuration error. There is no
  fallback file.
- Keeper TOML does not own model or provider selection. Keeper-specific
  routing lives in `runtime.toml` under `[runtime.assignments]`, keyed by
  keeper name; unassigned keepers use `[runtime].default`.
- Catalog changes in `runtime.toml` apply on the next runtime resolve.

### Runtime lens boundary

The Runtime Lens redacts provider and model identity at external surfaces:
metric labels, the dashboard agent-core bridge, provider error envelopes, and
the redacted variants of keeper metrics. It must not redact internal
observability: the boot log, the audit log, and operator-facing `Log.*.info`.

Before adding a `*_to_yojson` function or a metric emitter that touches
provider or model identity, answer three questions: who reads this surface, is
there a `redacted_*` companion, and do sibling fields agree. A new internal
serializer comes with a test that pins the un-redacted shape.

## License

By contributing, you agree that your contributions are licensed under the MIT
License.
