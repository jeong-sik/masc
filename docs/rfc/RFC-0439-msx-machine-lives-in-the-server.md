---
rfc: "0439"
title: MSX 머신은 서버에 산다 — 사람과 keeper 가 같은 기계에 키를 넣는 길
status: Draft
created: 2026-09-07
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0414"]
---

## 0. 한 줄 요약

지금 MSX 머신은 TUI 프로세스 안에 산다. keeper 는 서버 도구로만 세상을 만지므로 그 머신에
손이 닿지 않는다. 머신을 **서버로 옮기고**, TUI 는 프레임을 받아 그리는 구경꾼이 되고,
keeper 는 `masc_msx_*` 도구로 **같은 기계에 키를 넣는다**. 누가 눌렀는지는 서버가 세고,
모든 입력을 프레임 번호와 함께 기록하고, §3.6의 실행 조건을 고정한 하네스 재생을 목표로 한다.

## 1. 지금 서 있는 곳

오늘(2026-09-07) 코어 `ocaml-msx` main `50002bc` 에서 XSpelunker(카트리지, SCREEN 2)가
부트 로고 → "BRAIN GAMES PRESENTS" → 타이틀 → LEVEL 1-1 → 게임플레이까지 간다.
부트 하네스 `boot.exe --cart … --tap-space 340,420` 로 재현되고, 프레임 덤프를 눈으로 확인했다.

코어가 이미 내주는 것(`lib/msx.mli`):

| 함수 | 뜻 |
|---|---|
| `create` / `load_cartridge` | 머신 하나, 카트리지 한 장 |
| `step ~frames` | 이만큼 시간이 간다. 코어는 스스로 시계를 읽지 않는다 |
| `set_key key ~pressed` | 논리 키를 누르거나 뗀다. 자리가 없는 키는 `false` |
| `frame_rgb` / `frame_dims` | 256×192 RGB 한 장 |
| `screen_text` | name table 을 문자 그리드로 (글자 폰트일 때만 뜻이 있다) |
| `dump_pc` / `cpu_halted` / `vdp_regs` | 판정용 계기 |

코어는 호출자가 준 프레임 수만큼 진행한다. 이 성질을 이용한 세션 재현은 초기 상태와 입력
순서를 함께 고정해야 하며, 서버 원장의 재생 성공은 §5에서 별도로 검증한다.

