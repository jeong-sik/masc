# TRPG 운영 매뉴얼 (관전자/감독자 기준)

상태: v1 (Dashboard 3화면 + Control 2단계 안전 잠금)  
대상: 키퍼들이 자동으로 진행하는 TRPG를 관전/감독하는 운영자

이 문서는 `docs/TRPG-KEEPER-SPECTATOR-QUICKSTART.md`의 후속 운영 가이드다.
빠른 관전 진입은 quickstart를 보고, 실제 개입 판단과 복구 절차는 이 문서를 본다.

## 1. 빠른 시작

1. 서버 확인: `curl -sS http://127.0.0.1:8935/api/v1/status | jq .`
2. Dashboard 열기: `http://127.0.0.1:8935/dashboard#trpg`
3. 기본 화면: `Overview`
4. 흐름 확인: `Timeline`
5. 개입 필요 시: `Control` 화면으로 이동

## 2. 화면 역할

### Overview

- 목적: 현재 세션 상태를 한눈에 파악
- 확인 항목: 세션/라운드/파티/이벤트, 다음 행동, 최근 이벤트
- 운영 원칙: 여기서는 읽기 위주로 판단만 수행

### Timeline

- 목적: 실제 진행 로그를 시간 순으로 관전
- 필터: actor, event type, phase
- 사용 팁: 문제가 생기면 `timeout/fallback` 이벤트부터 필터링

### Control

- 목적: 운영 개입 (`Run Round`, `Next Turn`, `Request Join` 등)
- 기본 상태: 잠금(관전 전용)
- 잠금 해제: 120초 제한
- 위험 액션: 실행 전 2차 확인 필요

## 3. Control 안전 정책

1. 1단계: 잠금 해제 확인
- 잠금 상태에서는 조작 버튼 실행 불가
- `잠금 해제 (120초)` 클릭 시 room/phase 확인 후 해제

2. 2단계: 위험 액션 확인
- 대상: `Run Round`, `Next Turn`, `Request Join`
- 실행 직전 확인 대화상자 재확인

3. 자동 재잠금
- 위험 액션 실행 후 자동 재잠금
- 또는 120초 경과 시 자동 재잠금

## 4. 빈 상태 대응

증상: 이벤트 0건, 로비 상태

1. Control 화면에서 세션/파티 준비 상태 확인
2. DM/플레이어 keeper 배정 여부 확인
3. 세션 시작 후 라운드 실행

## 5. Viewer 실행/복구

### 기본 실행

- 빌드: `scripts/viewer-trunk.sh build --release`
- 서빙: `scripts/viewer-trunk.sh serve --port 8083`

### 내장 복구 동작

- stale lock(`viewer/.trunk-lock`) 자동 정리
- serve 시작 후 헬스체크 자동 수행:
  - `GET /`
  - `GET /api/v1/trpg/state?room_id=default`
  - `POST /mcp` (Accept: `application/json, text/event-stream`)

### 강제 해제(필요 시)

- `MASC_FORCE_UNLOCK=1 scripts/viewer-trunk.sh serve --port 8083`

### 헬스체크 우회(디버그)

- `MASC_SKIP_SERVE_HEALTHCHECK=1 scripts/viewer-trunk.sh serve --port 8083`

## 6. 자주 발생하는 문제

1. `실행 대기`가 계속 보임
- 원인: 세션 미시작, player 미배정, 엔진 연결 오류
- 조치: Overview 가이드 문구 확인 후 Control에서 선행조건 해결

2. `ERR_CONNECTION_REFUSED` 반복
- 원인: trunk serve 미기동/중단
- 조치: serve 재기동 후 포트 리스닝 확인
  - `lsof -nP -iTCP:8083 -sTCP:LISTEN`

3. 빌드는 성공했는데 화면이 안 움직임
- 원인: build 성공과 serve 정상은 별개
- 조치: `/api/v1/trpg/state`와 `/mcp` 프록시 응답을 반드시 확인

## 7. 운영 체크리스트

1. Overview에서 상태/다음 행동을 먼저 확인했다.
2. Timeline에서 이벤트 흐름을 확인했다.
3. Control 개입 전 잠금을 해제했다.
4. 위험 액션 2차 확인 내용을 확인했다.
5. 개입 후 자동 재잠금을 확인했다.
