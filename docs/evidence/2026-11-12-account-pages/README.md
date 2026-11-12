# 계정 서버 화면 실측 (2026-11-12)

계정 서버가 직접 쓰는 화면을 층마다 그 층의 바이너리로 띄워 실제 브라우저에서 잰 기록이에요. 화면 문구와 배치는 시험으로 고정하지 않아서(constitution `execution_protocol`), 이 폴더의 수치와 캡처가 근거예요.

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
- `done_held`. 로그인을 마친 화면이에요. GitHub 로그인이 있어야 나오는 답이라 브라우저로는 못 가요. 로그인 시험(`test_server_login_http`)이 GitHub 를 대신해 로그인을 끝낸 자리에서 서버가 답한 header 와 바이트를 저장했고(`harness/ux-dump-done.py`), 대역이 그것을 그대로 줘요. 이 화면은 뜨자마자 다음 주소로 떠나요. 재는 동안 머물게 하려고 대역이 정책의 script nonce 만 다른 값으로 바꿔 줬어요. sheet 의 nonce 는 그대로예요.

| 상태 | HTTP | axe 위반 | incomplete | CSS 규칙 | 정책 위반 | `style` 속성 | 24px 미만 대상 | 가장 낮은 대상 | landmark | 문서 `lang` | 첫 Tab | 320px 가로 넘침 | 시도 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| refused_401 | 401 | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 2 | `ko` | `a` | none | 1 |
| refused_404_no_client | 404 | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 2 | `ko` | `a` | none | 1 |
| done_held | 200 | 0 | 0 | 34 | 1 | 0 | 0 | 44px | 2 | `ko` | `a#next` | none | 1 |
| 전: refused_401 | 401 | 4 | 1 | 0 | 0 | 0 | 1 | 20px | 0 | `en` | `a` | none | 1 |
| 전: refused_404_no_client | 404 | 4 | 1 | 0 | 0 | 0 | 1 | 20px | 0 | `en` | `a` | none | 1 |

- "전" 두 줄은 앞 층 바이너리(`b85f755a84bb`)의 같은 두 주소예요(`l1c/l1c-before-measure.json`). axe 위반 넷은 `landmark-one-main`, `page-has-heading-one`, `region` 둘이고 incomplete 는 `bypass` 예요. 화면에 style 이 없었고, 하나뿐인 링크의 높이가 20px 이었어요.
- 정책. 실패 화면은 `default-src 'none'; style-src 'nonce-N'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'` 이에요. 전에는 `style-src` 가 없었어요. 완료 화면은 여기에 `script-src 'nonce-N'` 이 더 있고, 이 줄은 전과 같아요.
- `done_held` 의 정책 위반 1건은 `script-src-elem` 이에요. 대역이 막아 둔 그 script 예요. 서버가 답한 그대로면 script 가 돌고 화면이 떠나요.
- 문서 제목은 `MASC 로그인 실패`, `MASC 로그인 완료` 예요.
- 나머지 아홉 줄(로그인 전 다섯, 로그인한 셋, 대조군)은 L1b 표와 값이 같아요.
- 완료 화면의 `href` 는 시험이 고른 돌아갈 주소예요. 실제 로그인에서는 로그인을 시작한 화면이 보낸 주소가 들어가요.

경로 시험(`test_login_routes`)이 두 화면의 정책과 sheet 의 nonce 를 붙드는지는 코드를 일부러 틀리게 고쳐서 봤어요(`l1c/policy-mutants.py`, 결과 `l1c/policy-mutants.tsv`). 고칠 때마다 시험을 다시 빌드해 돌렸고 넷 다 시험이 실패했어요. 끝나면 스크립트가 소스를 원래대로 되돌려요.

| 틀리게 고친 것 | 결과 | 실패한 시험 |
| --- | --- | --- |
| 실패 화면의 정책에 `script-src 'self'` 를 더함 | 잡힘 | `refused` 의 `start`, `callback` |
| 실패 화면의 정책에서 `style-src` 를 뺌 | 잡힘 | `refused` 의 `start`, `callback` |
| 실패 화면의 sheet 를 정책과 다른 nonce 로 실음 | 잡힘 | `refused` 의 `start`, `callback` |
| 완료 화면의 sheet 를 정책과 다른 nonce 로 실음 | 잡힘 | `sign-in` 의 `Google, then sign out` |

