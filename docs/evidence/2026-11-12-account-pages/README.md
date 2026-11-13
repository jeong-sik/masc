# 계정 서버 화면 실측 (2026-11-12)

계정 서버가 직접 쓰는 화면을 층마다 그 층의 바이너리로 띄워 실제 브라우저에서 잰 기록이에요. 화면 문구와 배치는 시험으로 고정하지 않아서(constitution `execution_protocol`), 이 폴더의 수치와 캡처가 근거예요.

로그인한 사람의 콘솔(`/accounts/console`)을 계정 서버가 답하는 경로와, sheet 를 두 파일로 나눈 전후의 비교는 `console/README.md` 에 있어요. 그 콘솔 틀의 로그아웃 흐름과 머리줄을 고친 전후는 `frame/README.md` 에 있어요.

## 방법

- 서버. 그 층의 소스로 만든 `masc` 바이너리로 임시 폴더에 다계정 설치 둘을 만들어 `127.0.0.1` 의 빈 포트에 띄웠어요. 하나는 GitHub 로그인 client 가 있고(지어낸 client id), 하나는 없어요. 환경은 `env -i` 로 비웠고 HOME 은 빈 임시 폴더예요. 운영 중인 설치는 쓰지 않았어요(`harness/ux-serve.sh`).
- 바이너리의 출처는 제품 소스의 tree id 로 적어요(`git rev-parse <커밋>:lib`, `<커밋>:bin`). 스택을 다시 쌓으면 커밋 id 는 바뀌어도 이 값은 그대로예요.
- 브라우저. Chromium 156(ego-browser 0.6.2.9)이에요. 접근성 검사는 axe-core 4.14.0 의 `wcag2a`, `wcag2aa`, `wcag21a`, `wcag21aa`, `wcag22aa`, `best-practice` 규칙이에요.
- 로그인 전 상태 다섯은 실제 서버에 바로 붙여 쟀어요.
- 로그인한 상태 셋은 GitHub 로그인이 있어야 해서 실제 서버로는 못 만들어요. 실제 서버가 답한 HTML 과 header(CSP 포함)를 저장해 그대로 주고, JSON 경로의 답만 지어낸 대역(`harness/ux-mock.mjs`)으로 쟀어요. 화면에 보이는 id 는 전부 지어낸 값이에요. 서버의 JSON 경로를 본 것은 아니에요.
- 대조군. 같은 저장 화면을, 정책의 style nonce 만 다른 값으로 바꿔서 줘요. 브라우저가 sheet 를 버리고 정책 위반을 한 건 내야 측정이 맞게 도는 거예요.
- 재는 것(`harness/ux-measure3.mjs`). axe 위반과 incomplete, 적용된 CSS 규칙 수, 브라우저가 낸 정책 위반(`securitypolicyviolation`) 건수, `style` 속성 수, 24px 미만 누름 대상 수, 가장 낮은 대상 높이, 보이는 `<pre>` 가운데 HTTP 상태나 JSON 이 든 것의 수, 자유 입력 칸 수, 첫 Tab 이 닿는 요소, 폭 320 CSS px 에서의 가로 넘침이에요.
- 로그인 단추는 브라우저가 든 값으로 읽어요(행의 `login`). start 경로로 POST 하는 form 의 제출 단추 수, 그 단추의 `disabled` property, 단추가 가리키는 설명 가운데 보이는 글자 수예요. L1a 표를 만든 뒤에 더한 항목이에요.
- timeout 이 난 상태는 처음부터 다시 재요. 세 번까지이고 횟수는 행의 `attempts` 예요. 재는 값은 시간에 기대지 않아요.
- 캡처는 상태마다 데스크톱과 320px 둘이에요. 320px 캡처는 Tab 을 한 번 누른 뒤에 찍어서 focus 표시가 보여요. 폴더에는 고른 것만 넣었어요.

다시 재려면 axe-core 4.14.0 의 `axe.min.js` 를 `harness/` 안에 두고(저장소에는 넣지 않았어요) 아래를 돌려요. 포트 넷을 쓰고, 끝나면 띄운 것을 스스로 내려요.

```sh
sh harness/ux-layer.sh <masc 바이너리> <label> <출력 폴더> <빈 포트>
python3 harness/ux-table.py <출력 폴더>/<label>-measure.json
```

로그인 실패·완료 화면까지 재려면 완료 화면을 먼저 저장해요. `harness/ux-dump-done.py` 가 저장 프로그램을 만들고, 그 머리말대로 빌드해 돌리면 `<저장 폴더>` 에 header 와 바이트가 남아요. 그다음 상태 셋과 그 폴더를 인자로 더해요.

```sh
python3 harness/ux-dump-done.py <worktree> <저장 폴더>
sh harness/ux-layer.sh <masc 바이너리> <label> <출력 폴더> <빈 포트> \
  '[["refused_401","REAL",null,"/auth/github/callback"],["refused_404_no_client","NOCLIENT",null,"/auth/github/callback"],["done_held","MOCK",null,"/__saved/done?hold"]]' \
  <저장 폴더>
```

## L1a — stylesheet 와 화면 뼈대

바이너리 sha256 앞 12자리 `ff7012df7e35`. 제품 소스 tree 는 `lib` `6f68976c06fe`, `bin` `6af85a0e0703` 이고 커밋 `b706d4df8092` 의 것과 같아요. 커밋하기 전 작업 트리에서 만든 바이너리라서 안에 든 build id 는 그 부모 `17df780c6390` 이에요. 수치는 `l1a/l1a-measure.json` 이에요.

