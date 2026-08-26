---
rfc: "the-boundary-is-a-mount"
title: "The boundary is a mount, not a list"
status: Draft
created: 2026-08-26
updated: 2026-08-26
author: vincent
supersedes: []
superseded_by: null
related: ["execute-subset-dispositions", "spawn-a-process-that-outlives-the-call"]
---

# The boundary is a mount, not a list

## 1. Problem

A keeper is told where it may work by `allowed_paths`, a list carried in its
runtime contract. The list is enforced for the file tools MASC mediates and is
not enforced for the shell. The shell is where the damage happens.

**1.0 Measured 2026-08-26: the operator's own repository was rewritten twice.**

`~/me` is the operator's Second Brain repository and the server's `base_path`.
Twice in one day it stopped being that repository:

```
12:02:53  origin/main = 8b7ca3c66b        me repo, PR #1266
13:09:02  fetch moved it to 8873487388    masc repo, PR #30785
13:09:05  checkout main -> task-382-fleet-readiness
```

After the second, `~/me` held masc's tree. `instructions/` was empty,
`memory/MEMORY.md` was gone, and `lib/keeper/keeper_agent_run.ml` was present.
The repository's `origin` and `upstream` both pointed at `masc.git`. Recovery
was `git checkout main` plus `git remote set-url`; nothing was lost because
`main` was already pushed, which was luck rather than design.

The first occurrence, that morning, was repaired by returning the tree and
leaving `origin` alone. That is why there was a second: the cause was never
the tree.

**1.1 Five links, each one checkable.**

```
1. default_sandbox_profile = Local          lib/config/keeper_sandbox_config.ml:26
     -> no container
2. "Positional argv is opaque application    lib/exec_policy/exec_policy.mli:43-47
    data and is never classified ...
    Runtime sandbox containment remains
    authoritative for the process itself"
     -> with no containment, nothing holds argv
3. cwd = base_path = ~/me                    11 sites, 4 keeper runtimes
     keeper_codex_runtime.ml:693,872
     keeper_claude_code_runtime.ml:487
     keeper_antigravity_runtime.ml:521
     keeper_capability_probe.ml:399,416,452,575,596
4. "Execute path arguments resolve           the runtime contract, told to the
    against cwd"                             keeper on every turn
5. the keeper runs git; it lands in ~/me/.git
```

Nothing in the chain is a bug. Each step is the documented behaviour of the
step above it.

**1.2 The keeper did not break a rule. It stood where the rules put it.**

The contract a keeper receives says both of these, in the same object:

```json
"sandbox_root":  ".../.masc/playground/<keeper>/",
"allowed_paths": [".masc/playground/<keeper>/"],
"execute_path_basis": "Execute path arguments resolve against cwd."
```

The first two say the playground. The third says paths resolve against the
working directory, and the working directory is `~/me`, which is not in the
list. A keeper doing masc work in `~/me` that runs
`git remote set-url origin .../masc.git` is issuing a correct command for the
repository it appears to be standing in.

**1.3 `allowed_paths` is half a boundary.**

It is enforced. `Keeper_sandbox_containment.check_read_target` resolves a
target against `effective_allowed_paths` and rejects, and it is wired:
`keeper_workspace_read_ops.ml:52` and
`keeper_tool_filesystem_runtime.ml:364`.

It is enforced for the tools MASC mediates. It is not enforced for `Execute`,
because `exec_policy` says so in as many words, and it hands that
responsibility to a containment that is off by default.

So the list is not a lie. It is a boundary with the shell cut out of it, and
the shell is the part that runs `git`.

**1.4 What the list costs.**

```
core modules                        1,214 lines
  keeper_alerting_path.ml               848
  keeper_alerting_path.mli              254
  keeper_path_check_error.ml             68
  keeper_path_rejection.ml               25
  keeper_sandbox_containment.ml          19

references across the tree        426 sites in 148 files
```

Normalisation, resolution, rejection vocabulary, an `effective_` layer, a
dashboard projection, a TUI pane, and a rejection-message contract -- all of
it to describe a set of directories.

**1.5 And the isolation is not paying for itself either.**

Per-keeper playgrounds were meant to keep keepers apart. Measured on this
workspace:

```
44 playgrounds, 65 clones
masc cloned 7 times, 109 GB
  taskmaster 27G  polisher 26G  rondo 22G  sangsu 12G
  code-reviewer 11G  lane-smith 10G  kidsnote 1.7G
```

There is no prune anywhere in the tree. The copies are not isolation; they are
seven checkouts of the same repository that nobody deletes.

## 2. What every comparable system does

The boundary is below the agent, not beside it.

| | enforced by | the agent sees |
|---|---|---|
| Claude Code | bubblewrap + seccomp (Linux), Seatbelt `sandbox-exec` (macOS) | writable: project + tmp; `.git` read-only even under a writable root |
| Hermes Agent | Docker / Singularity / Modal / Daytona / Vercel | caps dropped, no-new-privs, PID limit, noexec tmpfs |
| OpenClaw | Docker / Podman gateway | container per agent, per session, or shared |
| pi.dev Gondolin | QEMU micro-VM | host cwd mounted at `/workspace`; nothing else exists |
| pi.dev OpenShell | gateway (Docker/Podman/VM) or remote Kubernetes | remote gateway does not bind-mount the project at all |

