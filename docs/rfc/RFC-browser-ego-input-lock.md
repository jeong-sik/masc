---
rfc: "browser-ego-input-lock"
title: "Ego 입력 잠금을 남길지"
status: Draft
created: 2026-11-04
author: vincent + claude
related: ["browser-live-ego", "browser-ego-goal-spaces"]
---

# RFC — Ego 입력 잠금을 남길지

## 1. 문제

2026-11-03 18:45:18 KST 에 `kidsnote-slack-reader` 가 Space #3 탭 2 에서
`text="dev-frontend"` 를 클릭했다. 일치하는 요소가 8개라 SDK 가 53ms 만에 거절했다.
아무것도 누르지 않았는데 Space #3 의 입력은 `release_uncertain` 으로 잠겼다.

잠금은 2026-11-04 10:50:32 KST 운영자 확인까지 약 16시간 이어졌다.
그동안 같은 Space 를 쓰는 Keeper 넷(`kidsnote-slack-reader`, `kidsnote-incoming-dd-manager`,
`wkbl-data`, `wkbl-web-leader`)이 클릭·입력을 못 했다.
서버 로그의 입력 거절은 11-01 4건, 11-02 6건, 11-03 42건, 11-04 2건이다.
Keeper 들은 거절을 몇 번 받은 뒤 시도를 멈췄으니 실제로 막힌 일은 이보다 많다.
Space #1 에도 11-03 17:15 에 마지막으로 기록된 잠금이 남아 있다(잠근 시각은 기록되지 않았다).

거절된 클릭이 잠그는 문제는 이 RFC 와 별개로 고친다(스택 PR, `Refused_before_press`).
이 RFC 는 그다음 질문을 다룬다. 잠금 자체가 필요한가.

## 2. 지금 잠금이 하는 일

- 누르기와 떼기가 갈라질 수 있는 입력(click, dblclick, dragAndDrop, press,
  keyboard.type 등)을 시작하기 전에 `Pending` 을 디스크에 쓴다
  (`lib/browser_ego_input.ml` `begin_holding`).
- SDK 가 떼기를 선언한 답(대화상자 없는 receipt, 검증된 native window)이 오면 푼다.
  그 밖의 답은 모두 잠금을 남긴다.
- 잠기면 그 Space 의 모든 탭, 모든 Keeper 의 입력을 효과 전에 거절한다(`admit`).
  읽기는 된다.
- 시간이 지나도 풀리지 않는다. 서버를 다시 시작해도 남는다(`lane-addons/ego-input/<space>.json`).
- 푸는 길은 둘이다. 운영자의 `assert_input_reset`, Space 를 가진 Keeper 의 `release_input`.
  둘 다 "확인했다"는 주장을 기록할 뿐 키가 실제로 올라갔다는 증거는 아니다.

막으려는 것은 하나다. 끊긴 입력이 키나 버튼을 누른 채로 남겨,
다음 입력이 그 상태를 물려받는 것(Shift 가 눌린 채 글자 입력, 버튼이 눌린 채 클릭이 드래그가 됨).

## 3. 지금까지 잰 것

| 날짜 | 버전 | 조건 | 결과 |
|---|---|---|---|
| 10-27 | ego lite 0.6.1.11, Chromium 156 | `confirm()` 이 click·type·Control+a 를 끊음 | 끊긴 쪽은 mouseup·keyup 이 안 옴. 다음 클릭은 `buttons: 0`, ctrl 없음, `modifierMask()` 0. 같은 키를 다시 누를 때만 `repeat: true` |
| 10-27 | 같음 | 보통 타이핑 30회(Shift 문자 포함) | keydown 201 = keyup 201, 남은 키 없음 |
| 11-04 | ego-browser 0.6.2.5, Chromium 156 | 대상 못 찾음 11가지(클릭·더블클릭·드래그) | 모두 `ElementResolutionError`, 페이지 이벤트 0건, 다음 클릭 정상 |
| 11-04 | 같음 | M1~M3 (6절) | keyboard.type 이 끊긴 Page 에서만 다음 같은 키에 `repeat: true`. 그 밖에는 남은 것 없음 |

기록과 스크립트: `docs/evidence/2026-11-04-ego-input-residue/`.

잰 적 없는 것:

- http(s) 페이지와 교차 출처 iframe 에서 여는 대화상자
- 실제 사용자 활성화가 있는 beforeunload (스크립트 입력으로는 대화상자가 뜨지 않았다)
- 0.6.2.5 이외 버전

## 4. 비용과 이득

| | 잠금이 있을 때 | 잠금이 없을 때 |
|---|---|---|
| 남은 키가 다음 입력에 섞임 | 막지 못한다. 잠금도 리셋도 keyup·mouseup 을 보내지 않아, 풀린 뒤에도 같은 `repeat` 이 남는다 | keyboard.type 이 끊긴 Page 에서 그 키를 다음에 한 번 누를 때 `repeat: true`. 그 키를 누르고 떼면 사라진다 |
| 한 Keeper 의 실패가 다른 Keeper 를 멈춤 | 생긴다(Space 전체) | 없다 |
| 사람이 개입해야 풀림 | 대부분 그렇다(16시간 사례) | 없다 |
| 기록·코드 | `Pending` 저장소, 두 해제 경로, 해제 보고서, 거절 문장 | 관측값(`inputReadiness`)만 남김 |

