---
rfc: "0255"
title: "Withdraw inferred argv path policy"
status: Withdrawn
created: 2026-06-18
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0208", "0254"]
implementation_prs: []
---

# RFC-0255: Withdraw inferred argv path policy

## Decision

The original proposal is withdrawn. MASC does not classify positional command
arguments as filesystem paths from executable names, flag strings, or token
shapes.

The current execution contract is deliberately smaller:

1. Shell IR treats positional argv as opaque application data.
2. `Exec_policy.validate_shell_ir_paths` validates only explicit typed `cwd`
   and file-redirect targets.
3. The selected runtime sandbox owns process-level filesystem containment.
4. Actual spawn, sandbox, permission, and exit failures remain explicit and
   observable.
5. Product authorization or HITL belongs to the outer Keeper Gate, not to the
   backend-neutral Shell IR parser.

This removes a static unconditional-block descendant rather than replacing it
with a more elaborate typed version of the same guess.

## Why the original design was rejected

The old implementation inferred paths using a hand-maintained command corpus
and string rules. It then needed command-specific exceptions for values such
as Git revisions and GitHub API endpoints. This caused ordinary exploration
and tool use to fail before a process reached its real execution boundary.

The original RFC proposed moving that classification into typed descriptors.
That would make the result exhaustively represented, but it would not make the
underlying judgment objective. A closed sum of guessed command semantics is
still a heuristic, and every new command or flag expands a MASC-owned catalog
of another product's argv rules.

That cost is especially inappropriate at this layer:

- an argument containing `/` is not necessarily a path;
- a path argument is not necessarily a request for authority;
- read/write meaning cannot be derived reliably from a binary basename;
- provider, repository-hosting, and CLI-specific knowledge would leak into the
  generic execution substrate;
- false positives stop valid Keeper work before the actual sandbox can decide.

## Removed surfaces

The withdrawal removes the following active surfaces and their policy tests:

- the execution-policy path-argument descriptor module;
- token-shape path detection and path-prefix classification;
- per-command argument and flag parsing for `git`, `gh`, `rg`, `grep`, `sed`,
  and related commands;
- Git revision and repository-hosting endpoint exemptions;
- Shell-command-gate literal argv `path_policy` callbacks;
- the `.masc` / `backlog.json` string-matching command gate;
- the Shell-command-gate argv path rejection verdict.

## Boundaries that remain

| Boundary | Current authority |
|---|---|
| Command syntax | Typed Shell IR parser and syntax policy |
| Explicit working directory | `Path_scope` plus `Exec_policy` containment |
| Explicit redirect target | `Redirect_scope` plus `Exec_policy` containment |
| Process filesystem access | Selected runtime sandbox |
| Product authorization / HITL | Outer Keeper Gate |
| Runtime failure | Spawn/sandbox/OS result, surfaced without fallback |

If a deployment requires stronger process containment, it must select a real
sandbox or a capability-owned tool implementation. Reintroducing an argv
string classifier is not an acceptable substitute for containment.

## Verification contract

Focused tests pin both sides of the boundary:

- an absolute or traversal-looking positional argv value is admitted by the
  structural command gate and ignored by `validate_shell_ir_paths`;
- an explicit `cwd` outside the workdir is rejected;
- an explicit redirect target outside the workdir is rejected;
- existing sandbox containment tests remain authoritative for runtime access.

Repository audit must report zero active-code hits for the retired descriptor,
argv path inference, command-specific exemptions, and Shell-gate path-policy
surface.

## Historical context

The original audit measured repeated `path_reject` failures during routine
Keeper exploration. Those observations remain useful evidence for why the
classifier was removed. They are not a reason to preserve or reimplement the
old policy hierarchy.
