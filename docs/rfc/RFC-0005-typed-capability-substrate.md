# RFC-0005: Typed Capability Substrate for Local Exec Core

**Status**: Draft
**Date**: 2026-04-17
**Scope**: `lib/exec/` (신규 internal sub-library), `lib/process/`, 87 Process_eio / Unix.* exec 사이트, `Tool_dispatch` handler 시그니처, `Keeper_approval_queue` source 필드 확장
**One sentence**: LLM이 emit하는 bash 입력을 OCaml 5 typed IR (`Bin`/`Path_scope`/`Shell_ir`/`Capability`/`Verdict`)로 강제 변환하고, capability extraction → approval policy → 중앙 executor를 거쳐 문자열 substring 방어에서 **타입 수준 fail-closed 증명**으로 이동하는 8-11주 리팩터링.

## Related Documents

- `./RFC-0001-det-nondet-boundary-harness.md` — Det/NonDet 경계
- `./RFC-0002-keeper-state-machine.md` — keeper lifecycle
- `./RFC-0004-shared-contract-ocaml-ts.md` — dashboard OCaml↔TS 계약
- `../CAPABILITY-REGISTRY-SSOT.md` — `Capability_registry.risk_class` SSOT
- Draft PRs:
  - #8083 — T0 observational tap
  - #8087 — A0 typed IR skeleton
  - #8099 — `test_ci_hardening_source` ratchet fix (unblocker)

## Status Note

이 문서는 구현 승인 전 합의용 RFC다.

- 이 RFC가 승인되기 전에는 추가 코드 변경을 진행하지 않는다.
- T0 (empirical tap)는 RFC 승인과 독립적으로 merge 가능 — 관측만 수행하고 프로덕션 동작 변경 0.
- A0 skeleton은 typed IR 계약을 세우며 consumer가 아직 없으므로 파일 추가만. RFC 승인 전엔 A1 이후 단계 진입 금지.
- 번호 체계가 변경되면 rename 한다.

## Context

masc-mcp의 LLM 도구 실행 경로는 현재 문자열 중심 검증이다. 실측:

- `Process_eio.run_argv*` 호출 **78 사이트** (28 lib 파일)
- `Unix.create_process`, `Unix.open_process_*`, `Unix.system` 등 **9 사이트**
- **합계 87 사이트** (이전 plan의 99는 드리프트, 실측 정정)
- `Tool_dispatch.handler` 시그니처 `(bool * string) option` — 14 파일에서 legacy tuple 전파 (`lib/tool_dispatch.ml:14`)
- Typed tool producer 단 **1개** (`lib/typed_tool_masc.ml`, broadcast는 consumer)
- `lib/eval_gate.ml:132` substring 정규화 + 18 destructive 패턴 — `${IFS}`/base64 **일부** 검사 있음, nested-quote false negative 잔존
- 5종 LLM CLI 공개 guardrail-bypass class (substring matcher 우회 기법 알려져 있음)

**RFC 목표**: LLM이 emit하는 bash 입력을 typed IR로 **강제 변환**, capability extraction → approval policy → 중앙 executor. 문자열 substring 방어에서 **타입 수준 fail-closed 증명**으로 이동.

**Location 확정: `masc-mcp/lib/exec/` 내부 서브트리**. 별도 repo 없음. tree-sister / masc-exec-gate 등 분리 옵션 전부 reject. 본질은 masc-mcp 실행 경계 일원화 + typed dispatch이므로 분리는 소비자 2+ 발생 & 유지 비용 < 통합 혼잡도 증명 후에만 추출. tree-sitter 비교 공격 표면을 naming 레벨에서 제거.

**핵심 차별화 — OCaml 5 타입 경계**:
- `Parsed.t = Parsed of 'a | Parse_error | Parse_aborted | Too_complex` sum type — 소비자 exhaustive match 강제
- `Bin.t` opaque — unknown bin → `risk_class = Privileged` → Ask (변환 site 한 곳에만)
- `Verdict.t = Allow of approved | Ask of request | Deny of reason` 3-way
- `type trusted_argv = private { bin: Bin.t; args: Arg.t list }` smart ctor만
- Layer 1 functor: `module Extract (L : LANGUAGE) : CAPABILITY_SOURCE` — bash만 instantiate, 2번째 언어는 미래
- Layer 2-3: parametric over Layer 1

**이전 plan 사실 정정**:
| 항목 | 오류 | 정정 |
|-----|-----|------|
| exec 사이트 | 99 | **87** |
| Typed_tool producer | 2 | **1** |
| Semgrep 라이선스 | LGPL/GPL3 혼용 | core=**LGPL-2.1**, semgrep=**GPL-3.0** (sibling 별개) |
| Wagner GLR | "base algorithm" | **incremental reparse layer만**, base는 LR(1)+conflict |
| Menhir subset 불가 | 절대 | **subset은 가능** — Morbig SLE 2018 |
| MCP approval | "서버 책임" | **host/client 책임** |
| eval_gate.ml | "substring only" | regex+부분 검사 있음, nested-quote FN 잔존 |
| 별도 repo (tree-sister 등) | 분리 가치 증명 없음 | **masc-mcp 내부 `lib/exec/`** |

