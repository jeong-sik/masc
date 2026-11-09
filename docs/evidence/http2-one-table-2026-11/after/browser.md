# 브라우저가 보는 전송 (RFC-0512 §5 브라우저 항목)

2026-11-09 00:49Z, 라이브 서버(빌드 `9c7452c0e208`, 11-08 23:07Z 시작)에 ego lite 0.6.2.9(Chromium 156.0.8078.74, `ego-browser` CLI)로 같은 대시보드 탭을 두 번 열었다. 한 번은 TLS 리스너 `https://127.0.0.1:8938/`, 한 번은 평문 리스너 `http://127.0.0.1:8935/`. 서버는 둘 다 `302` 로 `/dashboard` 에 보내고, `#overview` 는 대시보드 클라이언트가 붙인다. 자체 서명 인증서는 CDP `Security.setIgnoreCertificateErrors` 로 넘겼다. 로그인은 하지 않았다(화면은 "Login required").

## 방법

스크립트가 페이지를 열고 5초 뒤 `performance.getEntriesByType("navigation")[0].nextHopProtocol` 과 자원(`resource`) 항목의 `nextHopProtocol` 을 세고, 같은 순간 `lsof -nP -iTCP:<port> -sTCP:ESTABLISHED` 로 프로세스별 연결 수를 셌다. 브라우저 몫은 COMMAND 가 `ego Helper`(lsof 표시 `ego\x20He`)인 행이다. `masc` 행은 같은 연결의 서버 쪽이고, 다른 클라이언트(cloudflared, 다른 세션)의 행은 세지 않았다. `nextHopProtocol` 은 DevTools Network 의 Protocol 열이 보여 주는 값과 같은 값이다. 아래 스니펫은 측정 때 돌린 것 그대로다(`ego-browser nodejs` 의 `page` 객체).

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
| 브라우저 → 리스너 ESTABLISHED 연결(load 5초 뒤 한 순간) | 1개 | 4개 |

- 측정 순간 한 탭이 TLS 리스너에는 연결 1개, 평문 리스너에는 연결 4개를 열고 있었다. 연 연결의 총수는 재지 않았다. 평문의 상한은 Chromium 의 origin 그룹당 소켓 6개다(`net/socket/client_socket_pool_manager.cc` 의 `g_max_sockets_per_group`, kNormal 6).
- #50192 와 S4(#49840)가 적은 "한 탭 연결 수 전·후" 의 "전" 은 같은 빌드의 평문 리스너 값이다. 브라우저는 h2c 를 쓰지 않으므로 평문 리스너의 전송은 S4 전과 같다.
- `nextHopProtocol` 이 빈 32개는 네트워크를 타지 않은 응답(캐시)이거나 timing 정보가 가려진 자원이다. 어느 쪽인지 가르지 않았다.
- 로그인 전 화면이라 로그인 뒤에 열리는 스트림은 들어 있지 않다.

## 재지 않은 것

- 로그인 뒤 열리는 SSE·WebSocket 연결 수. 공개 호스트(`masc.crying.pictures`)를 거친 값. 다른 브라우저.
- 브라우저 프로필의 이전 방문·캐시 상태는 통제하지 않았다. 8935 는 운영자가 평소 쓰는 주소다. 자원 항목 수가 35 대 51 로 다른 이유도 가르지 않았다.
- 같은 브라우저의 다른 탭이 이 포트에 붙어 있었는지는 확인하지 않았다. lsof 는 탭이 아니라 프로세스 단위로 센다.

## 파일

- 스크린샷은 운영자 로컬 `~/me/.tmp/masc-h2-dashboard-8938.png` 에 두고 저장소에는 넣지 않았다(화면에 운영 상태 문구가 있다). 수치는 위 표가 전부다.
