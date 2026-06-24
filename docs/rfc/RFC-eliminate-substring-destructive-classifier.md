---
rfc: "eliminate-substring-destructive-classifier"
title: "Eliminate Substring Destructive Classifier in Favor of Typed Shell IR"
status: Draft
created: 2026-06-24
updated: 2026-06-24
author: vincent
supersedes: []
superseded_by: null
related: ["0005", "0208", "0254", "0286"]
implementation_prs: []
---

# Eliminate Substring Destructive Classifier in Favor of Typed Shell IR

## 1. 문제 (Problem)

masc 에는 셸 명령 위험도를 판정하는 두 계층이 공존한다.

1. **Typed Shell IR** (`lib/exec/shell_ir_risk.ml` `classify`, `lib/exec/exec_dispatch.ml`
   `dispatch_decided`, `lib/exec/checked_shell_ir.ml` `classify_proof`): 셸 명령을 AST 로 파싱해
   phantom-typed `undecided -> decided` 전이로 위험 클래스(`R0_Read | R1_Reversible_mutation |
   R2_Irreversible | Destructive_protected`)를 부여한다. exhaustive match(110+ GADT 생성자, catch-all 없음),
   compositional pipeline risk, catastrophic floor 를 갖춘다. RFC-0208 이 governing.

2. **Substring 분류기** (`lib/eval_gate.ml` `detect_destructive` / `detect_evasion`):
   `String_util.contains_substring_ci` 로 lowercased 명령에 `config/destructive_ops.toml` 의 패턴
   카탈로그를 substring 매칭한다. `detect_evasion` 은 `Re.execp` regex.

처음 가설은 "substring 은 typed 의 중복(redundant)이므로 삭제하면 된다" 였다. **이 가설은 측정으로
반증됐다** (§3). substring 계층은 autonomous keeper 의 typed 경로보다 **더 넓은 집합을 차단**한다.

## 2. 실행 토폴로지 (Phase 0 검증 완료, 2026-06-24, origin/main dfd344783c)

### 2.1 worker 는 셸을 로컬 실행하지 않는다
worker 도구는 전부 MCP 프록시(`worker_container.ml:298-332` `build_oas_mcp_tools`). worker 의 Bash
호출은 `call_masc_tool`(`worker_container.ml:316`, MCP RPC)로 keeper 에 전달되어 keeper 가 typed Shell IR
로 실행한다. 따라서 worker command 는 두 게이트를 순차 통과한다:
- Gate 1 (worker-side, substring): `Eval_gate.detect_destructive` (`worker_oas.ml:369`)
- Gate 2 (keeper-side, typed): `keeper_tool_execute_runtime.ml:511-513`

### 2.2 keeper lane 은 autonomous overlay 다
`keeper_tool_execute_runtime.ml` (RFC-0254 §5.2/§5.5): Ask 에 답할 인간/resolver 가 없어 overlay 는
`autonomous` — **모든 non-catastrophic risk class 는 `Observe` ⇒ Allow + telemetry**.

### 2.3 autonomous keeper 의 typed 무조건 차단은 두 가지뿐
1. `Shell_ir_risk.is_destructive` (risk = `Destructive_protected`) — `keeper_tool_execute_runtime.ml:513`
   hard block.
2. `Approval_policy.catastrophic_floor` (`approval_policy.ml:107`) — `find_destructive_git` /
   `find_write_escape` / `find_catastrophic_program`. `dispatch_classified` 의 trust·flag 독립 floor.

`Approval_policy.decide` 의 등급 채점(`max_risk` × trust overlay)은 autonomous 에서 전부 `Observe`⇒Allow 이므로
위 두 가지 외에는 아무것도 막지 않는다. 즉 **R2_Irreversible(비-catastrophic)은 autonomous keeper 에서 허용**된다.

## 3. 측정된 gap (differential harness, §5)

`test/test_destructive_floor_differential.ml` 는 `config/destructive_ops.toml` 18개 패턴 각각에 대해
substring verdict 과 autonomous-keeper typed verdict 을 계산한다. 결과:

| 상태 | 수 | 패턴 |
|---|---|---|
| **typed 이미 커버** (즉시 삭제 가능) | 6 | `rm -rf`, `git push --force`, `git push -f`, `git reset --hard`, `git clean -f`, `mkfs` |
| **GAP** (substring 차단 / autonomous keeper 허용) | 12 | 아래 |

GAP 12 (= Phase 2 work-list):

| class | 대표 명령 | typed 가 못 막는 이유 |
|---|---|---|
| sql_destructive | `psql -c "drop table …"` / `drop database` / `truncate table` / `delete from` | SQL 이 psql 문자열 인자 — typed 는 셸 파서라 caps 에 안 잡힘 |
| recursive_delete | `rm -r` (force 없음), `rmdir` | `is_destructive_bash_operation` 은 `rm` 에 recursive **AND** force 요구; rmdir 미모델 |
| privilege_escalation | `chmod 777` | catastrophic_floor 비대상 |
| process_signal | `kill -9`, `pkill` | catastrophic_floor 비대상 |
| system_control | `shutdown`, `reboot` | catastrophic_floor 비대상 |
| device_write | `dd if=…` | `mkfs` 는 catastrophic_program 인데 `dd` 는 누락 (typed floor 내부 비일관성) |

