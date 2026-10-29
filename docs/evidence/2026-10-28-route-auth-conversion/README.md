# 경로 등록 383곳에 인증 종류를 붙인 변경의 근거 (다계정 A4b)

2026-10-28, main `197f56852c5` 기준이에요.
`lib/server`에서 `Http.Router.get/post/add/prefix_*/ws_get`를 부르던 383곳을 `Server_route.*`로 바꿨어요.
이제 등록마다 인증 종류(`Public_read`, `Permission …`, `Self_authenticated …`)를 적어야 해요.

이 문서는 "응답이 달라지지 않았다"를 어떻게 확인했는지, 달라질 수 있는 자리가 어디인지, 확인하지 못한 것이 무엇인지 적어요.
측정은 모두 main `197f56852c5`로 만든 서버와 이 브랜치로 만든 서버를 같은 방법으로 돌려서 나란히 놓은 거예요.
main은 그 사이 `83e86ad154f`까지 7커밋 앞으로 갔어요. 그 7커밋은 `lib/keeper`, `lib/runtime`, `config`, `docs`, `.agents`, changelog 조각, 시험 파일만 바꾸고 이 브랜치와 겹치는 파일이 없어요(`git merge-tree`로 합쳐 봐도 충돌이 없어요).

## 바꾼 것

