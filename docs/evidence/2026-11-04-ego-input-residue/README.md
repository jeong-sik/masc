# Ego 입력이 끊긴 뒤 남는 것 — 실측 (2026-11-04)

RFC `docs/rfc/RFC-browser-ego-input-lock.md` 의 M1~M3 와, SDK 공개 해제 호출(E)을 잰 기록이다.

- 버전: ego-browser 0.6.2.5, Chromium 156.0.8078.74, 내장 node v24.22.1
- 실행: `sed "s#__FIXTURE__#file://$PWD/fixture.html#" probe-residue.js | ego-browser nodejs`
  (`probe-m3.js`, `prepress/probe-prepress.js` 도 같은 방식). 스크립트마다 자기 task space 를 만들고 끝에 `finish({keep: []})` 로 지운다.
- 결과: `results.json` (`runs[0]` = `probe-residue.js`, `runs[1]` = `probe-m3.js`), `prepress/results.json`
- 로컬 경로는 `<fixture>/` 로 바꿨다.

## 확인 방법

끊긴 동작 뒤에 대화상자를 받아 주고, 같은 Page(p1)와 같은 Space 의 다른 Page(p2)에서
버튼 클릭 한 번과 입력칸에 `ab` 타이핑을 한다. 페이지가 받은 이벤트에서 아래 중 하나라도 보이면 "남음"으로 센다.

- 클릭의 mousedown `buttons` 가 `[1]` 이 아님, click 이 한 번이 아님, 버튼을 누른 채 움직인 mousemove
- 수정 키(shift·ctrl·alt·meta)가 켜진 이벤트, keydown `repeat: true`, 입력값이 `ab` 가 아님
- `page.keyboard.modifierMask()` 가 0 이 아님

## 결과

| 묶음 | 경우 | 같은 Page | 다른 Page |
|---|---|---|---|
| 기준 | 아무것도 안 끊음 | 없음 | 없음 |
| M1/M2 | click · dblclick · dragAndDrop 을 mousedown 의 alert·confirm·prompt 가 끊음 (9) | 없음 | 없음 |
| M1/M2 | press · keyboard.press `Shift+a` 를 keydown 의 alert·confirm·prompt 가 끊음 (6) | 없음 | 없음 |
| M1/M2 | keyboard.type `ab` 를 첫 keydown 의 alert·confirm·prompt 가 끊음 (3) | 다음 `a` keydown 에 `repeat: true`. 입력값은 `ab` | 없음 |
| M3 | click 을 mouseup 의 confirm 이 끊음 | 없음 | 없음 |
| M3 | beforeunload (속성·리스너, 링크 클릭·goto) | 대화상자가 뜨지 않고 이동함. 끊기지 않음 | 없음 |
| M3 | raw `mouse.down` 을 alert 가 끊음 | 셀렉터 클릭은 깨끗함. 다음 좌표 `mouse.click` 이 `mousemove buttons=1` 로 시작함 | 없음 |
| E | 위 raw 경우 뒤 `page.mouse.up()` | 다음 좌표 클릭 깨끗함 | — |
| E | 위 keyboard.type 경우 뒤 `page.keyboard.up('a')` | 페이지에 `keyup a` 가 가고, 다음 `a` 의 `repeat` 이 사라짐 | — |

18건 모두 대화상자가 실제로 동작을 끊었다(`trap` 이 비워지고 대화상자가 열려 있었음).
observed 동작(click, dblclick, dragAndDrop, press, keyboard.press)은 receipt 에 `dialog` 가 실렸고,
raw 동작(keyboard.type, mouse.down)은 `void` 였다.

## SDK 소스와 맞춰 본 것

`citrolabs/ego-lite@12407167f84a`:

- `driver/page-keyboard.ts` 115-145: `pressInSession` 은 실패해도 누른 키를 역순으로 뗀다. `#up` 은 디스패치 전에 상태를 지운다.
- 같은 파일 161-178(`type`), 180-231(`#down`·`#up`): `type` 은 글자마다 `#down` 뒤 `#up`. `#down` 이 끊기면 `#pressedCodes` 에 코드가 남아 다음 같은 키가 `autoRepeat` 가 된다. 그 키를 다시 누르고 떼면 지워진다. 실측으로도, keyboard.type·prompt 경우 바로 다음인 M3 mouseup 경우의 같은 Page 타이핑에는 `repeat` 이 없었다.
- `page-model.ts` 470-568: `PageMouse.down` 은 raw 라 대화상자 오류를 삼키고 `#buttons` 를 눌림으로 바꾼다. `mouse.click`·`move` 는 그 `#buttons` 를 싣는다. `mouse.up` 만 지운다.

## 잰 적 없는 것

- http(s) 페이지와 교차 출처 iframe 에서 여는 대화상자
- 사람이 직접 누르는 beforeunload 경로(실제 사용자 활성화)
- 0.6.2.5 이외 버전

## 누르기 전 거절 (`prepress/`)

click · dblclick · dragAndDrop 의 대상을 못 찾는 11가지(여러 개 일치, 없음, 숨김, 비활성, 가려짐, 오래된 ref, 출발지·도착지 없음)는
모두 `ElementResolutionError`(`kind` 있음)였고 페이지 이벤트는 0건이었다. `page.press` 도 같은 오류를 던진다.
