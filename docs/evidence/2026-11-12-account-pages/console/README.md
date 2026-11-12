# 콘솔 — 계정 서버가 주는 경로 (2026-11-12)

로그인한 사람의 콘솔을 계정 서버가 `/accounts/console` 에서 답하게 한 층의 기록이에요. 콘솔 화면은 Dashboard 와 같이 빌드돼요(`dashboard/src/accounts/`, #51635). 이 층은 서버가 그 빌드를 어느 주소로, 어떤 header 로 주는지를 정해요. 재는 값과 브라우저는 위 폴더 README 의 "방법" 절과 같아요.

## 방법

- 바이너리. 커밋 `5a767ce08174` 에서 빌드했어요(sha256 앞 12자리 `4840339f479d`, 제품 소스 tree 는 `lib` `867a853cd3a0`, `bin` `495af6fae0c1`). 그 뒤 커밋은 이 폴더만 바꿔요(`git diff 5a767ce08174 HEAD -- lib bin test` 는 아무것도 내지 않아요).
- 서버 둘. 같은 바이너리로 임시 다계정 설치 둘을 띄우고 `MASC_ASSETS_DIR` 만 다르게 줬어요. 하나는 콘솔 빌드가 든 bundle 이고, 하나는 빈 `dashboard/` 폴더예요(콘솔도 운영자 Dashboard 도 없는 bundle).
- bundle. 이 체크아웃의 `assets/dashboard/` 예요. 그 안의 콘솔은 `accounts/index.html`(760 B), `accounts/assets/index-48nnFfCc.js`(26,211 B), `accounts/assets/index-CfAaj9st.css`(333 B) 셋이에요. 콘솔 소스는 main 과 같고, 그 소스를 다시 빌드하면 세 파일의 sha256 이 같아요.
- 서버의 답(`harness/console-answers.py`). 두 서버에 콘솔 경로를 HTTP 로 물어 상태, header, 바이트 수를 적어요. 주소는 적힌 그대로 보내요(`http.client`). `..` 를 중간에서 정리하는 것이 없어요.
- 로그인 없이 실제 서버로 잰 상태 둘. 로그인하지 않은 브라우저가 콘솔을 열 때(`console_signed_out`), 빈 bundle 의 서버가 답하는 화면(`console_no_bundle`).
- 로그인한 상태 셋은 GitHub 로그인이 있어야 해서 실제 서버로는 못 만들어요. 실제 서버가 답한 콘솔, base sheet, 빌드 파일, `/` 의 header 와 바이트를 저장해 그 주소로 그대로 주고, 세션 경로(`/auth/session`, `/api/v1/auth/whoami`, `/auth/logout`)의 답만 지어낸 대역(`harness/console-mock.mjs`)으로 쟀어요. 화면의 id 는 전부 지어낸 값이에요. 서버의 세션 경로를 본 것은 아니에요.
- 대조군(`control_no_style_source`). 같은 저장 화면을, 정책에서 `style-src 'self'` 만 빼고 줘요. 브라우저가 sheet 둘을 버리고 정책 위반을 내야 측정이 맞게 도는 거예요.
- 이 층에서 행에 더한 값(`harness/ux-measure3.mjs`). 화면이 준비됐을 때의 주소(`finalPath`), 측정 도구가 돌기 전의 정책 위반(`policyViolationsBeforeAxe`), 규칙을 읽지 못한 sheet 수(`sheetsWithoutRules`)예요.
- 운영 중인 설치는 쓰지 않았어요.

다시 재려면 `axe.min.js`(axe-core 4.14.0)를 `harness/` 안에 두고 아래를 돌려요. 포트 셋을 쓰고, 끝나면 띄운 것을 스스로 내려요. `<assets>` 는 `dashboard/` 를 품은 폴더예요.

```sh
sh harness/console-layer.sh <masc 바이너리> <label> <출력 폴더> <빈 포트> <assets>
python3 harness/console-table.py <출력 폴더>/<label>-answers.json <출력 폴더>/<label>-measure.json
```

## 서버의 답

수치는 `l3c-answers.json` 이에요. 표는 `harness/console-table.py` 가 만든 것을 한국어로 옮겼어요.

| 서버 | 무엇 | 주소 | 보낸 header | 상태 | content-type | cache-control | content-encoding | 바이트 |
|---|---|---|---|---|---|---|---|---|
| 콘솔이 든 bundle | 콘솔 화면 | `/accounts/console` | - | 200 | text/html; charset=utf-8 | no-store | - | 760 |
| 콘솔이 든 bundle | 빌드 파일 | `/accounts/console/assets/index-48nnFfCc.js` | - | 200 | application/javascript; charset=utf-8 | public, max-age=31536000, immutable | - | 26211 |
| 콘솔이 든 bundle | 같은 파일, zstd·gzip 을 받는 브라우저 | `/accounts/console/assets/index-48nnFfCc.js` | `Accept-Encoding` | 200 | application/javascript; charset=utf-8 | public, max-age=31536000, immutable | zstd | 11164 |
| 콘솔이 든 bundle | 빌드 파일 | `/accounts/console/assets/index-CfAaj9st.css` | - | 200 | text/css; charset=utf-8 | public, max-age=31536000, immutable | - | 333 |
| 콘솔이 든 bundle | 같은 파일, zstd·gzip 을 받는 브라우저 | `/accounts/console/assets/index-CfAaj9st.css` | `Accept-Encoding` | 200 | text/css; charset=utf-8 | public, max-age=31536000, immutable | zstd | 262 |
| 콘솔이 든 bundle | base sheet | `/accounts/console/base.css` | - | 200 | text/css; charset=utf-8 | no-cache | - | 3799 |
| 콘솔이 든 bundle | base sheet, 이미 가진 브라우저 | `/accounts/console/base.css` | `If-None-Match` | 304 | - | no-cache | - | 0 |
| 콘솔이 든 bundle | 빌드 파일 폴더에서 위로 한 칸 | `/accounts/console/assets/../index.html` | - | 404 | text/plain; charset=utf-8 | - | - | 13 |
| 콘솔이 든 bundle | 위로 두 칸(운영자 Dashboard 의 화면) | `/accounts/console/assets/../../index.html` | - | 404 | text/plain; charset=utf-8 | - | - | 13 |
| 콘솔이 든 bundle | 같은 주소를 `%2f` 로 적은 것 | `/accounts/console/assets/..%2f..%2findex.html` | - | 404 | text/plain; charset=utf-8 | - | - | 13 |
| 콘솔이 든 bundle | 이름 없음 | `/accounts/console/assets/` | - | 404 | text/plain; charset=utf-8 | - | - | 13 |
| 콘솔이 든 bundle | 빌드에 없는 이름 | `/accounts/console/assets/missing.js` | - | 404 | text/plain; charset=utf-8 | - | - | 13 |
| 콘솔이 든 bundle | 운영자 Dashboard 의 주소 | `/dashboard` | - | 404 | text/plain; charset=utf-8 | - | - | 13 |
| 콘솔이 든 bundle | bundle 안의 경로 그대로 | `/accounts/index.html` | - | 404 | text/plain; charset=utf-8 | - | - | 13 |
| 빈 bundle | 콘솔 화면 | `/accounts/console` | - | 503 | text/html; charset=utf-8 | no-store | - | 6181 |
| 빈 bundle | 빌드 파일 | `/accounts/console/assets/index-48nnFfCc.js` | - | 404 | text/plain; charset=utf-8 | - | - | 13 |
| 빈 bundle | base sheet | `/accounts/console/base.css` | - | 200 | text/css; charset=utf-8 | no-cache | - | 3799 |
| 빈 bundle | 처음 화면 | `/` | - | 200 | text/html; charset=utf-8 | no-store | - | 20175 |
| 빈 bundle | 준비 확인 | `/health/ready` | - | 200 | application/json; charset=utf-8 | no-cache | - | 14 |

- 콘솔 화면의 정책: `default-src 'none'; script-src 'self'; style-src 'self'; style-src-attr 'none'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`
- 빈 bundle 의 503 화면의 정책: `default-src 'none'; style-src 'nonce-N'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`
- 빌드 파일 두 개의 답도 콘솔 화면과 같은 정책을 실어요. 브라우저가 빌드 파일을 문서로 열어도(나중 빌드의 `.html`·`.svg`) 화면과 같은 제한 아래에서 돌아요.
- base sheet 는 서버가 직접 쓰는 화면의 sheet 앞부분과 바이트가 같아요. `/` 의 style 요소(5,480 B)가 base sheet(3,799 B)로 시작해요. 그래서 콘솔과 로그인 화면의 바탕 모양이 같아요.
- 빌드 파일은 이름에 내용 hash 가 있어서 오래 둬도 돼요. base sheet 는 주소가 그대로이고 바이너리가 바뀌면 내용이 바뀌어서, 브라우저가 쓸 때마다 다시 물어요(`no-cache`, 같으면 304).
- 빈 bundle 이어도 서버는 뜨고, 로그인 화면과 준비 확인은 그대로 답해요. 콘솔 자리에는 503 화면이 나와요. 서버 로그에는 뜰 때 `[WARN] [Server] /accounts/console answers 503: the dashboard bundle of this server holds no accounts/index.html` 한 줄이 남아요. 콘솔이 든 bundle 의 서버에는 그 줄이 없어요.
- 이유는 뜰 때 한 번만 적어요. 로그인 없이 열리는 경로라 요청마다 적지 않아요. 그래서 뜬 뒤에 bundle 이 깨지면 로그에 이유가 남지 않아요.
- `dashboard/` 폴더조차 없는 assets 폴더에서는 빌드 파일도 503 이에요(빈 bundle 에서는 404). 브라우저로 재지 않았고, `test/test_server_accounts.ml` 이 붙들어요(둘 다 503, 답에 서버의 폴더 경로가 없음).

## 브라우저에서 잰 상태

수치는 `l3c-measure.json` 이에요.

| 상태 | 도착한 주소 | axe 위반 | incomplete | CSS 규칙 | 정책 위반 | `style` 속성 | 24px 미만 대상 | 가장 낮은 대상 | 보이는 조작 대상 | 첫 Tab | 320px 가로 넘침 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| console_signed_out | `/` | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 1 | `button#go` | none |
| console_no_bundle | `/accounts/console` | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 1 | `a` | none |
| console_member | `/accounts/console` | 0 | 0 | 31 | 0 | 0 | 1 | 23px | 2 | `button` | none |
| console_admin | `/accounts/console` | 0 | 0 | 31 | 0 | 0 | 1 | 23px | 2 | `button` | none |
| console_session_unread | `/accounts/console` | 0 | 0 | 31 | 0 | 0 | 0 | 44px | 1 | `button` | none |
| control_no_style_source | `/accounts/console` | 0 | 0 | 0 | 2 | 0 | 2 | 20px | 2 | `button` | none |

- `console_signed_out`. 실제 서버예요. 로그인하지 않은 브라우저는 콘솔 script 가 세션이 없다는 답을 받고 `/` 로 가요. 표의 값은 도착한 로그인 화면의 것이에요.
- `console_no_bundle`. 실제 서버예요. script 없이 sheet 만 쓰는 화면이고, 조작 대상은 처음 화면으로 가는 링크 하나예요.
- 로그인한 세 상태는 정책 위반이 0 이에요. 콘솔은 엄한 정책 아래에서 sheet 둘과 script 하나를 다 받아요.
- 대조군은 CSS 규칙이 0 이고 정책 위반이 2 예요(sheet 둘). 측정이 끝난 뒤에는 4건인데, 나머지 둘은 axe-core 가 낸 거예요. axe-core 는 규칙을 못 읽은 sheet 를 가져와 style 요소로 쓰고, 정책이 그것을 막아요. 그래서 정책 위반은 axe-core 가 돌기 전의 값으로 적어요.
- 캡처: `l3c-console_member-desktop.png`, `l3c-console_member-320.png`, `l3c-console_no_bundle-desktop.png`, `l3c-console_no_bundle-320.png`. 320px 캡처는 Tab 을 한 번 누른 뒤에 찍었어요.

## 로그인 화면은 그대로인가

이 층은 로그인 화면의 sheet 를 두 파일로 나눠요(`lib/auth/account_base.css`, `lib/auth/account_page.css`). 서버가 쓰는 화면은 둘을 이은 것을 받아요. 나누기 전과 후에 화면이 같은지를 두 가지로 봤어요.

- 규칙(`harness/sheet-rules.py`). 주석과 빈 줄을 뺀 줄이 전 127줄, 후 127줄이고, 빠진 줄과 더해진 줄이 없어요. 무게가 없는 규칙 셋(`*`, `:where(…)` 둘)의 순서도 같아요.
- 브라우저(`harness/ux-layer.sh`, `harness/ux-compare.py`). 상태마다 모든 요소와 `::before`·`::after` 의 computed style 전체를 폭 320px 와 1280px 에서 읽어 지문을 내요. 전은 이 층의 바탕 커밋 `d09adad5eec2`(main)의 바이너리(sha256 앞 12자리 `753209051476`)이고, 후는 위의 이 층 바이너리예요.

| 상태 | 비교한 값 | 요소 수 | computed style 지문(320px) 전/후 | 지문(1280px) 전/후 | 결과 |
|---|---|---|---|---|---|
| home_signed_out | 27 | 86 | `f3ee0c5ad1752733/f3ee0c5ad1752733` | `d10ceb3aa0dd6e8d/d10ceb3aa0dd6e8d` | 같음 |
| home_no_client | 27 | 87 | `a07b2c97d4b67ac6/a07b2c97d4b67ac6` | `5e697871d36cabaf/5e697871d36cabaf` | 같음 |
| invite_token | 27 | 26 | `84fd236bda3e0853/84fd236bda3e0853` | `61988aab340b73cb/61988aab340b73cb` | 같음 |
| invite_no_token | 27 | 26 | `ad6cfa47763b1b0e/ad6cfa47763b1b0e` | `8968af99946f15cb/8968af99946f15cb` | 같음 |
| invite_no_client | 27 | 27 | `9b4fe3c3316fd345/9b4fe3c3316fd345` | `e15ec8cd50082827/e15ec8cd50082827` | 같음 |
| member_new | 27 | 86 | `b4932077726d05a3/b4932077726d05a3` | `6382a11f6b850299/6382a11f6b850299` | 같음 |
| member_full | 27 | 90 | `0f5e05d1dc4bcc6e/0f5e05d1dc4bcc6e` | `51bde2fddf056007/51bde2fddf056007` | 같음 |
| admin_full | 27 | 90 | `67e0d449f4402444/67e0d449f4402444` | `7afb55da5dab6f59/7afb55da5dab6f59` | 같음 |
| refused_401 | 27 | 20 | `238ebe198349b575/238ebe198349b575` | `a8e409dc25aac2ce/a8e409dc25aac2ce` | 같음 |
| refused_404_no_client | 27 | 20 | `238ebe198349b575/238ebe198349b575` | `a8e409dc25aac2ce/a8e409dc25aac2ce` | 같음 |
| done_held | 27 | 18 | `1755988224065900/1755988224065900` | `c4acc2dc63389b88/c4acc2dc63389b88` | 같음 |
| control_other_style_nonce | 27 | 86 | `6d61364791b3c2dc/6d61364791b3c2dc` | `3f26b255b1a710f0/3f26b255b1a710f0` | 같음 |

- 열두 상태 모두 표의 값과 두 지문이 같아요. 수치는 `sheet-before-measure.json`, `sheet-after-measure.json` 이에요.
- 로그인 완료 화면(`done_held`)은 GitHub 로그인이 있어야 열려서, 로그인 시험이 저장한 서버의 답을 대역이 줘요(`harness/ux-dump-done.py`). 전의 것은 바탕 커밋의 소스로, 후의 것은 이 층의 소스로 만들었어요. 본문은 5,808 B(sha256 앞 12자리 `58afe5cd504d`)와 6,299 B(`383df5c38e53`)로 달라요. 안에 넣는 sheet 의 주석이 달라서예요(4,989 B → 5,480 B). 측정 JSON 에는 이 차이가 남지 않아서 여기에 적어요.
- 지문 뒤의 값(요소별 속성)은 다시 재면 `<출력 폴더>/styles/` 에 남아요. 저장소에는 넣지 않았어요.

## 콘솔 틀에서 보인 것

이 층은 서버 경로만 바꿔요. 콘솔 틀(#51635)을 처음으로 실제 정책 아래에서 그려 보니 셋이 보였어요. 다음 PR 에서 고쳐요.

- 로그인한 화면의 문장 안 링크가 23px 이에요(표의 `console_member`, `console_admin`). 합격선은 24px 이에요.
- 머리줄의 로그아웃 단추가 8px 내려앉고, 머리줄이 85px 로 커져요. 로그인 정보가 없을 때는 50px 이에요.
- 머리줄의 이름과 본문 열의 왼쪽이 안 맞아요. 폭 1548px 에서 이름은 x=16, 본문 열은 x=254 에서 시작해요.

## 시험이 붙드는 것

`test/test_server_accounts.ml` 이 이 경로들을 실제 listener 로 물어요. 경로 소스를 일부러 틀리게 고친 것마다 그 시험을 돌렸어요(`route-mutants.py`, 결과 `route-mutants.tsv`).

| 틀리게 고친 것 | 결과 | 실패한 단언 |
|---|---|---|
| 콘솔 정책의 `script-src` 에 `'unsafe-inline'` | 잡힘 | `the policy of the console` |
| 콘솔 정책이 `default-src 'self'` 로 시작 | 잡힘 | `the policy of the console` |
| 콘솔 정책에서 `base-uri`·`form-action`·`frame-ancestors` 를 뺌 | 잡힘 | `the policy of the console` |
| 콘솔 화면에 `no-store` 가 없음 | 잡힘 | `a browser does not keep the page` |
| 콘솔 화면에 `referrer-policy` 가 없음 | 잡힘 | `a link to another site carries no address of this server` |
| 콘솔 없는 bundle 인데 200 을 답함 | 잡힘 | `the console of a bundle that does not hold it` |
| 503 화면에 `no-store` 가 없음 | 잡힘 | `nothing between the server and the browser keeps the page that stands in` |
| 503 화면의 정책에 `script-src 'self'` | 잡힘 | `the page that stands in applies its own sheet and runs no script` |
| 콘솔 자리에 운영자 Dashboard 의 화면을 줌 | 잡힘 | `it is the page of the build, byte for byte` |
| 빌드 파일 자리에 운영자 Dashboard 의 파일을 줌 | 잡힘 | `a file of the build` |
| 파일 이름을 검사하지 않고 bundle 에 물음 | 못 잡음 | - |
| 바탕 sheet 를 `immutable` 로 줌 | 잡힘 | `a browser asks for it again on every use` |
| 바탕 sheet 의 tag 가 내용을 따르지 않음 | 잡힘 | `the tag of the sheet is the tag of its bytes` |
| 콘솔 경로를 등록하지 않음 | 잡힘 | `the console of a bundle that does not hold it` |
| 빌드 파일에 정책을 싣지 않음 | 잡힘 | `a file of the build carries the policy of the console` |
| 503 화면이 서버 로그의 이유를 말함 | 잡힘 | `the page that stands in does not say why` |
| 503 화면에 `referrer-policy` 가 없음 | 잡힘 | `a link of the page that stands in carries no address of this server` |
| bundle 이 줄 수 없는 빌드 파일을 404 로 답함 | 잡힘 | `GET /accounts/console/assets/app.js without a bundle` |
| 빌드 파일을 브라우저가 오래 두지 않음(공유 함수) | 잡힘 | `a browser keeps a file of the build, which is named after its bytes` |

- 열아홉 가운데 18개를 잡았어요. 고치지 않은 소스에서는 시험이 통과해요. 마지막 다섯은 리뷰 뒤 더한 단언을 확인하려고 더했어요.
- 못 잡은 하나는 경로가 파일 이름을 검사하는 줄이에요(`Web_dashboard.is_public_asset_relative_path`). 그 줄을 빼도 bundle 을 읽는 함수가 같은 이름들을 거절해서 답이 같아요. 운영자 Dashboard 경로도 같은 검사를 먼저 해요(`lib/server/server_routes_http_routes_frontend.ml`). 경로가 읽는 길(설치, run-local, 폴더)에 기대지 않으려고 뒀어요. 시험이 붙드는 줄은 아니에요.

## 확인하지 않은 것

- 설치된 release 와 `scripts/run-local.sh` 가 bundle 을 읽는 길. 잰 것은 `MASC_ASSETS_DIR` 로 폴더를 준 길 하나예요. 세 길은 같은 함수(`Web_dashboard.load_dashboard_asset`)로 모이고, 설치는 bundle 폴더를 통째로 옮겨요(소스를 읽어서 확인).
- 설치 release·run-local 에서 목록에는 있는데 읽지 못하는 파일의 답(503). 폴더 bundle 에서 빌드 파일이 503 인 경우는 시험이 붙들어요(위 `dashboard/` 가 없는 폴더).
- 실제 GitHub 로그인 뒤의 콘솔. 시험용 OAuth App 이 있어야 해요.
- 여러 사람이 동시에 열 때의 서버 부하. 압축이 CPU pool 로 넘어가는지(`Server_routes_http_pages.serve_dashboard_asset` 의 주석)도 계정 서버에서는 보지 않았어요.
- 화면 낭독기로 읽는 소리, 다른 브라우저 엔진(WebKit, Gecko).

## 알려진 것

- 폴더에서 읽는 bundle 은 요청한 이름 그대로 파일을 열어요. 대소문자를 가리지 않는 파일시스템에서는 대소문자만 다른 이름이 모두 200 이고, 이름마다 자산 표에 한 칸씩 쌓여요. `ENOENT` 가 아닌 거절(경로 중간이 파일, 너무 긴 이름, 디렉터리, link)은 404 가 아니라 503 이에요. 운영자 `/dashboard/assets/` 도 같은 함수를 지나요(#51705).
- HEAD 요청과 405 의 `Allow` header 는 계정 서버의 모든 경로가 같아요(#50861).
