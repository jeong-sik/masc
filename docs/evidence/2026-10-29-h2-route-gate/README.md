# HTTP/2 게이트웨이가 HTTP/1 라우터에서 인증 종류를 읽게 한 변경의 근거 (다계정 A4c)

2026-10-29, main `0744b9de509`(A4d 앞부분 병합 직후) 기준이에요.
HTTP/2 게이트웨이는 갈래마다 `with_h2_public_read`, `with_h2_read_auth`, `with_h2_token_permission_auth` 중 하나를 직접 골랐어요.
이제 요청이 오면 HTTP/1 라우터에 같은 요청의 종류를 묻고(`Router.resolve`가 돌려주는 `route.access`), 그 종류에 맞는 게이트를 걸어요.

이 문서는 응답이 어디서 바뀌는지, 어떻게 쟀는지, 재지 못한 것이 무엇인지 적어요.

## 바꾼 것

- `Server_h2_route_gate`(새 모듈)가 종류를 게이트로 바꿔요. 종류와 `Subpath_dispatch` 같은 이유를 모두 이름으로 적어서, `Route_access`에 하나를 더하면 이 모듈이 컴파일되지 않아요. H2에 갈래가 없는 종류(`Permission`, `Private_token_permission`, `Tool`, `Tool_actor`, `Browser_lane`, `Loopback_dev_token`, `Subpath_dispatch`)는 열지 않고 거절해요.
- 게이트웨이는 `~routes`(HTTP/1 리스너가 쓰는 같은 표)를 받아요. `Server_runtime_bootstrap`이 H2 핸들러를 만들 때 넘겨요.
- 갈래의 게이트 호출을 바꿨어요.

| 호출 | 곳 | 설명 |
|---|---:|---|
| `h2_gate_state` | 38 | 옛 `with_h2_public_read` 35곳과 `with_h2_read_auth` 3곳 |
| `h2_gate_actor` | 11 | 옛 `with_h2_token_permission_auth`. 권한은 표에서 와요 |
| `h2_gate_unit` | 15 | 게이트가 없던 갈래: `/health` 셋, `/ws`, `/`, OAuth 6곳, MCP 2곳, agent card, favicon |
| `gate` (`routes_extra`) | 14 | 옛 `with_public_read` 9곳과 게이트가 없던 5곳 |

- 표에 종류가 없는 갈래 5곳(키퍼 `hitl`, `child-content`, `native-tasks`, `github-identity`, `github-login`)은 옛 래퍼를 그대로 불러요. HTTP/1은 `/api/v1/keepers/`를 `Subpath_dispatch`로 등록해서 하위 경로의 종류가 표에 없어요. 이 5곳에 표의 종류를 쓰면 `Open`이나 500이 돼서 일부러 두었어요.
- 갈래의 `namespace-truth` 별명(`project-snapshot`과 같은 본문)을 지웠어요. HTTP/1에 없는 경로이고 이 저장소에서 부르는 곳이 시험뿐이에요.

## 응답이 바뀌는 곳

| 설정 | 요청(HTTP/2) | 전 | 후 | 이유 |
|---|---|---:|---:|---|
| 엄격 | `GET /.well-known/agent.json`, `agent-card.json` (자격 없음, 잘못된 bearer) | 200 | 401 | 표는 `Public_read`예요. #46675를 닫아요 |
| 기본, 엄격 | `GET /api/v1/dashboard/namespace-truth` | 200, 401 | 404 | 표에 없는 경로예요 |
| 기본, 엄격 | favicon 둘, agent card 둘, 서버 상태가 아직 준비되지 않았을 때 | 200 | 503 | 표의 `Public_read` 게이트가 상태를 기다려요. HTTP/1과 같아요 |

세 번째 줄은 코드를 읽어 적은 것이고 재지 않았어요. 측정은 서버가 `/health/ready`를 준 뒤에 시작해요.

## 어떻게 쟀나요

`scripts/auth-route-baseline/run.sh`(A1)로 서버 둘을 같은 방법으로 돌렸어요.

- 전: A4d 앞부분 PR 머리(`e2f8012`, main `0744b9de509`와 트리가 같아요)로 만든 서버
- 후: 이 브랜치로 만든 서버
- 기본 설정과 엄격 설정(`MASC_HTTP_AUTH_STRICT=true MASC_AUTH_STRICT=strict`) 각각

