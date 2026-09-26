---
rfc: "tui-single-input-decoder"
title: "TUI 입력은 해석기 하나가 읽는다 — 덜 들어온 시퀀스를 세 곳이 나눠 들지 않게"
status: Draft
created: 2026-09-26
updated: 2026-09-26
author: claude
supersedes: []
superseded_by: null
related: []
implementation_prs: []
---

# RFC: TUI 입력은 해석기 하나가 읽는다 (tui-single-input-decoder)

## 0. Summary

TUI는 터미널에서 받은 바이트를 지금 세 곳에서 따로 해석한다. 시작 probe
(`bin/masc_tui_terminal_probe.ml`), 입력 읽기(`read_input`, `bin/masc_tui.ml`),
붙여넣기 해석기(`bin/masc_tui_paste.ml`)다. 셋 다 "아직 덜 들어온 시퀀스"를
제각각 들고 있다. 그래서 바이트를 서로 돌려주고, 서로에게 상태를 물어보는
이음매 코드가 계속 늘어난다.

이 RFC는 셋을 **순수 함수로 된 해석기 하나**로 합친다. 이 해석기는 바이트와
시간 경과를 입력으로 받아 닫힌 타입의 이벤트를 낸다. probe는 바이트를 앞에서
거르지 않고, 해석기가 낸 `Reply` 이벤트만 받아 쓴다.

## 1. 배경 — 지금 무엇이 어디에 붙잡혀 있나

### 1.1 미완성 상태를 들고 있는 곳

| 위치 | 상태 | 무엇을 기다리나 |
|---|---|---|
| probe `decoder.mode` + `pending` | `Escape`, `Paste_prefix n`, `Paste n`, `Osc_candidate`, `Osc_passthrough`, `Csi_private`, `Csi_window`, `Apc_prefix`, `Apc`, `Apc_passthrough` | 터미널 답의 끝, 붙여넣기 시작 표시의 나머지 |
| probe `replay` + `replay_position` | 답이 아니라고 판명된 바이트 | 입력 읽기가 가져가기 |
| `input_reader.csi_parameters` | CSI 인자 | 끝 바이트 |
| `input_reader.paste_phase` | `Pasting` / `Draining_tail` | `ESC [201~` |
| `input_reader.partial_scalar` | UTF-8 앞 바이트 | 뒤따르는 바이트 |
| `read_input` 안의 `timeout:0.05` 읽기 | `ESC` 다음 바이트, `ESC O`, `ESC _ G`, X10 마우스 3바이트, APC 본문 | 짧은 시간 안에 오는 다음 바이트 |

### 1.2 같은 시퀀스를 두 곳이 해석한다

- **붙여넣기 시작 `ESC [200~`**: probe는 `Paste_prefix`/`Paste`로 붙여넣기 안의
  "답처럼 생긴 바이트"를 지킨다. `read_input`은 `handle_csi "200" '~'`로
  붙여넣기를 시작한다. `Masc_tui_paste`는 끝 표시를 찾는다.