## Thesis (fixed)

1. Internal canonical = typed IR + Verdict, not raw string
2. Bash = 여러 frontend 중 하나 (Layer 1 functor slot, 지금은 1개만 instantiate)
3. Machine decision 에서 prose 재파싱 = 0
4. Approval = **Auto Safe / Ask Risky / Deny Unknown**
5. Phase A 범위 = **Local Exec Core only** (bash)
6. Fail-closed: 파싱 실패 / 스키마 없음 / unknown capability = Deny 또는 Ask
7. Config 기반 per-agent per-cap. 전역 bypass knob 없음
8. 외부 의존성 license: copyleft 금지. MIT/ISC/Apache-2.0/BSD만
9. **별도 repo 분리 없음**. 분리 가치 (2+ 소비자 & 유지 비용 < 통합 혼잡도) 증명 후에만 추출
10. Layer 1 functor 경계만 now. utility typing / 2번째 언어 instantiate는 Phase B (실제 수요 발생 전 설계 금지)

## Scope

**Phase A (이 RFC, 8-11주 솔로 full-time)**:
- Bash subset hand-rolled parser (Menhir LR(1), simple+pipeline+redirect+cwd+env만)
- Typed IR (Capability/Verdict/Bin opaque/Path_scope/Shell_ir)
- AST → Shell_ir walker (exhaustive match, fail-closed allowlist)
- Capability extraction + Approval policy + per-agent TOML
- Exec gate + 87-사이트 cutover
- Dispatch typed outcome + legacy tuple 제거
- Approval drawer 자동 e2e 테스트

**Phase B (별도 RFC, 실제 수요 발생 시)**:
- Utility structural argv typing (find / curl / xargs / docker / ssh 등) — 지금은 `Bin.t` unknown → Ask. 확장 trigger = A 운영 중 Ask 비율 UX 저하
- Multicore Domain parallel (LLM blob 10KB+ 입력)
- Algebraic effect scanner (2번째 언어 합류)
- Persistent tree / incremental reparse (LLM streaming 분석)
- Workflow grammar (LLM action sequence parsing)
- Cross-language injection (bash → python → sql 체인)
- `lib/exec/` 서브트리 분리 추출 (2+ 소비자 발생 시)

**Phase A 아키텍처가 Phase B 확장을 문 열어둠**:
- Layer 1 functor 경계 now 설정
- `Shell_ir.t` immutable value (추후 hashcons 추가만)
- scanner API를 1st-class module로 (effect handler 교체 가능)
- `Capability.t list`가 structured sequence (outer grammar mount 준비)
- `lib/exec/` sub-tree 경계로 추후 추출 가능성 보존

**Anti-scope (명시 제외)**:
- Network/DB capability
- 43 MCP tool의 typed_tool 대량 승격
- Agent identity / cancellation token 리팩터
- Keeper FSM 리팩터
- Prompt DSL / TOML 포맷 교체
- 기존 52 TLA+ spec 수정
- tree-sitter runtime 재구현 (GLR/Wagner/Multicore/persistent/effects 전부)
- 별도 repo / public 공개 준비 (분리 가치 증명 전까지 금지)
- Utility structural argv typing (Phase B)

## Existing assets (widen not build)

| 자산 | 파일:라인 | 활용 |
|------|---------|-----|
| `Capability_registry.risk_class` (Safe/Audited/Privileged) | `lib/capability_registry.ml:12-48` | `Bin.risk_class` vocabulary SSOT |
| `Cdal_verdict_gate` Allow/Reject 2-way | `lib/cdal_verdict_gate.ml:7-48` | 3-way `Verdict.t`로 generalize |
| `Operator_approval.pipeline` | `lib/operator_approval.ml:30-41` | `Approval_policy.decide` emit 경로 |
| `Approval_callbacks.auto_approve` | `lib/approval_callbacks.mli:8` | OAS Hooks 정합 |
| `Keeper_approval_queue` — Eio.Promise + SSE 완성 | `lib/keeper/keeper_approval_queue.ml:1-120` | **widen only**, source 필드 추가 |
| `Typed_tool.create` bridge | `lib/typed_tool_masc.ml:15` | canonical 승격 |
| `Tool_result.wrap` + `structured_payload_of_message` | `lib/tool_result.ml:44-62` | `of_exec_verdict` 추가 |
| `Tool_code.normalize_path` | `lib/tool_code_write.ml:26-27` | `Path_containment.classify`의 primitive |
| `Tool_name.ml` (compile-time typed identifier) | `lib/tool_name.ml:1` | Layer 2 extraction에서 재사용 |

