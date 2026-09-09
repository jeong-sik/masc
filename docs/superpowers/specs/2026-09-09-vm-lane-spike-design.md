# VM lane (spike) — keeper 가 조종하는 두 번째 머신

- 날짜: 2026-09-09
- 상태: Draft (사용자 리뷰 대기)
- 맥락: RFC-0439(MSX 머신은 서버에 산다)의 두 번째 인스턴스. 첫 인스턴스가
  검증한 패턴(서버 소유 머신, keeper 도구, 입력 원장, TUI spectator)을
  범용 머신(QEMU VM)으로 옮기면서, **도구 표면 재사용률과 도구 합성 한계를
  측정하는 실험대**로 삼는다.

## 1. 목적 — 두 개의 검증 질문

1. keeper 가 프리미티브 도구만으로 VM 조종 작업을 완수할 수 있는가?
2. `masc_msx_*` 도구 표면의 재사용률은 얼마나 되는가? (목표: 이름/스키마
   1:1 매핑 여부를 아래 고정 분모로 보고)

실험 시작 기준은 이 PR의 `lib/tool_schemas/tool_schemas_misc.ml`에 등록된
MSX 10개 도구(load, eject, save, restore, change_disk, screen, press, step,
peek, ram_diff)다. **기존 표면 커버리지 = 대응된 서로 다른 MSX 도구 수 / 10**.
현재 제안은 load, screen, press, save, restore의 5/10이며, key와 type이
같은 press에 대응해도 한 번만 센다. VM 6개를 분모로 바꿔 합격시키지 않는다.
별도로 각 대응의 인자·결과·효과 의미를 비교해 `동일 / 변경 필요 / 대응 없음`을
기록한다. 이름 접두사만 바꾸어도 스키마가 같다는 증명이 되지는 않는다.
현재는 개념 대응만 있고 1:1 스키마 재사용률은 아직 측정하지 않았다.

합성 도구(고수준 도구)는 미리 만들지 않는다. keeper 가 어디서 막히는지
관측한 실패가 곧 7번째 도구의 요구사항이다. 이것이 이 spike 의 실험 규칙이다.

## 2. 범위

### 포함

- QEMU sidecar 프로세스 하나 (서버가 spawn/관리, 워크스페이스당 머신 하나)
- QMP(unix socket) 경유 입력·스냅샷·상태
- 화면: QMP `screendump`(PPM) → 기존 spectator 프레임 파이프라인
- 텍스트/메뉴 중심 게스트 (키보드만으로 조작 가능한 환경)
- 입력 원장 JSONL — **감사 로그다. 결정적 리플레이 소스가 아니다** (§9)

### 제외 (spike 이후로 미룸)

- 마우스 입력 (`masc_vm_click` 은 7번째 도구 후보 1순위, §6 참고)
- VNC 스트리밍 (screendump 캐던스로 부족하다는 관측이 생기면)
- `-icount` record/replay (결정성 부활 실험 — 별도 RFC)
- PC-98 계열 게스트 (§3)
- 그래픽스 게임 전반 — 화면 자체가 VGA 그래픽인 것은 괜찮고, "실시간
  반응이 필요한" 게임이 제외다

## 3. 게스트 정책 — lane 은 게스트를 모른다

lane은 게스트 프로그램의 의미를 판단하지 않는다. 부팅은 지원되는 QEMU
머신·블록 장치 구성에 한하며, 텍스트 입력은 아래 선언된 키보드 레이아웃이 필요하다.

| 게스트 | 부착 | 비고 |
|---|---|---|
| FreeDOS | 됨 | 기본 검증 게스트, 라이선스 프리 |
| MS-DOS / PC-DOS / DR-DOS | 됨 | 이미지는 운영자 준비 (MSX carts inventory 와 같은 패턴) |
| DOS/V (일본어 DOS, IBM PC) | 됨 | PC 호환이라 QEMU 그대로 |
| JDOS on PC-98 | **안 됨** | NEC PC-98 은 IBM PC 가 아니라 별도 아키텍처. QEMU 가 에뮬레이트하지 않음 (Neko Project 2 계열 필요). 이 lane 의 문제가 아니라 다른 머신이다 |
| 리눅스 | 됨 | 본편 방향. spike 의 시나리오 2 가 이 길을 연다 |

