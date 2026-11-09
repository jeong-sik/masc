# 브라우저가 보는 전송 (RFC-0512 §5 브라우저 항목)

2026-11-09 00:49Z, 라이브 서버(빌드 `9c7452c0e208`, 11-08 23:07Z 시작)에 ego-browser 2.2.0(Chromium 기반)으로 같은 대시보드 탭을 두 번 열었다. 한 번은 TLS 리스너 `https://127.0.0.1:8938/`, 한 번은 평문 리스너 `http://127.0.0.1:8935/`. 둘 다 `/dashboard#overview` 로 리다이렉트된다. 자체 서명 인증서는 CDP `Security.setIgnoreCertificateErrors` 로 넘겼다. 로그인은 하지 않았다(화면은 "Login required").

## 방법

스크립트가 페이지를 열고 5초 뒤 `performance.getEntriesByType("navigation")[0].nextHopProtocol` 과 자원(`resource`) 항목의 `nextHopProtocol` 을 세고, 같은 순간 `lsof -nP -iTCP:<port> -sTCP:ESTABLISHED` 로 프로세스별 연결 수를 셌다. DevTools Network 의 Protocol 열이 보여 주는 값과 같은 값이다.

```js
await page.cdp("Security.setIgnoreCertificateErrors", { ignore: true });
await page.goto("https://127.0.0.1:8938/");
await page.waitForLoadState("load");
await page.waitForTimeout(5000);
const seen = await page.evaluate(() => {
  const nav = performance.getEntriesByType("navigation")[0];
  const by = {};
  for (const e of performance.getEntriesByType("resource")) by[e.nextHopProtocol || "?"] = (by[e.nextHopProtocol || "?"] || 0) + 1;
  return { url: location.href, navProto: nav.nextHopProtocol, byProto: by };
});
```

## 결과

| | TLS 리스너 8938 | 평문 리스너 8935 |
|---|---|---|
| 문서(navigation)의 프로토콜 | `h2` | `http/1.1` |
| 자원 항목 | 35개, 모두 `h2` | 51개. `http/1.1` 19개, `nextHopProtocol` 이 빈 것 32개 |
| 브라우저 → 리스너 ESTABLISHED 연결 | 1개 | 4개 |

- 한 탭이 TLS 리스너에서는 연결 하나로 문서와 자원 35개를 받는다. 평문 리스너에서는 같은 탭이 연결 4개를 연다(브라우저의 origin 당 상한은 6개).
- `nextHopProtocol` 이 빈 32개는 네트워크를 타지 않은 응답(캐시)이거나 timing 정보가 가려진 자원이다. 어느 쪽인지 가르지 않았다.
- 로그인 전 화면이라 로그인 뒤에 열리는 스트림은 들어 있지 않다.

## 재지 않은 것

- 로그인 뒤 열리는 SSE·WebSocket 연결 수. 공개 호스트(`masc.crying.pictures`)를 거친 값. 다른 브라우저.

## 파일

- 스크린샷은 운영자 로컬 `~/me/.tmp/masc-h2-dashboard-8938.png` 에 두고 저장소에는 넣지 않았다(화면에 운영 상태 문구가 있다). 수치는 위 표가 전부다.