| 상태 | HTTP | axe 위반 | incomplete | CSS 규칙 | 정책 위반 | `style` 속성 | 24px 미만 대상 | 가장 낮은 대상 | 보이는 경로 답 원문 | 자유 입력 칸 | 첫 Tab | 320px 가로 넘침 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| home_signed_out | 200 | 0 | 0 | 21 | 0 | 0 | 0 | 44px | 1 | 0 | `button#go` | none |
| home_no_client | 200 | 0 | 0 | 21 | 0 | 0 | 0 | 44px | 1 | 0 | `body` | none |
| invite_token | 200 | 0 | 0 | 21 | 0 | 0 | 0 | 44px | 0 | 0 | `button#go` | none |
| invite_no_token | 200 | 0 | 0 | 21 | 0 | 0 | 0 | 44px | 0 | 0 | `body` | none |
| invite_no_client | 200 | 0 | 0 | 21 | 0 | 0 | 0 | 44px | 0 | 0 | `body` | none |
| member_new | 200 | 0 | 0 | 21 | 0 | 0 | 0 | 44px | 1 | 7 | `button#signout` | none |
| member_full | 200 | 0 | 0 | 21 | 0 | 0 | 0 | 44px | 2 | 7 | `button#signout` | none |
| admin_full | 200 | 0 | 0 | 21 | 0 | 0 | 0 | 44px | 2 | 9 | `button#signout` | none |
| control_other_style_nonce | 200 | 0 | 0 | 0 | 1 | 0 | 1 | 22px | 1 | 0 | `button#go` | 454px wide in 320px |

- 정책은 여덟 상태 모두 `default-src 'none'; script-src 'nonce-N'; style-src 'nonce-N'; connect-src 'self'; form-action 'self' https://github.com; base-uri 'none'; frame-ancestors 'none'` 예요(nonce 는 답마다 다른 값이고 표기만 `N` 으로 줄였어요).
- 대조군은 CSS 규칙 0, 정책 위반 1건(`style-src-elem`), 320px 에서 폭 454px 예요. sheet 가 없는 지금 main 의 화면과 같은 모양이에요.
- 전(main `be33cb4689c6` 의 화면, 같은 규칙으로 잼): axe 위반 0, CSS 규칙 0, 320px 에서 폭 454~1111px, 24px 미만 대상 1~23개였어요.
- 첫 Tab 이 `body` 인 세 상태는 화면의 단추 하나가 눌리지 않는 상태라서 focus 를 받을 요소가 없어요.
- `home_signed_out` 의 "보이는 경로 답 원문 1"은 세션이 없을 때 찍히는 `no session (401)` 두 줄이에요. 이 층은 구조를 안 바꿔서 남아 있고, 다음 층이 없애요.

| 캡처 | 상태 |
| --- | --- |
| `l1a/l1a-home_signed_out-desktop.png`, `l1a/l1a-home_signed_out-320.png` | 세션 없는 `/` (실제 서버) |
| `l1a/l1a-invite_token-320.png` | 초대 링크로 연 `/accounts/invite` (실제 서버, 지어낸 token) |
| `l1a/l1a-admin_full-desktop.png`, `l1a/l1a-admin_full-320.png` | Admin 으로 로그인한 `/` (실제 HTML, 지어낸 JSON) |
| `l1a/l1a-control_other_style_nonce-320.png` | 대조군 |

## 로그인 읽기 (#51563)

화면의 로그인을 읽는 시험 코드(`test/account_page_reading.ml`)가 틀린 화면을 맞다고 읽지 않는지, 그리고 브라우저가 든 값과 맞는지 본 기록이에요. 이 층은 제품 소스를 바꾸지 않아요.

- 변이. `reading/mutants.py` 가 읽기를 한 줄씩 망가뜨린 변이 11개를 만들고, 변이마다 `test_account_page_reading` 의 29가지를 다시 돌려요. 결과는 `reading/mutants.tsv`(변이, 판정, 실패한 경우)이고 11개 모두 잡혀요. 다시 돌리려면 `python3 reading/mutants.py <worktree> <출력.tsv>` 예요. 변이마다 소스를 고쳤다가 되돌려요.
- 브라우저의 값. L1a 바이너리(`ff7012df7e35`)를 `login` 을 읽는 측정 스크립트로 다시 쟀어요. 수치는 `l1a/l1a-dom-measure.json` 이에요.

  | 상태 | form 의 제출 단추 | `button.disabled` | 단추가 가리키는 설명 중 보이는 글자 |
  |---|---|---|---|
  | home_signed_out | 1 | false | - |
  | home_no_client | 1 | true | 32자 |
  | invite_token | 1 | false | - |
  | invite_no_token | 1 | true | 0자 |
  | invite_no_client | 1 | true | 32자 |

- `invite_no_token` 은 화면의 script 가 단추를 막은 상태예요. 막힌 까닭은 단추 위 문단에 보이지만 단추가 그 문단을 가리키지 않아요. 경로 시험은 script 가 돌기 전의 문서를 읽어서 이 상태를 못 봐요. 다음 층이 이 상태를 form 을 숨기고 안내와 링크를 보이는 화면으로 바꿔요.

## L1b — 로그인·초대 화면

바이너리 sha256 앞 12자리 `b85f755a84bb`. 제품 소스 tree 는 `lib` `1858fa49c245`, `bin` `6af85a0e0703` 이에요. 이 층의 코드 커밋에서 만들었어요(잴 때의 커밋 id 는 `2b24c204fe83`, 안에 든 build id 도 같아요). 수치는 `l1b/l1b-measure.json` 이에요.

