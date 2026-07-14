# RFC-0198: Execute Typed Redirection (Shell IR Syntax Leakage Closure)

**Status**: Draft
**Date**: 2026-05-27
**Meta-RFC**: [RFC-0194](./RFC-0194-tool-surface-semantic-ssot.md) §1 (Typed SSOT) + §3 (Dispatch layer is explicit, not inferred) — *inner-layer* instantiation
**Sibling**: RFC-0196 (outer dispatch_layer: Claude_api_native | Masc_structured | Shell_executable_argv)
**Memory anchors**: `feedback-surgical-workaround-rejected-for-tool-surface`

## Context

`masc` 의 `Execute` tool 은 RFC-0091 PR-1 에서 *typed argv schema* (execve semantic) 로 narrow 했다. `agent_tool_execute_typed_input.mli:13-20` 가 design constraint 를 명시:

> Each token in `argv` is passed verbatim to the child process; the implementation invokes the executable directly (no `/bin/sh -c "..."` wrapping). Therefore shell metacharacters like `*`, `?`, `|`, `&`, `;`, `>`, `<`, `` ` ``, `$` inside an argv token are *literal characters*, not shell operators.

이 contract 는 *architecturally correct* — execve(2) 의 정확한 모델. 그러나 LLM 에는 이 sub-layer 경계가 *invisible*:

```
LLM 의 mental model:
   "Execute 는 shell. ls/find/cat 같은 unix util 부른다."
   → "find . -name '*.ml' 2>/dev/null 같은 표현이 자연"

실제 typed argv contract:
   {executable: "find", argv: [".", "-name", "*.ml", "2>/dev/null"]}
   → "2>/dev/null" 이 find 의 *primary expression* 으로 해석 → 런타임 실패
```

## Fleet evidence

Bash parser 는 `Bash.parse_string "rg foo 2>/dev/null"` 을 *정확히* `redirects = [Redirect_scope.File { fd = 2; target = "/dev/null"; mode = Write }]` 로 분리한다 (`lib/exec/test/test_bash_parser.ml:151-158` 통과). 즉 *기능 부재가 아니라 entry point mismatch*. Typed argv path 가 `Bash.parse_string` 을 *우회*.

### Symptom (2026-05-27 ~18:56 KST live log)

```
[2026-05-27 18:56:15] [Keeper] shell_ir dispatch keeper=executor sandbox=local status=exit=1 elapsed_ms=64
[2026-05-27 18:56:15] [Keeper] keeper:executor tool_call tool=Execute
  params=[argv,executable] input_shape=[argv=array:6,executable=string:4]
  outcome=error
  error_preview={"ok":false,"error":"find: 2>/dev/null: unknown primary or operator\n",...}
```

`executable=string:4` = `"find"`, `argv=array:6` 의 마지막 토큰이 `"2>/dev/null"` 로 추정. `find` 가 이를 *primary* 로 해석 → exit 1 → 1620 byte error JSON 이 다음 turn context 로 누수.

### Related cluster

Issue #18892 (sandbox playground missing-file ENOENT, 15 ERROR/day) 와 같은 *dispatch layer 미인지* root 의 다른 surface — 같은 cluster 로 merge.

## Three remediation paths (incremental, RFC-0194 정합)

본 RFC 는 *single PR* 가 아닌 *phased coverage* 로 진행. 각 Phase 는 RFC-0194 의 다른 principle 을 instantiate.

### Phase A (P1): Surgical redirection-shape token reject

**Principle**: RFC-0194 §1 (typed SSOT 가 *control-flow gate* 에 위치).

`shell_metachar_in_token` (`lib/keeper/keeper_tool_execute_typed_input.ml`) 의 현재 형태는 *NUL* 만 거부. LF/CR 과 shell metacharacter 는 execve argv literal data 이다. 본 Phase 는 *redirection-shape pattern* 을 추가 거부:

| 거부 token shape | 예시 |
|---|---|
| `^[0-9]?>>?$` | `>`, `>>`, `2>`, `2>>` |
| `^[0-9]?<$` | `<`, `0<` |
| `^[0-9]?>&[0-9]+$` | `2>&1`, `>&2` |
| `^[0-9]?>/`, `^[0-9]?>./` | `2>/dev/null` 같은 *attached path* |
| `^&[0-9]+$` | `&1`, `&2` |

#### Rationale

LLM 이 *legitimate `find -name '*>foo'`* 같은 케이스에서 `'>foo'` 를 argv token 으로 보낼 *이론적* 가능성은 있으나 fleet evidence 0건. 본 reject 는 *false-positive* 보다 *true-positive* 비율이 압도적.

#### Typed error path

`Argv_contains_shell_metachar` 의 hint 가 *typed alternative* 로 emit:

```ocaml
| Argv_contains_shell_metachar { executable; index; token } when looks_like_redirection token ->
    workflow_rejection_error_json
      ~rule_id:"argv_shell_redirection_rejected"
      ~alternatives:[ Tool_name.Execute_with_pipeline; Tool_name.Execute_with_redirection_field ]
      (Printf.sprintf
         "executable %S argv[%d]=%S is a shell redirection token. \
          Use the typed redirection field (RFC-0198 Phase B) or split into a pipeline."
         executable index token)