**결론**: substring 을 지금 삭제하면 위 12개의 유일한 차단막이 사라진다 — autonomous keeper 안전 회귀.
substring 은 레거시 중복이 아니라 "irreversible/privileged 도 차단"이라는 *더 엄격한 정책의 유일한 인코딩*이다.

## 4. 결정 (Decisions)

### D1. 셸 명령 위험 판정의 단일 권위 = typed Shell IR. 단 삭제 전 typed floor 를 substring 수준으로 올린다
순서는 "substring 삭제 후 typed 가 커버"가 아니라 **"typed floor 확장 → 동등성 harness 증명 → substring 삭제"**.

### D2. worker pre-hook substring 은 keeper typed 게이트의 upstream 중복 — 단 §3 gap 이 닫힌 뒤 삭제
worker command 는 keeper typed 게이트(Gate 2)를 반드시 통과(§2.1). gap 이 닫히면 Gate 1 은 순수 중복이 되어
삭제 가능. keeper_guards(`keeper_guards.ml:649`)·eval_gate trajectory(`eval_gate.ml:325,348`) pre-hook 도 동일.

### D3. gap 각 class 의 목표 동작은 정책 결정 — Phase 2 에서 class 별 확정
`shutdown`/`reboot`/`rm -r`/`rmdir`/`dd`/`chmod 777`/`kill`/`pkill` 은 typed floor(또는 GADT risk arm)로 흡수
권장(현 substring 차단 동작 유지). SQL 은 셸 IR 의 범위 밖(DB 관심사) — typed 로 흡수할지, 별도 typed
DB-capability 로 다룰지, 또는 autonomous keeper 에서 허용으로 완화할지는 §6 에서 사용자 결정 대기.

### D4. gh 등 string-borne 위험은 RFC-0208 §4(B1)대로 word-list floor 가 영구 소유
"전멸"의 스코프는 *eval_gate substring 계층* 제거이지 B1 floor 폐지가 아니다.

## 5. 마이그레이션 (Phased)

### Phase 0 — 검증 게이트 (완료)
실행 토폴로지(§2) + `Tool_capability.Destructive` 는 셸 전용 아님(Tool_catalog 플래그) 확인.

### Phase 1 — differential-safety harness (완료, 본 PR)
`test/test_destructive_floor_differential.ml`. read-only 결정론. substring verdict vs autonomous-keeper typed
verdict 을 18 패턴에 대해 계산하고, gap 을 baseline ratchet 으로 고정(현재 12). gap 이 silent 하게 늘면 red.

### Phase 2 — typed floor 확장 (gap 축소)
class 별로 typed risk arm / catastrophic_floor 를 확장해 gap baseline 을 줄인다. 각 PR 은 harness baseline 을
함께 줄이며, harness 가 회귀 0 을 증명. (SQL class 는 §6 결정 후.)

### Phase 3 — substring 삭제 + drift-guard
baseline = 0 도달 시 `detect_destructive`/`detect_evasion`/dead `pre_check`·`guarded_execute` 제거,
worker/keeper_guards/eval_gate pre-hook 제거. drift-guard 로 substring 분류기 재등장 차단.

## 6. 미결 정책 질문 (사용자 결정 필요)
- SQL 차단(`drop table` 등): typed Shell IR 가 psql 문자열 인자를 모델링하지 않는다. 선택지 — (a) typed
  DB-capability 신설, (b) 현행 substring 동작을 명시적 좁은-스코프 가드로 보존, (c) autonomous keeper 에서
  허용으로 완화(현 substring 정책 변경). 제품 안전 정책 결정.
- `kill`/`pkill`/`shutdown`/`reboot`/`chmod 777`: autonomous keeper 차단 유지가 맞는지(권장 유지).

## 7. 검증 (Verification)
- CI 빌드 green (local 아님).
- Phase 1 harness green (gap = baseline).
- Phase 2 각 PR 은 baseline 축소 + harness green.

## 8. 트레이드오프 / 리스크
- gap 이 12개로 크다 — naive 삭제의 위험을 정량 입증. 작업은 *typed 안전 floor 확장*(중간 규모)이다.
- harness 모델은 autonomous overlay(가장 관대 = 안전 worst-case)를 기준 — enforced/HITL keeper 는 gap 이 더
  작다. 보수적 선택.
- device_write `> /dev/` (redirect 형)은 harness corpus 에서 제외(Redirect_scope 구성 필요); catastrophic_floor
  write-escape 가 별도 커버. `dd if=` 가 class 대표.
