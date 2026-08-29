---
rfc: "execute-subset-dispositions"
title: "Execute subset dispositions: resolve it, spawn it, or name the replacement"
status: Draft
created: 2026-08-24
updated: 2026-08-24
author: vincent
supersedes: []
superseded_by: null
related: ["0091"]
---

# Execute subset dispositions: resolve it, spawn it, or name the replacement

## 1. Problem

`Masc_exec.Parsed.reason_too_complex` has fourteen arms and one disposition:
refuse. The arms have nothing in common except that the Phase 1 subset does not
parse them, and collapsing four different kinds of thing into one answer is what
produces the escape.

Measured over 23,082 Execute records (`<base-path>/.masc/tool_calls/2026-08/*.jsonl`,
counted 2026-08-23):

| observation | count |
|---|---|
| argv-form calls | 22,309 |
| `argv[0]` is `sh`/`bash`/`zsh`/`dash` | 1,216 (5.5%) |
| …of those, using **no** shell feature at all | 508 |
| shell operator as a bare argv token | 119 (`\|` 58, `&&` 52, `;` 7, `\|\|` 2) |
| …of the 52 `&&`, recorded `success: true` | 43 |
| argv containing glob characters | 284 |
| command substitution | 28 |

Three separate defects hide in that table.

**1.1 `sh -c` voids the whole boundary, by construction.** `Execute` accepts
`Script of string` — which goes through `Shell_gate.gate_raw`, is parsed,
path-scoped, and refused with a classified reason — and `Staged { program; next }`,
which lowers `argv` to a `Simple`. So:

```
argv:   ["sh";"-c";"cd x && build; tmux new-session ..."]
        -> Staged -> Simple { bin = sh; args = ["-c"; "cd x && build; tmux ..."] }
        -> the gate sees one program and two opaque literals.

script: "cd x && build; tmux new-session ..."
        -> Script -> gate_raw -> parse, Path_scope, redirect policy, classified refusal
```

Same text. Which JSON field it arrives in decides whether the gate applies at
all. `;` is unrepresentable in `Shell_ir.connector` and pipeline status already
behaves like `pipefail` — both guarantees evaporate inside those quotes. This is
5.5% of all calls.

**1.2 The 43 silently-successful `&&` calls are not a validation gap.**
`["test";"-w";"f";"&&";"echo";"writable"]` hands `test` four arguments; the
second command never runs and the call is recorded successful. The typed schema
documents this as intentional (`execute_typed_input.mli`, "Literal argv"), and
for `execve` semantics it is correct. The caller wanted shell semantics and
picked the shell-shaped field's neighbour. Rejecting the token would break
literal use; the fix is to send shell-shaped input to the shell gate.

**1.3 On the typed path, `Cannot_parse` and `Too_complex` are unreachable.**