masc 쪽 지금 모양(`bin/masc_tui_msx.ml`, #33818 → #33975):

- `&` 로 전체화면. `Msx.create` 를 **TUI 프로세스 안에서** 부르고, 키 하나 = 1프레임.
- `MSX_ROMS` 로 C-BIOS, `MSX_CART` 로 카트리지(#33975).
- 타이틀까지 330프레임이라 사람도 키만으로는 못 간다. 실시간 루프는 task-1403.

## 2. 문제

keeper 가 게임에 손을 대는 길은 서버의 도구 디스패치 하나다. 머신이 TUI 프로세스에 있으면
길이 없다. 세 갈래를 봤다.

| | 머신이 사는 곳 | keeper 의 손 | 사람의 눈 | 판정 |
|---|---|---|---|---|
| A | **서버** | 도구 → 서버 머신 | TUI 가 서버 프레임을 받아 그린다 | 채택 |
| B | TUI | 도구 → 서버 → TUI 로 되돌려 전달 | 그대로 | 서버가 클라이언트에 명령하는 역방향. TUI 가 꺼지면 게임도 꺼진다 |
| C | keeper 마다 따로 | 각자 자기 머신 | 못 본다 | "같이 플레이" 가 아니다 |

A 를 택한다. 비용은 둘이다. 서버가 상태를 하나 더 들고, TUI 가 그리던 것을 스트림으로 받아야 한다.
둘 다 이미 있는 모양(도구 상태·TUI 이벤트 채널)의 반복이다.

## 3. 계약

### 3.1 머신 수명

workspace 에 머신은 **하나**다. `masc_msx_load` 가 만들고(C-BIOS + 카트리지 경로),
`masc_msx_eject` 가 끝낸다. 하나인 이유는 목적이 "같이 플레이" 이기 때문이다. keeper 마다
머신을 주는 것은 §7 의 열린 결정에 두고 지금은 만들지 않는다.

### 3.2 시간 — 누가 시계를 돌리나

코어는 턴제다. 서버는 두 가지 방식으로 시간을 준다.

- **턴제(기본)**: `masc_msx_step frames` 나 `masc_msx_press` 가 부를 때만 간다. keeper 혼자
  플레이할 때의 방식이다. 룬 마스터 II 같은 턴제 게임에 맞다.
- **실시간**: 사람 TUI 가 붙어 `masc_msx_realtime on` 을 켜면 서버 틱커가 1/60초마다 1프레임을
  민다. 틱커는 **domain 0 에 두지 않는다** — P4 지표(domain 0 의 ≥100ms 실행 수)가 늘면 안 된다.
  TUI 가 떨어지면 틱커는 멈춘다. 이 방식이 task-1403 의 본체다.

실시간 중에 keeper 가 `press` 를 부르면, 그 입력은 **다음 틱들이 소비하는 큐**에 들어가고
응답은 소비가 끝난 프레임의 관측이다. 턴제 중에는 `press` 가 직접 `step` 을 부른다.

### 3.3 입력 — 두 손이 한 키보드를 누른다

- 입력 단위는 코어의 논리 키(`Msx.key`)다. 누가 눌렀는지(사람 TUI / keeper 이름)는 **서버가**
  주체별 눌림 집합으로 든다. 코어는 주체를 모른다 (코어 계약 그대로).
- 코어에 넣는 값은 주체들의 **OR** 다. 둘 중 하나라도 누르고 있으면 눌림. 뗌은 각자 뗀 것만 반영된다.
- `masc_msx_press keys hold_frames step_frames`: `keys` 를 `hold_frames` 동안 누른 채
  `step_frames` 를 진행하고 뗀다. `hold_frames ≤ step_frames`. XSpelunker 의 입력 루틴은
  프레임 사이의 에지를 보므로 1프레임 눌림도 읽힌다(오늘 하네스에서 5프레임으로 확인).

### 3.4 관측 — 텍스트 keeper 에게 돌려주는 것

MASC에는 이미지 ingestion과 `keeper_analyze_image` 경로가 있다
(`lib/keeper/keeper_vision_ingest.ml`, `lib/keeper/keeper_vision_tool.ml`). 아직 연결되지 않은 것은
MSX의 `frame_rgb`를 이미지 artifact로 만들어 그 경로에 전달하는 부분이다. 이 RFC의 기본
관측은 글자·타일이며, 이미지 전달은 기존 runtime capability와 도구 surface를 따른다.

```
frame: 421            mode: G2       pc: 7d4a   halted: true
screen_text:          (TEXT1/G1 에서 폰트가 글자일 때 — 40×24 또는 32×24)
tiles:                (G1/G2) 32×24 name 그리드, 0 이 아닌 칸만 "행,열=번호"
sprites:              SAT 순서대로 번호·x·y·패턴·색 (0xD0 앞까지)
image:                MSX frame의 이미지 artifact 참조 (기존 이미지 경로와의 연결은 미구현)
```

타일 번호가 무슨 그림인지는 게임마다 다르다. 그 뜻은 keeper 가 게임을 하며 배우는 것이고
이 RFC 의 범위가 아니다. 룬 마스터 II 처럼 글자가 많은 게임은 name table 이 폰트이면
`screen_text` 로 바로 읽힌다 — 그래서 P5 목표 게임이다.

### 3.5 도구 이름 — 닫힌 어휘

`Keeper_tool_name` 과 같은 방식으로 `Msx_tool_name.t` 를 만든다. 변형을 더하면 스키마와
디스패처가 컴파일 에러로 누락을 알린다(#33625 의 규칙). 문자열은 `of_string` 한 번만 본다.

| 도구 | 한다 |
|---|---|
| `masc_msx_load` | 머신을 만든다 (roms 디렉터리, cart 경로) |
| `masc_msx_eject` | 머신을 없앤다 |
| `masc_msx_screen` | §3.4 관측을 준다. 시간은 안 간다 |
| `masc_msx_step` | `frames` 만큼 간다. 관측을 돌려준다 |
| `masc_msx_press` | §3.3. 관측을 돌려준다 |
| `masc_msx_realtime` | on/off. 사람 세션이 붙어 있을 때만 켜진다 |

### 3.6 기록 — 재현에 필요한 실행 조건

입력은 `(frame, who, key, down|up)`과 같은 프레임 안의 적용 순서를 append-only 원장에 남긴다.
재현 bundle은 코어 revision, 실제 BIOS·카트리지 바이트의 digest, 머신 설정, 초기화 조건,
관측할 프레임과 마지막 프레임 번호도 함께 고정해야 한다. 키 입력 없이 진행한 시간도 마지막
키 이벤트에서 잘리지 않아야 한다. 같은 파일 경로나 카트리지 이름만으로 동등한 실행을 보장하지 않는다.

`boot.exe --replay`는 이 조건을 검증하며 재생할 후속 구현이다. 아직 서버 원장의 재생이나
픽셀 일치가 입증된 것은 아니다. savestate는 코어 `serialize`가 구현된 뒤 별도로 다룬다.

### 3.7 TUI — 구경꾼으로

`&` 화면은 그리는 절반(모자이크)은 그대로 두고 만드는 절반(`Msx.create`)을 버린다. 서버가 주는
프레임을 그리고, 키는 서버로 보낸다. `state.msx : Msx.t option` 은 사라진다.

## 4. 하지 않는 것

- 오디오, 디스크(P3), 조이스틱 방향(커서 키만), 색 0 투명 → R#7 배경색(코어 쪽).
- 머신 여러 개. 게임별 타일 의미 해석. 새로운 범용 vision 경로(기존 이미지 경로를 사용).

## 5. 증명

1. 서버 단위 테스트: §3.6의 bundle을 두 번 재생해 지정한 각 프레임의 `frame_rgb` 해시를 비교한다.
2. 하네스 재생: 같은 bundle을 `boot.exe --replay`로 재생해 마지막 프레임까지 픽셀 수·해시를 비교한다.
   입력 없는 구간과 같은 프레임의 복수 주체 입력을 포함한다. 이 검증은 아직 실행하지 않았다.
3. 눈: keeper 가 `masc_msx_press [Space]` 두 번으로 XSpelunker 를 LEVEL 1-1 까지 보낸다 —
   오늘 하네스 `--tap-space 340,420` 과 같은 길.
4. domain 0 의 ≥100ms 실행 수가 실시간 틱커를 켜도 늘지 않는다 (P4 지표, `rtev/_build/default/`).

## 6. 순서

1. 서버 머신 + 원장 + 도구 네 개(`load`·`screen`·`press`·`step`), 턴제만. keeper 가 XSpelunker
   타이틀을 지난다. (task-1402 의 앞부분)
2. TUI 구경꾼 전환 + 실시간 틱커. (task-1403 과 합친다)
3. 룬 마스터 II 는 디스크라 P3(FDC) 뒤다. 그 전까지의 P5 검증 대상은 카트리지 게임이다.

## 7. 열린 결정 (Vincent)

- 머신 하나(§3.1) vs keeper 마다 하나.
- 이미지 전달: MSX frame artifact를 기존 이미지 ingestion/분석 도구에 어떤 응답 형태로 연결하나.
- 도구를 보는 keeper: 전부인가, 지정한 keeper 만인가.
- 실시간 틱커를 어느 domain 에 두나 (P4 의 분리 원칙만 정해져 있다).