```

#### Test plan

- `test_shell_redirection_token_rejected.ml`: 5 redirection shape × pass-through 거부 확인
- `test_legitimate_metachar_still_allowed.ml`: `*.ml`, `'$HOME'`, `;abc` 같은 *literal* token 은 통과 (regression guard)
- `test_redirection_token_emits_typed_alternative.ml`: error JSON 이 `alternatives` 필드 carry

### Phase B (P0): Typed redirection schema field

**Principle**: RFC-0194 §3 (Dispatch sub-layer 가 *typed field* 로 carry, prose paraphrase 아님).

`execute_input` schema 에 redirection field 추가:

```ocaml
type redirect_target =
  | Discard            (* /dev/null equivalent, fd-agnostic *)
  | File of string     (* absolute path, validated *)
  | Inherit            (* default — passthrough *)

type execute_input =
  | Exec of {
      executable : string;
      argv : string list;
      cwd : string option;
      env : (string * string) list;
      stdin  : redirect_target;   (* default Inherit *)
      stdout : redirect_target;   (* default Inherit *)
      stderr : redirect_target;   (* default Inherit *)
    }
  | Pipeline of { ... }           (* unchanged *)
```

JSON shape:

```json
{
  "argv": ["find", ".", "-name", "*.ml"],
  "stderr": {"discard": true}
}
```

또는 더 narrow:

```json
{
  "argv": ["find", ".", "-name", "*.ml"],
  "discard_stderr": true
}
```

#### Implementation surface

| File | 변경 |
|---|---|
| `lib/keeper/agent_tool_execute_typed_input.ml` / `.mli` | `redirect_target` type + field 추가, `of_json` 확장 |
| `lib/keeper/agent_tool_execute_shell_ir.ml` | redirect 필드 → `Shell_ir.simple.redirects` 변환 |
| `lib/exec/shell_ir.ml` | 이미 `redirects : Redirect_scope.t list` carry — 변경 0 |
| `lib/exec/exec_dispatch.ml` | redirect 처리 이미 존재 (Bash parser path 와 공유) |
| Descriptor (RFC-0195 합치) | Execute 의 `examples` 에 typed field 사용 예시 |

#### Backward compat

`stdin/stdout/stderr` 모두 *optional, default Inherit* — 기존 caller 변경 0건. 새 field 미사용 시 100% 기존 동작.

#### Test plan

- `test_execute_typed_stderr_discard.ml`: `{executable: "find", argv: [...], discard_stderr: true}` 가 `/dev/null` redirect 와 equivalent
- `test_execute_typed_stdout_file.ml`: 절대경로 file redirect, relative path reject
- Exhaustiveness: `redirect_target` variant 추가 시 build fail (principle §5)

### Phase C: Descriptor enrichment (RFC-0195 흡수)

**Principle**: RFC-0194 §2 (Descriptor `examples` + `alternatives` 가 selection guidance, prose hint 아님).

RFC-0195 task #14 의 Execute descriptor entry 에 다음 examples:

```ocaml
{ tool_name = Tool_name.Keeper Keeper.Execute;
  when_to_use = "Run an allowlisted binary with typed argv. Each argv token is execve-literal — no shell expansion.";
  examples = [
    "find . -name '*.ml'                            (*  ✓ glob is find-internal  *)";
    "{executable: \"find\", argv: [\".\", \"-name\", \"*.ml\"], discard_stderr: true}";
    "❌ argv: [..., \"2>/dev/null\"]                (*  ✗ shell redirection — use discard_stderr  *)";
    "❌ argv: [..., \"|\", \"head\"]                 (*  ✗ shell pipe — use Pipeline mode  *)";
  ];
  alternatives = []; (* terminal in success path; Phase A error emits typed alts *)
  ...
}
```

Negative example 이 *typed signal* — LLM 의 mental model 을 *typed argv vs shell-string* 경계로 명시적으로 끌어옴.

## Sub-RFC dependency

```
RFC-0194 (Meta, principles)
    ├── RFC-0193  §1  substring sunset (independent)
    ├── RFC-0195  §2  descriptor enrichment ← Phase C 흡수
    ├── RFC-0196  §3  outer dispatch_layer taxonomy (Claude/Masc/Shell)
    └── RFC-0198  §1+§3  inner Shell sub-layer (typed argv vs shell-string)
            ├── Phase A  surgical reject (independent)
            ├── Phase B  typed redirect field (independent)
            └── Phase C  Execute descriptor entry  ← RFC-0195 합치
