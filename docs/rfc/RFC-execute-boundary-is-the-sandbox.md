---
rfc: "execute-boundary-is-the-sandbox"
title: "The subset judges; the sandbox contains"
status: Draft
created: 2026-08-31
updated: 2026-08-31
author: vincent
supersedes: []
superseded_by: null
related: ["execute-subset-dispositions", "0394", "0091"]
---

# The subset judges; the sandbox contains

## 1. What this asks to reopen

`RFC-execute-subset-dispositions` §4 rejected two things:

> **Drop the subset and gate only at the OS boundary,** as Codex and pi.dev do.
> Same objection: their model resolves the residue with a human prompt, which
> unattended keepers do not have.

> **Escalate refusals to an approving keeper.** [...] A keeper waiting on
> another keeper's approval is a delegation contract with a response
> obligation, forbidden by `instructions/projects.md`.

Both were right when written, on 2026-08-24. The second still is, and this RFC
does not propose it. The first rested on a fact about the fleet that stopped
being true four days later.

## 2. What changed under it

| date | |
|---|---|
| 2026-08-24 | `RFC-execute-subset-dispositions` written. Profiles available: `Local`, `Docker`, `Remote_ssh`. |
| 2026-08-28 | `Micro_vm` lands (#31253) — one guest kernel per keeper through Apple's `container` CLI, network `none` by default. |
| 2026-08-30 | Three keepers move to it. |
| 2026-08-31 | `Local` is removed (#32078). A keeper declares `docker`, `microvm`, or `remote_ssh`, or it is refused at config load. |

The live fleet, 2026-08-31: `remote_ssh` 5, `microvm` 3, `docker` 1, host 0.

§4's objection was that the industry answer needs a human at the end. What the
survey below actually found is that the human is the *fallback for the
sandbox-less case*, not the mechanism. Codex's
`render_decision_for_unmatched_command` returns **Allow** for a
not-known-dangerous command when a sandbox is present, and prompts only when
there is none. Claude Code states the same trade openly: `autoAllowBashIfSandboxed`
means a sandboxed command runs without a prompt unless a rule says otherwise.

So the question §4 answered was "who says yes when the parser cannot?" and the
answer the surveyed products give is "nobody — the boundary already did."

## 3. What is actually costing us

`tools/costume_census` over `<base-path>/.masc/tool_calls/2026-08/*.jsonl`,
31 days, run 2026-08-31 with the counter corrected in #32075:

```
execute=45381  argv_form=43821  costumes=6815  lowered=5680
```

So §3.7 step 4 already takes 83% of the shell costumes under the gate. The
remaining **1,135** run as opaque `argv:["bash";"-c";S]` — no `Path_scope`, no
redirect policy, no connector rules — because the subset cannot represent what
is inside:

```
   656  param_expansion       36  subshell
   128  cmd_subst             28  glob_brace
    89  parse_error            4  proc_subst
    76  heredoc                3  background
   115  representable, held back by a guard
```

They are not refused. They run. The gate simply does not see them, and
`escaped_shell` tells the caller afterwards what it should have written.

Refusing them instead would break work that runs today — §3.7 says so and is
right. That leaves the third option §4 did not have available: **run them
inside the boundary the keeper already has.**

## 4. Proposal

One rule, stated per profile:

| profile | a script outside the subset |
|---|---|
| `Micro_vm` | delegate to a real shell in the guest |
| `Docker` | delegate to a real shell in the container |
| `Remote_ssh` | **open — see §6** |

Delegation means what every surveyed product does: hand the original text to
`sh -c` on the far side of the boundary, and let the boundary be the boundary.

What does **not** change:

- The subset still runs for everything it can represent. It is not a fallback
  path; it is the first one, and it is what gives a representable script path
  scope and redirect policy. This RFC does not propose deleting it, and §4's
  "drop the subset" is not what is asked here.
- `Keeper_gate.decide` still runs on every Execute call, before any of this.
  Delegation is about what the shell may contain, not about who authorized the
  call.
- No approval keeper. No human prompt. Nothing waits on anything. §4's second
  rejection stands untouched.
- `escaped_shell` advice keeps riding back, because a caller that learns to
  write the typed form still gets path scope, and delegation does not.

## 5. Why this is not "drop the subset"

The distinction §4 could not make in August is between a parser used as an
*executor* and a parser used as a *judge*.

Today masc is the only product of the six surveyed where the parse result is
what runs. Everywhere else — Claude Code, Codex, OpenClaw, Hermes — the parser
answers one question ("can I produce a trustworthy argv?") and the original
string is what executes. Claude Code's own parser header says it outright:

> The key design property is FAIL-CLOSED [...] This is NOT a sandbox. It does
> not prevent dangerous commands from running. It answers exactly one
> question.

masc gets something real from being the odd one out: the typed path has no
shell, so command substitution and word splitting are not *policed*, they are
*absent*. That is worth keeping for the 83%.

What it does not get is a boundary for the other 17%, because those already
run — through the side door, unjudged. This RFC does not lower the boundary
for them. It raises it from "nothing" to "the guest kernel."

## 6. Open questions

**`Remote_ssh` is the majority and the least contained.** Five of nine keepers.
The endpoints are all `127.0.0.1:2222` — one `masc-ssh-testbed` container, one
unix user and one `/opt/masc-playground-<name>` root per keeper. So a shell
there cannot touch this host, which is the property that matters most. But
`network_mode = "none"` is *rejected* for this profile (`remote_ssh_no_network_mode`),
so the guest has network, and keepers are separated from each other by unix
permissions rather than by a kernel.

Three possible answers, and this RFC does not pick one:

1. Delegate there too — the host is safe, and that was the point.
2. Do not, until per-endpoint isolation is per-keeper.
3. Delegate, but only when the endpoint declares it (a new endpoint field),
   which makes the operator state it once per endpoint rather than per call.

**What does the tap record?** `shell_costume` currently reports `finding` and
`lowered`. A delegated script is neither lowered nor escaped; it is a third
disposition, and the census that decides the next step has to be able to
count it.

**Does anything become unreachable?** If delegation lands,
`Parsed.reason_too_complex` stops being a refusal for backend keepers and
becomes a routing signal. `Subset_rewrite` still has a job (it writes the
advice), but the arms that exist to *refuse* would want re-reading.

## 7. What would have to be true first

- A keeper's profile is available at the Execute dispatch site. It already is
  (`dispatch_sandbox`, `sandbox_profile_label` in `keeper_tool_execute_runtime.ml`).
- The Docker and SSH runners can carry an arbitrary `sh -c` payload. The
  `Sandbox_target.runner` closure already takes an argv, so this is
  `["sh"; "-c"; script]` rather than new plumbing.
- The census can tell delegated from lowered from escaped, so the effect is
  measurable after the fact rather than argued before it.

## 8. Workaround self-check (CLAUDE.md bar)

- **Telemetry-as-fix?** No. §6 asks for a third disposition in the tap, but the
  change is what executes, not what is counted.
- **String/substring classifier?** None added. The routing key is a typed
  `sandbox_profile`, and the parse result stays the closed
  `reason_too_complex`.
- **N-of-M?** The rule is stated for all three profiles; `Remote_ssh` is
  explicitly open rather than quietly skipped.
- **Catch-all added?** No. The per-profile match is exhaustive by construction.
- **Cap/cooldown/dedup/repair?** None.
- **Test backdoor?** None.
- **Second SSOT?** The profile stays the one in the keeper TOML. This RFC adds
  a consumer, not a second declaration.
- **Acknowledged risk.** Delegation gives up path scope and redirect policy for
  the scripts it covers. Today those scripts have neither, so the change is
  not a loss — but if step 4's coverage ever grew to include them, delegation
  would be the weaker of the two and should lose.

## 9. Sources

Product behaviour in §2 and §5 was read from source on 2026-08-31: Claude Code
(leaked 2026-03-31 tree, `utils/bash/ast.ts`, `sandbox-adapter.ts`),
openai/codex (`core/src/exec_policy.rs`, `sandboxing/src/seatbelt.rs`),
openclaw (`src/agents/bash-tools.exec.ts`, `src/infra/exec-approvals.ts`),
NousResearch/hermes-agent (`tools/terminal_tool.py`), badlogic/pi-mono
(`packages/coding-agent/src/core/tools/bash.ts`). Fleet and corpus figures from
`~/me/.masc/config/keepers/*.toml` and `tools/costume_census`.
