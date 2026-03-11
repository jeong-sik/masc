# TRPG Keeper Spectator Quickstart

Status: 운영 가이드 (관전 전용)  
Updated: 2026-03-02

## 1. 목적

운영자가 직접 플레이하지 않고, `keeper`(DM + players)가 라운드를 진행하는 과정을 Viewer에서 실시간으로 관전한다.

## 2. 사전 조건

- `masc-mcp` 서버가 HTTP 모드로 실행 중이어야 한다. (`/mcp`, `/health` 접근 가능)
- Viewer 실행에 `trunk`가 필요하다.
- 최소 1개 이상의 실행 가능한 모델이 준비되어야 한다. (`new-game-models` 또는 `KEEPER_MODELS`, 권장: `default`)

## 3. 관전 루트 A (Viewer UI 권장)

### 3.1 서버 상태 확인

```bash
curl -sS http://127.0.0.1:8935/health
```

서버가 내려가 있으면:

```bash
./start-masc-mcp.sh --http --port 8935
```

### 3.2 Viewer 실행

```bash
make viewer-serve
```

브라우저에서 `http://127.0.0.1:8080` 접속 후 TRPG 모드로 진입한다.

### 3.3 새 게임 생성 (Keeper 자동 진행 준비)

1. 상단 `새 게임` 클릭
2. `DM` 1명 선택
3. 플레이어 keeper 선택 (권장 4명)
4. `new-game-models` 확인 (권장: `default`)
5. `세션 시작` 클릭

### 3.4 관전 시작

1. `자동 진행: OFF`를 눌러 `ON`으로 전환
2. 필요 시 `라운드 실행`으로 수동 턴 진행
3. `멈춤` / `재개`로 세션 제어

## 4. 관전 루트 B (CLI로 세션 부트스트랩 후 Viewer 관전)

Viewer에서 직접 세션을 만들지 않고, 터미널에서 TRPG 세션 + keeper 배치를 먼저 만든다.

```bash
KEEPER_MODELS="default" \
RUN_ROUND=1 \
ROUNDS=3 \
scripts/run_trpg_grimland_smoke.sh
```

- 출력에서 `room_id`를 확인한다.
- Viewer 상단 `방 열기`에 해당 `room_id`를 입력해 관전한다.

## 5. 실시간 관측 포인트

### 5.1 SSE 스트림 (raw 이벤트)

```bash
curl -N "http://127.0.0.1:8935/api/v1/trpg/stream/sse?room_id=<ROOM_ID>"
```

### 5.2 상태 조회 (현재 턴/phase)

```bash
curl -sS "http://127.0.0.1:8935/api/v1/trpg/state?room_id=<ROOM_ID>" | jq
```

## 6. 점검 체크리스트

- 세션 시작 직후 `session.started` 이벤트가 보인다.
- `자동 진행` 활성화 후 turn 번호가 증가한다.
- `라운드 실행` 시 `turn_before -> turn_after`가 증가하거나 진행 사유(`progress_reason`)가 반환된다.
- 세션 종료 시 `session.outcome` 또는 `session.ended` 계열 이벤트가 기록된다.

## 7. 자주 막히는 경우

### 7.1 `라운드 실행`이 잠겨 있는 경우

- 자동 진행이 이미 실행 중인지 확인한다.
- 동일 room에서 다른 탭/프로세스가 라운드를 실행 중인지 확인한다.

### 7.2 DM/플레이어 미선택 오류

- `새 게임` 패널에서 DM 1명, 플레이어 keeper를 다시 선택한다.
- DM과 플레이어에 같은 keeper를 중복 지정하지 않는다.

### 7.3 모델 응답 지연/실패

- `new-game-models` 값을 현재 사용 가능한 모델로 변경한다.
- 필요 시 `ROUND_TIMEOUT_SEC`, `ROUND_KEEPER_TIMEOUT_SEC`를 늘린다.

## 8. 관련 스크립트

- `scripts/viewer-local-e2e-check.sh`: 로컬 Viewer + TRPG 계약/스모크 점검
- `scripts/run_trpg_grimland_smoke.sh`: keeper 자동 배치 + 라운드 실행 워크로드
- `scripts/harness_trpg_session_contract.sh`: 세션 부트스트랩 계약 점검

## 9. 다음 문서

- 운영자가 Dashboard에서 실제 개입 절차와 복구 루틴까지 보려면 `docs/TRPG-OPS-MANUAL.md`를 함께 본다.