## Module 구성 (masc-mcp 내부)

```
masc-mcp/lib/exec/
├── capability.ml/.mli          — closed variant Capability.t
├── path_scope.ml/.mli          — abstract t + smart ctor
├── bin.ml/.mli                 — opaque Bin.t + of_string → (t, unknown) result
├── git_op.ml/.mli              — typed subcommand + destructive variant
├── redirect_scope.ml/.mli      — File | Fd_to_fd only
├── shell_ir.ml/.mli            — closed variant Simple | Pipeline | ...
├── parsed.ml                   — Parsed | Parse_error | Parse_aborted | Too_complex
├── verdict.ml/.mli             — Allow | Ask | Deny
├── language.ml                 — module type LANGUAGE = sig ... end (functor 경계)
├── parser/
│   ├── bash_lexer.mll          — ocamllex (modes for $() nesting)
│   ├── bash_subset.mly         — Menhir LR(1), 서브셋만
│   └── bash.ml/.mli            — expose parse_string: string -> Shell_ir.t Parsed.t
├── capability_check.ml/.mli    — Shell_ir.t → Capability.t list (exhaustive)
├── approval_policy.ml/.mli     — decide (pure)
├── approval_context.ml/.mli    — runtime context
├── approval_config.ml/.mli     — TOML per-agent per-cap
├── exec_gate.ml/.mli           — run : Verdict.t → result (유일 privileged 경로)
└── dune                        — (library (name masc_exec) (public_name ...)) — 내부 전용, public 이름 없음

masc-mcp/test/exec/
├── test_parser_subset.ml       — golden corpus (Track 0 + qcheck)
├── test_capability_check.ml
├── test_approval_policy.ml     — 50+ bypass fixture
└── fuzz/                       — qcheck 10k safe + 50 bypass
```

**추출 조건 (Phase B 이후)**: `lib/exec/` 소비자가 masc-mcp 외 1개 이상 생기고, 분리 유지 비용 < 통합 혼잡도 증명 시. 그 전까지는 내부 library. 현재 dune scope는 `masc_mcp` 프로젝트 내부 sub-library로, 외부 공개 이름 부여하지 않음.

## Typed IR — Variant 정의 (A0 확정 대상)

소비자 exhaustive match를 강제하기 위해 **각 sum type의 arm을 plan 단계에서 확정**한다. A0 진입 직전 이 정의로 `.mli` 작성, A0 이후 arm 추가는 RFC 개정 필요.

### `Bin.t` — opaque + smart constructor

```ocaml
(* lib/exec/bin.mli *)
type t  (* opaque; 내부 rep은 string + risk_class cached *)

type unknown = [ `Unknown of string ]

val of_string : string -> (t, unknown) result
(** 유일한 생성 경로. PATH lookup 안 함 — 이름만 classify *)

type risk_class =
  [ `Safe        (* ls, cat, grep, echo, pwd, date, ... *)
  | `Audited     (* git, docker, curl, ssh, tar, rsync, make, ... *)
  | `Privileged  (* sudo, su, chmod, chown, rm, dd, mkfs, ... *)
  ]

val risk_class : t -> risk_class
val to_string : t -> string  (* exec gate용, 그 외 금지 *)
```

Unknown bin → `risk_class = Privileged` → `Verdict.Ask` (우회 불가).

### `Path_scope.t` — abstract + smart constructor

```ocaml
(* lib/exec/path_scope.mli *)
type t  (* abstract *)

type scope =
  | Inside_worktree of string       (* relative to worktree root *)
  | Inside_sandbox of string         (* .masc/, /tmp/masc-* 등 *)
  | Outside_worktree of string       (* 외부 read/write *)
  | Absolute_unknown of string       (* /etc, /var 등 *)

val classify : raw:string -> cwd:string -> t
val scope : t -> scope
val raw : t -> string
```

`Tool_code.normalize_path` primitive 재사용. `..`/symlink escape는 `classify`에서 `Outside_worktree`로.

### `Git_op.t` — subcommand 3-class polymorphic variant

```ocaml
(* lib/exec/git_op.mli *)
type t =
  | Read of
      [ `Status | `Log | `Diff | `Show | `Branch_list
      | `Remote_list | `Rev_parse | `Ls_files | `Blame ]
  | Mutating of
      [ `Commit | `Merge | `Rebase | `Pull | `Fetch
      | `Push | `Tag | `Stash_push | `Checkout_branch ]
  | Destructive of
      [ `Reset_hard | `Push_force | `Branch_delete
      | `Clean_force | `Stash_drop | `Worktree_remove ]

val of_argv : string list -> (t, [`Unknown_subcmd of string]) result
```

### `Redirect_scope.t` — 닫힌 variant (heredoc/proc-sub 제외)

```ocaml
(* lib/exec/redirect_scope.mli *)
type mode = Read | Write | Append

