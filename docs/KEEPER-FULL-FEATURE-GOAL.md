# MASC Keeper 기능 우선 검증·개선 계획

> Status: Active implementation plan
> Scope: Keeper의 실제 제품 기능, 연속 실행, 실행 결과 관측

## 1. 목표

목표는 새로운 범용 프레임워크나 정책을 만드는 것이 아니다. Keeper에서 이미
제공하는 기능이 요청부터 terminal 결과까지 실제로 동작하고, 기다림이나 재시작이
필요한 기능은 같은 작업을 이어가며, 실패하면 실패 지점이 사용자에게 드러나게 한다.

현재 사용 가능한 GLM Coding, Kimi Coding, Ollama Cloud, local llama-server,
Codex subscription, Claude Code subscription은 이 사용자의 live 검증 자원이다.
제품 코드에 이 목록, 개수, 이름, 전용 역할 정책을 넣지 않는다. local
llama-server의 모델 이름도 제품 개념이 아니다.

Lane은 특정 종류의 일을 수행하는 실행 경로다. Runtime은 어떤 Lane에도 할당할 수
있다. `librarian`, `verification`, `judge`, `fusion panel`, `meta judge`는
Runtime의 고정 role이 아니다. 실제 Lane 실행이 실패하면 그 실행 경계의 기능 고장으로
관측하며, 사전 runtime-role 정책으로 할당을 막지 않는다.

## 2. 완료 판정

기능별 완료 기준은 그 기능의 사용자 관점 동작이다.

1. 요청이 실제 실행 경계까지 도달한다.
2. 의도한 결과, 사용자가 확인할 수 있는 구체적인 실패, 또는 효과가 실행됐을
   가능성은 있지만 결과를 증명할 수 없는 명시적 `Effect_outcome_unknown` /
   `Indeterminate` 상태로 끝난다.
3. 해당 기능이 원래 제공하는 상태/receipt/UI가 있다면 실제 결과와 모순되지 않는다.

기능이 wait, async handle, queue, scheduler 또는 process restart를 포함하면 같은
identity로 후속 진행되는 것도 확인한다. 해당 기능과 무관한 fleet 상태, runtime 수,
optional telemetry, 증거 문서의 존재를 제품 실행 조건으로 만들지 않는다.

관측 인프라가 없거나 오래됐다는 이유만으로 정상 기능을 막지 않는다. 단, 요청한
실행 의미가 바뀌는 경우에는 명시적으로 실패해야 한다. 예를 들어 Docker 실행 요청을
Host 실행으로 몰래 바꾸는 것은 허용하지 않는다.

외부 효과의 결과가 indeterminate이면 같은 효과를 재실행, 재시도 또는 보상하지
않는다. 대상 상태를 별도로 확인하거나 operator가 명시적으로 결론낼 때까지 unknown을
보존한다. 실행 결과와 재시도 의미의 권위는 이 계획 문서가 아니라
`lib/tool_types/tool_result.mli`와 `lib/keeper/keeper_gate_replay.mli`의 typed source
계약이다.

성능·효율 최적화는 baseline 기능이 동작한 뒤 별도 PR로 다룬다. 최적화가 없어도
기능이 정확히 동작한다면 admission gate로 만들지 않는다.

## 3. 기능 범위와 조사 방법

먼저 live canary로 기능을 실행한다. 실패가 재현되면 필요한 방법만 선택해 경계를
좁힌다. 다음 세 방법은 선택지이며 모든 기능의 통과 조건이 아니다.

- A — source path: 입력이 어느 reducer와 effect boundary를 지나 어느 store/receipt에
  도달하는지 추적한다.
- B — focused scenario: 성공, 명시적 실패, 재개/중복 중 해당 기능에 필요한 경우만
  작은 fixture로 확인한다.
- C — live scenario: 먼저 `/health?full=1`에서 `effective_base_path`와
  `effective_masc_root`를 읽고, 확인된 effective root에서 고유 canary ID로 실행한 뒤
  API, receipt, Dashboard를 같은 ID로 대조한다.

| 기능 | source 조사 예시 | focused 확인 예시 | live 실행 예시 |
|---|---|---|---|
| 자율 turn·승계 | turn 시작→provider→후속 turn | wait/restart가 필요한 경로 | Keeper가 이전 작업을 이어 완료 |
| Queue·Scheduler | enqueue→claim→terminal receipt | blocked/failed head가 있는 경로 | 고유 event/occurrence의 처리 순서 |
| HITL Auto Judge | request→judge→resolution→wake | approve/reject/defer 중 구현된 결과 | configured judge로 owner가 다시 진행 |
| Tool·Multi·Batch | tool plan→dispatch→result | 순차/독립 병렬/partial failure | 실제 tool 결과와 호출 순서 |
| Async | accept→handle→observe/cancel→terminal | terminal 및 cancel | handle을 다시 조회해 최종 결과 확인 |
| Board·Task·Goal·Broadcast | command→store revision→event | duplicate/revision conflict | canary 객체의 생성부터 terminal |
| Verification·Fusion·Judge | producer/panel→verdict→consumer | partial/all-fail 및 judge 단계 | 실제 configured topology 한 건 완료 |
| Sandbox | TOML→effective meta→execute target | Docker 준비 실패 | Docker 또는 명시적 실패, Host 강등 없음 |
| Stream·Reasoning | provider event→reducer→projection | replay/out-of-order/same text | 같은 event 1회, 다른 동일 text 보존 |
| Dashboard | receipt/store→API→UI | loading/stale/failed projection | DOM 숫자·상태와 같은 시각 API 대조 |

