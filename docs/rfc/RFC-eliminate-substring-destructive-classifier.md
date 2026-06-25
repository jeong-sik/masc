---
rfc: "eliminate-substring-destructive-classifier"
title: "Eliminate Substring Destructive Classifier in Favor of Typed Shell IR"
status: Draft
created: 2026-06-24
updated: 2026-06-24
author: vincent
supersedes: []
superseded_by: null
related: ["0005", "0208", "0254", "0255", "0286"]
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

### 2.3 autonomous keeper 의 typed 무조건 차단은 세 가지
1. `Shell_ir_risk.is_destructive` (risk = `Destructive_protected`) — `keeper_tool_execute_runtime.ml:513`
   hard block. **command-shape**.
2. `Approval_policy.catastrophic_floor` (`approval_policy.ml:107`) — `find_destructive_git` /
   `find_write_escape`(redirect 만) / `find_catastrophic_program`(mkfs 등 identity). `dispatch_classified` 의
   trust·flag 독립 floor. **command-shape**.
3. `Exec_policy.validate_shell_ir_paths` (path jail, `keeper_tool_execute_shell_ir.ml:82`) — 명령 **인자 경로**를
   workspace whitelist 로 가둠. **path-based**.

`Approval_policy.decide` 의 등급 채점(`max_risk` × trust overlay)은 autonomous 에서 전부 `Observe`⇒Allow 이므로
위 세 가지 외에는 아무것도 막지 않는다.

