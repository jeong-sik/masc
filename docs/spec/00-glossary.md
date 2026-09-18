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

## Task Lifecycle

**Requester**
: Task 를 만든 쪽. `created_by` 에 만들 때 한 번 적히고 바뀌지 않는다. Keeper 는
  자기가 만든 `Todo` 를 자동 claim 대상에서 뺀다.

**Assignee**
: `Claimed`, `InProgress`, `AwaitingVerification` 에 적힌 에이전트 이름. 앞의 둘에서는
  지금 일을 맡은 쪽이고, `AwaitingVerification` 에서는 제출한 쪽이다.

**Claim**
: `Todo` 인 Task 를 맡는 전이. 한 에이전트는 `Claimed` 와 `InProgress` 를 합쳐 하나만
  가질 수 있고, 이 검사는 claim 할 때만 한다. Keeper 의 claim 은 곧바로 Start 를 이어
  보낸다.

**Release**
: 맡은 쪽이 Task 를 `Todo` 로 돌려놓는 전이. Handoff Context 를 남긴다.

**Submission**
: 맡은 쪽이 증거와 함께 완료를 내는 전이(`Submit_for_verification`). 상태는
  `AwaitingVerification` 이 되고 새 Verification ID 를 받는다. 대기 중인 Task 는 claim
  한도에 세지 않는다. 제출자는 대기 중에 다시 낼 수 있고 그때마다 id 가 바뀐다.

**Intent**
: 대기 중인 청구가 완료(`Complete_task`)인지 중단(`Cancel_task`)인지. 맡은 쪽의 cancel 은
  `Cancel_task` 청구가 된다. `Todo` 의 cancel 은 청구 없이 바로 `Cancelled` 다.

**Verification ID**
: 제출 하나의 식별자. 판정은 자기가 읽은 id 가 지금 id 와 같을 때만 적용된다.

**Completion Authority**
: 판정을 내리는 쪽. 서버 안의 판정 에이전트(`System_llm_agent`)이거나 인증된 HTTP
  경로로 들어온 운영자(`Human_operator`)다. Keeper 는 판정하지 못한다. 중단 청구는
  운영자만 승인한다.

**Verdict**
: `Verdict_approved` 또는 `Verdict_rejected { reason }`. 완료 청구의 승인은 `Done`, 중단
  청구의 승인은 `Cancelled`, 거절은 어느 쪽이든 제출자의 `InProgress` 다.

**Handoff Context**
: Task 에 붙어 다니는 인계 메모. summary, reason, next_step, evidence_refs, updated_by
  를 담는다. Release, Submission, cancel 이 쓰고 Claim 과 Start 는 지우지 않는다. 거절
  판정은 이 메모를 판정 사유로 덮어쓴다.

**Evidence Reference**
: 제출에 다는 증거 참조. `artifact:`, `note:`, `board:`, `fusion:` 네 형식만 열린다.

**Rejection Delivery**
: 거절을 제출자 Keeper 에게 알릴 때까지 backlog 의 `pending_completion_rejections` 에
  남는 항목. 제출자에게 Keeper 큐가 없으면 Task 를 `Todo` 로 되돌린다.

**Operator Attention**
: 운영자만 풀 수 있는 Task 의 목록(`Operator_task_attention.item`). 종류는 `Cancel_claim`,
  `Held_without_actor`, `Producer_record_unreadable` 이다.

**Cycle Count**
: Release 로 `Todo` 에 돌아온 횟수. 화면 표시에만 쓰고 claim 순서를 바꾸지 않는다.

**Current Task**
: 에이전트 기록의 `current_task` 와 Keeper meta 의 `current_task_id`. 권위는 backlog 이고
  이 둘은 거기서 다시 계산되는 표시다.

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
