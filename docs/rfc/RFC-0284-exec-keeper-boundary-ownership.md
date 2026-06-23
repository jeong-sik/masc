# RFC-0284 — exec/keeper 스택: redirect & turn-termination 경계 소유권

- Status: Draft
- Author: Vincent (yousleepwhen) + Claude
- Created: 2026-06-23
- Parent: none (standalone diagnosis). 관련: RFC-0125(turn watchdog, 회고상 opt-in 구조로 변경), RFC-0138(lock-free audit projection)
- Scope: `lib/exec/` (`shell_command_gate`, `exec_dispatch`, `exec_effect`, `shell_ir_risk`, `path_scope`), `lib/keeper/` (`keeper_hooks_oas`, `keeper_supervisor_launch`), `lib/agent_sdk_log_bridge.ml`, `lib/turn_fsm/`
- Boundary: **동작 불변**. 본 RFC는 진단 + 경계 소유권/정합성 계약의 *명시화*만 다룬다. 런타임 동작 변경(redirect 실행 지원/거부, 카운터 통합, watchdog 재도입)은 별도 후속 RFC/PR에서, 본 RFC가 세팅한 계약 위에서.

---

## 1. 동기 (Motivation)

2026-06-23, executor keeper의 한 run에서 `unsupported redirect in native dispatch: fd 1 write to .../mind/loop-prevention-guidelines.md` 에러가 발생했다. 단발성 비정상 run(run은 `ContractOk`로 정상 종료됨)의 일시적 증상이었지만, 원인을 추적하는 과정에서 **흩어진 silent 모순 여럿**이 드러났다. 본 RFC는 그 모순들을 개별 버그가 아니라 **하나의 설계 병**으로 진단하고, 경계 소유권(boundary ownership)을 명시하는 것을 목적으로 한다.

근거 로그: `~/me/.masc/logs/system_log_2026-06-23.jsonl` (`keeper_name=executor`, 00:10–02:08Z, 244라인).

## 2. 진단 — 두 축의 모순 매핑

### 2.1 축 A: redirect 경계 (4레이어, 전부 코드 확정)

`redirect`라는 개념이 4레이어에 산재하며, 각 레이어가 **서로 다른 질문**에 답한다.

| 레이어 | 위치 | redirect를 무엇으로 다루나 | 답하는 질문 |
|--------|------|---------------------------|------------|
| gate | `shell_command_gate.ml:364-373` | 있/없 bool + `redirect_allowed` | "구문적으로 허용?" |
| dispatch | `exec_dispatch.ml:39-60` | capture/drop/fd-to-fd만; file read/write=`Error` | "실행 가능?" |
| effect | `exec_effect.ml:193-210` | `Fs_write` 라벨 (read는 `None` 증발) | "무슨 효과?" (단, 정책 결정에 **미사용**) |
| risk | `shell_ir_risk.ml` `redirect_floor` | `R0_Read`/`R1` floor | "위험 등급?" |

**확정 모순 A1**: gate가 `redirect_allowed=true`로 `>file`을 *허용*하지만 dispatch는 `Error`로 *실행 거부*한다. 이 모순은 컴파일 타임도 런타임 단언도 아닌 silent 상태로 존재한다 — gate 허용 집합 ⊋ dispatch 실행 가능 집합.

**확정 결함 A2**: `exec_effect.extract_redirects`(`exec_effect.ml:193`)의 유일 caller는 `exec_effect.ml:388`이며, `shell_command_gate`·`approval_policy`·`capability_check_typed` 어디서도 참조되지 않는다. 즉 effect 분류는 승인 게이트와 무관한 라벨링 전용 레이어다. (초기 진단에서 "classification 통과 vs execution 거부 gap"으로 오지목했으나, effect는 게이트에 기여하지 않음이 코드로 확정됨.)

**확정 결함 A3**: `exec_effect.ml:208`에서 `Redirect_scope.File { mode = Read; _ } -> None`. read redirect가 effect에서 증발한다. 측정 시 `redirect:read`가 0건으로 잡힌 원인.

**정당 설계 (결함 아님) A4**: `path_scope.ml:103` `is_discard_sink = String.equal t.raw "/dev/null"`. `/dev/null` 단독 하드코딩이지만 POSIX discard sink 정석이며 `approval_policy.ml:51-53` 주석이 의도 명시. 결함에서 제외.

### 2.2 축 B: turn-termination 경계

**확정 결함 B1 (카운터 SSOT 부재)**: 로그에 `turn=14854 total_turns=1986`이 동시 등장 — 현재 턴(14854)이 total(1986)보다 크다. 카운터 정의:
- `total_turns` = `meta.runtime.usage.total_turns` (`keeper_hooks_oas.ml:437`)
- run summary 카운터 = `turn`/`max_turns` (`agent_sdk_log_bridge.ml:166`)

최소 3개 카운터(`turn`/`total_turns`/`max_turns`)가 **서로 다른 것**을 세며, 어느 것이 "진짜 진행도/종료 판정"의 SSOT인지 정의가 없다.

**부분 확정 B2 (watchdog 경계 불명)**: `keeper_supervisor_launch.ml`에 max-turn watchdog이 **opt-in env 구조로 존재**. 회고상 RFC-0125/PR#22037로 "제거"되었다는 기록과 부분 충돌 — 완전 삭제가 아니라 구조 변경. keeper 종료 허용 상한이 현재 어디서 결정되는지 불명확.

**보류 B3/B4**: `ContractOk` done semantics(B3), `playground_state`(5/25) vs `system_log`(6/23) 상태 동기화 SSOT(B4)는 §5 open questions로 둔다.

