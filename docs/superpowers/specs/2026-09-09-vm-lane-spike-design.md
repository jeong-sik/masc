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
   1:1 매핑 80% 이상)

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

- 마우스 입력 (`vm_click` 은 7번째 도구 후보 1순위, §6 참고)
- VNC 스트리밍 (screendump 캐던스로 부족하다는 관측이 생기면)
- `-icount` record/replay (결정성 부활 실험 — 별도 RFC)
- PC-98 계열 게스트 (§3)
- 그래픽스 게임 전반 — 화면 자체가 VGA 그래픽인 것은 괜찮고, "실시간
  반응이 필요한" 게임이 제외다

## 3. 게스트 정책 — lane 은 게스트를 모른다

lane 의 계약은 QMP + screendump 뿐이라, QEMU 가 부팅하는 것은 무엇이든
붙는다.

| 게스트 | 부착 | 비고 |
|---|---|---|
| FreeDOS | 됨 | 기본 검증 게스트, 라이선스 프리 |
| MS-DOS / PC-DOS / DR-DOS | 됨 | 이미지는 운영자 준비 (MSX carts inventory 와 같은 패턴) |
| DOS/V (일본어 DOS, IBM PC) | 됨 | PC 호환이라 QEMU 그대로 |
| JDOS on PC-98 | **안 됨** | NEC PC-98 은 IBM PC 가 아니라 별도 아키텍처. QEMU 가 에뮬레이트하지 않음 (Neko Project 2 계열 필요). 이 lane 의 문제가 아니라 다른 머신이다 |
| 리눅스 | 됨 | 본편 방향. spike 의 시나리오 2 가 이 길을 연다 |

게스트 이미지는 keeper 가 만들지 않는다. `.masc/vm/images/` (가칭) 의
운영자 준비 inventory 를 `vm_boot` 가 가리킨다 — MSX 의
`.masc/msx/bios/`, `carts/` 와 같은 책임 분리.

## 4. 아키텍처

```
masc server
 └─ lib/vm_lane/            msx_lane.mli 와 같은 모양의 계약
 │    ├─ 머신 하나 / 워크스페이스 (교체는 vm_boot 가 함)
 │    ├─ 원장 JSONL: (seq, who, key|text, edge, wall_ts) — 감사 로그
 │    └─ typed error: No_machine | Invalid_request | Unreadable (MSX 패턴 재사용)
 └─ QEMU sidecar            서버가 spawn/감독, 죽으면 도구가 typed error
      ├─ QMP (unix socket)  ← 키 주입(sendkey), 스냅샷(savevm/loadvm), 상태(query-status)
      └─ screendump → PPM   ← 화면. PPM→RGB 변환 후 기존 msx_frame 형태로 spectator 에 공급
```

TUI spectator 는 프레임 소스만 교체한다. Kitty 픽셀 retain / truecolor
mosaic / 셀 픽셀 프로브는 전부 재사용.

## 5. 도구 예산 — 정확히 6개

| 도구 | QMP 대응 | msx 대응 |
|---|---|---|
| `vm_boot(image)` | (프로세스 spawn + `-loadvm` 없이) | `masc_msx_load` |
| `vm_screen` | `screendump` | `masc_msx_screen` |
| `vm_key(key, edge)` | `sendkey` (down/up) | `masc_msx_press` |
| `vm_type(text)` | `sendkey` 시퀀스 | (msx 의 printable char press) |
| `vm_save(name)` | `savevm` | `masc_msx_save` |
| `vm_restore(name)` | `loadvm` | `masc_msx_restore` |

**7번째 도구 규칙**: 추가하려는 도구마다 "어느 시나리오의 어느 관측된
실패 때문에" 라는 근거 한 줄을 요구한다. 근거 없는 추가는 거절.

예상 후보 (미리 만들지 않음):

- `vm_click` — 삼국지 3 이 마우스를 요구하는 것으로 판명되면 (§6)
- `vm_peek` / `vm_ram_diff` — QMP `pmemsave`/`xp` 로 MSX 식 RAM 관측이
  가능하나, DOS 게임의 상태 주소는 리버싱이 필요해 별도 작업

## 6. Quick win — 한글판 삼국지 3

첫 수용 시나리오. 선정 이유: 턴제, 메뉴 중심, 실시간 반응 불필요,
키보드로 메뉴 조작 가능 (KOEI PC 이식작 특성 — **검증 항목**: 마우스
전용 조작이 섞여 있으면 그것이 `vm_click` 의 관측 근거가 된다).

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
3. **스냅샷 분기**: `vm_save` → 실패하는 입력 → `vm_restore` → 다른
   입력. 원장에 두 갈래가 who 와 함께 남는지 확인.

측정 (시나리오마다 기록):

- 작업당 도구 호출 수
- 화면 읽기 : 입력 비율 (화면을 몇 번이나 다시 보는가)
- 실패 후 재시도 패턴 (같은 키 반복? 화면 재확인? 포기?)

이 숫자들이 7번째 도구 후보를 결정한다.

## 8. 실패 모델

- QEMU 프로세스 사망 → 이후 모든 `vm_*` 호출이 `Unreadable "qemu: ..."`
- 스냅샷 손상/`loadvm` 거절 → `Invalid_request`, 현재 머신 상태 보존
  (MSX 의 "rejected disk boot preserves the previous machine" 패턴)
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
- 통합 테스트 — 실제 QEMU 필요, `qemu-system-i386` 부재 시 skip
- 수용 테스트 = §7 시나리오 3개 (수동 실측 + 증거 저장, constitution 의
  evidence 요구에 따름)

## 11. 사이드 퀘스트 — 해설 keeper (양념)

lane 무관하게 원장 + 화면 이벤트를 구독해 중계문을 board/chat 에 쓰는
keeper 페르소나. 본 spike 의 의존성이 아니며, VM lane 이후 어느 머신에도
붙는다. 재화/예측 시스템은 채택하지 않는다 (시청자 = 운영자 1인,
무가치 포인트는 혼잣말 장부).

## 오픈 질문

- QEMU 바이너리 의존성 관리: 시스템 qemu 가정 vs 배포 스크립트에서 설치
- 스냅샷 저장 위치: 게스트 이미지 내장(qcow2 internal snapshot) vs lane 디렉터리
- `vm_key` 의 키 네이밍: QEMU sendkey 식(`ret`, `shift-r`) 그대로 vs
  msx 식 이름 매핑 테이블 — keeper 도구 설명의 일관성은 후자, 구현 단순성은 전자
