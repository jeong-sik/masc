# 계정 서버 화면 실측 (2026-11-12)

계정 서버가 직접 쓰는 화면을 층마다 그 층의 바이너리로 띄워 실제 브라우저에서 잰 기록이에요. 화면 문구와 배치는 시험으로 고정하지 않아서(constitution `execution_protocol`), 이 폴더의 수치와 캡처가 근거예요.

## 방법

- 서버. 그 층 커밋으로 만든 `masc` 바이너리로 임시 폴더에 다계정 설치 둘을 만들어 `127.0.0.1` 의 빈 포트에 띄웠어요. 하나는 GitHub 로그인 client 가 있고(지어낸 client id), 하나는 없어요. 환경은 `env -i` 로 비웠고 HOME 은 빈 임시 폴더예요. 운영 중인 설치는 쓰지 않았어요(`harness/ux-serve.sh`).
- 브라우저. Chromium 156(ego-browser 0.6.2.9)이에요. 접근성 검사는 axe-core 4.14.0 의 `wcag2a`, `wcag2aa`, `wcag21a`, `wcag21aa`, `wcag22aa`, `best-practice` 규칙이에요.
- 로그인 전 상태 다섯은 실제 서버에 바로 붙여 쟀어요.
- 로그인한 상태 셋은 GitHub 로그인이 있어야 해서 실제 서버로는 못 만들어요. 실제 서버가 답한 HTML 과 header(CSP 포함)를 저장해 그대로 주고, JSON 경로의 답만 지어낸 대역(`harness/ux-mock.mjs`)으로 쟀어요. 화면에 보이는 id 는 전부 지어낸 값이에요. 서버의 JSON 경로를 본 것은 아니에요.
- 대조군. 같은 저장 화면을, 정책의 style nonce 만 다른 값으로 바꿔서 줘요. 브라우저가 sheet 를 버리고 정책 위반을 한 건 내야 측정이 맞게 도는 거예요.
- 재는 것(`harness/ux-measure3.mjs`). axe 위반과 incomplete, 적용된 CSS 규칙 수, 브라우저가 낸 정책 위반(`securitypolicyviolation`) 건수, `style` 속성 수, 24px 미만 누름 대상 수, 가장 낮은 대상 높이, 보이는 `<pre>` 가운데 HTTP 상태나 JSON 이 든 것의 수, 자유 입력 칸 수, 첫 Tab 이 닿는 요소, 폭 320 CSS px 에서의 가로 넘침이에요.
- 캡처는 상태마다 데스크톱과 320px 둘이에요. 320px 캡처는 Tab 을 한 번 누른 뒤에 찍어서 focus 표시가 보여요. 폴더에는 고른 것만 넣었어요.

다시 재려면 axe-core 4.14.0 의 `axe.min.js` 를 `harness/` 안에 두고(저장소에는 넣지 않았어요) 아래를 돌려요. 포트 넷을 쓰고, 끝나면 띄운 것을 스스로 내려요.

```sh
sh harness/ux-layer.sh <masc 바이너리> <label> <출력 폴더> <빈 포트>
python3 harness/ux-table.py <출력 폴더>/<label>-measure.json
```

## L1a — stylesheet 와 화면 뼈대

커밋 `b706d4df8092`, 바이너리 sha256 앞 12자리 `ff7012df7e35`. 수치는 `l1a/l1a-measure.json` 이에요.

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

## 확인하지 않은 것

- 실제 GitHub 로그인 뒤의 화면과 JSON 경로. 시험용 OAuth App 이 있어야 해요.
- 화면 낭독기로 읽는 소리, 다른 브라우저 엔진(WebKit, Gecko).