## 3. 공통 병 — overlap + 정합성 계약 부재

`★ 핵심 진단`: 축 A와 축 B는 다른 개념이지만 **같은 설계 병**을 공유한다.

> 경계(boundary)가 아니라 **겹침(overlap)**으로 설계되었고, 겹치는 컴포넌트 사이에 **정합성 계약(contract)이 없다.**

- redirect: 4레이어가 각자 "허용/실행/효과/위험"을 판정. 누가 어떤 질문의 SSOT인지 정의 없음 → A1 silent 모순 필연.
- turn-termination: 카운터/watchdog/ContractOk/state가 각자 종료·진행도를 판정. SSOT 없음 → B1 역전 현상.

각 컴포넌트는 개별적으로 합리적이다. 합치면 silent 모순이 나오는 건, **분할이 아니라 중복**으로 설계됐기 때문이다. CLAUDE.md "경계를 정확하게 구분하는 것이 더 좋은 제품"의 역상태.

## 4. 설계 방향 — 계약 명시 (비파괴)

본 RFC는 동작 변경이 아닌 **계약 명시**만 제안한다. 구현은 별도 후속 PR.

### 4.1 레이어별 "답하는 질문" 주석화 (문서 계약)

각 레이어 모듈 헤더에 그 레이어가 redirect/turn에 대해 *유일하게* 답하는 질문을 명시한다. 예: gate는 "구문 허용", dispatch는 "실행 가능". 이것만으로도 "gate가 허용했으니 dispatch도 되겠지"라는 암묵 가정이 드러난다.

### 4.2 정합성 불변 (invariants) — 타입/단언으로 세팅

- **INV-1 (redirect 정합성)**: `gate Allow(file redirect) ⇒ dispatch executable`. 현재 위반. 해소는 후속 PR에서 — (a) dispatch가 file write를 지원하거나, (b) gate가 file redirect를 reject. 어느 쪽이든 INV-1을 **컴파일 타임 또는 게이트 단위 단언**으로 잡아 silent 모숸을 불가능하게 만든다.
- **INV-2 (turn 카운터 SSOT)**: "진행도/종료 판정"에 쓰이는 카운터는 단일 SSOT. 파생 카운터(total_turns, run summary)는 SSOT에서 *계산*되어야 하며, 각자 독립 집계하지 않는다.

### 4.3 비파괴 원칙

- 런타임 동작 불변 (현재 `>file`이 dispatch에서 실패하는 현상 자체는 본 RFC에서 바꾸지 않는다).
- 계약은 주석/타입/단언으로 명시만.
- 동작 변경(redirect 지원 여부, 카운터 통합, watchdog 재도입)은 반드시 본 RFC의 INV 위에서 별도 RFC.

### 4.4 워크어라운드 거부 명시

CLAUDE.md 워크어라운드 거부 기준에 따라, 다음은 본 RFC가 *거부*하는 접근이다:
- A1 silent 모순을 "counter로 visible하게 만드는" 텔레메트리-as-fix (모순 자체는 해소 안 됨).
- 카운터 불일치를 "dedup/normalize on read"로 숨기는 symptom 억제.
근본은 계약 명시(INV-1/INV-2)여야 한다.

## 5. Open questions (별도 조사)

- **B2 상세**: max-turn watchdog opt-in env의 현재 기본값과 keeper별 허용 상한. keeper가 14855턴까지 도는 게 허용된 구조적 이유.
- **B3**: `ContractOk` done 판정 semantics. false completion(비생산적 장기 run이 완료로 락되는) 가능성.
- **B4**: `playground_state` 갱신 주체와 `system_log` 활동 간 동기화 SSOT.
- **rg 출력 텍스트 치환 이상**: 본 진단 중 `completion_contract`·`playground_state` 등 토큰이 `n`으로 치환되어 출력되는 현지 관측. 메모리 "masc runtime fingerprint" 관련 별도 이슈 가능성.

## 6. 근거 (Evidence)

- redirect 매트릭스: `exec_dispatch.ml:39-65`, `shell_command_gate.ml:364-373`, `exec_effect.ml:193-210`, `shell_ir_risk.ml`(redirect_floor), `path_scope.ml:103`
- 카운터: `keeper_hooks_oas.ml:436-437,485`, `agent_sdk_log_bridge.ml:166`
- watchdog: `keeper_supervisor_launch.ml`(P4 max-turn watchdog, opt-in env)
- 측정: `redirect:write` 1건/`redirect:append` 0건/`redirect:read` 0건 (system_log_2026-06-23.jsonl, 11253라인) — keeper의 정상 file redirect 사용이 사실상 없음(=redirect 정책 변경의 실사용 가치 낮음 → 본 RFC는 동작 변경이 아닌 계약 명시에 한정하는 근거)
- executor run: `keeper_name=executor`, 00:10:01Z–02:08:31Z, 마지막 `completing -> done action=ContractOk` (이미 정상 종료됨)

## 7. 측정이 설계를 무효화한 사례 (메타)

본 진단의 전개 과정에서, 측정 전에 redirect 정책 변경(A/B+C) 설계를 전개한 것은 순서 오류였다. 측정(file redirect 사용 빈도 = 하루 1건)이 그 설계 전제를 무효화했다. 교훈: 설계 옵션을 세우기 전에 **실제 사용 빈도/패턴을 먼저 잰다**. 이 메타는 본 RFC가 "동작 변경이 아닌 계약 명시"로 범위를 좁힌 근거이기도 하다.
