# G2 — typed command substitution `$(cmd)` in the Shell IR — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal.** Implement the approved RFC `docs/rfc/RFC-shell-ir-typed-command-substitution.md` (status: "승인 (구현 전 — PR-A 파서부터)"): the lexer/parser read `$(cmd)` into a new closed-sum node `Shell_ir.Subst of t`; dispatch evaluates it left-to-right, and the child's stdout (trailing newlines stripped) becomes **one argv element** of the parent — no word splitting, no glob, no re-parsing of output.

**Architecture.** The Shell IR (`lib/exec/shell_ir.mli`) is a pure closed-sum tree (`Simple | Pipeline | Sequence`); a new recursive `Subst of t` argv node extends it. The Menhir-era lexer (`bash_lexer.mll`) gains a balanced-scan rule for `$( )` that re-enters the parser through a hook (avoiding a module cycle and the shell-ir-consumption audit allowlist). Execution semantics live only in `lib/exec/exec_dispatch.ml` (effects at the boundary); the gate, policy, readonly-classifier, and keeper shell-tool rewrite each gain exhaustive `Subst` arms.

**Tech stack:** OCaml 5.5, ocamllex/Menhir, dune, existing test style in `lib/exec/test/` (plain asserts) and `test/`.

**Approved scope limits (quoted from the RFC, binding for this plan):**

- §1: opens `VAR=$(cmd)` assignment values (29 corpus cases) and inline `… $(cmd) …` (11). Does **not** open `eval $(opam env)` (16) or backticks (~0).
- §2.1: "`Subst of t` (* 새 노드: 자식 IR *) … 자식은 완전한 `Shell_ir.t`다 — 파이프·시퀀스·중첩 치환이 전부 같은 문법을 쓴다. `arg`의 소비자(`resolve_arg`, `pp_arg`, `bash.ml`의 `arg_as_assignment`, keeper 쪽 arg 순회)는 exhaustive match라 컴파일러가 전부 열거해 준다. `_ ->`로 삼키지 않는다."
- §2.2: "이 재파싱의 대상은 **사용자가 쓴 소스**뿐이다 — 실행 결과를 다시 파싱하는 일은 없다." Backticks keep the `` `Cmd_subst `` refusal.
- §2.3: children run left→right **with the parent's sandbox target**, env-binding Substitutions included; child stdout has trailing newlines stripped (bash rule); child stderr is appended to parent stderr; child exit status does not affect the value (bash rule); result is exactly one argv element; child runs inside what remains of the parent's `?timeout_sec`.
- §2.4: `eval`, `source`, `.` refused **by name in bin position** with new reason `` `Shell_builtin of string `` — "이 거절은 `$(` 개방 **이전에** 들어가야 한다". **No stdout size cap** ("ARG_MAX가 자연 상한이고, cap은 워크어라운드 시그니처다") and **no depth cap** (the 50k token budget already binds source size).
- §2.5: the external-effect judgement must traverse the whole IR; a Subst child's IR gets the same classification, and if any child needs approval the whole call waits.
- §3 staging: **PR-A** = parser + `Shell_builtin` refusal, with Subst-bearing IR still refused at dispatch as a typed `Too_complex`; **PR-B** = dispatch evaluation + gate traversal + execution tests. eval/opam gets no code — just one sentence in the refusal message ("switch env는 이미 export되어 있으니 eval을 빼라").

**Architecture at a glance (verified against current code):**

- The keeper typed Execute lane does **not** dispatch parsed subset IR today: `Keeper_tool_execute_typed_input.to_shell_ir` (`lib/keeper/keeper_tool_execute_typed_input.ml:313-336`) lowers `script` to one `Simple {bin=sh; args=["-c"; text]}` and real `sh` performs any substitution. The subset parser gates execution only in `validate_docker_dispatch_context` (`lib/keeper/keeper_sandbox_docker.ml:395`) and drives classification in `keeper_gate_readonly.ml` (RFC-0421) and costume findings. So PR-B's dispatch semantics are exercised by `Exec_dispatch`'s direct callers (tests, `lib/exec/test/test_shell_ir_chaining_benchmark.ml`) and are required for IR self-containment: once the gate allows a Subst-bearing IR, dispatch must execute it, not crash. See Risks.
- The RFC's "lexer calls `Bash.parse_string` recursively" cannot be literal: `bash.ml` already calls `Bash_lexer.token`, so a direct call back would be a module cycle, and `scripts/audit-shell-ir-consumption.sh` (CI lint, baseline `scripts/shell-ir-consumption-baseline.json`) fails on any new `Bash.parse_string` caller file outside its allowlist. Plan uses a **hook ref** installed by `Bash.parse_string`, which avoids both.

## Files map

