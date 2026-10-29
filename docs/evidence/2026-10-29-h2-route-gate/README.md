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

## 확인한 것과 하지 못한 것

확인한 것:

- `with_h2_token_permission_auth`를 쓰던 11곳은 전에 적던 권한과 표의 권한이 모두 같아요(`CanAdmin` 6, `CanReadState` 2, `CanVote` 1, `CanPlayMachine` 2). 그래서 자격이 있는 요청의 응답은 달라지지 않아요.
- `when` 조건으로 고르는 갈래(건강 검사, 대시보드 화면, 키퍼 하위 경로, 융합 실행, play room, artifact-bytes, 보드 하위 경로)에서 대표 경로 13개를 골라 표에 대 봤어요. 모두 표에 있고, 종류가 갈래가 쓰던 게이트와 같아요(키퍼 하위 경로는 `Subpath_dispatch`).

하지 못한 것:

- 자격이 있는 H2 요청(Worker, Admin 토큰)을 모든 경로에 보내 보지 않았어요. A1 도구는 자격이 있는 요청을 HTTP/1로만 보내요. 위 시험이 대표 경우만 덮어요.
- `when` 갈래를 하나씩 모두 대 보지는 않았고, 갈래가 받는 경로의 변형도 보지 않았어요.
- 키퍼 하위 경로 5곳은 여전히 갈래가 직접 권한을 적어요. 이걸 표로 올리려면 하위 경로마다 등록을 나눠야 해요(`Subpath_dispatch`를 없애는 일).
- HTTP/1과 HTTP/2 핸들러가 두 벌이라서 생기는 차이(쿼리 전제조건, 호스트 리다이렉트, #46676)는 그대로예요.