type t =
  | File of { fd : int; target : Path_scope.t; mode : mode }
  | Fd_to_fd of { src : int; dst : int }
```

Heredoc / here-string / process substitution / `&>` bash-ism 등은 파서 단계에서 `Too_complex`.

### `Shell_ir.t` — subset AST

```ocaml
(* lib/exec/shell_ir.mli *)
type simple = {
  bin : Bin.t;
  args : Arg.t list;
  env : (string * Arg.t) list;   (* FOO=bar prefix *)
  cwd : Path_scope.t option;
  redirects : Redirect_scope.t list;
}

type t =
  | Simple of simple
  | Pipeline of t list   (* 길이 ≥ 2 — head | middle* | tail *)

and Arg.t =
  | Lit of string                     (* "foo", 'bar' *)
  | Concat of Arg.t list              (* foo"bar"$X → [Lit; Lit; Var] *)
  | Var of string                     (* $HOME, ${VAR}, ${VAR:-default} 만 *)
```

`$()` command substitution / `` ` ` `` / `$(())` 산술 / 함수 정의 / `for/while/if` / `&&/||` 등 전부 `Parsed.Too_complex`.

### `Parsed.t` — 4-way 결과 (Too_complex는 arm으로 분리)

```ocaml
(* lib/exec/parsed.ml *)
type reason_aborted = [ `Timeout_50ms | `Depth_limit | `Token_limit_50k ]

type reason_too_complex =
  [ `Heredoc | `Here_string
  | `Cmd_subst | `Proc_subst
  | `Subshell | `Arith_expansion
  | `Control_flow    (* if/for/while/case *)
  | `Logic_op        (* && || ; *)
  | `Function_def
  | `Glob_brace      (* {a,b,c} *)
  | `Background      (* & *)
  | `Unknown_construct of string
  ]

type parse_error = {
  pos : Lexing.position;
  token : string;
  expected : string list;
}

type 'a t =
  | Parsed of 'a
  | Parse_error of parse_error
  | Parse_aborted of reason_aborted
  | Too_complex of reason_too_complex
```

`Too_complex` arm을 세분화하는 이유: T0 corpus에서 LLM emit 분포 집계 후 Phase B 승격 후보를 **arm 빈도로** 결정 (예: `Cmd_subst` > 30%면 승격).

### `Capability.t` — 정책 소비 타입

```ocaml
(* lib/exec/capability.mli *)
type t =
  | Read_path of Path_scope.t
  | Write_path of Path_scope.t * Redirect_scope.mode  (* Write | Append *)
  | Exec_bin of Bin.t * Arg.t list
  | Git of Git_op.t
  | Env_set of string * Arg.t          (* FOO=bar prefix *)
  | Pipeline_fold of t list            (* pipeline 내부 집합 *)
```

`of_ir : Shell_ir.t -> t list` — exhaustive walker, new arm 추가 시 컴파일러가 누락 arm 차단.

### `Verdict.t` — 3-way + Trusted_argv

```ocaml
(* lib/exec/verdict.mli *)
type request = {
  caps : Capability.t list;
  summary : string;                    (* human-readable *)
  bin : Bin.t;                         (* approval UI용 *)
  raw_source : string;                 (* 원문 한 번만 표시용 *)
}

type deny_reason =
  | Unknown_bin of string
  | Path_escape of Path_scope.t
  | Destructive_git of Git_op.t
  | Policy_deny of { rule : string }
  | Parse_too_complex of Parsed.reason_too_complex
  | Parse_failed

type t =
  | Allow of Trusted_argv.t
  | Ask of request
  | Deny of { caps : Capability.t list; reason : deny_reason }

and Trusted_argv.t = private {
  bin : Bin.t;
  args : Arg.t list;
  env : (string * Arg.t) list;
  cwd : Path_scope.t option;
  redirects : Redirect_scope.t list;
}

val trust : caps:Capability.t list -> Shell_ir.simple -> Trusted_argv.t
(** 유일한 Trusted_argv 생성 site. policy.decide 내부에서만 호출 *)
```

`Trusted_argv.t`가 `private` 이므로 exec_gate는 **approval_policy를 통과한 값만** 실행 가능. smart ctor `trust`는 `approval_policy.ml` 모듈에서만 호출 (mli로 export하지 않음).

### Arm 추가 규칙

A0 이후 이 9개 타입에 arm을 추가할 때:

1. RFC 개정 필요 (여기서 확정된 계약)
2. 새 arm의 `Capability.t` 매핑 먼저 결정
3. `approval_policy.decide`가 exhaustive match 이므로 자동으로 컴파일 에러 → 정책 결정 강제
4. 테스트: arm 추가 시 bypass corpus에 해당 케이스 1건 이상 추가

## LOC 추정

| 모듈 | LOC | 기간 |
|------|-----|------|
| typed IR (capability, path_scope, bin, git_op, redirect, shell_ir, parsed, verdict) | 600-900 | 3-5일 |
| Menhir bash subset parser (lexer mll + grammar mly + wrapper) | 1500-2500 | 2-3주 |
| capability_check walker | 400-600 | 3-4일 |
| Capability extraction + git_op normalization | 500-700 | 4-5일 |
| Approval policy + TOML loader | 300-500 | 2-3일 |
| Exec gate (중앙 1 사이트) | 200-400 | 2-3일 |
| Golden corpus + fuzz harness | 300-500 | 3-5일 |
| Track 0 tap | 200-300 | 3-5일 관측 |
| Approval queue widen | 200-300 | 2-3일 |
| 87-사이트 cutover (4 sub-phase) | 600-900 | 2-3주 |
| Dispatch typed outcome + tuple 제거 | 300-500 | 3-4일 |
| Drawer 자동 e2e | 200-300 | 2-3일 |
| **합계** | **5,300-8,400** | **8-11주 솔로 full-time** |

(이전 v4의 "tree-sister 3800-6100 + masc-mcp 1500-2300" 동일 총량. repo 분리 비용 제거. 다른 작업 병행 시 ×1.5-2 = 12-22주.)

## OCaml 5 advantage (실제 효과 있는 곳만)

선행 TS 구현 대비 OCaml 5가 본질적으로 이기는 부분:

| 레이어 | TypeScript | OCaml 5 |
|-------|-----------|---------|
| Node type allowlist | 런타임 switch + default throw | 닫힌 variant → 컴파일러가 누락 arm 거부 |
| "simple" vs "too-complex" | tagged union + 런타임 검사 | private ctor + exhaustive match, 우회 타입으로 차단 |
| argv 신뢰 경계 | `string[]` 그냥 흘림 | `private { bin: Bin.t; args }`, smart ctor만 |
| Parsed/Aborted/TooComplex | 3-way tagged union, 소비자 보장 없음 | sum type + exhaustive match, 새 variant = 모든 소비자 컴파일 에러 |
| 언어 확장 | 각 언어 별 파서 + validator | functor instantiate (Phase B 확장 여지) |
| Grammar DSL | 외부 CLI (tree-sitter CLI) | Menhir `.mly` 직접 선언 |
| Bin 안전 | string | opaque + of_string 한 곳 |

이득은 파서 본체(어느 언어든 동일 복잡도)가 아니라 **allowlist → IR → Verdict 경계의 타입 증명**. 압축비 1.5-2×, 컴파일러가 보안 누락 차단.

**효과 없어서 Phase A 제외**:
- Multicore Domain parallel: bash <1KB 입력에 Domain overhead > parse time. LLM blob 10KB+는 Phase B
- Algebraic effect scanner: 토큰당 50-200ns 누적. 단일 언어에 composition 이득 미미. Phase B
- Persistent tree: LLM emit fresh, no edit. streaming 분석은 Phase B
- Workflow grammar: 2번째 소비자 미지명. Phase B
- Utility structural argv typing (awk/sed/find/curl 등): Phase A의 `Bin.of_string unknown → Ask`로 Safe 범위 커버. 확장 근거는 실측 UX 저하 이후에만 수용

## Phase breakdown

### T0 — Empirical tap (선행 PR, 5 cal days, 단독 merge)

**Scope**: 87 exec 사이트 tap, 관측만, 프로덕션 변화 0

**Files new**:
- `scripts/exec_corpus_tap.ml` — ref-cell wrapper
- `scripts/exec_corpus_report.ml` — JSONL → inventory
- `audits/local-exec-core-inventory.md`

**Files modified**:
- `lib/process/process_eio.ml` — `run_argv_with_status` ref-cell dispatch
- 9 Unix.* 사이트도 `lib/exec_tap.ml` 얇은 shim 경유 (tap=0 시 identity)

**Exit criteria**:
- N ≥ 200 invocations 수집
- Coverage table + Risk 분포 (Git_mutating, Write_outside, Pipeline_cmdsub, Simple_read)
- risk-weighted `w = 0.4·Git_mut + 0.3·Write_out + 0.2·Pipe_cmdsub + 0.1·Simple_rd ≥ 0.85` → A0 proceed
- `w < 0.85` → scope 재검토 (subset 확장 vs typed tool whitelist로 선회)

### A0 — IR types + Menhir skeleton (1주)

**Scope**: `masc-mcp/lib/exec/` 서브트리 초기화. 타입 모듈 + 빈 Menhir grammar 빌드 통과.

**Files new**:
- `lib/exec/capability.ml/.mli`, `path_scope.ml/.mli`, `bin.ml/.mli`, `git_op.ml/.mli`, `redirect_scope.ml/.mli`, `shell_ir.ml/.mli`, `parsed.ml`, `verdict.ml/.mli`
- `lib/exec/language.ml` (functor signature)
- `lib/exec/parser/bash_lexer.mll` (skeleton)
- `lib/exec/parser/bash_subset.mly` (skeleton, 단순 token pass-through)
- `lib/exec/dune` — sub-library

**Exit criteria**: `dune build` + `dune runtest` green, `test/exec/test_exec_types.ml` 5+ tests

### A1 — Bash subset parser (2-3주)

**Scope**: Menhir LR(1) grammar로 simple + pipeline + redirect + cwd + env assignment. heredoc, `$()`, subshell, control flow 전부 `Parse_error`.

**Files**:
- `lib/exec/parser/bash_lexer.mll` — token 분류, quote mode
- `lib/exec/parser/bash_subset.mly` — 8-12 productions
- `lib/exec/parser/bash.ml/.mli` — parse_string wrapper + 50ms timeout + PARSE_ABORTED sentinel

**Exit criteria**:
- T0 corpus 재생: Parsed 비율 ≥ 70% simple+pipe+redir
- qcheck 1000 random bash: crash 0
- 50 bypass corpus: 100% Parse_error

### A2 — Capability check + Policy (1-2주)

**Files**:
- `lib/exec/capability_check.ml/.mli` — `of_ir : Shell_ir.t → Capability.t list`
- `lib/exec/approval_context.ml/.mli`
- `lib/exec/approval_policy.ml/.mli` — decide pure function
- `lib/exec/approval_config.ml/.mli` — TOML loader, per-agent per-cap
- `config/approval_policy.toml` (example)

**Exit criteria**:
- 50+ 적대적 fixture 전원 Ask-or-Deny
- coverage ≥ 95% line, 100% Deny branch

### A3 — Exec gate + Approval queue widen (1-1.5주)

**Layer 경계 (근본적 해결)**: bash execution gate는 **MASC 내부 문제**.  OAS `Hooks.approval_callback`은 SDK consumer가 외부 MCP tool을 호출할 때 사용자 승인 받는 hook — keeper가 내부적으로 bash 실행할 때와는 layer가 다르다.  Claude Code가 Claude Agent SDK 이용자인 것과 같이, MASC는 OAS 이용자이지만 keeper의 shell action 정책은 MASC 내부에서 완결.  A3는 OAS touch 0, bridge 파일 없음, pin bump 없음.  기존 `governance_pipeline.ml`가 쓰는 OAS hook은 MCP tool approval path — A3 exec gate와 독립 유지.

**Files**:
- `lib/exec/exec_gate.ml/.mli` — `run : Verdict.t → result`
- 내부 단일 privileged `Process_eio.run_argv_with_status` 경유
- `lib/keeper/keeper_approval_queue.ml` — source 필드 (Keeper|Worker|System|MCP|Unix) widen (MASC 내부 타입)
- (기존 SSE `approval:pending` + Eio.Promise 재사용)

**Exit criteria**:
- unit test: Allow/Ask/Deny 3-way 정상 분기
- Ask 경로 SSE blocking 검증
- 기존 keeper approval 경로 regression 0
- OAS 의존 신규 0 (exec gate 내 `Oas.*` import 금지)

### A4 — 87-사이트 cutover (2-3주, 4 sub-phase)

각 sub-phase 24-48h shadow (`MASC_EXEC_GATE=parallel` flag).

#### A4a — Simple callers (3일, ~20 사이트)
- `lib/notify.ml`, `graphql_client.ml`, `task_sandbox.ml`, `tool_code.ml` ...

#### A4b — Coord/Swarm/Autoresearch (3일, ~20 사이트)
- `lib/coord/*`, `lib/swarm/*`, `lib/autoresearch/*`, `lib/auto_responder.ml`

#### A4c — Keeper (4일, 31 사이트, 48h shadow)
- `lib/keeper/keeper_exec_shell.ml` (19) 외

#### A4d — 잔존 Unix.* + deprecation (2일, 9 + 삭제)
- `lib/spawn.ml`, `worker_runtime_docker.ml` 등 + `tool_code_write.ml:36-48` allowlist 삭제, `worker_dev_tools.ml:76-150,283-300` 삭제, `eval_gate.ml:100-130` `@@deprecated`

**Exit criteria**:
- `rg -e 'Process_eio\.run_argv' -e 'Unix\.(create_process|open_process|system)' lib/ | grep -v lib/exec/exec_gate` = 0
- 각 sub-phase canary shadow 통과
- T0 corpus 재생 전원 Verdict 생성

### A5 — Dispatch typed outcome (3-4일)

**Files**:
- `lib/tool_dispatch.ml:14` — `type handler = ... -> Tool_result.t option`
- `lib/tool_dispatch.ml:50-54` — `| Ask of Verdict.approval_request` 추가
- `lib/tool_result.ml:62-68` — `to_legacy_compat [@@alert deprecated]`
- 14 tuple 사이트 전원 제거
- `rollback/revert-rfc-v5-A5.patch` + runbook 사전 작성

**Exit criteria**:
- `rg '\(bool \* string\)' lib/ | rg -v CHANGELOG | rg -v to_legacy_compat` = 0
- 3개월 유예 deprecated warning 활성

### A6 — Drawer 자동 e2e (2-3일, A5와 병행)

**Files**:
- `test/fuzz/test_approval_drawer.ml` — Playwright/headless, rm -rf fixture 자동 구동

## Approval channel

`lib/keeper/keeper_approval_queue.ml` widen, source 필드 추가. 기존 SSE `approval:pending` + Eio.Promise 재사용. 전역 env knob 금지. per-agent TOML 기반.

## Verification

### TLA+ (outcome trichotomy 적용)

clean.cfg + buggy.cfg 쌍. buggy는 TLC fail 강제. CI:

- `tla/boundary/ShellCapability.tla` + `-buggy.cfg` — Write_path cap는 Allow|Approved-Ask 이후만
- `tla/boundary/PathContainment.tla` + `-buggy.cfg` — `..`/symlink escape 불가
- `tla/boundary/ApprovalLifecycle.tla` + `-buggy.cfg` — 모든 Ask resolve, Promise.u leak 없음, cancel 시 cleanup
- `tla/boundary/InFlightContinuity.tla` + `-buggy.cfg` — gate flip arrival-time

**Merge gate**: spec 위반 = outcome-3 → fix 없이 merge 금지

### Fuzz

- safe 10k: 0 regression
- bypass 50: 100% Ask|Deny

### Latency

- approved path p99 ≤ 200μs
- Ask path: human-bound, SSE emit → drawer render p99 < 1s
- bash parse budget: 50ms + 50k node

### Invariants CI

```bash
rg -e 'Process_eio\.run_argv' \
   -e 'Unix\.(create_process|open_process|system)' \
   lib/ | grep -v lib/exec/exec_gate | wc -l  # 0
rg '\(bool \* string\)' lib/ | rg -v CHANGELOG | rg -v to_legacy_compat | wc -l  # 0
rg 'MASC_AUTO_APPROVE' lib/ | wc -l  # 0
```

## Risk register

| # | 위험 | 확률 | 영향 | 완화 |
|---|-----|-----|-----|------|
| R1 | T0 risk-weighted < 0.85 | 중 | 상 | scope halt, subset 확장 vs typed tool whitelist 선회 |
| R2 | Menhir subset grammar 확장 압력 | 중 | 중 | productions > 16 또는 작성 > 3주 시 scope 축소. Morbig 방식 차용 가능 (POSIX 선별 파싱) |
| R3 | 87 사이트 migration regression | 상 | 중 | 4 sub-phase + shadow 24-48h + diff JSONL + env flag revert 1줄 |
| R5 | Approval UX latency 압력 | 중 | 상 | per-agent TOML allow-safe-in-worktree 기본. 전역 knob 삭제. drawer p99 <1s CI |
| R6 | heredoc/cmd-sub 등 subset 제외 항목을 LLM 대량 emit | 상 | 중 | Parse_aborted → Too_complex → Ask. T0 비율 모니터 + 필요 시 특정 패턴 typed tool로 승격 |
| R7 | In-flight gate flip race | 중 | 중 | TLA+ InFlightContinuity + arrival-time 구현 |
| R8 | Fiber cancel Promise.u leak | 중 | 중 | `Eio.Switch.on_release` cleanup + TLA+ liveness |
| R9 | TLA+ spec checkbox | 중 | 중 | outcome trichotomy CI gate |
| R10 | A5 rollback 곤란 | 낮 | 치명 | `to_legacy_compat @@alert deprecated` 3개월 + pre-drafted revert patch |
| R11 | eval_gate.ml 기존 방어 삭제로 regression | 중 | 중 | secondary-only `@@deprecated`로 **유지**, primary는 `Approval_policy.decide` |
| R12 | `lib/exec/`가 masc-mcp 다른 모듈과 엉킴 | 중 | 중 | sub-tree 경계 + dune internal library. public interface 최소화 (Exec.run / Exec.classify만 export) |
| R13 | unknown utility (awk/sed/find/curl 등)를 LLM 대량 emit → Ask flood | 중 | 중 | T0에서 unknown bin 빈도 집계. threshold 초과 시 Phase B utility typing trigger, 아니면 per-agent TOML allow-safe로 흡수 |
| R14 | Phase B 확장 시 A의 경계가 부적합 판명 | 낮 | 중 | Layer 1 functor + named module seams. 실제 Phase B 진입 전까지 증명 불가 — architectural risk 허용 |

## Quantitative predictions (accurate)

| Metric | Before | After | 측정 |
|--------|-------|-------|-----|
| exec entry 사이트 | **87** | **1** (`lib/exec/exec_gate.ml`) | invariants CI |
| `(bool * string)` tuple 파일 | 14 | 0 (`to_legacy_compat @@alert`) | rg |
| Typed_tool producer | **1** | 2-4 (Exec_gate 인접) | rg |
| Bypass corpus 차단율 | ~60% (regex/substring) | 100% (subset 내, 나머지 Parse_aborted → Ask/Deny) | fuzz |
| eval_gate.ml 역할 | primary defense | **secondary-only**, primary = Approval_policy | `@@deprecated` mark |
| Approval config | 전역 env 가정 | `config/approval_policy.toml` per-agent | 파일 + CI lint |
| 전역 auto-approve knob | 1 (`MASC_AUTO_APPROVE_*`) | 0 | grep invariant |
| 빌드 opam dep | baseline | +0 (외부 repo 없음) | diff opam |
| CI time | baseline | +40-60s (fuzz + TLA+ 4 spec + drawer e2e) | CI log |
| masc-mcp Δ LOC | baseline | +5,300-8,400 (모두 내부) | `git diff --stat` |

## Sequencing

```
T0 tap (5 cal days) ─┐
                     │
  A0 types (1wk) ────┤
  A1 parser (2-3wk) ─┤
  A2 policy (1-2wk) ─┤
  A3 gate (1-1.5wk) ─┘
  │
  A4 cutover (2-3wk)  4 sub-phase
  A5 dispatch (3-4d)
  A6 drawer e2e (2-3d, A5 병행)
```

**총 working**: 8-11주 솔로 full-time. 다른 작업 병행 시 ×1.5-2 = 12-22주.

## Decisions locked-in

1. **typed capability substrate** — 구현 위치 `masc-mcp/lib/exec/` 내부 (별도 repo 없음)
2. **분리 금지** — 별도 public/private repo 추출은 소비자 2+ & 유지 비용 < 통합 혼잡도 증명 후에만
3. **Parser**: Menhir LR(1) bash subset (simple+pipe+redir+cwd+env). heredoc/`$()`/subshell 전부 Parse_error → Too_complex → Ask
4. **Bin.t**: opaque + `of_string: string → (t, unknown) result`. Unknown → `risk_class = Privileged` → Ask
5. **Executor boundary**: `Process_eio.run_argv*` + `Unix.create_process/open_process/system` 모두 포함, invariant grep 확장
6. **Approval**: `Keeper_approval_queue` widen, 전역 env knob 삭제, per-agent TOML
7. **A4 4 sub-phase + shadow 24-48h** (big-bang 금지)
8. **OAS 무관**: bash execution gate는 MASC 내부 문제. OAS approval hook은 MCP tool approval path 전용(layer 다름). A3 exec gate가 OAS import 신규 추가 금지. pin bump / cross-repo PR / bridge 모듈 전부 **없음**
9. **TLA+**: outcome trichotomy, clean+buggy 쌍, CI gate
10. **Rollback**: `to_legacy_compat @@alert deprecated` 3개월 + pre-drafted revert patch
11. **Drawer test**: 자동 e2e
12. **Path_containment**: `Tool_code.normalize_path` primitive 재사용, 자체 canonicalization 0
13. **In-flight race**: arrival-time flip + TLA+ 포함
14. **Fiber cancel**: `Eio.Switch.on_release` cleanup
15. **Sequencing**: T0 tap 선행 PR, empirical-before-design
16. **OCaml 5 scope**: closed variant + private type + exhaustive match + functor (Layer 1). GADT phantom 소량 허용
17. **Phase B 제외 항목**: Utility structural argv typing (awk/sed/find/curl 등), Multicore Domain, algebraic effect scanner, persistent tree, workflow grammar, cross-language injection, `lib/exec/` 추출. 아키텍처는 문 열어두되 Phase A에 없음
18. **License**: 외부 의존성 copyleft 금지 (Semgrep LGPL/GPL3, Morbig GPL3 모두 reject)

## References

- Miller et al. (2003) *Capability Myths Demolished*
- arXiv 2601.08012 *Towards Verifiably Safe Tool Use for LLM Agents*
- arXiv 2412.14470 *Agent-SafetyBench*
- MCP Spec 2025-11-25 (consent는 host/client 책임)
- Morbig SLE 2018 (Menhir POSIX shell subset 가능성 증명)
- memory/feedback `empirical-before-design`, `tla-spec-audit-outcome-trichotomy`, `no-invented-abstractions`, `consider-base-library`, `no-lifecycle-invasion-from-masc`, `no-derived-tag-when-existing-identifier-suffices`
