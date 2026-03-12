# Dashboard Widget Audit 2026-03-12

## 범위
- 공통 shell / rail / navigation
- Mission
- Execution
- Intervene
- Command: War Room, Orchestra
- 공통 상태/시간/semantic 안내

## 분류 요약

### 유지
- 상황판 세션 카드
  - 목표, 최근 흐름, 막힘, 연결 작전을 한 카드에서 읽을 수 있어서 유지
- 실행 큐
  - 막힌 실행과 handoff 경로를 한 번에 보여주므로 유지
- 워룸 실행 흐름
  - live run, 세션, 워커 흐름을 한 화면에서 보는 진입점으로 유지
- 오케스트라 맵
  - room 전체 구조를 한 장에서 읽는 가치가 있어서 유지

### 수정
- 공통 status/time badge
  - raw 영어 상태와 `2m ago` 같은 표현이 운영 판단을 방해해서 한국어 우선으로 수정
- Mission briefing
  - `cached/stale/refreshing/metadata gap`를 truth처럼 읽기 어려워 상태명을 한국어로 정리
- Mission attention / continuity 카드
  - `unknown/n/a/evidence preview` 같은 fallback 문구를 해석 가능한 표현으로 수정
- Execution 요약/카드 제목
  - `Execution Queue`, `Affected Sessions`, `Worker Support` 같은 제목을 한국어 중심으로 수정
- Intervene 헤더 / 우선순위 카드
  - `Intervene`, `Room gate`, `Keeper pressure` 같은 표현을 한국어 우선으로 수정
- War Room 요약 카드
  - `Workers/Runtime/Pressure/Last signal` 라벨을 한국어화하고 상태를 해석 가능한 표현으로 수정
- Orchestra detail / summary strip
  - `workers/keepers/signals`와 node kind를 한국어 중심으로 수정
- Semantic layer
  - `Why/Source/Trigger/Agent Role` 같은 meta 설명을 한국어로 정리

### 제거
- 별도 제거 위젯 없음
  - 이번 턴은 misleading copy와 상태 표현을 우선 정리했고, 구조 제거까지는 진행하지 않음

## 남은 후보
- Governance / Memory / Planning / Proof / Command 기타 surfaces
  - 아직 영어 혼용과 raw status가 남아 있어 다음 단계 audit 대상
- topology / operations / control 세부 카드
  - command surface 안에서도 아직 영어 technical label이 일부 남아 있음

## 검증
- `git diff --check`
- `cd dashboard && npm ci`
- `cd dashboard && npx tsc --noEmit --pretty false`
- `cd dashboard && npm run build`
