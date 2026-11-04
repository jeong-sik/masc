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

잰 적 없는 것:

- `alert`, `prompt`, `beforeunload`, mouseup 에서 여는 대화상자
- 한 Page 에서 끊긴 입력이 같은 Space 의 다른 Page 입력에 주는 영향
- 0.6.2.5 에서 대화상자로 끊긴 입력(10-27 은 0.6.1.11)
- 좌표 드래그(`mouse.down/move/up`)가 끊긴 경우

## 4. 비용과 이득

| | 잠금이 있을 때 | 잠금이 없을 때 |
|---|---|---|
| 남은 키가 다음 입력에 섞임 | 막는다 | 잰 범위에서는 일어나지 않았다. 안 잰 경우는 모른다 |
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
`assert_input_reset`, `release_input`, `releasePath`. 지금 있는 저장소 파일은 지우고 설치한다.

**D. SDK 의 해제 확인 신호를 기다린다**(MASC task-2742). SDK 에 그런 API 는 아직 없다.
생기기 전까지는 A 와 같다.

## 6. 결정 전에 잴 것

설치된 버전(지금 0.6.2.5)에서, 각 조건 뒤에 같은 Page 와 다른 Page 에서 클릭·타이핑을 한 번씩 하고
페이지가 받은 `buttons`, 수정 키, `repeat` 를 기록한다.

- M1. `alert`·`confirm`·`prompt` 가 mousedown·keydown 에서 click·dblclick·dragAndDrop·press·keyboard.type 을 끊음
- M2. M1 직후 같은 Space 의 다른 Page 입력
- M3. `beforeunload`, mouseup 에서 여는 대화상자, 좌표 드래그 중단

## 7. 제안

M1~M3 에서 남은 키·버튼이 없으면 C 로 간다.
남은 상태가 Page 안에서만 보이면 B 로 간다.
다른 Page 까지 번지면 A 를 유지하고 D 를 기다린다.

결정은 운영자가 한다.

## 8. 범위 밖

- 거절된 클릭이 잠그는 문제와, 실패 응답에 잠금 상태를 싣는 일(별도 스택 PR)
- Keeper 지침 문장 추가