경로 388개마다 요청 4개를 보내요(HTTP/1.1과 h2c, 자격 없음과 잘못된 bearer). `probe_extra.py`가 라우터 밖 경우 78개를 더 보내요. 비교는 `compare.py`예요. 출력은 `compare.txt`에 있어요.

```
compared 3260 statuses, 6 problems
```

달라진 항목 6개가 위 표의 첫 두 줄이에요(엄격 설정의 agent card 경로 둘, 두 설정의 `namespace-truth` 자격 없음·잘못된 bearer 넷). 다른 항목은 없어요. HTTP/1 상태 코드는 하나도 바뀌지 않았어요.

## 시험

깨끗한 환경(`env -i`, 새 HOME, `DUNE_SOURCEROOT`)으로 `run_tests.sh`를 돌렸어요.

| 시험 | 결과 |
|---|---|
| `test_server_h2_route_gate`(새) | 2개 통과. 종류 14개마다 게이트, 라우터 응답 |
| `test_h2_route_gate_http`(새) | 5개 통과. 실제 게이트웨이와 h2c 연결 |
| `test_dashboard_http_core` | 171개 통과 |
| `test_h2_request_body_admission` | 21개 통과 |
| `test_request_workspace_precondition` | 14개 통과 |
| `test_h2_listener_response_resources` | 7개 통과 |
| `test_native_task_http` | 3개 통과 |
| `test_dashboard_asset_worker` | 4개 통과 |
| `test_h2_github_response_resources`, `test_h2_oauth_request_fibers` | 각 2개 통과 |
| `test_h2_play_room` | 1개 통과 |
| `test_http_pages_asset_read` | 9개 중 3개 실패. main 빌드에서도 같은 3개 |
| `test_server_lane_inventory` | 16개 중 1개 실패. main 빌드에서도 같은 1개 |
| `test_play_page` | 7개 중 1개 실패. main 빌드에서도 같은 1개 |

실패 셋은 main 빌드(A4d 앞부분 머리)에서 같은 이름, 같은 단언 줄, 같은 예외로 실패해요. 이 변경 때문이 아니에요.

`test_h2_route_gate_http`가 보는 것:

- 엄격 설정에서 agent card가 401, 기본 설정에서 200, `/health`는 엄격 설정에서도 200
- `/api/v1/lanes`는 자격이 없으면 401, Player 토큰은 표의 `CanAdmin`이 없어서 403
- 키퍼 `github-identity`는 자격이 없으면 401(옛 래퍼)
- 표에 없는 경로 404, 표에 없는 메서드 405
- 표가 `Public_read`나 `Subpath_dispatch`로 적었는데 갈래가 행위자를 요구하면 500(열리지 않아요)

## 자격이 있는 요청

위 측정은 H2로 자격 없는 요청과 잘못된 bearer만 보냈어요. 같은 두 서버를 Worker와 Admin 토큰으로 한 번 더 쟀어요.

- `h2_identities.py`(새)가 경로 388개와, 표 프로브에 없던 `when` 갈래의 대표 경로 9개를 합쳐 397개를 h2c로 보내요. 신원은 none, bad, worker, admin이에요. admin은 GET만 보내요(A1 도구와 같아요). `run.sh`의 새 훅 `AUTH_BASELINE_AFTER`가 서버가 떠 있는 동안 이 스크립트를 돌려요.
- 같은 실행에서 A1 도구가 자격 있는 요청을 HTTP/1.1로 보내요(`AUTH_BASELINE_CREDENTIALS=1`).
- `compare.py --noise`에는 변경 전 빌드를 한 번 더 돌린 결과를 줬어요. 같은 빌드끼리도 다른 값이 무엇인지 알아내려는 거예요.