운영 원칙(`~/me/instructions/projects.md`)은 두 가지를 적는다.
`Interrupted`·`Ambiguous` 같은 과거 증거를 scheduling Gate 로 쓰지 않는다.
기존 Gate 가 없어도 실제 상태가 유지되고 이득이 압도적으로 분명하지 않으면 지운다.
입력 잠금을 scheduling Gate 로 볼지는 해석이 갈릴 수 있다.
다만 "지난 입력의 해제를 모른다"는 과거 증거로 다음 입력을 막는다는 점은 같다.
남길 근거는 "없으면 실제 상태가 망가진다"는 것뿐인데, 잰 범위에서는 그 일이 없었다.

## 5. 선택지

**A. 그대로 둔다.** 위 표의 비용이 그대로 남는다.
`Refused_before_press` 와 `release_input` 이 일부를 줄인다.

**B. Page 하나로 좁힌다.** 잠금은 남기되, 끊긴 입력이 있던 Page 의 입력만 거절한다.
다른 Keeper·다른 탭은 멈추지 않는다. 키 상태가 Page 마다 따로인지 먼저 재야 한다(M2).

**C. Gate 를 없애고 관측값으로만 보여 준다.** 입력은 받아들인다.
답에는 `inputReadiness: release_uncertain` 과 어떤 입력이 언제 끊겼는지 실어,
Keeper 가 보고 판단한다. 함께 지울 것: `Pending` 저장소(`lane-addons/ego-input/`),
`assert_input_reset`, `release_input`, `inputLock`(#48042)·`releasePath`. 지금 있는 저장소 파일은 지우고 설치한다.

**D. SDK 의 해제 확인 신호를 기다린다**(MASC task-2742). SDK 에 그런 API 는 아직 없다.
생기기 전까지는 A 와 같다.

**E. 남은 것을 SDK 공개 호출로 뗀다.** `page.keyboard.up(key)` 는 `#pressedCodes` 에서 키를 지우고
페이지에 keyup 을 보낸다. `page.mouse.up()` 은 `PageMouse.#buttons` 를 지우고 mouseReleased 를 보낸다.
실측에서 둘 다 남은 것을 없앴다. 다만 keyboard.type 이 어느 글자에서 끊겼는지 masc 는 모르므로,
타이핑한 글자마다 keyup 을 보내면 누르지 않은 키의 keyup 이 페이지에 간다.
raw `mouse.down` 은 masc 가 지금 쓰지 않는다(좌표 드래그는 거절된다).

## 6. 잰 것 (2026-11-04, ego-browser 0.6.2.5)

각 조건 뒤에 같은 Page 와 같은 Space 의 다른 Page 에서 클릭 한 번, `ab` 타이핑 한 번을 하고
페이지가 받은 `buttons`, 수정 키, `repeat`, 입력값, `modifierMask()` 를 봤다.

| | 조건 | 같은 Page | 다른 Page |
|---|---|---|---|
| M1/M2 | click · dblclick · dragAndDrop 을 mousedown 의 alert·confirm·prompt 가 끊음 (9) | 없음 | 없음 |
| M1/M2 | press · keyboard.press `Shift+a` 를 keydown 의 alert·confirm·prompt 가 끊음 (6) | 없음 | 없음 |
| M1/M2 | keyboard.type 을 첫 keydown 의 alert·confirm·prompt 가 끊음 (3) | 다음 같은 키에 `repeat: true`, 입력값 정상 | 없음 |
| M3 | click 을 mouseup 의 confirm 이 끊음 | 없음 | 없음 |
| M3 | beforeunload (속성·리스너, 링크 클릭·goto) | 대화상자 없이 이동, 끊기지 않음 | 없음 |
| M3 | raw `mouse.down` 을 alert 가 끊음 | 셀렉터 클릭은 깨끗, 좌표 클릭은 버튼 누른 채 이동으로 시작 | 없음 |

SDK 소스(`citrolabs/ego-lite@12407167f84a`)와도 맞는다. `pressInSession` 은 실패해도 키를 역순으로 떼고,
`#up` 은 디스패치 전에 상태를 지운다. `type` 은 `#down` 이 끊기면 `#up` 을 못 해 `#pressedCodes` 에 남는다.
키보드·마우스 상태는 Page 마다 따로다.

## 7. 제안

측정 전에 적은 규칙은 "남은 상태가 Page 안에서만 보이면 B" 였다. 결과는 그 경우에 해당한다.
그런데 B 가 기대던 전제, 즉 잠금이 남은 상태를 막아 준다는 것이 성립하지 않았다.

- 남은 것은 keyboard.type 이 끊긴 Page 의 `repeat` 표시 하나다. 입력값은 맞고, 그 키를 한 번 누르고 떼면 사라진다.
- 잠금은 그 표시를 지우지 못한다. 리셋 뒤에도 같은 표시가 남는다. 잠금이 하는 일은 그동안 입력을 멈추는 것뿐이다.
- 그러니 B 는 보호 없이 Page 하나를 멈추고, A 는 Space 전체를 멈춘다.

그래서 C 를 제안한다. Gate 와 `Pending` 저장소, 두 해제 경로를 지우고,
끊긴 입력은 답의 관측값으로만 보여 준다. E 는 지금 필요 없다.
masc 가 raw `mouse.down` 을 쓰게 되면 그때 끊긴 경우의 `mouse.up` 을 함께 둔다.

결정은 운영자가 한다.

## 8. 범위 밖

- 거절된 클릭이 잠그는 문제와, 실패 응답에 잠금 상태를 싣는 일(별도 스택 PR)
- Keeper 지침 문장 추가