```

Phase A/B 간 dependency 없음. Phase C 는 *RFC-0195 PR 안에 흡수*.

## Verification

### Phase A

- **Fleet metric**: `argv_shell_redirection_rejected` typed event rate, 7d. Target ≥90% of current `unknown primary`-style runtime failures.
- **OCaml test**: 5 redirection shape rejected + 5 literal metachar still allowed (regression guard).
- **Build-time**: `Argv_contains_shell_metachar` variant 의 redirection-shape arm 이 exhaustive match 강제.

### Phase B

- **Fleet metric**: `discard_stderr`/`stdout: {file: ...}` typed field usage rate vs `tee`/`>` Pipeline 사용 rate. Target ≥70% (7d) — LLM 이 typed field 채택.
- **OCaml test**: 3 redirect_target variant × 3 fd (stdin/stdout/stderr) 9 combination expect-test.
- **Equivalence test**: `{argv:[...], discard_stderr:true}` 결과 = `Bash.parse_string "cmd ... 2>/dev/null"` 결과.

### Phase C

- **Review-time only**. RFC-0195 PR body 가 RFC-0198 reference + negative example 포함.

## ROA Boundary (RFC-0194 §"ROA" 재확인)

- **Probabilistic (LLM)**: Execute 선택, redirect 필요성 판단, descriptor 의 `examples` 참조 후 typed field 또는 pipeline 선택.
- **Deterministic (Runtime)**: schema validation (redirect_target variant exhaustive), absolute-path enforcement (File redirect), execve passthrough.

Phase B 의 typed field 는 *deterministic boundary* 를 *확장* — 기존 shell-string parsing 의 일부를 *typed schema* 로 가져옴. LLM reasoning 영향 없음.

## Out of scope

- Bash parser path 의 entry point 신설 (현재 `Bash.parse_string` 은 *internal* — external surface 추가는 별도 RFC 후보)
- Pipeline 안에서의 per-stage redirect (현재는 stage-level argv 만, 후속 RFC)
- Heredoc / process substitution (`<()`) — execve 모델 밖, 명시적 reject

## Implementation order (recommended)

1. **Phase A surgical PR** — 1-day work, fleet impact 즉시. Independent merge.
2. **Phase B typed field PR** — 2-3 day work, schema + executor wiring. Independent of Phase A but benefits from A 의 typed alternative emit pointing to Phase B field.
3. **Phase C** — RFC-0195 PR 안에 흡수, 별도 PR 없음.

## References

- RFC-0091 (Typed argv schema 도입)
- RFC-0194 (Meta, principles)
- RFC-0195 (Descriptor enrichment — Phase C 흡수)
- RFC-0196 (Outer dispatch_layer)
- Issue #18892 (sandbox playground missing-file, sibling cluster)
- `lib/keeper/agent_tool_execute_typed_input.mli:13-20` (design constraint anchor)
- `lib/exec/test/test_bash_parser.ml:151-187` (redirection parsing proof)
- CLAUDE.md §워크어라운드 거부 기준 §3 (N-of-M — Phase A/B/C 의 단일 결정으로 누적 차단)
- 메모: `feedback-surgical-workaround-rejected-for-tool-surface`
