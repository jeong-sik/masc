---
title: "기계 조작은 한 계층이다 — 입력·시간·수명을 모든 기계가 같은 모양으로 받는다"
status: Draft
created: 2026-09-24
updated: 2026-09-24
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0439", "machine-spectating-goes-through-lanes", "lane-addon-v0"]
implementation_prs: []
---

# RFC — 기계 조작은 한 계층이다

## 1. 원칙

DOS, MSX, Mac·Linux VM, Browser, 다음 기계, 어떤 조이스틱이든 조작은 같은 계층을 거친다.
기계마다 다른 것은 **어떤 장치를 가졌는가**이지, 조작의 모양이 아니다.

조작은 세 층이다.

| 층 | 무엇 | 공통인가 |
|---|---|---|
| 입력 | Button·Abs·Rel 이벤트 | 모든 기계. 장치 선언만 다르다 |
| 시간 | 진행, "입력을 기다릴 때까지 진행" | 턴제 기계만. 실시간 기계는 시간을 쥐지 않는다 |
| 수명 | 전원·리셋, 미디어 넣기·빼기, 저장·복원 | 모든 기계. 지원 범위만 다르다 |

"URL 로 이동", "이 요소 클릭", 패키지 Act 같은 **의미 동작**은 Lane 마다 다르다. 공통 층에
넣지 않는다.

## 2. 표준 (2026-09-24 확인)

입력을 세 종류로 나누는 것은 새로 만든 모양이 아니다.

| 표준 | 모양 | 출처 |
|---|---|---|
| Linux evdev | `EV_KEY`(키·버튼, 값 1=누름·0=뗌·2=자동 반복), `EV_REL`, `EV_ABS` | https://www.kernel.org/doc/html/latest/input/event-codes.html |
| QEMU QAPI | `InputEventKind` = `key`·`btn`·`rel`·`abs`·`mtt`(멀티터치), `input-send-event` | https://raw.githubusercontent.com/qemu/qemu/master/qapi/ui.json |
| QEMU 수명 | `system_reset`, `blockdev-change-medium`·`eject`, `snapshot-save`·`snapshot-load` | qemu-qmp-ref, `qapi/block.json`, `qapi/migration.json` |
| USB HID Usage Tables | Generic Desktop 0x01(X 0x30·Y 0x31·Z 0x32·Hat 0x39), Keyboard/Keypad 0x07, Button 0x09 | https://usb.org/document-library/hid-usage-tables-16 (페이지 표기 Version 1.7). 페이지 번호는 Linux `include/linux/hid.h` 로 교차 확인했고, HUT 원문 표는 확인 못함 |
| VNC RFB | KeyEvent(down-flag, keysym), PointerEvent(button-mask, x, y) | https://datatracker.ietf.org/doc/html/rfc6143 |
| Chrome DevTools | `dispatchKeyEvent`(keyDown·keyUp·rawKeyDown·char), `dispatchMouseEvent`(mousePressed·mouseReleased·mouseMoved·mouseWheel) | https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/domains/Input.pdl |
| WebDriver BiDi | `input.performActions`(key·pointer·wheel source), `input.releaseActions` | masc Browser lane 이 쓰는 경로 |

## 3. 지금 모양 (origin/main 과 #38438)

### 3.1 입력

| 기계 | 입력 함수 | 기록 | 누름·뗌 |
|---|---|---|---|
| MSX | `press ~who ~keys ~hold_frames ~step_frames ~sequence` (`msx_lane.mli:171-192`) | `{at_frame; who; key_name; down}` (`:67`) | 있다 |
| DOS | `press ~keys ~steps` (`dos_lane.mli:228`), `type_text` (`:254`), `click ~x ~y ~buttons ~steps` (`:239`) | `{at_step; who; key_name}` (`:72`). 마우스는 `key_name = "mouse(x,y,b)"` 문자열 (`dos_lane.ml:654`) | 없다 |
| Browser | 좌표: BiDi `input.performActions` (`browser_bidi_peer.ml:80-96`). 셀렉터: `script.callFunction`. 키: WebDriver `/element/{id}/value` (`browser_webdriver.ml:155-157`) | — | 경로마다 다르다 |

- MSX 키는 닫힌 variant 다(`ocaml-msx msx.mli:10-26`). 조이스틱 1 은 방향키·`Trigger_a/b` 와
  같은 키로 들어가고(`msx.mli:113-118`), 조이스틱 2 는 비어 있다(`msx.ml:361-364`).
  키보드와 조이스틱을 가르는 타입이 없다.
- DOS 코어는 BIOS 키 링만 쓴다. `Dos_state.push_key` 가 make 코드를 포트 0x60 에 넣지만
  break 코드는 없고(`dos_ports.ml:146`), IRQ 는 IRQ0 만 전달한다(`dos_machine.ml:180-188`).
  typematic 반복이 없다. 게임포트 0x201 은 늘 0 이다(`dos_ports.ml:157`).
