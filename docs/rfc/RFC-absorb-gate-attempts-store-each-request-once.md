---
rfc: "absorb-gate-attempts-store-each-request-once"
title: "흡수 시도가 같은 요청을 다시 저장하는 몫은 다음 gate 형식 변경 때 뺀다 — 다시 묻기는 그대로 둔다"
status: Draft
created: 2026-11-16
updated: 2026-11-16
author: claude
supersedes: []
superseded_by: null
related: ["librarian-absorb-gate", "librarian-history-settles-finished-originals", "0484", "0489", "0498"]
---

# 흡수 시도가 같은 요청을 다시 저장하는 몫은 다음 gate 형식 변경 때 뺀다 — 다시 묻기는 그대로 둔다

2026-11-15 하루 동안 TypeSafe 는 크레딧이 없다며(HTTP 402) 판정을 거절했다.
그동안 Librarian 은 깨어날 때마다 같은 원본에 흡수 시도를 하나씩 더 남겼다.
시도가 70개 쌓인 Keeper 의 pass 검증 구간은 75초였다. 시도가 0개일 때는 1초가 안 걸렸다.
운영자가 TypeSafe 콘솔에서 크레딧을 넣자 다음 깨어남에 판정이 돌아왔다.

이 RFC 는 #52382 의 질문 둘에 답한다.

1. 운영자만 풀 수 있는 거절 동안에도 깨어날 때마다 다시 묻는가. → 그대로 다시 묻는다(§5).
2. 시도가 쌓이는 비용을 어떻게 줄이는가. → 읽는 비용은 #52381 이 줄인다. 저장 비용의 대부분은 같은 판정 요청의 사본이다. 사본을 빼려면 저장 형식을 바꿔야 하고, 그 배포는 Keeper 마다 진행 중인 Librarian 작업을 지운다. 그래서 따로 배포하지 않고 다음 gate 형식 변경에 싣는다(§4, §6).

- 다루지 않는 것: 사슬을 한 번 읽을 때 같은 시도를 여러 번 복원하는 비용. #52381 이 고친다.
- 근거 기준: 코드는 `origin/main` `706704b625a5` 에서 읽었다. 측정은 운영 저장소 `~/me/.masc` 를 읽기만 했다. 크기와 해시만 셌다.
- 표시: **[사실]** 코드·문서·데이터에서 확인한 것, **[계산]** 측정값으로 셈한 것, **[추정]** 근거는 있으나 재지 않은 것, **[제안]** 이 RFC 가 내놓는 것, **[확인 필요]** 모르는 것.

## 1. 지금 동작

### 1.1 실패 뒤 다시 묻는 자리

세 gate 가 같은 모양으로 다시 묻는다. 앞 시도가 실패로 끝났고 지금 권한이 있으면, 앞 시도를 `predecessor` 로 가리키는 새 시도를 `Journal.retain` 으로 남기고 `Journal.resume` 으로 보낸다.

| gate | scope 접두어 | 다시 묻는 자리 |
|---|---|---|
| durable(완료 이력) | `keeper-librarian-durable-gate/` | `lib/keeper/keeper_librarian_durable_commit.ml:361-368` |
| admission | `keeper-librarian-admission-gate/` | `lib/keeper/keeper_librarian_admission_owner.ml:258` |
| floor step | `keeper-librarian-floor-step-gate/` | `lib/keeper/keeper_librarian_floor_step_judgment.ml:112` |

- **[사실]** 세 gate 의 저장과 검증은 공용 functor `Keeper_librarian_original_gate.Make` 하나다.
- **[사실]** 새 시도의 요청 본문은 원본의 proposal 전체를 다시 담는다(`keeper_librarian_durable_commit.ml:367`, `keeper_librarian_original_gate.ml:216-222`). 한 사슬의 proposal 은 하나로 강제된다(`:281`, `:295`, `:339`, `:360`, `:703`).
- **[사실]** guidance 는 시도마다 지금 권한에서 다시 만든다(`keeper_librarian_absorb_gate.ml:987-999`). proposal 은 guidance 가 있는지만 정한다(`keeper_librarian_original_gate.ml:204-207`).

### 1.2 시도 하나가 저장하는 판정 요청

- **[사실]** 판정 한 번마다 gate 는 transcript 전체를 `Waiting` 증거로 두 번 남긴다. 보내기 전에 한 번(`keeper_librarian_original_gate.ml:761-767`), 답을 받은 뒤 한 번(`:768-775`)이다. transcript 의 평가 항목은 판정 요청 전체(`direction`, `destinations`, `state`, `questions`)를 담는다(`keeper_librarian_absorb_gate.ml:964-975`).
- **[사실]** 받은 답의 증거(`evaluation_evidence_to_yojson`, `:1059-1074`)도 판정 요청 전체를 다시 담는다.
- **[사실]** 끝나면 판정 보고서(`run_result_to_yojson`)를 `Refused` 나 `Judgment_retained` 증거로 남긴다(`keeper_librarian_original_gate.ml:223-226`). 보고서의 평가 항목(`evaluation_to_yojson`, `keeper_librarian_absorb_gate.ml:1298-1360`)도 판정 요청 전체를 담는다.

