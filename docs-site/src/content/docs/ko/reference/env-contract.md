---
title: 환경 변수 계약 (Env Contract)
description: MASC가 읽는 환경 변수의 범위와 적용 시점.
---

환경 변수는 프로세스 부팅 계약입니다. 실행 중인 프로세스는 새 셸 값을 관찰하지 않으며, 값이 바뀌려면 재시작이 필요합니다. 영속 설정의 단일 진실 공급원은 `.masc/config/*.toml`입니다. 원본은 저장소의 `docs/ENV-CONTRACT.md`입니다.

## 적용 시점 네 범주

| 범주 | 의미 |
|---|---|
| `boot_static` | 재시작 필요. 소켓 바인딩, 설정 루트, 시작 시 로드 |
| `sweep_dynamic` | 다음 감독 스윕에 반영. 키퍼 프로필 동기화 등 |
| `request_dynamic` | 다음 요청·턴에 반영. `runtime.toml` resolve 경로 등 |
| `immediate_dynamic` | 즉시 반영. `Runtime_params` 갱신 |

기본 정책: 모든 환경 변수는 `boot_static`입니다. 라이브 조절이 필요하면 환경 변수가 아니라 `Runtime_params` 항목을 씁니다.

## 대표 변수

### 부팅 고정 (boot_static)

| 변수 | 역할 |
|---|---|
| `MASC_BASE_PATH` | 작업 공간(`.masc/`)이 위치할 루트 경로 |
| `MASC_CONFIG_DIR` | 설정 루트를 따로 지정 |
| `MASC_HOST` | 서버 바인딩 주소 |
| `MASC_HTTP_PORT` | HTTP·MCP 포트 |
| `MASC_LOG_LEVEL` | 로그 레벨(`debug`, `info`, `warn`, `error`) |
| `MASC_GRPC_PORT` · `MASC_GRPC_ENABLED` · `MASC_WS_ENABLED` | gRPC·WebSocket 전송 on/off |
| `MASC_STARTUP_WATCHDOG_SEC` | 부팅 와치독 |

### 웹 검색 (요청 시 읽기)

`[web_search]` 값을 `runtime.toml`에 두거나 환경 변수로 줄 수 있습니다. 우선순위는 프로세스 환경 변수 > `runtime.toml` > 기본값입니다.

| 변수 | 기본값 | 효과 |
|---|---|---|
| `MASC_SEARXNG_URL` | `http://localhost:8888` | 셀프호스팅 SearXNG 제공자 활성화·최우선 |
| `MASC_WEB_SEARCH_PROVIDER` | `auto` | 제공자 하나를 고정 |
| `MASC_WEB_SEARCH_TIMEOUT_SEC` | `15` | 제공자별 요청 타임아웃 |
| `BRAVE_SEARCH_API_KEY` · `TAVILY_API_KEY` · `EXA_API_KEY` · `BING_SEARCH_API_KEY` | (없음) | 해당 검색 제공자 입장 허용 |

### 프로바이더 API 키

프로바이더 키는 고정 목록이 아니라 `runtime.toml`의 `[providers.<id>.credentials]` (`type = "env"`, `key = "<변수명>"`)이 이름을 정하고, 서버는 자기가 시작된 환경에서 그 값을 읽습니다. 소스 체크아웃에서는 `quickstart.sh`가 `.env.local`(권한 600)에 쓰고 `start-masc.sh`가 읽습니다. 바이너리 설치에는 둘 다 없으니 직접 export 하세요.

## 새 환경 변수 규칙

1. 새 변수는 기본으로 `boot_static`.
2. 라이브 조절이 필요하면 `Runtime_params` 항목으로.
3. 선언 지점과 운영 문서에 `reload_class`를 적는다.
4. 운영 문서에 "runtime-readable"이라는 표현은 쓰지 않는다. 네 범주 중 하나로 적는다.
