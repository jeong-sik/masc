---
status: reference
---

# MASC Glossary

이 문서는 현재 코드와 운영 표면에 존재하는 용어만 정의한다.

## Core

**MASC**
: 다중 에이전트의 Board, Task, Goal, Schedule, Keeper와 도구 실행을 조율하는
  OCaml/Eio 서버.

**Workspace**
: 에이전트와 협업 상태가 공유되는 조율 범위.

**Agent**
: Workspace에 참여해 typed capability를 호출하는 실행 주체.

**Keeper**
: 독립된 agent core checkpoint와 MASC lifecycle을 가진 장기 실행 Agent. 현재 typed
  event와 tool schema를 관찰하고 자율 turn을 실행한다.

**Keeper Cycle**
: 현재 상태와 event를 관찰하고 Keeper turn 실행 여부를 결정하는 서버 loop의
  한 회차. 모든 cycle이 모델 호출을 실행하지는 않는다.

**Keeper Turn**
: 하나의 Keeper 작업 시도를 위해 MASC가 agent core Agent run을 실행하는 단위.

**agent core Turn**
: 하나의 agent core Agent run 내부에서 provider response와 tool 실행이 진행되는 한
  단계. Keeper turn과 동일한 단위가 아니다.

**Runtime Attempt**
: Keeper turn에서 하나의 resolved runtime 후보를 실행하는 시도.

## Collaboration State

**Board**
: 공유 발견, 질문, 답변, 의견과 결정을 게시하는 durable 협업 표면.

**Task**
: 실제 작업의 소유권과 검증 상태를 기록하는 단위. 상태는 `Todo`, `Claimed`,
  `InProgress`, `AwaitingVerification`, `Done`, `Cancelled`다.

**Goal**
: 장기 의도와 Task 연결을 기록하는 단위. phase는 `Executing`, `Blocked`,
  `Paused`, `Completed`, `Dropped`다.

**Schedule**
: 미래 시점에 Keeper를 깨우는 durable 요청. 현재 동작은 create, list, get,
  cancel이다. Schedule은 이후 외부 효과를 자동 승인하지 않는다.

**Fusion**
: 여러 독립 판단을 비동기로 수집하고 하나의 결론으로 합성하는 실행.

**Gate**
: 외부 효과를 Always Allowed, Auto Judge, HITL 중 설정된 정책으로 판정하는
  경계. pending 판정은 다른 작업을 막지 않는다.

## Repository Execution

**Repository Catalog**
: repository ID, remote URL, default branch를 소유하는 identity SSOT.

**Repository Checkout**
: Keeper가 실제로 읽고 수정할 수 있는 Git checkout. Catalog 등록만으로
  checkout 존재를 보장하지 않는다.

**Checkout Freshness**
: checkout HEAD와 명시된 local tracking ref의 ahead/behind 관계. 이 값은
  네트워크 fetch 시각이 아니라 로컬 tracking ref를 기준으로 한다.

**Sandbox**
: Keeper tool이 접근할 수 있는 writable filesystem 경계. 도구에는 반환된
  sandbox-relative path를 사용한다.

**Worktree**
: 한 repository 안에서 branch 작업을 격리하는 Git worktree.

## Continuity

**Checkpoint**
: agent core conversation과 Keeper working context의 durable 저장점.

**Generation**
: 같은 Keeper가 새 trace로 이어진 횟수. 초기값은 0이다.

**Trace ID**
: 현재 Keeper generation의 실행 식별자.

**Memory OS**
: Keeper의 durable personal facts와 recall을 소유하는 typed memory store.
