# HTTP 경로별 인증 현황 (다계정 계획 A1)

2026-10-28, main `2d6cdfbdac5`. 서버 동작은 바꾸지 않았고 지금 상태를 재기만 했어요.
이후 C 계층(경로 인증을 타입으로 묶는 작업)이 "무엇이 바뀌었는지"를 이 표와 비교해요.

## 방법

1. `tools/auth_route_inventory`가 `Server_routes_http.make_routes`의 라우터 표를 JSON으로 내보내요. 경로 396개, 메서드 조합 397개예요.
2. `scripts/auth-route-baseline/run.sh`가 격리 서버를 띄워요. 환경변수는 비우고(`env -i`), base path는 새 디렉터리, 키퍼는 없고, loopback에만 열어요. 운영 중인 워크스페이스는 건드리지 않아요.
3. `probe.py`가 조합마다 요청 4개를 보내요. HTTP/1.1과 HTTP/2(h2c) 각각 "자격 없음"과 "아무 토큰과도 맞지 않는 bearer"예요. prefix 경로는 `/probe-a1` 한 칸을 붙여서 보내요.
4. `probe_extra.py`가 라우터 밖에서 처리하는 경로를 따로 확인해요. `/mcp`와 프로필 셋, `/ws`, `/api/v1/ide/lsp`, query `token`, 서버 자신의 것이 아닌 `Host` 헤더예요.
5. 같은 일을 기본 설정(`default/`)과 엄격 설정(`strict/`, `MASC_HTTP_AUTH_STRICT=true MASC_AUTH_STRICT=strict`)으로 한 번씩 했어요.

다시 돌리려면:

```
scripts/auth-route-baseline/run.sh <main_eio.exe> <auth_route_inventory.exe> <port> <work-dir> <out-dir> [NAME=value ...]
```

## 결과 (HTTP/1.1, 자격 없음)

| 응답 | 기본 | 엄격 |
|---|---:|---:|
| 401/403 거절 | 229 | 355 |
| 2xx 성공 | 113 | 21 |
| 404 | 17 | 11 |
| 그 밖의 4xx | 30 | 5 |
| 5xx | 5 | 4 |
| 리다이렉트 | 1 | 1 |
| 응답 없음 | 2 | 0 |

쓰기 메서드(POST/PUT/DELETE) 161개 중 기본 설정에서 거절하지 않은 것은 5개예요.

- `/oauth/authorize`, `/oauth/register`, `/oauth/token`: 404. 기본 설정에서는 OAuth가 꺼져 있어요.
- `/api/v1/keepers/probe-a1`: 404. prefix 경로에 없는 이름을 붙인 것이라 정상이에요.
- `POST /api/v1/dashboard/nav-event`: 400. 인증보다 먼저 본문 검증을 해요. 엄격 설정에서는 401이에요.

## 눈에 띄는 것

1. **`GET /api/v1/dashboard/dev-token`**: 기본 설정에서 자격 없이 admin 토큰을 줘요(actor `dashboard`, role `admin`). 코드 주석에는 loopback용으로 일부러 열었고 엄격 설정에서는 없어진다고 적혀 있어요. 실제로 엄격 설정에서는 404예요. 의도된 동작이지만, 로컬에서 서버가 열려 있으면 어떤 프로세스든 admin이 되는 경로예요.
2. **자격 없이 열려 있는 읽기 경로**: 기본 설정에서 `/api/v1/dashboard/*` GET 45개 등 113개가 인증 없이 200을 줘요. 어느 것이 의도된 것인지는 이 표만으로 알 수 없어요. C 계층에서 경로마다 정해야 해요.
3. **`GET /api/v1/board`**: 자격이 없으면 200인데 틀린 bearer를 보내면 401이에요. 없는 자격은 통과시키고 틀린 자격은 거절하는 셈이에요.
4. **HTTP/2 경로 표가 달라요**: HTTP/2는 79개 조합만 처리하고 나머지는 404예요. `GET /`는 HTTP/1에서 302, HTTP/2에서 200이에요. `GET /api/v1/dashboard/namespace-truth`는 HTTP/2에서만 있고 자격 없이 200이에요(HTTP/1에서는 404).
5. **`Host` 헤더**: 서버 자신의 것이 아닌 `Host`를 보내면 `/health`, 대시보드 shell, board, `POST /mcp` 모두 400이에요.
6. **MCP 경로**: `/mcp`, `/mcp/managed`, `/mcp/operator`의 POST/DELETE는 자격이 없으면 401과 `WWW-Authenticate: Bearer`를 줘요. `GET /mcp` 스트림은 HTTP/1에서 401, HTTP/2에서 404예요. `/mcp/seat`는 404예요. `/ws`와 `/api/v1/ide/lsp` 업그레이드는 자격이 없거나 query `token`이 틀리면 401이에요.

## 한계

- 요청 본문은 `{}`뿐이에요. 본문을 제대로 보내면 400으로 끝나던 경로가 다른 결과를 낼 수 있어요. "거절" 칸은 인증 때문인지 검증 때문인지 구분하지 못해요(nav-event처럼 400이 먼저 나오는 경우만 눈에 띄어요).
- 맞는 토큰으로 보낸 요청은 재지 않았어요. 이 표는 "자격이 없거나 틀렸을 때"만 말해요.
- 기본 설정의 5xx 5개와 응답 없음 2개는 대시보드 정적 파일(`/dashboard` 계열 503 3개), `GET /api/v1/voice/config`(500), `GET /api/v1/msx/carts`(503), `execute-output/*`(3초 안에 응답 없음 2개)예요. 키퍼와 외부 연동이 없는 격리 환경 탓일 수 있지만 원인은 확인하지 않았어요.
- 라우터 표를 읽어서 만든 목록이라, 라우터에 등록되지 않은 채 요청 처리기 안에서 경로를 직접 가르는 곳은 `probe_extra.py`가 아는 만큼만 들어 있어요.

## 파일

- `default/`, `strict/`: `results.json`(조합별 상태 코드), `extra.json`(라우터 밖 경로), `routes.json`(경로 목록)
