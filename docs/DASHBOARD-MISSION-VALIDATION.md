# Dashboard Mission Validation

Mission 검증은 두 층으로 나눈다.

- 자동 검증: 결정적 fixture로 `Mission -> drill-down -> Intervene/Command` 흐름을 재현
- 수동 검증: 실시간 room 데이터로 정보 밀도와 읽힘을 확인

## 자동 smoke

```bash
scripts/harness_dashboard_mission_smoke.sh
```

환경 변수:

- `PORT`: dashboard server port, 기본 `8947`
- `BASE_PATH`: temp fixture room path. 비우면 임시 디렉터리를 생성
- `KEEP_SERVER=1`: 종료 후 서버 유지
- `KEEP_BASE_PATH=1`: 종료 후 fixture room 유지
- `PLAYWRIGHT_MODULE_PATH`: Playwright 모듈 경로 override

이 스크립트는 다음을 수행한다.

- temp base path로 MASC server 기동
- 결정적 Mission fixture seed
- `/dashboard#/mission` Playwright smoke
- `Attention Queue -> Affected Sessions -> Impacted Agents`
- `Intervene` / `Command` handoff hash 검증

## Fixture seed

직접 fixture만 만들고 싶으면:

```bash
BASE_PATH=/tmp/masc-mission-fixture \
MCP_URL=http://127.0.0.1:8947/mcp \
scripts/setup_dashboard_mission_fixture.sh
```

fixture에는 다음 신호가 포함된다.

- `spawn_failure_present`
- `local64_role_gap`
- `low_confidence_routing`
- room-level `pending_confirm_waiting`
- offline keeper 1개

## 수동 점검 체크리스트

실시간 room 데이터로 `http://127.0.0.1:8935/dashboard#/mission` 을 열고 다음을 본다.

- 첫 화면만 보고 5초 안에 “무슨 문제가 있고 어디를 눌러야 하는지” 판단 가능한가
- `Attention Queue`가 실제로 첫 메인 리스트 역할을 하는가
- session/member 정보가 과밀하지 않은가
- agent card 기본 상태에서 raw input/output이 숨겨져 있는가
- room/system 진단이 하단 보조 lane에만 남는가
- `세션 개입 열기` / `세션 원인 보기`가 올바른 target으로 이동하는가
