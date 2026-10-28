# 경로 등록 383곳에 인증 종류를 붙인 변경의 근거 (다계정 A4b)

2026-10-28, main `197f56852c5` 기준이에요.
`lib/server`에서 `Http.Router.get/post/add/prefix_*/ws_get`를 부르던 383곳을 `Server_route.*`로 바꿨어요.
이제 등록마다 인증 종류(`Public_read`, `Permission …`, `Self_authenticated …`)를 적어야 해요.

이 문서는 "응답이 달라지지 않았다"를 어떻게 확인했는지, 달라지는 곳이 어디인지, 확인하지 못한 것이 무엇인지 적어요.

## 바꾼 것

- 파일 35개, 등록 383곳이에요.
- 첫 커밋은 변환 도구(`route_auth_codemod`, #46598)가 낸 결과 그대로예요. 306곳을 바꿨어요.
- 둘째 커밋은 도구가 남긴 75곳과 `ws_get` 2곳을 사람이 정한 것이에요. 이유는 커밋 메시지와 `docs/rfc/RFC-typed-route-auth.md` §3.1에 있어요.
- 이 변경 뒤 `lib`에는 `Http.Router`의 등록 함수를 부르는 곳이 없어요.
- 경로 표는 386개이고 모두 종류가 있어요(`tools/auth_route_inventory` 출력).

| 종류 | 경로 수 | 종류 | 경로 수 |
|---|---:|---|---:|
| `Public_read` | 132 | `Self_authenticated Mcp_transport` | 13 |
| `Token_permission` | 130 | `Tool` | 12 |
| `Tool_actor` | 39 | `Read_auth` | 11 |
| `Permission` | 15 | `Self_authenticated Oauth_protocol` | 10 |
| `Always_public` | 14 | `Self_authenticated Browser_lane` | 4 |
| `Private_token_permission` | 1 | `Self_authenticated Websocket_upgrade` | 2 |
| `Self_authenticated Loopback_dev_token` | 1 | `Self_authenticated Subpath_dispatch` | 2 |

## 확인한 것

### 1. 변환 전후의 응답이 같아요 (A1 기준선)

main `197f56852c5`로 만든 서버와, 그 위에 이 변경(두 커밋)을 얹어 만든 서버에 A1 기준선을 돌렸어요.
기본 설정과 엄격 설정(`MASC_HTTP_AUTH_STRICT=true MASC_AUTH_STRICT=strict`)으로 각각 한 번씩, 모두 네 번이에요.

- (메서드, 경로) 조합 387개 × 요청 4개(HTTP/1.1과 HTTP/2, 자격 없음과 틀린 bearer) × 설정 2개, 3,096개 상태 코드가 모두 같아요.
- 라우터 밖에서 처리하는 경우 78개 × 설정 2개, 156개도 같아요. `/mcp`, `/ws`, query `token`, 다른 `Host`가 여기 들어가요.
  `WWW-Authenticate` 헤더에 서버 주소가 들어 있어서 포트는 지우고 비교했어요.
- `dev-token` 응답의 모양(키 `actor`, `role`, `token`)도 같아요.
- 네 번 모두 요청 387개에 전부 응답이 왔고 서버가 중간에 멈추지 않았어요.
- 비교 스크립트가 차이를 잡는지 보려고 상태 하나와 라우터 밖 경우 하나를 일부러 바꿔 봤어요. 둘 다 잡고 종료 코드 1을 줬어요.

경로마다 전후 상태는 `comparison.csv`에 있어요.

### 2. 경로마다 같은 래퍼와 같은 인자가 걸려요

래퍼는 `with_public_read`, `with_permission_auth` 같은, 핸들러 앞에서 인증을 확인하는 함수예요.
컴파일러 파서로 main의 소스와 변환 뒤 소스에서 등록마다 걸리는 래퍼와 `~permission`, `~tool_name` 인자를 뽑아 비교했어요.
새 소스에서는 종류가 가리키는 래퍼도 같이 셌어요(`Permission p`는 `with_permission_auth ~permission:p`).

등록 383곳 가운데 376곳은 래퍼와 인자가 같고, 7곳이 달라요.

| 등록 | main | 변환 뒤 | 이유 |
|---|---|---|---|
| `GET /api/v1/dashboard/telemetry` | 없음 | `with_public_read` | 핸들러(`handle_telemetry`)가 다른 파일에서 `with_public_read`를 불렀어요. 스캔은 다른 파일을 따라가지 않아요. 이제 등록이 `Public_read`이고 핸들러에서는 래퍼를 뺐어요. 같은 래퍼예요. |
| `POST /api/v1/lane-addons/{actions,attach,observe,detach,retain,evidence}` 6곳 | `~tool_name` (변수) | `~tool_name:"masc_lane_act"` 등 글자 | 공용 함수 `post ~tool_name`이 변수로 받았어요. 등록마다 글자로 적었고, 값은 main의 호출부 인자와 같아요(`masc_lane_act`, `masc_lane_attach`, `masc_lane_observe`, `masc_lane_detach`, `lane_addon_retain_route`, `masc_lane_evidence`). |

한계는 두 가지예요.
핸들러가 다른 파일에 있으면 따라가지 않고, 같은 파일 안에서는 세 단계까지만 따라가요.

### 3. 도구가 허락을 요구한 두 경우

도구는 아래 둘을 기본으로 거절하고, 사람이 확인한 뒤 옵션으로 켜야 바꿔요. 근거는 첫 커밋 메시지에 있어요.

- 이름 붙은 핸들러 10개(`--allow-named-after-external-use-review`): 자기 파일 밖에서 쓰이지 않고 `.mli`에도 없어요.
- 계산된 `~tool_name` 인자 11개(`--allow-early-evaluation`): 정해진 선택지(variant)의 상수 값이나 바뀌지 않는 값에 이름 변환 함수를 적용한 것이라, 등록할 때와 요청이 올 때 결과가 같아요.

### 4. 시험

소스에 변경한 파일의 모듈 이름이 나오는 시험 파일은 74개예요. 그중 34개와 새 등록 함수를 보는 `test_server_route`, 모두 35개를 돌렸어요.
dune 없이 실행 파일을 직접 돌렸고, 방식 둘을 썼어요.

- A: 저장소 루트에서 실행해요.
- B: A에 `DUNE_SOURCEROOT=<저장소 루트>`를 더해요. dune이 시험을 돌릴 때 주는 변수예요.

28개는 A와 B 모두 통과해요. 나머지 7개는 어느 방식에서 실패해요. 실패하는 방식으로 main 빌드를 돌려도 같은 시험이 같은 개수로 실패해요.

| 시험 | 방식 | 이 브랜치 | main |
|---|---|---|---|
| `test_play_page` | A | 1·2·3번 실패 | 1·2·3번 실패 |
| `test_play_page` | B | 3번 실패 | 3번 실패 |
| `test_play_skills` | A | 2 실패 | 2 실패 |
| `test_play_skills` | B | 통과 | 통과 |
| `test_channel_gate_connector_routes` | A, B | 1 실패 | 1 실패 |
| `test_server_ide_http` | B | 7 실패 | 7 실패 |
| `test_board_rest_routes` | B | 1 실패 | 1 실패 |
| `test_dashboard_http_core` | B | 1 실패 | 1 실패 |
| `test_keeper_portrait_http` | B | 5 실패 | 5 실패 |

- `test_server_ide_http`, `test_board_rest_routes`, `test_dashboard_http_core`, `test_keeper_portrait_http`는 A에서는 통과해요(이 브랜치만 돌렸어요).
- `test_play_page`의 5번은 돌릴 때마다 양쪽 빌드에서 들쭉날쭉해요(원인은 보지 않았어요).
- 원인을 찾은 것은 `test_play_skills`뿐이에요. `DUNE_SOURCEROOT`가 없으면 프롬프트 레지스트리가 `config/prompts`를 못 찾아서 agent guide가 500을 줘요. 나머지는 두 빌드의 결과가 같다는 것만 확인했어요.

## 응답이 달라지는 곳

이 변경에서 일부러 바꾼 응답은 하나예요.

`GET /dashboard`, `GET /dashboard/`, 그리고 `/dashboard/` 아래의 화면 경로(prefix 등록)예요.
셋 다 `Public_read`로 등록하고, `with_canonical_loopback_host` 검사(다른 호스트면 정규 호스트로 리다이렉트)를 핸들러 안에서 해요.
전에는 이 검사가 `with_public_read` 앞에서 돌았어요.

- 정규 호스트로 오는 요청: 응답이 같아요.
- 다른 호스트로 오는 요청: 서버가 준비되기 전이면 리다이렉트 대신 503을 받아요. workspace 전제조건이 잘못됐으면 리다이렉트 대신 400을 받아요.

A1 기준선은 `127.0.0.1`만 쓰기 때문에 이 경우를 재지 못했어요. 코드를 읽고 정했어요.
순서를 그대로 두려면 세 곳을 `Self_authenticated`로 적어야 해요. 실제로는 `with_public_read`가 확인하는 경로라서 그렇게 적지 않았어요.

## 확인하지 못한 것

- 자격이 맞는 요청과 권한이 모자란 요청은 경로마다 재지 않았어요. A1은 자격이 없을 때와 틀린 bearer일 때만 봐요.
  허용과 거절은 종류마다 `test_server_route`가 worker와 admin 토큰으로 보고, 경로마다 같은 래퍼와 인자가 걸리는지는 위 2번이 대신해요.
- prefix 경로 33개는 A1이 `/probe-a1` 한 칸만 붙여 보내서 하위 경로의 인증을 재지 못했어요. 이 33개는 2번으로만 확인했어요.
- 변경한 모듈을 이름으로 쓰는 시험 40개와 전체 `dune test`는 돌리지 않았어요. CI 결과가 최종이에요.
- A1 환경에는 키퍼와 외부 연동이 없어요. 그게 있어야 열리는 응답은 재지 못했어요.
- HTTP/2 게이트웨이(`server_h2_gateway_routes_extra.ml` 등)는 이 변경에 없어요. HTTP/2도 위 1번에서 상태가 같았지만, 게이트웨이가 같은 경로에 같은 인증을 거는지는 A4c에서 따로 다뤄요.

## 따로 이슈로 남긴 것

- [#46662](https://github.com/jeong-sik/masc/issues/46662): `/api/v1/keepers/` prefix 등록 둘은 하위 경로마다 인증이 달라서 `Subpath_dispatch`로 적었어요. 하위 경로별 종류는 경로 표에 없어요.
- [#46663](https://github.com/jeong-sik/masc/issues/46663): `Server_routes_http_routes_workspace.add_routes`가 두 번 불려서 등록 줄이 396개, 도달하는 경로가 386개예요.
- [#46560](https://github.com/jeong-sik/masc/issues/46560): `dev-token`은 loopback이고 엄격 설정이 꺼져 있으면 자격 없이 토큰을 줘요. `Loopback_dev_token`으로 적었어요.
- [#46569](https://github.com/jeong-sik/masc/issues/46569): `GET /api/v1/board/flairs`는 래퍼가 없고 공개 목록에도 없어서 엄격 설정에서 닫히지 않아요. `Always_public`으로 적었어요.

## 다시 돌리려면

1. 기준선 전후 비교. main 빌드와 이 브랜치 빌드를 각각 기본·엄격 설정으로 돌린 뒤 비교해요.
   `run.sh`의 `<out-dir>`을 `<before>/default`, `<before>/strict`, `<after>/default`, `<after>/strict`로 두면 `compare.py`가 `<before>`와 `<after>`를 받아요.

   ```
   scripts/auth-route-baseline/run.sh <main_eio.exe> <auth_route_inventory.exe> <port> <work-dir> <out-dir> [NAME=value ...]
   scripts/auth-route-baseline/compare.py <before> <after> --csv comparison.csv
   ```

   엄격 설정은 `run.sh` 끝에 `MASC_HTTP_AUTH_STRICT=true MASC_AUTH_STRICT=strict`를 붙여요.
   마지막 줄이 `compared 3252 statuses, 0 problems`로 끝나요.

2. 래퍼와 인자 비교. 저장소 루트에서 실행해요. 컴파일 부산물이 소스 옆에 남지 않게 임시 디렉터리에서 만들어요.

   ```
   work=$(mktemp -d)
   cp docs/evidence/2026-10-28-route-auth-conversion/scan_args.ml "$work" && (cd "$work" && ocamlfind ocamlopt -package compiler-libs.common -linkpkg scan_args.ml -o scan_args)
   rg -l 'Server_route\.(get|post|add|prefix_get|prefix_post|prefix_put|prefix_delete|ws_get)\b' lib/server | sort > "$work/files.txt"
   mkdir "$work/old" && while read -r f; do git show "197f56852c5:$f" > "$work/old/$(basename "$f")"; done < "$work/files.txt"
   "$work/scan_args" old "$work"/old/*.ml > "$work/old.tsv"
   "$work/scan_args" new $(cat "$work/files.txt") > "$work/new.tsv"
   python3 docs/evidence/2026-10-28-route-auth-conversion/compare_args.py "$work/old.tsv" "$work/new.tsv"
   ```

   마지막 줄이 `376 registrations with the same wrappers, 7 with different ones`로 끝나요.

3. 변환 자체는 도구(#46598)로 다시 만들 수 있어요. main `197f56852c5`에서 첫 커밋의 메시지에 적힌 명령을 그대로 돌려요.

## 파일

- `comparison.csv`: 경로마다 전후 상태 코드 네 개씩(`mode, method, route_path, probed_path`, 전 4개, 후 4개).
- `scan_args.ml`: 등록마다 걸리는 래퍼와 인자를 뽑는 스캐너.
- `compare_args.py`: 스캔 결과 둘을 짝지어서 다른 등록을 보여줘요.