| File | Change |
|---|---|
| `lib/exec/parsed.ml`, `lib/exec/parsed.mli` | add `` `Shell_builtin of string `` to `reason_too_complex` |
| `lib/exec/shell_ir.ml`, `.mli` | `Subst of t` node (recursive type group), `with_sandbox`/`has_variable_expansion`/`pp_arg` arms, new `has_command_substitution`, `subst_children_of_arg` |
| `lib/exec/parser/bash_lexer.mll` | `$(` balanced scanner + hook call in `token`, `word_tail`, `dq_pieces`; backtick refusal unchanged |
| `lib/exec/parser/bash.ml` | hook installation + reentrant parse, `arg_as_assignment` Subst arm, bin-position `Subst`/`Shell_builtin` refusals |
| `lib/exec/exec_dispatch.ml`, `.mli` | PR-A typed refusal; PR-B substitution evaluation, timeout propagation, pipeline fallback guards |
| `lib/exec/command_gate/shell_command_gate.ml`, `.mli` | Subst traversal in `with_sandbox`/`simples_of`/`check_syntax`; PR-A refusal in `structural_refusal` (removed in PR-B); new tag arm |
| `lib/keeper/keeper_gate_readonly.ml` | RFC-0421 classifier: Subst arms (child classification + literalness) |
| `lib/keeper/keeper_shell_tool_command.ml` | `literal_words`, `contains_masc`, `rewrite` Subst arms (refuse masc inside `$()` — see Risks) |
| `lib/exec_policy/exec_policy.ml` | glob-check Subst arm; `block_reason_of_exec_too_complex` arm |
| `lib/exec_policy/exec_policy_literal_words.ml` | `literal_words_of_simple` Subst arm; `flat_stage_words` descends into children |
| `lib/keeper_tooling/subset_rewrite.ml` | `of_construct` arm for `` `Shell_builtin `` (with the opam/eval sentence) |
| `lib/exec/shell_ir_oracle.ml` | drop `command_substitution` from `structural_feature_blockers` |
| Tests | `lib/exec/test/test_bash_parser.ml` (flip + add), new `lib/exec/test/test_shell_ir_subst_exec.ml`, `lib/exec/test/dune`, `test/test_shell_costume.ml`, `test/test_exec_shell_command_gate.ml`, `test/test_subset_rewrite.ml`, `test/test_keeper_gate_readonly.ml`, `test/test_keeper_shell_tool_command.ml`, `test/test_keeper_tool_execute_typed_input.ml` (comment/expectation), `lib/exec/test/test_shell_ir_oracle.ml` |
| `docs/rfc/RFC-shell-ir-typed-command-substitution.md` | status flip to implemented at the end |
| No change | `specs/shell-ir-first-class/ShellIRFirstClass.tla` (models the parse→validate→bind→dispatch state machine, not arg shapes; RFC does not ask), `sidecars/shell-ir-oracle/` (Go emitter unchanged; OCaml consumption changes only), audit script/baseline (hook design keeps the parse-string allowlist intact) |

---

## Task A1 — `Shell_builtin` refusal (lands before `$(` opens, RFC §2.4)

- [ ] **Step 1:** `lib/exec/parsed.mli:24-38` and `lib/exec/parsed.ml:10-24`: extend the polymorphic variant:

```ocaml
type reason_too_complex =
  [ `Heredoc
  | `Here_string
  | `Cmd_subst
  | `Shell_builtin of string  (** [eval], [source], [.] in program position:
      they re-parse their arguments in the shell that runs the line, which no
      IR node holds (RFC-shell-ir-typed-command-substitution §2.4). *)
  | ... ]
```

- [ ] **Step 2:** `lib/exec/parser/bash.ml` `raw_to_simple` (line 89-112): after `Exec_program.of_string` succeeds, refuse by name:

```ocaml
(* [eval]/[source]/[.] are not programs; they are the running shell
   re-parsing text.  The execution surface for a script is [<shell> -c
   <script>], where these genuinely re-parse (RFC §2.4), so the IR —
   which has no re-parse step — refuses them by name.  This refusal
   predates the opening of [$(...)]: a substitution that reaches one
   must meet the same closed vocabulary as any other construct. *)
let shell_builtins = [ "eval"; "source"; "." ]
...
| `Word bin_str ->
  if List.mem bin_str shell_builtins
  then Error (Stage_outside_subset (`Shell_builtin bin_str))
  else (match Exec_program.of_string bin_str with ...)
```

   Deliberately **not** in `Exec_program.of_string`: the typed argv lane spawns argv directly (no shell), where `eval` already fails as ENOENT; refusing there would change the argv lane, which the RFC does not ask for. Flagged in Risks.

- [ ] **Step 3:** Consumers of the new arm (compiler finds them; no catch-alls exist):
  - `lib/exec/command_gate/shell_command_gate.ml:173-188` `too_complex_reason_tag`: `| Unsupported_construct (`Shell_builtin _) -> "shell_builtin"` (stable census vocabulary).
  - `lib/exec_policy/exec_policy.ml:123-143` `block_reason_of_exec_too_complex`: add `| Unsupported_construct (`Shell_builtin _) -> Injection` — the Injection message already says shell-evaluation syntax is not accepted in the typed form. (A dedicated block_reason would ripple into `config/prompts/exec_policy.md` templates; Injection is the truthful class.)
  - `lib/keeper_tooling/subset_rewrite.ml:48-80` `of_construct`: new arm before the grouped one:

```ocaml
  | `Shell_builtin name as construct ->
    a_shell_is_the_answer
      construct
      (match name with
       | "eval" ->
         "eval re-parses its arguments in the running shell. The keeper \
          sandbox image already exports the switch environment (OPAMROOT, \
          OPAM_SWITCH_PREFIX), so drop the eval \$(opam env ...) wrapper \
          entirely"   (* RFC-shell-ir-typed-command-substitution §1/§3 *)
       | _ ->
         "source and . run text in the running shell; a shell runs this \
          line, so it does what you wrote — the typed argv form cannot \
          say it")
```

- [ ] **Step 4: Tests** (in `lib/exec/test/test_bash_parser.ml`, plain-assert style, registered in the runner at the bottom): `test_eval_refused_as_shell_builtin` (`eval $(opam env)` → `Too_complex (`Shell_builtin "eval")`), same for `source foo.sh` and `. foo.sh`; `test/test_subset_rewrite.ml`: add `` `Shell_builtin "eval" `` to the enumerated reason lists (lines ~24, ~45, ~130) and assert the advice mentions dropping the wrapper; `test/test_exec_shell_command_gate.ml`: tag check `"shell_builtin"`.

- [ ] **Commit 1:** `exec: refuse shell builtins (eval/source/.) by name before $( ) opens` — code + tests together. Push on the worktree branch; CI verifies.

## Task A2 (RFC PR-A) — `Subst` node + parser, dispatch still refuses typed

- [ ] **Step 1:** `lib/exec/shell_ir.ml`/`.mli`: regroup into a recursive type group (connector stays separate, before the group):

```ocaml
type arg =
  | Lit of string * arg_meta
  | Concat of arg list
  | Var of string * arg_meta
  | Subst of t
      (** Command substitution: the child is a complete IR — pipes,
          sequences and nested substitutions use the same grammar.  The
          child's stdout becomes exactly one argv element of the parent;
          there is no word splitting or glob after it (RFC
          shell-ir-typed-command-substitution §2.1, §2.3). *)

and simple = { bin : Exec_program.t; args : arg list; env : (string * arg) list
             ; cwd : Path_scope.t option; redirects : Redirect_scope.t list
             ; sandbox : Sandbox_target.t }

and t =
  | Simple of simple
  | Pipeline of t list
  | Sequence of { head : t; tail : (connector * t) list }
```

  - `with_sandbox` (shell_ir.ml:53-71): recurse into args and env values (`Subst child -> Subst (with_sandbox target child)`; `Concat` maps) — this is what makes the child inherit the parent's dispatch target (RFC §2.3 item 1); the `Delegated` exception is preserved inside children.
  - `arg_has_variable`/`has_variable_expansion` (73-87): merge into one `let rec … and` group; `Subst ir -> has_variable_expansion ir`.
  - `pp_arg` (89-95): `| Subst ir -> Format.fprintf fmt "$(%a)" pp ir` (needs `pp` in the same rec group or reordered; pp_arg/pp already need to become mutually recursive — combine them into one `let rec … and` group).
  - New, exported:

```ocaml
val subst_children_of_arg : arg -> t list
(** Direct [Subst] children of one arg, [Concat] flattened; children of
    children are reached by recursing on the result. *)

val has_command_substitution : t -> bool
(** Anywhere: arguments, environment prefixes, and every stage, recursively
    through nested substitutions. *)
```

  - mli header comment (lines 3-8): update the refusal enumeration — `$(...)` is now read into `Subst`; backticks, `$((...))`, `$1`, `${X:-y}` keep their refusals.

- [ ] **Step 2:** `lib/exec/parser/bash_lexer.mll`:
  - Header: add the hook and the refusal carrier:

```ocaml
  (* The recursive parse of a $( ) body.  A direct call to Bash.parse_string
     would close a module cycle (bash.ml drives this lexer) and add an
     unclassified caller to the shell-ir-consumption audit; the entry point
     installs this hook instead.  The hook shares this process's token
     budget — it must not reset the counter (RFC §2.4: source size is the
     only bound on nesting). *)
  let subst_parse_hook : (string -> Shell_ir.t Parsed.t) ref =
    ref (fun _ -> raise (Failure "subst_parse_hook unset"))
  exception Subst_inner_refusal of Shell_ir.t Parsed.t  (* never [Parsed _] *)
```

  - New rule `subst_body depth buf = parse`: quote-aware balanced scan. Arms: `"$("` → depth+1, copy; `'` sq body `'` → copy verbatim; `"` → delegate to a `subst_dq` sub-rule that copies until the closing `"` while still tracking nested `$(` (a `$(` inside dq inside subst must count); backtick region → copy verbatim to its closing backtick (the inner parse refuses it by name after the cut); `\\` any-char → copy both (escape outside quotes); `\n` → `Lexing.new_line lexbuf`, copy; `(` → depth+1; `)` → if `depth = 1` then stop and return `Buffer.contents buf` else depth-1, copy; `eof` → `raise (Failure "unterminated $( )")`; any other char → copy.
  - Helper producing the piece:

```ocaml
  let subst_piece lexbuf =
    incr_tokens ();
    let body = subst_body 1 (Buffer.create 256) lexbuf in
    match !subst_parse_hook body with
    | Parsed.Parsed ir -> Shell_ir.Subst ir
    | refusal -> raise (Subst_inner_refusal refusal)
    (* the inner refusal rides up unchanged: the same rules, the same
       reasons (RFC §2.2).  The re-parse target is the source the user
       wrote — never execution output. *)
```

  - Replace the three `"$("` exclusions: in `token` (line 163) → `word_tail (subst_piece lexbuf) [] lexbuf`; in `word_tail` → `word_tail first (subst_piece lexbuf :: rev_rest) lexbuf`; in `dq_pieces` (line 322) → piece-join like the `Var` arms (meta is irrelevant — `Subst` carries none; the result is one argv element quoted or not). Keep `` ` `` → `excluded `Cmd_subst` everywhere, and `"$(("` before `"$("` (longest match already orders them; keep the rule order and the comment).
  - Update the `dq_pieces` comment (lines 282-292) and the header doc: command substitution is no longer "its named refusal" for `$(`; only backticks keep `Cmd_subst`.

- [ ] **Step 3:** `lib/exec/parser/bash.ml`:
  - Split `parse_string` (179-192) into `parse_source` (no reset, current body) and:

```ocaml
let rec parse_source (source : string) : Shell_ir.t Parsed.t = ... (* as today, plus: *)
  (* | Bash_lexer.Subst_inner_refusal refusal -> refusal *)
let parse_string source =
  Bash_lexer.reset_tokens ();
  Bash_lexer.subst_parse_hook := parse_source;   (* reentrant: the hook re-enters here *)
  parse_source source
```

    (Set the hook before parsing; it is idempotent under recursion. Parsing is synchronous — no Eio yield — so the global ref cannot be observed mid-swap. Note this in a comment.)
  - `arg_as_assignment` (37-68): add `| Shell_ir.Subst _ -> None` and extend the leading-piece refusal arm to `(Shell_ir.Var _ | Shell_ir.Concat _ | Shell_ir.Subst _) :: _` (a binding name is literal text; `$(x)=1` assigns nothing in bash either).
  - `raw_to_simple` bin match (96-101): `| Shell_ir.Subst _ -> Error (Stage_outside_subset `Cmd_subst)` — a substituted program name is not opened by this RFC (`$(cmd) args` stays refused).
  - `value_of_pieces` unchanged — a single `Subst` piece stays `Subst`, so `VAR=$(cmd)` lands as `env = ["VAR", Subst _]` via the existing `Concat`-split path.

- [ ] **Step 4: PR-A typed refusal (removed in Task B):**
  - `lib/exec/command_gate/shell_command_gate.ml` `structural_refusal` (223-239): prepend `if SI.has_command_substitution ir then Some (`Too_complex (Unsupported_construct `Cmd_subst)) else …`. This is the RFC §3 "dispatch가 Too_complex로 돌려보낸다" — it surfaces through `Keeper_tooling.Execute_shell_ir.dispatch`'s existing `Too_complex` arm. Reusing the `cmd_subst` tag keeps the census vocabulary stable while execution is closed. Also make the gate's local `with_sandbox` (63-72) and `simples_of` (74-80) recurse into Subst children now (so the refusal cannot be bypassed by shape, and PR-B is a deletion plus traversal).
  - `lib/exec/exec_dispatch.ml`: mirror-guard at the top of `dispatch_simple`, `dispatch_pipeline`, `dispatch` (next to the existing `has_variable_expansion` checks): `if Shell_ir.has_command_substitution … then { status = Unix.WEXITED 2; stdout = ""; stderr = "command substitution is parsed but this dispatcher does not execute it yet"; output_files = None }` (mirrors `unsupported_expansion_result`, line 295-300; the typed refusal lives in the gate, this is the defensive lower layer). `resolve_arg` gains `| Subst _ -> invalid_arg "Exec_dispatch.resolve_arg: unevaluated substitution"` next to the `Var` arm.

- [ ] **Step 5: Remaining compile-driven `arg` consumers** (all exhaustive; no `_ ->`):
  - `lib/exec_policy/exec_policy.ml:88-93` `shell_ir_arg_has_unquoted_glob`: `| Subst _ -> false` with comment: the substituted text is one literal argv element and this IR has no re-split/glob stage (RFC §2.3 item 3, same argument as param-expansion RFC §6).
  - `lib/exec_policy/exec_policy_literal_words.ml:5-14`: `Shell_ir.Subst _ :: _ -> None`; `flat_stage_words` (16-29): also descend into `subst_children_of_arg` of each stage's args/env so log sanitizing (`exec_policy_log_sanitize.ml:88-92`) still sees child words.
  - `lib/keeper/keeper_shell_tool_command.ml`: `literal_words` (62-66) → `Subst _ :: _ -> None` (a masc stage's words must be literal — a tool path cannot come out of a substitution); `contains_masc` (180-187) and `rewrite` (205-281): descend into Subst children; a `masc` stage inside a `$(` → `Error "a masc stage cannot join a command substitution yet; call the tool directly and pass the value as a literal word"` (RFC silent — see Risks; the alternative of silently hosting it is the #32730 failure mode).
  - `lib/keeper/keeper_gate_readonly.ml`: `literal_of_arg` (341-354) → `Ir.Subst _ -> None`; `env_assignments_inert` (427-435) → `Ir.Subst _ -> false`. (Child classification arrives in Task B; in PR-A the gate refuses Subst anyway so these arms are unreachable through `classify_script` — still written exhaustively, per RFC §2.1.)

- [ ] **Step 6: Parser tests** in `lib/exec/test/test_bash_parser.ml` (flip two, add ~10; register each in the bottom runner):
  - FLIP `test_cmd_subst_paren_rejected` → `test_cmd_subst_parses_to_subst_node`: `echo $(date)` → `Parsed (Simple s)` with `s.args = [Subst (Simple date-stage)]`.
  - FLIP `test_double_quote_cmd_subst_named` (line 509): `"$(date)"` now parses to `[Subst _]`.
  - KEEP `test_cmd_subst_backtick_rejected`, `test_double_quote_with_backtick_rejected` unchanged (`` `Cmd_subst `` still their reason).
  - `test_cmd_subst_env_assignment_value`: `A=$(echo x) printenv A` → `env = ["A", Subst _]`.
  - `test_cmd_subst_nested`: `echo $(echo $(printf x))` → two levels of `Subst`.
  - `test_cmd_subst_inner_exclusion_rides_up`: `echo $(cat <<EOF)` → `Too_complex `Heredoc`; `echo $(echo $HOME)` → `Too_complex `Param_expansion`; `echo $(echo \`date\`)` → `Too_complex `Cmd_subst`.
  - `test_cmd_subst_unterminated_is_parse_error`: `echo $(date` → `Parse_error _`.
  - `test_cmd_subst_in_bin_position_refused`: `$(echo x) arg` → `Too_complex `Cmd_subst`.
  - `test_cmd_subst_shares_token_budget`: a `$(` body with enough words that outer+inner exceed 50_000 → `Parse_aborted `Token_limit_50k`.
  - `test_pp_prints_subst`: `Format.asprintf "%a" Shell_ir.pp ir` on a parsed `echo $(date)` contains `$(` — locks the new `pp_arg` arm.
  - Gate tests in `test/test_exec_shell_command_gate.ml`: PR-A — a hand-built Subst-bearing IR through `gate_typed` yields `Too_complex` with tag `"cmd_subst"`.

- [ ] **Step 7: Corpus regression evidence** (RFC §3 "코퍼스 재실행(회귀 0 증명)"): the corpus is `<base-path>/.masc/tool_calls/2026-{08,09}/*.jsonl` and the tool is `tools/costume_census` (per `docs/rfc/RFC-shell-ir-lines-heredoc-dquote.md:7-9`). On the branch, run the census before/after and attach the two tables to the PR: `cmd_subst` ~62 → only backtick residue, `shell_builtin` = 16 (the eval/opam cases), every other bucket unchanged. In CI, regression-0 is proven by the pinned disposition tables (`test/test_shell_costume.ml`, `lib/exec/test/test_bash_parser.ml`): every previously-`Parsed` source still parses identically. Note in the PR that the costume table flips land in Task B, so PR-A keeps `"echo $(date)" = "cmd_subst"` green.

- [ ] **Commit 2:** `exec: parse $( ) into Shell_ir.Subst (PR-A; execution stays a typed refusal)` — code + tests, push, CI.

## Task B (RFC PR-B) — dispatch evaluates, gate traverses, observation classifies children

- [ ] **Step 1:** `lib/exec/exec_dispatch.ml`:
  - Restructure: `dispatch_simple` joins the existing `let rec dispatch_pipeline … and dispatch_sequence … and dispatch …` group as `and dispatch_simple`, and add `and eval_substitutions`. New core:

```ocaml
(* bash's rule: all trailing newlines go, nothing else is touched. *)
let strip_trailing_newlines s =
  let len = ref (String.length s) in
  while !len > 0 && String.get s (!len - 1) = '\n' do decr len done;
  String.sub s 0 !len

(* What is left of the parent's budget when a child starts (RFC §2.3 item 4).
   NDT: wall clock is budget arithmetic only, never a policy decision.
   Verify Process_eio's behavior for a nonpositive timeout when
   implementing; if it rejects one, clamp to a small positive floor with a
   comment, or synthesize its timeout result — do not invent a number. *)
let remaining_timeout ~started = function
  | None -> None
  | Some budget -> Some (budget -. (Unix.gettimeofday () -. started))

and eval_substitutions ?base_host_env ?timeout_sec ~started (s : Shell_ir.simple)
  : Shell_ir.simple * string =
  (* env bindings before arguments: the order they appear on the line.
     Each child runs through the full dispatcher, so a pipeline, a sequence
     or a nested substitution inside means exactly what it means at the top
     level.  The child inherits the parent's sandbox target by construction
     (Shell_ir.with_sandbox reaches Subst children); re-applying it here
     keeps the invariant true for a hand-built IR.  No byte cap on the
     child's stdout: ARG_MAX is the natural bound (RFC §2.4).  The child's
     output is never streamed to the parent's callback — it is data that
     becomes argv, not output. *)
  let child_stderr = Buffer.create 256 in
  let rec eval_arg = function
    | Shell_ir.Subst child ->
      let child = Shell_ir.with_sandbox s.sandbox child in
      let result = dispatch ?base_host_env ?timeout_sec:(remaining_timeout ~started timeout_sec) child in
      Buffer.add_string child_stderr result.stderr;
      Shell_ir.Lit (strip_trailing_newlines result.stdout, Shell_ir.default_meta)
    | Shell_ir.Concat parts -> Shell_ir.Concat (List.map eval_arg parts)
    | (Shell_ir.Lit _ | Shell_ir.Var _) as leaf -> leaf
  in
  let env = List.map (fun (k, v) -> k, eval_arg v) s.env in
  let args = List.map eval_arg s.args in
  ({ s with Shell_ir.env; args }, Buffer.contents child_stderr)
```

  - `dispatch_simple` front (line 359-363): after the `has_variable_expansion` check, replace the PR-A guard with:

```ocaml
  let started = Unix.gettimeofday () in
  let s, child_stderr = eval_substitutions ?base_host_env ?timeout_sec ~started s in
  … existing body …
  let result = { result with stderr = child_stderr ^ result.stderr } in  (* children ran first *)
  emit_unseen_captured_output on_output_chunk emitted result
```

    (`resolve_env`/`process_spec_of_simple` then see only Lit/Concat; `resolve_arg`'s `Subst -> invalid_arg` arm stays as the unreachable-by-construction witness.)
  - Pipeline guards: in `host_pipeline_specs` (548-580) and `sandbox_pipeline_specs` (585-612), decline a stage with `Shell_ir.has_command_substitution (Shell_ir.Simple simple)` (→ `None`, per-stage chain fallback) — the chain calls `dispatch_simple`, which evaluates. Comment: a stage whose argv is known only after running its children cannot join a pre-spawned process pipe. Remove the PR-A guards from `dispatch_pipeline`/`dispatch`.
  - `exec_dispatch.mli`: extend the `dispatch`/`dispatch_simple` docs: `Subst` children are evaluated before the parent's argv is built; `resolve_arg` doc gains "and unevaluated substitutions".
  - Path-jail note (RFC §2.4 bullet 2): add a comment at `eval_substitutions` — redirect targets and `cwd` are literal-only by grammar, and `Exec_policy.validate_shell_ir_paths` (exec_policy.ml:260-324) validates exactly those two, so there is no argv path jail for a substituted value to re-pass; if one is added, it must run at this resolve point (param-expansion RFC §3.2). This is a doc comment, not code — see Risks.

- [ ] **Step 2:** `lib/exec/command_gate/shell_command_gate.ml`: delete the PR-A `has_command_substitution` refusal from `structural_refusal`; make `check_syntax` (100-123) recurse into each stage's Subst children via `SI.subst_children_of_arg` (a `$(a | b)` under `allow_pipes=false` rejects as `Pipes`, a redirect inside under `redirect_allowed=false` as `Redirect`). mli: update the `Too_complex` doc line that still names `cmd_subst` among excluded constructs → name the backtick explicitly.

- [ ] **Step 3:** `lib/keeper/keeper_gate_readonly.ml` (RFC §2.5): in `classify_simple` (437-447):

```ocaml
let classify_simple (simple : Ir.simple) =
  let children =
    List.concat_map Ir.subst_children_of_arg
      (simple.Ir.args @ List.map snd simple.Ir.env)
  in
  match List.find_map (fun child -> match classify_ir child with
            | Needs_observation _ as c -> Some c | Static_observation -> None) children with
  | Some classification -> classification
    (* a child that needs the judge makes the whole call wait (RFC §2.5) *)
  | None ->
    if children <> [] then Needs_observation Unproven_request
      (* every child is a static observation, but the value it yields is
         unknown until it runs, so the parent's argv cannot be proven from
         the line; the boxed-observation path owns this call *)
    else … existing body …
```

  Mutual recursion note: `classify_simple`/`classify_ir`/`classify_stages` become one rec group (they nearly are).

- [ ] **Step 4:** `lib/exec/shell_ir_oracle.ml`: remove `"command_substitution", f.command_substitution` from `structural_feature_blockers` (208-219) — the feature is representable now. Go sidecar unchanged (it reports facts; OCaml owns the verdict). Adjust `lib/exec/test/test_shell_ir_oracle.ml` expectations accordingly (read the fixture expectations when editing; no `command_substitution` fixture exists, so this is likely a pure deletion plus a new small case asserting a `command_substitution:true` fact is no longer a blocker).

- [ ] **Step 5: Test flips and additions:**
  - `test/test_shell_costume.ml`: line 87 `"echo $(date)"` `"cmd_subst"` → `"representable"`; line 118 `"echo $(date) > out.txt"` → `"representable"`; update the measured-table comment (the `cmd_subst` row's absence is now the point; keep the historical note style used there).
  - `test/test_keeper_tool_execute_typed_input.ml`: line 529 expectation `Outside_the_subset (Unsupported_construct `Cmd_subst)` → `Representable`; refresh the stale comment at 1049-1050 ("cannot be held in IR" — now it can; the lowered bin stays `"sh"` because scripts still run under the real shell).
  - `test/test_keeper_gate_readonly.ml`: add — `echo $(date)` → `Needs_observation Unproven_request` (child static, value unproven); `echo $(git status)` → `Needs_observation (Git_command_requires_execution Status)` (child reason propagates); a pure-literal command still classifies `Static_observation` (guard against regression).
  - New `lib/exec/test/test_shell_ir_subst_exec.ml` (register in `lib/exec/test/dune` `(names …)`; style: plain asserts like `test_bash_parser.ml`; end-to-end through `Bash.parse_string` + `Exec_dispatch.dispatch`, mirroring `test_semicolon_three_stages_dispatch`):
    - `test_subst_roundtrip`: `echo $(echo hi)` → status `WEXITED 0`, `String.trim stdout = "hi"`.
    - `test_subst_strips_trailing_newlines`: `echo $(printf 'a\n\n')` → stdout `"a\n"`.
    - `test_subst_is_one_argv_element_no_resplit`: `printf '%s|' $(printf 'a b')` → stdout `"a b|"` (word splitting would give `"a|b|"`).
    - `test_subst_child_failure_does_not_fail_parent`: `echo $(false)` → status 0, stdout `"\n"` (RFC §2.3 item 2).
    - `test_subst_child_stderr_joins_parent_stderr`: `echo $(ls /nonexistent-masc-test-dir)` → parent status 0, stderr contains the child's message.
    - `test_subst_env_value`: `MASC_SUBST_T=$(echo ok) printenv MASC_SUBST_T` → stdout `"ok"`.
    - `test_subst_in_sequence_and_pipeline`: `echo $(echo a) && echo b` → `"a\nb"`; `echo $(echo hi) | cat` → `"hi"` (proves the chain-fallback path).
    - `test_subst_nested`: `echo $(echo $(printf deep))` → `"deep"`.
    - `test_subst_timeout_budget_propagates`: `echo $(sleep 5)` with `~timeout_sec:0.2` → `status_is_timeout result.status` (pattern after the slow-stage tests in `test/test_exec_dispatch.ml`).
    - `test_subst_child_inherits_parent_sandbox`: hand-build parent `Simple` with `sandbox = Sandbox_target.delegated ~caller:spy`, arg `Subst (Simple …)`; the spy runner records argv and answers `Ran` — assert the child reached the same runner and the parent's argv carried the substituted literal.
    - `test_with_sandbox_reaches_subst_children`: pure — `Shell_ir.with_sandbox` on a parsed Subst-bearing IR rewrites the child's `sandbox` field.
  - `test/test_keeper_shell_tool_command.ml`: `rewrite` refuses a `masc` stage inside `$(` with the named error; `refuse_reserved_command` catches a hand-built `$(masc …)`.

- [ ] **Step 6: RFC status:** `docs/rfc/RFC-shell-ir-typed-command-substitution.md` line 3 → `상태: 구현 완료 (PR-A + PR-B)`. No TLA change; state in the commit message that `ShellIRFirstClass.tla` models the boundary state machine, not arg shapes, and the audit's `tla_spec_exists` check is untouched.

- [ ] **Commit 3:** `exec: dispatch evaluates $( ) — one argv element, no re-split (PR-B)` — code + tests, push, CI.

## Verification & constitution compliance

- No local build loops: each commit carries implementation + tests together; CI runs the suite. The three commits land in order on one worktree branch (A1 must precede A2 per RFC §2.4).
- Closed sums everywhere: every new arm is spelled out; the compiler enumerates consumers (`arg` has no catch-all in any consumer — verified: bash.ml:64-68 spells its refusal arms for exactly this reason).
- Effects at boundaries: IR + lexer/parser stay pure (the hook returns `Parsed.t` values); all execution is in `exec_dispatch.ml`.
- No undocumented magic numbers: the only numbers are the existing 50k token budget (reused per RFC §2.4) and the timeout floor — the latter only after reading `Process_eio`'s timeout semantics, with a comment citing RFC §2.3 item 4.

## Risks / open questions

1. **RFC vs. code reality — the "path jail re-validation" (§2.4) is vacuous today.** The RFC says a substituted value landing in a path argument re-passes "the same jail validator" per param-expansion RFC §3.2. Current `validate_shell_ir_paths` checks only `cwd` and redirect targets — both literal-only by construction. There is no argv path jail to re-apply. Plan handles this with a doc comment; if the reviewer expects an actual argv jail, that is new scope beyond this RFC.
2. **RFC vs. code reality — dispatch-level substitution has no production caller yet.** Keeper scripts execute under real `sh -c` (`keeper_tool_execute_typed_input.ml:309-311`), which already performs `$()`. PR-B's semantics make the IR honest (gate-allowed ⇒ dispatchable) and are exercised by direct `Exec_dispatch` callers and the new tests. The immediate production effect of the whole unit is in classification (`keeper_gate_readonly`), the docker-bash policy gate (`keeper_sandbox_docker.ml:395`), and the costume census — matching the RFC's measured motivation (parse acceptance 76.5% → ~84%).
3. **`$(masc tool …)` is unaddressed by the RFC.** Decision (documented in code): the keeper shell-tool rewrite refuses a `masc` stage inside a substitution with a named error, and `contains_masc`/`refuse_reserved_command` descend into Subst children so the #32730 silent-host-execution failure mode cannot recur. Opening delegated substitution is a follow-up RFC.
4. **Balanced-scan hazard: `case` item `)` inside `$( )`.** Plain paren counting mis-cuts `$(case x in a) … esac)`. The mis-cut is fail-closed in practice — the remainder hits `;;` (Parse_error) or `)` (`` `Subshell ``) — and the subset's 511-corpus shapes are simple commands. Documented in the scanner comment; if the corpus re-run shows a `case`-in-substitution, that is new scope.
5. **`Shell_builtin` placement.** Refusal is at the parser's bin position, not in `Exec_program.of_string` — the RFC's mention of `of_string` is descriptive context; putting it there would also change the typed argv lane, which the RFC does not ask for. Flagged for review.
6. **Hook ref is global mutable state in the lexer header.** Justified: parsing is synchronous with no Eio yield points, and it avoids both the bash↔lexer module cycle and a new `Bash.parse_string` caller that would trip `scripts/audit-shell-ir-consumption.sh` (CI-enforced baseline). Alternative would be functorizing the lexer — much larger diff for no semantic gain.
7. **Timeout floor semantics** need one read of `Process_eio`'s timeout handling during implementation (nonpositive `timeout_sec` behavior) before choosing clamp vs. synthesized timeout result.
8. **`Subst` in `Concat` for env binding values** relies on the existing `arg_as_assignment` Concat split; the `Concat []` and leading-nonliteral arms gain `Subst` explicitly — the compiler enforces this, but the env-prefix tests above pin the behavior (`A=$(echo x) cmd` works, `$(x)=1 cmd` refuses as bin-position substitution).