### 1.3 다시 읽을 때 사본을 쓰는 방식

- **[사실]** replay 는 저장된 입력에서 판정 요청을 다시 만들고, 저장된 사본과 같은지만 확인한다.
  - 보내기 전 요청: `"pre-dispatch request differs from original inputs"`(`keeper_librarian_absorb_gate.ml:1269-1274`).
  - 받은 답의 요청: `"returned request differs from original"`(`:1157-1159`).
- **[사실]** lib/, bin/, dashboard/ 에 transcript 나 받은 답 증거 속 요청 사본의 내용을 읽어 쓰는 곳은 없다. 비교만 한다. `scripts/librarian/compare-preflight.py:708-714` 는 판정 보고서의 모양만 확인한다.
- 그래서 transcript 와 받은 답 증거 속 사본은 새 정보가 없는 검사값이다. digest 하나로 같은 검사를 할 수 있다.
- **[사실]** 판정 보고서는 다르다. `:1353-1355` 주석은 같은 질문 ID 가 다른 요청에서 다시 쓰이니 답을 읽으려면 질문 내용이 보고서에 있어야 한다고 적는다. 같은 보고서가 Memory OS 프로그램의 `gate_evidence`(`keeper_librarian_memory_program.ml:34`)와 실행 기록(`keeper_librarian_runtime.ml:1583`, `:2406`)에도 저장된다.

### 1.4 이미 정해 둔 것

- `RFC-librarian-absorb-gate` §2 의 6항: 판정이 실패하면 입력 범위를 남겨 재시도한다. 입력 범위는 판정 서비스가 회복된 뒤 다시 읽힌다.
- RFC-0484 §3.2: `typesafeai` health 칸은 아무것도 막지 않는다. `destination_outcomes` 는 프로세스 메모리의 투영이고 호출을 정하는 데 쓰지 않는다.
- RFC-0489 §2.7: Goal 검증에서 같은 입력이 같은 실패를 되풀이하는 `Raised` 는 자동 재시도에서 빼고, 명시적 요청으로만 다시 만든다.
- 헌법 Task 검증 수명(`docs/constitution.xml:104-117`): 후보 실패의 typed 판정(`Reviews_again | Model_absent | Producer_must_act`)이 자동 재시도를 이어 갈지 정한다. `Producer_must_act`(잘못된 자격 증명, 계정 거절, 끝을 밝히지 않은 한도)는 자동으로 다시 하지 않는다(`lib/task/anti_rationalization.ml:576-593`).
- RFC-0498 D2: 보관된 기록은 살아 있는 기록이 그 요청 ID 를 가리키지 않으면 지운다.
- `docs/design/addon-original-request-discovery.md:40-41`: "No new cache, size cap or retry loop hides that cost."
- 헌법 `magic_number`, `budget_gate`: 반복 횟수나 누적 숫자로 멈추지 않는다. `failure_keeps_evidence`: 전달 실패는 증거를 남긴다.
- `docs/guides/DURABLE-STORE-HARD-CUT.md:33-43`: 빌드는 자기가 쓰는 형식만 읽는다. 옛 형식은 읽지도 바꾸지도 않는다. 모든 writer 를 멈추고, 바뀐 형식이 적은 것을 지우고, `validate-stores` 를 다시 돌린다. Librarian 원본이 거절되면 그 원본 owner 의 모든 scope 의 기록·본문·history fence·history resolution 을 지운다(`:125-142`).

## 2. 측정

`~/me/.masc/lane-addons` 를 11-16T02:28Z 에 읽었다. 살아 있는 durable gate 기록만 셌다. 본문은 몇 분 뒤에 따로 쟀다.

### 2.1 기록 384개, 13,949,197 바이트

| 판정 요청 사본이 있는 자리 | 사본 | 바이트 | 기록 바이트 중 |
|---|---:|---:|---:|
| `Waiting` transcript 의 평가 요청 | 788 | 6,302,050 | 45% |
| `Waiting` 받은 답 증거의 요청 | 402 | 3,194,764 | 23% |
| 보고서의 `failed` 평가 요청 | 374 | 3,022,069 | 22% |
| 보고서의 `answered`·`invalid_answer` 평가 요청 | 0 | 0 | 0% |