```ocaml
let decide_typed ~ir ~syntax_policy ~sandbox =
  match parse_only_to_ir (PD.Parsed ir) with   (* always wrapped as Parsed *)
  | Error (`Cannot_parse reason) -> Cannot_parse { reason }
  | Error (`Too_complex reason) -> Too_complex { reason }
  | Ok ir -> apply_policy ~syntax_policy ~sandbox ~ir
```

`parse_only_to_ir` returns `Ok` for every `PD.Parsed`, so a typed caller can only
ever receive `Gate_reject` or `Path_reject`. Witness, run 2026-08-24:
`Pipeline [Pipeline [a; b]; c]` handed to `Execute_shell_ir.dispatch` **executed**,
though `shell_command_gate.mli` states the facade rejects nested pipelines. The
invariant lives in `lower_typed_pipeline`, which that entry point does not use.

## 2. Boundary & invariants

- The gate stays the only door. Where a typed path would need its own copy of a
  check, it is routed back through the door instead. Two copies of a check
  always diverge; OpenAI Codex reached the same conclusion for `apply_patch`
  (openai/codex#24214, fixed in #1705 by running it through the shell sandbox
  rather than teaching it the allowlist).
- Expansion performed by the gate happens **inside** `Path_scope`. A glob the
  gate expands is more constrained than the same glob handed to `sh`, which
  expands against the real filesystem with no scope at all.
- No keeper waits on another keeper. An approval hop would be a delegation
  contract with a response obligation, which `instructions/projects.md`
  forbids. This RFC therefore does **not** adopt the escalate-to-a-reviewer
  model that Codex and pi.dev use, because both resolve escalation with a human
  and masc keepers run unattended.
- `;` stays unrepresentable. Its meaning is "ignore whether the last thing
  worked", and `Shell_ir.connector` was right to omit it.
- The taxonomy is closed and every one of the fourteen arms gets a disposition
  in §3. Staging is an implementation order, not a coverage claim.

## 3. Design

### 3.1 A refusal is a rewrite

An earlier draft of this section sorted the arms into four categories with four
dispositions. Two of those "refusals" were not refusals. `Needs_a_file` -- the
answer for a loop -- is not a refusal, it is *`Write` the script, then `Execute`
the file*: a sequence of calls that already exists. A heredoc is not outside the
subset either; `input_source` already has the field, and the caller used the
wrong one.

Once those two collapse, every arm turns out to answer the same question:

> **what should this call have been?**

| what arrived | the call it should have been |
|---|---|
| `{a,b}.txt` | the expanded argv -- the gate can produce it |
| heredoc / here-string | `stdin: { literal: "..." }`, a field that already exists |
| `;` | two calls, or `&&` |
| `&` | `Spawn` (§3.3) |
| `$(...)` | two `Execute` calls, the second using the first's stdout |
| `for` / `if` / function definition | `Write` the script, then `Execute` the file |
| `<(...)` | write the inner output to a file, pass the path |
| `*` | already accepted -- but it means something else here (§3.2) |

So `Too_complex` is not a verdict. It is a **rewrite**, and what comes back is
not a reason but the call the caller should have made:

```ocaml
type outside_the_subset =
  | Lower_differently of Masc_exec.Shell_ir.t
      (* the gate can express this after all; here is the IR *)
  | Move_to_field of { field : field_name; value : Yojson.Safe.t }
      (* the schema already has somewhere to put this *)
  | Call_this_instead of tool_call
      (* Spawn, or Write-then-Execute: a call the caller can make now *)
  | Unrepresentable of Masc_exec.Parsed.reason_too_complex
      (* the only genuine refusal; see below *)
```

Three consequences follow, and each of them settles a question an earlier draft
had open.

**The rewrite is the second door, and it costs no waiting.** §2 rules out an
approval hop because a keeper waiting on another keeper's approval is a
delegation contract. A rewrite needs no approver: the keeper receives a call it
can make immediately and makes it. Codex and pi.dev put a human at the end of
their escalation; this puts the answer in the caller's hands instead.

**The gate must hand the rewrite back rather than apply it silently.** This is
what §3.2 forces: expanding `*` behind the caller's back changes what runs.
Returning "you should have called it this way" changes nothing, and the caller
that sees the corrected call makes it directly next time. A silent fix teaches
nothing and hides the divergence it created.

**One arm has no rewrite.** `Unknown_construct` is, by definition, a construct
the parser could not name, so there is no call to suggest. It stays a refusal,
and it is the only one. `Cannot_parse` is likewise untouched -- text that does
not parse has no rewrite either, and it is a different verdict.

`reason_too_complex` does not grow. It stops being a bucket with one answer and
becomes a function from a construct to the call that expresses it.

### 3.2 The rewrite the gate can compute itself

Every arm in A computes an argv or a stdin and then disappears. The gate can do
that work and stay inside its own boundary:

- **`Glob_brace`, and the wildcard that is not it.** Measured 2026-08-24 and
  pinned in `test_shell_costume.ml`: `ls *.ml` through `gate_raw` is
  **`Representable`**, not a refusal. A wildcard survives as a literal argv
  token; only brace expansion (`{a,b}`) trips `Glob_brace`. So glob is not a
  refusal bucket at all -- it is a **semantic fork**:

  | | what `ls` receives |
  |---|---|
  | `sh -c "ls *.ml"` | the matched files, expanded by the shell |
  | `argv:["ls";"*.ml"]` | the literal string `*.ml` |

  Both are right for the field they arrived in, and routing the first to the
  second silently changes what runs. `Shell_ir.arg_meta` already carries
  `glob : bool`, which is exactly the bit that separates "this wildcard was
  parsed out of shell text" from "this wildcard is a literal the caller typed",
  so the disposition splits along it:

  - `glob = true` (came from shell text): the gate expands, **through
    `Path_scope`**. `sh -c "rm ../*"` currently expands against the real
    filesystem with no scope at all; gate-side expansion cannot leave the
    workspace.
  - `glob = false` (typed argv literal): untouched, exactly as
    `execute_typed_input.mli` documents today.

  Brace expansion builds argv before `exec` and has an obvious rewrite: the
  expanded argv, handed back as `Lower_differently`.
- **`Heredoc` / `Here_string`**: these are stdin content, and stdin is already
  typed — `input_source` has `Inherit_input | Empty_input | Read_file`. Add
  `Literal of string`. A heredoc becomes a typed field; no shell is involved.
- **`Arith_expansion`**: pure integer evaluation on the parsed AST.
- **`Cmd_subst`**: gate the inner command, dispatch it, substitute its stdout.
  This is the only arm in A that makes gating *effectful*, so it is staged last
  and may be declined outright (§6). Depth is bounded by the existing
  `reason_aborted `Depth_limit`.

### 3.3 The rewrite that names another tool, because the result shape differs

`Exec_dispatch.dispatch_result` is `{ status; stdout; stderr }`: a record that can
only be filled in once the process is dead. A live process does not fit, and
cramming it in is a known failure mode rather than a hypothesis — Codex#34115
reports exactly that ("unified exec drops canonical process identity and hides a
live background wait").

So `Background` becomes a tool, not an arm, and the result type splits:

```ocaml
type outcome =
  | Finished of dispatch_result
  | Live of Process_handle.t
```

Surface, following the split Claude Code ships (`run_in_background` + `Monitor` +
`TaskOutput` + `TaskStop`) rather than one overloaded call:

```ocaml
val spawn      : Shell_ir.simple -> Process_handle.t          (* returns while alive *)
val wait_until : handle:Process_handle.t
              -> probe:Shell_ir.t
              -> predicate:predicate
              -> timeout:Duration.t
              -> (unit, [ `Timed_out ]) result
val read       : Process_handle.t -> chunk
val stop       : Process_handle.t -> unit
```

`wait_until` has **no "sleep N seconds" arm**. `timeout` is the failure bound, not
the wait: a probe that never matches must end as `Timed_out`, never as a
plausible number. Claude Code blocks foreground `sleep` outright for this reason
and directs callers to a condition loop; this RFC encodes the same rule in the
type instead of in a guard.

Handles are scoped. `Scoped { setup; body }` is `Eio.Switch` with
`Switch.on_release`, already the codebase idiom, and it answers Codex#26382
(a cancelled task that kept running and saturated a server) structurally.

### 3.4 The rewrite that is a different call the caller already has

A refusal that does not say what to do instead has exactly one follow-up move,
and that move is `sh -c`. These two arms have a replacement the caller can
already express, so neither needs to be a refusal at all.

**`;`** carries `Move_to_field`: the separator becomes a connector.

```ocaml
Move_to_field { field = `Next_conditional; value = `And_then }
(* or two calls, when the caller really did mean "both, regardless" *)
```

`Shell_ir.connector` omits `;` on purpose -- it means "run the next thing
whether or not the last one worked" -- and the rewrite says so by naming the
connector that does not.

**Loops, conditionals, function definitions, subshells** carry
`Call_this_instead`: a program belongs in a file, written through the normal
write path and executed as a gated argv.

```ocaml
Call_this_instead (Write_then_execute { suggested_path; body })
```

That route is fully covered by the existing boundary, and it is the same answer
a reviewer would give. Nothing here is new capability; the rewrite only names a
call the caller already has.

### 3.5 One door: argv-shaped shells route to the script gate

With A resolved, the normalization becomes safe to perform:

> If `argv[0]` is a shell and `-c` is present, the call is a `Script` wearing an
> argv costume. Lower it through `script_to_shell_ir`.

Effect on the measured buckets:

| bucket | today | after |
|---|---|---|
| no shell feature (508) | gate voided | plain flat IR; nothing refused — strictly better |
| argv with glob characters (284) | `sh` expands against the real filesystem, unscoped | expanded by the gate inside `Path_scope` -- **only** where `arg_meta.glob` says the wildcard came from shell text (§3.2). Without that split this row is a silent behaviour change, not an improvement. |
| bare operator tokens (119, 43 silently successful) | wrong answer recorded as success | shell semantics actually applied, or a refusal with a name |
| `;` inside the string (7) | silently allowed | `Use_a_connector` |

`script_to_shell_ir` already exists, already has tests, and its own comment states
the intent this RFC generalises: *"Carried, not flattened: `reason_too_complex` is
the value the corpus tap counts to decide which construct the subset takes next,
and a script hidden inside `argv:["bash";"-c";...]` is counted as nothing at all."*

### 3.6 Close the typed-path hole (§1.3)

`decide_typed` must validate the IR it is handed rather than re-wrapping it as
already-parsed. Concretely, the structural invariants `lower_typed_pipeline`
enforces (no nested `Pipeline`, no empty stage list) move into a function both
entry points call, so a hand-built IR cannot skip them.

### 3.7 Staging, and what the corpus says

The order below was written before anything was counted. `tools/costume_census`
runs the same recogniser and classifier over the recorded Execute calls, which
answers the question the live tap answers, over a month instead of an
afternoon. Run over `<base-path>/.masc/tool_calls/2026-08/*.jsonl`, 2026-08-25:

```
execute=31798  argv_form=31008  costumes=2724  lowered=1474

what the gate would have said        what the caller should have called
   1484  representable                 1019  move_to_field:connector
   1019  command_separator              145  call_this_instead:execute-twice
    142  cmd_subst                       53  move_to_field:stdin
     39  heredoc                         18  call_this_instead:write-then-execute
     17  subshell                         5  call_this_instead:spawn
     13  redirect
      5  background
      3  arith_expansion
      1  here_string
      1  proc_subst
```

`lowered` is not an estimate: the census calls the same
`to_shell_ir_unvalidated` step 4 calls, so the three guards it applies are the
ones counted. 1474 of the 1484 `representable` costumes come out of it wearing
no shell, which puts the cost of the other two guards -- a declared stream, a
`Var` in the lowered IR -- at ten calls.

Live traffic looked like it said something different, and what dissolved the
difference is the point. `shell_costume` records from `<base-path>/.masc/logs/`,
531 of them on 2026-08-24:

```
   314  command_separator      12  subshell         2  arith_expansion
   153  representable           6  redirect         1  proc_subst
    38  cmd_subst               4  heredoc          1  here_string
```

This note first read that as the corpus and the tap disagreeing about which
construct dominates -- `;` at 16% of recorded costumes against 59% of live
ones. They were never compared over the same window: 16% averaged 24 days and
59% was one of them. Counting the corpus a day at a time settles it.

```
days 01-23   costumes 1413   command_separator  207 (15%)   representable 1099 (78%)
day  24      costumes 1246   command_separator  758 (61%)   representable  379 (30%)
```

61% against the tap's 59%, on the same day. The two instruments agree; what
changed is the traffic, on 2026-08-24 and sharply. Eighty percent of the whole
corpus is the last three days, so a month-wide average now describes a month
that no longer exists, and the numbers above are quoted per day for that
reason.

An earlier reading of 27 records put `subshell` at 44%; at 531 it is 2%, so
that one was sample noise, and this note keeps both numbers rather than only
the one that survived.

Two things follow for the staging below.

The flip covers less than the first corpus reading suggested. `representable`
was 78% of costumes through the 23rd and is 30% on the 24th, so step 4 buys the
boundary for roughly a third of recent escapes rather than three quarters. It
is still the largest thing the gate can take without refusing anything, and it
is still worth doing; it is not the whole problem.

And the largest live category is the one the IR refuses on purpose. `;` means
"run the next thing whether or not the last one worked", and
`Shell_ir.connector` omits it deliberately. Six of every ten escapes are
someone reaching for exactly that.

Except the rewrite was not reaching them, and the logs said so: 531
`shell_costume` records on 2026-08-24, and zero occurrences of any
`Subset_rewrite` sentence.

The reason is structural rather than a defect. `Subset_rewrite` speaks on the
refusal path, and an argv-shaped costume is never refused -- it arrives as one
opaque program, the gate has nothing to object to, and it runs.
`argv:["sh";"-c";"a; b"]` is smuggled through; only `script:"a; b"` is refused
and told what to write instead. §3.7 step 4 does not touch it either, because
it lowers the `representable` ones and deliberately leaves the rest on the
path they already work on.

So the largest live category had nothing in this plan pointed at it. Refusing
those calls would break work that runs today; saying nothing leaves the caller
with no reason to stop writing them. What was left was to **tell without
refusing**: when a costume is not representable, carry its rewrite back beside
the successful result, so the caller learns what the call should have been
while the call still does what it did. That is the same "a refusal is a
rewrite" shape as §3.1, applied where there is no refusal to carry it.

Shipped. The rewrite rides back in the answer's payload as `escaped_shell` --
`shell`, `finding`, and `should_have_been`, one entry per costume the gate
would have refused. `ok`, the status and the streams are untouched, so a call
that worked still reads as a call that worked.

It went into `metadata` first, which was the wrong shelf. A completed result's
model-visible text is the serialized `data`, and every read of `_meta` in
agent_core discards it -- `agent_tools.ml` answers `Ok { content; _meta = _ }`
at the point a tool result becomes conversation. Metadata reaches observers
and an MCP wire client; it does not reach the keeper this sentence is written
for. Telling the caller means putting it where the caller reads.


Two entries of the first draft do not survive it.

**`glob_brace` is zero.** The 284 this RFC first quoted counted argv that
*contained* a glob character, and §3.2 already found that a wildcard is
`representable` rather than refused. Brace expansion does not appear in a month
of traffic. The glob half of step 2 is cancelled: there is nothing to rewrite.

**Over half the escapes carry nothing the IR cannot hold.** 1484 of 2724
`sh -c` calls are `representable`, so routing them through the gate costs
nothing and buys them path scope, redirect policy, and the connector rules.
That makes the flip the highest-value step rather than the last one -- but it
must be partial. A blanket flip would refuse the other 1240, which run today.

The largest refusal is `;` (1019, 37% of the whole corpus and 61% of the most
recent day). It is the one thing `Shell_ir.connector` deliberately cannot say,
so the most common reason to leave the typed surface is to ignore whether the
last command worked.

Revised order:

1. **Shadow count** -- shipped. `Shell_costume` plus `hidden_script_findings`,
   and `tools/costume_census` for the recorded corpus.
2. **The rewrites** -- shipped for `;` and the script constructs
   (`Subset_rewrite`), and for heredoc, which needed `input_source` to gain a
   literal before its own advice was actionable. **Glob is cancelled.**
3. **§3.6 typed-path invariants** -- shipped.
4. **Flip §3.5, for the representable only.** Lower an argv-shaped shell
   through the gate when the classifier says `representable`, and leave the
   rest on today's path with the tap still recording them. **Shipped.** 1474
   of the corpus's 1484 `representable` calls come out of the lowering wearing
   no shell; none change what they do.
5. **Tell without refusing** -- shipped, and not in the first draft at all:
   it exists because step 4 left the largest live category untouched. The
   rewrite rides back as an `escaped_shell` field in the answer's payload.
6. **B (`Spawn`)**, on its own RFC-sized change: 5 calls in the corpus. The
   count says this is last on traffic, not that it is unnecessary --
   backgrounding has no alternative today, so a caller that needs it cannot
   ask. Its core is shipped and its tools are being wired.

No step splits `dispatch_result`. The 14 non-test consumers this RFC priced
that split at are the reason §4 of the spawn RFC declined it: a spawned
process answers with a handle, which is a separate tool surface rather than a
second shape for the same record, so `dispatch_result` keeps the shape only a
dead process can fill.

## 4. Rejected alternatives

- **Grow the grammar toward bash.** Adding `&&`/`|`/redirect arms to the typed
  surface covers 27% of the `sh -c` escapes (measured §1); the rest are globs,
  substitution, and the 508 that need nothing. Every arm is also a new divergence
  surface `shell_ir_oracle` must pin.
- **Reject bare operator tokens in argv.** Breaks the documented `execve`
  contract and the legitimate literal use it protects, and misreads the 43 calls:
  the caller wanted shell semantics, not a validation error (§1.2).
- **Escalate refusals to an approving keeper.** This is how Codex
  (`approvals_reviewer = "auto_review"`, risk tiers) and pi.dev (permission
  prompts) resolve the same fork, and it works because a human sits at the end.
  A keeper waiting on another keeper's approval is a delegation contract with a
  response obligation, forbidden by `instructions/projects.md`.
- **Drop the subset and gate only at the OS boundary,** as Codex and pi.dev do.
  Same objection: their model resolves the residue with a human prompt, which
  unattended keepers do not have.
- **Teach the typed path its own copy of the structural checks.** Two copies
  diverge; §2 routes instead. Codex#1705 is the precedent.
- **Keep `Too_complex` and only improve its message.** Attempted 2026-08-24 and
  discarded: on the typed path those branches are unreachable (§1.3), and on the
  raw path `script_to_shell_ir` already carries the reason. The change decorated
  dead code.

## 5. Test plan

- **§3.6 regression, must fail before the fix:** `Pipeline [Pipeline [a;b]; c]`
  through `Execute_shell_ir.dispatch` must refuse. Today it executes.
- **Glob scope, must fail before the fix:** a pattern reaching outside the
  workspace (`../*`) must be refused by `Path_scope` after gate-side expansion.
  The same string via `sh -c` currently expands unscoped.
- **Wildcard equivalence, the one that can regress:** `argv:["sh";"-c";"ls *.ml"]`
  after normalization must receive the same expanded file list it receives
  today, while `argv:["ls";"*.ml"]` must still receive the literal token. A test
  that only checks the first would pass while breaking the second.
- **Normalization equivalence:** for each of a corpus sample, `argv:["sh";"-c";S]`
  and `script:S` must produce the same IR or the same classified refusal.
- **Heredoc as stdin:** a heredoc script and the equivalent
  `input_source = Literal` must produce byte-identical child stdin.
- **`wait_until` timeout:** a probe that never matches must return `Timed_out`
  within the bound. There must be no test that passes by sleeping.
- **Refusal completeness:** an exhaustive `match` over `reason_too_complex` in
  the disposition function, so a new arm cannot be added without choosing a
  category. No `_ ->` catch-all.
- **Oracle:** every construct the gate now rewrites must be differentially
  tested against real `bash` output in `shell_ir_oracle`.

## 6. Verification (closed) & open questions

Closed by reading and by running, 2026-08-24:

- `decide_typed` cannot produce `Cannot_parse`/`Too_complex` (§1.3), with a
  nested-pipeline witness that executed.
- `script_to_shell_ir` exists, is reached from `Script`, and carries the reason.
- "corpus tap" appears in one comment and nowhere else; it is not built.
- `pipeline_status` already folds to failure if any stage fails, and
  `dispatch_sequence` matches connector x status exhaustively with no catch-all.

Closed by building, 2026-08-30:

- **A tag named the first trip, not the construct.** The reason was inferred
  after the fact by scanning the whole source for the first metacharacter off
  an ordered list. The list had no case for `$`, so any script combining an
  expansion with a redirect was reported as `redirect` — and `redirect`'s
  disposition sent the caller to the `stdin` field, which is not a move for
  `>`. The lexer now raises the reason from the rule that matched the
  offending lexeme, so a tag is an observation. Longest match orders `<<<`
  against `<<` against `<`, which the list was hand-simulating. `redirect`
  survives, meaning only the operators the grammar does not spell (`&>`,
  `>|`, `<>`, `>&-`), and its disposition is `Spell_it_as "> file 2>&1"`.

Open:

- **Should `Cmd_subst` be resolved at all?** It makes gating effectful, which is
  a property the gate does not otherwise have, for 28 calls. Declining it and
  rewriting it as `Call_this_instead` (write a file) is a defensible answer and the
  author leans that way.
- **Does expansion belong in the gate or between gate and dispatch?** Expansion
  must not run before `apply_policy`, or policy would inspect an unexpanded argv.
  Placement needs to be pinned before step 2.
- **Does control flow deserve rules of its own?** `for`, `while` and `if` lex
  as ordinary words, so `for f in a b; do echo $f; done` is now tagged
  `param_expansion` — the construct it does contain, named where it stops. A
  distribution grouped by tag still does not see control flow, and
  `` `Control_flow `` and `` `Function_def `` still have no producer. Reading
  a loop as a loop needs grammar, not another tag.
- **What does `wait_until`'s `probe` cost?** A probe is itself a gated dispatch
  per poll. Poll interval and a maximum probe count need numbers, not defaults.

## 7. Non-goals / future

- Not a sandbox change. `Sandbox_target` (host/Docker) is unchanged; this RFC is
  about what the gate can represent, not what the OS enforces.
- No approval or escalation machinery (§4).
- `Logic_op` keeps the write-a-file rewrite, and `Unknown_construct` stays the
  one genuine refusal, until the shadow count
  (step 1) shows what they actually are in production.

## 8. Workaround self-check (CLAUDE.md bar)

- **Telemetry-as-fix?** Step 1 is counting only, and it is explicitly a
  measurement step whose output decides steps 2-4 — not a counter shipped in
  place of a fix. Steps 2-5 change execution.
- **String/substring classifier?** No. This RFC *removes* string-shaped
  execution (`sh -c "..."` as opaque argv) and routes it to a parser with a
  closed reason type. No substring matching is added.
- **N-of-M?** No. §3.1 gives all fourteen arms a rewrite, or states why one
  (`Unknown_construct`) has none; §3.7 stages
  the implementation. Staging order is stated as order, not as coverage.
- **Catch-all added?** The opposite: §5 requires an exhaustive `match` over
  `reason_too_complex` so a new arm cannot be added without a category.
- **Cap/cooldown/dedup/repair?** No. `wait_until`'s timeout is a failure bound,
  and the RFC forbids a sleep-shaped arm precisely so it cannot become one.
- **Test backdoor?** None proposed.
- **Second SSOT?** Avoided by §2 and §3.6: the structural invariants get one
  implementation that both entry points call, rather than a copy per path.
- **Acknowledged risk.** §3.2 gives the gate work it did not previously do.
  Glob expansion reads the filesystem during gating, and `Cmd_subst` would run a
  process during gating. The first is a scoped read and is accepted; the second
  is open in §6 and the author leans toward declining it.
