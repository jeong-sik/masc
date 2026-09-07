# Contributing to MASC

MASC is a harness for running several coding agents against one repository:
a workspace server over MCP, supervised Keepers, and a terminal UI, in one
OCaml binary. This document is about changing this codebase, not about
justifying its design.

Coding agents that work on MASC read [`AGENTS.md`](AGENTS.md) and
`docs/constitution.xml` first. For them the constitution's execution protocol
replaces the local-build and CI-wait advice below.

## Quick start

```bash
git clone https://github.com/jeong-sik/masc.git
cd masc
git config core.hooksPath .githooks       # pre-commit and pre-push guards

scripts/opam-pin-external-deps.sh         # pin external OCaml dependencies
opam install . --deps-only

scripts/dune-local.sh build @default      # build
scripts/dune-local.sh exec test/test_keeper_meta_json_config_toml_only.exe
./start-masc.sh --http                    # server from the checkout
```

`scripts/dune-local.sh` wraps Dune for a machine where several agents build at
once: it serializes Dune inside one worktree, defaults concurrency to
`DUNE_JOBS` or 2, injects `--root`, and refuses a toolchain that does not
match `dune-project`. `MASC_DUNE_DRY_RUN=1` prints the command instead of
running it.

The hooks: `pre-commit` skips the `dune build` type-check for a commit that
only touches docs and assets; `pre-push` refuses a push that adds Dune trace
dumps, because those carry the environment.

## Where things are

```text
bin/
├── main_eio.ml                  server, CLI subcommands, and the hand-over to the TUI
├── main_stdio_eio.ml            stdio MCP entry point
├── masc_tui.ml                  TUI entry point; masc_tui_*.ml are its modules (about 120 files)
├── masc_exec_shim.ml            the shim a remote_ssh endpoint runs
└── ...                          SSH bootstrap, browser host, cost and trace tools, probes

lib/                             about 180 top-level modules and 147 directories, among them
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
test/                            Alcotest suites (about 1,200 files) and fixtures
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

CI runs `ocamlformat` on the `.ml` and `.mli` files a pull request changes.
Either command matches it:

```bash
opam exec -- dune build --root . @fmt --auto-promote   # whole tree
opam exec -- ocamlformat -i <changed .ml/.mli files>   # just what you touched
```

`dune-project` scopes formatting to OCaml, so `dune fmt` leaves `dune` files
alone.

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

On every pull request (`pr-check.yml`):

- **lint**: about 40 scripts through `scripts/ci/run-lint-suite.sh
  blocking-pr`, run to completion so every failure is listed at once. An
  advisory set follows and is recorded, not enforced.
- **check**: source text integrity, the RFC index,
  `scripts/check-doc-truth.sh`, release and namespace fixtures,
  `dune build @check`, then the tests the pull request edits
  (`scripts/ci/run-edited-tests.sh`) and the suites that need no build.
- **dashboard-types**: type-checks the SPA.

The full test suite is `test.yml`, on a daily schedule and on dispatch, not
per pull request. `release.yml` runs on a tag push and builds the published
binaries. `ci.yml` is a dispatchable build.

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

1. Branch from `main` as `feat/<topic>`, `fix/<topic>`, or `docs/<topic>`.
2. Write tests for new behaviour.
3. Run the focused checks for what you changed through
   `scripts/dune-local.sh`. CI owns the full-suite result.
4. Open a **draft** pull request linked to at least one issue. The template
   asks for `Summary`, `Product impact`, `Evidence`, `Direct evidence`,
   `Review evidence`, and `Linked issue`. Fill them, and leave the two
   checklists unchecked with a reason when they do not apply.
5. `Product impact` names the surface: the TUI, the MCP workspace, the Keeper
   runtime, the dashboard, or none/internal.
6. `Review evidence` records a cross-model review when the repo or a reviewer
   asks for one: which model reviewed, and why a fallback was used if one was.
7. Pull requests are squash-merged. Never push to a branch whose pull request
   has merged; open a new one.
8. When the work is ready to verify, hand it over with typed evidence. Every
   `evidence_refs` entry is `artifact:<producer-root-relative-path>` (a file
   the reviewer opens and snapshots) or `note:<text>` (prose the reviewer
   reads but cannot inspect); see RFC-0417. A PR URL, a commit, or a board
   post id inside a `note:` is narrative until something opens it — pair it
   with an `artifact:` entry, and never let a `note:` stand alone as
   completion evidence.

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
- Run `bash scripts/check-version-truth.sh` and `bash scripts/check-doc-truth.sh`
  before a release review; the tag workflow runs the former and CI runs the
  latter. `check-release-train-guard.sh` is not wired into CI yet
  (`scripts/ci/guards-not-wired.txt`).
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
- Nothing outside the binary is required to build, boot, or run a Keeper
  turn. Graph and vector integrations exist for specific workflows only.

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