| 상태 | HTTP | axe 위반 | incomplete | CSS 규칙 | 정책 위반 | `style` 속성 | 24px 미만 대상 | 가장 낮은 대상 | 보이는 경로 답 원문 | 자유 입력 칸 | 로그인 단추(DOM) | 첫 Tab | 320px 가로 넘침 | 시도 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| home_signed_out | 200 | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 0 | 0 | 누를 수 있음 | `button#go` | none | 1 |
| home_no_client | 200 | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 0 | 0 | `disabled`, 보이는 설명 55자 | `body` | none | 1 |
| invite_token | 200 | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 0 | 0 | 누를 수 있음 | `button#go` | none | 1 |
| invite_no_token | 200 | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 0 | 0 | 숨김 | `a` | none | 1 |
| invite_no_client | 200 | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 0 | 0 | `disabled`, 보이는 설명 55자 | `body` | none | 1 |
| member_new | 200 | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 1 | 7 | 숨김 | `button#signout` | none | 1 |
| member_full | 200 | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 2 | 7 | 숨김 | `button#signout` | none | 1 |
| admin_full | 200 | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 2 | 9 | 숨김 | `button#signout` | none | 1 |
| control_other_style_nonce | 200 | 0 | 0 | 0 | 1 | 0 | 1 | 22px | 0 | 0 | 누를 수 있음 | `button#go` | none | 1 |

- 정책은 L1a 와 같아요.
- 세션 없는 `/` 두 상태의 "보이는 경로 답 원문"이 1 에서 0 이 됐어요. `no session (401)` 두 줄을 쓰던 줄이 로그인한 사람이 쓰는 부분 안으로 들어갔어요.
- "로그인 단추(DOM)"는 브라우저가 든 값이에요. GitHub client 가 있는 두 화면은 `button.disabled` 가 `false` 예요. client 가 없는 두 화면은 `true` 이고, 단추가 가리키는 설명 55자가 보여요.
- `invite_no_token`. 주소에 token 이 없으면 화면의 script 가 form 을 숨기고, 초대 링크를 다시 열라는 안내와 로그인 화면으로 가는 링크를 보여요. 첫 Tab 이 그 링크에 닿아요. L1a 에서는 설명을 가리키지 않는 막힌 단추가 남았고 첫 Tab 이 `body` 였어요.
- 로그인한 세 상태는 구조가 그대로예요. 문서의 `lang` 이 `ko` 가 돼서, 영어로 남은 그 부분은 `lang="en"` 을 따로 가져요. 이 상태들의 "숨김"은 로그인 form 이 숨겨졌다는 뜻이에요.
- 대조군의 320px 넘침이 none 인 것은 세션 없는 화면에 넓은 `<pre>` 가 더는 없어서예요. sheet 가 버려진 것은 CSS 규칙 0, 정책 위반 1건, 22px 대상으로 보여요.
- 재지 않은 것. 세션이 있는 사람이 `/` 를 열면 세션 확인이 끝날 때까지 로그인 카드가 먼저 보여요. 화면의 script 를 읽고 안 것이고 그 시간은 재지 않았어요. 로그인한 상태는 지어낸 JSON 으로 재서 시간이 실제와 달라요.

| 캡처 | 상태 |
| --- | --- |
| `l1b/l1b-home_signed_out-desktop.png`, `l1b/l1b-home_signed_out-320.png` | 세션 없는 `/` (실제 서버) |
| `l1b/l1b-home_no_client-320.png` | GitHub client 없는 서버의 `/` (실제 서버) |
| `l1b/l1b-invite_token-320.png` | 초대 링크로 연 `/accounts/invite` (실제 서버, 지어낸 token) |
| `l1b/l1b-invite_no_token-320.png` | token 없는 주소로 연 `/accounts/invite` (실제 서버) |
| `l1b/l1b-member_new-320.png` | Member 로 로그인한 `/` (실제 HTML, 지어낸 JSON) |

## L1c — 로그인 실패·완료 화면

바이너리 sha256 앞 12자리 `e39944514abc`. 제품 소스 tree 는 `lib` `29d587c3e5fb`, `bin` `525a6aa7d7a0` 이에요. 이 층의 코드 커밋에서 만들었어요(잴 때의 커밋 id 는 `9641f31214a8`, 안에 든 build id 도 같아요). 스택이 새 main 위로 옮겨진 뒤라 `bin` tree 도 앞 층과 달라요. 수치는 `l1c/l1c-measure.json` 이에요.

새로 잰 상태는 셋이에요.

- `refused_401`. 실제 서버의 `GET /auth/github/callback` 을 쿠키 없이 열었어요.
- `refused_404_no_client`. GitHub client 가 없는 서버의 같은 주소예요.
- `done_held`. 로그인을 마친 화면이에요. GitHub 로그인이 있어야 나오는 답이라 브라우저로는 못 가요. 로그인 시험(`test_server_login_http`)이 GitHub 를 대신해 로그인을 끝낸 자리에서 서버가 답한 header 와 바이트를 저장했고(`harness/ux-dump-done.py`), 대역이 그것을 그대로 줘요. 이 화면의 script 는 뜨자마자 다음 주소로 떠나게 써 있어요(`login_routes.ml` 의 `completion_page`). 재는 동안 머물게 하려고 대역이 정책의 script nonce 만 다른 값으로 바꿔 줬어요. sheet 의 nonce 는 그대로예요.