```
AUTH_BASELINE_CREDENTIALS=1 \
AUTH_BASELINE_AFTER='python3 -I docs/evidence/2026-10-29-h2-route-gate/h2_identities.py probe --routes "$AUTH_BASELINE_ROUTES" --base-url "$AUTH_BASELINE_URL" --tokens "$AUTH_BASELINE_TOKENS" --out "$AUTH_BASELINE_OUT"' \
  scripts/auth-route-baseline/run.sh <main_eio.exe> <auth_route_inventory.exe> <port> <work-dir> <out-dir>/default
python3 docs/evidence/2026-10-29-h2-route-gate/h2_identities.py compare <before-dir> <after-dir>
python3 scripts/auth-route-baseline/compare.py <before-dir> <after-dir> --noise <second-before-dir> --ignore-file scripts/auth-route-baseline/volatile_fields.txt
```

H2, 신원 네 가지(`h2-identities-compare.txt`):

```
compared 2854 statuses, 4 problems
```

달라진 4개는 모두 앞 표에 있어요.

| 설정 | 요청(HTTP/2) | none | bad | worker | admin |
|---|---|---:|---:|---:|---:|
| 기본 | `GET /api/v1/dashboard/namespace-truth` | 200→404 | 200→404 | 200→404 | 200→404 |
| 엄격 | `GET /api/v1/dashboard/namespace-truth` | 401→404 | 401→404 | 200→404 | 200→404 |
| 엄격 | `GET /.well-known/agent.json`, `agent-card.json` | 200→401 | 200→401 | 그대로 | 그대로 |

다른 모든 경로에서 Worker와 Admin 토큰의 응답은 그대로예요. 권한 11곳이 표의 권한으로 바뀐 것이 자격 있는 응답에 영향이 없다는 코드 읽기 결과를 응답으로 확인했어요.

표준 비교(`compare-credentials.txt`, 자격 있는 HTTP/1 응답 포함):

```
compared 6044 statuses, 6 problems
credentialed bodies: 2571 same, 197 compared by JSON field, 16 not compared, 0 responses skipped
```

6개는 앞 표의 처음 두 줄이에요. 본문을 비교하지 못한 16개는 `GET /api/v1/prompts`, `/api/v1/providers`, `/graphql`의 응답이에요(상태는 전후 모두 200이에요).

변경 전 빌드 두 번째 실행(노이즈) 없이 돌리면 `etag`(본문이 달라지면 같이 달라져요), `mcp-session-id`(요청마다 무작위), CSP의 nonce(응답마다 새로 만들어요) 같은 헤더 540곳이 걸려요. 노이즈 실행을 주면 이 헤더는 걸리지 않아요. 두 번의 변경 전 실행이 우연히 같은 값이었던 프로세스 카운터 몇 개(`/health`의 `logs`·`scheduler`, `runtime-observables`의 `pool`, `memprof`의 `major_*`)는 `scripts/auth-route-baseline/volatile_fields.txt`에 경로별 규칙과 이유를 더했어요.

## 확인한 것과 하지 못한 것

확인한 것:

- `with_h2_token_permission_auth`를 쓰던 11곳은 전에 적던 권한과 표의 권한이 모두 같아요(`CanAdmin` 6, `CanReadState` 2, `CanVote` 1, `CanPlayMachine` 2). 그래서 자격이 있는 요청의 응답은 달라지지 않아요.
- `when` 조건으로 고르는 갈래(건강 검사, 대시보드 화면, 키퍼 하위 경로, 융합 실행, play room, artifact-bytes, 보드 하위 경로)에서 대표 경로 13개를 골라 표에 대 봤어요. 모두 표에 있고, 종류가 갈래가 쓰던 게이트와 같아요(키퍼 하위 경로는 `Subpath_dispatch`).

하지 못한 것:

- 자격이 있는 H2 요청은 경로마다 한 번씩 보냈어요. POST·PUT은 본문 `{}`이라서 핸들러 안쪽의 응답(400 같은 것)은 그 입력에서만 확인한 거예요.
- `when` 갈래는 대표 경로 19개를 신원 4개로 보냈고, 갈래마다 받는 경로의 변형을 모두 보지는 않았어요.
- 키퍼 하위 경로 5곳은 여전히 갈래가 직접 권한을 적어요. 이걸 표로 올리려면 하위 경로마다 등록을 나눠야 해요(`Subpath_dispatch`를 없애는 일).
- HTTP/1과 HTTP/2 핸들러가 두 벌이라서 생기는 차이(쿼리 전제조건, 호스트 리다이렉트, #46676)는 그대로예요.
