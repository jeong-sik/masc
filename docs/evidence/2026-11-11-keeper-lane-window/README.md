# 작업 대기열 목록: 5,000행이어도 화면 근처 행만 그려요

이슈 #26606 을 브라우저에서 재현하고, 고친 뒤 다시 잰 기록이에요.

Keeper 작업 화면의 "작업 대기열"은 서버가 준 대기 행을 전부 DOM 에 그렸어요. 서버는 행 수를 자르지 않아요. 다른 Keeper 를 골라도 목록의 스크롤 위치가 그대로 남았어요.

## 무엇으로 쟀나요

`dashboard/fixtures/2026-11-11-keeper-lane-window/` 가 실제 `KeeperLaneStrip` 에 만든 대기 목록을 넣어요. Keeper 는 alpha 와 beta 둘이고, 자율 이벤트가 5,000행씩 있어요. 백엔드는 없어요.

`browser.mjs` 가 headless Chromium 으로 이 화면을 움직여요. 기대값을 검사하기 전에 측정값을 `measurements.json` 에 먼저 써요. 그래서 고치기 전 코드에서도 같은 스크립트로 숫자가 남아요.

같은 `fixture.ts` 와 `browser.mjs` 로 두 번 돌렸어요.

| | 소스 | 결과 파일 |
|---|---|---|
| 앞 | main `7ba926ef4f60` | [`before-main-7ba926ef4f60/measurements.json`](before-main-7ba926ef4f60/measurements.json) |
| 뒤 | 브랜치 `fix/26606-lane-inventory-window` 커밋 `193c80e43ae2` (main `7ba926ef4f60` 위) | [`after-193c80e43ae2/browser-result.json`](after-193c80e43ae2/browser-result.json) |

환경은 macOS 27.2, Apple M3 Max, Playwright 1.61.1 이 띄운 Chromium 149.0.7827.55 headless, 창 1280×900, vite dev 서버예요.

## 결과

| 항목 | 앞 (main) | 뒤 |
|---|---|---|
| 처음 열었을 때 DOM 에 있는 대기 행 | 5,000 | 17 |
| 그중 목록 높이 하나보다 멀리 있는 행 | 4,977 | 0 |
| 목록 갱신 한 번에 든 시간, 9번의 중앙값 | 916 ms (866~1,103) | 8.7 ms (8.0~12.3) |
| 맨 끝 행이 보일 때까지 끝으로 스크롤한 횟수 | 1 | 2 |
| 맨 끝 행에서 누른 `normal` 이 보낸 주소 | 맨 끝 행의 주소 | 맨 끝 행의 주소 |
| 포커스를 둔 행이 화면 밖으로 나간 뒤 포커스 위치 | 그 행 (DOM 에 남아 있어요) | 목록 |
| 열어 둔 첫 행이 화면 밖에 나갔다 돌아온 뒤 | 열려 있어요 | 열려 있어요 |
| beta 로 바꾼 뒤 스크롤 위치 | 213,660 px (alpha 에서 내린 그대로) | 0 px |
| beta 로 바꾼 뒤 첫 행이 보이나요 | 아니요 | 예 |
| beta 로 바꾼 뒤 열려 있는 행 | 2 | 0 |

- "목록 갱신 한 번"은 fixture 가 다음 서버 응답처럼 행 객체를 모두 새로 만들어 다시 그리는 시간이에요. 앞의 3행이 빠지고 뒤에 3행이 붙어요. 동기 render 와 바로 뒤의 강제 layout 까지 재고, paint 는 재지 않았어요.
- 뒤에서 끝까지 두 번 스크롤한 이유는 행 높이예요. 목록은 아직 안 그린 행을 40 px 로 어림하고, 그린 행은 실제 높이(이 fixture 에서 42.8 px)로 다시 재요. 처음 끝에 닿으면 방금 잰 만큼 목록이 길어져서 한 번 더 내려야 해요.
- 앞에서 beta 에 열려 있던 2행은 alpha 에서 연 첫 행과 끝 행의 자리예요. beta 에서는 아무 행도 열지 않았어요.

고치기 전, alpha 목록을 끝까지 내리고 beta 를 고른 직후예요. beta 의 끝 행이 보이고, 열지 않은 행이 열려 있어요.

![앞: beta 로 바꿨는데 목록이 끝에 있고 끝 행이 열려 있어요](before-main-7ba926ef4f60/keeper-switch.png)

고친 뒤 같은 순서예요. beta 의 첫 행부터 보여요.

![뒤: beta 의 첫 행부터 보여요](after-193c80e43ae2/keeper-switch.png)

고친 뒤 alpha 목록의 끝이에요. 5,000번째 행을 열어 동작 버튼을 눌렀어요.

![뒤: alpha 목록의 끝 행을 연 모습](after-193c80e43ae2/list-end.png)

## 치른 값

화면 밖 행은 DOM 에 없어요. 그래서 브라우저 찾기(Ctrl-F)는 화면 근처 행만 찾아요. 40행 이하인 목록은 전처럼 모든 행이 DOM 에 있어요.

## 확인하지 않은 것

- 실제 서버와 실제 Keeper 의 대기 행으로는 보지 않았어요. 운영 서버가 지금 Keeper 하나에 몇 행을 주는지도 재지 않았어요.
- 대기 목록 store 와 SSE 로 오는 갱신은 fixture 에 없어요. fixture 가 새 목록을 직접 넣어요.
- Tools 화면과 예약 화면의 같은 목록은 브라우저로 열어 보지 않았어요. 두 화면도 같은 `LaneWaitingRows` 를 쓰고, vitest 시험 하나가 Tools 패널에서 2,000행 중 일부만 그려지는지 봐요.
- fixture 는 앱 전체 스타일 대신 `ds-theme-tokens.css`, `global.css`, `keeper-workspace.css` 만 불러요. 실제 화면의 행 높이는 42.8 px 와 다를 수 있어요.
- Chromium 에서만 봤어요.

## 다시 돌리기

```bash
cd dashboard
node fixtures/2026-11-11-keeper-lane-window/browser.mjs
```

결과는 `artifacts/dashboard/2026-11-11-keeper-lane-window/run-*/` 에 생겨요. Keeper 하나의 행 수는 `LANE_WINDOW_ROWS` 로 바꿔요.

앞의 숫자는 main `7ba926ef4f60` 을 꺼낸 폴더에 이 fixture 폴더를 넣고 같은 명령을 돌린 값이에요. 그 실행은 측정값을 쓴 다음 첫 기대값에서 실패로 끝나요.