| 상태 | HTTP | axe 위반 | incomplete | CSS 규칙 | 정책 위반 | `style` 속성 | 24px 미만 대상 | 가장 낮은 대상 | landmark | 문서 `lang` | 첫 Tab | 320px 가로 넘침 | 시도 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| refused_401 | 401 | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 2 | `ko` | `a` | none | 1 |
| refused_404_no_client | 404 | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 2 | `ko` | `a` | none | 1 |
| done_held | 200 | 0 | 0 | 34 | 1 | 0 | 0 | 44px | 2 | `ko` | `a#next` | none | 1 |
| 전: refused_401 | 401 | 4 | 1 | 0 | 0 | 0 | 1 | 20px | 0 | `en` | `a` | none | 1 |
| 전: refused_404_no_client | 404 | 4 | 1 | 0 | 0 | 0 | 1 | 20px | 0 | `en` | `a` | none | 1 |

- "전" 두 줄은 앞 층 바이너리(`b85f755a84bb`)의 같은 두 주소예요(`l1c/l1c-before-measure.json`). axe 위반 넷은 `landmark-one-main`, `page-has-heading-one`, `region` 둘이고 incomplete 는 `bypass` 예요. 화면에 style 이 없었고, 하나뿐인 링크의 높이가 20px 이었어요.
- 정책. 실패 화면은 `default-src 'none'; style-src 'nonce-N'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'` 이에요. N 은 답마다 새로 뽑는 값이에요. 전에는 `style-src` 가 없었어요. 완료 화면은 여기에 `script-src 'nonce-N'` 이 더 있고, 이 줄은 전과 같아요.
- `done_held` 의 정책 위반 1건은 `script-src-elem` 이에요. 대역이 막아 둔 그 script 예요. 서버가 답한 그대로 둔 화면에서 script 가 돌아 떠나는 것은 재지 않았어요.
- 문서 제목은 `MASC 로그인 실패`, `MASC 로그인 완료` 예요.
- 나머지 아홉 줄(로그인 전 다섯, 로그인한 셋, 대조군)은 L1b 표와 값이 같아요.
- 완료 화면의 `href` 는 시험이 고른 돌아갈 주소예요. 실제 로그인에서는 로그인을 시작한 화면이 보낸 주소가 들어가요.

경로 시험(`test_login_routes`)이 두 화면의 정책과 nonce 와 sheet 를 붙드는지는 코드를 일부러 틀리게 고쳐서 봐요(`l1c/policy-mutants.py`, 결과 `l1c/policy-mutants.tsv`). 고칠 때마다 시험을 다시 빌드해 돌리고, 끝나면 스크립트가 소스를 원래대로 되돌려요.

