---
rfc: "execute-boundary-is-the-sandbox"
title: "The subset judges; the sandbox contains"
status: Draft
created: 2026-08-31
updated: 2026-09-02
author: vincent
supersedes: []
superseded_by: null
related: ["execute-subset-dispositions", "0394", "0091"]
---

# The subset judges; the sandbox contains

`Execute` is the only tool in the six surveyed products whose parse result is
what runs. Everywhere else the parser answers one question and the original
string goes to a shell. This RFC proposes masc join them for the `script`
field, keep the typed path for `argv` — the typed `pipeline` field is removed
by RFC-execute-command-string (PR #32618) — and let the profile's sandbox be the
containment it already is.

## 1. What this asks to reopen

`RFC-execute-subset-dispositions` §4 rejected:

> **Drop the subset and gate only at the OS boundary,** as Codex and pi.dev do.
> Same objection: their model resolves the residue with a human prompt, which
> unattended keepers do not have.

It also rejected escalating refusals to an approving keeper, on the grounds
that a keeper waiting on another keeper is a delegation contract. **That second
rejection still holds and nothing here proposes touching it.** No approval
keeper, no human prompt, nothing waits.

The first rested on a fact about the fleet that stopped being true four days
later, and on a reading of the surveyed products that their source does not
support.

## 2. What changed under it

| date | |
|---|---|
| 2026-08-24 | `RFC-execute-subset-dispositions` written. Profiles: `Local`, `Docker`, `Remote_ssh`. |
| 2026-08-28 | `Micro_vm` lands (#31253) — one guest kernel per keeper via Apple's `container` CLI, network `none` by default. |
| 2026-08-30 | Three keepers move to it. |
| 2026-08-31 | `Local` is removed (#32078). A keeper declares `docker`, `microvm`, or `remote_ssh`, or it is refused at config load. |

Live fleet on 2026-08-31: `remote_ssh` 5, `microvm` 3, `docker` 1, host **0**.

And the prompt §4 worried about is not the mechanism. Read from source:
Codex's `render_decision_for_unmatched_command` returns **Allow** for a
not-known-dangerous command when a sandbox is present, and prompts only when
there is none. Claude Code states the same trade outright in
`autoAllowBashIfSandboxed`. The human is the fallback for the sandbox-less
case. Every masc keeper now has the sandbox.

## 3. What the subset is actually holding

`tools/costume_census` over `<base-path>/.masc/tool_calls/2026-08/*.jsonl`,
31 days, run 2026-08-31 with the counter corrected in #32075:

```
execute=45381  argv_form=43821  costumes=6815  lowered=5680
```

Three populations, and they want different things:

| | count | what it is |
|---|---|---|
| genuine `argv` | 37,006 | `["git";"log";"--oneline"]` — never wanted a shell |
| shell costumes | 6,815 | `["bash";"-c";S]` — wanted a shell, smuggled one |
| no top-level argv | 1,560 | `script`, and the since-removed `pipeline` / `then` forms |

The typed path's irreplaceable value is the first row: a call that is naturally
argv gets no shell, so word splitting and substitution are not policed, they
are **absent**. That is worth keeping and this RFC keeps it.

The second row is the problem. Of 6,815 costumes, 5,680 are lowered into the
IR by `RFC-execute-subset-dispositions` §3.7 step 4; the other **1,135 run as
opaque programs** — no `Path_scope`, no redirect policy, no connector rules.
They are not refused. They run. The gate does not see them.

Meanwhile the `script` field, which *does* cross the gate, refuses what the
subset cannot represent: 32 refusals over three days
(`redirect` 10, `cmd_subst` 8, `subshell` 8, `param_expansion` 4, `background` 2).

So the same text is refused through one field and executed unwatched through
another. Which field it arrives in decides.

## 4. Proposal: the field names the execution model

| field | model |
|---|---|
| `argv` | typed. argv spawn, no shell. **Unchanged.** |
| `script` | a real shell, inside the keeper's sandbox |

`script` becomes what every surveyed product's `command` parameter is: text
handed to `sh -c` on the far side of the boundary. Its current promise —
"parsed rather than handed to a shell" — is retired.

The routing key is the field the caller chose. Not the content, not a
substring, not a heuristic.

### 4.1 One door

An `argv` whose program is a shell with `-c` is a `script` in an argv costume.
It normalizes to `script` and takes the shell path.

That is `RFC-execute-subset-dispositions` §3.5's "one door", finished. Step 4
walked through it for the representable; this is the rest of the sentence, and
it closes the smuggling route rather than widening it: after this there is no
way to reach a shell that the gate did not route.

§3.7 declined a blanket flip because the gate would have **refused** the
non-representable, breaking work that runs. Nothing is refused here.

### 4.2 All three profiles

`Micro_vm`, `Docker`, `Remote_ssh` all delegate. The reason is narrower than
"the boundary is good enough": a shell already runs on each of them.
`Keeper_sandbox_ssh.runner` takes `~argv` and runs it on the endpoint
verbatim; the Docker and guest runners do the same. `argv:["bash";"-c";S]` is
a real shell on every profile today. This RFC changes nothing about *reach* —
only about whether the gate saw it.

There is no fourth profile, and no host arm to answer for (#32078).

## 5. Why not route by content

The alternative — keep `script` typed when the subset can represent it, shell
when it cannot — was this RFC's first draft. It is rejected.

**It makes the execution model invisible.** Editing a script would flip it:

```
script: "ls *.ml"            typed  — glob expanded inside Path_scope
script: "ls *.ml && date"    typed
script: "ls *.ml $(pwd)"     shell  — glob now expanded by the shell
```

The caller cannot see that boundary, and `RFC-execute-subset-dispositions` §5
already named this exact hazard as "the one that can regress".

Two paths do exist in the products surveyed, but they are split **by tool**,
and the model picks: Claude Code's Read/Glob/Grep against Bash, Codex's
`apply_patch` against `exec_command`. Nobody splits inside one tool by whether
a parser happened to cope.

**It puts the subset on a treadmill.** §4 of the parent RFC said it: *"Every
arm is also a new divergence surface `shell_ir_oracle` must pin."* Under
content routing, widening the grammar moves calls from shell to typed — every
fidelity improvement is a behaviour change, and the convergence point is
reimplementing bash.

**And the product that invested most in that parser refuses to execute from
it.** Claude Code reimplemented tree-sitter-bash in 4,436 lines of TypeScript,
validated against a 3,449-input golden corpus, and its header says:

> The key design property is FAIL-CLOSED [...] This is NOT a sandbox. It does
> not prevent dangerous commands from running. It answers exactly one
> question: "Can we produce a trustworthy argv[] for each simple command in
> this string?" If yes, downstream code can match argv[0] against permission
> rules [...] If no, ask the user.

masc executes from a much smaller parser. That is the asymmetry this RFC ends.

## 6. What the parser becomes

It stays, and it stops being load-bearing for execution:

- **Policy.** It still produces `Path_scope` for what it can parse, and that
  classification can keep feeding telemetry and rules without deciding the
  execution model.
- **Advice.** `Subset_rewrite` keeps telling a caller that `&` wants
  `keeper_spawn`. It rides back as `escaped_shell`
  the same way, and now it is advice about a better form rather than the
  explanation for a refusal.
- **Refusal, where refusal is the point.** A judge can still say no —
  to a dangerous pattern, to a path outside the workspace. That is a
  different question from "can I represent this", and separating them is
  what lets the parser improve without moving execution.

`Parsed.reason_too_complex` stops being a disposition and becomes a
classification. The arms that exist to refuse want re-reading; that is a
follow-up, not this RFC.

## 7. What this gives up

- **`Path_scope` on redirect targets inside `script`.** Containment moves to
  the sandbox mount, which is where it already was for the 1,135. What is lost
  is the *label* — "this redirect pointed outside the workspace" — not the
  containment. §6 keeps the judge able to compute it; wiring it to telemetry
  is a choice, not a requirement.
- **Enforcement of the typed form.** Today a `script` with `$(...)` is refused
  and the caller has to write something better. After this it runs, and the
  advice is only advice. The measured cost of the enforcement is 32 refusals
  in three days; the measured cost of the escape it creates is 1,135 unwatched
  calls a month.
- **The lowering of 5,680 representable costumes.** They move from typed to
  shell. What they lose is `Path_scope` and redirect policy inside a sandbox
  mount that already bounds them; what the fleet gains is one execution model
  per field.

## 8. What has to be true first

- The profile is available at the Execute dispatch site — it is
  (`dispatch_sandbox`, `sandbox_profile_label` in `keeper_tool_execute_runtime.ml`).
- The runners carry an arbitrary payload — they do; `Sandbox_target.runner`
  takes an argv, so this is `["sh"; "-c"; script]`.
- The census can tell shell from typed from advised, so the effect is
  measurable afterwards rather than argued beforehand.
- `argv → script` normalization is byte-exact: the same text through either
  field must produce the same child. `RFC-execute-subset-dispositions` §5
  already asks for this test.

## 9. Workaround self-check (CLAUDE.md bar)

- **Telemetry-as-fix?** No. This changes what executes.
- **String/substring classifier?** The opposite. The routing key is a schema
  field name; the smuggling route this closes is precisely the string-shaped
  one (`argv[0]` happening to be a shell).
- **N-of-M?** All three profiles, both fields, stated together. §4.2 is
  explicit that no profile is deferred, because deferring one would leave the
  side door open for it — the partial migration this bar forbids.
- **Catch-all added?** No. The field match is two arms and the profile match
  is three, both exhaustive.
- **Cap/cooldown/dedup/repair?** None.
- **Test backdoor?** None.
- **Second SSOT?** The field the caller chose is the single declaration. The
  costume normalization in §4.1 removes the second one.
- **Acknowledged risk.** §7 lists what goes. The sharpest is that a keeper can
  now write `$(...)` in `script` and have it run. It already could, by writing
  `argv:["bash";"-c";"$(...)"]`, on every profile, unwatched. This RFC makes
  that visible rather than possible.

## 10. Sources

Product behaviour read from source on 2026-08-31: Claude Code (leaked
2026-03-31 tree — `utils/bash/ast.ts`, `utils/bash/bashParser.ts`,
`sandbox-adapter.ts`), openai/codex (`core/src/exec_policy.rs`,
`shell-command/src/bash.rs`, `sandboxing/src/seatbelt.rs`), openclaw
(`src/agents/bash-tools.exec.ts`, `src/infra/exec-approvals.ts`),
NousResearch/hermes-agent (`tools/terminal_tool.py`), badlogic/pi-mono
(`packages/coding-agent/src/core/tools/bash.ts`). Fleet figures from
`<base-path>/.masc/config/keepers/*.toml`; corpus figures from
`tools/costume_census`; refusal counts from `shell_costume` records in
`<base-path>/.masc/logs/`.