**중요 — caps 는 redirect 만 path cap 을 emit** (`capability_check.mli:13-16`): `rm`/`chmod`/`dd` 의 인자 경로는
cap 이 아니라 단순 arg 이므로 `find_write_escape`(catastrophic_floor)가 못 본다. 이들의 경로 차단은 오직 path
jail(3)이 한다. path jail 은 `Shell_ir_path_jail.enabled` 로 끌 수 있으나 **기본값 true**(`env_config_runtime.ml:956`)
이며 **영구 메커니즘**이다 — RFC-0255 §3 은 "path jail 제거"(대안 C)를 *기각*("the jail is the only write-escape
guard on Host")하고, P5 는 jail 을 *the only path* 로 graduate(=무조건화)한다. "short-lived valve, not a steady
state"·`removal target: P5` 가 가리키는 것은 jail 을 **끄는 kill-switch(disabled 상태)**이지 jail 자체가 아니다
(`keeper_tool_execute_shell_ir.ml:77-81`: "When disabled, … short-lived valve"). 즉 제거되는 건 off-switch 이고,
그 결과 jail 은 영구화된다.

### 2.4 측정 framing — command-shape only (path jail 은 별개의 영구 축)
본 RFC 의 harness 와 gap 은 (1)+(2) **command-shape 분류기**만 측정하고 (3) path jail 을 **의도적으로 제외**한다.
근거(temporariness 가 아님): ① command-shape(어떤 binary/git op/redirect 인가)와 path-scope(인자가 어디를
가리키는가)는 **직교하는 별개 축**이며, path jail 은 영구(default-on, P5 graduate)다. command-shape gap 에 path
jail 을 섞으면 "명령 정체성만으로 함의되는 파괴성"을 분리해 측정할 수 없다. ② path jail 은 target 경로만 제약하므로
path-independent 명령(kill/pkill/shutdown/reboot/SQL)을 **절대** 못 막는다 — 이들이 진짜 command-shape work-list
다. **workspace 내부** path-bearing(예: `rm -r ./build`)은 path jail 이 *설계상 허용*하는 정당한 keeper 작업이며,
substring 이 이를 **과잉 차단**한다(삭제 시 의도적으로 드롭). 따라서 path-bearing 은 floor 로 올릴 대상이 아니라
영구 path jail(workspace 밖) + 과잉성 드롭(workspace 안)으로 해소된다.

## 3. 측정된 gap (differential harness, §5)

`test/test_destructive_floor_differential.ml` 는 `config/destructive_ops.toml` 18개 패턴 각각에 대해
substring verdict 과 autonomous-keeper **command-shape** typed verdict(§2.4)을 계산한다. 결과:

| 상태 | 수 | 패턴 |
|---|---|---|
| **command-shape typed 이미 커버** (즉시 삭제 가능) | 6 | `rm -rf`, `git push --force`, `git push -f`, `git reset --hard`, `git clean -f`, `mkfs` |
| **GAP** (substring 차단 / command-shape typed 허용) | 12 | 아래 |

GAP 12 를 **path jail 이 적용 가능한지**로 분할한다(두 baseline ratchet 으로 고정):

**A. path-INDEPENDENT gap (8) — 진짜 command-shape work-list.** path 인자가 없어 영구 path jail 이 절대 못 막는다.
floor/typed risk arm 으로 흡수하거나 명시적으로 결정해야 삭제 가능:

| class | 대표 명령 | typed command-shape 가 못 막는 이유 |
|---|---|---|
| sql_destructive | `psql -c "drop table …"` / `drop database` / `truncate table` / `delete from` | SQL 이 psql 문자열 인자 — 셸 파서 caps 에 안 잡힘 |
| process_signal | `kill -9`, `pkill` | catastrophic_floor 비대상, path 없음 |
| system_control | `shutdown`, `reboot` | `Exec_program.known` 미등재 → `Privileged` 기본값 → autonomous Observe⇒Allow. `mkfs` 처럼 catastrophic-by-identity 인데 floor 미인코딩 |

**B. path-BEARING gap (4) — 영구 path jail 이 커버, floor 대상 아님.** path 인자를 가지므로 영구 path jail
(default-on, P5 graduate)이 **workspace 밖** 타깃을 막는다. 아래 in-workspace 대표값은 path jail 이 *설계상 허용*하는
정당한 keeper 작업이며(`test_rm_root_allowed_at_policy_layer_jailed_downstream` 가 argv 경로를 floor 밖에 둠을 pin),
substring 이 이를 과잉 차단한다 → Phase 3 삭제 시 의도적 드롭:

| class | 대표 명령 | 처리 |
|---|---|---|
| recursive_delete | `rm -r ./build`(force 없음), `rmdir ./build` | workspace 밖은 영구 path jail; workspace 안은 정당 작업(과잉성 드롭) |
| privilege_escalation | `chmod 777 ./script.sh` | 동일 |
| device_write | `dd if=… of=./out.img` | `dd of=/dev/sda`(device)는 path jail; `of=./out.img`(workspace 파일)은 단순 쓰기로 안전. `mkfs`(인자 무관 catastrophic)와 달리 dd 위험은 target 함수 → floor 미인코딩이 **정상**(비일관성 아님) |

**결론**: substring 은 레거시 중복이 아니라 "irreversible/privileged 도 차단"이라는 *더 엄격한 정책의 유일한
command-shape 인코딩*이다. 단 그 "더 엄격함"의 **삭제 가능 여부는 둘로 갈린다**: path-INDEPENDENT 8종
(SQL/kill/pkill/shutdown/reboot)은 영구 path jail 로도 못 막으므로 floor/decision 으로 흡수해야 진짜 gap 이 닫히고,
path-BEARING 4종은 영구 path jail + in-workspace 과잉성 드롭으로 이미 해소된다.

## 4. 결정 (Decisions)

### D1. 셸 명령 위험 판정의 단일 권위 = typed Shell IR. 단 삭제 전 typed floor 를 substring 수준으로 올린다
순서는 "substring 삭제 후 typed 가 커버"가 아니라 **"typed floor 확장 → 동등성 harness 증명 → substring 삭제"**.

### D2. worker pre-hook substring 은 keeper typed 게이트의 upstream 중복 — 단 §3 gap 이 닫힌 뒤 삭제
worker command 는 keeper typed 게이트(Gate 2)를 반드시 통과(§2.1). gap 이 닫히면 Gate 1 은 순수 중복이 되어
삭제 가능. keeper_guards(`keeper_guards.ml:649`)·eval_gate trajectory(`eval_gate.ml:325,348`) pre-hook 도 동일.

### D3. gap 해소 경로는 path-independence 로 갈린다
- **path-INDEPENDENT (floor/decision)**: `shutdown`/`reboot`(+`halt`/`poweroff`)은 catastrophic-by-identity →
  `find_catastrophic_program` 에 흡수(`mkfs` 와 동일 범주). `kill`/`pkill` 은 차단 유지 여부 결정 필요(§6).
  SQL 은 셸 IR 범위 밖(DB 관심사) — §6 결정 대기.
- **path-BEARING (floor 아님)**: `rm -r`/`rmdir`/`chmod 777`/`dd` 는 floor 로 올리지 **않는다**. 영구 path jail 이
  workspace 밖을 막고, in-workspace 형은 정당한 keeper 작업이므로 substring 의 과잉 차단을 Phase 3 에서 드롭한다.
  `test_rm_root_allowed_at_policy_layer_jailed_downstream` 가 이 경계(argv 경로는 floor 밖)를 pin 한다.

### D4. gh 등 string-borne 위험은 RFC-0208 §4(B1)대로 word-list floor 가 영구 소유
"전멸"의 스코프는 *eval_gate substring 계층* 제거이지 B1 floor 폐지가 아니다.

## 5. 마이그레이션 (Phased)

### Phase 0 — 검증 게이트 (완료)
실행 토폴로지(§2) + `Tool_capability.Destructive` 는 셸 전용 아님(Tool_catalog 플래그) 확인.

### Phase 1 — differential-safety harness (완료, 본 PR)
`test/test_destructive_floor_differential.ml`. read-only 결정론. substring verdict vs autonomous-keeper
**command-shape** typed verdict(§2.4, path jail 은 별개 영구 축이라 제외)을 18 패턴에 대해 계산하고, gap 을 두
baseline ratchet 으로 고정: path-INDEPENDENT(8, 진짜 work-list)·path-BEARING(4, 영구 jail 커버). 어느 쪽이든
silent 하게 늘면 red.

### Phase 2 — path-independent floor/decision (gap 축소)
path-INDEPENDENT gap 만 좁힌다. 우선 `shutdown`/`reboot`(+`halt`/`poweroff`)을 `find_catastrophic_program` 에
흡수(`mkfs` 와 동일, behavior-preserving) → independent baseline 8→6. `kill`/`pkill`·SQL 은 §6 결정 후. 각 PR 은
harness independent baseline 을 함께 줄이며 회귀 0 을 증명. path-BEARING 4 는 floor 대상이 아니므로 Phase 2 에서
건드리지 않는다(영구 path jail 이 권위).

### Phase 3 — substring 삭제 + drift-guard
path-INDEPENDENT baseline = 0(흡수+SQL/kill 결정 완료) 도달 시 `detect_destructive`/`detect_evasion`/dead
`pre_check`·`guarded_execute` 제거, worker/keeper_guards/eval_gate pre-hook 제거. 이때 path-BEARING in-workspace
과잉 차단이 의도적으로 드롭됨(영구 path jail 이 workspace 밖을 계속 보호). drift-guard 로 substring 분류기 재등장 차단.

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
- gap 이 12개로 크다 — naive 삭제의 위험을 정량 입증. 단 실제 floor 작업은 path-INDEPENDENT 8 에 한정되고
  (path-BEARING 4 는 영구 path jail 이 권위), 그중에서도 흡수 가능한 catastrophic 은 shutdown/reboot 류, 나머지
  (kill/pkill/SQL)는 정책 결정이다.
- harness 모델은 autonomous overlay(가장 관대 = 안전 worst-case)를 기준 — enforced/HITL keeper 는 gap 이 더
  작다. 보수적 선택.
- **path jail 제외(§2.4)는 temporariness 가 아니라 직교성 때문**: path jail 은 영구(default-on, RFC-0255 §3 가
  제거를 기각, P5 가 the only path 로 graduate)이며 command-shape 와 별개 축이다. path-BEARING 의 workspace 밖
  변형은 이 영구 jail 이 막고, in-workspace 형은 정당한 keeper 작업이라 substring 의 차단이 과잉이다 → 삭제 시
  의도적 드롭(회귀 아님). 따라서 retirement 의 전제는 "path jail 의존 회피"가 아니라 "path-INDEPENDENT gap 을
  command-shape 로 닫고, path-BEARING 은 영구 jail 에 위임"이다.
- device_write `> /dev/` (redirect 형)은 harness corpus 에서 제외(Redirect_scope 구성 필요); catastrophic_floor
  write-escape 가 별도 커버. `dd if=` 가 class 대표.