fixture와 source 추적은 live 실패를 설명하고 수정을 좁히기 위해 사용한다. 기존
artifact만으로 원인이 분명한 경우에는 불필요한 새 harness를 만들지 않는다.

## 4. 상태와 SSOT

새로운 campaign-wide evidence registry를 먼저 만들지 않는다. 기능을 조사할 때
source에서 현재 producer-owned store와 consumer를 확인하고 그 경계를 유지한다.
Dashboard/SSE/OTel은 product 상태를 보여주는 consumer이며 복구 권위로 사용하지 않는다.

한 기능에서 dual writer나 fallback reader가 실제 불일치를 만들면 그 기능 PR에서
producer와 consumer를 추적한 뒤 제거한다. 모든 subsystem을 새 Journal로 이전하는
작업을 선행 조건으로 삼지 않는다.

핵심 로직은 가능하면 `Raw -> Resolved -> Decision -> Command`의 pure core로 두고,
filesystem/network/process effect는 바깥 shell에서 실행한다. 유효한 상태 조합은
곱타입의 boolean 묶음보다 닫힌 합타입으로 표현한다. 이 원칙 역시 기존 기능을
막는 새 framework를 만들기 위한 이유로 사용하지 않는다.

## 5. 현재 확인된 실제 고장과 수정 순서

### 5.1 Dashboard 상태 의미

- As-Is: 같은 화면에서 executable, running fiber, configured roster가 같은
  `실행 중` 또는 `정상` 의미로 섞였다. Gate loading이 fleet health를 가리기도 했다.
- To-Be: fresh health의 executable, shell의 Keeper fiber, roster-derived running을
  서로 다른 이름으로 표시한다. backend status와 operator-action 신호를 둘 다 보존하고,
  action 신호가 없는 non-ok 상태를 숨기거나 주의 항목으로 재해석하지 않는다. 미수집은
  0이 아니라 unknown으로 표시한다.

### 5.2 Sandbox 설정 전달

- As-Is: direct/message turn이 TOML로 resolve한 meta를 registry의 raw Local meta로
  다시 덮어썼다.
- To-Be: 최신 registry meta에 한 번 읽은 TOML defaults를 overlay한 단일 effective
  meta를 runtime/tool/receipt까지 전달한다.

### 5.3 Docker의 Host 강등

- As-Is: Docker image preflight 실패 시 Host target으로 바꿔 실행할 수 있었다.
- To-Be: Local 요청만 Host에서 실행한다. Docker 요청은 Docker target에서 실행하거나
  구체적인 typed tool failure로 끝난다.

### 5.4 Hidden reasoning 공개 저장

- As-Is: provider thinking 원문이 raw trace와 public trajectory/API 경로에 남았다.
- To-Be: 공개 관측에는 kind, size, redacted 여부만 남긴다. Agent Core가 provider
  continuation에 필요한 private checkpoint는 이 변경에서 삭제하지 않는다.

### 5.5 Queue 정체

- As-Is: 현재 live의 일부 pending event는 owner가 operator-paused여서 처리되지 않는다.
- To-Be: 이는 곧바로 FIFO 구현 결함으로 단정하지 않는다. owner를 실행 가능한
  상태로 둔 canary에서도 claim/terminal이 유실될 때에만 queue 코드 수정 PR을 만든다.

다음 작업은 고정 architecture stack이나 고정 순서로 진행하지 않는다. queue delivery,
scheduler occurrence, HITL wake, async/batch/broadcast, verification/fusion,
Dashboard drill-down 중 live canary로 실제 실패한 경계를 먼저 수정한다. 서로 독립적인
고장은 병렬 PR로 진행한다.

## 6. 작은 PR 원칙

실제 dependency가 있을 때만 stack한다.

```text
sandbox effective meta -> Docker no-host-fallback
raw trace metadata-only -> public trajectory metadata-only
```

Dashboard truth, stream reducer 등 독립 수정은 main에서 별도 PR로 둔다. 공통 evidence
framework, runtime-role policy, unused execution-store plumbing처럼 현재 기능을 직접
고치지 않는 PR은 닫거나 보류한다.

각 PR은 다음을 지킨다.

- 하나의 재현 가능한 As-Is와 하나의 To-Be를 가진다.
- 기능을 막는 새 admission 조건을 추가하지 않는다.
- Runtime 이름이나 사용자 로컬 설정을 production OCaml variant로 만들지 않는다.
- 빠르게 Draft로 발행하고 긴 CI를 기다리지 않고 다음 독립 기능으로 이동한다.
- push 전 `git diff --check`, parser/format, 필요한 frontend typecheck와 focused test처럼
  빠른 검사를 수행한다. 로컬 Dune build는 실행하지 않고 OCaml build와 넓은 동작 검증은
  exact-head CI에서 판정한다.
- Dashboard도 reducer, interaction, reconnect를 포함한 실제 UI 기능 고장만 수정한다.

## 7. Live 실행 경계

- live 확인은 `/health?full=1`의 effective base/root를 먼저 확인한다.
- canary Board/Task/Goal에는 고유 prefix를 사용한다.
- Git/commit/PR 효과가 필요한 도구 검증은 새 private canary repository에서만 한다.
- 기존 운영 객체와 credential은 별도 승인 없이 변경하지 않는다. 격리된 canary
  Keeper와 canary config를 만들거나 변경하는 것도 operator의 명시적 승인을 받은
  범위에서만 한다. 이 계획 자체는 live mutation 권한을 부여하지 않는다.
- source, PR, CI, merged, deployed, live 결과는 서로 다른 상태로 보고한다.
- screenshot은 보조 증거이며 API/receipt와 다른 사실을 만들지 않는다.