- 파일 35개, 등록 383곳이에요. 도구(`route_auth_codemod`, #46598)가 306곳을 바꿨고(첫 커밋), 사람이 75곳과 `ws_get` 2곳을 정했어요(둘째 커밋). 이유는 커밋 메시지와 `docs/rfc/RFC-typed-route-auth.md` §3.1에 있어요.
- 종류를 하나 더했어요. `Public_read_on_canonical_host`는 `Public_read`와 같은 접근이에요. `localhost` 같은 별칭 호스트를 정규 호스트로 돌려보내는 검사를 `Public_read` 앞에 둬요. `/dashboard` 페이지 3곳이 원래 이 순서였고, 경로 표에는 `public_read`로 적혀요. 호스트 리다이렉트 함수는 `Server_canonical_host`로 옮겼어요.
- 이 변경 뒤 `lib`와 `bin`에는 `Http.Router`의 등록 함수를 부르는 코드가 없어요. 옛 함수를 가리키는 주석 둘(`bin/main_eio.ml`, `lib/server/server_mcp_transport_ws.ml`)과 옛 함수를 쓰는 시험 파일 다섯(`test_server_route`, `test_http_server_eio`, `test_dashboard_http_core`, `test_keeper_asks_http`, `browser_addon_webextension_probe`)이 남아 있어요. 옛 함수를 지우는 A4d에서 같이 바꿔요.
- 경로 표는 386개이고 모두 종류가 있어요(`tools/auth_route_inventory` 출력). main에서는 386개 모두 `unclassified`였어요.

| 종류 | 경로 수 | 종류 | 경로 수 |
|---|---:|---|---:|
| `Public_read` | 132 | `Self_authenticated Mcp_transport` | 13 |
| `Token_permission` | 130 | `Tool` | 12 |
| `Tool_actor` | 39 | `Read_auth` | 11 |
| `Permission` | 15 | `Self_authenticated Oauth_protocol` | 10 |
| `Always_public` | 14 | `Self_authenticated Browser_lane` | 4 |
| `Private_token_permission` | 1 | `Self_authenticated Websocket_upgrade` | 2 |
| `Self_authenticated Loopback_dev_token` | 1 | `Self_authenticated Subpath_dispatch` | 2 |

`Public_read` 132개에 `Public_read_on_canonical_host` 3개가 들어 있어요.

## 확인한 것

### 1. 자격이 없는 요청과 틀린 bearer

main으로 만든 서버와 이 브랜치로 만든 서버에 A1 기준선(`run.sh`)을 돌렸어요.
설정은 기본과 엄격(`MASC_HTTP_AUTH_STRICT=true MASC_AUTH_STRICT=strict`) 두 가지예요.
설정마다 main을 두 번, 이 브랜치를 한 번 돌려서 모두 여섯 번이에요. main을 두 번 돌리는 까닭은 2번에서 설명해요.

- (메서드, 경로) 조합 387개 × 요청 4개(HTTP/1.1과 HTTP/2, 자격 없음과 틀린 bearer) × 설정 2개, 3,096개 상태 코드가 모두 같아요. 이 가운데 4개는 3초 안에 답이 없었는데(기본 설정에서 `/api/dashboard/execute-output/`와 `/api/v1/dashboard/execute-output/`의 HTTP/1 요청), 두 빌드가 똑같았어요.
- 라우터 밖에서 처리하는 경우 78개 × 설정 2개, 156개도 같아요. `/mcp`, `/ws`, `/api/v1/ide/lsp` 업그레이드, query `token`, 다른 `Host`가 여기 들어가요. `WWW-Authenticate` 헤더에 서버 주소가 들어 있어서 포트는 지우고 비교했어요.
- `dev-token` 응답의 모양(키 `actor`, `role`, `token`)도 같아요.
- 여섯 번 모두 서버가 중간에 멈추지 않았어요.

비교 스크립트(`compare.py`)가 차이를 잡는지는 `test_compare.py`의 시험 20개가 봐요. 비교 규칙을 하나씩 망가뜨려 보면(6가지) 시험이 실패해요.

경로마다 전후 상태는 `comparison.csv`에 있어요.

### 2. worker와 admin 토큰으로 보낸 요청

`AUTH_BASELINE_CREDENTIALS=1`로 `run.sh`를 돌리면 서버를 띄우기 전에 `masc login`으로 Worker 토큰과 Admin 토큰을 base path에 만들어요.
경로마다 같은 요청을 네 가지로 보내요. 자격 없음, 틀린 bearer, Worker 토큰, Admin 토큰이에요.

- Admin은 GET에만 보내요. POST, PUT, DELETE는 권한이 있으면 일을 하기 때문에 격리 서버에서도 보내지 않았어요.
- 응답마다 상태, 헤더(`date`, `content-length`, `server-timing` 빼고 전부), 본문 해시를 남겨요. 본문은 앞 256 KiB만 보고, 포트, 시각, 임시 디렉터리, UUID, 긴 16진수를 가린 뒤 해시를 내요. 토큰 값은 응답에서도 가려요.
- main 서버를 두 번 돌려서 실행마다 저절로 달라지는 응답을 찾아요. 두 실행에서 상태가 다르면 비교하지 않고, 헤더가 다르면 그 헤더만 빼고, 본문이 다르면 JSON 필드 중 두 실행에서 값이 같은 것만 비교해요. 두 실행에서 본문이 같았는데 이 브랜치에서 다르면, 빼기로 적어 둔 필드를 뺀 나머지가 모두 같아야 해요.
- 빌드 정보처럼 두 빌드가 다를 수밖에 없는 필드와, 타이밍 탓에 두 실행의 값이 우연히 같은 필드는 `volatile_fields.txt`에 이유와 함께 적어서 뺐어요. 규칙 18개 가운데 6개는 경로 하나에만 걸어요.

결과는 이래요.

- 응답 2,776개(설정 2개 × 경로 387개 × 자격 3가지, 더하기 Admin이 보낸 GET 227개 × 2): 상태가 다른 것 0개, 헤더가 다른 것 0개예요. main 두 실행에서 상태가 달라서 건너뛴 응답도 0개예요.
- 본문은 2,557개가 같고, 203개는 JSON 필드로 비교해서 같고, 16개는 비교하지 못했어요(아래 "확인하지 못한 것").
- 엄격 설정에서 Worker 토큰의 응답 387개 가운데 131개가 403이고 134개가 200이에요. Admin 토큰의 GET 응답 227개 가운데 152개가 200이에요. 자격이 없는 응답 387개 가운데 342개가 401이에요.

경로 종류마다 하나씩 고른 응답이에요. 칸은 자격 없음, 틀린 bearer, Worker, Admin(GET만) 순서의 상태 코드이고 `-`는 보내지 않았다는 뜻이에요. main과 이 브랜치가 같아요.

| 종류 | 경로 | 기본 설정 main | 기본 설정 이 브랜치 | 엄격 설정 main | 엄격 설정 이 브랜치 |
|---|---|---|---|---|---|
| always_public | `GET /` | 302/302/302/302 | 302/302/302/302 | 302/302/302/302 | 302/302/302/302 |
| public_read | `GET /.well-known/agent-card.json` | 200/200/200/200 | 200/200/200/200 | 401/401/200/200 | 401/401/200/200 |
| read_auth | `GET /api/v1/gate/connector/names` | 401/401/400/400 | 401/401/400/400 | 401/401/400/400 | 401/401/400/400 |
| permission | `GET /api/v1/dashboard/browser-lane/clients` | 401/401/503/503 | 401/401/503/503 | 401/401/503/503 | 401/401/503/503 |
| token_permission | `GET /api/v1/artifact-app-data/` | 401/401/403/400 | 401/401/403/400 | 401/401/403/400 | 401/401/403/400 |
| private_token_permission | `POST /api/v1/lane-addons/operator` | 401/401/403/- | 401/401/403/- | 401/401/403/- | 401/401/403/- |
| tool | `GET /api/v1/gate/keeper-status` | 401/401/400/400 | 401/401/400/400 | 401/401/400/400 | 401/401/400/400 |
| tool_actor | `GET /api/v1/lane-addons/broadcast-principal` | 401/401/200/200 | 401/401/200/200 | 401/401/200/200 | 401/401/200/200 |
| self_authenticated:mcp_transport | `POST /` | 401/401/400/- | 401/401/400/- | 401/401/400/- | 401/401/400/- |
| self_authenticated:oauth_protocol | `GET /.well-known/oauth-authorization-server` | 200/200/200/200 | 200/200/200/200 | 200/200/200/200 | 200/200/200/200 |
| self_authenticated:browser_lane | `POST /browser-lane/disconnect` | 403/403/403/- | 403/403/403/- | 403/403/403/- | 403/403/403/- |
| self_authenticated:websocket_upgrade | `GET /api/v1/ide/lsp` | 401/401/0/0 | 401/401/0/0 | 401/401/0/0 | 401/401/0/0 |
| self_authenticated:loopback_dev_token | `GET /api/v1/dashboard/dev-token` | 200/200/200/200 | 200/200/200/200 | 404/404/404/404 | 404/404/404/404 |
| self_authenticated:subpath_dispatch | `GET /api/v1/keepers/` | 404/404/404/404 | 404/404/404/404 | 401/401/404/404 | 401/401/404/404 |

### 3. 같은 래퍼가 같은 순서로 걸려요

래퍼는 `with_public_read`, `with_permission_auth`처럼 핸들러 앞에서 인증을 확인하는 함수예요.
컴파일러 파서로 main의 소스와 변환 뒤 소스에서 등록마다 걸리는 래퍼를 바깥쪽부터 순서대로, 겹쳐 걸린 횟수까지 뽑고, `~permission`과 `~tool_name` 인자도 같이 봐요.
새 소스에서는 종류가 가리키는 래퍼도 같이 세어요. `Permission p`는 `with_permission_auth ~permission:p`이고, `Public_read_on_canonical_host`는 `with_canonical_loopback_host`가 `with_public_read`를 감싸는 둘이에요.

등록 383곳 가운데 375곳은 래퍼 순서와 인자가 같고, 8곳이 달라요.

| 등록 | main | 변환 뒤 | 이유 |
|---|---|---|---|
| `GET /api/v1/dashboard/telemetry` | 없음 | `with_public_read` | 핸들러(`handle_telemetry`)가 다른 파일에서 `with_public_read`를 불렀어요. 스캔은 다른 파일을 따라가지 않아요. 이제 등록이 `Public_read`이고 핸들러에서는 래퍼를 뺐어요. 같은 래퍼예요. |
| `POST /api/v1/lane-addons/{actions,attach,observe,detach,retain,evidence}` 6곳 | `~tool_name` (변수) | `~tool_name:"masc_lane_act"` 등 글자 | 공용 함수 `post ~tool_name`이 변수로 받았어요. 등록마다 글자로 적었고, 값은 main의 호출부 인자와 같아요(`masc_lane_act`, `masc_lane_attach`, `masc_lane_observe`, `masc_lane_detach`, `lane_addon_retain_route`, `masc_lane_evidence`). |
| `POST /api/v1/lane-addons/operator` | 바깥에 `with_scoped_headers` | 없음 | 래퍼가 거절할 때 같은 헤더 셋을 쓰고, 핸들러의 응답은 모두 `reply`를 거치면서 같은 헤더를 다시 붙여요. 이 등록의 거절 응답 헤더는 2번에서 같았어요. |

한계는 두 가지예요.
핸들러가 다른 파일에 있으면 따라가지 않고, 같은 파일 안에서는 세 단계까지만 따라가요.

### 4. 도구가 허락을 요구한 두 경우

도구는 아래 둘을 기본으로 거절하고, 사람이 확인한 뒤 옵션으로 켜야 바꿔요. 근거는 첫 커밋 메시지에 있어요.

- 이름 붙은 핸들러 10개(`--allow-named-after-external-use-review`): 자기 파일 밖에서 쓰이지 않고 `.mli`에도 없어요.
- 계산된 `~tool_name` 인자 11개(`--allow-early-evaluation`): 정해진 선택지(variant)의 상수 값이나 바뀌지 않는 값에 이름 변환 함수를 적용한 것이라, 등록할 때와 요청이 올 때 결과가 같아요.

### 5. `/dashboard` 페이지의 호스트 검사 순서

`/dashboard`, `/dashboard/`, `/dashboard/` 아래 화면 경로는 호스트 검사가 `with_public_read` 앞에서 돌았어요.
`Public_read`로만 등록하면 이 순서가 뒤집혀서, 별칭 호스트(`localhost`)로 온 요청이 서버가 준비되기 전에는 503, workspace 전제조건 쿼리가 틀리면 400, 안 맞으면 409를 받아요.
그래서 `Public_read_on_canonical_host`로 순서를 지켰어요.
호스트 검사 함수 넷은 `Server_canonical_host`로 옮겼고, main의 `server_routes_http_routes_frontend.ml`에 있던 함수와 공백을 빼고 글자가 같아요.

- 시험: `test_server_route`가 서버 상태가 없을 때와 준비됐을 때 별칭 호스트의 응답을 `Public_read`만 쓴 경로와 나란히 봐요. 호출 순서를 뒤집으면 둘 다 실패해요(뒤집어서 확인했어요).
- 서버: `dashboard_host_probe.sh`가 서버를 띄우고, 부팅하는 동안 별칭 호스트(`localhost:<포트>`)로 `/dashboard`와 `/health/ready`를 계속 불러서 서버가 준비되기 전의 응답을 잡아요. 준비된 뒤에는 호스트 둘, 페이지 셋, 전제조건 쿼리 넷, 24개 요청의 응답을 재요. main은 포트 18981, 이 브랜치는 18982예요.

결과는 이래요.

- 부팅 중: 서버가 아직 준비되지 않은 구간(`/health/ready`가 503)에서 별칭 호스트로 부른 `/dashboard`는 main에서 23번, 이 브랜치에서 29번 모두 302(리다이렉트)였어요. `Public_read`만 쓴 경로는 같은 조건에서 503을 줘요(`test_server_route`). 구간의 길이는 부팅 시간에 따라 달라서 횟수가 다르지만, 두 빌드가 같은 답을 줘요.
- 준비된 뒤: 24개 요청의 응답이 같아요(차이 0개). 별칭 호스트는 12개 모두 302이고 `Location`이 요청의 쿼리를 그대로 가져가요. 정규 호스트는 쿼리가 없거나 맞으면 핸들러까지 가고(이 서버에는 dashboard 파일이 없어서 핸들러가 503을 줘요), 파라미터가 하나뿐이면 400, 안 맞으면 409예요. 리다이렉트 주소에 들어 있는 서버의 base path는 서버마다 달라서 `<BASE>`로 바꿔 비교했어요.

### 6. 시험

소스에 변경한 모듈의 이름이 나오는 시험 파일은 81개예요. 한 파일에 시험이 여러 개 들어 있어요. 그중 `browser_addon_webextension_probe`는 시험이 아니라 `--manifest`를 받아야 도는 도구라서 80개가 시험이고, 81개 모두 두 빌드에 돌렸어요.

`dune`을 거치지 않고 실행 파일을 직접 돌렸어요(`run_tests.sh`). 환경 변수는 `PATH`, 새 `HOME`, `DUNE_SOURCEROOT`, `MASC_MAIN_EIO_EXE`만 줘요. 이 저장소 루트의 셸에는 `MASC_*` 변수가 있고, 공개 `MASC_HTTP_BASE_URL`이 있으면 여러 시험의 답이 달라지기 때문이에요. main은 `197f56852c5`, 이 브랜치는 `d7bae504821`에서 돌렸고, 두 트리 모두 `lib`, `bin`, `test`에 커밋하지 않은 파일이 없어요(`build.txt`). 그 뒤 커밋은 `lib`, `bin`, `test`를 바꾸지 않아요.

- 72개는 두 빌드 모두 통과해요.
- 종료 코드가 두 빌드에서 같은 시험: 81개 / 81개.
- 9개는 이 맥에서 실패해요. 실패하는 번호와 첫 단언이 두 빌드에서 같은지 봤어요.

| 시험 | main 실패 번호 | 이 브랜치 실패 번호 | 같음 | 알아낸 원인 |
|---|---|---|---|---|
| `test_play_page` | page 3, 5 | page 3 | 아니오 | 5번은 간헐적이에요(아래). 3번은 찾지 않았어요 |
| `test_channel_gate_connector_routes` | sidecar_connector_state 10 | sidecar_connector_state 10 | 예 | 찾지 않았어요 |
| `test_http_pages_asset_read` | dashboard_assets 0, 1 | dashboard_assets 0, 1 | 예 | Eio 밖에서 `Fiber.get`을 불러 `Effect.Unhandled`가 나요 |
| `browser_addon_webextension_probe` | - | - | 예 | 시험이 아니라 `--manifest`를 받아야 도는 도구예요 |
| `test_heartbeat_integration` | direct_keepalive 17 | direct_keepalive 17 | 예 | Docker 이미지 `masc-sandbox-test:ci`가 이 맥에 없어요 |
| `test_play_current_credential_authority` | routes 0, 1, 2, 3, 4, 8, 9, 11, 12, 13, 14, 15, 16 | routes 0, 1, 2, 3, 4, 8, 11, 13, 14, 15, 16 | 아니오 | 실패하는 번호가 돌릴 때마다 달라요(아래) |
| `test_server_lane_inventory` | read boundaries 5 | read boundaries 5 | 예 | 찾지 않았어요 |
| `test_tui_ask_followup_result` | protocol/resources 10 | protocol/resources 10 | 예 | `waitpid`가 `EINTR`로 끊겨요 |
| `test_verification_operator_evidence` | download 0 | download 0 | 예 | 찾지 않았어요 |

두 시험은 같은 빌드를 다시 돌려도 실패하는 번호가 달라요(`repeat_test.sh`, 출력은 `tests/repeat-*.txt`).

- `test_play_page`: 5번 시험은 두 빌드 모두 돌릴 때마다 통과와 실패가 오가요. 단독으로 8회씩 돌리면 main에서 5회, 이 브랜치에서 4회 실패하고, 앞에 있는 시험들을 같은 HOME으로 돌린 뒤에 8회씩 돌리면 main에서 4회, 이 브랜치에서 4회 실패해요. 3번 시험은 32회 중 32회 실패해요.
- `test_play_current_credential_authority`: 단독으로 6회씩 돌려도 실패하는 번호가 달라요. 6회 모두 실패한 번호는 main이 0, 2, 3, 4, 8, 12, 13, 14, 15, 이 브랜치가 0, 2, 3, 4, 11, 12, 16이고, 가끔 실패한 번호는 main이 1, 9, 10, 11, 16, 이 브랜치가 1, 8, 9, 10, 13, 14, 15예요. 두 빌드 모두 가끔 실패한 번호는 1, 9, 10예요. 한쪽에서만 보인 번호(8, 11, 13, 14, 15, 16)는 6회로는 우연인지 가를 수 없어요.

## 응답이 달라질 수 있는 자리

위 측정에서 달라진 응답은 없어요. 코드를 읽고 다르게 움직일 수 있다고 본 자리가 다섯 곳 있고, 모두 응답이 같다고 판단했어요.

| 자리 | 바뀐 것 | 같다고 보는 이유 |
|---|---|---|
| `GET /api/v1/dashboard/telemetry` | 핸들러 안에서 부르던 `with_public_read`를 등록 종류 `Public_read`로 옮겼어요. | 같은 래퍼가 같은 순서로 걸려요. |
| `POST /api/v1/lane-addons/operator` | 바깥 `with_scoped_headers`를 뺐어요. | 래퍼가 거절할 때 같은 헤더 셋을 쓰고, 핸들러 응답은 모두 `reply`를 거치면서 같은 헤더를 다시 붙여요. 거절 응답은 2번에서 같았어요. 권한이 있는 토큰으로 일이 끝난 응답은 POST라서 재지 못했어요. |
| `published_artifacts`의 읽기 경로 | `authorized_capability_read` 안에서 `with_public_read`를 부르던 것을 `Public_read` 종류로 옮기고, 선택 토큰 확인만 `capability_read`에 남겼어요. | 순서가 `with_public_read`, 선택 토큰 확인, 요청 한도 확인으로 그대로예요. |
| `GET /api/v1/dashboard/runtime-probe` | `force` 쿼리를 읽는 일이 인증 뒤로 갔어요. | `bool_query_param`은 쿼리만 읽고 값을 돌려줘요. |
| `/dashboard`, `/dashboard/`, `/dashboard/…` | `Public_read_on_canonical_host`로 등록해요. | 호스트 검사가 `with_public_read` 앞에서 도는 순서를 그대로 지켜요. 5번에서 시험과 서버로 확인했어요. |

`dev-token`은 핸들러가 loopback과 엄격 설정을 먼저 보고 나서 `with_public_read`를 불러요. 래퍼를 그 자리에 그대로 두고 종류만 `Loopback_dev_token`으로 적어서 응답이 같아요.

## 확인하지 못한 것

- Admin 토큰은 GET에만 보냈어요. 권한이 있는 토큰으로 POST, PUT, DELETE가 통과하는 경우는 일을 해 버리기 때문에 재지 못했어요. 종류마다 허용과 거절은 `test_server_route`가 worker와 admin 토큰으로 봐요.
- 응답 본문 16개를 비교하지 못했어요. 상태와 헤더는 같아요.
  - `/api/v1/prompts`, `/api/v1/providers`(12개): 본문이 256 KiB를 넘어서 앞부분만 남겼고, JSON이 중간에 잘려서 필드를 읽을 수 없어요. 해시는 앞 256 KiB만 덮어요.
  - `/graphql`(4개): 응답마다 바뀌는 `nonce`가 들어 있는 HTML이에요.
- `GET /api/v1/dashboard/logs`는 서버 로그의 꼬리라서 `entries`를 비교에서 뺐어요. 대신 `logs_tail_diff.py`로 `HTTP auth rejected` 줄이 두 빌드에서 같은지 봤어요. 최신 줄부터 두 창이 닿는 데까지 같아요. 그 밖에 한쪽에만 있는 줄은 주기 작업 로그(`periodic task gc` 등)와 창 끝에서 밀려난 줄이었어요.
- 3초 안에 답이 없는 응답 16개가 있어요. `GET /api/dashboard/execute-output/`, `GET /api/v1/dashboard/execute-output/`, `GET /api/v1/ide/lsp`예요. 두 빌드가 똑같이 답이 없었다는 것만 알아요.
- prefix 경로 33개는 하위 경로 한 칸(`/probe-a1`)만 보내서 하위 경로의 인증을 재지 못했어요. 이 33개는 3번으로만 확인했어요.
- 래퍼 비교(3번)는 다른 파일의 핸들러 안에서 걸리는 래퍼를 따라가지 않아요.
- 키퍼와 외부 연동이 없는 서버라서, 그게 있어야 열리는 응답은 재지 못했어요.
- HTTP/2 게이트웨이(`server_h2_gateway_routes_extra.ml` 등)는 이 변경에 없어요. HTTP/2도 위 1번에서 상태가 같았지만, 게이트웨이가 같은 경로에 같은 인증을 거는지는 A4c에서 따로 다뤄요.
- 이 저장소의 PR CI는 changelog 형식만 검사해요. 컴파일과 시험 결과는 이 문서의 로컬 결과가 전부예요.
- 두 서버를 지금 이 맥에서 돌렸어요. 다른 OS나 다른 빌드 설정에서는 재지 않았어요.

## 따로 이슈로 남긴 것

- [#46662](https://github.com/jeong-sik/masc/issues/46662): `/api/v1/keepers/` prefix 등록 둘은 하위 경로마다 인증이 달라서 `Subpath_dispatch`로 적었어요. 하위 경로별 종류는 경로 표에 없어요.
- [#46663](https://github.com/jeong-sik/masc/issues/46663): `Server_routes_http_routes_workspace.add_routes`가 두 번 불려서 등록 줄이 396개, 도달하는 경로가 386개예요.
- [#46560](https://github.com/jeong-sik/masc/issues/46560): `dev-token`은 loopback이고 엄격 설정이 꺼져 있으면 자격 없이 토큰을 줘요. `Loopback_dev_token`으로 적었어요.
- [#46569](https://github.com/jeong-sik/masc/issues/46569): `GET /api/v1/board/flairs`는 래퍼가 없고 공개 목록에도 없어서 엄격 설정에서 닫히지 않아요. `Always_public`으로 적었어요.
- [#46675](https://github.com/jeong-sik/masc/issues/46675), [#46676](https://github.com/jeong-sik/masc/issues/46676): HTTP/2 게이트웨이를 HTTP/1 등록과 맞춰 보다가 찾은 차이예요. A4c에서 다뤄요.

## 다시 돌리려면

저장소 루트에서 실행해요. 서버를 띄우는 스크립트는 빈 환경, 새 base path, loopback으로만 돌고, 포트에 이미 서버가 있으면 멈춰요.

1. 기준선 전후 비교. main 빌드를 두 번, 이 브랜치 빌드를 한 번, 기본·엄격 설정으로 각각 돌려요.
   세 실행 모두 이 브랜치의 `run.sh`를 써요. `<out>/<이름>/default`, `<out>/<이름>/strict`가 `compare.py`가 읽는 모양이에요.

   ```
   AUTH_BASELINE_CREDENTIALS=1 scripts/auth-route-baseline/run.sh <main_eio.exe> <auth_route_inventory.exe> <port> <work-dir> <out>/before/default
   AUTH_BASELINE_CREDENTIALS=1 scripts/auth-route-baseline/run.sh <main_eio.exe> <auth_route_inventory.exe> <port> <work-dir> <out>/before/strict MASC_HTTP_AUTH_STRICT=true MASC_AUTH_STRICT=strict
   (같은 명령을 main 빌드로 한 번 더 <out>/before2에, 이 브랜치 빌드로 <out>/after에)

   scripts/auth-route-baseline/compare.py <out>/before <out>/after --noise <out>/before2 \
     --ignore-file scripts/auth-route-baseline/volatile_fields.txt --csv comparison.csv --responses-csv responses.csv
   scripts/auth-route-baseline/logs_tail_diff.py <out>/before <out>/after
   ```

   `compare.py`의 마지막 줄이 `compared 6028 statuses, 0 problems`로 끝나요. 여섯 번을 이어서 돌리면 이 맥에서 19분 걸렸어요.
   `AUTH_BASELINE_CREDENTIALS=1` 없이 돌리면 자격 없음과 틀린 bearer만 보내요.

2. 비교 규칙의 시험.

   ```
   python3 -m unittest discover -s scripts/auth-route-baseline
   ```

3. 래퍼 비교. 컴파일 부산물이 소스 옆에 남지 않게 임시 디렉터리에서 만들어요.

   ```
   work=$(mktemp -d)
   cp docs/evidence/2026-10-28-route-auth-conversion/scan_args.ml "$work" && (cd "$work" && ocamlfind ocamlopt -package compiler-libs.common -linkpkg scan_args.ml -o scan_args)
   rg -l 'Server_route\.(get|post|add|prefix_get|prefix_post|prefix_put|prefix_delete|ws_get)\b' lib/server | sort > "$work/files.txt"
   mkdir "$work/old" && while read -r f; do git show "197f56852c5:$f" > "$work/old/$(basename "$f")"; done < "$work/files.txt"
   "$work/scan_args" old "$work"/old/*.ml > "$work/old.tsv"
   "$work/scan_args" new $(cat "$work/files.txt") > "$work/new.tsv"
   python3 docs/evidence/2026-10-28-route-auth-conversion/compare_args.py "$work/old.tsv" "$work/new.tsv"
   ```

   마지막 줄이 `375 registrations with the same chains, 8 with different ones`로 끝나요.

4. `/dashboard` 호스트 검사. main 빌드와 이 브랜치 빌드에 한 번씩 돌린 뒤 비교해요.

   ```
   docs/evidence/2026-10-28-route-auth-conversion/dashboard_host_probe.sh <main 빌드의 main_eio.exe> <port> <work-dir> main.json
   docs/evidence/2026-10-28-route-auth-conversion/dashboard_host_probe.sh <이 브랜치 빌드의 main_eio.exe> <port> <work-dir> a4b.json
   python3 docs/evidence/2026-10-28-route-auth-conversion/dashboard_host_probe.py compare main.json a4b.json
   ```

   마지막 줄이 `24 requests, 0 differences`로 끝나요.

5. 시험. 두 빌드에 같은 시험을 먼저 `dune build --root . test/<이름>.exe`로 만든 뒤 돌려요.

   ```
   docs/evidence/2026-10-28-route-auth-conversion/run_tests.sh <tree> <out-dir> <시험 이름>...
   ```

6. 변환 자체는 도구(#46598)로 다시 만들 수 있어요. main `197f56852c5`에서 첫 커밋의 메시지에 적힌 명령을 그대로 돌려요.

## 파일

이 폴더:

- `comparison.csv`: 경로마다 자격 없음·틀린 bearer의 상태 코드 네 개씩(`mode, method, route_path, probed_path`, 전 4개, 후 4개).
- `responses.csv`: Worker·Admin을 포함한 응답마다 전후 상태와 비교 결과(`mode, method, route_path, probed_path, identity, before_status, after_status, skipped, body, fields_checked, problems`).
- `scan_args.ml`, `compare_args.py`: 등록마다 걸리는 래퍼를 뽑는 스캐너와, 두 결과를 짝지어 다른 등록을 보여 주는 스크립트.
- `dashboard_host_probe.py`, `dashboard_host_probe.sh`, `dashboard_host_main.json`, `dashboard_host_a4b.json`: `/dashboard` 호스트 검사를 재는 스크립트와 그 결과.
- `run_tests.sh`, `tests/main/`, `tests/a4b/`: 시험을 돌리는 스크립트와, 시험마다 출력(`<시험>.txt`), `results.tsv`, `build.txt`(커밋, 도구 버전).

`scripts/auth-route-baseline/`: `run.sh`, `probe.py`, `probe_extra.py`, `compare.py`, `volatile_fields.txt`, `logs_tail_diff.py`, `test_compare.py`.
