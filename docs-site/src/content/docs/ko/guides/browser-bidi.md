---
title: Browser Lane BiDi 자동 기동
description: runtime.toml 설정으로 Keeper Firefox와 WebDriver BiDi 호스트를 자동 기동합니다.
---

## 개요

`runtime.toml`에 `[browser.live.bidi]` 테이블을 선언하면 MASC 서버가 기동할 때나 Keeper가 `hover_at` 또는 `drag` 액션을 요청할 때 전용 프로필의 Firefox와 WebDriver BiDi 호스트를 자동으로 데몬(detached) 프로세스로 띄우고 상태를 관리합니다.

---

## 켜는 법: 설정 및 CLI

### 1. TOML 직접 설정
`<base-path>/.masc/config/runtime.toml`을 편집합니다:

```toml
[browser.live]
enabled = true

[browser.live.bidi]
firefox = "/Applications/Firefox.app/Contents/MacOS/firefox"  # Firefox 바이너리 절대 경로
profile = "/Users/you/masc-keeper-firefox-profile"           # 전용 프로필 디렉터리
port = 9222                                                 # 선택 사항, 기본값 9222
```

### 2. CLI 설정 도구 (`masc browser-lane-setup`)
CLI 설정 명령으로 테이블을 기록하고 호스트 래퍼를 자동 설치할 수도 있습니다:

```bash
masc browser-lane-setup --mode bidi \
  --firefox "/Applications/Firefox.app/Contents/MacOS/firefox" \
  --profile "/Users/you/masc-keeper-firefox-profile" \
  --port 9222
```
*참고: `[browser.live.bidi]`가 이미 있을 때 `browser-lane-setup --mode bidi`는 전달하지 않은 키의 기존 값을 보존하며, `--firefox`, `--profile`, `--port`로 명시한 키는 전달한 값으로 갱신합니다.*

### 주요 코드 및 모듈 좌표
- `lib/browser_keeper_firefox.ml` / `lib/browser_keeper_firefox.mli`: `--no-remote --remote-debugging-port` 옵션으로 Firefox를 기동하는 로직.
- `lib/browser_host/browser_host.ml`: BiDi 호스트 런처 및 프로세스 잠금 관리.
- `lib/browser_bidi_peer.ml`: WebDriver BiDi 피어 연결 및 프로필 검증.
- `lib/browser_bidi_host_status.ml`: `bidiHost` 상태 보고 (`masc_starts`, `lane_off`, `not_configured`, `not_known`).

---

## 활성화 조건과 진단 수명주기

### 활성화 조건
- **서버 시작 시 기동**: MASC 부팅 시 `[browser.live.bidi]`가 존재하고 `[browser.live] enabled = true`이면 지정된 포트를 확인하고, 응답이 없으면 Firefox와 BiDi 호스트를 띄웁니다.
- **온디맨드 자동 복구**: 운영 중 Firefox나 호스트가 종료되더라도 Keeper가 `hover_at` 또는 `drag` 도구를 호출하면 끊어진 연결을 감지하고 단일 실행(single-flight)으로 재기동합니다.
- **분리된(Detached) 프로세스 수명주기**: Firefox와 호스트 모두 독립 프로세스 그룹(`Posix_spawn_detached`)으로 실행되어, 서버를 재시작하거나 배포해도 Keeper 브라우저 창은 그대로 유지됩니다.

### 실패 증상 및 진단
- **시작 감사 저널**: 모든 기동 시도는 타임스탬프, 포트, 프로필 경로, 결과 상태와 함께 `.masc/browser-lane/keeper-firefox-start.json`에 기록됩니다.
- **로그 파일**:
  - Firefox 출력: `.masc/browser-lane/keeper-firefox.log` (새 실행마다 `keeper-firefox.log.1`로 회전).
  - BiDi 호스트 출력: `.masc/browser-lane/bidi-host.log` (`bidi-host.log.1`로 회전).
- **프로필 잠금 충돌**: Firefox는 같은 프로필 디렉터리에 여러 인스턴스를 허용하지 않습니다. 다른 Firefox 인스턴스가 이미 프로필을 잡고 있으면 새 프로세스는 즉시 종료 코드 0으로 끝나고 포트 대기가 30초 후 타임아웃됩니다.
- **호스트 잠금 충돌**: 지정된 포트에서 이미 호스트가 잠금을 보유 중이면(`Host_running` 또는 `Host_address_unknown`) 서버는 중복 호스트를 띄우지 않습니다.
- **TUI 및 Doctor 보고**:
  - `masc doctor`는 MASC가 브라우저를 관리 중인지와 최근 실패 원인을 보고합니다.
  - TUI Browser Lane 선택기는 `bidiHost` 상태(`masc_starts` 및 포트·프로필, `lane_off`, `not_configured`)를 표시합니다.

---

## 실행 예시

### 1. 프로필 및 설정 초기화
```bash
# 격리된 Firefox 프로필 디렉터리 생성
mkdir -p "$HOME/.masc/browser-lane/firefox-profile"

# runtime.toml에 설정 추가 ($HOME이 위 경로로 확장됨)
cat << EOF >> .masc/config/runtime.toml

[browser.live]
enabled = true

[browser.live.bidi]
firefox = "/Applications/Firefox.app/Contents/MacOS/firefox"
profile = "$HOME/.masc/browser-lane/firefox-profile"
port = 9222
EOF
```

### 2. 서버 기동 및 확인
```bash
# MASC 서버 시작
masc start --base-path . --port 8935

# 다른 터미널에서 진단 상태 확인
masc doctor --base-path .

# 기동 감사 영수증 확인
cat .masc/browser-lane/keeper-firefox-start.json

# 라이브 호스트 로그 확인
tail -n 20 .masc/browser-lane/bidi-host.log
```

---

## 끄는 법 및 되돌리는 법

- **설정에서 비활성화**: `runtime.toml`에서 `[browser.live.bidi]`를 지우거나 주석 처리하거나, `[browser.live] enabled = false`로 설정하면 서버가 더 이상 브라우저 프로세스를 띄우지 않습니다.
- **실행 중인 데몬 종료**:
  ```bash
  # 분리 실행 중인 프로세스 종료
  pkill -f "firefox.*--remote-debugging-port 9222"
  pkill -f "masc[-_]browser[-_]host.*--bidi-url"
  ```
- **수동 호스트로 복귀**: Firefox를 `--remote-debugging-port 9222`로 직접 띄우고 `masc-browser-host --bidi-url ws://127.0.0.1:9222/session`을 실행합니다.

---

## 상태 및 알려진 한계

- **지원 상태**: v0.52.0에 도입되었습니다. Remote Agent를 지원하는 Firefox 157.0.1 이상이 필요합니다.
- **전용 프로필 필수**: 반드시 전용 프로필 경로를 지정해야 합니다. 평소 쓰는 기본 프로필을 지정하면 개인 브라우저가 이미 실행 중일 때 실패합니다(`--firefox-profile` 가드).
- **루프백 제한**: WebSocket BiDi URL은 보안을 위해 루프백(`127.0.0.1`)으로만 제한되며 원격 호스트는 거부됩니다.