- **[사실]** 같은 기록들 속 요청 안쪽(`request` 칸) 내용은 서로 다른 것이 19개, 한 번씩 저장하면 142,314 바이트다.
- **[사실]** Keeper 하나의 gate scope 에 기록이 66개여도 판정 요청 내용은 하나였다. 기록이 많은 scope 8개 중 6개가 내용 하나, 나머지 둘이 2개와 4개다. scope 는 Keeper owner 마다 하나다(`keeper_librarian_durable_gate.ml:6-8`).

### 2.2 요청 본문 369개, 7,082,881 바이트

| 칸 | 바이트 | 서로 다른 내용 | 한 번씩 저장하면 |
|---|---:|---:|---:|
| `proposal` | 4,082,676 | 14 | 126,803 |
| `guidance` | 2,774,724 | 2 | 7,544 |

- **[계산]** 시도 하나는 기록 약 36 KB 와 본문 약 19 KB 다. 기록과 본문을 합친 바이트의 약 91% 가 앞 시도와 같은 내용이다.

## 3. 문제

1. **시도 하나가 앞 시도와 같은 내용을 다시 저장한다.** 판정 서비스가 거절하는 동안 깨어날 때마다 약 55 KB 가 는다. 원본이 끝나야 보관소로 옮겨진다.
2. **다시 읽을 때도 같은 내용을 다시 읽는다.** 복원은 기록과 본문을 풀고 요청 사본을 구조 비교한다. 같은 시도를 여러 번 복원하는 몫은 #52381 이 없앤다. 시도 하나의 크기에 비례하는 몫은 남는다.
3. **운영자만 풀 수 있는 거절 동안에도 깨어날 때마다 다시 묻는다(#52382).** 이 RFC 는 이 규칙을 바꾸지 않는다(§5).

## 4. 사본을 빼는 길과 그 비용

### 4.1 D-1 transcript 는 판정 요청 digest 만 담는다 (다음 gate 형식 변경에 싣는다)

- **[제안]** transcript 평가 항목의 `request` 를 `request_sha256` 으로 바꾼다. replay 는 지금처럼 입력에서 요청을 다시 만들고 digest 를 견준다.
- 대가: 요청이 어긋났을 때 저장된 사본과 새 요청을 줄 단위로 비교할 수 없다. 오류 문구에 두 digest 를 싣는다.

### 4.2 D-2 받은 답 증거는 요청 digest 만 담는다 (D-1 과 함께)

- **[제안]** `evaluation_evidence_to_yojson` 의 `request` 를 `request_sha256` 으로 바꾼다.
- **[계산]** D-1·D-2 는 §2.1 의 기록 바이트 중 68%(9,496,814 바이트)를 뺀다. 시도 하나는 약 55 KB 에서 약 30 KB 가 된다.

### 4.3 고르지 않은 것

| 길 | 고르지 않는 이유 |
|---|---|
| D-3 판정 보고서의 `failed` 평가만 digest 로 | 같은 보고서가 Memory OS 프로그램의 `gate_evidence` 와 실행 기록에도 저장된다(§1.3). 형식 변경이 Memory OS 저장소까지 번진다. |
| D-4 다음 시도의 본문이 처음 시도의 proposal 을 digest 로 가리키기 | 부모 실행 기록의 `Preparation_intended` 가 처음 gate 요청 전체를 바꿀 수 없게 담는다(`lane_addon_request_progress.mli:13`, `:20`, `:44-48`). 요청 형식을 바꾸면 부모 scope 도 읽지 못한다(`keeper_librarian_original_gate.ml:315`, `:533`, `keeper_librarian_store_preflight.ml:65-84`). 처음 시도는 같은 ID 로 다시 만들 수 없다(`:691`, `:694`, `:544`). 사슬의 기록은 하나씩 보관소로 옮겨지므로(`keeper_librarian_durable_execution.ml:222-240`) 처음 시도만 먼저 옮겨진 상태도 생긴다. |
| 판정 요청을 따로 두는 내용 주소 저장소 | 새 저장소와 그 정리 규칙이 는다. 같은 내용은 이미 저장된 입력에 있다. |
| 옛 형식과 새 형식을 같이 읽기 | `DURABLE-STORE-HARD-CUT.md:33-37`. |

## 5. 다시 묻기는 그대로 둔다 (#52382)

운영자만 풀 수 있는 거절(402·401·403) 동안에도 깨어날 때마다 다시 묻는다.

- **[사실]** 11-16 의 두 회복은 운영자가 TypeSafe 콘솔에서 크레딧을 넣은 결과다(01:34Z, #52382 댓글의 11:19 KST). 목적지와 모델은 실패한 시도와 같았다. masc 가 볼 수 있는 설정 변화가 없었다.
- 그래서 masc 가 회복을 아는 길은 다시 묻는 것뿐이다. 다시 묻지 않으면 운영자가 크레딧을 넣은 뒤 masc 에서 따로 풀어야 한다. 그 전까지 그 원본의 흡수가 멈춘다.
- 헌법은 Task 검증에서 `Producer_must_act` 뒤 자동 재시도를 멈추게 한다(§1.4). 그 경우는 검증 한 번이 provider 턴 하나라 비싸고, 운영자가 고친 뒤 다시 하라고 알릴 Task 가 있다. 흡수 gate 의 다시 묻기는 거절을 바로 받는 HTTP 호출 하나와 시도 기록 하나다. 운영자가 masc 쪽에서 할 일도 없다.
- 운영자 방향(11-16): 근본 개선, 더 안전하게, Keeper 를 멈추지 않게, 자원은 효율적으로.

| 길 | 고르지 않는 이유 |
|---|---|
| 402·401·403 뒤에는 자동으로 다시 묻지 않기 | 위 이유로 원본의 흡수가 운영자 조치까지 멈춘다. |
| 시도 횟수 상한, backoff, cooldown | `magic_number`, `budget_gate`. |
| health 투영으로 다시 묻기를 막기 | RFC-0484 §3.2. 프로세스 메모리라 재시작하면 빈다. |
| 기록 하나 안에서 다시 보내기 | 기록 하나는 요청 ID 하나다. 거절은 끝난 상태로 남는다(`lib/lane_addon/lane_addon_request_progress.mli:78-79`). |
| 대체된 시도를 보관소로 옮기기 | 사슬 계약(앞 시도가 scope 에 있어야 한다, `keeper_librarian_original_gate.ml:449`)과 RFC-0498 D2 를 함께 바꿔야 한다. |
| 오래된 시도를 지우기 | `failure_keeps_evidence`. |

## 6. 배포 — 단독 하드컷을 하지 않는다

- **[사실]** D-1·D-2 는 gate 기록의 진행 증거 형식을 바꾼다. 하드컷 가이드대로면 살아 있는 gate 기록이 있는 Keeper 마다 그 원본 owner 의 모든 scope 를 지운다(§1.4). 진행 중인 Librarian 작업과 history fence 가 같이 지워진다.
- **[사실]** 가이드의 첫 단계는 모든 writer 를 멈추는 것이라, 배포를 기다리는 동안 사슬이 저절로 끝나지 않는다. 서버가 도는 동안에는 새 원본이 계속 지금 형식으로 gate 를 남긴다.
- **[제안]** 그래서 D-1·D-2 만을 위해 fresh state 를 요구하지 않는다. gate 진행 증거 형식을 바꿔야 하는 다음 변경이 생기면 그 변경에 싣는다. 그 PR 의 **Fresh state required** 항목이 같은 scope 를 이미 지우므로 비용이 더 들지 않는다.
- 그때까지 저장 형식은 바뀌지 않는다. 판정 서비스가 길게 거절하면 시도마다 약 55 KB 가 늘고, 원본이 끝나면 보관소로 옮겨진다.

## 7. 검증

D-1·D-2 를 싣는 변경에서:

1. 402 로 세 번 거절된 사슬의 기록에 판정 요청 내용이 없고 `request_sha256` 만 있다.
2. 저장된 입력 하나를 바꾸면 replay 가 지금과 같은 오류로 끝나고, 오류 문구에 두 digest 가 있다.
3. 변형 시험: replay 가 digest 비교를 건너뛰게 바꾼 코드에서 2번이 실패한다.
4. 배포 뒤 같은 바이트 셈을 다시 해 §2.1 과 견준다.

이 RFC 를 받아들인 뒤 지금 할 일:

5. #52381 배포 뒤 `durable Librarian inventory validated` 줄의 `gate_records` 대비 `elapsed_ms` 를 §2 의 시각과 견준다. 다음 판정 서비스 거절이 길어질 때도 같은 줄로 잰다.

## 8. 정할 것

1. D-1·D-2 를 단독 하드컷으로 하지 않고 다음 gate 형식 변경에 싣는 데 동의하는지.
2. 운영자만 풀 수 있는 거절 동안에도 다시 묻는 규칙을 그대로 두는지(§5).
3. 2를 받아들이면 #52382 를 이 RFC 로 닫을지.

## 9. 관련

- #52381 사슬을 한 번 읽을 때 시도마다 한 번만 복원한다.
- #52382 운영자만 풀 수 있는 거절 동안 다시 묻는 규칙.
- #46247 gate 요청이 부모 실행을 digest 로 가리킨다.
- `RFC-librarian-absorb-gate`, `RFC-librarian-history-settles-finished-originals`, RFC-0484, RFC-0489, RFC-0498.