| 캡처 | 상태 |
| --- | --- |
| `l1c/l1c-refused_401-desktop.png`, `l1c/l1c-refused_401-320.png` | 쿠키 없이 연 `/auth/github/callback` (실제 서버) |
| `l1c/l1c-refused_404_no_client-320.png` | GitHub client 없는 서버의 같은 주소 (실제 서버) |
| `l1c/l1c-done_held-desktop.png`, `l1c/l1c-done_held-320.png` | 로그인을 마친 화면 (시험이 저장한 서버의 답, script 는 막아 둠) |

## 후속 — 같은 탭에서 다시 연 초대 링크

초대 화면이 열린 탭에서 초대 링크를 또 열면 주소가 `#` 뒤만 달라져요. 브라우저는 그럴 때 문서를 다시 읽지 않아요. 화면 script 는 문서를 읽을 때 한 번만 token 을 읽어서, 고치기 전에는 주소창의 초대와 화면의 초대가 달랐어요. 고친 화면은 `#` 뒤가 바뀌면 자기를 다시 읽어요.

- 재는 법(`harness/invite-reopen.sh`, `harness/invite-reopen.mjs`). 실제 서버의 `/accounts/invite` 를 주소창이 여는 방식(`Page.navigate`)으로 열어요. 걸음마다 브라우저가 문서를 다시 읽었는지, 주소의 `#` 뒤 길이, 보이는 제목, 단추를 누르면 나갈 token 이 어느 링크 것인지를 적어요.
- token 둘은 모양만 맞춘 지어낸 값이에요(hex 64자). 서버가 낸 값이 아니고, 어떤 걸음도 그 값을 서버로 보내지 않아요.
- 전은 L1c 절의 바이너리(`e39944514abc`)예요. 그 뒤로 main 의 `lib/auth_preview.ml` 은 바뀌지 않았어요. 후는 고친 커밋 `9107df280028` 의 바이너리예요(sha256 앞 12자리 `c36648c75d65`, tree 는 `lib` `d37cb8ccb5a7`, `bin` `3c542c1c07e1`). 두 서버가 답한 `/accounts/invite` 는 nonce 를 빼면 더한 한 줄만 달라요.

| 걸음 | 전 (문서 · `#` 뒤 길이 · 제목 · 양식의 token) | 후 |
| --- | --- | --- |
| 첫 링크를 연다 | 읽음 · 0 · 초대를 받았어요 · 첫 링크 | 전과 같음 |
| 탭을 다시 읽는다 | 읽음 · 0 · 이 주소에는 초대 정보가 없어요 · 없음 | 전과 같음 |
| 같은 탭에서 첫 링크를 다시 연다 | 안 읽음 · 65 · 이 주소에는 초대 정보가 없어요 · 없음 | 읽음 · 0 · 초대를 받았어요 · 첫 링크 |
| 같은 탭에서 둘째 링크를 연다 | 안 읽음 · 65 · 이 주소에는 초대 정보가 없어요 · 없음 | 읽음 · 0 · 초대를 받았어요 · 둘째 링크 |
| (새로 시작) 첫 링크를 연다 | 읽음 · 0 · 초대를 받았어요 · 첫 링크 | 전과 같음 |
| 같은 탭에서 둘째 링크를 연다 | 안 읽음 · 65 · 초대를 받았어요 · 첫 링크 | 읽음 · 0 · 초대를 받았어요 · 둘째 링크 |

- 전의 셋째·넷째 줄. 주소창에는 token 이 있는데(`#` 뒤 65자) 화면은 초대 정보가 없다고 해요.
- 전의 마지막 줄. 주소창은 둘째 링크인데 양식에는 첫 링크의 token 이 남아 있어요. 단추를 누르면 첫 초대로 로그인을 시작해요.
- 전에는 다시 연 token 이 주소창에 그대로 남아요. 후에는 걸음마다 `#` 뒤가 지워져요.
- 표는 `python3 harness/invite-reopen-table.py followup/before-invite-reopen.json followup/after-invite-reopen.json` 이 만들어요.
- 캡처는 셋째 줄의 전·후예요(`followup/before-reopen-3_open_the_first_link_again.png`, `followup/after-reopen-3_open_the_first_link_again.png`). 주소창은 캡처에 없어요.
- 뒤로 가기와, 다른 앱에서 링크를 눌러 새 탭으로 여는 길은 재지 않았어요.

## 확인하지 않은 것

- 실제 GitHub 로그인 뒤의 화면과 JSON 경로. 시험용 OAuth App 이 있어야 해요.
- 화면 낭독기로 읽는 소리, 다른 브라우저 엔진(WebKit, Gecko).