게스트 이미지는 keeper 가 만들지 않는다. `.masc/vm/images/` (가칭) 의
운영자 준비 inventory 를 `masc_vm_boot` 가 가리킨다 — MSX 의
`.masc/msx/bios/`, `carts/` 와 같은 책임 분리.
경로는 설정으로 해소한 base path 아래에서 파생한다. inventory 원본은
read-only backing node로만 열고, boot마다 machine generation 전용 qcow2
copy-on-write overlay를 만든다. 모든 쓰기는 overlay에만 간다. 원본으로
commit하지 않으며, 교체 전 generation과 스냅샷은 증거·명시적 정리용으로
보존한다. 부팅 실패도 원본을 수정하지 않는다. 수용 실험 전후 원본 digest를 비교한다.
[QEMU backing image 문서](https://www.qemu.org/docs/master/system/images.html).

Inventory manifest에 디스크 format, 머신 구성과 `keyboard_layout`을 명시한다.
spike의 text 입력은 명시적으로 설정된 US 레이아웃의 지원 문자표로 제한한다.
게스트도 해당 레이아웃으로 운영자가 맞춘다. 미선언 레이아웃이나 표현 불가능한
문자는 입력 전에 typed `Unsupported_layout` / `Unrepresentable_text`로 거절한다.
일부 문자열만 먼저 입력하거나 레이아웃을 추측하지 않는다. 키·수정키의 명시적
정적 변환표는 문자 인코딩 계약이며 LLM 내용 분류 휴리스틱이 아니다.
DOS/V와 다른 Linux 레이아웃에는 `masc_vm_key`의 물리 키 조작을 사용할 수 있다.

## 4. 아키텍처

```
masc server
 └─ lib/vm_lane/            msx_lane.mli 와 같은 모양의 계약
 │    ├─ 머신 하나 / 워크스페이스 (교체는 masc_vm_boot 가 함)
 │    ├─ 원장 JSONL: generation / branch / request / typed event (§7) — 감사 로그
 │    └─ typed error: No_machine | Invalid_request | Unsupported | Unreadable | State_uncertain
 └─ QEMU sidecar            서버가 spawn/감독, 죽으면 도구가 typed error
      ├─ QMP (unix socket)  ← 키 주입(input-send-event), 스냅샷(snapshot-save/load), 상태(query-status)
      └─ screendump → PPM   ← 화면. PPM→RGB 변환 후 VM frame projection으로 spectator에 공급
```

픽셀 렌더러(Kitty retain / truecolor mosaic / 셀 픽셀 프로브)는 재사용한다.
현재 `masc_tui_msx_tick.frame_with_rgb`와 `masc_tui_msx.title_of`는 MSX 전용
필드·제목을 요구하므로 VM 응답을 그 decoder에 넣지 않는다. 공통 픽셀 계약은
`{source_id; generation; revision; width; height; rgb}`이고, VM 전용 typed
projection은 machine/image/branch/lifecycle metadata를 따로 가진다.
새 VM API route와 TUI VM source 선택을 추가해 기존 MSX route와 화면을 유지한다.
MSX mode/cartridge/disk를 가짜 값으로 채우지 않는다. reconnect와 source 전환 시
픽셀 캐시도 source_id/generation으로 격리한다.

## 5. 도구 예산 — 정확히 6개

| 도구 | QMP 대응 | msx 대응 |
|---|---|---|
| `masc_vm_boot(image)` | (프로세스 spawn + `-loadvm` 없이) | `masc_msx_load` |
| `masc_vm_screen` | `screendump` | `masc_msx_screen` |
| `masc_vm_key(key, edge)` | `input-send-event`의 key event (`down`: bool) | `masc_msx_press` |
| `masc_vm_type(text)` | 선언된 layout으로 변환한 `input-send-event` 시퀀스 | (msx 의 printable char press) |
| `masc_vm_save(name)` | `snapshot-save` job | `masc_msx_save` |
| `masc_vm_restore(name)` | `snapshot-load` job | `masc_msx_restore` |

공개 이름은 모두 기존 MCP namespace인 `masc_vm_*`를 사용한다.
`masc_vm_key`는 QAPI `KeyValue`의 qcode enum과 typed Down/Up을 받으며,
[QMP input-send-event](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html#command-input-send-event)의
명시적 edge로 전달한다. HMP `sendkey`나 자동 release하는 `send-key`를 대신 쓰지 않는다.
text는 전체 변환 검증 후 순서대로 down/up을 보내며, 부분 실패 시 마지막 확인된
입력과 미해제 키를 기록한다. QMP ack는 게스트 프로그램이 입력을 소비했다는 증명이 아니다.

스냅샷은 QEMU 6.0 이상 native `snapshot-save` / `snapshot-load`를 사용한다.
시작 시 QMP schema/command 조회로 실제 지원을 확인한다. `job-id`, `tag`,
`vmstate`, `devices`를 보내며, 모든 writable disk는 internal snapshot 가능한
qcow2 overlay여야 한다. `vmstate`는 그 중 명시적으로 지정한 node이고,
`devices`에는 모든 writable node를 포함한다. unsupported storage는 typed 결과다.
ACK 뒤 job 상태·오류를 조회해 종결을 확인하기 전에는 성공을 반환하지 않는다.
이후 job을 dismiss하며, 연결이 끊겨 결과를 확인하지 못하면 성공/실패를 추측하지 않는다.
[QMP snapshot jobs](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html#command-snapshot-save).

**7번째 도구 규칙**: 추가하려는 도구마다 "어느 시나리오의 어느 관측된
실패 때문에" 라는 근거 한 줄을 요구한다. 근거 없는 추가는 거절.

예상 후보 (미리 만들지 않음):

- `masc_vm_click` — 삼국지 3 이 마우스를 요구하는 것으로 판명되면 (§6)
- `masc_vm_peek` / `masc_vm_ram_diff` — QMP `pmemsave` (HMP `xp`는 이 QMP 계약 밖) 로 MSX 식 RAM 관측이
  가능하나, DOS 게임의 상태 주소는 리버싱이 필요해 별도 작업

## 6. Quick win — 한글판 삼국지 3

첫 수용 시나리오. 선정 이유: 턴제, 메뉴 중심, 실시간 반응 불필요,
키보드로 메뉴 조작 가능 (KOEI PC 이식작 특성 — **검증 항목**: 마우스
전용 조작이 섞여 있으면 그것이 `masc_vm_click` 의 관측 근거가 된다).

요구와 대응:

- VGA 그래픽 화면 → screendump 가 그대로 잡는다. 픽셀 파이프라인 묵직함 없음.
- 한글 텍스트가 그래픽 모드에 그려진다 → luminance ASCII (`screen_view`)
  같은 텍스트 축약은 불가. **keeper 는 vision 런타임으로 screendump
  이미지를 읽는다** (MSX 의 image artifact 경로 재사용). vision 없는
  keeper 의 삼국지 3 은 범위 밖.
- 게임 이미지와 DOS 환경은 운영자 준비 inventory. KOEI 한글판은 자체
  폰트를 내장해 별도 한글 DOS 셸이 필요 없는 것으로 알려져 있으나,
  게스트 이미지 제작 시 확인한다.

## 7. 합성 시험 시나리오 (수용 기준)

1. **삼국지 3 한 턴**: 부팅 → 타이틀 도달 → 시나리오 선택 → 첫 명령
   실행 → 결과 화면 확인. 성공 = keeper 가 프리미티브 6개만으로 여기까지.
2. **파일 편집과 실행**: 리눅스 또는 DOS 게스트에서 파일 하나를 고치고
   프로그램을 실행해 결과를 읽는다. 프리미티브 합성만으로.
3. **스냅샷 분기**: `masc_vm_save` → 실패하는 입력 → `masc_vm_restore` → 다른
   입력. 원장에 두 갈래가 who 와 함께 남는지 확인.

원장의 공통 필드는 `seq, who, wall_ts, generation_id, branch_id, request_id`다.
이벤트는 `Boot_requested/Boot_completed`, `Key_requested/Key_completed`,
`Text_requested/Text_completed`, `Save_requested/Save_completed`,
`Restore_requested/Restore_completed`, `Operation_failed`, `Outcome_unknown`의
typed 합타입이다. 요청을 효과 전에 쓰고 QMP request/job ID 및 결과를 연결한다.
`Save_completed`는 snapshot ID, source branch와 source seq를 고정한다.
`Restore_completed`에서만 새 branch ID를 발급하고 parent snapshot/source seq와
restore 직전 branch를 연결한다. 이전 branch 기록은 덮어쓰지 않는다.
실패·결과 불명인 restore는 새 branch 성공 기록을 만들지 않는다.

측정 (시나리오마다 기록):

- 작업당 도구 호출 수
- 화면 읽기 : 입력 비율 (화면을 몇 번이나 다시 보는가)
- 실패 후 재시도 패턴 (같은 키 반복? 화면 재확인? 포기?)

이 숫자들이 7번째 도구 후보를 결정한다.

## 8. 실패 모델

- QEMU 사망 → 실행 중 작업은 실패 또는 결과 불명으로 기록하고 기존 머신을
  필요로 하는 호출은 `Unreadable`이다. **`masc_vm_boot`는 계속 사용 가능**하며
  이전 자식 프로세스를 reap하고 새 generation/overlay/socket으로 spawn한다.
  서버 재시작을 요구하지 않는다. preflight 실패는 살아 있는 기존 머신을 교체하지 않는다.
- snapshot 요청 전 manifest 검증 실패는 `Invalid_request`이며 효과가 없다.
  snapshot-load 실행 후 실패·연결 단절에는 현재 상태 보존을 보장하지 않는다.
  `State_uncertain`으로 기록하고 입력을 중단한다. 명시적 restore 재시도 또는
  boot로 회복하며, job 종결과 query-status 확인 후에만 사용 가능한 상태로 전이한다.
- 부팅 후 게스트가 인터랙티브 화면에 도달했는지는 lane 이 판정하지 않는다
  — MSX 와 같은 원칙: "loading 성공은 게임 도달의 증거가 아니다"

## 9. 결정성에 대한 정직한 명기

QEMU 는 wall clock 을 읽고 게스트는 타이머 인터럽트에 의존한다.
RFC-0439 의 "같은 원장 = 같은 프레임" 보장은 이 lane 에 없다. 원장은
감사와 재시도 맥락용이며, 리플레이는 `-icount` 실험(별도 RFC)에서 다룬다.
keeper 증거 체계가 이 차이를 오해하지 않도록 도구 설명에 명시한다.

## 10. 테스트

- `lib/vm_lane` 상태기 단위 테스트 — QMP 트랜스포트를 fake 로 주입,
  QEMU 없이 돈다
- 통합 테스트 — 실제 QEMU 필요, `qemu-system-i386` 부재 시 skip (수용 완료로 세지 않음)
- feature 검증: edge 유지/해제, punctuation·미지원 문자 무효과, snapshot ACK 이후
  job 실패, branch 연결, 원본 digest 불변, QEMU kill 뒤 boot 복구, MSX/VM 화면 동시 접근
- 수용 테스트 = §7 시나리오 3개 (수동 실측 + 증거 저장, constitution 의
  evidence 요구에 따름)

## 11. 사이드 퀘스트 — 해설 keeper (양념)

lane 무관하게 원장 + 화면 이벤트를 구독해 중계문을 board/chat 에 쓰는
keeper 페르소나. 본 spike 의 의존성이 아니며, VM lane 이후 어느 머신에도
붙는다. 재화/예측 시스템은 채택하지 않는다 (시청자 = 운영자 1인,
무가치 포인트는 혼잣말 장부).

## 오픈 질문

- QEMU 바이너리 의존성 관리: 시스템 qemu 가정 vs 배포 스크립트에서 설치
- overlay·증거 보존의 운영자 정리 UI (자동 삭제나 원본 commit은 범위 밖)
