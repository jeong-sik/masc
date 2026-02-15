# TRPG Social Experiment Playbook (MVP)

Status: MVP experiment templates  
Updated: 2026-02-15

## 1. Experiment Set

MVP에서는 아래 3개 실험을 우선 지원한다.

1. 협상 게임 (Negotiation)
2. 루머 전파 게임 (Rumor Propagation)
3. 신뢰/공공재 게임 (Trust & Public Goods)

## 2. 공통 실행 프로토콜

1. 룸 생성: 실험 ID와 seed를 고정한다.
2. 참가자 매핑: `dm + players`를 연결한다. (`dm_control=keeper|human`)
3. 시작: `briefing -> round` 진입을 확인한다.
4. 관측: 모든 이벤트를 append-only로 수집한다.
5. 종료: stop condition 충족 시 `resolution -> end`.
6. 리포트: 메트릭 요약 + 이벤트 리플레이 링크 저장.

## 2.1 DM Mode

- `keeper DM`: DM도 keeper가 맡아 자동 진행
- `human DM`: 운영자가 DM 콘솔에서 직접 판정/서사 입력
- 같은 시나리오를 두 모드로 반복 실행해 차이를 비교할 수 있다.

## 3. Template A — Negotiation

### 목표

- 제한된 라운드 안에 다자 합의를 도출하는 과정을 관찰한다.

### 가설 예시

- 초기 신뢰도가 높은 조합일수록 합의 라운드가 짧다.
- 강경 전략 비중이 높을수록 최종 만족도 분산이 커진다.

### 핵심 메트릭

- `agreement_rate`
- `rounds_to_agreement`
- `proposal_acceptance_rate`
- `coalition_switch_count`

### 그래픽 추천

- 턴 타임라인
- 제안/거절 Sankey
- 동맹 관계 그래프(라운드별 edge 변화)

## 4. Template B — Rumor Propagation

### 목표

- 정보가 전파되며 왜곡/증폭되는 패턴을 관찰한다.

### 가설 예시

- 전파 경로 길이가 길수록 원문 보존율이 하락한다.
- 고중앙성 노드가 있는 경우 확산 속도가 빨라진다.

### 핵심 메트릭

- `spread_depth`
- `spread_breadth`
- `source_recall_rate`
- `distortion_score`

### 그래픽 추천

- 확산 네트워크 그래프(노드 색=왜곡도)
- 라운드별 누적 도달 히트맵
- 원문-파생문 유사도 라인차트

## 5. Template C — Trust & Public Goods

### 목표

- 개인 이익과 집단 이익 간 긴장에서 협력이 유지되는지 본다.

### 가설 예시

- 반복 라운드에서 제재 메커니즘이 있으면 free-riding이 감소한다.
- 초기 3라운드 협력 패턴이 장기 협력 안정성을 예측한다.

### 핵심 메트릭

- `avg_contribution_rate`
- `free_rider_ratio`
- `sanction_frequency`
- `cooperation_stability_index`

### 그래픽 추천

- 개인별 기여도 stacked chart
- 신뢰도 매트릭스(행렬 heatmap)
- 제재 이벤트 타임라인

## 6. 로그/데이터 규칙

- 모든 실험은 동일 event envelope를 사용한다.
- 후처리 메트릭은 원시 이벤트(`turn.action.resolved` 등)에서 재계산 가능해야 한다.
- 요약값만 저장하지 말고 원본 이벤트를 보존한다.

## 7. 안전장치

- 최대 라운드 제한 필수
- 턴 timeout 필수
- keeper 미응답 시 fallback action 허용
- 운영자 강제 종료(`room.abort`) 경로 유지

## 8. MVP Exit Criteria

- 3개 실험 모두 최소 5회 이상 재현 실행
- 동일 seed에서 핵심 메트릭 오차가 허용 범위 내 재현
- Viewer에서 메트릭과 이벤트 리플레이가 일관되게 표시
