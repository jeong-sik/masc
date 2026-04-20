# 허풍을 책임지기 위한 Reputation 시스템 구현 계획 (Task-044)

## 1. 개요 (Overview)
MASC(다중 에이전트 스트리밍 조정) 환경 내에서 에이전트들이 작업의 완료(DONE), 상태, 의도를 선언할 때, 실제 증거 없이 허풍(블러핑)이나 약속만 남기는 현상("말로만 하는 건 안 한 거다")을 시스템적으로 차단하고 추적하기 위한 Reputation(평판) 시스템을 설계한다.

## 2. 문제 정의 (The Weak Assumption)
현재 에이전트들은 `[STATE]` 블록이나 텍스트를 통해 상태를 약속하지만, 이를 어겼을 때 받는 패널티가 없다. 
* "내가 이 태스크를 완수하겠다"고 Claim하고 아무것도 안 하거나,
* "Broke the loop"라고 선언하며 정작 Tool Call은 하지 않는 가짜 루프에 빠진다.
이는 에이전트의 자기 선언(Self-reporting)이 검증된 사실(Verified fact)과 동일하다는 취약한 가정(Weak assumption)에 기반한다.

## 3. 핵심 설계 (Core Design)
*   **신뢰 점수 (Trust Score/Reputation)**: 각 에이전트(혹은 인증 토큰/Identity)는 기본 평판 점수를 갖는다.
*   **검증 게이트 (Verification Gate)**: 에이전트가 Task를 Claim하거나 Done으로 전환하려면, 반드시 시스템 레벨의 증거(Evidence Ref, 실제 Tool Call의 결과, 변경된 워크트리, CI 통과 등)가 첨부되어야 한다.
*   **패널티 (Penalties)**:
    *   증거 없이 "Claim/Done"을 선언할 경우: 평판 점수 차감.
    *   일정 점수 이하로 떨어진 Identity: `masc_claim_next` 호출 시 권한 거부(Unauthorized / Insufficient Reputation).
    *   연속적인 실패나 허풍 시 해당 에이전트는 샌드박스에서 격리(Quarantine)되거나, 특정 태스크 유형(예: 검증이 필요한 코드 수정)에서 배제된다.

## 4. 구현 단계 (Implementation Steps)

### Phase 1: 스키마 및 상태 확장
*   `agent_identity` 스키마에 `reputation_score` 필드 추가.
*   `task_transition` 이벤트 발생 시 `evidence_payload` 유효성 검증 로직 추가.

### Phase 2: 평가기 (Evaluator) 통합
*   상태 전환(Transition) 시 해당 에이전트가 제시한 증거(Evidence)를 검증하는 독립적인 Evaluator 데몬 프로세스 도입.
*   증거가 불충분할 시 상태 전환 거부 및 평판 점수 `-1` 차감.

### Phase 3: 보드(Board) 및 라우팅 연동
*   평판이 낮은 에이전트는 보드에 글을 쓸 때 가시성이 낮아지거나, 다른 에이전트들로부터 신뢰할 수 없는 노드(Untrusted node)로 라우팅에서 배제됨.
*   연쇄적인 합의 수렴을 방지하기 위한 "신뢰 가중치(Trust-weighted) 투표" 도입.

## 5. 의도적 반례 (Adversary View)
평판 시스템 자체가 또 다른 단일 장애점(SPOF)이 될 수 있다. 평가기(Evaluator)가 특정 에이전트의 방식을 이해하지 못해 억울하게 평판을 깎거나, 평가 기준 자체가 오염되면 어떻게 할 것인가?
**방어책**: 평판 차감 시 반드시 Audit Log(디버깅 가능한 사유)를 남기고, 오퍼레이터가 롤백(Restore)할 수 있는 API(`masc_reputation_restore`)를 열어둔다.
