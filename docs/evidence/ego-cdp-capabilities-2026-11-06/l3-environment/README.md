# L3 위치·언어·시간대 시험 (2026-11-06)

[RFC-browser-ego-cdp-capabilities](../../../rfc/RFC-browser-ego-cdp-capabilities.md) §5 L3 의 확인이다.
ego 연결의 set_emulation·clear_emulation 이 기대는 CDP 동작을 쟀다.

## 환경

- ego lite 0.6.2.7, Chromium 156.0.8078.74, macOS (MacBook M3 Max)
- masc 서버를 거치지 않았다. `ego-browser nodejs` 를 직접 불렀다.
- 시험 전용 task space 에서 돌렸다(26, 27, 28). 26·27 은 시험 뒤 `finish({keep: []})` 로 닫았다.
- 페이지는 [`../probe-page.html`](../probe-page.html) 를 `index.html` 로 두고 `python3 -m http.server <port> --bind 127.0.0.1` 로 띄웠다. 포트는 18768, 18769, 18770 이다. 권한은 origin 마다 따로라서 포트를 나눴다.

## 명령과 시각

모두 `ego-browser nodejs < <probe> > <result> 2>&1` 로 돌렸다. 결과 파일의 `[ego-browser:notice]` 줄은 ego 업데이트 안내다.
시각은 결과 파일을 다 쓴 때(UTC)다.

| probe | 결과 | 끝난 시각 |
|---|---|---|
| `probe-env-a.mjs` | `result-env-a.json` | 04:36:25Z |
| `probe-env-b.mjs` | `result-env-b.json` | 04:36:26Z |
| `probe-env-c.mjs` | `result-env-c.jsonl` | 06:17:09Z |
| `probe-env-d.mjs` | `result-env-d.jsonl` | 06:17:29Z |
| `probe-env-e.mjs` | `result-env-e.jsonl` | 06:17:50Z |
| `probe-env-f.mjs` | `result-env-f.jsonl` | 06:18:12Z |
| `probe-env-g.mjs` | `result-env-g1.jsonl` | 06:29:49Z |
| `probe-env-g2.mjs` | `result-env-g2.jsonl` | 06:30:14Z |
| `probe-env-h.mjs` | `result-env-h.jsonl` | 06:30:27Z |
| `probe-env-i.mjs` | `result-env-i.jsonl` | 06:34:03Z |

## 먼저 일어난 일: 운영자 화면에 권한 창이 떴다 (a, b)

`probe-env-a.mjs` 는 `task.cdp("Browser.setPermission", …)` 를 부른 뒤 결과를 확인하지 않고 `getCurrentPosition` 을 불렀다.
`Browser.setPermission` 은 task 세션에 없어서(아래 c) 권한이 없었다. 그래서 운영자 ego 창에 위치 권한 창이 떴다.
SDK 는 `A browser permission prompt for location access has appeared. The user now controls this task space.` 로 프로세스를 끝냈다(종료 코드 1).
같은 space 를 여는 다음 프로세스(b)도 같은 오류로 끝났다.

그 뒤 시험은 `navigator.permissions.query` 가 `granted` 라고 할 때만 위치를 읽었다. 권한 창을 띄우는 호출은 f 의 한 번뿐이고, 그때 상태는 `granted` 였다.

18768 의 권한은 지금 `granted` 다(c, e). `Browser.resetPermissions` 뒤에도, 새 프로세스에서도 남았다. CDP 로 준 권한은 둘 다에서 사라졌으므로(3), 이 권한은 그 권한 창에서 허용해 프로필에 저장된 것으로 본다.

## 결과

### 1. 덮어쓰기는 걸리고, 새로고침과 다시 열기 뒤에도 남는다 (c)

| 시점 | language | Intl locale | 시간대 |
|---|---|---|---|
| 덮어쓰기 전 | ko-KR | ko | Asia/Seoul |
| locale fr-FR·시간대 America/New_York·Accept-Language fr-FR 뒤 | fr-FR | fr-FR | America/New_York |
| 새로고침 뒤 | fr-FR | fr-FR | America/New_York |
| 같은 프로세스에서 task space 를 다시 연 뒤 | fr-FR | — | America/New_York |

c 의 language 는 `Emulation.setUserAgentOverride` 의 `acceptLanguage` 로 바뀐 것이다. 앞선 측정(`../result-a.json`)에서 `setLocaleOverride` 만으로는 language 가 그대로였다. masc 는 user agent 를 덮어쓰지 않으므로 locale 은 Intl 만 바꾼다.

### 2. 권한 명령은 Page 세션으로만 간다 (c, d)

| 명령 | `task.cdp` | `page.cdp` |
|---|---|---|
| `Browser.setPermission` | `wasn't found` | 받음 |
| `Browser.grantPermissions` | `wasn't found` | 받음 |
| `Browser.resetPermissions` | `wasn't found` | 받음 |
| `Browser.getVersion` | `wasn't found` | 재지 않음 |

### 3. 권한은 SDK 프로세스와 같이 끝나고, origin 이 없으면 모든 origin 에 걸린다 (e, g)

