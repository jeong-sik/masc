---
rfc: "0148"
title: "Typed `tool_error` Variant for LLM-Facing Tool Failure Surface"
status: Draft
created: 2026-05-20
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0088", "0091", "0105"]
implementation_prs: []
---

# RFC-0148: Typed `tool_error` Variant for LLM-Facing Tool Failure Surface

## §0 한 줄 요약

LLM 이 호출하는 tool 들의 *실패 분류* 가 현재 `Failure msg` (catch-all 문자열) 으로 ~30 사이트에 분산. 이를 **closed sum type `tool_error`** 로 root-fix 하여 컴파일 타임에 새 실패 클래스 누락이 잡히도록 한다. 본 RFC 는 *2026-05-20 18-log audit Sweep1 §2* 의 후속.

> Phase 2 reservation note: ledger 0146/0147 슬롯은 collision recovery PR (#16910 `permissive-silent-fallback → 0146`, #16863 `keeper-agent-run → 0147`) 점유 예상. 본 RFC 는 그 두 슬롯 *건너뛰고* 0148 부터 시작.

## §1 문제: catch-all `Failure msg` 의 LLM-facing 노출

2026-05-20 18-log audit (`memory/masc-mcp-log-audit-2026-05-20-final-synthesis.html`) Sweep1 §2 결과: LLM 이 직접 보는 8 사이트 + 2차 사이트 다수 가 catch-all 패턴.

### 1.1 HIGH 8 사이트 (LLM 이 직접 string surface 봄)

| 파일 | 라인 | 현재 형태 | 영향 |
|------|------|-----------|------|
| `lib/tool_dispatch.ml` | 203 | `with _ -> Failure "dispatch failure"` | tool 호출 실패 분류 소실 |
| `lib/tool_code.ml` | 529 | `with exn -> Failure (Printexc.to_string exn)` | read 실패가 raw exn 메시지로 노출 (RFC-0091/0105 인접) |
| `lib/tool_code.ml` | 584 | 동일 패턴 | write 실패 |
| `lib/tool_code_write.ml` | 471 | catch-all | write 분기 |
| `lib/tool_code_write.ml` | 601 | catch-all | clone 분기 |
| `lib/tool_code_write.ml` | 626 | catch-all | 별도 path |
| `lib/tool_library.ml` | 222 | catch-all | library lookup |
| `lib/tool_library.ml` | 285 | 동일 | |
| `lib/tool_library.ml` | 324 | 동일 | |

위 라인 번호는 2026-05-20 18-log audit 시점 측정. 라인 drift 가능, 본 RFC 의 검증은 *catch-all match arm 의 본문이 `Failure ...` 또는 `Error (Failure ...)` 를 반환* 하는 site 전수 grep 으로 한다 (§5 참고).

### 1.2 워크어라운드 시그니처 적용 분석

본 패턴은 `software-development.md` 의 *워크어라운드 거부 7항목* 중 다음에 정확히 부합:

- **#2 String/Substring 분류기 보강** — LLM 이 string surface 를 봐서 *반복 prompt 매칭* 으로 분류. typed variant 이 있으면 OCaml 컴파일러가 누락을 잡지만, 현재 *catch-all 문자열* 이라 새 실패 클래스 추가 시 LLM-side 분류기에 *string match 추가* 가 unblocked.
- **#3 N-of-M 패치** — ~30 사이트가 같은 변환 (exn → Failure string) 을 *개별 복제*. abstraction 부재의 admit. 본 RFC 가 typed variant + codemod 로 *한 번에 모든 사이트 변환*.

## §2 제안: closed sum `tool_error`

### 2.1 타입

```ocaml
type tool_error =
  | Not_found of { what : string }
  | Permission_denied of { path : string }
  | Invalid_input of { detail : string }
  | Resource_exhausted of { resource : string; detail : string }
  | Timeout of { stage : string; elapsed_sec : float }
  | Cancelled of { reason : string }
  | Internal_error of { detail : string; exn : exn option }
```

- 7 variant. 컴파일러 exhaustive match enforce.
- `Internal_error` 가 catch-all 역할 — *단, exception 객체 (`exn`) 를 보존* 하여 디버깅 surface 유지.
- *Tag* 는 LLM-facing JSON serialization 시 sum constructor 이름 (e.g. `"not_found"`).
- *Message* 는 record field 로 분리 — LLM 이 *tag* 로 분류 + *detail* 로 추가 컨텍스트 수신.

### 2.2 JSON wire format

```json
{
  "error": {
    "kind": "not_found",
    "what": "file:lib/foo.ml"
  }
}
```

또는

```json
{
  "error": {
    "kind": "internal_error",
    "detail": "unexpected EOF during parse"
  }
}
```

LLM-side prompt 는 *kind* field 만으로 1차 분류 가능. *detail* 은 user-facing description 용. *exn* 은 LLM 에 노출 안함 (debug log 한정).

## §3 비교 (Trade-offs)

| 측면 | 현재 (`Failure msg`) | RFC-0148 (typed) |
|------|----------------------|------------------|
| 새 실패 클래스 추가 | 무성 — match arm 추가 안해도 컴파일 | 컴파일 강제 — 모든 호출 site exhaustive |
| LLM 분류 정확도 | string prefix match (~70% 추정) | tag 1-to-1 (100%) |
| Debug 가능성 | exn 정보 *문자열* 로 lossy | exn 객체 보존 + tag |
| 마이그레이션 비용 | 0 | ~30 사이트 codemod + alcotest |
| Backward compat | (변경 없음) | `Failure msg` 잔존 호출자는 `Internal_error { detail = msg; exn = None }` 으로 자동 변환 |

## §4 비-목표

- Tool registry / dispatcher 자체 변경 안함 (`Tool.descriptor.t`). 본 RFC 는 *실패 surface* 한정.
- LLM prompt 변경 안함. RFC-0148 PR-1 머지 후 prompt 가 새 kind 사용은 *별도 RFC* 후속.
- Provider/SDK 레벨 error mapping (`Openai_compat_error_map`, RFC-0098) 와는 *별개* — 본 RFC 는 *tool 실행* 후 LLM 에 *return* 되는 형태 한정. SDK 호출 시 발생한 에러는 RFC-0098 이 담당.

## §5 검증 방법 (Acceptance Criteria)

본 RFC 머지 + PR-1~3 완료 시점 의 통과 조건:

1. **Exhaustive 누락 0**: `rg 'with\s+_\s*->\s*(Failure|Error \(Failure)' lib/tool_*.ml` 결과 = 0 (HIGH 8 사이트 자체) — 단, 명시적 변환 helper (`Tool_error.of_exn`) 호출 site 는 제외.
2. **Codemod 검증**: 각 8 사이트 의 *변환 helper* 호출이 *exhaustive exn 매칭* 을 통과 — `Sys_error`, `Unix.Unix_error`, `Failure`, `Not_found` 각각 명시 (RFC-0091 PR-3 의 패턴 따름).
3. **Alcotest 6 케이스 (PR-1)**: 7 variant 각각 + `Internal_error.exn` 보존 1 케이스.
4. **CI guard**: PR-2 에 *backsliding test* — 새 `Failure msg` catch-all 이 본 8 영역 에 추가될 시 lint fail.
5. **LLM-side acceptance** (PR-3 후): production 1주일 logs 에서 `kind` field 분포가 `internal_error` 이외 variant 가 >5% 발생 (즉, 실제로 분류가 happening). `internal_error` 만 나오면 catch-all 변환 codemod 가 *의미 없는 mapping* 한 것.

## §6 PR 분할 (Phase Plan)

| PR | Scope | LoC 추정 | Blocker |
|----|-------|---------|---------|
| **PR-1** | `Tool_error.t` 모듈 + 6 Alcotest | +250 / -0 | (본 RFC 머지) |
| **PR-2** | 8 HIGH 사이트 codemod (`tool_dispatch`, `tool_code`, `tool_code_write`, `tool_library`) + backsliding lint | +180 / -50 | PR-1 |
| **PR-3** | LLM prompt 의 `kind` field 인식 추가 (`prompts/keeper-tool-error-instruct.md`) | +30 / -5 | PR-2 + 1주일 production canary |
| **PR-4** (optional) | 2차 사이트 (~22) codemod — keeper hook / persistence 영역 | +400 / -150 | PR-2 |

## §7 Risk / Counter-arguments

### Risk 1: `Internal_error` 가 *카테고리 sink* 가 됨

다른 variant 추가가 컴파일러 enforce 안되면, 개발자가 "분류 모르겠으니 Internal_error 쓰자" 로 catch-all 회귀 가능. 

**Mitigation**: PR-2 의 backsliding lint 가 *`Tool_error.Internal_error` 직접 생성 site* 를 추적. 새 use site 추가 시 *RFC link 의무화* (PR description gate).

### Risk 2: LLM prompt 변경 cost

`kind` field 가 추가되면 LLM 이 기존 string prefix match 대신 *typed lookup* 사용해야. prompt 재학습 비용 발생.

**Mitigation**: PR-3 (prompt 변경) 은 *별도 stage*. backward-compat = string `detail` 도 함께 emit 하여 LLM 이 *둘 다* 사용 가능. 1주일 canary 후 prompt only-`kind` 로 단순화.

### Risk 3: `exn` 객체 보존이 cross-process serialization 차단

`Internal_error.exn : exn option` 은 *in-process* 한정. wire format 으로 보낼 때는 `exn=None` + `detail` 문자열만.

**Mitigation**: §2.2 JSON format 이 `exn` 제외. 본 RFC 는 *in-process* 에서 디버그 surface 유지 + *wire* 에서 typed kind 전달.

## §8 메모리 / 컨텍스트

- `memory/masc-mcp-log-audit-2026-05-20-final-synthesis.html` §"5. 12 RFC candidates" line 127 (HIGH 8 sites enum)
- `feedback_fallback_constant_to_discriminated_union` (2026-05-14): closed sum type 으로 *unknown→permissive default* 박멸 사례
- `feedback_exhaustive_match_sweep_type_plus_arm` (2026-05-12): repo 전수 grep 시 *type+arm shape* 로 patten 잡기 — PR-2 의 codemod 가 이 패턴 따름
- RFC-0098 `Openai_compat_error_map` — SDK 레벨 error mapping (본 RFC 와 *비-목표 boundary*)
- RFC-0105 `route_keeper` audit — `keeper_turn.ml:521-531` 의 `Agent_sdk.Error.to_string` lossful surface (deferred, 본 RFC 의 *후속 candidate*)

## §9 미해결 (Open Questions)

- Q1: `Cancelled` variant 가 OCaml `Eio.Cancel.Cancelled` 와 어떻게 mapping? — PR-1 검토.
- Q2: `Resource_exhausted` 의 *resource* enumeration 이 string free-form? typed sub-variant (`Fd`, `Memory`, `Disk`) 으로 더 좁혀야? — PR-1 결정.
- Q3: PR-4 의 2차 사이트가 RFC-0042 PR-4 의 *terminal code* RFC 와 충돌? — RFC-0042 완료 대기.

## §10 체크리스트 (워크어라운드 거부 self-check)

- [x] Telemetry-as-fix 아님 (counter 추가 없이 *root-fix variant*)
- [x] String/Substring 분류기 *제거* (`Failure msg` → `tag` field)
- [x] N-of-M 미적용 — PR-1 후 PR-2 가 *all 8 sites* 일괄 codemod (sub-batch 분할은 review 편의 한정, 의도는 atomic)
- [x] Cap/cooldown/dedup/repair 없음
- [x] Test backdoor 없음
- [x] 같은 typo N× fix 없음
- [x] Catch-all 추가 없음 (`Internal_error` 는 catch-all *축소* 도구 — exn 객체 보존 + tag)