- DOS 마우스는 `set_mouse` 로 움직이지만 `attach_mouse` 를 부르지 않는다. 게스트는 마우스가
  없다고 안다(#38709).

### 3.2 시간

| 기계 | 단위 | 진행 | 멈추는 조건 |
|---|---|---|---|
| MSX | frame | `step ~frames`, `step_until_change`, `step_frame`(tick) | `{changed; stable}` |
| DOS | 8086 명령 | `step ~steps ~until_ready` | ready: 키를 물었는데 비었고 화면이 멈춤 (`dos_lane.mli:98-118`) |
| Browser | 실제 시간 | 없다 | — |

### 3.3 수명

| | MSX | DOS | Browser |
|---|---|---|---|
| 미디어 | load(카트리지·디스크), eject, change_disk | load, eject | Open_tab, Close_tab |
| 저장·복원 | save, restore | 없다 (게스트가 쓴 파일만) | — |
| 리셋 | load 가 대신한다 | load 가 대신한다 | Reload |
| 제어권 | — | pass (`tool_misc_dos_lane.ml:428`) | — |

### 3.4 사람의 조작은 알림을 내지 않는다

- `notify_activity` 를 부르는 곳은 `keeper_event_bridge.ml:715` 하나다. 도구가 끝났다는
  이벤트만 `Msx_changed` 같은 활동으로 바꾼다.
- `/api/v1/msx/press`·`tick`·`load`·`restore`·`disk` 는 `Msx_lane` 을 바로 부른다. 그래서
  사람이 TUI 에서 넣은 조작은 Lane 인스턴스를 깨우지 않는다.

## 4. 결정

### 4.1 입력 이벤트는 한 타입이다

```ocaml
type edge = Down | Up
type input =
  | Button of { device : device_id; control : control; edge : edge }
  | Abs of { device : device_id; axis : axis; value : int }
  | Rel of { device : device_id; axis : axis; delta : int }
```

- `control`·`axis` 이름은 HID Usage 를 따른다. 기계가 만든 이름을 쓰지 않는다.
- 자동 반복(evdev 값 2)은 이벤트가 아니다. 누르고 있는 동안 반복할지는 기계 adapter 가
  정한다(PC 키보드의 typematic 처럼).
- 멀티터치(QEMU `mtt`)는 지금 기계 중에 받는 게 없다. 받는 기계가 생길 때 더한다.

### 4.2 기계는 장치를 선언한다

- adapter 는 자기 장치 목록을 선언한다. 장치마다 종류(키보드·조이스틱·마우스·패드)와 받는
  control·axis, Abs 의 범위가 있다.
- 선언 밖의 입력은 오류다. 비슷한 것으로 몰래 바꾸지 않는다.
  - MSX 조이스틱은 디지털이다. Abs 가 오면 거절한다.
  - 마우스가 없는 DOS 에 Pointer 가 오면 거절한다(#38709 의 조용한 성공을 없앤다).
- 장치 선언은 load 때 정해진다. 같은 DOS 코어라도 프로그램에 따라 마우스가 있고 없다.

| 기계 | 선언 예 |
|---|---|
| MSX | 키보드 행렬, 조이스틱 포트 1·2 (방향 4 + 트리거 2, 모두 Button) |
| DOS | PC 키보드, 마우스(선언 시에만), 게임포트 조이스틱(Abs 2 + Button 2, 코어가 붙인 뒤) |
| Mac·Linux VM | HID 키보드·마우스·게임패드 (QEMU `input-send-event` 로 전달) |
| Browser | 키보드, 포인터, 휠 (BiDi `input.performActions` 로 전달) |

### 4.3 바인딩이 사람 장치를 기계 장치로 옮긴다

- 내 게임패드 아날로그 스틱 → MSX 디지털 방향처럼 값을 잃는 변환은 바인딩에 선언한다.
  "X 가 범위의 N% 를 넘으면 Right Down" 같은 문턱이 바인딩에 적혀 있다.
- adapter 는 변환하지 않는다. adapter 는 자기 선언과 맞는 이벤트만 받는다.
- 바인딩이 없으면 사람 장치와 기계 장치가 같은 control 이름일 때만 그대로 간다.

### 4.4 시간 층

- 턴제 기계는 `Advance of { budget : machine_time; until : stop }` 를 받는다.
  `stop` 은 기계가 선언한 멈춤 조건이다(MSX `Changed`·`Stable`, DOS `Ready`).
- 입력 이벤트에는 기계 시간이 붙는다. 턴제 기계는 그 시간에 적용하고, 실시간 기계는 도착한
  순간에 적용한다.
- 누르고 있기 = `Down`, `Advance`, `Up` 이다. MSX 의 `hold_frames` 는 이 조합의 이름이다.

### 4.5 수명 층

- `Reset`, `Insert_media`, `Eject_media`, `Save`, `Restore` 를 둔다. 기계는 지원하는 것만
  선언한다. DOS 는 지금 `Save`·`Restore` 를 선언하지 않는다.
- 제어권(DOS `pass`)은 조작이 아니라 누가 조작하는가의 문제다. 공통 층에 넣지 않고 기록의
  `who` 로 남긴다.

### 4.6 모든 조작은 한 길로 들어가 한 번 기록되고 알림을 낸다

- 사람(TUI)과 Keeper(도구) 모두 같은 조작 계층으로 들어간다.
- 계층은 기록 한 줄 `(at, who, 조작)` 을 남기고, 끝나면 Lane 활동을 낸다. 사람의 조작도
  `Msx_changed`·`Dos_changed` 를 낸다. 그러면 관전 RFC 의 `/api/v1/msx/frame` 을 지울 수 있다.
- DOS 기록의 `"mouse(x,y,b)"` 문자열은 `Button`·`Abs` 이벤트로 바뀐다.

### 4.7 Keeper 도구는 묶음을 받는다

- Keeper 에게 누름·뗌만 주면 턴과 토큰이 는다. 도구는 지금처럼 탭·글자 치기·누르고 있기를
  받고, 계층이 공통 이벤트로 푼다.
- 묶음은 보내는 쪽 편의 기능이다. 기계 쪽 계약은 §4.1 하나다.

## 5. 바꾸지 않는 것

| 그대로 | 왜 |
|---|---|
| 기계는 서버에 산다 (RFC-0439) | 조작의 길만 바꾼다 |
| 의미 동작 (Browser 셀렉터, 패키지 Act) | Lane 마다 다르다 |
| 턴제 기계의 결정론 | 같은 프로그램과 같은 기록이 같은 실행을 낸다. 공통 기록도 이것을 지킨다 |
| 관측과 관전 | 관전 RFC 가 다룬다 |

## 6. 대안

- **기계마다 조작 API.** 지금 모양이다. 사람 경로가 알림을 빠뜨리는 문제가 기계마다 되풀이된다.
- **탭·누르고 있기를 기본 이벤트로 둔다.** 누르고 있는 중에 다른 키를 누르는 조합(chord)과
  아날로그 축을 표현하지 못한다.
- **VNC RFB 를 그대로 쓴다.** 키보드와 포인터뿐이다. 조이스틱·아날로그 축이 없다.
- **adapter 가 비슷한 입력으로 바꿔 준다(아날로그 → 디지털).** 문턱이 코드에 숨는다.
  같은 기계를 다른 사람이 다른 문턱으로 쓰지 못한다.

## 7. 열린 항목

1. **MSX 실시간 진행.** `/api/v1/msx/tick` 을 `Advance` 를 자주 보내는 것으로 할지, 서버
   ticker 로 둘지. 잦은 `Advance` 는 기록과 알림이 많아진다.
2. **DOS 코어.** break 코드, IRQ1/INT 9, typematic, 게임포트 조이스틱은 ocaml-dos 에 없다.
   그 전까지 DOS 키보드 선언은 "Down 만 기계에 전달"이라고 적고, `Up` 은 기록만 한다.
3. **MSX 조이스틱 2.** 코어가 비워 뒀다. 선언하지 않는다.
4. **VM 기계.** Mac·Linux VM 은 아직 masc 에 없다. QEMU 경로는 모양만 확인했다.
5. **HID 이름을 그대로 쓸지.** `KEY_A` 같은 evdev 이름이 읽기 쉽고, HID usage 번호는 모호함이
   없다. 둘 중 하나를 정한다.

## 8. 단계

| 단계 | 내용 | 끝났다는 증거 |
|---|---|---|
| 1 | 조작 타입(§4.1·§4.4·§4.5)과 장치 선언 타입 | 단위: 선언 밖 입력 거절, 모르는 control 거절 |
| 2 | MSX adapter + 사람 경로 이전. `/api/v1/msx/press`·`tick` 이 계층을 거친다 | TUI 에서 키를 누르면 `Msx_changed` 가 한 번 난다. 같은 기록으로 다시 돌리면 같은 frame |
| 3 | DOS adapter. 마우스는 load 선언으로 붙인다(#38709) | 마우스 선언 없는 click 은 오류, 선언하면 INT 33h 함수 0 이 `0xFFFF` |
| 4 | Keeper 도구가 계층을 거친다 | 도구 스키마 바이트 테스트가 줄거나 같다 |
| 5 | Browser 좌표 입력을 계층으로 옮긴다 | BiDi 요청 모양이 그대로다 |

## 9. 검증

- 단위: 이벤트 파싱, 장치 선언과 거절, 기록 인코딩.
- 결정론: MSX 기록 하나로 두 번 돌려 frame 이 같다.
- PTY: 사람의 키 입력 → 기록 한 줄 → Lane 알림 → 관전 화면 갱신.
- 라이브: 사람과 Keeper 가 번갈아 조작한 한 판의 기록에서 `who` 가 둘 다 나온다.