- 앞선 프로세스가 18769 에 준 권한은 새 프로세스에서 `prompt` 였다(e 첫 줄).
- `Browser.resetPermissions` 는 CDP 로 준 것만 지운다. 18768 의 저장된 권한은 남았다.
- origin 을 주면 그 origin 의 위치 권한만 바뀌었다. notifications·camera·microphone 은 그대로 `prompt` 였다.
- origin 없이 notifications 를 `denied` 로 두면 18769 와 18770 이 둘 다 `denied` 가 됐다. 다음 프로세스에서는 `prompt` 로 돌아왔다(f 첫 줄). masc 는 항상 페이지의 origin 을 준다.
- locale ja-JP·시간대 Asia/Tokyo·위치 권한을 건 채로 프로세스가 끝나면, 다음 프로세스에서는 셋 다 처음 값이었다(g2).

### 4. 권한이 있으면 덮어쓴 위치가 창 없이 온다 (f)

18770 에 `page.cdp("Browser.setPermission")` 와 `Emulation.setGeolocationOverride`(37.5665, 126.978, 25 m)를 걸었다. 상태가 `granted` 인 것을 본 뒤 `getCurrentPosition` 을 불렀다.
덮어쓴 값 그대로 왔고 창은 뜨지 않았다. `resetPermissions` 뒤 상태는 `prompt` 였다.

### 5. 해제, 다시 걸기, 잘못된 값 (g, h)

- 해제(`setLocaleOverride {}`, `setTimezoneOverride {timezoneId: ""}`, `clearGeolocationOverride`)는 처음 값을 돌려놓았다. 두 번 해제해도 오류가 없었다.
- 걸린 위에 다시 걸면 오류 없이 새 값으로 바뀌었다.
- 시간대는 모르는 이름(`Mars/Olympus`)이나 대소문자가 다른 이름(`asia/seoul`)에도 오류가 없었다. 앞의 시간대가 그대로 남았다.
- 시간대 별칭은 정규 이름으로 바뀌었다. `US/Eastern` 은 `America/New_York`, `Asia/Kolkata` 는 `Asia/Calcutta` 로 보였다.
- locale 은 `x-bad`, `123` 에 `Invalid locale name` 오류를 냈다. `fr-fr` 은 `fr-FR` 로 보였다. `zz-ZZ-x-notreal` 은 오류 없이 `zz-ZZ` 로 보였다.

### 6. masc 가 보내는 스크립트 (i)

`emulation.js` 는 `lib/browser_ego_peer.ml` 의 `emulation_script` 와 같은 글이다. 여섯 경우를 돌렸다.

| 경우 | 답 |
|---|---|
| locale `fr-fr`, 시간대 `US/Eastern`, 위치 | 네 단계 적용. 페이지가 fr-FR, America/New_York, `granted` 로 보고 |
| 시간대 `Mars/Olympus` | 바꾸기 전에 거절: `Invalid time zone specified` |
| locale `123` | 바꾸기 전에 거절: `Invalid language tag` |
| 시간대 `asia/seoul` | 페이지 Intl 이 `Asia/Seoul` 로 고친 이름을 보내 적용 |
| 시간대 `Asia/Kolkata` | `Asia/Calcutta` 로 적용 |
| 해제 | 세 덮어쓰기를 지우고 ko, Asia/Seoul 로 보고. 위치 권한은 `granted` 그대로 |

## masc 에 옮긴 것

- 페이지의 Intl 로 시간대와 locale 이름을 먼저 고친다. Intl 이 모르는 이름은 바꾸기 전에 거절한다(5의 시간대가 오류 없이 무시되기 때문이다).
- 덮어쓴 뒤 페이지가 보고하는 시간대가 보낸 이름과 다르면 실패로 답한다. 다른 단계가 이미 걸렸으면 partial 이다.
- 위치 권한은 `page.cdp("Browser.setPermission")` 로 페이지의 origin 에만 준다(2, 3). 그 권한은 ego 프로필에서 같은 origin 의 모든 탭에 걸린다.
- 답은 `lifetime: "ego_sdk_process"` 와 `localeScope: "intl_only"` 를 싣는다. 덮어쓰기와 권한이 언제 끝나는지는 `sdkProcessStartedAt` 이 알려 준다(3).
- clear_emulation 은 덮어쓰기만 지우고 권한은 둔다(RFC §4 D3).

## 이 시험이 보여 주지 않는 것

- masc 서버의 `page.emulation` 단계를 통째로 돌리지 않았다. 단계 주변 스크립트는 `test/test_browser_ego_peer.ml` 의 가짜 runner 시험과 `node --check` 시험이 맡는다.
- 덮어쓰기를 지운 뒤 권한이 남은 페이지가 실제 위치를 읽는지는 재지 않았다. 재면 운영자의 실제 위치를 읽게 된다.
- 다른 origin 으로 옮긴 뒤 덮어쓰기가 남는지는 재지 않았다.
- 브라우저를 껐다 켠 뒤는 재지 않았다. 권한이 SDK 프로세스와 같이 끝나므로 그보다 오래 남지 않는다.