이 층에서 처음 돌린 것은 아래 표의 위 넷이었고, 넷 다 잡혔어요. 그런데 완료 화면 정책의 `style-src` 와 그 뒤 지시어는 어떤 시험도 읽지 않았어요(#51592 리뷰). 완료 화면 시험은 정책에서 첫 nonce(`script-src` 의 것)만 꺼냈고, 실패 화면 시험은 빈 nonce·빈 sheet·모든 답이 같은 nonce 를 그대로 통과시켰어요. 후속 PR 이 시험을 고친 뒤 열둘을 다시 돌렸고, 열둘 다 잡혔어요.

| 틀리게 고친 것 | 결과 | 실패한 시험 |
| --- | --- | --- |
| 실패 화면의 정책에 `script-src 'self'` 를 더함 | 잡힘 | `refused` 의 `start`, `callback` |
| 실패 화면의 정책에서 `style-src` 를 뺌 | 잡힘 | `refused` 의 `start`, `callback` |
| 실패 화면의 sheet 를 정책과 다른 nonce 로 실음 | 잡힘 | `refused` 의 `start`, `callback` |
| 완료 화면의 sheet 를 정책과 다른 nonce 로 실음 | 잡힘 | `sign-in` 의 `Google, then sign out` |
| 완료 화면의 정책에서 `style-src` 를 뺌 | 잡힘 | `sign-in` 의 `Google, then sign out` |
| 완료 화면의 `style-src` 를 다른 nonce 로 | 잡힘 | `sign-in` 의 `Google, then sign out` |
| 완료 화면의 `script-src` 에 `'unsafe-inline'` 을 더함 | 잡힘 | `sign-in` 의 `Google, then sign out` |
| 완료 화면의 정책에서 `base-uri`·`form-action`·`frame-ancestors` 를 뺌 | 잡힘 | `sign-in` 의 `Google, then sign out` |
| 완료 화면의 `default-src` 를 `'self'` 로 | 잡힘 | `sign-in` 의 `Google, then sign out` |
| 모든 실패 화면이 같은 nonce 를 씀 | 잡힘 | `refused` 의 `start`, `callback` |
| 실패 화면의 nonce 가 빈 값 | 잡힘 | `refused` 의 `start`, `callback` |
| 화면 뼈대의 sheet 가 빈 값 | 잡힘 | `sign-in` 의 `Google, then sign out`, `refused` 의 `start`, `callback` |

| 캡처 | 상태 |
| --- | --- |
| `l1c/l1c-refused_401-desktop.png`, `l1c/l1c-refused_401-320.png` | 쿠키 없이 연 `/auth/github/callback` (실제 서버) |
| `l1c/l1c-refused_404_no_client-320.png` | GitHub client 없는 서버의 같은 주소 (실제 서버) |
| `l1c/l1c-done_held-desktop.png`, `l1c/l1c-done_held-320.png` | 로그인을 마친 화면 (시험이 저장한 서버의 답, script 는 막아 둠) |

## 후속 — 같은 탭에서 다시 연 초대 링크

초대 화면이 열린 탭에서 초대 링크를 또 열면 주소가 `#` 뒤만 달라져요. 브라우저는 그럴 때 문서를 다시 읽지 않아요. 화면 script 는 문서를 읽을 때 한 번만 token 을 읽어서, 고치기 전에는 주소창의 초대와 화면의 초대가 달랐어요. 고친 화면은 `#` 뒤가 바뀌면 자기를 다시 읽어요.

- 재는 법(`harness/invite-reopen.sh`, `harness/invite-reopen.mjs`). 실제 서버의 `/accounts/invite` 를 주소창이 여는 방식(`Page.navigate`)으로 열어요. 걸음마다 브라우저가 문서를 다시 읽었는지, 주소의 `#` 뒤 길이, 보이는 제목, 단추를 누르면 나갈 token 이 어느 링크 것인지를 적어요.
- token 둘은 모양만 맞춘 지어낸 값이에요(hex 64자). 서버가 낸 값이 아니고, 어떤 걸음도 그 값을 서버로 보내지 않아요.
- 전은 L1c 절의 바이너리(`e39944514abc`)예요. 그 뒤로 main 의 `lib/auth_preview.ml` 은 바뀌지 않았어요. 후는 고친 커밋 `9107df280028` 의 바이너리예요(sha256 앞 12자리 `c36648c75d65`, tree 는 `lib` `d37cb8ccb5a7`, `bin` `3c542c1c07e1`). 화면 본문과 script 를 쓰는 `auth_preview.ml` 은 두 `lib` tree 에서 6줄 더하고 1줄 뺀 것만 달라요. 화면 뼈대(`auth/account_page.ml`·`.css`)는 같아요. 경로를 다는 `server/server_login_http.ml` 처럼 다른 `lib` 파일도 여럿 달라요(`git diff --numstat 29d587c3e5fb 9107df280028:lib`). 서버가 답한 본문은 커밋하지 않아서 두 답을 직접 비교한 기록은 없어요.

| 걸음 | 전 (문서 · `#` 뒤 길이 · 제목 · 양식의 token) | 후 |
| --- | --- | --- |
| 첫 링크를 연다 | 읽음 · 0 · 초대를 받았어요 · 첫 링크 | 전과 같음 |
| 탭을 다시 읽는다 | 읽음 · 0 · 이 주소에는 초대 정보가 없어요 · 없음 | 전과 같음 |
| 같은 탭에서 첫 링크를 다시 연다 | 안 읽음 · 65 · 이 주소에는 초대 정보가 없어요 · 없음 | 읽음 · 0 · 초대를 받았어요 · 첫 링크 |
| 같은 탭에서 둘째 링크를 연다 | 안 읽음 · 65 · 이 주소에는 초대 정보가 없어요 · 없음 | 읽음 · 0 · 초대를 받았어요 · 둘째 링크 |
| (새로 시작) 첫 링크를 연다 | 읽음 · 0 · 초대를 받았어요 · 첫 링크 | 전과 같음 |
| 같은 탭에서 둘째 링크를 연다 | 안 읽음 · 65 · 초대를 받았어요 · 첫 링크 | 읽음 · 0 · 초대를 받았어요 · 둘째 링크 |

- 전의 셋째·넷째 줄. 주소창에는 token 이 있는데(`#` 뒤 65자) 화면은 초대 정보가 없다고 해요.
- 전의 마지막 줄. 주소창은 둘째 링크인데 양식에는 첫 링크의 token 이 남아 있어요. 단추를 누르면 첫 초대로 로그인을 시작해요. 다음 절의 L1c 열에서 실제로 눌러 봤어요.
- 전에는 다시 연 token 이 주소창에 그대로 남아요. 후에는 다시 읽힌 화면이 `#` 뒤를 지워요. 서버가 답할 때까지는 남아 있어요.
- 표는 `python3 harness/invite-reopen-table.py followup/before-invite-reopen.json followup/after-invite-reopen.json` 이 만들어요.
- 캡처는 셋째 줄의 전·후예요(`followup/before-reopen-3_open_the_first_link_again.png`, `followup/after-reopen-3_open_the_first_link_again.png`). 주소창은 캡처에 없어요.
- 뒤로 가기와, 다른 앱에서 링크를 눌러 새 탭으로 여는 길은 재지 않았어요.

## 후속 — 다시 읽는 동안 누른 초대 단추

앞 절의 화면은 `#` 뒤가 바뀌면 자기를 다시 읽어요. 그런데 서버가 답할 때까지는 첫 링크의 화면이 그대로 있고 단추도 눌려요. 그때 누르면 첫 초대로 로그인을 시작해요. 고친 화면은 `#` 뒤가 바뀌면 단추를 끄고 양식을 숨겨요. 새 링크를 불러오는 중이라고 적은 뒤 다시 읽어요.

- 재는 법(`harness/invite-press.sh`, `harness/invite-press.mjs`). 실제 서버 앞에 대역(`harness/invite-delay.mjs`)을 둬요. 대역은 다음 초대 화면의 답을 정한 시간만큼 붙잡아요. 로그인 시작(`POST /auth/github/start`)은 GitHub 으로 보내지 않고, 받은 초대 값을 적어 둬요.
- 첫 링크는 주소창 방식(`Page.navigate`)으로 열어요. 둘째 링크는 화면 안에서 `location.href` 로 열어요. 주소창에 붙여 넣을 때처럼 `#` 뒤만 바뀌어요. 둘째 링크를 주소창 방식으로 열면 이 브라우저는 붙잡은 시간이 끝난 뒤에야 누름을 넣었어요.
- 정한 시각에 첫 링크 화면의 단추가 있던 자리를 마우스로 눌러요. 누르기 전에 화면에 묻지 않아요.
- 키 두 경우는 첫 링크 화면에서 단추에 focus 를 준 뒤 둘째 링크를 열어요. Tab 으로 단추까지 간 사람과 같아요. 정한 시각에 Enter 나 Space 를 눌러요.
- 마지막 경우는 누르지 않고 화면만 찍어요. 붙잡은 시간 안에 찍은 캡처만 남겨요.
- 바이너리 셋. L1c 는 앞 절의 전(`e39944514abc`)이에요. 고치기 전은 앞 절의 수정(#51652)이 들어간 main `d09adad5eec2` 의 바이너리(`753209051476`)예요. 고친 뒤는 커밋 `3b9cb4472b2d` 의 바이너리(`085741658e67`)예요. 줄마다 답한 바이너리를 `binary` 에 적어요.
- 세 서버가 답한 초대 화면은 `followup/<label>-invite-page.html` 이에요. nonce 를 빼면 `hashchange` 를 듣는 부분만 달라요. L1c 는 그 부분이 없고, 고치기 전은 다시 읽기만 해요. 고친 뒤는 단추를 끄고 양식을 숨기고 안내를 적은 뒤 다시 읽어요. `d09adad5eec2` 뒤에 main 에 들어온 #51693 은 `/` 화면만 바꿨어요.

| 경우 | L1c | 고치기 전 | 고친 뒤 |
| --- | --- | --- | --- |
| 300ms 붙잡음, 150ms 에 마우스로 누름 | 누름(165ms): 첫 링크 → 로그인 시작 → 다시 누름: 단추 없음 | 누름(164ms): 첫 링크 → 로그인 시작 → 다시 누름: 단추 없음 | 누름(163ms): 보낸 것 없음 → 초대 화면 · 양식 둘째 링크 → 다시 누름: 둘째 링크 |
| 2000ms 붙잡음, 400ms 에 마우스로 누름 | 누름(412ms): 첫 링크 → 로그인 시작 → 다시 누름: 단추 없음 | 누름(413ms): 첫 링크 → 로그인 시작 → 다시 누름: 단추 없음 | 누름(408ms): 보낸 것 없음 → 초대 화면 · 양식 둘째 링크 → 다시 누름: 둘째 링크 |
| 2000ms 붙잡음, 400ms 에 focus 를 둔 단추에 Enter | Enter(410ms): 첫 링크 → 로그인 시작 → 다시 누름: 단추 없음 | Enter(413ms): 첫 링크 → 로그인 시작 → 다시 누름: 단추 없음 | Enter(407ms): 보낸 것 없음 → 초대 화면 · 양식 둘째 링크 → 다시 누름: 둘째 링크 |
| 2000ms 붙잡음, 400ms 에 focus 를 둔 단추에 Space | Space(406ms): 첫 링크 → 로그인 시작 → 다시 누름: 단추 없음 | Space(407ms): 첫 링크 → 로그인 시작 → 다시 누름: 단추 없음 | Space(405ms): 보낸 것 없음 → 초대 화면 · 양식 둘째 링크 → 다시 누름: 둘째 링크 |
| 2000ms 붙잡음, 400ms 에 화면만 찍음 | 찍음(481ms) → 초대 화면 · 양식 첫 링크 | 찍음(493ms) → 초대 화면 · 양식 둘째 링크 | 찍음(463ms) → 초대 화면 · 양식 둘째 링크 |

- 칸 읽는 법. "누름(165ms): 첫 링크" 는 둘째 링크를 열고 165ms 뒤에 눌렀더니 대역이 받은 초대가 첫 링크 값이었다는 뜻이에요. 화살표 뒤는 화면이 자리 잡은 뒤의 모습과, 거기서 같은 방법으로 한 번 더 누른 결과예요. "로그인 시작" 은 대역이 시작 요청에 돌려준 화면이에요.
- 누름과 찍음은 모두 붙잡은 시간 안에 들어갔어요(`actedInTime`).
- L1c. `#` 뒤가 바뀌어도 화면을 다시 읽지 않아요. 서버에 초대 화면을 다시 묻지 않았어요. 양식에 첫 링크가 남아서 언제 눌러도 첫 초대가 나가요.
- 고치기 전. 화면이 다시 읽기를 시작해요(초대 화면을 한 번 더 물음). 답이 오기 전에 누르면 첫 링크가 나가고, 브라우저는 다시 읽은 화면 대신 로그인 시작으로 가요.
- 고친 뒤. 기다리는 동안에는 단추 자리를 마우스로 누르든, focus 가 남은 단추에 Enter·Space 를 누르든 아무것도 나가지 않아요. 답이 오면 둘째 링크의 양식이 보이고, 그때 누르면 둘째 링크가 나가요.
- 키 줄의 L1c·고치기 전 열은 대조군이에요. focus 를 둔 단추에 키를 누르면 첫 링크가 나가요. 이 측정이 키로 누른 것을 잡는다는 뜻이에요.
- 캡처는 기다리는 동안의 화면이에요(`followup/<label>-while_the_server_answers.png`). L1c 와 고치기 전은 단추가 보이고, 두 파일은 바이트까지 같아요. 고친 뒤는 제목과 "새 초대 링크를 불러오고 있어요" 안내만 있어요.
- 기다리는 동안의 화면을 화면에 물어서 읽지는 못했어요. 이 측정에 쓴 브라우저(ego-browser)는 탭이 다른 문서를 읽는 동안 `page.evaluate` 와 `page.screenshot` 의 답을 미뤄요. 화면이 `window.name` 에 직접 적게도 해 봤어요. 다시 읽힌 문서에는 그 값이 없었고, 앞 측정이 적은 값이 다음 측정에서 읽혔어요. 그래서 마우스 누름과 `Page.captureScreenshot` 만 써요.
- 표는 `python3 harness/invite-press-table.py "L1c=followup/l1c-invite-press.json" "고치기 전=followup/before-invite-press.json" "고친 뒤=followup/after-invite-press.json"` 이 만들어요.

시험(`test/test_auth_preview_invite.js`)은 `lib/auth_preview.ml` 의 화면 script 를 node 에서 돌려요. 마크업의 id 와 `hidden` 은 소스에서 읽어요. 시험의 가짜 탭은 브라우저처럼 움직여요.

- 다시 읽기는 부른 때의 주소로 가요. 화면은 부른 일(task)이 끝난 때의 모습으로 남아요. 서버가 답할 때까지 사람이 보는 화면이에요.
- 시험은 그 화면에서 양식이 보이는지와 단추가 켜졌는지를 따로 봐요. 꺼진 단추는 focus 가 남아도 키로 보내지 않아요. 위 표의 Enter·Space 줄이 브라우저에서 잰 것이에요.
- `once` 로 들은 listener 는 한 번 부른 뒤 지워요. 둘째 링크의 답이 오기 전에 셋째 링크를 열면 한 번 더 다시 읽는지 봐요.
- 소스를 한 군데씩 바꾼 사본 스물셋에 이 시험을 돌렸어요(`followup/invite-mutants.py`, 결과 `followup/invite-mutants.tsv`). 사본은 출력 폴더에 쓰고 소스는 건드리지 않아요.
- 화면을 망가뜨리는 스물은 모두 잡혔어요. 단추를 켜 둠, 양식을 남김, 한 번만 들음도 여기에 들어요.
- 같은 일을 다르게 하는 둘(`window` 로 들음, 양식을 끄기 전에 다시 읽기를 부름)은 통과해요. 바꾸지 않은 소스도 통과해요.
- 기다린다는 안내를 빼는 하나는 시험이 보지 않아요. 문구는 위 캡처에 있어요.

재지 않은 것.

- 서버가 이 화면이 아닌 답(503 같은)을 줄 때. 다시 읽힌 문서에 `#` 뒤를 지우는 script 가 없으니 둘째 링크가 주소창에 남아요. 코드에서 읽은 동작이에요.
- 다시 읽기가 멈출 때(Esc, 끊긴 연결). 화면은 단추가 꺼진 채 "새로고침해 주세요" 안내를 남겨요. 코드에서 읽은 동작이에요.
- 기다리는 동안의 주소창. 캡처에는 주소창이 없어요.
- Chromium 밖의 브라우저(Firefox, Safari).

## 후속 — 세션을 읽지 못했을 때의 화면과 로그아웃

`/` 화면은 세션 경로(`GET /auth/session`)의 답으로 무엇을 보일지 정해요. 고치기 전에는 200 이 아니면 전부 로그인 카드를 보였어요. 권한 파일을 읽지 못하는 서버는 503 을 답하고 세션은 그대로 둬요. 그래서 로그인한 사람에게 로그아웃된 것처럼 보였어요. 고친 화면은 답 셋을 가려요. 세션이 있으면(200) 도구, 없으면(401) 로그인 카드, 그 밖에는 "확인하지 못했어요" 안내예요.

로그아웃도 답을 가려요. 세션이 끝났으면(204, 또는 세션이 없다는 401) 화면을 처음부터 다시 읽어요. 그 밖의 답이면 세션을 다시 읽고, 세션이 그대로면 로그아웃이 안 됐다고 상태 줄에 적어요.

- 재는 법(`harness/session-views.sh`, `harness/session-views.mjs`). 실제 서버가 답한 `/` 를 저장해 대역(`harness/ux-mock.mjs`)으로 주고, 대역이 세션 경로와 로그아웃 경로의 답을 경우마다 바꿔요. 로그아웃 단추는 키보드로 눌러요(focus 뒤 Enter). 줄마다 그 뒤 세션 경로의 답도 적어요. 그 값은 대역이 그 경우에 정한 답이에요. 실제 서버의 세션을 읽은 값이 아니에요.
- 대역에 경우 셋을 더했어요. `session_unread`(세션 경로가 503), `signout_refused`(로그아웃이 503, 그 뒤 세션 경로는 200), `zone_stops_at_signout`(로그아웃이 503 이고 그 뒤 세션 경로도 503).
- 실제 서버에서 503 인 로그아웃의 결과는 셋이에요. 권한 파일을 못 읽으면 세션 경로도 503 이에요(`zone_stops_at_signout`). 로그아웃 기록을 남기지 못했으면 세션이 그대로예요(`signout_refused`). 기록은 남겼는데 답을 쓰지 못했으면 세션이 끝났어요. 셋째는 대역으로 만들지 않았어요.
- 전은 앞 절의 고친 바이너리(`c36648c75d65`)예요. 앞 절의 변경은 초대 화면 script 한 줄이라 `/` 화면의 소스는 main 과 같아요. 후는 커밋 `0d6a6c20f925` 의 바이너리예요(sha256 앞 12자리 `299351730ed1`, tree 는 `lib` `6f21c79c99ae`, `bin` `3c542c1c07e1`).
- "문서에 남은 그 사람의 id" 는 보이든 숨었든 문서 글자에 든 지어낸 id(`pa_`, `rt_`, `pat_`, `usr_`)의 수예요. 처음 커밋한 값은 둘씩 적었어요. `<select>` 의 선택지 글자는 사이에 아무것도 없이 이어져서, 세는 식의 `\b` 가 붙은 id 를 못 셌어요(#51658 리뷰). 식을 고쳐 2026-11-13 에 같은 두 바이너리로 다시 쟀고, 표는 그 값이에요. 이 열 말고는 처음 값과 같아요.

| 경우 | | 보이는 화면 | 그 뒤 세션 경로의 답 | 상태 줄의 첫 줄 | focus | 문서에 남은 그 사람의 id | 문서 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 세션 경로가 503 인 서버에서 화면을 연다 | 전 | 로그인 카드 | 503 | 보이지 않음 | `body` | 0 | - |
| | 후 | 확인하지 못했다는 안내 | 503 | 보이지 않음 | `body` | 0 | - |
| 로그아웃한다, 서버가 세션을 끝낸다(204) | 전 | 로그인 카드 | 401 | 보이지 않음 | `body` | 13 | 그대로 |
| | 후 | 로그인 카드 | 401 | 보이지 않음 | `body` | 0 | 다시 읽음 |
| 로그아웃한다, 서버가 거절하고(503) 세션은 그대로다 | 전 | 로그인한 사람의 도구 | 200 | `session of usr_01JCM8P0Y4A7M2 until 2026-11-…` | `button#signout` | 15 | 그대로 |
| | 후 | 로그인한 사람의 도구 | 200 | `The sign-out did not happen (503), and the s…` | `button#signout` | 15 | 그대로 |
| 로그아웃한다, 서버가 거절하고(503) 세션 경로도 503 이 된다 | 전 | 로그인 카드 | 503 | 보이지 않음 | `body` | 13 | 그대로 |
| | 후 | 확인하지 못했다는 안내 | 503 | 보이지 않음 | `a#reopen` | 13 | 그대로 |

- 첫째 경우의 전. 세션 경로는 503 인데 화면은 로그인 카드예요.
- 둘째 경우의 전. 로그아웃한 뒤에도 그 사람의 id 열셋이 숨은 채 문서에 남았고, 누른 단추가 숨어서 focus 가 `body` 로 갔어요. 후에는 문서를 다시 읽어서 남는 것이 없어요.
- 셋째 경우의 전. 로그아웃이 안 됐는데 화면은 누르기 전과 같아요. `sign-out: 503` 줄을 바로 다음 읽기가 덮어썼어요.
- 넷째 경우의 전. 세션이 끝났다는 답이 없는데 화면은 로그인 카드예요. 후에는 안내가 뜨고 focus 가 "다시 열기" 링크로 가요. 세션이 끝났다는 답이 없으니 문서는 그대로 둬요.
- 표는 `python3 harness/session-views-table.py followup/before-session-views.json followup/after-session-views.json` 이 만들어요.

새 안내 화면의 수치는 `harness/ux-layer.sh` 에 상태 하나를 더해 쟀어요(`followup/f2-measure.json`). 바이너리는 후 바이너리(`299351730ed1`)이고, 상태 인자는 `'[["session_unread","MOCK","session_unread","/"]]'` 예요. 처음 커밋한 파일은 이 폴더에 없는 측정 스크립트(열린 스택 #51718 의 판)로 잰 것이었고, `member_new` 가 두 번째 시도에 재졌어요(#51658 리뷰). 2026-11-13 에 이 폴더의 harness 로 다시 쟀어요. 다시 잰 값은 처음 값과 시도 수만 달라요. 캡처는 바이트까지 같아요.

| 상태 | HTTP | axe 위반 | incomplete | CSS 규칙 | 정책 위반 | `style` 속성 | 24px 미만 대상 | 가장 낮은 대상 | 보이는 경로 답 원문 | 자유 입력 칸 | 로그인 단추(DOM) | 첫 Tab | 320px 가로 넘침 | 시도 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| session_unread | 200 | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 0 | 0 | 숨김 | `a#reopen` | none | 1 |

- 같은 실행의 나머지 아홉 줄(로그인 전 다섯, 로그인한 셋, 대조군)은 L1c 표와 값이 같아요. 다른 것은 `/` 의 live region 수 하나예요(8 → 9, 새 안내가 `role="alert"`).
- 캡처는 `followup/f2-session_unread-desktop.png`, `followup/f2-session_unread-320.png` 예요.
- 안내는 화면이 처음 보인 로그인 카드를 바꿔 끼우는 것이라 `role="alert"` 로 뒀어요. 화면 낭독기가 실제로 읽는지는 확인하지 않았어요.
- 화면은 세션 답이 오기 전까지 로그인 카드를 먼저 보여요. 고치기 전과 같고, 이 PR 은 바꾸지 않았어요. 얼마나 오래 보이는지는 재지 않았어요.
- CSRF token 이 낡아서 거절된(403) 로그아웃은 대역으로 만들지 않았어요. 거절 뒤에 읽은 token 을 다음 요청이 쓰는지는 script 시험(`test/test_auth_preview_session.js`)이 봐요.

## 확인하지 않은 것

- 실제 GitHub 로그인 뒤의 화면과 JSON 경로. 시험용 OAuth App 이 있어야 해요.
- 화면 낭독기로 읽는 소리, 다른 브라우저 엔진(WebKit, Gecko).