Two things are worth taking directly.

**Claude Code protects `.git` inside a writable root.** Today's incident was
`~/me/.git` while `~/me` was legitimately writable. A writable working
directory does not imply a writable repository.

**pi.dev mounts the working directory and nothing else.** There is no allow
list in Gondolin because there is nothing to allow: the rest of the filesystem
is not in the VM. The list exists in MASC precisely because everything is
visible.

> "Containers, denylists, and permission prompts exist in the same space the
> agent reasons in: userspace, language, logic."
> -- *Your Container Is Not a Sandbox*, 2026

`allowed_paths` is text the keeper reads. Needing it is the evidence that
there is no wall under it.

## 3. Proposal

**3.1 The keeper's world is its playground, and it is mounted, not listed.**

- A keeper process starts in `.masc/playground/<keeper>/`, which
  `Playground_paths.bundle_root` already names and which already exists on
  disk for all 44 keepers.
- That directory is what the sandbox mounts. Nothing above it is in the
  namespace.
- `default_sandbox_profile` stops being `Local`.

**3.2 `.git` is read-only inside a writable root.**

A checkout the keeper is working in stays writable. Its `.git` does not.
`remote set-url`, `checkout`, `worktree add` and `reset` all need to write
there, and none of them is work MASC asks a keeper to do.

**3.3 `allowed_paths` is removed, and its absence is the default.**

Once the mount is the boundary, the list has nothing left to say. Deleting it
removes 1,214 lines of core modules and 426 references, and it removes the
category of bug where the list and the mount disagree.

**3.4 The cwd is a type, not a string.**

```ocaml
(* Where a keeper may stand. Built only from a playground bundle, so a spawn
   site cannot pass an arbitrary path -- the value that reaches the process
   is itself the proof that the policy held. *)
type keeper_cwd

val keeper_cwd : keeper_name:string -> base_path:string -> keeper_cwd
```

The eleven spawn sites take `keeper_cwd`. A site that wants `base_path` does
not compile. This is what stops the next runtime from re-introducing the
default, the way `masc_tui_frame` stopped the next caller from re-deriving
`cols - 4`.

## 4. Order matters, and the tempting order is wrong

Removing `allowed_paths` first is a regression. It is the only enforcement on
the read path today, and deleting it before the mount exists takes that away
while leaving the `Execute` hole exactly as it is. Today's incident came
through `Execute`; it would not have been prevented, and reads would have got
worse.

```
1. mount is the boundary        container/micro-VM default,
                                playground-only mount, .git read-only
2. keeper_cwd type              spawn sites cannot name base_path
3. allowed_paths removed        now genuinely redundant
```

Step 3 is only safe as a consequence of step 1. It is not a separate decision
that can be taken earlier.

## 5. What this does not solve

- **The 109 GB.** Isolation and sharing pull in opposite directions: a shared
  clone is smaller and a per-keeper clone is separate. Hermes exposes exactly
  this choice as `shared` / `session` / `agent` rather than deciding it. That
  is a second RFC.
- **Escape from the container itself.** The 2026 reading is that a shared
  kernel is not a sandbox for untrusted code, and OpenClaw shipped a bind-mount
  injection that reached `docker.sock`. Whatever mount specification this RFC
  produces has to be built from typed values, not concatenated from config.
- **What a keeper legitimately needs outside its playground.** Some keepers
  read `instructions/` and workspace state today. Every such use has to be
  named and given a mount, or moved. This is the migration's real cost and it
  is not yet counted.

## 6. Evidence

| claim | how it was checked |
|---|---|
| `~/me` rewritten twice | `.git/logs/refs/remotes/origin/main`, `git reflog --date=iso` |
| default profile is `Local` | `keeper_sandbox_config.ml:26` |
| argv is not classified | `exec_policy.mli:43-47` |
| cwd is `base_path` | `rg 'cwd = base_path\|~cwd:.*base_path'`, 11 sites |
| the contract says both | `.masc/trajectories/rw-e0-r3-20260818-research/trace-*.jsonl` |
| `allowed_paths` is enforced for reads | `keeper_sandbox_containment.ml`, callers at `keeper_workspace_read_ops.ml:52`, `keeper_tool_filesystem_runtime.ml:364` |
| 1,214 lines / 426 sites | `wc -l`, `rg -c` |
| 109 GB in 7 clones | `du -sh` over `find -name .git` under `.masc/playground` |
| container already mounts only playground | `Dockerfile.keeper-sandbox:80-84`, `keeper_sandbox_runtime_setup.ml:368` |

## 7. Sources

- Claude Code containment: <https://simonwillison.net/2026/May/30/how-we-contain-claude/>
- Claude Code / Codex sandbox internals: <https://medium.com/@Koukyosyumei/how-claude-code-and-codex-sandbox-untrusted-code-ba39b493046a>
- Hermes Agent security: <https://hermes-agent.nousresearch.com/docs/user-guide/security>
- OpenClaw sandbox CLI: <https://docs.openclaw.ai/cli/sandbox>
- OpenClaw security analysis: <https://arxiv.org/pdf/2603.27517>
- pi.dev containerization: <https://pi.dev/docs/latest/containerization>
- Your Container Is Not a Sandbox: <https://emirb.github.io/blog/microvm-2026/>