- **그래픽 답 `ESC _ G … ESC \`**: probe의 `Apc*` 상태와 `read_input`의
  `Graphics_reply` 분기가 둘 다 읽는다.
- **`ESC [6…`**: probe의 `Csi_window`는 셀 크기 답일 수도, PageDown일 수도 있어서
  끝 바이트까지 붙잡은 뒤 키로 판명되면 replay로 돌려준다.

### 1.3 이음매 코드

`bin/masc_tui.ml`에서 `has_replay`, `return_replay`, `unread_replay`,
`holds_incomplete_sequence`, `last_source`를 부르는 곳이 19곳이다(2026-09-26
`origin/main` 기준, `rg -c`). 대표적인 예는 다음과 같다.

- `take_input_byte`는 probe가 끝났는지, replay가 남았는지에 따라 세 갈래로 나뉜다.
- `return_input_byte`는 바이트가 어느 출처에서 왔는지(`Probe_replay` /
  `Terminal_buffer`) 기억했다가 그쪽으로 되돌린다.
- `input_holds_incomplete_sequence`는 `csi_parameters`와 probe 상태를 함께 본다.
  주석에 따르면, 예전에는 `csi_parameters`만 봐서 안내가 뜨지 않았고 Ctrl-C가
  종료 확인 창으로 넘어갔다.

### 1.4 이 구조가 만든 결과

- #38767을 고치던 중, 붙잡힌 `ESC [200`을 "누가 들고 있어야 하나"를 두고 두
  설계가 나왔다. 하나는 probe에 물어보는 방식(병합됨)이고, 다른 하나는 입력
  읽기로 넘기는 방식(버림)이다. 넘기는 방식은 probe의 `Paste_prefix`와 입력
  읽기의 `csi_parameters`가 같은 바이트를 동시에 들게 만든다.
- probe는 그래픽 답을 받아야만 끝난다. 그래픽 답을 주지 않는 터미널에서는
  세션 내내 모든 바이트 앞에 probe가 서 있다(§1.3 주석). 테마 변경 알림
  (DECSET 2031)도 세션 중간에 오므로, probe는 사실상 "시작 때만" 쓰이는 부품이
  아니다.

## 2. 설계

### 2.1 해석기 하나, 순수 함수

```ocaml
(* bin/masc_tui_input_decoder.ml *)
type reply =
  | Palette_color of palette_slot * rgb        (* OSC 4 / 10 / 11 *)
  | Theme_mode of theme_mode                   (* DECSET 996 답, 2031 알림 *)
  | Cell_pixels of int * int                   (* CSI 6 ; h ; w t *)
  | Graphics of string                         (* APC G 본문 *)

type event =
  | Key of string
  | Paste of paste                             (* 200~ … 201~ 전체. text, dropped *)
  | Mouse of mouse
  | Reply of reply

type t   (* 미완성 상태는 전부 여기. 밖에서 볼 수 없다. *)

val create : unit -> t
val feed : t -> char -> t * event list
val idle : t -> elapsed:Mtime.Span.t -> t * event list
  (* 시간이 지났다는 사실도 입력이다. ESC 단독 키, 끊긴 UTF-8,
     멈춘 붙여넣기 복구가 여기서 결정된다. *)
val pending : t -> pending option
  (* 안내 문구와 Ctrl-C 취소가 보는 유일한 상태 *)
val cancel_pending : t -> t * event list
```

- 입출력이 없다. `Unix.read`와 시계는 호출하는 쪽이 들고 있다.
- 지금 `read_input` 안에 흩어진 `timeout:0.05` 읽기는 `idle ~elapsed`로
  바뀐다. 그러면 시간에 의존하던 판단을 단위 테스트로 결정적으로 재현할 수 있다.
- `pending`은 닫힌 합타입이다(`Escape`, `Csi of string`, `Utf8 of string`,
  `Paste_marker of int`, `Pasting`, `Reply_body of reply_kind`, …).
  `_ ->` 없이 모든 경우를 처리한다.

### 2.2 붙여넣기 안의 "답처럼 생긴 바이트"

해석기 상태가 `Pasting`이면 `ESC [201~`를 뺀 모든 바이트는 붙여넣기 본문이다.
probe가 따로 지킬 필요가 없다. 지금 probe의 `Paste_prefix`/`Paste` 상태는 이
역할만 하므로 사라진다.

### 2.3 모호한 접두어

`ESC [6`처럼 키와 답이 같은 머리로 시작하는 경우에는 해석기가 끝 바이트까지
기다린다. 끝 바이트가 `t`면 `Reply (Cell_pixels …)`, `~`면 `Key "pagedown"`을
낸다. 되돌려 주기(replay)가 필요 없다.

### 2.4 probe가 하는 일

probe는 시작할 때 질의를 쓰고, 정해진 시간 동안 `Reply` 이벤트를 모은다.
이때 함께 나온 `Key`/`Paste` 이벤트는 순서대로 쌓아 두었다가 메인 루프에 넘긴다.
그 뒤에 오는 `Reply`(늦은 팔레트, 테마 알림)는 메인 루프가 같은 경로로 받는다.
그러면 "probe가 끝났는가"라는 상태가 필요 없다.

### 2.5 바이트 해석은 이 모듈에만 있다 (SSOT)

터미널 바이트를 읽어 의미를 정하는 일은 `Masc_tui_input_decoder` 한 곳에서만 한다.

- `Masc_tui_paste`는 이 모듈 안으로 흡수한다. 끝 표시 찾기, 본문 누적,
  `max_bytes`/`dropped` 계산이 모두 해석기 상태 `Pasting` 안에 들어간다.
  모듈 파일은 지운다.
- X10 마우스(`ESC [M` + 3바이트)도 해석기 상태 하나로 둔다. CSI 끝 바이트
  규칙을 따르지 않는 유일한 형식이므로, `Csi` 상태에서 인자 없이 `M`이 오면(SGR의 `<…M`과 구별)
  `X10_mouse of int`(남은 바이트 수)로 넘어간다. 지원은 끊지 않는다.
- `Masc_tui_csi.name`과 `Masc.Tui_decode`의 SGR 좌표 함수는 상태가 없는
  표·순수 함수다. 해석기만 이 함수들을 부르고, 다른 모듈은 부르지 않는다.
  2단계에서 `bin/masc_tui.ml`이 이들을 직접 부르는 곳을 모두 없앤다.
- 1·2·3단계가 끝나면 `rg 'Masc_tui_csi\.|Tui_decode\.(sgr|x10)' bin lib`의
  결과가 해석기 파일 하나만 나와야 한다. 이 검사를 3단계 PR의 완료 조건으로 둔다.

## 3. 옮기는 순서

| 단계 | PR 내용 | 연결 여부 | 검증 |
|---|---|---|---|
| 1 | `Masc_tui_input_decoder`와 단위 테스트. 지금 `test_tui_terminal_probe.ml`과 붙여넣기 테스트의 입력 사례를 모두 옮겨 같은 결과인지 비교한다. | 연결 안 함 | 단위 테스트 |
| 2 | `read_input`이 새 해석기를 쓴다. `csi_parameters`, `partial_scalar`, `paste_phase`, 안쪽 `timeout:0.05` 읽기, `bin/masc_tui_paste.ml`을 지운다. probe는 그대로 앞에 둔다. | 입력 경로 | PTY 키보드·붙여넣기 시나리오 |
| 3 | probe를 `Reply` 소비자로 바꾼다. `replay`, `return_replay`, `last_source`, `holds_incomplete_sequence`, `Masc_tui_terminal_probe.next`를 지운다. | 시작 경로 | PTY 시작·팔레트·그래픽 시나리오 |

단계마다 main이 동작하는 상태를 유지한다. 옛 경로와 새 경로를 나란히 두는
기능 플래그는 만들지 않는다. 2단계와 3단계는 각각 한 번에 바꾼다.

## 4. 트레이드오프

- **장점**
  - 미완성 상태가 한 곳에 있다. 안내와 Ctrl-C 취소가 보는 값이 하나다.
  - 시간 판단이 입력이 되므로, 지금 PTY로만 재현하던 "잠깐 멈춘 붙여넣기",
    "끊긴 한글" 같은 경우를 단위 테스트로 검사할 수 있다.
  - 새 터미널 답을 추가할 때 `reply`에 경우를 하나 더하면, 컴파일러가 처리하지
    않은 곳을 알려 준다.
- **단점과 위험**
  - probe에는 터미널별 예외 처리가 쌓여 있다(`Csi_private`가 붙여넣기 판정 뒤에만
    오는 순서, OSC 종료 문자 BEL/ST 두 가지, 최대 길이 제한). 빠짐없이 옮기지
    않으면 회귀가 생긴다. 1단계에서 기존 테스트 입력을 전부 옮기는 이유다.
  - 2단계는 `bin/masc_tui.ml`의 입력 경로 수백 줄을 한 번에 바꾼다. PTY
    시나리오 여러 개가 함께 깨질 수 있다.
  - 지금 사용자 눈에 보이는 버그는 없다. 이 작업은 앞으로 생길 이중 처리
    버그를 막는 구조 정리다.

## 5. 하지 않는 것

- 키 이름 표(`Masc_tui_csi.name`)와 마우스 좌표 해석(`Masc.Tui_decode`)의
  내용은 바꾸지 않는다. 부르는 곳만 해석기 하나로 모은다(§2.5).
- 붙여넣기 크기 제한과 복구 정책(`paste_quiet_seconds`)의 값은 바꾸지 않는다.
  위치만 `idle`로 옮긴다.
- 터미널에 보내는 질의 문자열은 바꾸지 않는다.

## 6. 결정

1. `Masc_tui_paste`는 해석기 안으로 흡수한다. 붙여넣기 상태를 두 모듈이 나눠
   들면 이 RFC가 없애려는 구조가 그대로 남는다. (2026-09-26 운영자)
2. X10 마우스는 해석기 상태로 두고 지원을 유지한다. 같은 원칙(바이트 해석은
   한 곳)을 따른다.
