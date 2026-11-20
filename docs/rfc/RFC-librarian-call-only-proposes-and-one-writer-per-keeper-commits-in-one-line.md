---
rfc: "librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line"
title: "Librarian 의 모델 호출은 제안만 하고, 반영은 Keeper 마다 하나인 쓰는 쪽이 기록 한 줄로 한다"
status: Draft
created: 2026-11-18
updated: 2026-11-18
author: vincent + claude
supersedes: []
superseded_by: null
related: ["librarian-lifecycle", "0517", "librarian-read-waits-and-shrinks-no-further-than-the-refusal-says", "0474"]
---

# Librarian 의 모델 호출은 제안만 하고, 반영은 Keeper 마다 하나인 쓰는 쪽이 기록 한 줄로 한다

## 0. 요약

durable Librarian 을 지우고 다시 만든다. 옛 Librarian 의 파일은 지우고 fresh state 로 설치한다. Memory 내용(`memory-current.json`)과 원본 턴은 남는다.

**바뀌는 것**

- Memory 를 바꾸는 일은 Keeper 마다 하나인 쓰는 쪽이 한다. 반영은 반영 기록에 fsync 한 한 줄이다. 그 줄에 Memory 변화, 읽은 자리, 하던 일, 출처가 같이 들어간다(§8).
- Librarian 의 모델 호출은 제안만 한다. 결과를 모르면 버리고 다시 묻는다. 보낸 요청을 기억하는 장치(원본, fence, 계보, resolution)가 없어진다(§3).
- 입력은 새 턴 기록이다. 턴 경로가 받아들일 때와 끝날 때 줄을 쓴다. 내용은 두 끝자리의 차라서 빠지는 턴이 없다. 오류로 끝난 턴과 죽은 턴도 닫힌다(§5).
- 질문은 slot 이 거절했을 때만, 거절이 말한 만큼만 줄인다. Memory 를 바꾸거나 내용을 지나치는 일은 선언한 slot 전부의 타입 있는 크기 사실이 있을 때만 한다(§7).
- Keeper 의 쓰기는 모델을 기다리지 않는다. 답을 기다리는 사이의 쓰기는 답 전체가 아니라 닿는 op 만 뺀다. 지금은 표본의 42% 를 통째로 버렸다(§8.3).
- 묻기는 턴 도착을 따라간다. 재생에서 턴이 닫힌 뒤 반영까지 p50 5~12분이다. 지금은 시간당 98개가 닫히고 4.9개가 반영된다(§15).
- 새로 들어온 것이 없으면 아무것도 읽지 않는다. tick 의 값은 앞선 기록의 길이와 무관하다(§16).
- checkpoint purge 는 Librarian 을 기다리지 않는다. 안 읽은 줄은 bundle 로 자기 내용을 읽는다. 지금은 읽기가 서면 purge 도 거절된다(§5.6).
- 읽기가 서 있는 곳은 모두 Keeper 행에 타입으로 보이고, 곳마다 나가는 길이 §9.4 에 있다.

**없어지는 것**

- `keeper_librarian_*` 69개 파일 24,061줄 가운데 대부분, Librarian add-on package 와 worker, admission 큐, 바깥 판정 gate, Memory 바이트 상한(§19).
- 디스크의 옛 Librarian 파일 전부. 목록은 §19.1 에 파일마다 있다.

**값**

- 하루 생성이 1,450~1,850번으로 지금의 12~16배다. GLM 요금제 한도와는 견주지 못했다(§15, §23).
- Librarian 호출은 Keeper 턴과 같은 계정의 자리를 약 14배 오래 잡는다. lane 의 slot 구성과 run limit 선언이 Keeper 턴의 대기를 가른다(§15.3).
- 반영 기록이 fleet 전체로 하루 약 27 MB 자란다(추정). 이 RFC 는 줄이지 않는다(§10).
- 컷 때 Keeper 의 창 밖에 있던 안 읽은 턴은 읽지 않는다. 옛 admission 큐에서 기다리던 쓰기는 없어진다(§22).
- 컷 이전에 지운 claim 의 기록(journal 134.8 MB, absorbed 24.3 MB)을 지운다. 컷 뒤에는 그 claim 을 다시 찾을 수 없다. 운영자가 2026-11-18 에 받아들였다(§22.1).
- 크기를 타입으로 말하지 않는 slot 이 lane 에 있으면, 어느 slot 에도 안 들어가는 항목 하나에서 읽기가 선다. 그 slot 이 거절로 답하면 오류(E4)가, 말이 없으면 경고(W1)가 켜진다. 코드에서 provider 쪽 넘침을 타입으로 만드는 backend 는 지금 GLM 하나다. 운영 lane 의 slot 마다 어떤지는 Agent-Core 층의 측정이 적는다(§7.7, §20).

**증명**

- 실패 열여섯과 사실 열여덟마다 장치 하나와 시험 하나(§13), 불변식 열다섯마다 모델 속성이나 시험(§14).
- 상태 표는 스크립트가 빠진 쌍을 잡는다. TLA+ 모델 셋은 정상 설정에서 속성을 지키고, 옛 규칙을 남긴 설정에서 그 속성을 어긴다(§21). 한 항목에서의 slot 별 판정은 모델에 없다(§21.5).
- 구현은 층마다 PR 하나인 stack 이다. 층마다 확인 방법이 있다. 옛 경로는 전환 층에서 한 번에 바뀐다(§20).

## 1. 지금

이력과 그 숫자의 근거는 [연구 기록](../research/2026-11-17-librarian-failure-history.md)에 있다.
이 설계가 쓰는 측정값은 [근거 폴더](../evidence/research/2026-11-18-librarian-rebuild-design/README.md)에 있다.
여기에는 결정에 쓰는 것만 옮긴다. 코드 사실은 2026-11-17 과 11-18 의 main 에서 읽었다(`8eb70b2ebece` 부터 `55a024cc280e` 까지). 줄 번호는 읽은 때의 것이다.

### 1.1 잰 값

- durable Librarian 은 `lib/keeper/keeper_librarian_*.ml` 69개 파일, 24,061줄이다.
- 2026-06-01 부터 11-17 까지 Librarian 경로에 커밋 785개가 들어갔다. 337개(43%)가 fix 다. revert 는 없다.
- Keeper 턴은 11-10 23:00 부터 11-17 23:00 까지 7일 동안 16,519개 끝났다. 한 시간 평균 98.3개다. 시간별로는 p50 99개, p90 169개다.
- 같은 때 durable Librarian 이 Memory 에 반영한 답은 한 시간에 약 4.9개다.
- GLM 의 durable 호출 하나는 중앙값 407초 걸린다. p90 은 660초, 최대는 936초다(11-15~11-18, 답을 받은 호출 185개).
  - 시간은 출력이 정한다. 출력은 약 24K token 이고 속도는 약 62 token/s 다(11-17 의 표본 19개).
  - 입력 크기와는 무관했다. 입력 1,014,803 token 짜리 호출도 523초였다(1건).
- 그 표본 19개 가운데 8개(42%)는 반영하지 못하고 버렸다. 답을 기다리는 사이 Keeper 의 명시적 쓰기가 Memory 를 바꿨다(`keeper_memory_os_current_program_apply.ml:290-297`).
- 24시간 동안 턴 기록 1,776개 가운데 289개(16.3%)가 끝 줄을 쓰지 않았다. 오류로 끝난 턴과 프로세스가 죽은 턴이다.
- 패스 하나는 18~50초 걸린다. 풀 작업 12~15개를 차례로 기다린다(11-17 운영 로그).
- 11-17 에 Librarian 선언을 두 번 바꾼 뒤 Keeper 약 20개의 읽기가 멈췄다.

### 1.2 구조

턴 하나가 Memory 에 닿기까지 지금은 이 길을 지난다.

1. Keeper 턴이 끝나면 경계 줄 하나를 쓴다(`turn-boundaries.jsonl`). 오류로 끝난 턴은 쓰지 않는다.
2. Keeper 마다 도는 consumer 가 패스를 연다. 패스는 보관한 요청 기록(원본, original)을 전부 나열하고, 읽을 범위를 atom 번호로 고른다.
3. 범위와 Memory 전체를 담은 원본을 저장하고 Lane Add-on 의 Exact worker 에 넘긴다.
4. worker 는 모델을 부르지 않는다. 본문을 fsync 하고 4 MiB 쪽 단위로 목록을 돌려준다. 모델은 서버가 부른다.
5. 답이 오면 정산(settle)하고, Memory 의 revision 이 원본을 만들 때와 같으면 반영한다. 다르면 답을 버린다.
6. Memory 를 쓴 뒤 읽은 자리를 옮긴다. 쓰기 함수 하나가 잠금 둘을 잡고 파일을 여덟 개까지 차례로 쓴다(`keeper_memory_os_current_update.ml:106-637`).
7. Keeper 는 다음 요청의 시작점을 Librarian 이 읽은 자리에서 잡는다.

단계마다 실패를 다루는 장치가 따로 붙어 있다. 원본, frontier, fence, 계보(lineage), resolution, gate, message floor, admission 큐, 선언 revision 이다.

## 2. 문제

실패 열다섯 가지와 그 근거는 연구 기록 §4 에 있다. 뿌리는 둘이다.

**뿌리 1. 패스 하나가 판단, 반영, 진행의 단위다.**

- 패스가 중간에 실패하면 그 패스 전체를 어떻게 할지 다시 정해야 한다. 그 결정이 다시 실패할 수 있어서 결정을 다루는 장치가 또 붙었다.
- 진행이 패스에 묶여 있어서 패스가 비용의 단위가 됐다. 패스마다 보관한 기록을 전부 나열하고 검증한다. 새로 들어온 것이 없어도 든다.

**뿌리 2. 「결과를 모르면 다시 부르지 않는다」는 규칙이 제안만 하는 호출에 걸려 있다.**

- 이 규칙은 같은 호출을 두 번 하면 비용이 두 번 드는 lane 에서 왔다. Exact 틀이 모든 소비자에게 건다.
- Librarian 의 모델 호출은 Memory 를 바꾸지 않는다. 바꾸는 것은 답을 받은 서버다. 다시 물어도 달라지는 것이 없다.
- 그런데 다시 묻지 못하니 「보냈는지 모르는 요청」을 영원히 들고 있어야 했다. 원본, fence, 계보, resolution, 선언 교체 장치가 여기서 나왔다.
- 11-17 의 정지가 이 모양이다. 보내기 전 상태로 남은 원본이 선언이 바뀐 뒤 어느 복구 경로에도 들지 않았다.

두 뿌리 밖의 문제가 셋 더 있다.

- 입력의 이름이 흔들린다. 읽은 자리가 atom 번호를 따르는데, purge 가 번호를 다시 매긴다. 경계 줄을 못 쓴 턴은 이름이 없다.
- 크기를 만들 때 맞추지 않는다. 본문이 4 MiB 중계를 지나다 거절되고, 거절된 뒤에 줄인다.
- Librarian 이 밀리면 Keeper 의 요청이 커진다. Keeper 요청은 Librarian 이 읽은 자리부터 싣는다([RFC-keeper-context-window-in-tokens](RFC-keeper-context-window-in-tokens.md) §1.1 의 결정이고, 이 RFC 는 그 결정을 바꾸지 않는다). 그래서 Librarian 이 도착을 못 따라가면 그 값을 Keeper 가 치른다. 요청 크기는 중앙값 714 KB, 최대 20.5 MB 였다.

## 3. 규칙

> Librarian 의 모델 호출은 제안만 한다. Memory 를 바꾸는 일은 Keeper 마다 하나인 쓰는 쪽이 기록 한 줄로 한다.

여기서 나오는 것은 셋이다.

- **다시 물어도 된다.** 호출에는 효과가 없다. 결과를 모르면 버리고 다시 묻는다. 보낸 요청을 기억할 것이 없다.
- **Memory 를 두고 다투지 않는다.** 쓰는 쪽이 하나다. Librarian 의 답, Keeper 의 명시적 쓰기, 운영자의 수정이 같은 문을 차례로 지난다.
- **재시작은 마지막 줄을 읽는 일이다.** 한 줄에 Memory 변화, 읽은 자리, 하던 일이 같이 들어간다. 반쯤 된 상태가 없다.

모르는 것은 그것이 생긴 곳에서 타입으로 확정한다. 안쪽 로직은 확정된 값만 받는다.

| 모르는 것 | 확정하는 곳 | 확정된 모양 |
|---|---|---|
| 턴이 무엇을 남겼나 | 턴 경로가 줄을 쓸 때 | 그 순간 입력 저장소들의 끝자리(mark). 내용은 두 끝자리의 차다 |
| 호출이 어떻게 끝났나 | Agent-Core 가 결과를 돌려줄 때 | 닫힌 타입 하나. 답, 크기에 대한 거절, 그 밖 |
| 질문이 창에 들어가나 | provider 가 셀 때 | 센 token 수나 타입 있는 거절 |
| Memory 가 내가 쓴 그대로인가 | 쓰는 쪽이 반영하기 직전 | 파일의 sha 가 마지막 줄의 값과 같다, 또는 멈춘다 |

## 4. 모양

Keeper 마다 fiber 하나가 Memory 를 쓴다. 턴 경로는 파일 하나에 줄을 덧붙이고, 나머지는 그 fiber 가 한다.

```text
Keeper 턴 경로 ──덧붙임──▶ turns.jsonl        Opened / Closed / Reset. 단위 = 두 끝자리의 차
                               │ 저장해 둔 offset 부터 읽는다
                               ▼
               ┌──── 쓰는 쪽: Keeper 마다 fiber 하나, <k>.memory.lock 을 쥔다 ────┐
Keeper·운영자 ─▶│ Write        ─▶ 직접 쓰기 반영                                    │
의 쓰기         │ Turn_closed  ─▶ 묻는 fiber: 질문 만들기 ─▶ slot 걷기              │
               │                   ◀── Ask_ended {result} ──                       │
               │ 반영 = <k>.memory-log.jsonl 한 줄, 그다음 memory-current.json      │
               └──────────────────────────────────────────────────────────────────┘
                               │ 메모리에 둔 view. boot 때 반영 기록의 마지막 줄로 다시 만든다
                               ▼
Keeper 요청 builder 와 health 가 읽는다: 읽은 자리, 그 끝자리, 하던 일
```

checkpoint purge 는 이 값을 읽지 않는다. 턴 기록의 마지막 단위 줄만 본다(§5.6).
object sweep 도 이 값을 읽지 않는다. 쓰는 쪽이 생기기 전에 돌아서 반영 기록의 꼬리 줄을 직접 읽는다(§5.6).

- **쓰는 쪽(writer)이 Keeper 마다 하나다.** Librarian 의 답, Keeper 의 쓰기, 운영자의 수정이 모두 여기를 지난다. 쓰는 쪽은 모델을 기다리는 동안 Keeper 경로가 쓰는 것을 쥐지 않는다.
- **질문은 Keeper 마다 한 번에 하나다.** 질문에는 Memory 전체, 하던 일, 안 읽은 단위(unit)가 들어간다. 단위는 끝난 턴 하나가 남긴 내용이다.
- **Librarian 은 같이 도는 질문 수를 정하지 않는다.** Keeper 마다 하나라서 Keeper 수를 넘지 않는다. provider 로 나가는 요청 수는 binding 이 선언한 자리(seat)가 묶는다. 자리를 잡는 방법은 「Exact 요청은 자리만 기다린다」 RFC(#52986)의 §3.1 을 따른다.
- **모델 호출은 서버 프로세스 안에서 한다.** `Agent_core.Exact_output.execute_flow_once` 를 직접 부른다. Librarian 은 Lane Add-on 틀에서 나온다. worker, 원본, 4 MiB 중계가 이 경로에서 없어진다.
- **Librarian 은 자기 lane 선언을 읽는다.** built-in lane 하나를 더한다(표 이름 제안: `[runtime.exact_output_lanes.librarian_memory]`). working-context pass 가 쓰는 `librarian_exact` 표와 나누지 않는다. 두 소비자는 질문도 출력 크기도 다르고, 운영자는 지금도 둘을 다른 slot 목록으로 선언한다.
- **반영(commit)은 fsync 한 한 줄이다.** 그 줄에 Memory 변화, 읽은 자리, 하던 일, 출처가 들어간다. `memory-current.json` 은 그 줄에서 다시 쓴다.
- **바깥 판정자는 반영 경로에 없다.** 줄에는 나중에 판정자가 볼 것이 남는다. 이 RFC 는 판정자를 만들지 않는다.

이 RFC 가 고치지 않는 것이다.

- Lane Add-on 틀과 그 틀을 쓰는 다른 소비자
- working-context pass 의 코드, 프롬프트, 호출
- 파일에 묶인 fact 의 저장소(`memory-source-current.json`)가 쓰고 읽는 규칙. 그 저장소가 부르던 크기 검사와 aggregate 잠금만 바꾼다(§11.6)
- fact 의 모양과 `memory-current.json` 의 codec
- provider 가 Keeper 요청을 크다고 거절했을 때 Keeper 쪽에서 시작점을 당기는 세 단계
- Memory 를 찾는 도구(`keeper_memory_search`, `keeper_memory_select`)의 입력 모양

## 5. 입력: 턴 기록

Keeper 마다 덧붙이기만 하는 파일 하나가 Librarian 의 입력에 이름을 붙인다.
`<keepers_dir>/<k>/turns.jsonl` 이고, 이 문서에서는 턴 기록이라고 부른다.
`turn-boundaries.jsonl` 을 대신한다. 새 빌드에는 옛 파일을 읽는 코드가 없다.

### 5.1 내용은 두 끝자리의 차다

끝자리(mark)는 한 순간에 입력 저장소들이 각각 어디서 끝났는지를 적은 값이다.
줄은 「이 턴에 무엇이 들었다」고 말하지 않는다. 그 줄이 본 끝자리를 적는다.
내용은 앞 끝자리와 이 끝자리 사이에 있는 것이다.

```ocaml
type mark =
  { trace : string; closed_messages : int                       (* Agent-Core 이력 *)
  ; session : string; history_bytes : int; internal_bytes : int (* official-client 파일 둘 *)
  ; chat_bytes : int; external_rows : int }                     (* 상대가 보낸 것 *)

type slice = { bundle : Sha256.t; skip : int; take : int }
type outcome =
  | Completed | Errored | Cancelled | Save_failed | Stale_save | Close_missing | Process_exited
type announced = Cleared | Recovered
type reset_cause = Announced of announced | Unannounced

type goal_shown = { goal : string; shown : string }   (* shown: 받아들일 때 Goal 쪽이 만든 글. phase 와 criterion *)
type task_evidence =
  | No_task
  | Task_source_unavailable
  | Task of { task : Task_id.t; goals : goal_shown list option }   (* None: 받아들일 때 Goal 을 읽지 못했다 *)
type stimulus = Board of board_item | Schedule of { schedule : string; occurrence : string } | ...
  (* event queue 의 갈래마다 생성자 하나. 그 항목의 id 와 항목이 실은 이름만 *)
type admission = { task : task_evidence; stimuli : stimulus list }

type turn_line =
  | Log_started of { id : Turn_log_id.t; at : float; mark : mark }
  | Opened of { at : float; turn_ref : Ids.Turn_ref.t; runtime : Runtime_id.t
              ; admission : admission; baseline : mark }
  | Closed of { turn : Turn_id.t; at : float; outcome : outcome; after : mark
              ; unattributed : slice list; own : slice list }
  | Reset of { at : float; cause : reset_cause; before : mark; after : mark
             ; closed_before : slice list }
```

- `closed_messages` 는 닫힌 메시지 수다. 마지막 segment 의 `segment_messages` 에 head 가 가진 턴들의 `messages` 를 더한다. 열린 메시지는 세지 않는다. 열린 메시지는 닫힌 뒤의 첫 단위에 든다(§5.2).
- 닫힌 턴 수는 쓰지 않는다. purge 가 메시지 하나를 다시 쓰면 그 뒤의 닫힌 턴이 모두 bundle 하나로 합쳐진다(`checkpoint_objects.ml:478-499, 590-615`). 턴 수는 바뀌고 메시지 수와 순서는 남는다.
- official-client 의 끝자리는 파일 길이가 아니라 마지막 줄바꿈의 offset 이다. 줄이 반만 쓰인 순간에 끝자리를 잡아도 그 줄이 둘로 갈리지 않는다.
- `Turn_id.t` 는 그 턴의 `Opened` 줄이 시작하는 바이트 offset 이다. 줄 번호를 쓰면 boot 때마다 파일 전체를 세어야 한다.
- `turn_ref` 는 턴 기록(turn record)과 요청 seed 를 잇는 열쇠다. 지금 `Turn_ended` 가 싣는 값이다.
- `slice` 는 bundle 하나에서 메시지 `skip` 개를 건너뛰고 `take` 개를 가리킨다. 줄을 쓰는 쪽이 그때 가진 head 를 보고 적는다. purge 뒤에는 bundle 하나가 두 단위의 메시지를 같이 담을 수 있어서, bundle digest 만으로는 범위를 가리키지 못한다.

- Task 는 턴을 받아들일 때 잡아서 `Opened` 에 적는다. `Closed` 는 싣지 않는다. `Opened` 를 못 쓴 턴에는 Task 가 없다.
- `stimuli` 는 턴이 Keeper 의 event queue 에서 받은 것이다. queue 가 준 순서대로 적는다.
  - queue 의 갈래마다 줄 타입이 하나다. queue 에 갈래가 생기면 바꾸는 함수가 컴파일되지 않는다.
  - 줄은 그 항목의 id 를 싣는다. 항목이 이름을 실었으면 그 이름도 싣는다. Board 글의 글쓴이, workspace 메시지를 보낸 agent, Task 를 취소한 Keeper, 맡긴 턴을 돈 Keeper 가 그렇다.
  - 이름은 만든 쪽이 적은 글이다. Keeper 등록부와 맞춰 보지 않았다.
  - 이름을 싣지 않는 갈래가 있다. connector 의 귀띔, HITL 판정, Ask 의 답은 id 만 싣는다. 보낸 이는 그 id 가 가리키는 행에 있다.
  - 내용은 싣지 않는다. id 가 가리키는 저장소에 있다.
  - 직접 요청으로 시작한 턴과 Keeper 의 cadence 로 시작한 턴은 비어 있다. 직접 요청의 메시지는 이력에 말한 이와 함께 있다.
  - 스스로 깬 official-client 턴은 깨운 문장을 이력 파일에 쓰지 않는다(`World_state_prompt`). 그 턴의 단위에는 답과 tool 관찰만 있다. 무엇이 깨웠는지는 이 칸만 말한다.

줄에 적은 digest 는 그 줄이 남아 있는 한 읽을 수 있다. head 가 나중에 어떻게 바뀌어도 같다.

코드의 타입은 `lib/keeper/keeper_turn_log.mli` 가 정한다. 위 묶음과 다른 곳은 다음이다.

- 턴 기록의 id 는 `Keeper_turn_log.Log_id.t` 다.
- `runtime` 은 runtime 선언의 id 글(`string`)이다.
- `Closed.turn` 은 `int` 다. 그 턴의 `Opened` 가 시작하는 바이트 offset 이다.
- `slice.bundle` 은 `Agent_core.Checkpoint_objects.digest` 다.
- `Opened` 는 `admission` 묶음 대신 `task` 와 `stimuli` 두 칸을 싣는다.

**줄은 이 모듈이 가진 타입, id, 글만 담는다.** 다른 저장소가 가진 타입의 값은 담지 않는다.
쓰는 쪽이 줄을 쓸 때 남의 값을 이 모듈의 타입으로 바꾼다. 바꾸는 함수는 모든 경우를 다룬다.

- 지금 `turn-boundaries.jsonl` 의 줄은 Goal 의 criterion 을 타입째 담는다. 11-18 에 criterion 모양이 바뀌자 옛 줄 137,969개 가운데 11,530개가 해석되지 않았다(#53018). Keeper 14개가 요청 seed 를 잃었고 Librarian 은 그 줄에서 멈췄다.
- 그래서 Goal 은 `goal_shown` 으로 적는다. 받아들일 때 Goal 쪽이 만든 글이다. 이 값을 읽는 것은 Librarian 의 질문뿐이고, 질문은 글을 싣는다.
- Goal 이나 Task 의 모양이 바뀌면 글을 만드는 함수가 바뀐다. 이미 쓴 줄은 그대로 읽힌다.
- 대가는 하나다. 줄에는 그 줄을 쓴 빌드가 만든 글이 남는다. criterion 을 타입으로 읽으려는 코드는 이 줄을 쓰지 못한다.
- 반영 기록도 같은 규칙을 지킨다. 줄이 담는 `Fact.t`, `Category.t`, `Basis.t`, `removal` 은 Memory 자신의 타입이다.

### 5.2 누가 언제 무엇을 덧붙이나

턴 기록은 턴 기록 모듈만 쓴다. 그 모듈을 부르는 곳은 턴 경로(받아들임, 끝남), 프로세스 시작 단계, head 를 줄이는 함수, purge, session 을 지우는 정지, 쓰는 쪽을 만들 때와 운영자의 `Resume` 때 하는 저장소 시작(§8.6)이다. Keeper 를 만드는 길은 턴 기록을 쓰지 않는다. 프로세스가 뜬 뒤 만든 Keeper 의 `Log_started` 는 첫 저장소 시작이나 첫 턴의 덧붙임 가운데 먼저 오는 쪽이 쓴다. Memory 를 쓰는 쪽(§9)은 이 파일을 읽기만 한다.
부르는 곳은 그 Keeper 의 owner 안이거나, Keeper 가 등록되지 않은 동안의 purge 이거나, 정지의 마무리 단계다. owner 안은 턴이거나 턴 사이의 idle maintenance 자리다. 정지의 마무리 단계는 그 Keeper 의 턴이 모두 끝난 뒤에만 돈다. 까닭은 문단 아래에 적었다. dashboard purge 는 Keeper 가 등록되지 않았을 때만 돌고 그 Keeper 의 lifecycle key lock 을 쥔다(`server_dashboard_http_keeper_api_checkpoints.ml:618-626`). CLI purge 는 서버가 workspace 를 쥐고 있으면 적용을 거절한다(`bin/masc_checkpoint_purge.ml:322`). 그래서 저장소 시작을 빼면, 한 Keeper 의 턴 기록을 쓰는 곳은 한 번에 하나다.

- 마무리는 `Joined_idle` 과 그 뒤의 phase 에서만 돈다. 그 앞의 phase 는 `Unsupported_phase` 로 거절한다(`keeper_shutdown_finalize.ml` 의 `run`).
- `Joined_idle` 을 쓰는 곳은 넷이다. 켜진 Keeper 의 정지는 owner 가 쉬고 lane fiber 가 끝난 뒤에 쓴다. 꺼진 Keeper 의 정지는 owner 가 쉬고 lane 이 없는 것을 본 뒤에 쓴다(`keeper_shutdown_prepare_join.ml`). 나머지 둘은 새 프로세스의 boot 복구다(`keeper_shutdown_runtime.ml`). 앞 프로세스의 턴은 이미 없다.
- `Prepared` 부터 `Cleanup_ready` 까지 admission fence 가 서 있다(`requires_admission_fence`). 그래서 그사이 새 턴도 받아들여지지 않는다.

저장소 시작만 다르다. owner 의 자리를 기다리지 않고 덧붙이는 helper 의 잠금만 잡는다. 쓰는 줄은 `Log_started` 하나이고, 파일에 완전한 줄이 없을 때만 쓴다. 턴의 덧붙임과는 아래의 끝 offset 규칙이 가른다.
덧붙일 때마다 꼬리를 읽고, 읽은 끝 offset 에서만 덧붙인다. 끝이 달라졌으면 꼬리를 다시 읽는다. 덧붙이는 helper 는 프로세스 안의 잠금과 프로세스 사이의 경로 잠금을 같이 잡는다.

| 때 | 덧붙이는 것 |
|---|---|
| 파일이 없거나 완전한 줄이 하나도 없다(프로세스 시작 때, 저장소 시작 때, 덧붙이기 직전) | `Log_started {id; mark}`. `id` 는 새로 만든다 |
| 턴을 받아들인다. 앞선 `Opened` 는 모두 닫혔다 | `Opened {baseline = 지금 끝자리}` |
| 턴을 받아들인다. 마지막 `Opened` 가 닫히지 않았다 | 한 번의 덧붙임으로 두 줄. `Closed {Close_missing}`, 그다음 `Opened`. 둘 다 들어가거나 둘 다 안 들어간다 |
| 받아들일 때 덧붙임이 실패한다 | 줄 없이 턴이 돈다. 카운터 `turn_log_append_failed` 가 오른다. 턴은 거절하지 않는다 |
| 턴이 끝난다(완료, 오류, 취소, 예외) | 닫는 저장을 한 뒤 `Closed {outcome; after = 지금 끝자리}`. 저장이 실패하면 `Save_failed`, 이 턴의 메시지가 이력에 없으면 `Stale_save` 다 |
| 끝날 때 덧붙임이 실패한다 | 더 하지 않는다. 다음 턴이나 다음 프로세스 시작이 닫는다 |
| `Opened` 를 못 쓴 턴이 끝난다 | 쓰지 않는다. 이 턴이 닫은 것은 다음 단위가 싣는다. 턴은 받아들일 때 쓴 `Opened` 의 offset 을 끝까지 들고 간다. 꼬리의 열린 `Opened` 가 그 offset 이 아니면 쓰지 않는다 |
| 프로세스가 시작한다. checkpoint 꼬리 복구가 끝났고 마지막 `Opened` 가 닫히지 않았다 | head 의 열린 메시지를 닫고(아래) `Closed {Process_exited}` 를 쓴다. Keeper 턴이 시작하기 전에 한다 |
| 제품 경로가 head 를 줄이거나 바꾸려 한다 | 먼저 `Reset {Announced _; before; after; closed_before}` 를 쓴다. 덧붙임이 성공한 뒤에만 head 를 바꾼다 |
| 줄을 쓰려는데 head 가 다른 trace 에 있거나, 마지막 끝자리보다 아래이거나, 해석되지 않는다 | 같은 덧붙임 안에서 자기 줄 앞에 `Reset {Unannounced; before = 그 끝자리; after = 지금 head 의 빈 끝자리}`. 까닭은 표 아래에 적었다 |

**열린 메시지는 닫힌 뒤의 첫 단위에 든다.** 끝자리는 닫힌 메시지만 센다. 열린 메시지는 닫힐 때까지 어느 줄에도 없다.

- 받아들임은 head 의 열린 메시지를 닫지 않는다. 턴 앞에서 head 에 열린 메시지를 두는 제품 경로가 있어서다.
  - Keeper 를 만들 때의 첫 저장(`keeper_turn_up_create.ml:288`).
  - 멈춘 턴을 잇는 저장(`keeper_direct_gate_continuation.ml:297`, `keeper_direct_checkpoint_continuation.ml:75`, `keeper_direct_runtime_continuation.ml:148`).
  - 입력을 기다린 답의 저장(`keeper_input_wait_response.ml:191`).
- 그 메시지는 받아들인 턴의 것이다. 그 턴의 닫는 저장이 닫고 그 턴의 `own` 에 든다. 받아들임이 닫으면 `baseline` 앞이 되어 Task 없이 실린다.
- 턴이 남긴 열린 메시지도 같은 길로 간다. 다음 턴의 닫는 저장이 닫고 그 턴의 `own` 에 든다. 그 메시지는 다음 턴의 Task 와 함께 보인다. 그런 때는 넷이다.
  - 턴의 닫는 저장이 실패했다. 그 턴의 줄이 `Save_failed` 라서 읽는 쪽은 그 사정을 안다.
  - 이력 지우기가 남길 메시지를 열린 채로 넣었다(§5.6).
  - `Opened` 를 못 쓴 턴이 도중에 저장하고 죽었다. 닫지 못한 `Opened` 가 없어서 프로세스 시작 단계가 닫지 않는다.
  - 프로세스 시작 단계의 닫는 저장이 실패했다. 카운터 `turn_log_open_close_failed` 가 오른다.
- 닫지 못한 `Opened` 가 있었으면 `Closed {Close_missing}` 의 `own` 은 그 턴의 닫는 저장이 닫은 것이다. 닫는 저장도 없었으면 비어 있다.
- 줄 앞에서 head 의 열린 메시지를 닫는 쪽은 둘이다. 마지막 `Opened` 가 닫히지 않았을 때의 프로세스 시작 단계와, head 를 줄이는 함수다. 열린 메시지가 있으면 닫는 저장(`Turn_closes`)을 한 번 하고 그 뒤에 끝자리를 읽는다. 없으면 저장하지 않는다.
- 프로세스 시작 단계가 닫는 것은 죽은 턴이 저장한 메시지다. `Closed {Process_exited}` 의 `own` 에 든다.
- head 를 줄이는 함수가 닫은 것은 `Reset` 줄의 `closed_before` 에 든다. 지우기와 recovering purge 가 버리는 메시지는 열려 있던 것까지 그 줄에 이름이 있다.
- 프로세스 시작 단계는 이 저장이 실패해도 그대로 간다. 줄은 쓰고, 남은 것은 다음 턴의 닫는 저장이 닫는다.
- head 를 줄이는 함수는 이 저장이 실패하면 줄을 쓰지 않고 거절한다. head 변경도 같은 저장소에 쓰는 일이라 어차피 실패한다.
- 값은 저장 한 번이다. 이력을 한 번 읽고 bundle 하나와 head 를 쓴다.
- 지금 boot 의 꼬리 복구는 마지막 tool 요청이 결과를 기다릴 때만 죽은 턴의 메시지를 닫는다(`keeper_transcript_tail_recovery.mli:14-15`). 그 밖에는 열린 채 남아 다음 턴의 `own` 에 든다. 지우기와 recovering purge 는 그것을 이름 없이 버린다.

reset 줄의 `after` 는 앞 줄의 `after` 에서, 그 경로가 바꾼 저장소의 값만 지금 값으로 바꾼 것이다.

**줄 쓰는 쪽이 본 `Unannounced` reset 의 `after` 는 지금 head 의 빈 끝자리다.** 그 trace 에 닫힌 메시지가 0 인 끝자리다. 다른 저장소의 값은 `before` 그대로다.

- 다음 단위는 지금 head 가 가진 닫힌 메시지를 처음부터 싣는다. `Opened` 를 못 쓴 턴이 새 head 에서 닫은 것도 빠지지 않는다.
- `after` 를 지금 끝자리로 두면 그 메시지들이 줄 없이 지나간다. 지우기 표의 「넣은 것은 다음 줄이 싣는다」와도 어긋난다.
- 대가가 하나 있다. head 가 앞부분을 그대로 둔 채 줄어든 것이었으면 그 앞부분이 한 번 더 든다. 알리지 않은 변경은 어느 쪽인지 가릴 수 없어서 빠뜨리지 않는 쪽을 고른다.
- 해석되지 않는 head 는 그 trace 의 빈 head 로 센다. checkpoint 버전이 바뀌어 옛 head 를 읽지 못하는 턴(`Saved_history_superseded`)이 여기 든다. 받아들일 때 이 줄이 쓰이고, 그 턴의 첫 저장이 head 를 새 이력으로 바꾼다. 그 턴이 닫은 것은 `own` 에 든다.
- head 를 읽다가 I/O 가 실패한 것은 해석되지 않는 것이 아니다. 그때는 줄 없이 턴이 돈다.
- 빈 끝자리 뒤에는 같은 head 가 그 아래일 수 없다. 그래서 이 줄은 되풀이되지 않는다.

head 를 줄이거나 없애는 제품 경로는 셋이다. 이력 지우기, 끊긴 곳 뒤를 버리는 purge, session 을 지우는 정지다. 셋 다 줄을 먼저 쓰고, 덧붙임이 성공한 뒤에만 head 를 건드린다.
앞의 둘은 함수 하나를 지난다. 그 함수는 head 변경이 거절할 수 있는 조건을 먼저 다 보고, 줄을 쓰고, head 를 바꾼다.

- 이력 지우기(`masc_keeper_clear`). 지금은 head 를 먼저 바꾸고 줄을 나중에 쓴다. 순서를 뒤집는다. 지우기는 턴 밖에서만 돈다. owner 의 idle maintenance 자리다. 지우기가 맨 먼저 바꾸는 것은 head 가 아니라 official-client 의 session 묶음이다(`clear_then`, `keeper_tool_surface.ml:406`). 줄은 그 앞에 쓴다. 코드의 갈래는 다섯이다(`keeper_history_clear.ml:143-160`).

  | 갈래 | 쓰는 줄 |
  |---|---|
  | head 가 있다 | `Reset {Announced Cleared; after = 지우기가 넣을 head 의 끝자리}`. 남기는 메시지는 열린 채로 들어가므로(`keeper_history_clear.ml:199`) 닫힌 메시지 수는 0 이다 |
  | head 가 없고 넣을 것이 있다 | 따로 쓰지 않는다. head 가 마지막 끝자리보다 아래면 위 표의 `Unannounced` 가 쓰인다. 넣은 것은 다음 줄이 싣는다 |
  | 해석 못 하는 head 를 치우고 새로 넣는다 | `Reset {Unannounced; before = 마지막 끝자리; after = 그 trace 의 빈 끝자리}`. 넣는 메시지는 열린 채 들어가서 새 head 의 끝자리가 빈 끝자리다. 그 head 에서 무엇이 닫혔는지 셀 수 없다. 지금은 줄을 쓰지 않는다 |
  | 해석 못 하는 head 를 치우기만 한다 | 위와 같은 줄 |
  | 바꿀 것이 없다 | 쓰지 않는다 |

  - 해석 못 하는 head 를 치우는 두 갈래의 줄은 session 을 지우는 정지의 줄과 같다. 줄 쓰는 쪽의 사건 하나를 셋이 쓴다.
  - 그 사건은 head 를 읽지 않는다. `before` 는 꼬리의 끝자리다. `after` 는 거기서 그 경로가 없애는 저장소의 값만 0 으로 바꾼 값이다. `closed_before` 는 비어 있다.
  - 지우기는 닫힌 메시지 수만 0 으로 바꾼다. official-client 파일 둘은 그대로 두기 때문이다(§5.6).
  - 매번 쓴다. 마지막 줄이 이미 같은 줄이어도 쓴다. 까닭은 정지와 같다(아래).
- 끊긴 곳 뒤를 버리는 purge(recovering purge). 규칙은 `keeper_checkpoint_purge.ml:391-428` 에 있다. dashboard(`server_dashboard_http_keeper_api_checkpoints.ml:612`)와 CLI(`bin/masc_checkpoint_purge.ml:251`) 두 군데서 들어온다. `Announced Recovered` 를 쓴다. 지금은 두 진입이 head 를 다르게 넣는다. dashboard 는 compare-and-swap 이고 CLI 는 watermark 저장이다. 함수 하나를 지나게 하면서 CLI 를 compare-and-swap 으로 옮긴다.
- session 을 지우는 정지(`remove_session`, `keeper_shutdown_finalize.ml:609`). head 와 그 trace 의 object 를 디렉터리째 지운다. 지금은 줄을 쓰지 않는다. 지우기 전에 `Reset {Unannounced; before = 마지막 끝자리; after}` 를 쓴다.
  - 그 디렉터리에는 official-client 파일 둘도 있다. 그래서 정지의 `after` 는 닫힌 메시지 수와 `history_bytes` 와 `internal_bytes` 가 모두 0 이다. chat 과 external 의 값은 `before` 그대로다.
  - 정지는 이 줄을 매번 쓴다. 위 표의 줄은 head 가 마지막 끝자리 아래일 때만 쓰인다. 정지는 head 를 없애는 쪽이라 마지막 끝자리가 이미 비어 있어도 쓴다.
  - 덧붙임이 실패하면 지우지 않는다. 정지는 그 단계가 실패했다고 알린다.
  - 줄을 쓴 뒤에 지우지 못했거나 그사이 프로세스가 죽으면 head 와 official-client 파일이 남는다. 다음 단위는 `after` 에서 시작해 그 이력과 그 파일의 내용을 한 번 더 싣는다.
  - 버리는 내용은 디렉터리와 함께 없어진다. 그래서 조각으로 가리키지 않는다. 읽는 쪽은 그 줄을 `Unknown_span` 으로 적는다(§5.4).
  - 다음에 줄 쓰는 쪽이 수를 보고 알아내게 두지 않는다. 마지막 끝자리가 0 이면 빈 head 가 그 아래가 아니다. `Opened` 를 못 쓴 턴이 그 뒤에 head 를 같은 수까지 다시 키울 수도 있다. 두 경우에 구멍이 기록 없이 지나간다.

head 를 줄이지 않는 것은 이 함수를 지나지 않는다. 고쳐 쓰기만 하는 purge, 턴의 닫는 저장, 응답을 버린 뒤의 턴 안 저장, boot 의 꼬리 복구, dashboard 의 스냅샷 파일 지우기가 그렇다. 닫는 저장과 턴 안 저장은 열린 메시지만 바꾸고, 끝자리는 닫힌 메시지만 센다. 고쳐 쓰기만 하는 purge 는 닫힌 메시지를 줄이지 않는다(§5.6).

이 함수가 도는 동안 그 Keeper 의 턴은 받아들여지지 않는다. `Reset` 줄부터 head 변경이 돌아올 때까지다. 들어오는 길은 넷이고 턴을 막는 방법이 다르다.

- 지우기는 턴과 같은 자리에서 돈다. owner 의 턴 자리(`turn_in_flight`)는 하나이고 비었을 때만 찬다. 지우기는 그 자리를 쥔 maintenance 로 돌고(`run_maintenance_if_idle`), 턴이 돌고 있으면 아무것도 건드리지 않고 `Busy` 로 끝난다.
- dashboard purge 는 등록되지 않은 Keeper 에서만 돌고 lifecycle key lock 을 쥔다. Keeper 를 등록하는 쪽이 같은 잠금을 잡는다. 턴은 등록된 Keeper 에서만 시작한다. 등록에서 빠진 Keeper 에 도는 턴이 남지 않는지는 빼는 곳 여섯을 다 읽지 못했다(§23.2).
- CLI purge 는 head 를 읽기 전부터 workspace lease 를 쥔다. 서버는 그 lease 를 사는 동안 쥐고, 턴은 서버 안에서만 돈다.
- 정지는 `Joined_idle` 뒤에만 돌고 그사이 admission fence 가 서 있다(위).

**줄을 쓴 뒤에 head 변경이 일어나지 않으면.** 변경이 오류를 돌려준 경우와, 줄과 변경 사이에서 프로세스가 죽은 경우가 있다. 지우기에는 줄 뒤에 실패할 수 있는 단계가 여덟 개 넘게 있다. 두 경우는 디스크에서 똑같이 보인다. `Reset` 줄이 있고 head 는 그대로다.
이 경우를 가리지 않는다. 다음 단위는 언제나 그 줄의 `after` 에서 시작한다.

- 변경이 일어났으면 head 는 `after` 에서 자란 것이다. 그대로 맞다.
- 일어나지 않았으면 head 는 `before` 에 있다. `after` 와 `before` 사이의 메시지가 다음 단위에 한 번 더 든다. 건너뛰는 것은 없다.
- 지우기에서는 그 사이가 Keeper 가 들고 있던 이력 전체다. 그만큼을 lane 의 값으로 한 번 더 읽는다. Keeper 가 그사이 철회한 claim 이 다시 들어올 수 있다.
- 이 일은 줄을 쓴 뒤에 head 저장이 실패하거나 프로세스가 죽어야 생긴다. 함수가 거절할 수 있는 조건은 줄 앞에서 다 본다.
- 수로는 가리지 못한다. `Opened` 를 못 쓴 턴이 그사이에 돌 수 있고, 지운 뒤의 head 가 `before` 를 넘게 다시 자랄 수 있다. 내용으로 가리는 값을 줄에 싣지 않은 까닭은 §22.4 에 적었다.
- 그 `Reset` 단위를 읽은 반영은 `covered` 를 `after` 에 둔다. 한 번 더 읽기가 끝날 때까지 Keeper 요청은 seed 에서 시작한다(§11.2).

줄을 쓴 뒤에는 함수에 오류 갈래가 없다. 실패한 head 변경과 kill 을 같은 경우로 둔다.

**meta 를 치우고 Keeper 를 다시 만들면.** boot 때 Keeper meta 를 옆으로 치우고 같은 이름으로 다시 만들면, 새 trace 옆에 옛 턴 기록이 남는다. 알리는 경로를 따로 두지 않는다. 처음 줄을 쓰는 쪽이 head 가 다른 trace 에 있는 것을 보고 `Unannounced` 를 쓴다. 구멍은 옛 head 에서 마지막 줄 뒤에 닫힌 것이고, 턴이 끊기지 않았으면 비어 있다.

- 이 경로는 실제로 있다. Keeper 만들기는 그 Keeper 의 턴 기록과 Memory 파일을 읽지 않는다. 옛 파일이 남아 있어도 거절하지 않는다.
- 만들기가 거절하는 때는 넷이다. meta 가 이미 있을 때, lifecycle 예약이나 정지의 intake fence 가 있을 때, `create_only` 인데 선언된 config 가 있을 때, 새로 만든 trace 디렉터리가 이미 있을 때다(`keeper_turn_up.ml`, `Keeper_owner_registry.create_meta`, `Keeper_input_birth.reserve_session`).
- 그래서 다시 만든 Keeper 는 같은 이름의 턴 기록과 Memory 를 이어 쓴다.

읽는 쪽이 받아들이는 순서는 이것 하나다.

```text
Log_started · ( Reset | Opened · Reset* · Closed )*    끝은 Opened · Reset* 일 수 있다(도는 턴)
```

쓰는 규칙으로는 이 밖의 순서가 나오지 않는다. 닫지 못한 `Opened` 는 다음 받아들임이 한 번의 덧붙임 안에서 닫으므로 `Opened · Opened` 가 디스크에 놓이지 않는다.
읽는 쪽의 순서 규칙(`Keeper_turn_log.step`)은 하나를 더 본다. `Opened` 뒤에 `Reset` 이 있었던 턴의 `Closed` 가 `own` 을 실으면 거절한다(§5.3).

### 5.3 단위

**`Closed` 줄과 `Reset` 줄이 각각 단위(unit) 하나다.**
단위의 내용은 그 줄의 끝자리와, 그 앞에서 가장 가까운 단위의 끝자리 사이다.

| 줄 | 여기까지 | 다음 단위는 여기서부터 |
|---|---|---|
| `Log_started` | – | `mark` |
| `Closed` | `after` | `after` |
| `Reset` | `before` | `after` |

- `Opened` 는 이 점을 옮기지 않는다.
- 규칙은 저장소 넷에 똑같다. Agent-Core 메시지, official-client 의 두 파일, chat 바이트, 외부 행이다. 그래서 `Closed` 와 다음 `Opened` 사이에 쓰인 것은 다음 단위에 든다.
- `Closed` 는 Agent-Core 범위를 `baseline` 에서 둘로 나눈다. 앞쪽이 `unattributed`, 뒤쪽이 `own` 이다. 그 턴의 `Opened` 뒤에 `Reset` 이 있으면 나누지 않고 전부 `unattributed` 다. 그 범위는 그 턴이 쓴 것이 아니다. 일어나지 않은 head 변경을 한 번 더 읽는 것이거나 지우기가 남긴 것이다.
- `baseline` 앞의 것은 Task 없이 보여 준다. `Reset` 단위도 Task 없이 보여 준다. 옛 턴이 다른 턴의 Task 를 빌리지 않는다. 받아들일 때 열려 있던 메시지와 턴이 남긴 열린 메시지는 예외다. 어느 단위에 들고 Task 가 붙는지는 §5.2 가 정한다.
- `Close_missing` 이나 `Process_exited` 로 닫힌 턴의 `own` 은 「이 턴이 닫았다」가 아니라 「이 턴을 받아들인 뒤에 닫혔다」는 뜻이다. 질문에 그렇게 적는다.

이 규칙이면 어느 head 가 닫은 메시지든 빠지지 않고 단위에 든다. 줄을 못 쓴 턴이 닫은 것, 늦게 들어온 저장, 꼬리 복구가 닫은 것도 같다.
두 번 드는 것은 셋뿐이다. 지우기가 남긴 System 메시지(§5.6)가 하나다. 줄을 먼저 쓴 head 변경이 일어나지 않았을 때 그 줄의 `after` 와 `before` 사이가 둘이다. 알리지 않고 줄어든 head 가 그대로 둔 앞부분이 셋이다(§5.2). 지우기, recovering purge, session 을 지우는 정지가 줄을 먼저 쓴다(§5.2).

단위 안의 것은 항목(item)으로 센다. 상대가 보낸 행이 먼저고 메시지가 그다음이다.
보이는 순서는 `unattributed` 다음 `own` 이고, 구간 안은 chat 행, 외부 행, Agent-Core 메시지(slice 순서), official-client history 행, internal 행이다.
항목의 이름은 `{ line; index }` 다. `line` 은 그 단위의 줄이 시작하는 바이트 offset 이다.
순서는 줄이 정한다. 그래서 bundle 하나가 없어지거나 돌아와도 번호가 밀리지 않는다.

`Announced` reset 인데 그 앞에 닫힌 것이 없으면 항목이 없는 단위다. 항목 없는 단위는 따로 묻지 않고 다음 반영과 같이 지나간다.

### 5.4 안 읽은 것과 읽지 못하는 것

쓰는 쪽은 다 읽지 않은 첫 줄의 바이트 offset(`turn_log_offset`)을 반영 기록에 적는다(§8). 첫 boot 의 `Started` 에서는 0, 곧 `Log_started` 줄이다. 반쯤 읽은 단위에서는 그 단위의 줄이고, `covered` 는 그 단위가 시작하는 자리다.

끝자리의 official-client 바이트 둘은 그 끝자리 `session` 의 파일을 잰다. `session` 은 trace id 이고 새 trace 의 디렉터리는 비어서 시작한다. 그래서 한 단위의 시작 끝자리가 끝 끝자리와 다른 session 을 가리키면, 끝 session 의 두 파일을 0 부터 읽는다. 줄 쓰는 쪽의 `Unannounced` reset 은 `after` 에 옛 `session` 과 옛 바이트를 그대로 둔다. 그 어긋남과 쓰는 쪽에서 고칠 방향은 이슈 #53570 에 있다.
읽는 쪽은 거기서부터 읽는다. 첫 줄부터 훑는 일은 없다.
턴 안에서 읽기 시작하면 그 턴의 `Closed` 가 가리키는 `Opened` 부터 그 `Closed` 앞까지만 다시 읽는다. Task, runtime, `baseline` 과, 그 사이에 `Reset` 이 있는지를 거기서 얻는다. 그래서 같은 단위는 몇 번째 읽기든 똑같이 나뉜다.
읽는 쪽은 해석하지 못하는 줄이나 `Unannounced` reset 을 만나면 거기서 멈춘다. 그 앞에 항목이 든 단위가 있으면 그것을 평소대로 먼저 묻는다.

`Unannounced` reset 은 「그사이에 무엇이 닫혔는지 모른다」는 줄이다. 줄을 쓰는 쪽이 head 가 다른 trace 에 있거나, 마지막 끝자리보다 아래이거나, 해석되지 않는 것을 보고 쓴다. session 을 지우는 정지도 쓴다(§5.2).
그 줄 앞에 항목이 든 단위가 없으면 쓰는 쪽은 모델을 부르지 않고 `Skip (Unknown_span {before; after})` 을 반영한다. 앞에 놓인 항목 없는 단위는 같이 지나간다(§9.2).
지금은 줄 없이 지나가는 일이다.

질문을 만들다가 내용이 없는 것을 알게 되면 있는 항목만 읽고, 없는 것은 반영 줄에 적는다.

```ocaml
type range = { from : int; until : int }      (* 두 끝자리의 값: 바이트, 외부 저장소는 행 *)
type missing_part =                             (* 줄이 부르는 대로 부른다 *)
  | Bundle of slice | History_bytes of range | Internal_bytes of range | Chat_bytes of range
  | External_rows of range
  | Undecodable_history_line of { offset : int } | Undecodable_internal_line of { offset : int }
  | Undecodable_external_row of { row : int }

type input_fault =
  | Line_unreadable of { offset : int }               (* 해석되지 않는 줄이고, 그 앞에 항목이 든 단위가 없다 *)
  | Turn_log_replaced of { expected : Turn_log_id.t; observed : Turn_log_id.t option }
  | Position_lost of { offset : int; length : int }   (* 같은 id 인데 offset 이 끝을 넘거나 줄 시작이 아니다 *)
  | Content_unreadable of { line : int }              (* bundle 이 있는데 지금 읽히지 않는다 *)
```

- 읽을 항목이 하나도 없는 범위는 `Skip (Content_missing _)` 으로 지나간다.
- 읽는 쪽은 결함을 정해진 순서로 본다. 턴 기록의 id, 저장한 offset, 줄 해석이다.
- `Line_unreadable` 은 운영자의 `Skip_line` 으로 지나간다. 해석 안 되는 줄이 `Opened` 였으면 그 턴의 `Closed` 는 Task 없이 읽는다.
- `Turn_log_replaced` 와 `Position_lost` 는 운영자의 `Restart_reading` 으로 나간다. 그 파일을 처음부터 읽는다. 복원한 파일이면 전에 읽은 것을 한 번 더 읽는다.
- 턴 기록의 결함은 Memory 쓰기를 멈추지 않는다. 읽기만 쉰다(§9).

제품 밖에서 손으로 한 수정 가운데 보이지 않는 것이 셋 있다. 적어 두는 한계다.

- 손으로 바꾼 head 가 다음 줄이 쓰이기 전에 마지막 끝자리를 넘게 자랐다. 줄 쓰는 쪽은 그것을 자란 것으로 읽는다.
- 되돌려 놓은 턴 기록이 저장한 offset 을 넘게 자라 있고 그 offset 이 줄 시작이다. 다른 줄부터 읽고 결함은 뜨지 않는다.
- 턴 기록을 같은 길이의 다른 파일로 바꿨다. `Idle` 의 pulse 는 길이만 본다. 다음 줄이 쓰일 때까지 모른다.

### 5.5 질문에 어떻게 싣나

- tool 호출은 id 와 이름만 남긴 표시로 싣는다. tool 결과는 id 와 결과 종류만, tool 관찰은 `{index, tool_name, outcome}` 만 싣는다. 지금 재는 줄임과 같다.
- 상대가 보낸 행은 저마다 자기 보낸 이를 타입으로 싣는다. 턴을 깨운 것(stimulus)은 갈래와 id, 그리고 queue 항목이 실은 이름을 싣는다(§5.1).
- 단위마다 턴 id, 닫힌 시각, runtime, outcome, 그리고 자기 `Opened` 의 Task 를 싣는다. Goal 은 `shown` 의 글 그대로다.

### 5.6 purge 는 Librarian 을 기다리지 않는다

지금 purge 는 Librarian 이 안 읽은 atom 이 있으면 거절한다(`Unread_atoms_present`). 읽기가 밀리거나 서 있으면 Keeper 의 이력을 고쳐 쓸 수 없다. context 가 찬 Keeper 에게는 purge 가 출구인데, 그 출구가 Librarian 에 묶여 있다. 이 묶음을 없앤다.

안 읽은 내용은 purge 가 건드리지 못하는 곳에 있다.

- 줄은 자기 내용을 bundle 의 조각으로 가리킨다. bundle 의 이름은 내용의 sha 다.
- purge 는 object 를 지우지 않는다. 새 bundle 과 새 head 를 쓴다.
- object sweep 은 `turn_log_offset` 뒤의 줄이 가리키는 bundle 을 모두 뿌리로 잡는다. offset 을 쓰는 조건은 아래에 있다.

그래서 안 읽은 줄은 그 줄을 쓸 때의 내용을 그대로 읽는다. purge 가 그 뒤에 메시지를 고쳐 써도 같다.
고쳐 쓰기만 하는 purge 가 망가뜨릴 수 있는 것은 아직 어느 줄도 가리키지 않는 메시지뿐이다. 두 가지다. 닫는 저장은 끝났는데 단위의 줄이 아직 없는 닫힌 메시지, 그리고 열린 메시지다. 턴이 도중에 저장하고 죽으면 열린 메시지가 남는다. 아래 규칙은 그 둘을 지킨다.
끊긴 곳 뒤를 버리는 purge 는 head 를 줄이는 함수를 지난다. 열린 메시지를 닫고, 버리는 것을 줄에 먼저 적는다(§5.2).

**고쳐 쓰기만 하는 purge 는 마지막 단위 줄의 끝자리 아래에 있는 메시지만 고쳐 쓴다.** 끝자리를 메시지 목록의 번호로 읽는다. 단위 줄은 `Closed` 와 `Reset` 이고, 둘 다 없으면 `Log_started.mark` 다. `Reset` 줄에서는 `after` 다(§5.3).

- 그 끝자리 위의 닫힌 메시지와 열린 메시지는 모두 바이트 그대로 둔다. 다음 단위가 그것을 실은 뒤의 purge 가 고친다.
- 지금 purge 는 메시지 목록 전체를 닫힘과 열림의 구분 없이 고치고, 저장할 때 열린 메시지를 닫는다(`Turn_closes`). 지금은 `Unread_atoms_present` 가 「저장하고 죽은 턴」을 막는다. 그 거절을 지우는 대신 이 규칙이 같은 것을 지킨다.
- purge 의 저장이 열린 메시지를 닫으면 닫힌 메시지의 수가 그만큼 는다. 그 메시지의 바이트는 같으므로 다음 단위가 같은 내용을 싣는다. 수가 줄지는 않는다.
- head 가 다른 trace 에 있거나, 그 끝자리보다 아래이거나, 해석되지 않으면 purge 도 줄 쓰는 쪽이다. `Reset {Unannounced}` 를 먼저 쓴다(§5.2). 그 덧붙임이 실패하면 아무것도 고쳐 쓰지 않는다.
- 어느 메시지가 atom 을 여는지는 지금처럼 그대로 둔다. Keeper 요청의 시작점은 수로 찾는다(§11.2).
- CLI purge 는 head 를 읽기 전에 workspace lease 를 잡는다. 지금은 읽고 계산한 뒤에 잡는다.
- purge 는 반영 기록을 읽지 않고, 쓰는 쪽에 묻지 않는다. 쓰는 쪽이 `Stopped` 이거나 없어도 돈다.
- 턴 기록이 없는 Keeper(사람 Keeper)의 purge 는 지금과 같다.

```ocaml
type purge_refused = Turn_log_unwritable of io_error
```

- 끊긴 곳 뒤를 버리는 purge 는 head 를 줄이는 쪽이다(§5.2). 열린 메시지를 닫고 줄을 쓴 뒤에 버린다. 버린 메시지는 닫혀 있던 것이든 열려 있던 것이든 안 읽은 줄이 가리키는 bundle 로 계속 읽힌다. 깨진 head 를 가진 Keeper 가 Librarian 을 기다리는 일이 없다.
- object sweep 은 프로세스가 시작할 때 한 번, 쓰는 쪽이 생기기 전에 돈다(`bin/main_eio.ml:350`). 그래서 sweep 은 `turn_log_offset` 을 반영 기록의 꼬리 줄에서 직접 읽는다.
- 그 offset 은 꼬리 줄의 `turn_log` 가 턴 기록 파일의 id 와 같고, offset 이 그 파일의 줄 시작일 때만 쓴다. 아니거나 꼬리 줄을 읽지 못하면 턴 기록의 모든 줄이 가리키는 bundle 을 뿌리로 잡는다.
- 턴 기록을 읽지 못하면 sweep 은 아무것도 지우지 않고 끝난다. 뿌리로 읽을 줄 하나가 해석되지 않아도 같다. 지금 읽지 못하는 head 를 만났을 때와 같다(`keeper_checkpoint_object_sweep.mli:17-23`).
- 줄의 bundle 은 그 줄의 trace 가 가리키는 session 에 뿌리로 잡는다. `Closed` 는 `after.trace`, `Reset` 은 `before.trace` 다.
- sweep 은 턴 기록이 있는 Keeper 디렉터리를 모두 읽는다. Keeper 가 켜져 있든 꺼져 있든 같다.
- Keeper 를 멈추면서 session 을 지우면(`remove_session`) head 와 그 trace 의 bundle 이 함께 없어지고 턴 기록은 남는다. 정지가 지우기 전에 `Unannounced` 줄을 쓴다(§5.2). 그 앞의 안 읽은 단위는 `Content_missing` 으로 적힌다.
- 이력 지우기는 그 trace 의 옛 object 와 `covered` 뒤의 fragment 바이트를 그대로 둔다.
- 지우기가 남기는 System 메시지는 열린 채로 들어간다. 다음 턴의 닫는 저장이 닫고, 그 메시지는 한 번 더 읽힌다.

이 규칙의 값은 디스크다. 안 읽은 줄이 가리키는 bundle 은 읽힌 뒤 첫 프로세스 시작까지 남는다. Librarian 이 많이 밀린 Keeper 는 purge 를 해도 그만큼의 옛 bundle 을 그대로 갖고 있다. purge 가 바꿔 놓은 object 는 지금처럼 다음 시작 때 지워진다.

### 5.7 컷 직후의 첫 단위

`Log_started.mark` 는 그 Keeper 가 마지막으로 provider 에게 받아들여진 요청의 시작점이다. 그 시작점이 지금 이력에서 풀리지 않으면 이력의 끝이다.
첫 턴이 닫히면 그 끝자리와의 차가 첫 단위가 된다. 그래서 첫 질문은 Keeper 가 지금 창에 들고 있는 것을 읽는다.
그 밖, 곧 컷 때 이미 Keeper 의 창 밖에 있고 읽히지 않은 것은 읽지 않는다(§22).

## 6. 질문과 크기

질문(question)은 모델에게 보내는 요청 하나다. 이 절은 질문에 무엇이 어떤 순서로 들어가는지와, 크기를 누가 재는지를 정한다.

### 6.1 질문 세 가지

```ocaml
type ask =
  | Read_range of width                 (* 읽은 자리부터 폭만큼. Memory 를 보여 준다 *)
  | Read_item_alone of item_ref         (* 맨 앞 항목 하나. Memory 를 보여 주지 않는다 *)
  | Make_room of { after : item_ref }   (* Memory 만 보여 준다. 항목은 없다 *)
```

| 순서 | 들어가는 것 | `Read_range` | `Read_item_alone` | `Make_room` |
|---|---|---|---|---|
| 1 | Librarian 프롬프트 | ○ | ○ | ○ |
| 2 | 첫 줄 `question: <앞 절반>` | ○ | ○ | ○ |
| 3 | 지금 Memory. fact 마다 `m1 … mN` 이름, claim, category, basis, `first_seen`, `last_seen` | ○ | – | ○ |
| 4 | 하던 일(working state). 마지막 반영 줄의 글 | ○ | – | ○ |
| 5 | 단위들. §5.5 대로 싣는다 | ○ | 항목 하나 | 「방금 읽은 항목이 Memory 와 함께는 들어가지 않았다」 한 문장 |
| 6 | 끝 줄 `question-end: <뒤 절반>` | ○ | ○ | ○ |

- 순서는 고정이다. 같은 Memory 에 폭만 다른 질문은 1~4 가 같아서 provider 캐시가 앞부분을 다시 쓴다.
- fact 는 71자 id 대신 `m1 … mN` 으로 가리킨다. 단위도 질문이 붙인 짧은 이름으로 가리킨다. 지금은 답이 긴 id 를 옮겨 적다가 틀려서 답 전체가 거절됐다.
- 질문 id 는 반쪽 둘이다. 앞 절반은 `sha256(선언, 그 질문이 싣는 Memory 바이트와 하던 일)` 의 반이고, 뒤 절반은 `units:` 줄 바이트 sha256 의 반이다. 두 반쪽은 본문을 나눠 덮는다. 그래서 Memory 만 바뀌면 앞 절반만 바뀐다. 답은 둘 다 되돌려 적는다.
  - 항목만 싣는 질문의 id 는 Memory 가 바뀌어도 같다. 그래야 그 질문에 대한 크기 사실(§7.4)이 직접 쓰기마다 버려지지 않는다.
  - 입력의 앞이나 뒤를 잘라 받는 slot 은 잘린 쪽 절반을 적지 못한다. 그 답은 `Echo_mismatch` 로 버린다.
- 질문은 (선언, Memory 바이트, 하던 일, 단위, 폭)의 순수 함수다. 시각이나 카운터를 싣지 않는다. 같은 입력에서 같은 바이트가 나오는지를 묻기 층의 시험이 고정한다. 읽는 것이 모두 이미 디스크에 있다. 그래서 보내기 전에 따로 저장할 것이 없다(`persist_before_model_call`).
- Memory 바이트는 걷기를 시작하기 전에 읽는다. 자리를 기다린 만큼 오래된 Memory 로 답이 만들어질 수 있다. 그사이의 직접 쓰기는 §8.3 이 다룬다.

### 6.2 답

```ocaml
type new_fact = { claim : string; category : Category.t; observation : Observation.t; from_units : string list }
type op =
  | Add of new_fact
  | Drop of { ref_ : string; reason : string }
  | Merge of { refs : string list; into : new_fact }
  | Revise of { ref_ : string; into : new_fact }
type answer = { question : Question_id.t; ops : op list; working_state : Keep | Set of string }
type rejection = Not_json | Schema_violation of wire_error | Echo_mismatch | Empty_or_partial
```

- 답은 바뀌는 것만 적는다. 답이 이름 붙이지 않은 fact 는 그대로 남는다.
- 답 전체를 버리는 이유는 `rejection` 넷뿐이다. op 하나의 흠은 그 op 만 반영하지 않고 줄에 적는다(§8.2).
  - 그 op 만 빼는 흠은 이름과 상태의 흠이다. 표에 없는 이름, 앞의 op 가 이미 쓴 이름, 그사이 지워진 fact 다. 계획이 본다.
  - 모양의 흠은 다르다. 모르는 op 이름, 빈 claim, 모르는 category, 파생 basis, `Merge` 하나의 `refs` 안에 두 번 적은 이름은 `Schema_violation` 이고 답 전체를 버린다. 모양이 틀린 답의 나머지를 믿을 근거가 없다.
- 답의 새 fact 는 관측한 것만이다. 대화에서 읽었거나 Board 에서 읽었다. 파생 fact 는 Keeper 의 직접 쓰기(§8.5)만 만든다. 지금과 같다.
- wire 모양은 `lib/librarian/librarian_answer.mli` 가 정한다. object 마다 field 집합이 정확히 맞아야 한다. 새 fact 의 `basis` 는 Memory 에 실린 fact 의 `basis` 와 같은 모양이다. 모델은 읽은 모양대로 쓴다.
- 답 글은 JSON 문서 하나다. code fence 나 앞뒤의 말이 붙으면 `Not_json` 이다. 고쳐서 읽지 않는다. slot 이 그렇게 답하는 비율은 채점기가 알린다.
- 검사 순서는 고정이다. 문서의 field 집합, 되돌려 적은 반쪽 둘이 문자열인가, 그 반쪽이 물은 질문의 것인가, 그다음이 하던 일과 op 다. 다른 질문의 답은 다른 흠이 있어도 `Echo_mismatch` 다.
- `Empty_or_partial` 은 빈 글이다. provider 가 중간에 끊은 답은 묻기 층이 이 값으로 바꾼다. 끊긴 것을 아는 곳이 거기다.
- 답이 적은 이름(`m3`, 단위 이름)은 codec 이 그대로 둔다. 질문의 표에 없는 이름은 계획이 그 op 만 빼는 이유다(§8.2).
- `Read_item_alone` 의 답에서는 `Add` 와 `working_state = Keep` 만 받는다. 그 밖은 반영하지 않고 `Not_valid_alone` 으로 줄에 적는다. Memory 와 하던 일을 보지 않은 답이 그것을 지우거나 갈아 쓸 수는 없다. 하던 일을 바꾸려 한 것은 op 가 아니어서 계획이 따로 돌려준다(`working_state = Not_valid_alone`).

### 6.3 크기는 provider 가 잰다

| 값 | 어디서 오나 | 종류 |
|---|---|---|
| slot s 의 창 W(s) | `Runtime_instance.resolve_max_context_of_runtime` (binding, provider, model, capability catalog 순) | 운영자 선언 |
| 출력 몫 R | lane 의 `max_output_tokens`. 켠 lane 은 반드시 적는다(§6.4). HTTP slot 의 요청에 `max_tokens` 로 실린다. CLI slot 은 `max_tokens` 를 받지 않는다. catalog 의 출력 한도는 검증에만 쓰는 상한이다 | 운영자 선언 |
| 질문 q 의 입력 token 수 | 미리 세는 slot(Anthropic, Kimi)은 Agent-Core 가 보내기 전에 센다. 그 밖은 provider 가 받은 뒤 거절하거나, 답과 함께 `usage.input_tokens` 로 알려 준다 | provider 사실 |
| 폭 | 단위 몇 개, 그다음은 한 단위의 항목 몇 개 | 입력의 구조 |

들어가는 조건은 `input_tokens(q, s) + R ≤ W(s)` 다. 미리 세는 slot 에서 Agent-Core 가 하는 비교가 이것이다(`prepared_completion_request.ml:377-381`). 그래서 R 을 키우면 「입력이 크다」가 되는 항목과 Memory 가 늘어난다. R 이 창보다 크면 그 slot 은 모든 질문을 입력 크기로 거절한다.

이 경로에는 바이트 수, 비율, 바닥값, 배워서 정한 한도가 없다. 바이트 크기는 화면에만 나온다.
같이 지우는 것은 `facts_max_bytes` 와 `check_facts_budget`, admission 큐의 바이트 상한이다. Keeper 와 운영자의 쓰기는 크기로 거절되지 않는다.

「크기가 묶여 있다」는 말은 정확히 이것이다.

- 미리 세는 slot 에서는 센 값이 binding 에 들어가야 요청이 나간다. 안 들어가면 생성 없이 `Input_capacity (Context_window_exceeded _)` 가 돌아온다.
- 미리 세지 않는 slot 에서는 provider 자신의 창이 요청을 묶고, 넘치면 provider 가 거절한다. 그 거절에 타입이 있는 것은 지금 GLM 뿐이다(`backend_glm.ml:234-240`). 나머지는 400 이라 크기 사실이 되지 않는다(§7.4, §12.2). binding 의 400K 는 보내기 전에 확인할 수 없다. 그런 slot 이 `usage.input_tokens + R > W(s)` 인 질문에 답하면 답은 반영하고 카운터만 올린다.
- 센 값은 추정이다. 세어서 들어간다고 본 질문을 provider 가 받은 뒤 거절할 수 있다. 그 거절은 자기 타입대로 분류한다(§7.2).
- 다른 provider 의 세는 slot 으로 모든 질문을 미리 재지 않는다. 한 tokenizer 를 다른 tokenizer 의 대리로 쓰는 일이다. 이 lane 의 provider 들은 token 하나에 2.46~3.15 바이트로 서로 다르다.

### 6.4 출력 몫과 본문 시간

- R 은 운영자의 선언이다. 켠 Librarian lane 은 `max_output_tokens` 를 적어야 로드된다. 적지 않으면 요청에 provider 기본값이나 catalog 최대값이 실린다. 그 값은 lane 값에 없어서, 값이 바뀌어도 크기 사실이 남는다. 로드 때는 그 밖에 `R ≤` 각 slot 의 catalog 출력 한도를 본다.
- R 을 정할 때 두 힘이 있다. 둘 다 설치 안내에 적고, 로드에서 검사하지 않는다.
  - 너무 작으면 답이 R 에서 잘린다. reasoning token 을 `max_tokens` 안에서 세는 slot 에서 그렇다. GLM 은 thinking 을 강제하는데, 그 token 을 안에서 세는지는 문서에 없다.
  - slot 이 본문 시간 안에 만들 수 있는 양보다 크면 긴 답이 시간 초과로 끝난다. 시간 초과는 「말 없음」이라 폭을 줄이지 않는다.
- 설치 안내는 slot 마다 아는 한도 둘을 적는다. catalog 출력 한도, 그리고 잰 속도 × 선언한 본문 시간이다. GLM 은 11-17 에 약 62 token/s 였고 본문 시간이 1,200초라 약 74K token 이다. 이 값은 GLM 것이다. tinker 의 본문 시간은 600초다.
- Librarian 은 시간 한도를 더하지 않는다. slot 마다 provider 가 선언한 `exact-body-timeout-s` 아래서 돈다. 본문 시간은 생성 요청을 보낸 때부터 센다(#52986).
- 설치 뒤에 slot 마다 센다: `Output_over_reserve`, `Window_reached`, 보낸 뒤의 `Lost`.

## 7. 묻기

묻기(ask)는 질문 하나를 lane 의 slot 들에 한 번 보내 보는 일이다. 이 절은 묻기가 무엇으로 끝날 수 있는지와, 끝난 결과마다 쓰는 쪽이 무엇을 하는지를 정한다.

규칙은 하나다.

> 질문은 slot 이 이 질문을 거절했을 때만, 거절이 말한 만큼만 바꾼다. Memory 를 바꾸거나 내용을 지나치는 일은 선언한 모든 slot 의 타입 있는 크기 사실이 있을 때만 한다.

두 가지 걸음이 여기서 갈린다.

- **폭을 줄이는 일**은 잃는 것이 없다. 거절된 범위를 나눠 읽으면 된다. 그래서 질문에 대한 거절이 하나라도 있으면 줄인다.
- **한 항목 아래로 가는 일**은 Memory 를 바꾸거나 구멍을 남긴다. 항목을 Memory 없이 읽기, 자리 내기, 건너뜀이 그렇다. 그래서 lane 이 줄 수 있는 가장 강한 근거를 요구한다. 선언한 slot 이 모두 입력 크기로 거절했다는 것이다.

### 7.1 묻기 하나는 걷기 하나다

묻는 fiber 는 쓰는 쪽이 정한 질문 하나를 만들고, slot 을 한 번 걷고, 결과를 돌려준다.
폭을 줄이지 않는다. 상태를 갖지 않는다. 폭과 바닥의 판단은 모두 쓰는 쪽의, 모델을 기다리지 않는 동기 함수다.

1. 쓰는 쪽이 메모리에 둔 마지막 줄의 값을 읽는다. 스냅샷 sha, 읽은 자리, 턴 기록의 offset 이다.
2. 스냅샷 바이트를 읽고 그 값을 다시 읽는다. 값이 그대로인데 바이트의 sha 가 다르면 `Memory_diverged` 로 끝난다. 값이 달라졌으면 처음부터 다시 읽는다. 스냅샷은 반영(§8.2)이 읽는 함수로 읽고, sha 를 해석보다 먼저 비교한다. 파일이 없거나, 일반 파일이 아니거나, 읽기가 실패하거나, sha 는 맞는데 해석되지 않으면 `Snapshot_fault` 로 끝난다. 쓰는 쪽은 그 결함에 저장소와 같은 이유로 멈춘다. 이 결함은 저절로 낫지 않으니 쉬고 다시 묻지 않는다.
3. 턴 기록을 그 offset 부터 읽어 질문을 만든다(§5, §6).
4. slot 을 걷는다. 자리를 잡는 방법은 #52986 의 §3.1 이다. 빈 자리가 있는 slot 가운데 앞의 것, 없으면 먼저 비는 자리다. HTTP slot 이 모두 실패하거나 쉬거나 빠졌을 때만 CLI slot 으로 간다.
5. 걷기 전에 `Runtime_exact_lane_backpressure.order` 를 읽는다. provider 가 「이 시각까지 두라」고 한 slot 은 부르지 않는다. slot 결과마다 `observe` 를 부른다.
6. 선언한 slot 마다 결과를 하나씩 붙여 돌려준다.

```ocaml
type ask_result =                        (* 코드는 Librarian_read_result.t *)
  | Answered of { question : question; answer : answer; slot : string }
  | Nothing_to_ask
  | No_answer of { slots : (slot_key * unanswered) list }     (* 답한 slot 이 없다. 그래서 답한 slot 을 담지 못한다 *)
  | Nothing_readable of { reach : reach; missing : missing_at list }
  | Span_unknown of { before : mark; reach : reach }          (* reach 는 그 reset 줄까지 Whole *)
  | Memory_diverged of { expected : Sha256.t; observed : Sha256.t }
  | Snapshot_fault of snapshot_fault
  | Input_fault of input_fault
  | Ask_failed of failed
and reach = { line : int; within : within; covered : mark; turn_log_offset : int }   (* 반영 줄이 그대로 적는 값 *)
and snapshot_fault = Absent | Not_a_snapshot_file | Not_read     (* 코드는 Librarian_snapshot_fault.t. 반영·boot 와 같은 판정 *)
and failed = Raised | Flow_stopped | Read_failed                 (* Read_failed: 턴 기록, 단위의 파일을 읽지 못했다 *)
```

- `Refused_by_lane` 은 지금 선언된 slot 가운데 질문을 거절한 slot 이 하나는 있는 `No_answer` 이고, `Silent_lane` 은 그런 slot 이 없는 `No_answer` 다. 둘은 `decide` 의 조건이다(§9.3). 폭이 드는 `offered` 와 `lane_result` 의 나머지 칸(`question`, `basis`, `head`)은 L7 이 더한다.

- 폭과 반영한 수는 결과의 `offered` 에서 읽는다. 쓰는 쪽이 따로 세지 않는다. fiber 가 읽은 뒤에 턴이 닫혔을 수 있다.
- 걷기가 masc 쪽에서 멈춘 것(측정이나 시도를 시작하지 못함, callback 실패)과 쓰는 쪽이 더는 열려 있지 않은 것은 slot 결과가 아니다. `Ask_failed Flow_stopped` 다.
- 예외의 글은 구조화 로그로 간다. 행에는 오지 않는다.
- 기다린 시간, 호출 시간, 버린 본문은 결과에 없다. metric 과 span 으로 간다.

### 7.2 slot 결과

```ocaml
type size_fact =
  | Input_too_large        (* 보내기 전에 셌거나, provider 가 입력 넘침으로 타입했거나, HTTP 413. 생성하지 않았다 *)
  | Output_over_reserve    (* 출력 한도에서 멈췄다고 타입했다. R 을 선언했으면 R 이고, 아니면 provider 기본값이다. 생성 하나를 썼다 *)
  | Window_reached         (* 입력과 출력이 창에 닿아 멈췄다. 내용이 있든 없든. 생성 하나를 썼다 *)
type refusal = Sized of size_fact | Unsized      (* Unsized: provider 가 이 요청을 거절했고 크기를 말하지 않았다 *)
type silence = Not_called | Unavailable | Busy | Lost | Unusable of rejection
type unanswered = Refused of refusal | Silent of silence   (* No_answer 가 slot 마다 싣는다 *)
type slot_outcome = Slot_answered | Unanswered of unanswered
```

- 분류는 함수 하나다. `classify : slot_visit -> slot_outcome` 이고 결과 타입마다 와일드카드 없는 `match` 다.
- 생성자마다 한 행인 표는 근거 폴더에 있다. 타입 17개의 생성자 176개이고 행은 181개다. 다섯 생성자는 타입 있는 칸으로 둘로 나뉜다. 스크립트가 코드에서 생성자를 뽑아 표와 맞춘다. 행이 없는 생성자, 생성자가 없는 행, 겹치는 행이 있으면 실패한다.
- **선언한 slot 은 모두 결과가 있다.** 묻기는 선언한 slot 목록(HTTP, 그다음 CLI)을 돌면서 slot 마다 방문을 찾는다. 방문이 없으면 `Silent Not_called` 다. 그래서 「모든 slot」이라는 조건은 빠짐없는 목록 위의 fold 다.
- registry 가 받아들이지 않은 선언 slot 은 `Silent Unavailable` 로 센다. lane 값이 그 id 를 싣는다(L7).
- 판단이 읽는 것은 넷뿐이다. 답했다, 입력 크기로 거절했다, 다르게 거절했다, 말이 없다. 나머지 갈래는 운영자의 행에 쓴다.

| 갈래 | HTTP (Agent-Core) | CLI |
|---|---|---|
| `Refused (Sized Input_too_large)` | `Context_window_exceeded`, `Capacity_input_rejected`, 오류 봉투의 `Context_overflow`, 413 | Claude 와 Codex 의 `Context_window_exceeded` 가운데 생성이 시작되지 않은 것 |
| `Refused (Sized Output_over_reserve)` | `Output_limit_reached` | – |
| `Refused (Sized Window_reached)` | 창에서 멈춘 응답(새 생성자) | Claude 와 Codex 의 `Context_window_exceeded` 가운데 생성이 시작된 것 |
| `Refused Unsized` | `Invalid_request`(400, 422), stop reason 이 `Refusal` 이나 `ContentFilter` | Codex 가 타입으로 알린 요청 거절(`Bad_request`, `Cyber_policy`, `Misalignment_policy_violation`) |
| `Silent Not_called` | `order` 가 잡고 있다(`held_http`), `Seats_full`, 방문이 없다 | `Held`(`order_slots` 가 잡고 있다), Antigravity 의 `Spawn_capacity_busy`, 방문이 없다 |
| `Silent Unavailable` | slot 이나 runtime 을 선언대로 쓸 수 없다. 계약, 준비, 인증, 결제(402), 측정 불가, 어느 갈래에도 들지 않은 status | 모르는 runtime, official client 아님, client 를 띄우지 못함(`Setup_failure`, 설정 오류, 로그인 없음) |
| `Silent Busy` | rate limit, 과부하, 서버 오류, quota | `refused_for_binding_rest` |
| `Silent Lost` | 네트워크, 연결, 본문 시한, 본문을 못 받음, provider 가 끊음, 원인을 타입으로 알 수 없는 provider 오류 | 원인을 타입으로 알 수 없는 실행 실패 |
| `Silent (Unusable _)` | 본문이 왔는데 쓸 수 없다. JSON 아님, schema 어김, 되돌려 적기 틀림, 비었거나 잘림, 받은 본문이 masc 의 읽기 경계를 넘음(`Response_body_too_large`) | JSON 아님, schema 어김, 답 없이 끝난 턴(`Missing_reply`) |

- **갈래를 정하는 규칙은 하나다.** 타입 있는 값이 아래 셋 가운데 하나를 말하면 거절이다. 그 밖은 모두 말 없음이다.
  - 이 요청의 입력이 이 slot 의 경계에 들어가지 않았다.
  - 이 요청의 답이 이 slot 의 경계에서 잘렸다.
  - 이 slot 이 이 요청을 받지 않겠다고 했다.
- 타입 있는 값은 status, 오류 code, stop reason, client 가 준 타입 있는 오류, 그리고 masc 가 선언한 창과 견준 token 수다. 오는 길에 수를 잃은 값은 말 없음이다. Keeper 턴 경로의 `Input_capacity` 가 그렇다.
- 말 없음 아래의 갈래는 운영자의 행에 쓰는 이름이고, 판단은 그것을 읽지 않는다.
- 표는 생성자마다 한 행이다. 「그 밖의 것」 같은 행은 없다. CLI 가 감싼 client 별 오류 타입도 생성자마다 적는다. 위 표는 그 줄임이다.
- `Unsized` 는 크기를 말하지 않은 거절이다. HTTP 400 과 422, 모델이 내용을 거절한 stop reason, Codex 의 타입 있는 요청 거절이 여기다. provider 가 받은 요청을 두고 한 판정이라 거절이다. 크기 사실이라고 부르지 않고, 크기 사실이 필요한 곳에 쓰지 않는다.
- 선언이나 probe 로 알아낸 경계를 넘는 입력(`Capacity_input_rejected`)은 `Input_too_large` 다. 보내기 전에 token 수와 견준 것이다.
- CLI 의 창 넘침은 client 가 준 타입 있는 칸으로 가른다. Claude 는 tool 을 쓰지 않았고 응답을 내지 않았을 때만 `Input_too_large` 다. Codex 는 tool 을 쓰지 않았을 때다. 그 밖은 `Window_reached` 다. 생성을 쓴 것을 「생성하지 않았다」로 읽지 않으려는 것이다. HTTP 의 둘째 변경과 같은 이유다.
- Antigravity 와 Muse 는 판정을 타입으로 알리지 않는다. 그 client 의 실패는 모두 말 없음이다. 그래서 그 client 에서는 너무 큰 질문이 폭을 줄이지 못한다.
- Claude CLI 는 실패한 턴에 HTTP status 를 실어 준다. 분류는 그것을 읽지 않는다. 읽으면 HTTP 의 status 분류가 CLI 경로에 하나 더 생긴다. 그래서 Claude CLI 의 400 은 말 없음이고 폭을 줄이지 않는다.
- quota 를 타입으로 알리는 provider(429, 402)는 말 없음이다. 폭을 줄이지 않는다. quota 를 맨 400 으로 알리는 provider 는 `Refused Unsized` 가 되어 폭을 줄인다. 그 slot 은 이유를 다르게 말한 것이다. 값은 §7.7 에 있다.
- 본문 시한은 `Silent Lost` 다. POST 하나에 부분 본문이 없으면 느린 provider 와 긴 답을 가를 수 없다.
- 받은 본문이 masc 의 읽기 경계를 넘으면(`Response_body_too_large`) `Silent (Unusable Empty_or_partial)` 이다. 그 경계는 10 MiB 이고 모든 slot 에 같다(`api_common.ml:12`). 출력 한도 안의 답은 거기 닿지 않는다. status 를 쓰기 전에 본문을 읽으므로 오류 본문도 같은 값을 낸다. 「이 slot 의 경계에서 답이 잘렸다」는 뜻이 아니라서 폭을 줄이지 않는다.
- 원인을 글로만 알린 provider 오류(`Provider_reported_error`)는 `Silent Lost` 다. 그 글을 읽어 갈래를 나누지 않는다.

Agent-Core 는 다섯 곳을 고친다. 이 스택의 작은 층 하나이고 #52986 의 자리 걷기 층 위에 놓인다.

1. provider 오류가 `Context_overflow` 인 receipt 는 `http_status` 가 무엇이든 그 타입을 지킨다.
   - 지금 코드가 이미 그렇다. 이 오류를 만드는 곳은 `Glm_chat` codec 하나다(`backend_glm.ml:240`).
   - 그 codec 은 받은 본문과 성공이 아닌 status 에서만 불린다. 두 경우 모두 receipt 에 status 가 있다(`exact_output_execution.ml:189-222`).
   - 그래서 status 가 없는 갈래(`exact_output.ml` 의 `None -> Completion_failed`)에는 닿지 않는다. L2 는 이 항목에 코드를 더하지 않는다.
   - 닿지 않는 그 갈래를 타입에서 없애는 일은 이슈 #53260 에서 한다. Exact 경계의 오류 타입을 고치는 일이다.
2. 창에 닿아 멈춘 응답은 내용이 있든 없든 자기 생성자다. 지금은 내용이 있으면 `Incomplete_output`, 없으면 `Context_overflow` 다. 뒤쪽은 쓴 생성을 「생성하지 않았다」로 읽게 한다.
3. `Invalid_request` 는 400 과 422 만 뜻한다. 지금은 어느 갈래에도 들지 않은 status(3xx, 405, 408, 409)가 모두 여기로 떨어진다. 그것은 자기 생성자가 되고 `Silent Unavailable` 이다.
4. `Incomplete_output` 이 stop reason 을 싣는다. 지금은 stop reason 열한 가지가 값 없는 생성자 하나로 접힌다(`exact_output.ml:961-973`). 그래서 모델이 내용을 거절한 것과 답이 중간에 끝난 것을 가를 수 없다. 칸 하나를 더하고 동작은 바꾸지 않는다.
5. provider 가 창 넘침에 기계가 읽는 오류 code 를 문서로 정해 두었으면, 그 provider 에만 속한 wire codec 이 그 code 로 `Context_overflow` 를 만든다. 지금 그런 codec 은 `Glm_chat` 하나다(`backend_glm.ml:234-240`, code 1261). 닫힌 wire 칸을 타입으로 푸는 일이고, 오류 글을 읽는 일이 아니다.
   - 여러 provider 가 같이 쓰는 codec(`Openai_chat` 같은 것)은 code 를 풀지 않는다. 풀면 그 code 를 문서로 정한 적 없는 provider 의 답에 타입이 붙는다.
   - 새로 푸는 codec 은 모르는 code 에 아무것도 만들지 않는다. HTTP status 가 정한다. GLM 의 codec 은 지금 모르는 code 를 `Invalid_request` 로 접는다. 그것은 Keeper 턴 경로도 지나는 코드라 이 RFC 가 바꾸지 않는다(#53120).
   - 그런 code 가 없는 provider 의 slot 은 크기를 말하지 않는 slot 으로 남는다.

이 층은 선언한 slot 마다 창을 넘는 질문을 한 번 보내고, 돌아온 타입 있는 결과를 slot 별 표로 PR 에 붙인다. 한 항목 아래의 단계(§7.4)가 어느 lane 에서 닿는지는 그 표가 말한다.

### 7.3 결과마다 쓰는 쪽이 하는 일

`decide` 는 모델을 기다리지 않는 동기 함수다. 반영에 드는 저장소 I/O 는 그 안에서 한다. 아래에서 「다시 묻는다」는 §9.2 의 「다음 묻기」다. lane 이 켜져 있고 안 읽은 것이 있으면 폭 기억이 정한 폭으로 묻고, 아니면 `Idle` 이다.

| 결과 | 조건 | 하는 일 |
|---|---|---|
| `Answered` | – | 반영한다(§8). 폭 기억에 반영한 수를 알린다. 다시 묻는다 |
| `Nothing_to_ask` | – | 다시 묻는다. fiber 가 읽은 뒤에 턴이 닫혔을 수 있다 |
| `Refused_by_lane` | 질문이 한 항목보다 넓다 | 폭 기억에 거절을 알리고, 줄인 폭으로 바로 다시 묻는다 |
| `Refused_by_lane` | 한 항목이다 | §7.4 |
| `Silent_lane` | – | `Resting`. 다음 pulse 에 같은 폭으로 묻는다 |
| 답이 아닌 결과 | 묻는 사이에 lane 값이 바뀌었고, 지금 선언한 slot 가운데 결과가 있는 것이 없다 | 다시 묻는다. 다음 묻기는 지금 lane 값으로 가므로 되풀이되지 않는다 |
| `Nothing_readable` | – | `Skip (Content_missing _)` 을 반영하고 다시 묻는다 |
| `Span_unknown` | – | `Skip (Unknown_span _)` 을 반영하고 다시 묻는다. 모델을 부르지 않는다 |
| `Memory_diverged` | – | `Stopped (Log_diverged _)` |
| `Snapshot_fault` | – | 저장소가 같은 결함에 멈추는 이유로 `Stopped`. 없음·스냅샷 아님은 `Memory_unreadable`, 읽기 실패는 `Store_unwritable` |
| `Input_fault`, `Ask_failed` | – | `Resting` |

- 고장 난 slot 은 폭 줄이기를 막지 못한다. 거절이 하나만 있어도 줄인다.
- 고장 난 slot 은 한 항목 아래로 가는 일을 막는다. 그 일에는 모든 slot 의 크기 사실이 필요하다.
- quota 폭풍은 `Silent_lane` 이라 폭을 줄이지 않는다.
- 결과는 지금 선언한 slot 위에서 읽는다. 걷는 사이에 lane 에서 빠진 slot 의 결과는 읽지 않는다. 답은 그래도 반영한다.

### 7.4 한 항목에서

폭이 한 항목까지 줄면 더 좁힐 수 없다. 여기서부터는 slot 마다의 크기 사실을 모은다.

**거절은 사실이다.** slot 이 어떤 질문을 크기로 거절했으면, 같은 질문을 그 slot 에 다시 보내는 것은 같은 호출을 두 번 하는 일이다.
쓰는 쪽은 맨 앞 항목의 두 질문에 대해 slot 마다 받은 크기 사실을 메모리에 둔다.

```ocaml
type target =
  | Http of { provider_id : string option; model_id : string; provider_kind : Provider_kind.t
            ; endpoint : string; reserve : int }   (* reserve: lane 의 출력 몫 R *)
  | Cli of { runtime_id : string; api_name : string }
type slot_key = { id : string; target : target; window : int }
  (* lane 값이 푼 slot. 하나라도 바뀌면 다른 key 다 *)
type judged = { question : Question_id.t; facts : (slot_key * size_fact) list }
type bottom = { with_memory : judged option; alone : judged option }  (* 맨 앞 항목의 두 질문 *)
```

- HTTP slot 의 `reserve` 는 lane 의 R 이고 slot 마다 다르지 않다. 보내기 전에 세는 slot 은 R 로 세고, 세지 않는 provider 도 입력과 `max_tokens` 의 합으로 창을 잰다. 그래서 R 이 바뀌면 HTTP slot 의 key 가 모두 바뀌고 그 크기 사실을 다시 묻는다. CLI slot 은 `max_tokens` 를 받지 않아서 `reserve` 가 없다.
- 기억하는 것은 한 항목짜리 질문에 대한 `Refused (Sized _)` 뿐이다.
  - 한 항목보다 넓은 질문의 거절은 기억하지 않는다. 바로 폭을 줄이므로 그 질문을 다시 묻지 않는다.
  - `Unsized` 는 기억하지 않는다. 400 은 크기를 말하지 않고, provider 는 지나가는 일(다 쓴 quota)도 400 으로 알린다. 그 slot 에는 pulse 마다 다시 묻는다. 400 이면 요청 하나가 들고 생성은 없다. 모델이 내용을 거절한 stop reason 이면 생성도 하나 든다.
  - 말 없음은 기억하지 않는다.
- 사실은 질문 id 와 slot key 아래에 둔다. 질문 id 는 질문 바이트의 hash 다. Memory 가 바뀌거나 선언이 바뀌면 id 가 다르고, slot 이 바뀌면 key 가 다르다. 그래서 그런 때에 지울 것이 없다. key 는 부를 때의 slot 값이다. 지금 선언에 없는 key 의 사실은 찾지 않는다. 기록은 다른 질문 id 의 크기 사실이 올 때만 갈아 쓴다.
- `bottom` 을 비우는 때는 셋이다. 읽은 자리가 움직였다, 운영자가 `Resume` 했다, boot 했다.
- 묻기는 `bottom` 을 받는다. 질문을 만든 뒤, 그 질문 id 아래에 사실이 있는 slot 은 HTTP 든 CLI 든 부르지 않는다. 걷기에는 남은 slot 만 넘기고, 뺀 slot 의 결과는 그 사실로 채운다. 부를 slot 이 없으면 아무도 부르지 않고 그 사실들로 끝난다. 그 결과는 `Refused_by_lane` 이다.

`decide` 는 지금 선언한 slot 위에서 접는다. slot 마다 이 질문 id 의 사실을 찾는다. 기억에 있거나 이번 결과에 있다.
「모두」는 선언한 slot 마다 사실이 있다는 뜻이다. 「입력」은 모두이고 그 사실이 전부 `Input_too_large` 라는 뜻이다.

| 물은 것 | 답했다 | 입력 | 모두, 입력은 아님 | 모두가 아님 |
|---|---|---|---|---|
| 한 항목과 Memory | 반영하고 다시 묻는다 | 바로 그 항목만 묻는다 | `Refused_at_bottom` | `Resting` |
| 그 항목만(`Read_item_alone`) | 반영한다. 그다음 자리 내기를 한 번 묻는다 | `Skip (Item_exceeds_window)` 을 반영하고 다시 묻는다 | `Refused_at_bottom` | `Resting` |
| 자리 내기(`Make_room`) | 효과 있는 op 가 있으면 반영한다. 다시 묻는다 | 다시 묻는다 | 다시 묻는다 | 다시 묻는다 |

- **항목만 읽기.** 그 항목을 Memory 와 하던 일 없이 보여 준다. 답에서 `Add` 와 `working_state = Keep` 만 받는다. 그 밖은 반영하지 않고 줄에 적는다. Memory 를 보지 않은 답이 Memory 를 지우거나 하던 일을 갈아 쓸 수는 없다. 항목만 읽기는 「입력」이 있어야 시작한다. 그 답은 묻는 사이에 Memory 나 slot 이 바뀌었어도 반영한다. 더하기만 하는 답이라 잃는 것이 없다.
- **자리 내기.** Memory 와 하던 일만 보여 주고 줄일 것을 묻는다. 항목만 읽어 반영한 바로 뒤에 한 번 묻는다. 그 묻기 동안 직접 쓰기가 fact 를 지웠거나 lane 값이 바뀌었으면 묻지 않는다. 근거가 이미 옛것이다.
- **자리 내기는 읽기를 세우지 않는다.** 어떻게 끝나든 다음 항목으로 간다. 선언한 slot 이 모두 입력 크기로 거절하면 Memory 가 어느 slot 에도 들어가지 않는 것이다. 읽기는 항목만 읽으며 이어지고, 경보 E5 가 켜진다(§12).
- **`Refused_at_bottom`.** 선언한 slot 이 모두 맨 앞 항목의 질문에 크기 사실을 줬고, 그것이 전부 입력 크기는 아니다. 한 항목 아래로 갈 근거가 없고, 다시 물을 slot 도 없다. 질문이 달라질 수 있을 때까지 묻지도 읽지도 않는다.
  - 이것이 `Resting` 과 다른 상태인 이유다. 모든 slot 이 크기를 말한 질문은 시간이 지나도 답이 같다. 바꾸는 것은 사건뿐이다. `Resting` 은 「다음 pulse 에는 다를 수 있다」는 상태다. 이 상태가 없으면 서 있는 Keeper 마다 pulse 마다 질문을 다시 짓고 아무것도 알아내지 못한다(§16).
  - 직접 쓰기가 반영되면 다시 묻는다. Memory 가 바뀌어 Memory 를 실은 질문의 바이트가 달라졌다. 항목만 실은 질문은 그대로라 그 사실은 남는다.
  - 선언이 다른 값으로 바뀌면 다시 묻는다. `Resume` 은 사실을 지우고 다시 묻는다. `Skip_item` 은 그 항목을 지나간다.
- **옛 Memory 를 두고 한 판정으로 내려가지 않는다.** 한 항목짜리 질문의 결과가 본 스냅샷이 지금의 스냅샷이 아니면, 그 결과의 「입력」과 「모두」를 쓰지 않고 다시 묻는다. 그 판정은 지금의 Memory 에 대한 것이 아니다. 항목만 물은 결과도 같다. 그때는 Memory 를 실은 질문을 한 번 더 걷는다. 항목만 실은 질문의 사실은 남아 있어서 그 질문은 slot 을 다시 부르지 않는다.
- 한 항목보다 넓은 질문의 거절은 그사이 직접 쓰기가 있었어도 바로 폭을 줄인다. 폭을 줄여서 잃는 것은 없다.

이 순서의 뜻은 이렇다. 항목을 Memory 없이 읽으려면, 그 항목과 Memory 를 함께는 어느 slot 도 받지 못한다는 사실이 있어야 한다. 건너뛰려면 그 항목만도 어느 slot 이 받지 못한다는 사실이 있어야 한다. 자리 내기는 둘 사이다. 함께는 안 들어가고 항목만은 들어갔을 때만 묻는다.

### 7.5 쉼

쉬는 시각은 없다. `Resting` 은 값을 갖지 않는다.

- pulse(서버 maintenance tick, 60초)가 오면 `lane_held` 를 본다. 선언한 slot 이 모두 provider 가 잡아 둔 slot 이면 아무것도 읽지 않고 `Resting` 에 남는다. 아니면 다시 묻는다.
- `lane_held ~now lane` 은 이 프로세스가 남긴 기록을 읽는다. HTTP 는 `order(lane).held_http`, CLI 는 `Keeper_lane_cli_oneshot.order_slots` 가 잡은 쪽을 읽는다.
- 그래서 멀리 있는 reset 시각 하나가 lane 전체를 쉬게 하지 못한다. provider 가 말한 시각이 지난 뒤 늦는 것은 pulse 한 번까지다.
- 바닥에서 쉬는 Keeper 는 pulse 마다 크기 사실을 주지 않은 slot 에만 묻는다. 한 항목과 Memory 를 실은 질문을 먼저 만들고, 모두 입력 크기로 판정돼 있으면 부르지 않고 그 항목만 실은 질문으로 넘어간다.
- pulse 는 등록된 Keeper 를 모두 돈다. Keeper 마다 `ensure` 를 부르고 그 쓰는 쪽에 `Pulse` 를 보낸다(§8.6). 등록부에 없는 Keeper 의 쓰는 쪽에는 `Retire` 를 보낸다.

### 7.6 폭 기억

거절된 범위를 기억하지 않으면, 반영할 때마다 가장 넓은 폭부터 다시 거절당한다. 운영자 RFC 가 이름 붙여 거절한 모양이다([RFC-librarian-read-waits-and-shrinks-no-further-than-the-refusal-says](RFC-librarian-read-waits-and-shrinks-no-further-than-the-refusal-says.md) §3.2).
쓰는 쪽은 거절된 범위마다 그 크기와 아직 안 읽은 양을 메모리에 둔다.

```ocaml
type width = All | Units of int | Items of int       (* Items: 맨 앞 단위의 안 읽은 항목 가운데 *)
type entry = { size : int; left : int }               (* 거절된 범위 하나. 거절될 때의 크기와 아직 안 읽은 양 *)
type narrowing = { units : entry list; items : entry list }   (* 안쪽부터 *)
```

- **거절.** 질문이 실은 수 n 으로 `{ size = n; left = n }` 을 그 층에 올린다. 가장 안쪽 범위가 이미 정확히 그 값이면 올리지 않는다.
  - 단위 하나를 실었고 그 단위의 안 읽은 항목이 j 개(j ≥ 2)면 항목 층에도 j 로 올린다.
  - 한 항목이면 올리지 않는다. 바닥이다(§7.4).
  - 「남은 양이 n 이면 올리지 않는다」로 쓰면 틀린다. 일부를 읽은 범위의 나머지가 다시 거절됐을 때 같은 폭을 쉬지 않고 되묻게 된다. 모델이 여덟 상태로 보였다(§21 의 `skip-push-when-left-is-n`).
- **반영.** 반영한 수를 그 층 모든 범위의 `left` 에서 뺀다. 0 이 된 범위는 버린다. 단위 하나가 끝나면 항목 층을 비운다. 건너뜀과 항목만 읽은 반영도 반영으로 센다.
- **다음 폭.** 가장 안쪽 범위 e 를 본다. 항목 층이 단위 층보다 먼저다. `e.left = e.size` 이고 `e.size ≥ 2` 면 `e.size / 2`(내림)다. 그 범위에서 반영한 것이 있으면 `e.left` 다. 범위가 없으면 `All` 이다.
- **비움.** boot, 다른 값으로 바뀐 선언, `Restart_reading`, `Adopt`. 건너뜀과 자리 내기 반영은 비우지 않는다.
- 항목이 없는 단위는 따로 묻지 않는다. 다음 반영과 같이 지나간다.

안 읽은 단위가 16개이고 넷까지만 들어가는 경우다.

| 걸음 | 폭 기억(안쪽부터, 크기/남은 양) | 묻는 폭 | 결과 |
|---|---|---|---|
| 1 | – | 전부(16) | 거절 |
| 2 | 16/16 | 8 | 거절 |
| 3 | 8/8, 16/16 | 4 | 답. 넷을 반영한다 |
| 4 | 8/4, 16/12 | 4 | 답. 넷을 반영한다 |
| 5 | 16/8 | 8 | 거절 |
| 6 | 8/8, 16/8 | 4 | 답 |
| 7 | 8/4, 16/4 | 4 | 답 |
| 8 | – | 전부 | |

지키는 것은 다섯이다(§21 의 `LibrarianWidth`).

- 거절된 범위 안에서 시작한 묻기는 그 범위의 끝을 넘지 않는다.
- 거절된 범위 전체를 다시 묻지 않는다. 같은 자리에서 거절된 범위를 그대로 다시 묻지도 않는다.
- 거절 한 번은 절반(내림)까지만 줄인다.
- 말 없음은 폭을 바꾸지 않는다. 거절된 범위가 없으면 안 읽은 것 전부를 묻는다.
- 턴이 더 들어오지 않으면 안 읽은 것이 빈다.

폭 기억은 직접 쓰기를 넘어 남는다. Memory 가 줄었는데도 범위를 작게 나눠 읽을 수 있다. 「반영한 것이 있으면 남은 전부」 규칙이 그 값을 묶는다.

### 7.7 치르는 값

- **항목만 읽기.** 그 항목에서 나온 fact 는 더해지기만 하고 합쳐지지 않는다. 하던 일도 움직이지 않는다. Memory 가 어느 항목과도 함께 들어가지 않는 동안은 모든 읽기가 이렇다. 고친 claim 이 옛 claim 옆에 남고 Memory 는 더한 만큼 자란다. 그동안 W3 이 켜져 있다.
- **자리 내기의 근거.** 「항목과 Memory 는 함께 안 들어가고 항목만은 들어간다」는 것이다. Memory 가 크다는 뜻은 아니다. 가장 큰 창을 거의 채우는 항목 하나가 작은 Memory 의 정리 한 번을 부른다.
- **Memory 가 큰 Keeper.** Memory 가 어느 slot 에도 들어가지 않는 동안, 항목마다 거절되는 걷기 한두 번, 항목만 읽는 생성 하나, 자리 내기 걷기 하나가 든다. 자리 내기 걷기는 선언한 slot 모두에게 간다. HTTP slot 이 다 거절하면 CLI slot 까지 간다.
- **말 없는 slot.** 바닥에서 말이 없거나 400 으로 답하는 slot 에는 pulse 마다 다시 묻는다. 그 slot 이 매번 생성을 쓰고 쓸 수 있는 것을 돌려주지 않으면(보낸 뒤 끊김, 쓸 수 없는 본문), 쉬는 동안 pulse 마다 생성 하나다. 나가는 길은 그 slot 이 답하거나 크기 사실을 주는 것, 선언 변경, `Skip_item` 이다. W1 이 보인다. 말 없는 slot 이 없고 400 으로 답하는 slot 만 남았으면 E4 다(§12.2).
- **GLM 이 모르는 code.** GLM 이 모르는 code 로 알린 오류는 `Refused Unsized` 로 읽힌다. 한 항목보다 넓으면 폭을 줄인다. 한 항목에서는 E4 를 켤 수 있다. 그 code 가 quota 나 과부하를 뜻해도 같다(#53120).
- **한 항목을 넘는 폭에서도 같다.** 답이 늘 본문 시한을 넘는 질문은 `Silent Lost` 라 폭이 줄지 않고 다시 묻는다. W1 이 보인다.
- **크기 사실은 질문이 바뀔 때까지 믿는다.** 같은 선언 아래서 provider 가 한도를 올려도, 직접 쓰기나 선언 변경이나 `Resume` 이나 재시작 전에는 옛 판정이 남는다.
- **출력 쪽 크기 사실은 생성 한 번의 결과다.** 답이 잘렸다는 사실은 그 한 번에 대한 것이다. 같은 질문에 다시 물으면 들어갈 수도 있다. `Resume` 이 다시 묻게 한다.
- **`bottom` 은 종류마다 질문 하나만 기억한다.** 앞서 물었던 질문이 돌아오면 slot 마다 한 번 더 묻는다.
- **`Refused_at_bottom` 에서의 직접 쓰기.** 쓸 때마다 Memory 를 실은 질문을 한 번 걷는다. 답을 자르는 slot 마다 생성 하나다.
- **재시작.** 폭 기억과 `bottom` 이 비어 있다. 폭 줄이기를 처음부터 다시 걷는다(약 ⌊log2 단위 수⌋ + ⌊log2 항목 수⌋ 번). 바닥 질문은 slot 마다 한 번 더 묻는다.
- **선언 변경.** 폭 기억이 비므로 바닥 위의 폭 줄이기를 다시 걷는다. 걸음마다 선언한 slot 모두에게 간다. 생성한 뒤에 거절하는 slot 은 걸음마다 생성 하나를 쓴다. 바닥의 두 질문에 대한 사실만 남는다.
- **크기를 타입으로 말하지 않는 slot 이 있는 lane.** 「어디에도 안 들어간다」를 보일 수 없다. 그 lane 에서는 한 항목 아래의 단계(항목만 읽기, 자리 내기, 크기로 건너뛰기, `Refused_at_bottom`)에 닿지 않는다. 너무 큰 항목 하나가 맨 앞에 남는다. 그 slot 이 거절로 답하면(400) 경보 E4 가 켜진다. 말이 없으면 W1 이 켜지고, 그 경고는 스스로 끝나지 않는다(§12.2). 판정을 타입으로 알리지 않는 client 가 그렇다. pulse 마다 크기 사실이 없는 slot 에 그 항목을 다시 보낸다. 나가는 길은 운영자가 그 slot 을 빼거나 고치는 것, 또는 `Skip_item` 이다.
  - 코드에서 provider 쪽 넘침을 타입으로 만드는 backend 는 지금 GLM 하나다. 미리 세는 slot 은 세어서 말한다. 운영 lane 의 slot 마다 어느 쪽인지는 Agent-Core 층의 측정이 적는다(§7.2).
- **이유를 다르게 말하는 slot.** quota 를 맨 400 으로 알리는 slot 은 한 항목보다 넓은 폭에서 폭을 줄이게 한다. 잃는 것은 없고 묻기가 늘어난다.

## 8. 반영

반영(commit)은 Memory 를 바꾸는 일이다. 반영 기록(`<k>.memory-log.jsonl`)에 한 줄을 fsync 하면 반영된 것이다. 스냅샷(`memory-current.json`)은 그 줄에서 다시 쓴다.
이 절은 줄의 모양, 여섯 단계, 읽은 자리가 움직이는 규칙, boot 때 하는 일을 정한다.

### 8.1 줄의 모양

```ocaml
type position = Before_first | Through of { line : int; within : within }
and within = Whole | Item of int

type actor = Keeper | Operator of string    (* 그 Memory 의 Keeper 자신, 또는 운영자의 이름 *)
type removal =
  | Dropped of { reason : string } | Merged_into of Memory_id.t | Revised_into of Memory_id.t
  | Superseded_by of Memory_id.t | Retracted of { by : actor; reason : string }
  | Support_lost of { missing : Memory_id.t list }
type why_not =
  | Unknown_ref | Ref_used_twice | Source_outside_question
  | Removed_during_flight of { seq : int }
  | Not_valid_alone            (* 항목만 읽은 답이 Memory 를 지우거나 하던 일을 바꾸려 했다 (§7.4) *)
  | Successor_unsupported      (* 이 op 가 말한 fact 가 근거를 잃어 남지 못했다 *)
type effects =
  { added : Fact.t list                      (* fact 전체. 지금의 fact 모양 그대로 *)
  ; touched : Memory_id.t list               (* last_seen 만 옮김 *)
  ; removed : (Fact.t * removal) list        (* fact 전체. 지운 claim 을 나중에 찾을 수 있다 *)
  ; not_applied : (int * why_not * new_fact option) list
  ; sources : (Memory_id.t * int list) list }    (* fact 가 나온 단위의 줄 offset *)

type hole =
  | Item_exceeds_window
  | Content_missing of missing_at list
  | Line_unreadable of { offset : int; sha : Sha256.t }
  | Unknown_span of { before : mark; after : mark }
  | Turn_log_replaced of { from : Turn_log_id.t; to_ : Turn_log_id.t }
  | Position_lost of { offset : int; length : int }
  | Operator_skipped of { by : string }
type cause =
  | Read of { question : Question_id.t; shown_memory : bool; slot : string; trace : string; missing : missing_at list }
  | Make_room of { question : Question_id.t; after : item_ref; slot : string }
  | Direct of { by : actor; trace : string; write : write }
  | Skip of { hole : hole }
  | Adopt of { by : string; observed : Sha256.t }

type commit =
  { seq : int; at : float; basis : Sha256.t; after : Sha256.t; revision : int
  ; cause : cause; effects : effects
  ; turn_log : Turn_log_id.t; turn_log_offset : int   (* 어느 턴 기록의 어디부터 안 읽었나 *)
  ; covers_through : position; covered : mark         (* 읽은 자리와 그 끝자리 *)
  ; working_state : string option }
type log_line =
  | Started of { at : float; turn_log : Turn_log_id.t; snapshot : Sha256.t; revision : int
               ; turn_log_offset : int; covered : mark }
  | Committed of commit
```

- 마지막 줄 하나면 다시 시작할 수 있다. 그래서 하던 일(`working_state`)을 줄마다 다시 적는다. 크기는 §10 에 있다.
- `seq` 는 `Started` 뒤의 첫 `Committed` 가 1 이다. 그 뒤로 줄마다 1 씩 는다. `Started` 를 다시 쓰면 1 부터 다시 센다.
- `Started.revision` 은 그 줄이 가리키는 스냅샷의 revision 이다. `Committed.revision` 은 그 줄 뒤의 스냅샷의 revision 이다.
- `Sha256.t` 는 checkpoint object 가 쓰는 digest 타입이다(`Agent_core.Checkpoint_objects.digest`). 스냅샷 바이트의 sha256 을 소문자 16진수 64자로 적는다.
- 위치를 적는 값 셋은 쓰임이 다르다. `turn_log_offset` 은 읽는 쪽이 훑지 않고 시작하는 곳이다. `covers_through` 는 화면이 견주는 값이다. `covered` 는 턴 기록을 읽을 수 없을 때도 Keeper 요청의 시작점을 정한다.
- 줄에 넣지 않는 것: 기다린 시간, 호출 시간, 버린 답의 본문, 센 token 수. 이것들은 metric 과 구조화 로그로 간다.
- 실패한 묻기는 줄을 남기지 않는다. 읽은 자리가 안 움직이고 안 읽은 단위가 그대로 있는 것이 증거다(`failure_keeps_evidence`).

### 8.2 여섯 단계

쓰는 쪽은 사는 동안 `<k>.memory.lock` 을 쥔다. Keeper 경로는 이 잠금을 기다리지 않는다.

1. **계획**(순수 함수). `Librarian_plan.of_answer ~shown ~facts ~removed_since ~at ~trace_id answer` 가 새 Memory, `effects`, 받아들인 하던 일을 돌려준다. 새 Memory 는 `Librarian_effects.apply` 를 `effects` 에 적용한 값이다. 그래서 줄만으로 스냅샷을 다시 쓸 수 있다.
2. **쓰기 전 상태 확인.** `memory-current.json` 을 읽어 sha 를 낸다. 마지막 줄의 `after`(또는 `Started.snapshot`)와 같아야 한다. 다르면 `Stopped (Log_diverged _)` 로 가고 쓰지 않는다(`authoritative_read_only`).
3. **인코딩.** 지금 쓰는 스냅샷 codec 으로 새 envelope 을 만든다. `revision + 1` 이고 `after = sha256 bytes` 다. `Skip` 이나 효과 없는 답은 바이트를 그대로 두고 `after = basis` 다. 읽은 자리가 움직였으므로 줄은 쓴다.
   - envelope 은 `revision`, `updated_at`, `source`, `facts`, `change` 다. 지운 이유(`removal`)는 담지 않는다. 그것은 줄에만 있다.
   - `source.kind` 는 `Read` 와 `Make_room` 에서 `librarian`, `Remember` 와 `Supersede` 에서 `explicit_write`, `Retract` 에서 `explicit_retract` 다. `change` 는 `effects` 에서 만든다.
   - `source.trace_id` 는 줄이 싣는 trace 다. 직접 쓰기에서는 그 쓰기가 온 trace 다(`Direct.trace`). Keeper 의 턴이거나, 운영자 route 가 자기 요청에 붙인 이름이다.
   - envelope 의 다섯 칸이 모두 줄에서 나온다. 그래서 boot 가 5단계를 줄에서 다시 해도 바이트가 같다(§8.6). 함수 하나가 한다(`Librarian_envelope.after`).
   - 첫 boot 가 쓰는 빈 envelope 은 revision 1 이고 fact 가 없다. `source` 는 `librarian` 이고 trace 는 그 턴 기록의 id 다.
   - 바이트는 `test_keeper_memory_snapshot_golden` 이 고정한다.
4. **덧붙이기.** 아는 끝 offset 에서 `Committed` 줄을 덧붙이고 fsync 한다. **여기가 반영된 시점이다.**
5. **스냅샷.** `memory-current.json.tmp` 를 쓰고 fsync, rename, 디렉터리 fsync 를 한다. `after = basis` 면 건너뛴다.
6. **알림.** 메모리의 view(`covers_through`, `covered`, `working_state`)를 바꾸고 부른 쪽에 답한다.

4와 5는 `Eio.Cancel.protect` 안에서 한다.

덧붙이기 결과가 분명하지 않으면 꼬리를 다시 읽는다.
- 이 `seq` 와 `after` 를 가진 줄이 있으면 들어간 것이다. 다시 쓰지 않는다.
- 끝이 달라졌는데 꼬리가 다른 줄이면 `Log_diverged` 다. 파일이 없어졌을 때도 같다.
- 끝이 그대로고 꼬리도 덧붙이기 전의 줄이면 들어가지 않은 것이다. `Stopped Store_unwritable` 로 간다.
- 덧붙이는 helper 는 마지막 줄바꿈 뒤의 찢긴 조각을 먼저 잘라낸다. 되돌리기까지 실패한 경우에만 바이트가 남을 수 있어서, 그때도 꼬리를 다시 읽고 판단한다.

계획의 규칙이다.

- 답의 `m3` 같은 이름은 질문의 표로 fact id 가 된다. 표에 없는 이름은 `Unknown_ref` 다. 두 op 가 같은 이름을 쓰면 둘째가 `Ref_used_twice` 다. op 하나에 흠이 둘이면 검사 순서에서 먼저 걸린 것을 적는다. 순서는 `librarian_plan.mli` 에 있다. op 번호는 0부터 센다.
- `Add` 한 claim 을 이미 갖고 있으면 `last_seen` 만 옮긴다(`touched`). fact id 는 claim 의 sha256 이다.
  - basis 는 올리지 않는다. 지금 코드는 올린다(`merge_basis`). 글자까지 같은 claim 은 질문이 보여 준 fact 를 되읽은 것일 수 있어서 새 근거로 치지 않는다.
- `Drop` 은 `Dropped` 로 지운다. `Merge` 는 원본들을 `Merged_into` 로 지우고 새 fact 를 더한다. `Revise` 는 옛 fact 를 `Revised_into` 로 지우고 새 fact 를 더한다.
- 지운 fact 는 줄에 통째로 남는다. `memory_search source=dropped|absorbed` 가 반영 기록에서 찾아 준다.
- 반영하지 않은 op 는 번호, 이유, 새 claim 을 줄에 남긴다. 멈춘 `Revise` 나 `Merge` 의 새 claim 을 `Add` 로 바꿔 넣지는 않는다. 그러면 방금 철회한 것을 되살릴 수 있다.
- op 의 흠은 답 전체를 버리지 않는다. 지금은 흠 하나에 답 전체가 거절됐다.
- op 를 다 적용한 뒤 파생 fact 의 근거를 본다. 근거가 된 fact 가 없어진 파생 fact 는 `Support_lost` 로 같은 줄에서 지운다.
- 그다음, 자기가 말한 fact 가 그 확인에서 살아남지 못한 op 는 거둔다. 그 op 가 지운 원본을 되살리고 그 op 를 `Successor_unsupported` 로 적는다. 달라지는 것이 없을 때까지 되풀이한다. 지운 것이 없는 `Add` 도 같다. 되살릴 것은 없고, 반영되지 않았다는 것이 줄에 남는다.
  - 이 순서가 없으면 `Merge` 가 원본과 새 fact 를 함께 잃는다. 새 fact 가 자기가 대신한 원본에서 파생된 경우다.
  - 지금 반영이 하는 일이다. `keeper_memory_os_disposition_core.plan` 안의 지역 함수 `settle` 이 한다. 새 모듈 `Librarian_plan` 이 같은 일을 op 번호와 함께 한다. 거둔 op 가 번호로 돌아온다. 옛 모듈은 부르던 곳 셋과 함께 지운다(§19).
  - `plan` 은 원본이 이미 없는 새 fact 를 따로 거절한다. 그 일은 쓰는 쪽의 규칙(§8.3)이 하므로 두 번 두지 않는다.
  - 직접 쓰기 뒤에는 근거 확인만 한다. 지금과 같다.

### 8.3 답을 기다리는 사이의 쓰기

묻는 동안에도 직접 쓰기는 바로 반영된다. 쓰는 쪽은 그사이 지워진 fact id 를 모아 둔다(`removed_since`).
답이 오면 그 목록에 든 id 를 더하거나 가리키는 op 만 `Removed_during_flight` 로 빼고, 나머지는 반영한다.

- 상관없는 쓰기 하나가 답 전체를 버리게 하지 않는다. 지금은 반영까지 간 답 19개 가운데 8개를 이렇게 버렸다(§1.1).
- 질문을 만든 뒤에 한 철회를 그 질문의 답이 되돌리지 못한다.
- `Make_room` 의 답은 다르다. 기다리는 사이 fact 가 지워졌으면 그 답은 이미 없는 Memory 를 두고 한 말이다. 반영하지 않고 센다.

### 8.4 읽은 자리가 움직이는 규칙

- `Read` 반영이 질문이 시작한 자리에서 이어지는 것은 묻기 번호와 취소 규칙이 지킨다. 읽은 자리를 옮기는 사건은 가던 묻기를 취소하고, 다른 묻기의 답은 늦은 답으로 버린다(§9.2). 받으면 `covers_through` 를 질문이 끝난 자리로 옮긴다.
- `Skip` 은 자기가 이름 붙인 것만 지나간다.
- `Restart_reading` 은 그 턴 기록의 처음으로 옮긴다.
- 그 밖에는 아무것도 자리를 옮기지 않는다. `Direct`, `Make_room`, `Adopt` 반영은 자리를 그대로 둔다.

### 8.5 직접 쓰기

Keeper 의 `memory_write` 와 철회, 운영자의 수정은 모델 없이 바로 반영된다. 밀리초 단위다.

```ocaml
type write =
  | Remember of { claim : string; category : Category.t; basis : Basis.t }
  | Supersede of { old : Memory_id.t; claim : string; category : Category.t; basis : Basis.t }
  | Retract of { id : Memory_id.t; reason : string }
```

| 쓰기 | 상태 | 답 |
|---|---|---|
| `Remember` | 없는 claim | 더한다 |
| `Remember` | 같은 claim, 같은 category 와 basis | `last_seen` 을 옮긴다 |
| `Remember` | 같은 claim, 다른 category 나 basis | `Already_held`. 바꾸지 않는다 |
| `Supersede` | `old` 가 있고 새 claim 은 없다 | `old` 를 `Superseded_by` 로 지우고 새 claim 을 더한다. 한 줄이다 |
| `Supersede` | `old` 도 새 claim 도 있다 | `old` 를 `Superseded_by` 로 지우고 새 claim 은 `last_seen` 만 옮긴다. 한 줄이다 |
| `Supersede` | `old` 가 없고 새 claim 은 있다 | 이미 된 것으로 답한다 |
| `Supersede` | 둘 다 없다 | `Refused Unknown_fact`. 더하지 않는다 |
| `Supersede` | `old` 가 새 claim 자신이다 | `Refused Supersedes_itself` |
| `Retract` | id 가 있다 | `Retracted` 로 지운다 |
| `Retract` | id 가 없다 | `Already_absent`. 성공도 거절도 아니다 |
| `Remember`, `Supersede` | 새 claim 이 파생인데 쓴 뒤에 그 근거가 Memory 에 없다 | `Refused (Premises_missing _)`. 없는 근거의 id 를 싣는다. 바꾸지 않는다 |
| `Remember`, `Supersede` | 파생 basis 의 모양이 틀렸다 | `Refused Malformed_derivation` |
| `Remember`, `Supersede` | 새 claim 이 비었다 | `Refused Blank_claim`. 스냅샷 codec 이 빈 claim 을 쓰지 않는다 |
| 모든 쓰기 | 쓰기가 온 trace 가 비었다 | `Refused Blank_trace`. 스냅샷 codec 이 trace 없는 `source` 를 읽지 않는다 |

- 표는 순수 함수 하나다(`Librarian_direct.plan`). 지금 Memory 와 쓰기에서 답을 낸다.
- 쓴 뒤에 근거를 본다. 근거를 잃은 파생 fact 는 같은 줄에서 `Support_lost` 로 지운다. 철회한 fact 에 기댄 fact 가 그렇게 같이 나간다.
- 쓰기가 말한 claim 은 그 확인 뒤에 Memory 에 있어야 한다. 없으면 쓰기를 거절한다. 없는 fact 에서 파생한 claim 이 그렇다. 자기가 대신하는 fact 에서 파생한 claim 도 그렇다. 지금과 같다.
- 「같은 category 와 basis」는 스냅샷에 적히는 모양이 같다는 뜻이다.
- 지금은 Librarian 이 넣은 fact 를 `Supersede` 하지 못한다. 그 거절은 없어진다. 철회와 쓰기를 따로 해도 같은 Memory 가 됐다.
- 지금은 `old` 가 없으면 지운 기록을 찾고, Librarian 이 지운 Keeper 의 fact 였으면 새 claim 을 쓴다. 이 설계는 기록을 찾지 않는다. 표의 「둘 다 없다」 행으로 답하고, Keeper 는 `Remember` 로 쓴다.

- 쓰기에 따로 붙이는 열쇠는 없다. fact 가 내용으로 이름 붙어 있어서 같은 쓰기가 두 번 와도 위 표가 답한다.
- 같은 쓰기는 실제로 다시 온다. masc 는 답한 tool 호출의 id 를 기억하지 않고, 모델이 같은 호출을 되풀이한다. 그래서 위 표의 「이미 있다」 행이 필요하다.
- 철회한 뒤에 같은 `Remember` 가 다시 오면 fact 가 다시 생긴다. 이 설계는 그것을 받아들인다.
- 운영자의 수정도 같은 문을 지난다. 그래서 운영자의 수정이 `Log_diverged` 를 만들지 않는다.
- 운영자의 철회 요청(`POST <k>/memory/retractions`)은 철회 여럿을 싣는다. 쓰는 쪽은 요청의 순서대로 하나씩 쓴다. 철회마다 줄이 하나다. 줄의 trace 는 요청의 `plan_id` 다.
- 그 요청은 스냅샷의 revision 이나 sha 를 싣지 않는다. 철회는 fact 의 id 로 대상을 정하고, id 는 claim 에서 나온다.
- 쓰는 쪽이 받지 않는 철회에서 요청이 끝난다. 그 앞의 철회는 반영된 채다. 같은 요청을 다시 보내면 그것들은 `Already_absent` 로 답한다.
- 쓰는 쪽은 등록된 Keeper 에게만 있다(§9.5). 그래서 꺼진 Keeper 의 Memory 는 운영자의 철회도 받지 않는다. Keeper 를 켠 뒤에 보낸다.
- `source_path` 가 붙은 claim 은 지금처럼 파일에 묶인 저장소로 간다(§11).
- 「admission 을 기다리는 쓰기」라는 상태는 없어진다.

Keeper 의 도구는 이 답을 영수증으로 옮긴다.

- 반영된 쓰기는 `inserted` 나 `reobserved` 다. `reobserved` 영수증에는 basis 가 없다. 반영 줄이 그 fact 의 basis 를 싣지 않는다.
- `Already_held` 는 성공으로 답하고 `already_held` 라고 적는다. `Already_done` 은 `already_superseded` 다. 둘 다 쓴 것이 없다.
- `Refused Unknown_fact` 는 `supersedes_not_current` 다. 영수증에 지운 기록은 없다.
- 철회의 `Already_absent` 는 지금처럼 `fact_not_found` 다.
- Memory 가 쓰기를 받지 않은 답은 `memory_unwritable` 하나다. 선 저장소, 등록부에 없는 Keeper, 쓰는 쪽을 시작하지 않은 프로세스가 그렇다. 이유를 함께 싣는다. 쓴 것은 없다.
- 쓰는 쪽이 답하지 못하고 예외로 끝나면 지금처럼 `persistence_failed` 다. 줄이 붙었는지 모른다.

### 8.6 boot

쓰는 쪽은 턴 기록을 쓰는 등록된 Keeper 마다 하나다. 등록된 Keeper 는 Keeper 등록부에 항목이 있는 Keeper 다. 사람 Keeper 에게는 쓰는 쪽이 없다(§11.1). 쓰는 쪽 등록부가 Keeper 등록부를 따른다.
함수 하나(`ensure k`)가 그 Keeper 의 산 쓰는 쪽을 돌려준다. 없거나 `Retired` 면 새로 만든다. 새 쓰는 쪽은 `Booting` 에서 시작하고, 만들어질 때의 lane 값을 받는다. 찾지 못한 그 걸음에서 등록부에 넣고, boot 의 I/O 는 그 뒤에 돈다. 등록되지 않은 Keeper 에게는 만들지 않는다.

- `ensure` 를 부르는 곳은 넷이다. view 읽기(§11.1), `Write`, `Turn_closed` 귀띔, pulse 다. pulse 는 등록된 Keeper 를 모두 돈다.
- pulse 는 등록부에 없는 Keeper 의 쓰는 쪽에 `Retire` 를 보낸다. Keeper 를 끄기만 하는 경로는 pulse 에 맡긴다. Keeper 를 지우는 경로는 등록부에서 뺀 뒤, 파일을 지우기 전에 `Retire` 를 보내고 `Retired` 를 기다린다. 아니면 묻기가 끝나면서 지운 스냅샷을 다시 만든다.
- Keeper 를 띄우는 길과 등록부에서 빼는 곳은 쓰는 쪽을 모른다. 띄우는 길은 여러 파일에 흩어져 있고(autoboot, dashboard, `keeper_up` 의 만들기와 고치기, direct message 뒤의 재시작, supervisor), 빼는 곳은 여섯이다. 곳마다 넣으면 하나가 빠진다.
- 그래서 등록된 Keeper 는 한 pulse 안에 산 쓰는 쪽을 갖는다. 프로세스가 시작한 뒤에도, 껐다가 다시 켠 뒤에도 같다.
- 턴은 등록된 Keeper 에게만 돈다(`keeper_turn.ml:227-236`). 그래서 턴이 보내는 쓰기는 쓰는 쪽을 만난다.
- 값: 등록되지 않은 Keeper 의 Memory 는 그 쓰는 쪽이 물러난 뒤에는 운영자 route 로도 고치지 못한다. 물러나는 것은 한 pulse 안이다. 답은 `Refused Keeper_retired` 다. Keeper 를 켠 뒤에 고친다.

쓰는 쪽 등록부(`Librarian_writers`)가 이것을 한다.

- 등록부는 Keeper 이름에서 쓰는 쪽으로 가는 표 하나다. 표는 읽은 그 표일 때만 바꾼다(compare-and-set). 그래서 찾기와 넣기가 한 걸음이고, 어느 domain 에서 불러도 같다. 진 쪽이 만든 쓰는 쪽은 돈 적이 없어 그냥 버린다.
- 쓰는 쪽을 만드는 곳과 그 fiber 가 도는 곳은 다르다. 만드는 곳은 처음 물은 곳이고 어느 domain 이든 된다. fiber 는 등록부를 만든 domain 에서 돈다. 등록부의 fiber 하나가 새 쓰는 쪽을 받아 띄운다.
- `registered` 는 등록부가 받는 함수 하나다. 그 Keeper 가 Keeper 등록부에 있고 턴 기록을 쓰는지 답한다. `ensure` 와 쓰는 쪽의 `Retire` 가 같은 함수를 본다.
- 쓰기와 운영자 행동은 `ensure` 로 쓰는 쪽을 찾아 보낸다. 쓰는 쪽이 받기 전에 끝났으면 다시 찾는다. 쓰는 쪽이 없으면, 곧 등록되지 않은 Keeper 면 `Keeper_retired` 다. 다른 까닭으로는 그 답이 나오지 않는다.
- view 는 기다리지 않는다. 찾은 쓰는 쪽이 내놓은 값을 읽는다. 그사이 끝난 쓰는 쪽이면 다시 찾는다.
- 물러난 쓰는 쪽은 표에서 빠진다. 표에 있는 것이 그 쓰는 쪽일 때만 뺀다. 그사이 다시 등록된 Keeper 의 새 쓰는 쪽은 그대로 둔다.
- pulse 는 받은 Keeper 이름마다 `ensure` 를 부르고, 표에 있는데 등록되지 않은 Keeper 의 쓰는 쪽을 물러나게 한다. 물러남의 답을 하나씩 기다린다.

쓰는 쪽은 스냅샷 파일이 새 revision 을 갖게 된 것을 알린다.

- 알리는 때는 둘이다. 스냅샷을 다시 쓴 반영 뒤와 저장소가 열린 때다.
- 신호는 지금 있는 것이다(`Keeper_memory_commit_notifications`). workspace memory curator 와 Memory 건강 화면이 이 신호로 Memory 를 다시 읽는다.
- 신호는 깨우기만 한다. 받는 쪽은 스냅샷을 읽는다. 같은 revision 이 두 번 와도 된다.
- 줄은 붙었는데 스냅샷을 쓰지 못한 반영은 알리지 않는다. 그 스냅샷을 쓰는 boot 가 저장소를 열면서 알린다.
- 쓰기를 보낸 쪽이 답을 먼저 받는다.

boot 는 새 쓰는 쪽이 맨 먼저 하는 일이다. 서버가 checkpoint 꼬리를 복구한 뒤에 돈다. Keeper 마다 fiber 하나라서, 느린 boot 는 자기 Keeper 의 Memory 만 늦춘다.
그 전에 턴 기록에는 `Log_started` 가 있다. 프로세스가 시작할 때와 저장소 시작의 첫 단계가 쓴다(§5.2, 아래).

- **Keeper 는 쓰는 쪽을 기다리지 않는다.** 쓰는 쪽에 view 가 없는 동안(`Booting`, `Stopped`) 요청은 seed 시작점을 쓴다(§11.1). 쓰기는 boot 가 끝날 때까지 mailbox 에서 기다리고, boot 가 `Stopped` 로 끝나면 거절된다.
  - Keeper 를 띄우는 길(autoboot, supervisor, dashboard, `keeper_up`, direct message)은 어느 것도 Librarian 의 파일을 보지 않는다. 쓰는 쪽을 만들지도 않는다.
  - 그래도 안 읽고 지나가는 턴이 없다. boot 가 멈춘 사이에 닫힌 턴은 턴 기록에 줄로 남고, 다음 boot 가 아래 표대로 읽는다.
- 꼬리 줄은 줄바꿈으로 끝나는 마지막 줄이다. 그 뒤의 바이트는 끊긴 덧붙임이라 버린다. 그런 줄이 하나도 없는 반영 기록은 없는 것으로 본다.
- 이 규칙은 덧붙이는 helper 가 끊긴 조각을 잘라 낸 뒤에 쓸 때만 맞다. 두 기록은 `append_private_jsonl_durable_locked_at_end_offset_result` 로만 덧붙인다. 일반 줄 쓰기(`Fs_compat.append_jsonl`)는 조각 뒤에 줄바꿈을 먼저 써서, 조각이 줄바꿈으로 끝난 깨진 줄로 남는다. 그 helper 로 이 파일들에 쓰는 코드는 없어야 한다(시험은 §20 의 L3a 와 L5).

| 반영 기록 | 그 밖 | 결과 |
|---|---|---|
| 없다 | 턴 기록 파일이 있다 | 첫 boot 다. 스냅샷 파일이 없으면 빈 envelope 을 쓰고 그 sha 를 쓴다. 있는데 해석되지 않으면 `Stopped Memory_unreadable`. `Started` 를 `Log_started` 자리에 쓴다. 그 뒤의 줄은 턴 줄이든 `Reset` 이든 모두 읽는다 |
| 있다 | 꼬리 줄이 해석되지 않는다 | `Stopped Log_unreadable`. 읽은 자리가 그 줄에 있었다 |
| 있다 | 스냅샷이 없거나 해석되지 않는다 | `Stopped Memory_unreadable`. 파일을 되돌려 놓고 `Resume` 한다 |
| 있다 | 스냅샷 sha 가 꼬리 줄의 `after` 다 | 복구됐다 |
| 있다 | 스냅샷 sha 가 꼬리 줄의 `basis` 다 | 5단계를 그 줄에서 다시 한다. 결과의 sha 가 `after` 가 아니면 `Stopped (Log_diverged _)`. 그 줄에서 스냅샷이 만들어지지 않을 때도 같다. 쓰지 않는다 |
| 있다 | 둘 다 아니다 | `Stopped (Log_diverged _)` |
| 없다 | 턴 기록 파일이 없다 | `Stopped Store_unwritable`. `Started` 는 턴 기록의 id 를 적어야 하고, 쓰는 쪽은 그 파일을 만들지 않는다. 턴 기록의 첫 줄이 `Log_started` 가 아닐 때도 같다. 저장소 시작의 첫 단계가 그 줄을 쓴 뒤라서, 이 행은 그사이 파일이 지워졌을 때다 |
| – | 반영 기록이나 스냅샷을 읽는 I/O 가 실패한다 | `Stopped Store_unwritable`. 해석되지 않는 꼬리, 없는 스냅샷과 다르다. `Adopt` 나 파일 되돌리기가 아니라 `Resume` 이 다시 읽어 본다 |
| – | 잠금을 잡지 못한다 | `Stopped Store_unwritable`. `Resume` 이 다시 해 본다 |
| – | boot 가 하는 쓰기(빈 envelope, `Started`, 스냅샷 다시 쓰기)가 실패한다 | `Stopped Store_unwritable` |

- boot 는 첫 boot 행에서만 줄을 쓴다. 두 번 복구해도 한 번 한 것과 같다.
- 첫 boot 는 스냅샷을 먼저 쓰고 `Started` 를 나중에 쓴다. 그 사이에 죽으면 다음 boot 가 그 스냅샷으로 첫 boot 를 다시 한다.
- 스냅샷의 sha 는 파일에 있는 바이트의 sha 다. 해석한 값을 다시 인코딩해서 내지 않는다.
- 스냅샷과 반영 기록은 설정 쪽 Keeper 디렉터리에 있고, 턴 기록은 실행 쪽 Keeper 디렉터리에 있다. 저장소는 두 디렉터리를 따로 받는다.
- **반영 기록이 없으면 언제나 첫 boot 다.** 턴 기록에 무엇이 있든 같다. 「반영 기록이 없다」는 읽었다는 기록이 없다는 뜻이다. 아무것도 읽지 않았다는 주장이 아니다. 그래서 `Log_started` 부터 읽고, 틀리는 방향은 한 번 더 읽는 쪽뿐이다.
  - 첫 boot 가 멈춘 사이에 Keeper 가 닫은 턴과, 서버가 없을 때 CLI purge 가 쓴 `Reset` 줄이 그렇게 읽힌다. `Adopt` 는 이 길에 없다.
  - 「반영 기록이 없는데 턴 줄이 있으면 잃은 기록」으로 가르지 않는다. 그렇게 가르려면 Keeper 의 첫 턴이 `Started` 를 기다려야 하고, 그 기다림을 Keeper 를 띄우는 길마다 넣어야 한다. 길 하나가 빠지면 `Adopt` 가 턴을 안 읽고 지나간다.
- 값: 반영 기록 파일이 없어지면 첫 boot 로 읽힌다. 경보는 없다.
  - 턴 기록을 처음부터 한 번 더 읽는다. 턴 기록은 잘리지 않으므로 그 Keeper 가 산 동안 전부다. 그만큼을 lane 의 값으로 다시 읽는다.
  - Keeper 가 그사이 철회한 claim 이 다시 들어올 수 있다.
  - 앞선 sweep 이 지운 bundle 을 가리키는 줄은 `Skip (Content_missing _)` 으로 지나간다.
  - 디스크의 스냅샷을 `Adopt` 없이 Memory 로 받는다.
  - 행에서 알아볼 수 있다. 반영 기록의 첫 줄 시각과 턴 기록의 `Log_started` 시각을 나란히 싣는다(§12.1). 수준은 없다.
  - 지금부터 새로 시작하려면 턴 기록도 같이 지운다(§18.5).
- Keeper 의 저장소 시작은 함수 하나의 두 단계다. 턴 기록 모듈이 파일과 `Log_started` 가 있는지 확인하고, 그다음 쓰는 쪽이 boot 한다. `ensure` 가 쓰는 쪽을 만들 때 하고, `Stopped` 에서 `Resume` 하면 두 단계를 다시 한다. 첫 단계는 owner 의 자리를 기다리지 않는다(§5.2). 쓰는 쪽은 턴 기록을 읽기만 한다.
  - 첫 단계는 첫 줄만 읽는다(`Keeper_turn_log_store.read_start`). 첫 줄이 있으면 아무것도 더 읽지 않는다. 마지막 줄, Keeper 의 메타데이터, 내용 저장소를 읽지 않으니, 이미 시작한 Keeper 의 boot 에 새 멈춤을 더하지 않는다.
  - 완전한 줄이 없으면 메타데이터로 session 을 찾고, 지금 끝자리로 `Log_started` 하나를 덧붙인다. 열린 턴을 닫지 않는다. 프로세스 시작 단계와 다른 점이다. 저장소 시작은 턴이 도는 동안 온다.
  - 첫 줄을 써야 하는데 쓰지 못하면 `Stopped Store_unwritable` 이고 그 까닭을 로그에 남긴다. 첫 줄을 읽지 못하면 로그만 남기고 boot 가 늘 하던 대로 읽는다.
  - 쓰는 쪽은 서버가 넘긴 함수를 부르기만 한다. 턴 기록 모듈이 쓰는 쪽 표를 부르므로(§9.5 의 알림), 표가 그 모듈을 직접 부르면 고리가 생긴다.
- 쉬던 상태, 마지막 묻기의 결과, 폭 기억, 바닥에서 받은 크기 사실, Memory 없이 읽었다는 표시는 되살리지 않는다. 메모리에만 있던 값이다. 대가는 §7.7 에 있다. `Stopped` 에서 `Resume` 하는 것도 boot 다.
- 재시작 때 가던 묻기는 다시 묻는다. Keeper 마다 생성 하나까지다.
- 턴 기록이 바뀌었거나 잘렸거나 읽히지 않는 것은 boot 가 보지 않는다. 「안 읽은 것이 있다」가 그것을 세고(§9.2), 첫 묻기가 입력 결함으로 알린다(§5.4).

### 8.7 맡김

맡김(`Adopt`)은 운영자가 「디스크에 있는 이 바이트가 맞다」고 말하는 일이다. `Log_diverged` 와 `Log_unreadable` 에서 나가는 문이다.
쓰는 쪽은 파일의 sha 가 운영자가 말한 값(`observed`)과 같고 스냅샷 codec 으로 해석될 때만 받는다. sha 가 다르면 `Refused Snapshot_mismatch`, sha 는 같은데 해석되지 않으면 `Refused Snapshot_unreadable` 이다. 거절하면 아무것도 바꾸지 않는다.

| 멈춘 이유 | 덧붙이는 줄 | 읽기가 이어지는 곳 |
|---|---|---|
| `Log_diverged` | `Committed {cause = Adopt; basis = 마지막 줄의 after; after = observed}` | 마지막 줄의 자리. 같은 턴 기록을 가리킨다 |
| `Log_unreadable` | `Started` 줄. `snapshot` 은 `observed`, `turn_log_offset` 은 `Log_started` 자리, `covered` 는 `Log_started.mark` 다 | 턴 기록의 처음. 첫 boot 와 같다. 자리는 해석되지 않는 줄에 있었다 |

- 쓰는 쪽은 자기가 쓰지 않은 바이트의 자리를 짐작하지 않는다. 행마다 아직 정의된 자리는 하나뿐이다.
- 어느 행인지는 맡길 때 읽은 꼬리 줄이 정한다. 멈출 때 적은 이유로 정하지 않는다. 꼬리 줄이 해석되면 첫째 행이다. 해석되지 않거나 줄이 하나도 없으면 둘째 행이다.
- 둘째 행의 `Started` 는 해석되지 않는 줄 바로 뒤에 덧붙인다. 그 줄은 지우지 않는다.
- 스냅샷 파일은 쓰지 않는다. 줄 하나만 덧붙인다.
- 둘째 행에서는 턴 기록을 처음부터 한 번 더 읽는다. 지나치는 줄은 없다. 값은 반영 기록이 없어졌을 때와 같다(§8.6).
- 읽은 자리를 모를 때 하는 일은 어디서나 하나다. 처음부터 읽는다. 첫 boot, 이 행, `Restart_reading` 이 같다.

### 8.8 왜 턴마다 한 번만 반영되고 빠지지 않나

- 사슬: 2단계가 스냅샷이 앞 줄의 `after` 인 것을 확인한 뒤에만 줄을 쓴다. 그래서 `basis(n+1) = after(n)` 이다.
- 스냅샷은 기록보다 한 줄까지만 늦다. 스냅샷을 쓰는 곳은 5단계와 boot 의 다시 쓰기뿐이다.
- 복구는 몇 번 해도 같다.
- `Read` 범위는 자리 규칙 때문에 이어지고 겹치지 않는다. 자리를 옮기는 다른 것은 `Skip` 과 `Restart_reading` 이고, 둘 다 지나친 것을 줄에 적는다.
- fact 는 내용으로 이름 붙는다. 가진 것을 다시 더하면 건드리기만 한다.
- Keeper 마다 쓰는 쪽이 하나고 묻기가 하나다. 답은 묻기 번호가 지금 것이고 되돌려 적은 id 가 맞을 때만 반영한다.

## 9. 상태 기계

쓰는 쪽은 Keeper 마다 fiber 하나다. mailbox 에서 사건을 하나씩 꺼내 다룬다. 이 절은 상태 일곱과 사건 열둘의 모든 쌍에서 쓰는 쪽이 무엇을 하는지 정한다.
근거 폴더의 스크립트가 이 절의 표를 그대로 읽는다. 쌍 84개 가운데 행이 없는 쌍, 조건 없이 겹치는 행, 모르는 상태나 사건 이름이 있으면 실패한다. 묻기 결과 표의 32쌍도 같이 본다. 조건들이 모든 경우를 덮는지는 스크립트가 보지 않고 모델이 본다(§21). 다만 한 항목의 slot 별 판정에 기대는 행은 L7 전까지 모델도 보지 않는다(§21.5). 그 행들은 §7.4 의 표를 글로 읽은 것이 전부다.

### 9.1 상태와 사건

```ocaml
type state =
  | Booting
  | Idle                    (* 안 읽은 것이 없거나 lane 이 꺼져 있다 *)
  | Asking of asking        (* 묻기 하나가 가고 있다 *)
  | Resting                 (* 안 읽은 것이 있고 마지막 묻기가 반영 없이 끝났다. 다음 pulse 에 다시 묻는다 *)
  | Refused_at_bottom       (* 맨 앞 항목의 질문을 선언한 slot 이 모두 크기로 거절했다 (§7.4) *)
  | Stopped of store_stop   (* Memory 저장소를 믿거나 쓸 수 없다 *)
  | Retired
and asking =
  { ask : int; since : float; asked : ask
  ; lane : Librarian_machine.declared                (* 묻기를 시작할 때의 lane 값과 그 registry 풀이 *)
  ; removed_since : (Memory_id.t * int) list }       (* 묻는 사이 직접 쓰기가 지운 fact 와 그 줄의 seq *)
type store_stop =
  | Log_diverged of { expected : Sha256.t; observed : Sha256.t }
  | Memory_unreadable | Log_unreadable | Store_unwritable

type event =
  | Boot_finished of boot_result | Turn_closed | Pulse
  | Write of actor * write
  | Ask_ended of { ask : int; result : ended }
  | Declaration_changed of lane option
  | Operator of operator_act          (* Resume, Skip_item, Skip_line, Restart_reading, Adopt *)
  | Retire
and ended = Read_ended of read_result | Room_ended of room_result
```

- 상태 옆에 쓰는 쪽이 메모리에 두는 값이 있다. 폭 기억, 바닥의 크기 사실, Memory 없이 읽었다는 표시, 마지막 묻기의 결과, 마지막 자리 내기의 결과, lane 값, 턴 기록을 마지막으로 본 길이, 그리고 view 다(§11.1).
- 이 값들은 디스크에 두지 않는다. 재시작하면 반영 기록의 꼬리 줄에서 view 를 다시 만들고 나머지는 비운다.
- 결과 타입은 물은 것에 따라 둘이다. 읽는 질문(`Read_range`, `Read_item_alone`)은 `read_result` 로 끝난다. §7.1 의 `ask_result` 다. 자리 내기는 `room_result` 로 끝난다. 자리 내기는 턴 기록을 읽지 않아서, 그 타입에는 입력 결함도 읽을 것 없음도 없다. 그래서 표에 일어날 수 없는 칸이 없다.
- `Stopped` 는 Memory 저장소에만 쓴다. 턴 기록의 결함은 쓰는 쪽을 멈추지 않는다. 읽기만 쉬고 직접 쓰기는 계속 반영된다.

### 9.2 규칙

표가 이름으로 부르는 규칙이다.

**안 읽은 것이 있다.** 순수 함수 하나다. 쓰는 쪽, 묻는 fiber, 경보(§12.2)가 같은 함수를 쓴다. 다음 가운데 하나면 참이다.

- `turn_log_offset` 뒤에 항목이 든 단위가 있다.
- `turn_log_offset` 뒤에 알리지 않은 reset 이나 해석되지 않는 줄이 있다.
- 턴 기록의 id 가 마지막 반영 줄이 적은 id 와 다르다.
- `turn_log_offset` 이 파일 끝을 넘거나 줄 시작이 아니다.

뒤의 둘은 파일이 바뀌었거나 잘린 경우다. 그때도 묻기를 시작해야 묻는 fiber 가 입력 결함을 알린다.

읽는 쪽은 이 함수가 참인 바이트에서 `Nothing_to_ask` 를 돌려주지 않는다. 알리지 않은 reset 이나 해석되지 않는 줄 앞에 항목이 든 단위가 없으면, 읽는 쪽은 그 줄을 `Span_unknown` 이나 `Line_unreadable` 로 알린다. 앞에 놓인 항목 없는 단위는 그 건너뜀 반영과 같이 지나간다. 「그 줄이 첫 안 읽은 줄일 때만 알린다」로 쓰면, 항목 없는 단위 하나가 앞에 있을 때 읽는 쪽은 물을 것이 없다고 하고 이 함수는 있다고 한다. 그러면 pulse 도 없이 같은 묻기가 되풀이된다.

**다음 묻기.** lane 이 켜져 있고 안 읽은 것이 있으면 `Read_range (폭 기억이 정한 폭)` 을 시작하고 `Asking` 으로 간다. 아니면 `Idle` 이다. 그때 본 턴 기록의 길이를 적어 둔다.
바닥의 질문을 따로 기억하지 않는다. 판정이 끝난 바닥에서는 이 묻기가 아무 slot 도 부르지 않고 크기 사실로 끝난다(§7.4).

**늦은 답.** 묻기 번호가 지금 것이 아닌 `Ask_ended` 는 어느 상태에서든 버린다. 답을 실은 것이었으면 센다. 묻기 번호는 프로세스 안에서 되돌아가지 않는다.

**반영 실패.**

- 쓰기 전 상태가 마지막 줄과 다르다 → `Stopped (Log_diverged _)`.
- 줄이 디스크에 닿기 전에 IO 가 실패했다 → 부른 쪽에 `Refused (Store_stopped _)` 로 답하고 `Stopped Store_unwritable`.
- 줄이 닿은 뒤 스냅샷 쓰기가 실패했다 → 부른 쪽에는 평소대로 답하고 `Stopped Store_unwritable`. boot 가 그 줄에서 스냅샷을 다시 쓴다.
- `Stopped` 로 가면 가던 묻기를 취소한다. 멈췄다는 줄은 쓰지 않는다. boot 가 디스크에서 다시 계산한다.

**선언 변경.** lane 값은 질문 쪽(프롬프트, 답 schema, 출력 몫, thinking)과 slot 목록이다. slot 은 풀린 창까지 값에 든다.
HTTP slot 의 창은 registry 가 게시할 때 target 옆에 고정한 값이다. CLI slot 의 창은 물을 때의 runtime 표에서 읽는다. CLI 호출도 그 표를 읽는다.
lane 값이 없는 때가 있다. 표가 없다, 꺼져 있다, 받아들인 slot 이 없다, R 을 적지 않았다, 창을 모르는 slot 이 있다(`Window_unknown {slot}`). 모두 선언이 없는 것과 같이 다룬다(W1).
`slots` 의 id 가 runtime 을 가리키지 않으면 로드가 거절한다. 그 뒤에 창을 모르는 slot 은 둘뿐이다. registry 가 창 없이 고정한 HTTP target 과, 지금 runtime 표에 없는 CLI id 다.

- 지금 가진 값과 같은 `Declaration_changed` 는 표에 닿지 않는다. runtime 표나 registry 가 다시 게시될 때마다 이 사건이 온다. 상태는 그대로이고 같이 온 풀이만 갈아 둔다. 풀이는 registry 가 고정한 target(credential, 본문 시한)과 provider 가 쥔 slot 이다. credential 이나 본문 시한은 lane 값에 들지 않으니, 그것만 바뀐 게시는 같은 값으로 온다. 다음 묻기와 쉼의 확인은 새 풀이를 읽는다. 나가 있는 묻기는 자기 풀이로 끝난다.
- 질문 쪽이 바뀌거나 lane 이 켜지고 꺼지면 가던 묻기를 취소한다. 옛 질문으로 만든 것은 반영되지 않는다.
- slot 목록만 바뀌면 묻기는 끝까지 간다. 답은 반영한다. 선언에서 빠진 slot 의 결과는 읽지 않는다.
- 어느 쪽이든 새 값을 저장하고 폭 기억을 비운다. 바닥의 크기 사실은 건드리지 않는다. 바뀐 slot 은 key 가 다르고 바뀐 질문은 id 가 다르다(§7.4).

**건너뛰기 셋.** `Skip_item`, `Skip_line`, `Restart_reading` 이다. 조건은 §12.4 에 있고, 반영하는 순간 디스크에서 다시 읽는다.
받으면 가던 묻기를 취소하고, `Skip` 줄을 반영하고, 바닥의 크기 사실과 마지막 묻기의 결과를 비우고, 다음 묻기로 간다. 지나간 줄에 대한 결과로 오류를 띄워 두지 않는다(§12.2). `Restart_reading` 은 폭 기억도 비운다. 거절하면 아무것도 바꾸지 않는다.

### 9.3 표

「반영」은 §8.2 의 여섯 단계다. 반영이 실패하면 어느 칸에서든 위의 반영 실패 규칙을 따른다.
줄을 쓰지 않는 쓰기는 답만 한다. §8.5 의 표에서 `Already_held`, 「이미 된 것」, `Already_absent`, `Refused _` 로 답하는 쓰기다. 그때 상태는 그대로다.
같은 claim 을 다시 쓰는 `Remember` 는 `last_seen` 을 옮기므로 줄을 쓴다. 표의 `Write` 행을 따른다.

**`Booting`**

| 사건 | 하는 일 |
|---|---|
| `Boot_finished` | boot 표(§8.6). `Stopped _` 이거나 다음 묻기 |
| `Ask_ended` | 늦은 답 |
| `Turn_closed`, `Pulse`, `Write`, `Declaration_changed`, `Resume`, `Skip_item`, `Skip_line`, `Restart_reading`, `Adopt`, `Retire` | mailbox 에서 기다린다. boot 가 끝나면 온 순서대로 다룬다 |

**`Idle`**

| 사건 | 하는 일 |
|---|---|
| `Turn_closed` | 다음 묻기 |
| `Pulse` | 턴 기록의 길이를 본다(stat). 적어 둔 길이와 같으면 `Idle` 이고 읽지 않는다. 다르면 다음 묻기 |
| `Write` | 반영하고 답한다 → `Idle` |
| `Ask_ended` | 늦은 답 |
| `Declaration_changed` | 저장하고 폭 기억을 비운다 → 다음 묻기 |
| `Resume` | `Refused Nothing_to_resume` |
| `Skip_item`, `Skip_line`, `Restart_reading` | 건너뛰기 규칙 |
| `Adopt` | `Refused Not_stopped` |
| `Retire` | 파일을 닫고 잠금을 놓는다 → `Retired` |
| `Boot_finished` | 버린다 |

**`Asking a`**

| 사건 | 하는 일 |
|---|---|
| `Turn_closed`, `Pulse` | `Asking a` |
| `Write` | 바로 반영하고 답한다. fact 를 지웠으면 그 id 를 `a.removed_since` 에 더한다 → `Asking a`. 쓰기는 모델을 기다리지 않는다 |
| `Ask_ended`, 지금 묻기 | 아래 표 |
| `Ask_ended`, 다른 번호 | 늦은 답 |
| `Declaration_changed`, 질문 쪽이 다르거나 lane 이 꺼진다 | 묻기를 취소하고 저장하고 폭 기억을 비운다 → 다음 묻기, lane 이 꺼졌으면 `Idle` |
| `Declaration_changed`, slot 목록만 다르다 | 저장하고 폭 기억을 비운다 → `Asking a` |
| `Resume` | `Refused Nothing_to_resume` |
| `Skip_item`, `Skip_line`, `Restart_reading` | 건너뛰기 규칙 |
| `Adopt` | `Refused Not_stopped` |
| `Retire` | 묻기를 취소한다 → `Retired` |
| `Boot_finished` | 버린다 |

지금 묻기가 끝났을 때다. 읽는 질문 둘은 앞의 여섯 행이 같다.

| 물은 것 | 결과 | 하는 일 |
|---|---|---|
| 읽는 질문 | `Nothing_to_ask` | 다음 묻기 |
| 읽는 질문 | `Nothing_readable` | `Skip (Content_missing _)` 을 반영한다 → 다음 묻기 |
| 읽는 질문 | `Span_unknown` | `Skip (Unknown_span _)` 을 반영한다. 모델을 부르지 않았다 → 다음 묻기 |
| 읽는 질문 | `Memory_diverged` | `Stopped (Log_diverged _)` |
| 읽는 질문 | `Snapshot_fault` | `Stopped`. 없음·스냅샷 아님은 `Memory_unreadable`, 읽기 실패는 `Store_unwritable` |
| 읽는 질문 | `Input_fault`, `Ask_failed` | `Resting` |
| `Read_range` | `Answered` | 반영한다. 폭 기억에 반영한 수를 알린다. Memory 없이 읽었다는 표시를 내리고 마지막 자리 내기의 결과를 비운다. Memory 를 실은 질문에 답이 왔으니 Memory 는 slot 에 들어간다 → 다음 묻기 |
| `Read_range`, 한 항목보다 넓다 | `Refused_by_lane` | 폭 기억에 거절을 알린다 → 다음 묻기(줄인 폭으로 바로) |
| `Read_range`, 한 항목보다 넓다 | `Silent_lane` | `Resting` |
| `Read_range`, 한 항목 | `Refused_by_lane`, `Silent_lane` | §7.4 의 표. 그 항목만 묻기, `Refused_at_bottom`, `Resting` 가운데 하나 |
| `Read_item_alone` | `Answered` | `Add` 와 `Keep` 만 반영한다. Memory 없이 읽었다는 표시를 올린다. 묻는 사이 지워진 fact 가 없고 lane 값이 그대로면 바로 `Make_room` 을 묻는다. 아니면 다음 묻기 |
| `Read_item_alone` | `Refused_by_lane`, `Silent_lane` | §7.4 의 표. `Skip (Item_exceeds_window)` 반영, `Refused_at_bottom`, `Resting` 가운데 하나 |
| `Make_room` | `Room_answered` | 효과 있는 op 가 있고 묻는 사이 지워진 fact 가 없으면 반영한다. 마지막 자리 내기의 결과에 적는다 → 다음 묻기 |
| `Make_room` | `Room_refused`, `Room_silent`, `Room_failed` | 마지막 자리 내기의 결과에 적는다 → 다음 묻기 |
| `Make_room` | `Memory_diverged` | `Stopped (Log_diverged _)` |
| `Make_room` | `Snapshot_fault` | 읽는 질문과 같다 |

- `Refused_by_lane` 과 `Silent_lane` 은 지금 선언된 slot 의 결과만으로 다시 정한다. 묻는 사이 선언에서 빠진 slot 이 한 거절은 세지 않는다. 남은 slot 가운데 거절한 것이 없으면 말 없음이다.
- 묻는 사이에 lane 값이 바뀌었고 지금 선언된 slot 가운데 결과가 있는 것이 하나도 없으면, 답이 아닌 결과는 `Resting` 으로 가지 않고 다음 묻기다. 그 묻기는 지금 lane 값으로 가므로 되풀이되지 않는다. 운영자가 방금 선언한 lane 에 pulse 한 번을 기다리지 않고 묻는다.
- 한 항목에서 「입력」과 「모두」를 읽는 것은 결과가 본 스냅샷이 지금의 스냅샷일 때뿐이다. 아니면 다음 묻기다(§7.4).
- 자리 내기의 결과는 마지막 묻기의 결과를 갈아 쓰지 않는다. 그래서 자리 내기는 경고를 켜지도 읽기를 세우지도 않는다. 결과는 온 그대로 적고, 물을 때의 Memory sha 와 lane 값을 같이 적는다. 모든 slot 이 입력 크기로 거절했고 그 둘이 지금 것과 같을 때만 E5 가 켜진다(§12.2).

**`Resting`**

| 사건 | 하는 일 |
|---|---|
| `Turn_closed` | `Resting` |
| `Pulse` | 선언한 slot 이 모두 provider 가 잡아 둔 slot 이면 `Resting` 이고 읽지 않는다. 아니면 다음 묻기 |
| `Write` | 반영하고 답한다 → `Resting` |
| `Ask_ended` | 늦은 답 |
| `Declaration_changed` | 저장하고 폭 기억을 비운다 → 다음 묻기, lane 이 꺼졌으면 `Idle` |
| `Resume` | 바닥의 크기 사실을 비운다 → 다음 묻기 |
| `Skip_item`, `Skip_line`, `Restart_reading` | 건너뛰기 규칙 |
| `Adopt` | `Refused Not_stopped` |
| `Retire` | `Retired` |
| `Boot_finished` | 버린다 |

**`Refused_at_bottom`**

| 사건 | 하는 일 |
|---|---|
| `Turn_closed`, `Pulse` | `Refused_at_bottom`. 묻지도 읽지도 않는다 |
| `Write` | 반영하고 답한다 → 다음 묻기. Memory 가 바뀌었으면 Memory 를 실은 질문이 새 질문이다 |
| `Ask_ended` | 늦은 답 |
| `Declaration_changed` | 저장하고 폭 기억을 비운다 → 다음 묻기, lane 이 꺼졌으면 `Idle` |
| `Resume` | 바닥의 크기 사실을 비운다 → 다음 묻기 |
| `Skip_item`, `Skip_line`, `Restart_reading` | 건너뛰기 규칙 |
| `Adopt` | `Refused Not_stopped` |
| `Retire` | `Retired` |
| `Boot_finished` | 버린다 |

줄을 쓰지 않은 쓰기는 묻기를 시작하지 않는다. 상태가 그대로다(위). 줄을 쓴 쓰기는 모두 질문 바이트를 바꾼다. `last_seen` 만 옮겨도 그렇다. 질문이 fact 마다 그 값을 싣는다(§6).
Memory 를 바꾼 쓰기 뒤에는 새 질문을 slot 마다 한 번 묻는다. 그 묻기가 가는 동안 상태는 `Asking` 이다. E2 는 꺼지고 W1 이 켜진다. 옛 Memory 에 대한 판정으로 오류를 띄워 두지 않는다(§12.2).

**`Stopped s`**

| 사건 | 하는 일 |
|---|---|
| `Turn_closed`, `Pulse` | `Stopped s` |
| `Write` | `Refused (Store_stopped s)` |
| `Ask_ended` | 늦은 답 |
| `Declaration_changed` | 저장하고 폭 기억을 비운다 → `Stopped s` |
| `Resume` | `Booting`. 저장소 시작을 다시 한다. 턴 기록 모듈이 파일을 확인하고, 그다음 boot 다(§8.6) |
| `Adopt`, s 가 `Log_diverged` 나 `Log_unreadable` 이고, 파일의 sha 가 `observed` 와 같고 codec 으로 해석된다 | §8.7 의 줄을 쓴다. 폭 기억을 비운다 → 다음 묻기 |
| `Adopt`, s 가 그 둘인데 파일의 sha 가 다르다 | `Refused Snapshot_mismatch` |
| `Adopt`, s 가 그 둘이고 sha 는 같은데 파일이 해석되지 않는다 | `Refused Snapshot_unreadable` |
| `Adopt`, s 가 `Memory_unreadable` 이나 `Store_unwritable` | `Refused (Store_stopped s)` |
| `Skip_item`, `Skip_line`, `Restart_reading` | `Refused (Store_stopped s)` |
| `Retire` | `Retired` |
| `Boot_finished` | 버린다 |

**`Retired`**

| 사건 | 하는 일 |
|---|---|
| `Write`, `Resume`, `Skip_item`, `Skip_line`, `Restart_reading`, `Adopt` | `Refused Keeper_retired` |
| `Turn_closed`, `Pulse`, `Ask_ended`, `Declaration_changed`, `Retire`, `Boot_finished` | `Retired` |

`Retire` 는 등록부에 없는 Keeper 의 쓰는 쪽에만 사건이다. 쓰는 쪽은 `Retire` 를 꺼낼 때 그 Keeper 가 등록부에 있으면 버린다. 꺼졌다가 그사이 다시 켜진 Keeper 다. 등록부에 없으면 어느 상태에서든 파일을 닫고 잠금을 놓는다. `Retired` 인 쓰는 쪽은 산 것으로 치지 않는다. 그 Keeper 가 다시 등록되면 `ensure` 가 새 쓰는 쪽을 만든다(§8.6). 그래서 등록된 Keeper 의 쓰기는 `Keeper_retired` 로 거절되지 않는다.
등록되지 않은 Keeper 에게는 쓰는 쪽을 만들지 않는다. 그 Keeper 에게 온 쓰기는 `Refused Keeper_retired` 다.

표의 칸을 판단하는 코드는 fiber 와 떨어져 있다(`Librarian_machine`). 상태와 사건을 받아 다음 상태와 답을 돌려주는 동기 함수다. I/O 는 저장소가 한다.

- `Booting` 은 그 함수의 상태가 아니다. fiber 가 boot 를 먼저 돌고 그 뒤에 mailbox 를 꺼낸다. 그래서 boot 중에 온 사건은 mailbox 에서 기다린다.
- `Resume` 의 답 `Done` 은 boot 가 돌았다는 뜻이다. 어떻게 끝났는지는 상태가 말한다.
- `Adopt` 가 줄을 덧붙이다 I/O 로 실패하면 `Refused (Store_stopped Store_unwritable)` 로 답한다. 상태는 멈춘 그대로다.
- 계획의 효과로 스냅샷이 만들어지지 않으면 쓰기를 거절하고 아무것도 쓰지 않는다. 계획과 스냅샷 codec 이 어긋났다는 뜻이라 일어나면 결함이다.

fiber 는 잠금을 잡고, boot 하고, mailbox 에서 사건을 하나씩 꺼낸다(`Librarian_writer`).

- 잠금은 기다리지 않고 잡는다. 못 잡으면 `Stopped Store_unwritable` 이고 `Resume` 이 다시 잡아 본다. 한번 잡으면 fiber 가 끝날 때까지 쥔다.
- 쓰는 쪽은 사건에 답하기 전에 바뀐 상태를 내놓는다. 그래서 답을 받은 쪽이 읽는 상태는 그 답 뒤의 상태다.
- 읽는 쪽은 mailbox 를 거치지 않는다. 쓰는 쪽이 내놓은 값 하나를 읽는다. 열린 저장소에서는 반영 기록의 꼬리 줄이다.
- 끝난 쓰는 쪽은 mailbox 를 꺼내지 않는다. 그래서 보낸 쪽은 답과 쓰는 쪽의 끝을 함께 기다린다. 끝이 먼저 오면 쓰는 쪽은 받지 않았다고 답한다. 그 요청으로는 아무 일도 하지 않았다.
- `Retired` 는 끝난 fiber 다. 그 함수에는 그 상태가 없다. 표의 `Retired` 행은 등록부가 답한다. 그 Keeper 가 등록돼 있으면 새 쓰는 쪽에 보내고, 아니면 `Keeper_retired` 다(§8.6).
- 쓰는 쪽을 만드는 것과 그 fiber 를 돌리는 것은 다른 걸음이다. 만든 쓰는 쪽은 `Booting` 이고, 돌기 전에 온 사건은 mailbox 에서 기다린다.
- `Retire` 의 답은 잠금을 놓은 뒤에 간다. Keeper 를 지우는 경로가 그 답을 받고 파일을 지운다.
- 저장소가 멈추면 이유를 Keeper 이름과 함께 로그에 적는다. 잠금을 못 잡은 이유도 적는다.
꺼진 Keeper 의 안 읽은 단위는 꺼져 있는 동안 읽지 않는다. 다시 켜면 boot 가 반영 기록의 자리에서 이어 읽는다. 지금은 autoboot 가 띄우지 않은 Keeper 의 것도 따라잡는다(`server_bootstrap_loops.ml:2197-2206`). 그 점이 달라진다.

### 9.4 읽기가 서 있는 곳

안 읽은 것이 있는데 운영자나 바깥의 변화 없이는 반영에 닿지 못하는 곳은 아래가 전부다. 저마다 행에 보인다(§12).

| 곳 | 나가는 길 | 보이는 곳 |
|---|---|---|
| `Stopped s` | 파일을 되돌리고 `Resume`, 또는 `Adopt` | E1 |
| `Refused_at_bottom` | 직접 쓰기, 선언 변경, `Resume`, `Skip_item` | E2 |
| 되풀이되는 입력 결함 | `Skip_line`, `Restart_reading`. 읽히지 않는 내용이면 `Skip_item` | E3 |
| 되풀이되는 `Ask_failed` | 맨 앞 항목 때문이면 `Skip_item`. 아니면 코드를 고친다 | E3 |
| 한 항목 질문을 선언한 slot 이 모두 거절했는데 크기 사실이 다 모이지 않았다(400 으로 답하는 slot) | 운영자가 그 slot 을 빼거나 고친다, `Skip_item`, Memory 를 바꾸는 쓰기 | E4 와 slot 별 결과 |
| 한 항목 질문에 말이 없는 slot 이 있다 | 그 slot 이 답하거나 거절한다, 운영자가 그 slot 을 뺀다, `Skip_item` | W1 과 slot 별 결과 |
| 넓은 질문에 모든 slot 이 늘 말이 없다 | slot 이 답한다, 선언 변경 | W1 과 slot 별 결과 |
| lane 이 꺼져 있거나 선언이 없다 | 선언 | W1 |
| 자리를 기다리는 묻기 | 자리가 빈다 | 행의 「묻는 중」 칸과 fleet 행. 경고는 아니다 |
| 꺼진 Keeper(`Retired`) | Keeper 를 켠다 | 경보는 없다. 읽기가 미뤄진 것이다 |

자리를 기다리는 묻기의 행에는 문턱값이 없다. 「Exact 요청은 자리만 기다린다」의 규칙이라 기다리는 시간에 끝을 두지 않는다. 얼마나 기다렸는지는 시작 시각으로 보인다.

### 9.5 누가 사건을 보내나

| 사건 | 보내는 쪽 |
|---|---|
| `Turn_closed` | 턴 기록에 `Closed` 나 `Reset` 줄을 쓴 쪽. 덧붙임과 같은 단계에서 보낸다. 싣는 값은 없다 |
| `Pulse` | 서버 maintenance tick(60초). 등록된 Keeper 를 돌며 `ensure` 를 부르고 그 쓰는 쪽에 보낸다(§8.6) |
| `Write` | Keeper 의 Memory 도구와 운영자 route. 답은 promise 로 받는다 |
| `Ask_ended` | 묻는 fiber. 예외로 끝나도 `Ask_failed` 를 보낸다 |
| `Declaration_changed` | fiber 하나가 신호 둘을 기다린다. runtime 표의 게시(`Runtime.await_catalogue_change`)와 이 lane 의 registry 변경(`Runtime_exact_output_registry.subscribe_lane_changes`)이다. 어느 쪽이 와도 lane 값을 다시 풀어 모든 쓰는 쪽에 보낸다 |
| `Operator _` | 운영자 route(§12.4) |
| `Retire` | 등록부에 없는 Keeper 의 쓰는 쪽을 본 pulse. Keeper 를 지우는 경로는 등록부에서 뺀 뒤 파일을 지우기 전에 보내고 `Retired` 를 기다린다. 꺼낼 때 그 Keeper 가 등록부에 있으면 사건이 아니다 |
| `Boot_finished` | 쓰는 쪽의 boot |

- **선언의 신호는 둘이다.** 한 신호는 다른 쪽이 바꾼 것을 보지 못한다.
  - runtime 표의 게시는 CLI slot 의 창과 모델 이름을 바꾼다. registry 의 구독은 그것을 보지 못한다.
  - registry 의 변경은 HTTP slot 의 target 과 창을 바꾼다. `runtime.toml` 을 바꾸는 commit 에서 runtime 표의 신호가 새 registry 보다 먼저 온다. 그사이 registry 는 `Publication_busy` 를 답한다.
  - `Publication_busy` 면 lane 값을 보내지 않는다. registry 가 다 바뀌면 lane 의 신호가 온다(`runtime_exact_output_registry.mli:125-129`).
- **`Turn_closed` 는 귀띔이다.** 쓰는 쪽은 사건이 실은 값을 믿지 않고 디스크에서 할 일을 계산한다. 귀띔이 오지 않아도 `Idle` 의 pulse 가 턴 기록의 길이를 보고 찾는다. 그래서 줄을 쓰는 경로가 귀띔을 빠뜨려도 읽기가 서지 않는다. 늦어질 뿐이다.
- **Keeper 의 턴은 쓰는 쪽을 기다리지 않고 시작한다**(§8.6). Keeper 가 답을 기다리며 보내는 것은 `Write` 하나다. 그 답은 반영 하나(줄 fsync 와 스냅샷 쓰기)를 기다린다. 쓰는 쪽이 `Booting` 이면 boot 가 끝날 때까지 더 기다린다. 모델 호출은 기다리지 않는다. 읽기는 메모리의 view 와 스냅샷 파일을 본다(§11).
- **사건은 하나씩 다룬다.** 묻는 fiber 는 따로 돌고 결과만 mailbox 로 보낸다. 반영의 덧붙이기와 스냅샷 쓰기는 취소되지 않는 구간이다(§8.2).
- 손으로 고친 runtime 파일이나 프롬프트 파일은 재시작 때 보인다. 게시 경로를 지나지 않은 변경에는 신호가 없다.

## 10. 기록

Librarian 이 디스크에 두는 것은 Keeper 마다 파일 셋과 잠금 하나다. 이 절은 누가 쓰고 누가 읽는지, 얼마나 자라는지, 재시작 때 어떻게 되는지를 정한다.

| 기록 | 쓰는 곳 | 읽는 곳 | 자라는 만큼 | 재시작 |
|---|---|---|---|---|
| `<keepers_dir>/<k>/turns.jsonl` (새로 생김) | 턴 기록 모듈뿐(부르는 곳은 §5.2) | 묻는 fiber(저장한 offset 부터), Keeper 요청 builder(턴 경계), purge(마지막 단위 줄의 끝자리), sweep(offset 뒤의 줄), 화면 | 턴마다 두 줄, reset 마다 한 줄 | 덧붙이기만 한다. 찢긴 꼬리는 덧붙이는 helper 가 자른다. 닫지 못한 `Opened` 는 프로세스 시작 때 닫는다 |
| `<config keepers>/<k>.memory-current.json` (그대로 둠, 바이트 모양 같음) | 쓰는 쪽뿐. 반영 5단계와 boot 의 다시 쓰기 | Keeper 의 Memory 도구, dashboard, boot | 제품의 크기다. fact 가 바뀌는 반영마다 한 번 다시 쓴다 | 마지막 줄의 `after` 와 같거나, 그 줄에서 다시 쓰거나, `Log_diverged` 다 |
| `<config keepers>/<k>.memory-log.jsonl` (새로 생김) | 쓰는 쪽뿐 | boot(꼬리 한 줄), object sweep(프로세스 시작 때 꼬리 한 줄), `memory_search source=dropped\|absorbed`, 화면, 나중의 판정자 | 답, 직접 쓰기, 건너뜀마다 한 줄. 자르지 않는다 | 줄바꿈으로 끝나는 마지막 줄이 사실이다. 찢긴 꼬리는 반영이 아니다 |
| `<config keepers>/<k>.memory.lock` | 쓰는 쪽이 사는 동안 | 다른 프로세스는 거절된다 | – | 프로세스가 죽으면 풀린다 |
| 파일에 묶인 fact 저장소, working-context 파일 | 지금과 같다 | 지금과 같다 | 지금과 같다 | 지금과 같다 |

자라는 양이다.

- 턴 기록은 턴마다 약 0.6 KB 에 받아들일 때의 맥락을 더한 크기다. 시간당 98.3턴이면 fleet 전체로 하루 약 1.4 MB 다(추정. 줄 크기는 설치 뒤에 잰다).
- 반영 기록의 한 줄은 8~10 KB 다. 하던 일을 줄마다 다시 적어서다(지금 continuity 파일 평균이 6.6 KB 다).
- 묻기가 턴 도착을 따라가므로(§15) 반영 기록은 fleet 전체로 하루 약 2,960줄, 27 MB 까지 자란다. 가장 바쁜 Keeper(하루 351턴)는 한 해 1.15 GB 까지다. 73% 가 되풀이해 적은 하던 일이다(추정. 입력은 §15 의 재생과 위 줄 크기다).
- 하던 일을 그것이 바뀐 줄에만 적으면 약 3.5배 줄어든다. 고르지 않았다. 그러면 boot 가 뒤로 거슬러 읽거나 파일이 하나 더 생긴다. 설치 뒤에 재고 정한다(§22).
- 지운 fact 를 찾는 색인은 만들지 않는다. `source=dropped|absorbed` 검색은 반영 기록을 훑는다. 설치 뒤에 줄 크기, Keeper 별 하루 줄 수, 그 검색 한 번의 시간을 잰다.

패스마다, 좁히는 걸음마다, 거절마다, pulse 마다, 장애가 이어지는 시간마다 자라는 것은 없다. 그런 값은 화면에만 있다.

디스크에 두지 않는 것이다. 모두 쓰는 쪽의 메모리에 있고 재시작하면 없어진다.

- 쉬고 있다는 것, 폭 기억, 바닥 질문에 받은 거절, 마지막 묻기의 결과
- Keeper 요청이 읽은 자리보다 뒤에서 시작했다는 표시
- 기다린 시간과 호출 시간, 버린 답의 본문

없어지는 것이다. 후보 파일, 보낸 요청의 기록, 손실 장부, 옛 범위 반영 파일(`librarian-range-commit.json`), 영수증, fence, 원본, worker volume 이 이 경로에 없다. 빠진 것은 반영 기록의 `Skip` 줄 하나로 남는다.

## 11. Keeper 와 만나는 곳

Keeper 는 Librarian 의 파일을 읽지 않는다. 쓰는 쪽이 메모리에 둔 값 하나를 읽는다. 이 절은 그 값과, 그것이 Keeper 요청의 시작점을 어떻게 정하는지를 정한다.

### 11.1 Keeper 가 읽는 값

```ocaml
type view = { covers_through : position; covered : mark; working_state : string option }
val view : Keeper_name.t -> (view, [ `Booting | `Stopped of store_stop | `No_writer ]) result
```

- 쓰는 쪽이 반영할 때마다 바꾼다. boot 때는 반영 기록의 꼬리 줄에서 다시 만든다.
- `Error` 면 요청 builder 는 seed 에서 시작하고 하던 일을 싣지 않는다. 기본값으로 덮어 「읽은 자리가 처음」인 것처럼 굴지 않는다.
- Keeper 는 cursor 파일, continuity 스냅샷, 안 읽은 것의 장부, Librarian 의 읽은 자리 파일을 읽지 않는다. 그 파일들은 없어진다.
- `view` 는 `ensure` 를 지난다(§8.6). 등록된 Keeper 를 처음 물으면 쓰는 쪽이 만들어지고 답은 `Booting` 이다. 그래서 켜진 Keeper 에게 「쓰는 쪽이 아직 없다」는 답은 없다.
- `No_writer` 는 쓰는 쪽을 갖지 않는 Keeper 다. 등록되지 않은 Keeper 와 사람 Keeper 가 그렇다. 쓰는 쪽은 등록된 Keeper 가운데 턴 기록을 쓰는 Keeper 에게만 있다.

### 11.2 요청의 시작점

runtime 다섯이 함수 하나를 쓴다. 날것 이력의 창은 아래 둘 가운데 뒤쪽에서 시작한다.
RFC #53307(§3.3)이 이 규칙을 고친다. 운영자가 2026-11-19 에 그 RFC 의 D2 를 정했다. 읽은 곳의 끝이 앞으로 가도 창은 seed 에 두고, 그 RFC 의 신호가 올 때 읽은 곳의 끝으로 옮긴다. L8 은 그 RFC 가 정한 규칙으로 짓는다.

- **읽은 곳의 끝.** `covered.trace` 에서 닫힌 메시지 `covered.closed_messages` 개 다음이다. 그 앞은 Memory 에 있다. official-client lane 에서는 `covered` 의 fragment offset 이다. `covers_through = Before_first` 면 없다.
- **seed.** 이 이력에서 provider 가 마지막으로 받아 준 범위의 시작이다. 지금의 `Keeper_carried_front` seed 이고, Keeper 쪽 코드라 그대로 둔다.

메시지 수를 atom 번호로 바꾸는 일은 지금 있는 `first_atom_at_or_after` 가 한다. 읽은 곳의 끝과 아래 세 단계는 digest 를 견주지 않는다. purge 가 읽은 곳의 메시지를 고쳐 써도 번호는 그대로다(§5.6). seed 는 지금처럼 digest 를 견준다. purge 가 seed 의 atom 을 여는 메시지를 고쳐 쓰면 seed 가 버려지고 요청은 읽은 곳의 끝에서 열린다. 지금도 그렇다.

seed 의 세대 경계도 턴 기록에서 읽는다. 지금은 `turn-boundaries.jsonl` 에서 읽는다.

- 이 trace 에서 센 마지막 `Reset` 을 찾는다. `Reset` 의 trace 는 `after.trace` 다.
- 그 줄 앞에서 닫힌 이 trace 의 마지막 턴이 경계다. 턴 번호는 그 턴 `Opened` 줄의 `turn_ref` 에서 읽는다.
- 그 번호 이하의 턴 기록(turn record)은 seed 가 되지 않는다.
- `Reset` 뒤에 닫힌 턴은 경계 밖이다. 도구로 이력을 지운 턴 자신이 그렇다. 지금의 경계도 그 턴을 포함하지 않는다.
- 세는 `Reset` 은 cause 가 `Announced Cleared` 이거나 `Unannounced` 인 것이다.
- `Announced Recovered` 는 세지 않는다. purge 는 번호를 바꾸지 않는다. purge 가 고쳐 쓴 atom 의 seed 는 위의 digest 가 버린다.
- 센 `Reset` 이 없거나 그 앞에 닫힌 턴이 없으면 경계가 없다.

head 가 그 trace 에 없거나 닫힌 메시지가 `covered.closed_messages` 보다 적으면 시작점은 `Front_unresolved` 다. 이력을 지운 뒤 Librarian 이 그 `Reset` 단위를 읽기 전까지가 그렇다.

provider 가 범위를 크다고 거절하면 Keeper 쪽에서 시작점을 당긴다. 코드에 있는 세 단계이고 그대로 둔다.

| 단계 | 지금 읽는 곳 | 바뀐 뒤 읽는 곳 |
|---|---|---|
| 턴 경계로 | `turn-boundaries.jsonl` 의 마지막 `Turn_ended` | 턴 기록의 마지막 단위 줄의 끝자리(`Closed.after` 나 `Reset.after`). 단위 줄이 없으면 `Log_started.mark`. 턴 기록에 줄이 없으면 시작점은 0 이다. 꼬리를 읽지 못했거나, 끝자리가 다른 trace 의 것이거나, 이력이 끝자리보다 짧으면 턴 경계는 모르는 것이다(`Turn_boundary_unknown`). 0 으로 바꾸지 않는다 |
| 이 턴의 tool 결과를 표시로 | 바뀌지 않는다 | 바뀌지 않는다 |
| 이 턴이 시작한 곳으로 | `history_at_start` 의 atom 번호와 digest | `Opened.baseline.closed_messages` 를 atom 번호로 바꾼 값. digest 대신 「그 trace 의 head 가 닫힌 메시지를 그만큼은 갖고 있다」를 본다 |

- 미리 세는 provider 는 보내기 전 거절로 같은 단계에 닿는다.
- 시작점의 출처 가운데 Librarian 것 다섯을 지운다(`Librarian_snapshot`, `Librarian_progress`, `Past_librarian_point`, `Turn_start_after_librarian_refusal`, `This_turn_start_after_librarian_refusal`). `Covered` 하나를 더한다.
- 자리는 수와 끝자리로 적는다. 읽은 이력의 bundle digest 를 쓰지 않는다. 그래서 읽은 턴을 purge 해도 시작점이 풀린다.

### 11.3 읽은 곳보다 뒤에서 시작한 요청

Keeper 요청이 읽은 곳의 끝보다 뒤에서 시작하면, Memory 에도 없고 요청에도 없는 단위가 생긴다.
builder 는 요청을 만들 때 자기 시작점을 메모리에 적어 둔다. 화면이 그것을 읽은 곳의 끝과 견준다.

- 디스크에 쓰지 않는다. 턴 기록(turn record)에도 더하지 않는다. 다음 요청이 덮어쓴다.
- 재시작 뒤 첫 요청 전에는 값이 없다. 그때는 「모름」(`Unknown_until_next_request`)으로 보인다. 「틈 없음」으로 보이지 않는다.
- 쓰는 쪽은 이 일로 따로 깨어나지 않는다. 안 읽은 단위가 있으면 어차피 묻는다.

### 11.4 하던 일

- 턴마다 `view.working_state` 를 싣는다. continuity 스냅샷의 「하던 일」을 대신한다. 요청의 어디에 싣고 언제 바꾸는지는 RFC #53307(§3.3)이 정한다. 창 맨 앞에 두고 창을 옮길 때만 바꾼다.
- 컷부터 그 Keeper 의 첫 반영까지는 비어 있다. 그 사이는 날것 창이 덮는다.
- Memory 변화와 하던 일은 답 하나에서 나와 줄 하나에 같이 들어간다. 지금은 두 파일로 따로 써서 한쪽만 쓰인 적이 있다.

### 11.5 Memory 찾기와 쓰기

- `keeper_memory_search` 와 `keeper_memory_select` 의 입력 모양은 그대로다.
- 스냅샷 읽기는 쓰는 쪽이 어느 상태든 된다. `Stopped` 면 결과에 멈춘 이유를 같이 싣는다. `Booting` 이거나 쓰는 쪽이 없으면 「확인 전」을 같이 싣는다. boot 가 끝나기 전의 스냅샷은 반영 기록보다 한 줄 늦을 수 있다(§8.6).
- `source=dropped|absorbed` 는 반영 기록의 `effects.removed` 를 읽는다. 쓰는 것은 없다. fact 가 무엇으로 바뀌었는지도 거기서 나온다(`Merged_into`, `Revised_into`, `Superseded_by`).
- `source=current` 와 `keeper_memory_select` 가 보여 주던 「뒤이은 fact」 후보도 같은 곳에서 낸다. 컷 이전 것은 없다.
- 그 읽기는 반영 기록을 처음부터 훑는다(`Librarian_archive`). fact 마다 그 fact 를 말한 마지막 줄이 정한다. 지운 줄이면 나간 것이고, 그 뒤에 다시 더한 줄이 있으면 나간 것이 아니다. 지금 스냅샷에 있는 fact 도 뺀다. 맡긴 스냅샷은 기록이 마지막으로 지운 fact 를 갖고 있을 수 있다.
- 해석되지 않는 줄은 훑기를 멈추지 않는다. 그 수를 결과에 싣는다. 수가 0 이 아니면 「없다」는 증거가 아니다. 읽지 못한 꼬리 뒤에 맡긴 기록에는 그 줄이 계속 남는다(§8.7).
- 훑는 동안 잠금은 한 번에 줄 64개만큼만 쥔다. 그사이 덧붙은 줄도 읽는다.
- `memory_write` 와 철회는 쓰는 쪽에 `Write` 로 가고 저장한 id 와 함께 바로 돌아온다(§8.5).

### 11.6 파일에 묶인 저장소

`memory-source-current.json` 은 이 RFC 의 쓰는 쪽 밖에 있다.

- 쓰는 곳 둘(`upsert_file_fact`, `revalidate`)은 자기 잠금을 그대로 쓴다. `revalidate` 를 부르는 곳은 셋이다. `memory_search`, 상태 도구, 턴마다의 recall 이다.
- 이 저장소가 지워지는 코드를 부르던 곳만 고친다. `check_facts_budget` 와 `Keeper_memory_os_aggregate_lock` 이다. 잠금은 저장소 자신의 잠금으로 바꾼다.
- `check_facts_budget` 가 없어지면 이 파일을 바이트로 묶는 것이 없다. 어떤 client 에도 바이트 상한을 두지 않는다는 운영자 규칙(2026-10-06)을 따른 결과다(§22). 그 검사는 평범한 fact 와 이 파일의 줄을 함께 셌다. 환경 변수 `MASC_KEEPER_MEMORY_OS_FACTS_MAX_BYTES` 를 읽는 코드도 같이 지운다.
- 파일은 묶인 source 하나에 fact 하나를 갖는다. 무효가 된 경로마다 무효 행도 하나씩 갖는다. 무효 행은 그 경로에 새 fact 를 묶을 때만 없어지고, 턴마다 recall 에 실린다. 11-18 에 파일 21개에 fact 28개, 무효 행 164개였다. 이 RFC 는 그 규칙을 바꾸지 않는다(#53031). 바이트 수와 행 수는 화면에 보인다.

### 11.7 없어지는 연결

- 시작점을 당기는 단계 가운데 Librarian 것
- 안 읽은 것을 요청에 실어 나르던 carrier, 그 장부로 만든 틈 경보
- `choose_continuity` 와 `choose_range_start` 의 Librarian 지점 watermark(`keeper_turn_driver.ml`, `keeper_official_client_host.ml:466-476`)
- continuity 스냅샷 읽기, admission 큐

[RFC-keeper-context-window-in-tokens](RFC-keeper-context-window-in-tokens.md) §1.1 의 한 문장을 고친다. 「Librarian 은 `prompt_max_messages` 로 자기 입력을 묶는다」는 문장인데, 그 이름은 코드에 없다. 「Librarian 의 입력은 이 RFC 의 폭 줄이기로 묶인다」로 바꾼다. 그 절의 결정은 그대로다.

## 12. 운영자가 보는 것

운영자는 Keeper 마다 한 행을 본다. 그 행은 쓰는 쪽의 상태와 마지막 묻기의 결과에서 나온다. 이 절은 행의 내용, 경보, 그것이 보이는 곳, 운영자가 할 수 있는 일 다섯을 정한다.

### 12.1 행

행은 닫힌 생성자와 수만 싣는다. 예외 글, provider 의 메시지, claim, 답의 본문은 행에 오지 않는다. 그런 것은 구조화 로그에 남는다.

| 칸 | 값 |
|---|---|
| 상태 | `Booting`, `Idle`, `Asking`, `Resting`, `Refused_at_bottom`, `Stopped s`, `Retired` |
| 읽은 자리 | `covers_through`, 마지막 반영 시각 |
| 기록의 시작 | 반영 기록의 첫 줄 시각과 턴 기록의 `Log_started` 시각. 반영 기록이 없어졌다가 다시 시작됐으면 앞의 것이 한참 뒤다(§8.6) |
| 안 읽은 것 | 가장 오래된 안 읽은 항목이 든 단위가 닫힌 시각. 안 읽은 것이 있는 Keeper 는 경보와 상관없이 모두 싣는다 |
| 마지막 묻기 | 결과의 생성자, slot 별 결과, 맨 앞 항목과 그 바이트 수 |
| 바닥 | 맨 앞 항목의 두 질문에 slot 마다 받은 크기 사실 |
| 자리 내기 | 마지막 자리 내기의 결과, 그리고 Memory 가 그 뒤에 바뀌었는지 |
| Memory | 스냅샷 파일의 sha 와 바이트 수, 파일에 묶인 저장소의 바이트 수와 행 수 |
| 묻는 중 | `Waiting_for_seat` 나 `Calling { slot }`, 그리고 그것이 시작한 시각 |
| Keeper 요청 | 가장 최근 요청이 읽은 곳의 끝보다 뒤에서 시작했는지. 재시작 뒤 첫 요청 전에는 「모름」 |

fleet 행은 하나다. 아직 slot 에 보내지 못한 묻기의 수와, 그 가운데 가장 오래된 것이 시작한 시각이다. 문턱값은 없다.

### 12.2 경보

수준은 함수 하나가 정한다. 상태, 마지막 묻기, 마지막 자리 내기, Memory 없이 읽었는지, 지금의 Memory sha 와 lane 값, 안 읽은 것, 요청의 시작점을 받아 `Ok`, `Warn`, `Error` 가운데 하나를 낸다. 닫힌 생성자 위의 `match` 다.

**판정에 기대는 경보는 그 판정이 지금 바이트에 대한 것일 때만 켜진다.** 판정은 물을 때의 Memory sha 와 lane 값을 싣고, 함수가 그것을 지금 값과 견준다. Memory 나 선언이 바뀌면 옛 판정으로 오류를 띄워 두지 않는다. 값: 새 바이트를 판정하는 묻기가 끝날 때까지 수준이 warn 으로 내려간다. `Resting` 에서는 그 묻기가 다음 pulse 에 시작한다.
pulse 가 잠깐 만드는 `Asking` 은 답을 바꾸지 않는다. 함수가 마지막으로 끝난 묻기를 읽기 때문이다.

「안 읽은 것이 있다」는 쓰는 쪽이 다음 묻기를 시작할지 정할 때 쓰는 그 함수다(§9.2). 항목이 없는 단위는 세지 않는다. 턴 기록이 바뀌었거나 잘린 것은 센다.

| | 켜져 있는 때 | 수준 |
|---|---|---|
| E1 | `Stopped s` | error |
| E2 | `Refused_at_bottom`. 선언한 slot 이 모두 맨 앞 항목의 질문을 크기로 거절했고, 한 항목 아래로 갈 근거는 없다 | error |
| E3 | 안 읽은 것이 있고, 마지막 묻기가 `Input_fault _` 나 `Ask_failed _` 로 끝났다 | error |
| E4 | 안 읽은 것이 있고, 마지막으로 끝난 묻기가 한 항목을 실었고 `Refused_by_lane` 으로 끝났다. 지금 선언한 slot 이 저마다 그 질문을 거절했거나 크기 사실을 갖고 있다. 말 없는 slot 은 없다. 그 가운데 크기 사실 없이 거절한 slot 이 하나는 있다. 그 결과가 본 스냅샷과 질문 쪽이 지금 것이다 | error |
| E5 | 마지막 자리 내기를 선언한 slot 이 모두 입력 크기로 거절했고, 그때의 Memory sha 와 lane 값이 지금 것이다. Memory 가 어느 slot 에도 들어가지 않는다 | error |
| W1 | `Booting` 이다. 또는 안 읽은 것이 있고 다음 가운데 하나다: lane 이 꺼져 있거나 선언이 없다, 마지막 묻기의 결과가 아직 없다, 마지막 묻기가 `Refused_by_lane _` 나 `Silent_lane _` 로 끝났다 | warn |
| W2 | Keeper 의 가장 최근 요청이 읽은 곳의 끝보다 뒤에서 시작했다. 재시작 뒤 첫 요청 전과 view 가 `Error` 인 동안에는 「모름」으로 보인다 | warn |
| W3 | 마지막 읽기 반영이 Memory 없이 됐다. 재시작하면 다음 읽기 반영까지 꺼져 있다 | warn |

- 경보는 아무것도 막지 않는다. 읽는 것이지 문이 아니다.
- 경보는 저장하지 않는다. 재시작하면 상태에서 다시 계산한다. `Stopped` 는 boot 표가 다시 낸다. E3 은 첫 묻기가 끝나면 다시 켜진다. E4 는 폭 줄이기가 한 항목에 다시 닿은 뒤에 켜진다. 그사이에는 W1 이 켜져 있다. E2 는 slot 마다 한 번씩 다시 물은 뒤에 켜진다. E5 와 W3 은 다음에 항목만 읽은 반영이 있을 때까지 꺼져 있다. 안 읽은 것이 없으면 W1 도 꺼져 있다.
- 그래서 재시작 직후에는 안 읽은 것이 있는 Keeper 가 모두 warn 이다. 첫 묻기가 끝날 때까지다.
- 한 항목에서 말이 없는 slot 때문에 쉬는 Keeper 는 W1 이다. error 가 아니다. 꽉 찬 자리, 타입 있는 quota, 끊긴 네트워크는 말 없음이고 스스로 끝난다.
- 스스로 끝나지 않는 말 없음이 하나 있다. 판정을 타입으로 알리지 않는 client 가 큰 항목에 매번 실패하는 경우다. 그 Keeper 는 W1 에 서 있고 pulse 마다 그 client 를 한 번 부른다. 운영자가 slot 별 결과를 보고 그 slot 을 뺀다.
- E3 은 지나간 줄에 서 있지 않는다. 받아들인 건너뛰기는 마지막 묻기의 결과를 비운다(§9.2).
- E5 는 마지막 자리 내기의 결과를 읽는다. Memory 를 재는 것이 아니다. Memory 가 바뀌거나 재시작하면 꺼지고, 다음 자리 내기가 끝나야 다시 켜진다. 자리 내기는 항목만 읽은 반영 뒤에만 묻는다. 그사이에는 행의 「자리 내기」 칸이 마지막 결과와 그 뒤의 변화를 보인다.
- E4 는 스스로 끝나지 않는 쪽이다. 선언한 slot 이 모두 그 질문을 받고 판정했는데 크기 사실이 다 모이지 않았다. 400 으로 답하는 slot 은 같은 바이트에 같은 답을 한다. 나가는 길은 그 slot 을 빼거나 고치는 것, `Skip_item`, Memory 를 바꾸는 쓰기다. 켜져 있는 동안 pulse 마다 크기 사실이 없는 slot 에 그 항목을 다시 보낸다. quota 를 맨 400 으로 알리는 provider 도 E4 를 켠다. 그 slot 은 이유를 다르게 말한 것이고, 운영자가 빼야 한다.
- `Booting` 에서는 안 읽은 것을 계산할 수 없다. boot 가 읽은 자리를 아직 읽지 않았다. 그래서 `Booting` 은 그 조건 없이 W1 이다.
- 자리를 기다리는 묻기에는 경보 행이 없다. fleet 행이 단계와 시작 시각을 보인다(§9.4).
- `E1` 의 행은 멈춘 이유가 무엇이든 스냅샷 파일의 sha 와 바이트 수를 싣는다. `Adopt` 에 넣을 값이 거기 있다.
- 안 읽은 것이 있는데 운영자나 변화 없이는 반영에 닿지 못하는 곳은 §9.4 의 표가 전부다. 그 가운데 둘은 경보 행이 없다. 자리를 기다리는 묻기는 fleet 행에 보인다. 꺼진 Keeper 에는 경보가 없다.
- 실패가 맨 앞 항목 때문이 아닌데 되풀이되는 `Ask_failed` 는 운영자 행동으로 풀리지 않는다. 코드를 고쳐야 한다. E3 가 그것을 보인다.

### 12.3 보이는 곳

- `/health?full=1` 의 Librarian 절과 `keeper-memory-health` 가 Keeper 별 행과 fleet 행을 싣는다.
- TUI 의 Keeper memory 화면이 그 행을 그린다. 생성자마다 해석 시험이 있다.
- Home 의 Health 줄에는 수 둘만 더한다. error 인 쓰는 쪽의 수와 warn 인 쓰는 쪽의 수다. 그 줄은 지금처럼 120초마다 다시 계산한다. workspace health 낱말은 바꾸지 않는다. 그 낱말은 운영자 digest 가 attention 항목에서 계산한다.
- 호출 시간, 자리를 기다린 시간, 버린 답의 수, slot 별 `Output_over_reserve`·`Window_reached`·보낸 뒤의 `Lost` 수는 metric 이다.
- 자리를 기다린 시간은 지금도 저장된다(`masc.provider_admission.waited`). 바꾸기 전과 뒤를 이 사건으로 견준다.

### 12.4 운영자가 할 수 있는 일

다섯이고 route 하나로 받는다. `CanAdmin` 이 있어야 한다. 이름은 `POST /api/v1/keepers/<k>/memory/act` 를 제안한다. TUI 의 Keeper memory 화면에서 같은 것을 한다. route 와 `Resume`, `Adopt` 는 쓰는 쪽과 같은 층(L5)에서 만든다. 건너뛰기 셋은 폭과 바닥 층(L7)에서 더한다(§20).

| 행동 | 받는 때 | 하는 일 |
|---|---|---|
| `Resume` | `Stopped` | 저장소 시작을 다시 한다. 턴 기록 파일을 확인한 뒤 boot 한다(§8.6) |
| | `Resting`, `Refused_at_bottom` | 바닥에서 받은 크기 사실을 지우고 바로 다시 묻는다 |
| `Skip_item i` | i 가 지금 첫 안 읽은 항목이다 | `Skip (Operator_skipped)` 줄을 쓰고 그 항목을 지나간다 |
| `Skip_line { offset }` | 읽는 쪽을 지금 다시 돌리면 그 offset 의 줄을 해석하지 못한다고 답한다 | `Skip (Line_unreadable)` 줄을 쓰고 그 줄을 지나간다 |
| `Restart_reading { observed }` | 디스크의 턴 기록 id 가 `observed` 다. 그 id 가 마지막 반영 줄의 것과 다르거나, 같은데 저장한 offset 이 파일 끝을 넘거나 줄 시작이 아니다 | `Skip (Turn_log_replaced)` 나 `Skip (Position_lost)` 줄을 쓰고 그 파일을 처음부터 읽는다 |
| `Adopt { observed }` | `Stopped (Log_diverged _)` 나 `Stopped Log_unreadable` 이고, 스냅샷 파일의 sha 가 `observed` 이며 codec 으로 해석된다 | §8.7 |

- 건너뛰기 셋(`Skip_item`, `Skip_line`, `Restart_reading`)은 `Idle`, `Asking`, `Resting`, `Refused_at_bottom` 에서 받는다. `Booting` 에서는 boot 가 끝날 때까지 기다린다. `Stopped` 와 `Retired` 에서는 거절한다.
- 조건은 행동을 반영하는 순간에 디스크에서 다시 읽는다. 상태나 마지막 묻기의 결과를 믿지 않는다. 그래서 재시작 뒤에도, 묻기가 실패한 뒤에도 쓸 수 있다.
- 읽는 쪽은 잘못을 정해진 순서로 본다. 턴 기록의 id, 저장한 offset, 줄 해석이다. 그래서 바뀌었거나 잘린 파일의 줄 토막을 `Skip_line` 으로 지나칠 수 없다. 그때 받는 행동은 `Restart_reading` 이다.
- `Skip_line` 은 읽을 수 있는 단위를 지나치지 못한다. 읽는 쪽은 해석 못 하는 줄 앞의 항목 든 단위를 먼저 묻고 반영한다. 그 줄 앞에 항목 든 단위가 없을 때만 받는다. 앞에 놓인 항목 없는 단위는 같이 지나간다.
- 받아들인 건너뛰기는 가던 묻기를 취소한다. 거절한 행동은 아무것도 바꾸지 않는다.
- route 는 `Done` 이나 `Refused of reason` 으로 답하고, 화면이 그 이유를 그린다. 이유는 닫힌 타입이다: `Not_the_head`, `Not_the_faulted_line`, `Not_replaced`, `Not_stopped`, `Nothing_to_resume`, `Snapshot_mismatch`, `Snapshot_unreadable`, `Store_stopped s`, `Keeper_retired`.
- `Done` 의 답은 그 뒤 저장소의 상태를 같이 싣는다. `Resume` 이 boot 를 다시 돌렸는데 같은 이유로 멈췄으면 그 이유가 답에 있다. `Log_diverged` 로 멈췄으면 반영 기록이 가리키는 sha 와 파일의 sha 를 싣는다. 파일의 sha 가 `Adopt` 에 넣을 값이다.
- 옛 route 인 `memory-catch-up` 은 쓰는 쪽을 켜기 전에 지운다(§20 L5p). 쓰는 쪽은 턴 기록과 pulse 로 할 일을 찾으므로 운영자가 깨우는 길을 두지 않는다. 일괄 cleanup 의 Memory 철회는 쓰는 쪽으로 쓴다(§8.5). `memory-journal`, `memory-facts` 는 지우는 층에서 저마다 지우거나 반영 기록을 읽게 고친다(§19.2).

## 13. 실패마다 장치와 시험

연구 기록 §4 의 실패 열다섯과, 이 설계를 만들다 스스로 찾은 열여섯째를 적는다. 실패마다 그것을 없애는 장치와 그것을 확인하는 시험이 하나씩 있다.
시험은 서버의 실제 경로에 건 기능 시험이다. 끝의 층 이름은 §20 의 층이다.

| 실패 | 장치 | 시험 | 층 |
|---|---|---|---|
| F1 턴이 빠진다 | 내용은 두 끝자리의 차라서 빈틈이 생기지 않는다. `Closed` 와 `Reset` 줄이 각각 단위다. 읽기는 저장한 바이트 offset 에서 시작한다. 쓰는 쪽이 하나다 | 속성 시험 T1. 받아들임, 저장, 끝남, kill, 꼬리 복구, purge, reset, 「닫는 저장과 그 줄 사이의 purge」, 「reset 줄과 head 변경 사이의 kill」, 「열린 메시지를 가진 head 의 지우기와 recovering purge」, session 을 지우는 정지를 아무 순서로 섞는다. 줄이 이름 붙인 메시지가 `Log_started` 뒤로 head 가 가졌던 메시지와 같다. session 을 지우는 정지가 버린 것만 다르다. 그 줄은 조각 없이 남고 읽는 쪽이 `Unknown_span` 으로 적는다. 두 번 이름 붙는 것은 둘뿐이다. 지우기가 남긴 System 메시지, 그리고 줄을 먼저 쓴 head 변경이 일어나지 않았을 때 그 줄의 `after` 와 `before` 사이다(§5.2) | L3a, L3c |
| F2 답을 옮겨 적다 틀려 전체가 거절된다 | 답은 바뀌는 것만 적는다. 이름 붙이지 않은 fact 는 남는다. 이름은 `m1 … mN` 이다. 흠 있는 op 는 그 op 만 빠진다. 답 전체를 버리는 것은 JSON, schema, 되돌려 적기 셋뿐이다 | 모르는 이름 하나와 맞는 op 넷이 든 답은 넷을 반영하고 `Unknown_ref` 하나를 줄에 남긴다 | L6 |
| F3 「아무것도 바꾸지 않는다」가 안전한 답이었다 | 바꿨다고 벌하는 gate 와 전수 확인이 없다. 고정한 채점기가 프롬프트를 내기 전에 slot 별 변화율과 되찾는 비율을 알린다 | L1 채점기 결과를 L6 PR 에 붙인다 | L1, L6 |
| F4 merge 가 내용을 잃는다 | 합쳐진 원본이 줄에 통째로 남고 `source=absorbed` 검색이 무엇으로 합쳐졌는지와 함께 돌려준다. merge 뒤 보존은 채점기가 따로 잰다 | merge 한 뒤 absorbed 검색이 원본 둘을 돌려준다 | L5 |
| F5 바깥 판정자가 멈추면 반영이 멈춘다 | 반영 경로에 판정자가 없다 | Librarian 경로 아래 `Typesafeai` 를 부르는 곳이 `rg` 로 0 이다 | L10 |
| F6 크기를 만들 때 맞추지 않는다 | provider 가 센다(§6.3). 중계가 없어 4 MiB 상한도 없다. 폭 줄이기는 끝이 있다. 바닥값이 없다 | 가짜 tokenizer 를 단 가짜 provider 가 들어가는 가장 넓은 폭을 ⌈log2⌉ 번 안의 거절로 받는다. 너무 큰 단위, 항목, Memory 가 저마다 타입 있는 끝에 닿는다. 크기를 타입으로 말하지 않는 slot 을 lane 에 넣으면 한 항목 아래로 가지 않는다. 그 slot 이 거절하면 E4 가, 말이 없으면 W1 이 켜진다 | L7 |
| F7 일 종류 여럿이 한 줄에 선다 | Keeper 마다 질문 종류 하나가 읽기와 하던 일을 같이 싣는다. 직접 쓰기는 모델이 필요 없다. Librarian 자신의 대기 줄이 없다 | 10분 걸리는 가짜 호출 중에 `Write` 가 그 호출을 기다리지 않고 답한다 | L6 |
| F8 읽은 자리가 atom 번호를 따른다 | 턴 id 는 줄의 바이트 offset 이다. 끝자리는 메시지 수다. `Reset` 줄이 있다. 줄이 내용을 bundle 로 가리켜서, purge 뒤에도 그 줄을 쓸 때의 내용이 읽힌다(§5.6) | purge(thinking 지우기, tool 결과 비우기) 뒤에 읽어도 같은 항목이 나오고 `Content_missing` 이 없다. 읽은 자리보다 뒤의 턴을 purge 해도 같다. 단위 줄이 아직 없는 닫힌 메시지와 열린 메시지는 purge 뒤에도 바이트가 같다(열린 메시지 30개인 head 를 `keep_recent_messages = 0` 으로 purge 한다) | L3a, L8 |
| F9 재시작이 일을 잃거나 되풀이한다 | boot 는 꼬리 한 줄을 읽는다. 원본, fence, 계보, 정산이 없다. 가던 묻기는 다시 묻는다 | 덧붙이기 전, 덧붙인 뒤, rename 뒤에 죽인 것이 모두 죽지 않았을 때의 sha 로 boot 한다. 두 번 복구는 한 번과 같다. 호출 중 재시작은 다시 묻기 하나다 | L5, L6 |
| F10 패스마다 전부를 다시 확인한다 | §16 | 세는 reader 로 tick 1,000번. 새 입력이 없으면 읽기, 쓰기, 호출이 0 이다. 앞선 줄이 10개든 100,000개든 값이 같다 | L6 |
| F11 선언을 바꾸면 읽기가 멈춘다 | 질문 id 가 선언을 담는다. 질문 쪽 선언이 바뀌면 가던 묻기를 취소한다. 늦게 온 답은 세고 버린다. 그 밖에 들고 있는 것이 없다 | 호출 중에 프롬프트를 바꾼다. 버린 답 하나가 세어지고 다음 질문이 새 선언을 담는다. slot 목록만 바꾸면 가던 묻기의 답이 반영된다 | L6 |
| F12 처리량이 도착의 20분의 1 이다 | §15. 묻기가 턴 도착을 따라간다 | 재생 스크립트와 출력(근거 폴더). 배포 뒤 fleet 행 | L0, L9 |
| F13 운영자가 볼 수 없다 | §12 | 상태, 원인, 경보 생성자마다 해석 시험. 재시작 뒤 안 읽은 단위가 있으면 첫 묻기가 끝날 때까지 경고가 켜져 있다 | L9 |
| F14 두 consumer 가 같은 범위를 보낸다 | 쓰는 쪽 하나가 사는 동안 잠금을 쥔다. 묻기는 한 번에 하나다. 읽은 자리 규칙(§8.4) | 둘째 프로세스는 `<k>.memory.lock` 을 못 잡는다. 읽은 자리를 옮기는 사건 뒤에 온 답은 늦은 답으로 버려진다 | L5, L6 |
| F15 서버와 worker 의 버전이 어긋난다 | Librarian 에 worker 와 add-on package 가 없다 | preflight 가 `keeper-librarian` add-on 이 남은 base path 를 거절한다 | L11 |
| F16 잠깐의 실패가 Keeper 를 세워 둔다 | 말 없음은 폭을 줄이지도 세우지도 않는다. 쉬는 Keeper 는 pulse 마다 같은 폭으로 다시 묻는다 | 모든 slot 이 N 번 시간 초과한 뒤 답한다. 운영자 행동 없이 반영되고, 질문의 폭이 처음과 같다 | L7 |

연구 기록이 실패로 세지 않고 사실로 적은 것들도 같은 표로 확인한다. 마지막 행은 그 뒤에 생긴 일이다.

| 사실 | 장치 | 시험 | 층 |
|---|---|---|---|
| G1 턴의 16.3% 가 끝 줄을 쓰지 않았다 | 받아들일 때 `Opened` 를 쓴다. 끝나는 길이 모두 닫는다. 놓친 것은 다음 받아들임이나 프로세스 시작이 닫는다 | T1. kill 시험: `Opened` 만 있으면 프로세스 시작 단계가 head 의 열린 메시지를 닫고 `Process_exited` 를 쓴다. 그 메시지는 그 단위에 든다. tool 결과를 다 받은 채로 죽은 턴도 같다 | L3a |
| G2 `turn_ref` 가 약 26번 되풀이된다 | 턴 id 는 줄의 바이트 offset 이다 | 두 턴 사이에 서버를 두 번 띄워도 id 가 둘이다 | L3a |
| G3 atom 번호가 다시 시작하고 purge 가 번호를 다시 매긴다 | 끝자리와 `Reset` | F8 시험에 reset 시험을 더한다 | L3c |
| G4 본문 시한에 줄 선 시간이 들어간다 | Librarian 의 대기 줄이 없다. 본문 시간은 생성 요청을 보낸 때부터 센다(#52986) | 가짜 시계: 자리를 얼마나 기다리든 본문 시한이 줄지 않는다 | L6 |
| G5 답의 42% 를 버렸다 | op 마다 따로 거절한다(§8.3) | 호출 중 `Remember` 는 답을 그대로 둔다. merge 원본의 `Retract` 는 그 op 하나만 `Removed_during_flight` 로 만든다 | L6 |
| G6 GLM 의 admission 답이 8개 모두 무효였다 | admission 질문이 없다. slot 별 유효율은 L1 이 재서 보인다 | L1 | L1 |
| G7 `record_failed` 폴링 14,219번 | 쉼은 pulse 를 기다린다. provider 가 시각을 말한 slot 은 그때까지 부르지 않는다 | 가짜 시계: 모든 slot 이 재시도 시각과 함께 rate limit 을 걸면 그 시각 전에는 flow 가 시작하지 않는다 | L7 |
| G8 중계의 용량 거절 | 경로에 중계가 없다 | 삭제로 확인한다 | L10 |
| G9 「모르면 다시 부르지 않는다」가 세 군데 있다 | 이 경로에는 없다. 공유 틀은 고치지 않는다 | – | – |
| G10 쓰기 함수 하나가 잠금 둘, 파일 여덟 | 문 하나, 줄 하나, 스냅샷 하나. 읽는 쪽 인터페이스에는 쓰는 함수가 없다 | L5 의 crash 시험. 타입 검사 | L5 |
| G11 요청의 15.3% 가 Librarian 이 읽은 곳보다 뒤에서 시작했다 | 요청이 뒤에서 시작했다는 것을 화면이 보인다. 시작점 규칙(§11.2). 읽기는 Keeper 자신의 시작점에서 시작한다 | runtime 마다: 읽은 자리가 n 이면 요청이 n 다음에서 시작한다. 크기 거절을 억지로 내면 표시가 켜진다 | L8 |
| G12 fact 에 출처가 없다 | `effects.sources` 가 fact 마다 나온 단위를 적는다. 그 단위의 `Opened` 가 보낸 이를 타입으로 갖는다 | 단위 t 에서 더한 fact 가 t 를 적는다 | L6 |
| G13 옛 동작이 시험, release 목록, TLA cfg, 문서에 박혀 있다 | §19 | 지운 이름을 `rg` 로 찾아 0. release 목록이 새 시험을 가리킨다 | L10 |
| G14 디렉터리를 scope 아홉이 나눠 쓴다 | 설치가 scope 정의에서 만든 경로 목록으로 지운다 | fixture base path 에 시험 설치 | L11 |
| G15 한 답의 두 반쪽이 어긋났다 | 하던 일과 Memory 변화가 한 줄에 있다 | L5 의 crash 시험 | L5 |
| G16 공개 health 행이 자유 글을 실을 수 있다 | 행은 닫힌 생성자와 수만 싣는다 | health JSON 에 claim, 답, 근거 글이 없다 | L9 |
| G17 창이 프롬프트와 Memory 를 담지 못하는 slot | 그 slot 은 크기로 거절한다. 타입이 있고 빠르다. 그 행에 보인다 | L7 의 거절 경로 시험 | L7 |
| G18 저장한 줄이 남의 타입을 담아 해석되지 않는다(#53018) | 줄은 자기 모듈의 타입, id, 글만 담는다(§5.1) | 줄 codec 모듈이 Goal·Task 저장소에 의존하지 않는다(빌드가 확인한다) | L3a |

## 14. 불변식

옛 Librarian 의 RFC 들과 실패 기록에서 모은 불변식 열다섯이다. 우연히 생긴 것으로 보고 버린 것은 없다. 둘은 말을 고쳤다.
끝 열은 그것을 확인하는 모델의 속성이나 시험이다. 모델과 설정은 §21 에 있다.

| | 불변식 | 지키는 방법 | 확인 |
|---|---|---|---|
| I1 | 턴은 빠지지 않고 순서가 지켜진다. 읽지 않고 지나가는 것은 타입 있는 구멍으로만, 기록과 함께 한다 | 읽은 자리 규칙(§8.4). 내용은 끝자리의 차라 이어진다. 지나친 것은 모두 `Skip` 줄에 이름이 있다 | `LibrarianTurnLog`: `NoSilentSkip`, `EveryClosedInOneUnit`, `PassedAccounted`, `SkipRecorded`. `LibrarianWriter`: `PositionMoves`, `PositionHasLine` |
| I2 | Memory 가 먼저고 읽은 자리가 나중이다 | 말을 고친다. Memory 변화와 읽은 자리가 한 줄에 같이 반영된다. 스냅샷은 boot 가 그 줄에서 다시 쓴다. boot 가 끝나기 전의 읽기는 한 줄 늦은 스냅샷을 볼 수 있고, 그 읽기는 「확인 전」을 같이 싣는다(§11.5). 두 파일 사이의 순서였던 것이 한 줄이 되어, 틀릴 순서가 없다 | `LibrarianWriter`: `Chain`, `SnapshotLag`. buggy 설정 `position-first` 가 깨진다 |
| I3 | 한 범위의 fact 는 많아야 한 번 적용된다 | 범위는 이어지고 겹치지 않는다. 쓰는 쪽이 하나다. 쓰기 전에 스냅샷의 sha 를 본다(2단계). op 마다 거절하는 것은 CAS 가 지키던 것(그사이 지워진 fact 를 건드리지 않는다)을 답을 버리지 않고 지킨다 | `LibrarianWriter`: `AnswerAtMostOnce`, `NoUndoRetract`. buggy 설정 `undo-a-retract` 가 깨진다 |
| I4 | 답은 자기가 답한 입력에만 적용된다. 받은 답을 말없이 버리지 않는다 | 말을 고친다. 답은 한 번 적용되거나 적용되지 않는다. 늦은 답은 세고 버린다. 되돌려 적은 id 를 보고, 시작 자리는 묻기 번호와 취소 규칙이 지킨다. 답을 받고 줄을 쓰기 전에 죽으면 그 답은 없고, 다시 묻는다 | `LibrarianWriter`: `AnswerOnlyWhenCurrent`. buggy 설정 `apply-stale-answer` 가 깨진다 |
| I5 | 모르는 것을 없음, 실패, 기본값으로 바꿔 쓰지 않는다 | slot 결과는 와일드카드 없는 `match` 하나다(§7.2). 해석되지 않는 반영 기록은 `Log_unreadable` 이다. 없는 반영 기록은 「읽었다는 기록이 없다」로만 읽는다(§8.6). 풀리지 않는 시작점은 `Front_unresolved` 다. 알리지 않은 reset 은 `Unknown_span` 이다 | `LibrarianTurnLog`: `UnknownRecorded`. `classify` 의 생성자별 시험(L2, L6) |
| I6 | 잃는 것은 기록과 함께만 잃는다. 답에서 빠진 fact 는 지워지지 않는다. 합쳐진 원본은 찾을 수 있다 | 지운 fact 는 줄에 통째로 남는다. 컷 뒤로 그렇다. 컷 이전 기록은 지운다(§22.1) | F4 시험(L5) |
| I7 | Keeper 는 Librarian 을 기다리지 않는다. 진행이 굶지 않는다. Keeper 끼리 떨어져 있다 | 쓰기에 모델이 필요 없다. Keeper 경로는 쓰는 쪽의 잠금을 잡지 않는다. 턴 기록 덧붙임이 실패해도 턴을 거절하지 않는다. 쓰는 쪽이 Keeper 마다 하나다. provider 자리를 Keeper 턴과 나누는 것은 §15.3 이 다룬다 | F7 시험(L6). 덧붙임 실패 시험(L3a) |
| I8 | 밀린 것은 모두 운영자에게 보인다. 재시도가 헛돌지 않는다. 사람이 고르거나 맞춘 숫자가 없다 | §12. 거절은 폭을 줄인다. 그 밖의 실패는 pulse 에 다시 묻는다. 바닥에서 크기로 거절한 slot 에는 질문이 바뀔 때까지 다시 묻지 않는다. 창과 출력 몫은 선언이고, 절반은 찾는 걸음이다 | `LibrarianWriter`: `NoSilentPark`. `LibrarianWidth`: `HalfStep`, `SilenceChangesNothing` |
| I9 | 죽은 뒤 상태는 durable 기록에서 다시 만든다. 깨움과 신호는 귀띔이고, 할 일은 디스크에서 계산한다 | 상태는 반영 기록의 꼬리 줄과 턴 기록에서 나온다. 귀띔을 놓쳐도 `Idle` 의 pulse 가 턴 기록의 길이를 보고 찾는다(§9.5) | 두 번 복구 시험(L5). `LibrarianWriter` 의 boot 행 |
| I10 | durable 기록은 들어온 일만큼 자란다. 패스 수나 장애 시간만큼 자라지 않는다 | §10 | F10 시험(L6) |
| I11 | 보내는 것의 크기는 만들 때 묶인다 | §6.3 에 적은 뜻으로 지킨다. 미리 세는 slot 은 보내기 전에, 그 밖은 provider 자신의 창이 묶는다 | F6 시험(L7) |
| I12 | 누구인지와 누가 말했는지는 타입 있는 값으로 온다. 옛 턴이 지금의 Task 를 빌리지 않는다. 받아들일 때 열려 있던 메시지와 턴이 남긴 열린 메시지는 예외다(§5.2) | 받아들일 때의 근거와 깨운 것을 `Opened` 에 적는다. queue 항목이 이름을 실었으면 그 이름이 줄에 있다. `baseline` 앞에서 닫힌 내용에는 Task 가 없다. `Opened` 를 쓰고 죽은 턴이 저장한 메시지는 프로세스 시작 단계가 그 턴의 단위로 닫는다(§5.2). 받아들일 때 열려 있던 메시지는 받아들인 턴의 것이다 | `LibrarianTurnLog`: `OwnNotClosedBefore` |
| I13 | 날것 턴은 덧붙이기만 한다. purge 가 독자가 무엇을 읽었는지를 정하지 않는다 | 줄이 내용을 sha 로 이름 붙은 bundle 로 가리킨다. purge 는 Librarian 의 읽은 자리를 읽지 않는다. 고쳐 쓰기만 하는 purge 는 단위 줄이 아직 없는 메시지(닫혔든 열렸든)를 건드리지 않는다. 끊긴 곳 뒤를 버리는 purge 는 버리는 것을 줄에 먼저 적는다(§5.6) | `LibrarianTurnLog`: `UnreadReadable`. 단위 줄 위의 메시지를 고쳐 쓰는 buggy 설정이 깨진다(§21) |
| I14 | metric 이 무엇도 막지 않는다. 갈래는 타입으로 나눈다. 모양은 하드컷으로 바꾼다 | 경보와 카운터는 아무것도 막지 않는다. 갈래는 닫힌 생성자 위에 있다 | 타입 검사. L9 의 해석 시험 |
| I15 | 지식 하나에 맞는 fact 하나. 낡았는지는 Librarian 이 판단한다. 시간이나 TTL 이 아니다 | Librarian 이 `Drop`, `Merge`, `Revise` 로 판단한다. TTL 도 크기 예산도 fact 를 지우지 않는다. 자리 내기는 Librarian 에게 하는 질문이다 | L1 채점기(merge 뒤 보존, 변화율) |

I15 에는 이 설계가 지키지 못하는 때가 있다. Memory 가 어느 항목과도 함께 들어가지 않는 동안에는 항목만 읽는다. 그동안은 더하기만 하고 합치거나 고치지 못한다(§7.4). 그 상태는 warn 으로, Memory 가 어느 slot 에도 안 들어가면 error(E5)로 보인다(§12.2).

## 15. 처리량

Librarian 은 같이 도는 묻기 수를 정하지 않는다(운영자 결정 2026-11-18). 그래서 묻기 수는 턴이 닫히는 수를 따라간다. 이 절은 그 결과를 재생으로 보인다.

### 15.1 무엇이 묻기 수를 묶나

- Keeper 는 안 읽은 단위가 있고 가는 묻기가 없으면 묻는다. Keeper 마다 하나라서 같이 도는 묻기는 Keeper 수를 넘지 않는다.
- provider 로 나가는 요청은 binding 이 선언한 자리가 묶는다. 자리가 없으면 묻기는 자리를 기다리고, 기다리는 동안 닫힌 턴은 다음 답 하나에 같이 들어간다.
- 지금은 한 시간에 약 4.9개를 반영하고 턴은 98.3개 닫힌다(§1.1). 지금 구조는 도착을 따라가지 못한다.

### 15.2 재생

7일 기록(2026-11-10~11-17, 닫힌 턴 16,519개, 시간당 평균 98.3개, 시간별 p90 169개)을 걷기 규칙대로 다시 돌렸다.
Keeper 턴이 GLM 과 ollama 자리를 잡은 시간도 잰 값 그대로 넣었다(GLM 35,613개, ollama 45,361개 호출). 그 7일의 working-context pass 호출 683개도 넣었다. Keeper 는 29개다.
스크립트와 출력은 근거 폴더에 있다. 아래는 평균 도착, 실패 없음, run limit 선언 없음일 때다.

| lane 에서 쓸 수 있는 HTTP 자리 | slot 속도 | 묻기/h | 하루 생성 | 답 하나의 단위 | 밀림 p50 / p90 / 최대(분) | Librarian 자리 대기 p90 | 900초 넘게 기다린 Keeper 턴 호출(GLM / ollama) |
|---|---|---|---|---|---|---|---|
| GLM 8, tinker 4, ollama 4 | 모두 GLM 속도 | 66 | 1,595 | 1.48 | 9 / 16 / 41 | 78초 | 0 / 0 |
| GLM 8, tinker 4, ollama 4 | 잰 속도 | 77 | 1,851 | 1.28 | 5 / 13 / 27 | 0초 | 0 / 0 |
| GLM 8, ollama 4 | 모두 GLM 속도 | 60 | 1,449 | 1.63 | 12 / 23 / 47 | 403초 | 283 / 1,189 |
| GLM 8, ollama 4 | 잰 속도 | 76 | 1,824 | 1.29 | 5 / 13 / 31 | 42초 | 0 / 0 |
| GLM 8, tinker 4, ollama 4, 매번 실패하는 slot 하나 | 모두 GLM 속도 | – | 1,593 | 1.48 | 10 / 19 / 149 | 1초 | 0 / 0 |
| GLM 8, ollama 4, 매번 실패하는 slot 하나 | 모두 GLM 속도 | – | 1,444 | 1.63 | 15 / 62 / 296 | 2초 | 0 / 0 |

- 밀림은 턴이 닫힌 때부터 그 턴이 반영될 때까지다.
- 잰 속도는 반영까지 간 durable 호출의 시간이다(11-15~11-18). GLM 은 p50 407초, p90 660초, 최대 936초(185개)다. tinker 는 p50 24초, p90 77초(106개)다. ollama 는 p50 51초(7개)다. ollama 표본은 작다.
- 첫 두 행은 지금 durable Librarian 의 lane 선언에서 쉬는 slot 과 매번 실패하는 slot 을 뺀 것이다. 셋째와 넷째 행은 거기서 tinker 를 뺀 것이다.
- 마지막 열은 과장이다. 재생은 기다리는 Keeper 호출이 그 Keeper 의 다음 호출을 늦추지 않는다. 방향만 읽는다.

읽을 것은 넷이다.

1. **묻기는 도착을 따라간다.** 답 하나가 단위 1.3~1.6개를 싣는다. 하루 생성은 1,450~1,850번이고 지금(118번)의 12~16배다.
2. **입력 양.** 지금 durable 질문의 평균 입력은 94,471 token 이다. 그대로면 하루 약 1.4억~1.7억 token 이다. GLM 요금제의 한도와 견주지 못했다(§23).
3. **Keeper 턴과 계정을 나누지 않는 slot 이 있느냐가 가른다.** tinker 가 있으면 Keeper 턴은 기다리지 않는다. 없고 ollama 가 GLM 만큼 느리면, 선언이 없어도 Keeper 턴이 400초짜리 Librarian 호출 뒤에 선다.
4. **매번 실패하는 slot 은 걷기를 끌어간다.** 그 slot 의 자리는 늘 비어 있다. 묻기는 줄에 서지 않고 1초 만에 실패한 뒤 쉬었다가 다음 pulse 에 다시 묻는다. tinker 없는 lane 에서는 7일에 걷기 36,059번이 CLI 층까지 갔고 최대 밀림이 약 5시간이었다.

도착이 p90 수준으로 이어지면(1.69배로 압축한 재생) 하루 생성은 1,900~3,130번이다. 이때는 Librarian 과 무관하게 Keeper 턴만으로 ollama 자리가 넘친다. 그래서 그 재생의 Keeper 대기 수는 Librarian 탓으로 읽지 않는다.

### 15.3 Keeper 턴과 나눠 쓰는 계정

`admission-priority-run-limit` 는 자리를 준 횟수를 센다. 자리를 잡은 시간은 세지 않는다(`slot_scheduler.mli:20-26`).
Librarian 호출 하나는 GLM 자리를 Keeper 턴 호출보다 약 14배 오래 잡는다(413초 대 29.5초, 평균). ollama 에서는 Librarian 이 GLM 만큼 느리다면 약 57배다(413초 대 7.3초).

tinker 없는 lane, 모두 GLM 속도인 재생에서 run limit L 을 바꿨다.

| L | 900초 넘게 기다린 Keeper 턴 호출(GLM / ollama) |
|---|---|
| 선언 없음 | 283 / 1,189 |
| 4 | 13,429 / 39,191 |
| 16 | 0 / 37,466 |
| Keeper 턴이 늘 먼저 | 0 / 0 |

- 점유 비보다 작은 L 은 선언이 없는 것보다 Keeper 턴에 나쁘다.
- 이 RFC 는 L 을 고르지 않는다. 잰 점유 비를 적고, 값은 운영자가 계정별로 정한다(§22).
- tinker 가 있고 잰 속도대로면 어떤 L 이든 「Keeper 턴이 늘 먼저」와 같게 돈다. tinker 가 Librarian 의 짐을 나눠 쓰는 계정 밖으로 가져가서다.

### 15.4 그 밖

- **working-context pass** 는 건드리지 않지만 GLM 자리를 Librarian 묻기와 같이 쓴다. 그 호출의 자리 대기는 tinker 가 있는 lane 에서 p90 116초, 최대 468초다. tinker 없는 lane 에서는 p90 381초, 최대 1,145초다(평균 도착, GLM 속도).
- **가장 나쁜 밀림.** 앞에 묻기 w 개가 있고 자리 N 개가 각각 S 초씩 잡히면 한 묻기는 약 (w + 1) × S / N 초를 기다린다. w = 28, S = 413초, N = 16 이면 723초다. 자기 Keeper 의 묻기가 막 시작한 뒤 닫힌 턴은 그 묻기와 다음 묻기를 다 기다려 약 46분이다.
- **직접 쓰기** 는 모델을 기다리지 않는다. 밀리초다.
- **재시작.** 가던 묻기는 다시 묻는다. 묻기가 시간당 66개이고 하나가 413초면 평균 7.6개가 가는 중이다. 하루 10.7번 재시작하면 하루 약 81번, 전체의 약 5% 를 다시 생성한다(추정).
- **lane 전체 장애.** 2시간 동안 Keeper 27개가 pulse(60초)마다 묻기를 다시 만들면 3,240번이다. 생성은 없고 질문을 다시 만드는 값만 든다. HTTP slot 이 모두 실패하면 짐이 CLI client 둘로 간다.

재지 못한 것은 §23 에 있다. GLM 요금제 한도, 질문 크기와 호출 시간의 관계(입력 1,014,803 token 호출 1건이 523초였다), ollama 의 속도다.

## 16. tick 마다 드는 값

값은 새로 들어온 입력을 따른다. 들어온 것이 없으면 아무것도 읽지 않는다. 이 절은 tick n, n+1, …, n+m 에서 쓰는 쪽 하나가 무엇을 하는지 적고, 그것을 시험으로 고정한다.

쓰는 쪽마다 세는 값은 여섯이다. 턴 기록에서 읽은 바이트, 스냅샷을 읽은 횟수, 반영 기록 꼬리를 읽은 횟수, 만든 질문 수, slot 호출 수, 덧붙인 줄 수다.

| tick | 상태 | 드는 값 |
|---|---|---|
| n: 턴 j 개가 닫혔다 | `Idle` → `Asking` | 그 j 개의 줄과 내용, 스냅샷 한 번, 질문 하나, 걷기 하나. 답이 오면 줄 하나와 스냅샷 쓰기 한 번 |
| n+1 … n+m: 닫힌 턴이 없다 | `Idle` | 여섯 값 모두 0 이다. pulse 마다 턴 기록의 길이를 한 번 본다(stat). 읽지 않는다 |
| n+1 … n+m: 닫힌 턴이 없다 | `Asking` | 묻기가 끝날 때까지 0 이다 |
| n+1 … n+m: 턴 m 개가 묻는 사이에 닫혔다 | `Asking` | 묻기가 끝날 때까지 0 이다. 그다음 질문 하나가 m 개를 같이 싣는다 |
| n+1 … n+m: 닫힌 턴이 없다 | `Resting` | pulse 마다 안 읽은 줄과 내용, 스냅샷 한 번, 질문 하나, 걷기 하나. 안 읽은 양과 Memory 크기에 비례한다. 선언한 slot 이 모두 잡혀 있으면 0 이다. 크기 사실을 가진 slot 을 뺀 나머지가 모두 잡혀 있으면 질문은 만들고 slot 은 부르지 않는다 |
| 언제든 | `Refused_at_bottom`, `Stopped` | 0 이다 |
| Keeper 의 쓰기 | 어느 상태든 | 스냅샷 한 번(sha), 줄 하나, 스냅샷 쓰기 한 번. 모델 호출은 없다 |
| boot | Keeper 마다 | 반영 기록의 꼬리 한 줄, 스냅샷 한 번(sha). 많아야 스냅샷 다시 쓰기 한 번 |

- 스냅샷을 읽는 것은 질문의 내용이라서다. 검증하려고 읽는 것이 아니다.
- 이미 읽은 것을 나열하거나 다시 확인하는 일은 없다. 지금은 패스 하나가 풀 작업 12~15개를 18~50초 동안 차례로 기다리고, 새로 들어온 것이 없어도 그 값을 치른다(§1.1).
- `Resting` 의 값이 가장 크다. 묻기가 반영 없이 끝난 Keeper 는 pulse(60초)마다 질문을 다시 만든다. 바닥에서 쉬는 Keeper 는 아직 답하지 않은 slot 에만 묻는다(§7.5). 크기 사실이 다 모이지 않아 서 있는 Keeper(E4)도 pulse 마다 이 값을 치른다.

시험은 둘이다.

1. 같은 새 입력을 주면 앞선 줄이 10개든 1,000개든 100,000개든 여섯 값이 같다.
2. 새 입력 없이 tick 을 m 번 주면 여섯 값이 모두 0 이다. `Idle` 이면 stat 이 m 번이다.

## 17. 고른 것과 그 값

갈래마다 무엇을 골랐고 무엇을 치르는지 적는다. 운영자 규칙이 정한 갈래는 §22 에 따로 모았다.

| 갈래 | 고른 것 | 치르는 값 |
|---|---|---|
| Memory 저장 모양 | `memory-current.json`, 그 envelope, fact 모양을 바이트 그대로 둔다. 지금 codec 으로 쓴다. 읽은 자리, 출처, 하던 일은 새 반영 기록에 둔다 | 이 스택에서는 fact 에 필드를 더하지 못한다. Keeper 마다 파일이 하나 는다 |
| 하던 일 | Memory 변화와 같은 답, 같은 줄에 싣는다. continuity lane 은 없앤다. working-context pass 는 그대로 둔다 | 컷부터 첫 반영까지 비어 있다. 줄마다 다시 적어서 한 줄이 8~10 KB 다 |
| Memory 크기 | 반영할 때 예산을 보지 않는다. 나누어 저장하지 않는다. 일부만 골라 보여 주지 않는다. provider 가 센 창만이 한도다 | 미리 세지 않는 slot 에서는 binding 의 400K 를 넘은 것을 답이 온 뒤에야 안다. Memory 는 Librarian 이 줄이거나 창에 닿을 때까지 자란다 |
| 쓰기 | 모든 Memory 변화가 Keeper 마다 하나인 쓰는 쪽을 지난다. 직접 쓰기는 모델도 우선순위도 없이 바로 반영한다 | Keeper 의 claim 이 들어가기 전에 아무도 판단하지 않는다. 비슷한 fact 가 다음 읽기까지 같이 산다(밀림 p50 5~12분) |
| 호출 경로 | 서버 프로세스 안에서 `execute_flow_once` 를 부른다. 답은 반영 줄로만 남는다. 재시작하면 다시 묻는다 | 답을 받고 줄을 쓰기 전에 죽으면 그 답은 없다. 다시 묻는 생성 하나를 치른다 |
| 같이 도는 묻기 수 | Librarian 은 수를 정하지 않는다. Keeper 마다 하나이고 provider 자리가 묶는다 | 하루 생성이 지금의 12~16배다(§15) |
| 폭을 줄이는 근거 | 질문을 거절한 slot 이 하나라도 있으면 폭을 줄인다. 한 항목 아래로 가는 일은 선언한 slot 이 모두 입력 크기로 거절했을 때만 한다 | 크기를 타입으로 말하지 않는 slot 이 lane 에 있으면 한 항목 아래로 가지 못한다. 그 항목은 운영자가 건너뛰거나 slot 을 뺄 때까지 맨 앞에 남는다. 그 slot 이 거절로 답하면 E4 가, 말이 없으면 W1 이 켜진다 |
| 한 항목이 안 들어갈 때 | 항목만 먼저 읽는다. 자리 내기는 그 반영 뒤에 한 번 묻는다 | 그 항목은 Memory 없이 읽힌다. 거기서 나온 fact 는 합쳐지지 않고 더해진다 |
| 거절당한 질문 | 한 항목짜리 질문을 크기로 거절한 slot 에는 질문이 바뀔 때까지 다시 묻지 않는다. 크기를 말하지 않은 거절과 말 없음은 기억하지 않는다 | 재시작하면 크기 사실을 잊는다. slot 마다 한 번씩 다시 묻는다. 400 으로 답하는 slot 에는 pulse 마다 다시 묻는다 |
| 쉬는 시각 | 두지 않는다. pulse 마다 다시 묻고, provider 가 시각을 말한 slot 만 부르지 않는다 | 반영 없이 끝난 Keeper 는 60초마다 질문을 다시 만든다 |
| lane 선언 | Librarian 은 자기 lane 표를 읽는다. working-context pass 의 표와 나눈다 | lane 종류가 하나 는다. 설치 때 운영자가 slot 목록을 옮겨 적는다 |
| 읽기 시작점 | Keeper 가 provider 에게 마지막으로 받아들여진 요청의 시작. 풀리지 않으면 지금 | 컷 때 Keeper 의 창 밖에 있던 안 읽은 턴은 읽지 않는다 |
| reset | head 를 바꾸기 전에 줄을 먼저 쓴다. 줄 뒤에 변경이 일어났는지는 가리지 않는다. 다음 단위는 언제나 그 줄의 `after` 에서 시작한다 | 변경이 일어나지 않았으면 `after` 와 `before` 사이를 한 번 더 읽는다. 지우기에서는 Keeper 가 들고 있던 이력 전체다 |
| 턴 밖의 열린 메시지 | 프로세스 시작 단계와 head 를 줄이는 함수가 줄 앞에서 닫는다. 받아들임은 닫지 않는다 | 도중에 죽은 턴 뒤의 프로세스 시작과 head 를 줄일 때에 저장이 한 번 더 든다 |
| purge | Librarian 의 읽은 자리를 보지 않는다. 마지막 단위 줄 아래의 닫힌 메시지만 고쳐 쓴다 | 안 읽은 줄이 가리키는 bundle 은 읽힐 때까지 디스크에 남는다. 단위 줄이 아직 없는 메시지는 다음 purge 까지 그대로다 |
| 반영 기록이 없는 boot | 언제나 첫 boot 다. `Log_started` 부터 읽는다. Keeper 는 쓰는 쪽을 기다리지 않는다 | 없어진 반영 기록은 `Stopped` 로 보이지 않는다. 턴 기록을 처음부터 한 번 더 읽고, 철회한 claim 이 다시 들어올 수 있다. 꼬리를 읽지 못한 반영 기록을 맡길 때도 같다 |
| `Refused_at_bottom` | 상태로 둔다. 모든 slot 이 크기를 말한 질문은 사건이 있을 때만 다시 묻는다 | 상태가 하나 많다. 없으면 서 있는 Keeper 마다 pulse 마다 질문을 다시 짓고 아무것도 알아내지 못한다 |
| 크기를 말하지 않는 거절 | 선언한 slot 이 모두 판정했는데 크기 사실이 다 모이지 않으면 error(E4)다. 말 없음이 섞였으면 warn 이다 | quota 를 맨 400 으로 알리는 provider 가 있으면 그 quota 동안 error 가 켜진다 |
| 꺼진 Keeper | 꺼져 있는 동안 그 턴을 읽지 않는다. 켜면 이어 읽는다 | 지금은 꺼진 Keeper 의 것도 따라잡는다. 켤 때까지 밀린다 |
| 줄이 담는 값 | 턴 기록과 반영 기록의 줄은 자기 모듈의 타입, id, 글만 담는다. Goal 과 Task 는 받아들일 때 글로 바꿔 적는다 | 줄은 그것을 쓴 빌드의 글을 담는다. criterion 을 타입으로 읽으려는 소비자는 줄을 쓰지 못한다 |
| `Idle` 에서 깨는 법 | 귀띔(`Turn_closed`)을 받거나, pulse 가 턴 기록의 길이가 달라진 것을 본다 | `Idle` 인 Keeper 마다 pulse 에 stat 한 번이다 |
| fact 의 출처 | 반영 기록의 `effects.sources` 에 둔다. fact 모양은 그대로다 | 출처를 보려면 기록을 거친다. 컷 이전 fact 는 출처가 없다 |
| 지운 fact 의 기록 | 컷 뒤로는 반영 기록에 통째로 남는다. 옛 journal 과 absorbed 파일은 지운다 | 컷 이전에 지운 claim 은 찾을 수 없다(§22.1) |
| 바깥 판정자 | 반영 경로에 두지 않는다 | 잘못된 merge 가 누가 보기 전까지 Memory 에 있다. 합쳐진 원본은 줄에 남아 되돌릴 수 있다 |

## 18. 설치

하드컷이다. 새 빌드는 옛 Librarian 파일을 읽지 않는다. 옮기는 단계도, 치워 두는 단계도 없다.
절차는 [DURABLE-STORE-HARD-CUT](../guides/DURABLE-STORE-HARD-CUT.md) 의 네 단계를 따른다. 서버를 세우고 띄우는 명령은 운영자가 친다.

### 18.1 이 컷 전에 끝내는 것

이 컷의 단계가 아니다. 먼저 따로 끝낸다.

- 「Exact 요청은 자리만 기다린다」 RFC(#52986)의 자리 걷기 층과 그 아래 로드 요구 층이 운영에 들어가 있다.
- 그 RFC 가 운영자에게 맡긴 일이 끝나 있다. CLI binding 둘에 `max-concurrent` 선언, `max_exact_in_flight` 키 삭제다.
- tinker binding 에 `max-context` 를 선언한다. 지금은 없다.
- Librarian lane 의 출력 몫 R 을 정한다(§6.4). 적지 않은 lane 은 로드되지 않는다.
- Librarian lane 에 모든 호출이 실패하는 slot 이 없다(§15.2 의 넷째 결론). 그런 slot 하나가 11-18 20:13 의 runtime 파일에 남아 있다. 설치 전에 뺀다.
- Keeper 턴과 나눠 쓰는 계정의 run limit 을 정한다(§15.3).
- 남길 스냅샷(`<k>.memory-current.json`)을 새 빌드의 codec 으로 읽어 본다. 읽기 전용 확인이다. 해석되지 않는 스냅샷이 있으면 그 Keeper 의 Memory 는 컷 뒤에 `Stopped Memory_unreadable` 로 선다. Keeper 는 돌고, 그사이의 턴은 스냅샷을 고친 뒤에 읽힌다(§8.6).

### 18.2 단계

1. **서버와 다른 쓰는 프로세스를 모두 멈춘다.**
2. **`runtime.toml` 을 고친다.** 새 parser 는 모르는 키를 거절하고 옛 parser 는 새 표를 거절한다. 그래서 멈춘 동안 고친다.
   - `[runtime.addon_exact_lanes.keeper-librarian.admission]` 과 `.durable` 을 지운다.
   - `.durable` 의 `slots` 와 `cli_slots` 를 새 표 `[runtime.exact_output_lanes.librarian_memory]` 로 옮겨 적는다. 표 이름은 제안이다.
   - `[runtime.exact_output_lanes.librarian_exact]` 는 건드리지 않는다. working-context pass 의 표다.
   - `[typesafeai]` 아래 `absorb_gate` 와 `librarian_preflight` 를 지운다. `context_review` 는 남긴다.
   - 서버 환경에서 `facts_max_bytes` 와 admission 바이트 상한 키를 지운다.
   - 새 lane 표에 `max_output_tokens` 를 넣는다. §6.4 의 두 한도를 보고 정한 값이다.
3. **지운다.** 목록은 §19.1 에 파일마다 있다. 디스크의 모든 Librarian 파일은 그 목록에서 「지운다」나 「남긴다」 가운데 하나다.
4. **새 빌드의 `validate-stores` 를 돌린다.** 읽기 전용이다. 모든 저장소가 통과하고 분류 안 된 파일이 0개여야 한다. blob sweep 의 dry run 도 0개여야 한다. 배포 preflight 는 `keeper-librarian` add-on 이 남아 있으면 거절한다.
5. **설치하고 서버를 띄운다.** 프로세스가 시작할 때 턴 경로가 Keeper 마다 `Log_started` 를 쓴다. 쓰는 쪽은 첫 pulse 안에 생겨 `Started` 를 쓴다. 프로세스가 뜬 뒤 만든 Keeper 는 쓰는 쪽의 저장소 시작이 `Log_started` 를 쓴다.
6. **health 를 본다.** 등록된 Keeper 는 모두 `Idle` 이나 `Asking` 이고 `Stopped` 는 없다. 쓰는 쪽은 첫 pulse 안에 생긴다(§8.6).

### 18.3 첫 한 시간

- 턴이 닫힌 Keeper 는 pulse 한 번 안에 `Asking` 이 된다.
- 첫 질문은 그 Keeper 가 지금 창에 들고 있는 것 전부를 단위 하나로 싣는다(§5.7).
- 첫 반영은 호출 하나 뒤다. 분 단위다.
- 첫 질문이 거절된 Keeper 는 항목 단위로 폭을 줄인다. 그 Keeper 의 줄에 slot 별 결과가 보인다.
- 하던 일은 첫 반영 전까지 비어 있다.

### 18.4 없어지는 것, 되돌릴 수 없는 곳

- 3단계 뒤에는 되돌릴 수 없다. 2단계까지는 아무것도 잃지 않고 멈출 수 있다.
- 옛 admission 큐에서 기다리던 명시적 쓰기는 없어진다(11-17 에 24개, 11-18 에 45개였다). 같은 claim 은 쓰기 도구로 다시 쓸 수 있다.
- 컷 이전에 지운 claim 은 찾을 수 없다(§22).
- Keeper 에게는 무엇이 없어졌는지 알리는 메시지를 보내지 않는다. 프롬프트는 지금 일어나는 일을 평서문으로 다시 쓴다.

### 18.5 나중에 새 파일 하나만 다시 시작할 때

새 두 파일은 저마다 혼자 지워도 나가는 문이 있다. 뒤에 어느 한쪽의 줄 모양을 하드컷할 때 이 절차를 쓴다.

- `turns.jsonl` 만 지운다. 턴 경로가 새 id 로 `Log_started` 를 쓴다. 첫 묻기가 `Turn_log_replaced` 를 알리고, 운영자가 `Restart_reading` 을 한다. 안 읽은 단위는 없어지고 그 사실이 `Skip` 줄로 남는다.
- 반영 기록만 지운다. 다음 boot 가 첫 boot 다. 턴 기록을 `Log_started` 부터 다시 읽는다. 지운 fact 의 기록은 없어진다. 철회한 claim 이 다시 들어올 수 있다(§8.6).
- 둘 다 지운다. 그 Keeper 는 지금부터 새로 시작한다. 안 읽은 단위는 줄 없이 없어진다.
- 반영 기록의 줄 모양만 바뀐 빌드에서는 boot 가 꼬리 줄을 해석하지 못해 `Stopped Log_unreadable` 로 선다. 나가는 길은 둘이다. 운영자가 `Adopt` 하면 턴 기록을 처음부터 다시 읽는다(§8.7). 그 값을 들이지 않으려면 위처럼 두 파일을 지우고 지금부터 시작한다. 그런 빌드의 changelog 는 어느 쪽을 하라는지 적는다.

changelog 는 「Fresh state required」 제목 아래 한 문장이다. 무엇을 읽지 않는지, 그리고 「멈추고, 이 경로들을 지우고, 설치한다」를 적는다. 개수는 적지 않는다.

## 19. 지우는 것

지우는 것은 둘로 나뉜다. 설치 때 운영자가 디스크에서 지우는 파일과, 구현 스택의 마지막 층들이 저장소에서 지우는 코드다.
줄 수는 main `3c4499eceb891` 에서 `.ml` 만 센 값이다. 지우는 층에서 다시 센다.

### 19.1 디스크: 파일마다 지운다, 남긴다

디스크의 Librarian 파일은 모두 아래 표의 한 행에 든다. 새 빌드의 `validate-stores` 가 분류 안 된 파일을 0개로 알릴 수 있어야 한다.

| 곳 | 파일 | 처분 |
|---|---|---|
| `<config keepers>/<k>.` | `memory-current.json` | 남긴다. 바이트 그대로 쓴다 |
| | `memory-source-current.json` 과 그 잠금 | 남긴다 |
| | `working-context*.json` 과 그 잠금 | 남긴다 |
| | `memory-events.jsonl` | 남긴다. 검색 기록이고, 쓰는 곳과 읽는 곳이 그대로다 |
| | 평가 journal | 남긴다 |
| | `memory-journal.jsonl`, `memory-absorbed.jsonl` | 지운다(§22.1) |
| | `memory-admission.json`, `memory-publication.json`, `memory-retraction-plan.json`, `memory-epoch.json` | 지운다 |
| | `librarian-range-commit.json`, `librarian-unread.json` | 지운다 |
| | `*.rejected-*` | 지운다 |
| | 지운 파일들의 잠금, `memory-os-aggregate.lock`, `memory-current.json.lock`, `.lock.lock` 로 끝나는 것 | 지운다 |
| | `turn-boundaries.jsonl` (옛 자리에 남은 것) | 지운다 |
| `<keepers_dir>/<k>/` | `turn-boundaries.jsonl` | 지운다 |
| | `librarian-progress.json`, `librarian-official-progress.json`, `librarian-external-read.json` | 지운다 |
| | `librarian-continuity.json` 과 그 잠금 | 지운다 |
| | working-context recall pin | 남긴다 |
| add-on | `keeper-librarian` 의 writer container, worker volume, 선언, package | 지운다. container 가 먼저다 |
| lane-addon 저장소 | Librarian scope 접두어 아홉 아래의 기록 | 지운다. 경로 목록은 마지막 층이 scope 정의에서 만든다 |
| | 같은 디렉터리의 curator, verifier, Candle, Goal 기록 | 건드리지 않는다 |
| run 기록부 | – | 손으로 고치지 않는다. 자기 보존 규칙이 옛 행을 지운다 |

- 새로 생기는 파일은 둘이다. `<keepers_dir>/<k>/turns.jsonl` 과 `<config keepers>/<k>.memory-log.jsonl` 이다. 잠금 `<k>.memory.lock` 이 하나 더 있다. 두 파일 옆에는 저장소 잠금 `<파일>.lock` 이 생긴다.
- `validate-stores` 는 두 파일을 첫 줄부터 읽는다. 해석되지 않는 줄은 거절로 세고, 그 줄이 시작하는 offset 을 알린다. 줄바꿈 없이 끝난 꼬리는 줄이 아니다.
- 반영 기록에서 해석되지 않는 줄 바로 뒤에 `Started` 줄이 있으면 거절이 아니다. 운영자가 읽지 못한 꼬리를 두고 맡긴 자리다(§8.7). 그 줄은 파일에 계속 남으므로, 거절로 세면 그 Keeper 는 검증을 다시 통과하지 못한다.
- 해석되지 않는 줄 뒤에 반영 줄이 오거나 아무 줄도 없으면 거절이다. 마지막 줄이면 저장소가 boot 에서 멈춘다.
- Keeper 를 지우면 `memory-log.jsonl`, 그 저장소 잠금, `memory.lock` 도 지운다. 반영 기록만 남으면 같은 이름으로 다시 만든 Keeper 의 저장소가 스냅샷이 없다는 이유로 boot 에서 멈춘다.
- blob sweep 은 `memory-log.jsonl` 과 `memory.lock` 을 blob 을 가리키지 않는 파일로 분류한다. 반영 줄에는 blob key 가 없다. 턴 기록이 있는 `keepers` 트리는 이미 분류돼 있다.
- 지금 설정에 없는 Keeper 의 `memory-current.json` 은 그대로 둔다. 쓰는 쪽은 등록된 Keeper 에게만 있다.

### 19.2 코드

**a. 옛 Librarian 경로.** `lib/keeper/keeper_librarian_*.ml` 69개 가운데 63개를 지우고 하나는 이름을 바꾼다. 64개가 20,334줄이다.

- 지운다: `durable_*`, `admission_*`, `floor_*`, `history_resolution`, `history_resolution_*`, `original_*` 전부. 그리고 `absorb_gate`, `queue_refresh`, `store_preflight`, `range`, `continuity`, `message_floor`, `refusal_frontier`, `retained_step_replacement`, `declaration_replacement`, `pending`, `progress*`, `official_progress`, `unread*`, `input_capture`, `input_sources`, `task_context`, `worker_request`, `request_*`, `queue_signal`, `addon`, `memory_plan`, `memory_program`, `history_program_settlement`.
- 남긴다: `keeper_librarian_context`, `_context_io`, `_context_recall`, `_context_review`. `keeper_librarian_runtime` 과 `keeper_librarian` 은 working-context pass 가 쓰는 만큼만 남는다. `keeper_memory_lane` 도 남고, working-context pass 한 가지만 싣는다. pass 하나는 `keeper_working_context_pass` 에 있다. 이 모듈이 모델을 부를지 정하고, 질문을 만들고, 실행한다. 큐 신호를 받아 Keeper 의 memory lane 에 pass 하나를 싣는 등록도 이 모듈에 있다. `submit_durable`(`keeper_librarian_queue_refresh`)과 그것을 부르는 곳 다섯은 지운다. 예약된 pass 가 durable 만 하는 단위로 바뀌던 일(#53000)이 같이 없어진다.
- 이름을 바꾼다: `keeper_librarian_input_refusal` → `keeper_exact_input_refusal`. 생성자 셋짜리 타입이고 Librarian 것이 아니다. Exact 걷기가 쓴다(`keeper_exact_walk_failure`, `keeper_exact_walk_receipt`, `exact_lane_failure`). 그 걷기와 그것을 쓰는 HITL 요약은 이 RFC 가 고치지 않는다. 새 Librarian 은 이 타입을 쓰지 않고 §7.2 의 slot 결과를 쓴다.

**b. Memory 저장소 장치.** 5,138줄이다.

- 지운다: `keeper_memory_os_current_{update, read_anchor, range_codec, receipt_store, publication, revision_evidence, journal, program_apply, retraction_plan}`, `keeper_memory_os_program{,_publication,_types}`, `keeper_memory_os_journal_codec`, `keeper_memory_os_receipt_selection`, `keeper_memory_absorbed`, `check_facts_budget`, `facts_max_bytes`.
- 남긴다: fact 타입, 스냅샷 codec, 파일에 묶인 저장소, `Keeper_memory_os_events`.
- 고쳐 쓴다(남는 것만 추린다). 지우는 모듈을 직접 부르는 단위들이다.

  | 단위 | 남는 것 | 없어지는 것 |
  |---|---|---|
  | `keeper_memory_os_current_types` | 스냅샷 파일을 읽는 데 드는 타입 다섯: `source_kind`, `source`, `support_invalidation`, `change`, `t` | 그 밖의 타입 전부. `removal` 은 `Librarian_effects.removal` 이, `supersession` 과 직접 쓰기의 오류 타입 넷, `retraction`, `commit_effect` 는 §8.5 의 표가, `librarian_failure_kind` 는 §7.2 의 slot 결과가 대신한다. `journal_entry`, range id 둘, `admission_recall*`, `explicit_candidate_id`, `consumed_range`, `durable_range_receipt`, `revision_evidence`, `recall_unresolved*`, `successor_program_*`, `successor_recall*` 는 대신하는 것 없이 없어진다 |
  | `keeper_memory_os_current_change_metrics` | `of_change` | publication 과 stage 로 세던 것 |
  | `keeper_memory_os_current_layout` | 스냅샷 경로 | journal, receipt, epoch, unread ledger 의 경로 |
  | `keeper_memory_os_current` | 스냅샷 읽기 | 쓰기, 복구, journal 읽기. 쓰는 쪽(§8)이 대신한다 |
  | `keeper_memory_os_current_fact_ops` | 스냅샷 파일을 옆으로 치우는 일(`move_aside_for_keepers_dir`). boot 의 저장소 맞춤이 부른다 | 직접 쓰기 넷과 journal 꼬리 읽기. 쓰는 쪽이 대신한다 |
  | `keeper_memory_os_successor_recall` | 뒤이은 fact 후보를 내는 일(§11.5) | 입력이 journal 에서 반영 기록으로 바뀐다. 후보의 타입도 새로 쓴다. 지금 타입(`successor_recall_candidate`)은 지우는 `revision_evidence` 와 `successor_program_step` 을 담는다. 새 후보는 반영 줄의 `removed` 한 항목이다 |
  | `keeper_memory_activity`, `keeper_memory_journal_outcome` | 화면에 내는 값 | 입력이 journal 에서 반영 기록과 쓰는 쪽 view 로 바뀐다(§12) |

  golden fixture 시험(`test_keeper_memory_snapshot_golden`)이 envelope 타입의 첫 소비자다. 타입 파일을 추릴 때 그 시험의 바이트가 그대로여야 한다.

**c. admission 과 cleanup.** 682줄이다. `keeper_memory_admission_{queue, judgment, worker}`, `keeper_memory_cleanup`, admission 바이트 상한이다.

**d. continuity, cursor, 옛 턴 색인.** 1,906줄이다.

- `librarian_continuity_snapshot`, `librarian_continuity_report`, `keeper_continuity_{request, evidence, observation}`, `keeper_external_read_cursor`.
- `keeper_turn_boundaries` 와 그 줄을 만들고 읽는 코드 전부. `Keeper_turn_task_context` 는 턴 기록의 `task_evidence` 로 바뀐다(§5.1).
- `keeper_carried_front` 의 Librarian 출처 다섯(§11.2).
- `turn-boundaries.jsonl` 을 읽던 곳 가운데 컷 뒤에도 남는 곳은 지우지 않고 턴 기록으로 옮긴다. 한 층(L3d)에서 옮긴다. 목록은 아래 k 의 표에 있다.
- 옛 파일 쓰기는 컷(L10)에서 멈춘다. 옛 durable consumer 가 읽은 자리를 그 줄에서 얻기 때문이다(`Keeper_librarian_durable_consumer` 의 `Keeper_turn_boundaries.read`). 쓰기를 먼저 멈추면 컷 앞의 빌드에서 옛 경로가 나아가지 못한다.
- 컷에서 같이 지우는 것은 넷이다. 줄을 쓰는 곳(`keeper_agent_run_finalize_response`, `keeper_history_clear`, `keeper_agent_run_turn_helpers` 의 턴 시작 줄), `keeper_shutdown_types` 의 `Keeper_turn_boundaries_artifact` 생성자와 삭제 계획, `Keeper_durable_store` 의 `Turn_boundaries` 검증, blob 분류의 `.turn-boundaries.jsonl` 행이다.
- L3d 가 옮기지 않은 독자는 컷까지 옛 파일을 그대로 읽는다. 쓰기가 컷까지 이어지므로 그 사이의 빌드에서도 읽는 값이 맞다.

**e. 반영 경로의 판정자.** `Typesafeai_librarian_preflight`, `bin/masc_librarian_preflight_eval.ml`, TUI 의 preflight 표시, `absorb_gate` 와 `librarian_preflight` 키.

**f. add-on.** `addons/keeper-librarian/` 와 `addons/tests/test_keeper_librarian.py`. `addons/exact_worker.py` 는 고치지 않는다. Lane Add-on 틀의 서버 쪽에서 지우는 모듈을 직접 부르는 곳은 셋이다(아래 k). 틀이 싣는 add-on 목록에서도 Librarian 이 빠진다. `Lane_addon_carried` 의 `Keeper_librarian` 갈래, `lib/embedded_exact_addons/dune` 의 `embedded_keeper_librarian` 모듈과 규칙, 그 목록 전체를 도는 `exact_addon_setup`, `bin/main_eio.ml` 의 도움말 글, `lane_addon_store.ml` 의 history fence 와 resolution 디렉터리 이름 둘이다. 이 곳들은 지우는 모듈 이름을 부르지 않아서 k 의 목록에 나오지 않는다. 틀은 나머지 add-on 을 그대로 싣는다.

**g. route 와 도구.** 일괄 cleanup route 의 Memory 철회는 쓰는 쪽으로 쓴다(§20 L5t). `memory-journal`, `memory-facts` route 는 저마다 지우거나 반영 기록을 읽게 고친다. `memory-catch-up` route 와 history resolution route 는 L5p 에서 지운다(`server_routes_http_routes_keepers` 의 등록과 그 handler). `bin/masc_librarian_continuity.ml`, `bin/masc_librarian_replay.ml` 은 지운다.

**h. 시험과 release 목록.**

- 지우는 모듈 이름을 부르는 시험 파일은 98개다(`Keeper_librarian` 이름을 모두 세면 106개). 시험 case 마다 가른다. 남는 모듈(스냅샷 codec, fact 타입, 파일에 묶인 저장소, working-context pass)을 시험하는 case 는 남긴다. 나머지는 지운다. 되살리지 않는다.
- `config/release-behavior.json` 에서 `test_keeper_librarian_continuity` 를 새 기능 시험으로 바꾼다. 반영하고, 재시작하고, view 가 같은 읽은 자리와 Memory 를 보이고, 요청이 읽은 곳의 끝에서 시작하는지를 본다. `test_workspace_memory_ledger` 는 view 위에서 다시 써서 목록에 남긴다.

**i. spec.** `specs/bug-models/LibrarianRead.tla`, `LibrarianContinuityWidth.tla` 와 cfg 24개. §21 의 모델이 대신한다.

**j. 문서와 프롬프트.**

- 다시 쓴다: Memory 안내 넷(`keeper-memory-execution.md`, `keeper-memory-limits.md`, `keeper-memory-recall.md`, `KEEPER-MEMORY-RECOVERY.md`)과 다른 일곱 문서의 Librarian 절.
- 지우는 경로만 말하는 RFC 는 이 RFC 로 superseded 표시한다. 후보는 `docs/rfc/RFC-librarian-*.md` 열 개와 Librarian 절이 있는 번호 RFC 다. 컷 층이 하나씩 읽고 정한다. working-context pass 를 말하는 RFC 는 남는다.
- `config/prompts/librarian.md` 는 답 schema 하나에 맞춰 다시 쓴다. `librarian.preflight.md` 는 지운다. `librarian.context_review.md` 는 남긴다.
- `keeper.md` 와 `keeper_memory_write.toml` 의 Librarian 줄은 지금 일어나는 일을 평서문으로 다시 쓴다. 쓰기는 바로 저장된다는 것이다. 무엇이 없어졌는지는 적지 않는다.

층마다 확인하는 것은 같다. 지운 이름을 부르는 곳이 `lib/`, `bin/`, `test/` 에 없고, 타입 검사가 통과하고, 새 기능 시험이 통과한다.

**k. 지우는 모듈을 부르는 바깥 코드.** 지우거나 이름을 바꾸는 모듈은 99개다. 위 a~e 의 93개와, 하는 일이 전부 옛 경로라 같이 지우는 단위 여섯이다. 그것을 직접 부르는 바깥 단위는 59개다(`lib/`, `bin/`). 목록은 근거 폴더의 `cut-callers/callers.tsv` 이고, 같은 폴더의 스크립트가 다시 만든다.

| 처분 | 단위 |
|---|---|
| 같이 지운다. 하는 일이 전부 옛 경로다. 지우는 집합에 넣었다 | `bin/masc_librarian_continuity`, `bin/masc_librarian_replay`, `bin/masc_librarian_preflight_eval`, `server_librarian_addon_validation`, `server_librarian_addon_wake`, `server_dashboard_http_keeper_memory_history_resolution` |
| 이름만 따라 바꾼다 | `keeper_exact_walk_failure`, `keeper_exact_walk_receipt`, `exact_lane_failure` (위 a) |
| Librarian 을 가르던 곳만 지운다. 나머지는 다른 add-on 이 쓴다 | `server_lane_addon_exact`(`authorize_request` 가 Librarian 요청이면 `Background` 와 Librarian 의 출력 검사를 골랐다), `server_unowned_exact_sweep`(`original_required` 의 Librarian 항), `server_settled_archive_sweep`(Librarian 의 gate 모듈로 기록을 가르던 갈래) |
| 고쳐 쓴다. 부르는 코드를 지우거나 새 모듈로 바꾼다 | 나머지 53개. 턴 기록으로 옮기는 것(위 d), Memory 저장소(위 b), Keeper 와 만나는 곳(§11), 화면과 route(§12, 위 g), purge(§5.6), boot 의 등록(`server_runtime_bootstrap` 은 `queue_refresh` 설치 대신 `keeper_working_context_pass` 의 설치를 부르고, add-on wake 설치를 지운다) |

- 같이 지우는 단위를 집합에 넣으면 그 단위를 부르는 곳이 다음 출력에 나온다. 그렇게 다시 돌려 새로 나온 단위가 셋이다(`server_lane_addon_exact`, `server_unowned_exact_sweep`, `server_routes_http_routes_keepers`). 셋 다 통째로 지우는 단위가 아니어서 거기서 멈춘다.
- Librarian 이 Lane Add-on 틀에서 나가면(§4) 틀의 Exact 요청은 모두 `Standard` 로 받는다. 틀 안에서 `Background` 를 고르던 곳은 Librarian 갈래 하나였다(`server_lane_addon_exact.ml:351`).
- **이 목록은 하한이다.** 모듈 이름을 직접 적은 `.ml`, `.mli` 만 잡는다. 다음은 잡지 못한다.
  - 지우지 않는 facade 를 거쳐 부르는 곳. `keeper_memory_os_current` 를 거쳐 `recover_publication` 을 부르는 `keeper_store_boot_reconcile` 이 그렇다. facade 를 추릴 때 드러난다.
  - dune 파일. `lib/dune` 의 `private_modules` 에 오른 지우는 모듈과 `bin/dune` 의 실행 파일 정의 셋이다.
  - 모듈이 아니라 함수나 값을 지우는 곳. `check_facts_budget`, `facts_max_bytes`, `MASC_KEEPER_MEMORY_OS_FACTS_MAX_BYTES` 를 정의하거나 읽는 단위다(§11.6, §19.3).
  - 생성자 이름으로만 닿는 곳. `keeper_shutdown_types` 의 `Keeper_turn_boundaries_artifact` 가 그렇다(위 d).
- 컷이 끝났다는 기준은 이 목록이 아니다. 지운 이름이 `lib/`, `bin/`, `test/` 와 dune 파일에 없고 타입 검사가 통과하는 것이다.
- 처분은 단위의 머리말과 부르는 이름을 읽고 정했다. 컷 층이 단위를 열어 보고 바꾸면 이 표를 같이 고친다.

### 19.3 지우는 층에서 다시 확인할 것

- `lib/librarian_working_state_evaluation.ml`, `lib/librarian_production_evaluation.ml` 은 지운다. 부르는 곳이 `bin/masc_librarian_continuity.ml` 과 자기 시험뿐이고, 그 실행 파일도 지운다. 새 평가 틀(§20 의 L1)이 대신한다.
- `keeper_memory_os_disposition_core` 는 고쳐 쓴다. 부르던 곳은 셋이고(`keeper_memory_os_current_program_apply`, `keeper_memory_os_program`, `keeper_librarian_memory_plan`) 모두 지운다. 지금 내보내는 `plan` 은 옛 답의 목록을 받고 op 번호를 돌려주지 않아서 쓰는 쪽이 그대로 부를 수 없다(§8.2).
- `keeper_checkpoint_purge.ml` 은 턴 기록으로 옮기는 곳이지만 옮기지 않고 지우는 것이 있다. Librarian 의 읽은 자리를 보던 거절(`Unread_atoms_present`)과 복구 울타리(`recovered_units`, `position_at_end`, `Recovery_end_unwitnessed`)다. purge 는 Librarian 의 자리를 읽지 않는다(§5.6). atom 을 여는 메시지의 digest 를 지키던 규칙도 같이 없어진다. 자리를 수로 적기 때문이다.
- `history_at_start` 타입을 읽던 곳은 `Opened.baseline` 을 읽는다(§11).
- 환경 변수 `MASC_KEEPER_MEMORY_OS_FACTS_MAX_BYTES` 를 읽는 코드를 `check_facts_budget` 와 같이 지운다. 그 검사는 평범한 fact 와 파일에 묶인 저장소의 줄을 함께 셌다.
- `keeper_librarian_continuity.ml:345` 와 `librarian_continuity_snapshot.ml:185` 가 `turn-boundaries.jsonl` 을 읽는다. 둘 다 지우는 목록에 있는 모듈이다. 지우는 층에서 부르는 곳을 다시 확인한다.

## 20. 구현 스택

이 RFC 가 먼저 자기 PR 로 병합된다. 코드는 그 뒤에 native stack(`gh stack`) 하나로 올린다. 스택은 맨 위 PR 로 한꺼번에 병합하고 운영에는 한 번에 들어간다.

지키는 것은 넷이다.

1. 스택의 어느 빌드에서나 Memory 를 쓰는 곳은 하나다.
2. 전환(L5) 뒤의 층은 모두 서버의 실제 경로가 부른다. 부르는 곳이 없는 코드 위에 시험을 쌓지 않는다.
3. 새 파일의 store 검증, Keeper 삭제 계획, blob GC 분류는 서버가 그 파일을 처음 쓰는 층이나 그 앞의 층에 넣는다.
4. 삭제는 마지막이다. 커밋 하나가 파일 다섯 개를 넘지 않는다.

쓰는 쪽을 서버가 시작하는 층은 턴 기록을 쓰는 층(L3c) 뒤에 온다. 턴 기록이 없는 Keeper 의 저장소는 `Store_unwritable` 로 서고 쓰기는 `Unavailable` 로 답한다.

앞서 끝나 있어야 하는 것은 「Exact 요청은 자리만 기다린다」 RFC(#52986)의 자리 걷기 층이다. 그 층이 병합되기 전에는 이 스택의 어느 PR 도 `exact_output.ml`, `exact_output.mli`, `retry.ml` 을 고치지 않는다.

| 층 | 넣는 것 | 확인 |
|---|---|---|
| L0 | 이 RFC, 연구 기록, 근거 폴더(상태 표와 검사 스크립트, 모델과 결과, 자리 재생, slot 결과 분류 표) | 독립 리뷰 판정. 상태 표와 slot 결과 표의 검사 스크립트를 돌린 결과를 근거 폴더에 적는다. 표가 OCaml 의 `match` 가 되는 L5·L6 부터는 컴파일러가 빠진 쌍을 잡는다 |
| L1a | 답의 타입과 codec(§6.2), 질문 id 의 반쪽 둘, 스냅샷 codec 의 golden fixture | 네 op 의 왕복. 글로 고정한 wire 모양. 답 전체를 버리는 이유 넷과 op 하나의 흠. fixture 가 지금 codec 과 바이트로 같다 |
| L1b | 순수 계획 `Librarian_plan.of_answer` 와 효과 타입 `Librarian_effects`(§8.1, §8.2): 이름 풀기, op 하나의 흠, 근거 잃은 fact, 거두기. `removal` 은 답이 만드는 넷만 넣는다. 직접 쓰기의 둘(`Superseded_by`, `Retracted`)은 L5a 가 더한다 | 계획 규칙마다 시험. 거둔 op 가 번호로 돌아온다. `Merge` 가 원본과 새 fact 를 함께 잃지 않는다 |
| L1c | 채점기. 프롬프트보다 먼저 고정한다. slot 별로 센다: 버린 답(이유별), 뺀 op(이유별), Memory 를 바꾼 답, 단위가 말한 것 가운데 Memory 에 든 것, merge 가 지킨 것. case 가 기대하는 것은 case 에 token 으로 적고, 채점기는 세기만 한다 | 고정한 답 일곱의 점수표가 시험에 글로 박혀 있다(`test_librarian_scoring`). 채점기를 고치면 그 표가 바뀐다. 아무것도 바꾸지 않은 답은 회수 수가 0 이다. 처음 Memory 가 이미 가진 token 은 세지 않는다 |
| L2 | Agent-Core 의 끝맺음 타입 다섯(§7.2). `Context_overflow` 는 status 와 무관하게 자기 타입, 창에서 멈춘 응답은 자기 생성자, `Invalid_request` 는 400·422 만, `Incomplete_output` 은 stop reason 을 싣는다, 창 넘침 code 를 문서로 정한 provider 에만 속한 codec 이 그 code 로 `Context_overflow` 를 만든다. 기존 소비처는 새 생성자를 전과 같은 분류로 받는다. 새 분류는 slot 결과를 분류하는 층(L6)이 읽는다 | 생성자마다 분류 시험. `classify` 에 와일드카드가 없다. 선언한 slot 마다 창을 넘는 질문을 한 번 보내고, 돌아온 타입 있는 결과를 slot 별 표로 PR 에 붙인다. 그 표가 크기를 타입으로 말하는 slot 과 그렇지 않은 slot 을 가른다. 말하지 않는 slot 은 거절하는지 말이 없는지를 열 하나로 적는다 |
| L3a1 | 턴 기록의 줄: 줄 타입(자기 모듈 타입만, `Keeper_turn_log`), codec(`Keeper_turn_log_codec`), 줄이 단위를 어디서 끝내는가(§5.3 의 표), 받아들이는 줄 순서(§5.2 끝). 파일을 읽거나 쓰지 않는다. 턴을 깨운 것(`stimuli`)은 L3a3 이 event queue 를 바꾸는 함수와 함께 더한다 | 줄 모양마다 왕복 시험과 글로 박은 모양. 표의 세 행. 순서 규칙의 오류 다섯. 줄 codec 모듈이 Goal·Task 저장소에 의존하지 않는다 |
| L3a2 | 턴 기록의 파일(`Keeper_turn_log_store`): 꼬리 읽기와 끝을 확인하는 덧붙임. 꼬리는 끝에서 뒤로 필요한 줄까지만 읽는다. 단위를 끝낸 마지막 줄과 마지막 `Opened` 나 `Closed` 다. 메모리에 두는 것은 없다 | 줄 종류마다 꼬리가 말하는 것. 한 번의 덧붙임에 두 줄. 낡은 끝으로 덧붙이면 아무것도 쓰지 않는다. 끊긴 조각은 줄이 아니고 다음 덧붙임이 잘라 낸다. 해석 안 되는 줄이 꼬리에 있으면 덧붙이지 않는다 |
| L3a2b | 닫힌 메시지 세기와 slice(`Keeper_turn_log_marks`): head 의 segment 와 닫힌 턴이 가진 메시지 수, 그리고 메시지 번호 둘 사이를 bundle 조각으로 적는 함수. object 를 읽지 않는다. 범위가 head 앞에서 시작하면 부르는 쪽이 앞 segment 를 읽어 붙인다 | 열린 메시지는 세지 않는다. 턴 안에서 시작하고 끝나는 범위. 턴을 어떻게 나눠도 같은 범위가 같은 메시지를 가리킨다(purge 가 bundle 을 합친 뒤에도 같다) |
| L3a3a | 턴 경로가 쓸 줄을 정하는 순수 함수(`Keeper_turn_log_writer.plan`): 읽은 꼬리, 지금 끝자리, 일어난 일(받아들임, 끝남, 프로세스 시작)에서 한 번에 덧붙일 줄을 낸다. 덧붙임은 마지막 줄의 offset 을 돌려주고 턴이 그것을 끝까지 든다 | 속성 시험 T1 의 턴 경로 부분(§13 F1). 받아들임, 끝남, 프로세스 재시작, 잃은 덧붙임, 실패한 저장, 바뀐 head 를 깊이 8 까지 모든 순서로 섞는다. 덧붙일 때마다 줄의 순서, 「닫힌 메시지가 한 번씩 순서대로 이름 붙는다」, 「`own` 은 그 턴이 열린 것으로 보였을 때 닫힌 것이다」를 본다. 수로 보이지 않는 head 교체는 세고 따라가지 않는다 |
| L3a3b1 | 저장된 Agent-Core 이력의 head 읽기(`Keeper_turn_log_head`). 닫힌 메시지 수, 열린 메시지 수, head 가 가진 턴을 낸다. message object 는 읽지 않는다. checkpoint 가 없거나 이 빌드가 바꿔 쓰는 옛 버전이면 빈 이력으로 읽는다. 범위가 head 의 턴보다 앞에서 시작하면 앞 segment 를 그 이름으로 읽어 붙인다 | 저장소의 저장 함수로 만든 이력에서 센다. segment 하나를 넘는 이력에서 segment 안에서 시작하는 범위를 가리킨다. 「빈 이력으로 읽는다」와 「그 상태에서 턴이 새로 시작한다」가 네 상태에서 같다. 네 상태는 checkpoint 없음, 옛 버전, 새 버전, head 가 아닌 바이트다. 옛 버전 뒤의 첫 저장은 같은 session 의 이력이다. segment 가 없거나 다른 바이트면 오류다 |
| L3a3b2 | 나머지 저장소의 끝 읽기(`Keeper_turn_log_ends`). official-client 파일 둘과 chat 파일은 마지막 줄바꿈 바로 뒤의 offset 이다. 외부 저장소는 온전한 행의 수다. 저장소마다 그 저장소가 쓰는 잠금 아래에서 읽는다. 아직 없는 파일의 끝은 0 이다 | 반만 쓰인 행은 끝 밖이다. 그 행이 다 쓰이면 끝이 행 하나만큼 옮겨 간다. 파일이 아닌 것이 그 자리에 있으면 0 이 아니라 오류이고, 어느 저장소인지 말한다 |
| L3a3b3 | 기록하기 한 번: 꼬리 읽기, head 읽기, 끝자리 잡기, `plan`, 앞 segment 읽기, 덧붙임을 잇는다. 끝이 달라졌으면 꼬리부터 다시 한다 | 실제 파일과 저장소의 저장 함수로 시험한다. kill 시험(도중에 저장하고 죽은 턴의 메시지가 `Process_exited` 단위에 든다). head 가 가진 턴보다 긴 범위는 segment 를 읽어 가리킨다. 줄어든 head 는 reset 뒤에 처음부터 실린다. 수로 보이지 않는 head 교체는 옛 수까지의 메시지를 싣지 않는다(§22.4). 끊긴 덧붙임이 남긴 조각 뒤에도 다음 줄이 써진다. 읽지 못한 head 로는 줄을 쓰지 않는다 |
| L3a3b4a | 턴이 자기 줄을 쓴다. 받아들일 때 `Opened`, 끝날 때 `Closed` 다. 두 줄을 쓰는 곳은 하나다(`Keeper_turn_log_turn.around`). 옛 경계 파일 옆에 쓴다. 닫는 저장이 한 일을 턴이 끝까지 들고 간다. 카운터 `turn_log_append_failed` | 끝나는 길마다 `Closed` 가 정확히 하나다. 길은 돌려줌, 예외, 취소다. 줄을 못 써도 턴의 답과 예외가 그대로다. 실패한 저장은 `Save_failed`, 쓰지 않은 저장은 `Stale_save` 로 실린다 |
| L3a3b4b | 받아들임은 head 의 열린 메시지를 닫지 않는다. §5.2 와 모델(`LibrarianTurnLog`)을 그렇게 고친다. 코드는 L3a3b4a 그대로다. 턴 앞에서 head 에 열린 메시지를 두는 제품 경로가 있어서다. Keeper 만들기의 첫 저장, 멈춘 턴을 잇는 저장(gate, checkpoint, runtime), 입력을 기다린 답의 저장이다. 받아들임이 닫으면 이어 가는 턴의 메시지가 Task 없이 실린다 | 모델의 정상 설정이 모두 통과한다. 받아들임이 닫는다는 규칙에 기대던 설정과 속성이 없어진다. 열린 메시지는 그것을 닫은 저장의 단위에 든다 |
| L3a3b4c | 프로세스 시작 단계(`Keeper_turn_log_process_start`). checkpoint 꼬리 복구 뒤, Keeper 턴 앞에서 저장된 Keeper 마다 돈다. 마지막 `Opened` 가 열려 있으면 head 의 열린 메시지를 닫고 `Closed {Process_exited}` 를 쓴다. 턴 기록이 없으면 `Log_started` 를 쓴다. 카운터 `turn_log_open_close_failed` | 죽은 턴이 저장한 메시지가 `Process_exited` 단위에 든다. 열린 턴이 없으면 head 의 열린 메시지를 그대로 둔다. 읽지 못한 턴 기록에는 닫지도 쓰지도 않는다. 닫는 저장이 실패해도 줄을 쓰고, 줄을 못 써도 프로세스 시작이 그대로 간다 |
| L3a3b4d | `Opened` 가 `stimuli` 를 싣는다. event queue payload 를 줄 타입으로 옮기는 전체 함수를 둔다(`Keeper_turn_log_turn.stimulus`). 턴을 도는 함수가 받은 queue 항목을 인자로 받는다. 이 칸이 없는 `Opened` 는 읽지 않는다 | payload 갈래마다 줄 타입이 하나다. 줄 타입마다 글로 박은 모양. 턴 기록에 쓰는 코드가 끝을 확인하지 않는 덧붙임(`Fs_compat.append_jsonl`)을 부르지 않는다 |
| L3b | official-client 턴의 단위가 두 이력 파일에서 그 턴의 줄과 같은지 턴 전체를 돌려 확인한다. 제품 코드는 바뀌지 않는다. 끝자리 읽기는 L3a3b2 가 넣었고, 받아들일 때의 근거는 L3a3b4a 와 L3a3b4d 가 넣었다 | 단위의 바이트 범위에 그 턴을 이름 붙인 줄이 전부 있고 다른 줄이 없다. 마지막 단위는 파일 끝에서 끝난다. 직접 턴, 실패한 턴, 스스로 깬 턴, 같은 trace 의 두 턴에서 본다. Codex app server 의 턴 fixture 에서 돈다. 나머지 official-client runtime 셋에는 턴 전체를 도는 fixture 가 없다(이슈 #53384). 이력 줄을 쓰는 세 곳은 runtime 을 가리지 않는다 |
| L3c | reset: head 를 줄이는 제품 경로 둘(이력 지우기의 갈래 다섯, recovering purge)이 함수 하나를 지난다(조건 확인, 줄, head 순서). session 을 지우는 정지가 지우기 전에 줄을 쓴다. CLI purge 를 compare-and-swap 으로 옮긴다. 함수는 줄 앞에서 head 의 열린 메시지를 닫는다. 줄 뒤에 head 변경이 일어났는지는 가리지 않는다. 알리지 않은 reset 을 줄 쓰는 쪽이 적는다 | 줄을 쓰고 죽는 시험과 head 변경이 오류를 돌려주는 시험이 같은 결과를 낸다: 다음 단위가 `after` 에서 시작하고, 건너뛴 메시지가 없다. 도중에 저장하고 죽은 턴 뒤의 지우기와 recovering purge 에서, 버린 메시지가 열려 있던 것까지 `Reset` 줄의 `closed_before` 에 있다. 닫는 저장이 실패하면 줄도 head 변경도 없다. session 을 지우는 정지 뒤에 `Unannounced` 줄이 있고, 덧붙임이 실패하면 session 이 남는다. 덧붙임이 실패하면 head 가 그대로인 시험, 줄과 head 변경 사이에 턴이 받아들여지지 않는 시험, 지우기의 갈래마다 줄 시험 |
| L3d | `turn-boundaries.jsonl` 을 읽던 곳 가운데 컷 뒤에도 남는 곳을 턴 기록으로 옮긴다(§19.2 d). 옛 파일 쓰기는 컷(L10)에서 멈춘다 | 옮긴 독자마다 다시 쓴 시험. 요청 seed 가 같은 atom 에서 풀린다 |
| L4 | lane 선언: Librarian 의 built-in lane 과 그 표, 풀린 lane 값(질문 쪽 값과 slot 별 key), `lane_held` | 로드 시험. 선언이 같으면 값이 같고, slot 하나의 창이 바뀌면 값이 다르다 |
| L5a | 직접 쓰기의 계획(`Librarian_direct.plan`, §8.5 의 표). 순수 함수다. `removal` 에 직접 쓰기의 둘(`Superseded_by`, `Retracted`)과 쓴 이(`actor`)를 더한다. 부르는 곳은 L5 의 쓰는 쪽이다 | 표의 행마다 시험. 줄을 쓰는 답마다 효과를 적용한 Memory 에 같은 fact 가 둘 없고 근거 없는 파생 fact 가 없다. 철회가 그 fact 에 기댄 fact 를 같은 계획에서 지운다. 같은 쓰기를 두 번 하면 둘째는 줄을 쓰지 않는다 |
| L5b | 반영 기록의 줄: 줄 타입(`Librarian_log`)과 codec(`Librarian_log_codec`, §8.1). 파일을 읽거나 쓰지 않는다. `cause` 는 전환이 만드는 둘(`Direct`, `Adopt`)만 넣는다. `Read`, `Make_room`, `Skip` 과 그것이 싣는 타입은 그것을 만드는 층(L6, L7)이 더한다. fact 는 스냅샷 codec 으로, 끝자리는 턴 기록 codec 으로 쓴다 | 생성자마다 왕복 시험과 글로 박은 모양. object 마다 field 집합이 정확히 맞아야 한다. 읽기는 쓰기가 실은 글(claim, 이유, 이름)을 거절하지 않는다. 쓰는 쪽이 쓴 줄을 읽는 쪽이 거절하면 저장소가 선다 |
| L5c | 반영 기록의 파일(`Librarian_log_store`): 꼬리 줄 읽기와 끝을 확인하는 덧붙임. 꼬리 줄 하나만 읽는다. 메모리에 두는 것은 없다. 파일은 스냅샷 옆에 있다(`<k>.memory-log.jsonl`) | 덧붙인 줄이 꼬리가 된다. 꼬리 앞의 줄은 읽지 않는다. 끊긴 조각은 줄이 아니고 다음 덧붙임이 잘라 낸다. 해석 안 되는 꼬리는 그 offset 과 함께 오류다. 낡은 끝으로 덧붙이면 아무것도 쓰지 않는다 |
| L5d | 줄에서 스냅샷을 만드는 순수 함수(`Librarian_envelope.after`, §8.2 의 3단계)와 첫 boot 의 빈 envelope. 직접 쓰기의 줄이 그 쓰기가 온 trace 를 싣는다(`Direct.trace`). 계획이 빈 trace 를 거절한다 | 만든 스냅샷마다 스냅샷 codec 으로 다시 읽는다. 같은 줄에서 두 번 만들면 바이트가 같다. 철회가 지운 fact 와 근거를 잃은 fact 가 `change` 에 실린다. 맡김은 바이트를 바꾸지 않는다. 다음 revision 이 아닌 줄은 거절한다 |
| L5e | Keeper 하나의 Memory 저장소(`Librarian_store`): boot 표와 직접 쓰기의 반영 2~5단계. 잠금과 fiber 는 없다. 턴 기록의 첫 줄을 읽는 함수(`Keeper_turn_log_store.read_start`). 줄에서 만든 스냅샷이 바이트와 함께 나온다(`Librarian_envelope.next`) | boot 표의 행마다 하나. 반영이 `basis` 와 `after` 로 이어진다. 스냅샷이 한 줄 늦으면 boot 가 그 줄에서 다시 쓰고, 두 번 해도 같다. 밖에서 바꾼 스냅샷은 반영과 boot 를 `Log_diverged` 로 세운다. 읽은 뒤에 다른 줄이 붙으면 덧붙이지 않는다. 스냅샷 쓰기만 실패하는 갈래는 시험이 없다 |
| L5f | 맡김(`Librarian_store.adopt`, §8.7). 해석되지 않는 꼬리가 줄이 끝나는 곳을 함께 알린다 | 밖에서 바꾼 스냅샷을 맡기면 줄 하나가 붙고 boot 가 열린다. 다음 반영이 그 줄에 이어진다. sha 가 다르거나 해석되지 않으면 거절하고 쓰지 않는다. 꼬리가 해석되지 않으면 `Started` 를 그 뒤에 쓰고 `seq` 를 1 부터 센다 |
| L5g | 상태표의 판단(`Librarian_machine`): boot, 직접 쓰기, `Resume`, `Adopt` 가 `Idle`, `Stopped` 에서 하는 일. `Retired` 는 등록부가 답한다. 동기 함수고 fiber 가 없다. 묻기의 상태와 사건은 그것을 만드는 층이 더한다 | 칸마다 하나. 줄을 쓰지 않는 답은 상태와 반영 기록을 그대로 둔다. 밖에서 바꾼 스냅샷을 만난 쓰기가 저장소를 세우고, 그 뒤의 쓰기는 거절된다. 파일을 되돌리고 `Resume` 하면 열린다. `Adopt` 는 `Log_diverged` 와 `Log_unreadable` 에서 받고 그 뒤의 쓰기가 이어진다 |
| L5h | 쓰는 쪽 fiber(`Librarian_writer`): 잠금, boot, mailbox, 읽는 쪽이 보는 상태, `Retire`. 사건마다 `Librarian_machine` 을 부른다. 등록부와 pulse 는 없다 | boot 전에 온 쓰기가 boot 뒤에 답을 받는다. 쓰기는 온 순서대로 반영된다. 턴 기록이 없으면 멈추고, 생긴 뒤 `Resume` 하면 열린다. 같은 Keeper 의 둘째 쓰는 쪽은 잠금을 못 잡는다. 등록된 Keeper 의 `Retire` 는 버린다. 끝난 쓰는 쪽은 받지 않았다고 답하고, 잠금이 풀려 둘째가 이어서 쓴다 |
| L5i | 쓰는 쪽 등록부(`Librarian_writers`): 표, `ensure`, view, 쓰기와 운영자 행동을 쓰는 쪽에 보내기, `Retire`, pulse. 아직 등록부를 만드는 곳은 없다 | 등록된 Keeper 를 처음 물으면 답이 `Booting` 이고 표에 쓰는 쪽이 생긴다. 등록되지 않은 Keeper 는 view 가 `No_writer` 이고 쓰기와 운영자 행동이 `Keeper_retired` 이며 파일이 생기지 않는다. 같은 Keeper 에 나란히 온 쓰기 둘이 한 쓰는 쪽에서 `seq` 1, 2 가 된다. 껐다가 다시 켠 Keeper 의 쓰기가 거절되지 않는다. 등록된 Keeper 의 `Retire` 는 버린다. 등록에서 뺀 뒤의 `Retire` 뒤에는 잠금이 풀려 있다. pulse 가 묻기 전에 쓰는 쪽을 만든다 |
| L5j | 반영 기록을 처음부터 읽는 것(`Librarian_log_store.fold`)과 나간 fact 의 읽기(`Librarian_archive`). 아직 부르는 곳은 없다 | 줄마다 시작 offset 과 함께 순서대로 나온다. 해석 안 되는 줄은 그렇게 표시돼 나오고, 끊긴 조각은 줄이 아니다. 한 번에 읽는 줄 수를 넘는 기록도 한 번씩 다 나온다. 철회한 fact, 근거를 잃은 fact, 대체된 fact 가 나간 순서대로 이유와 함께 나온다. 다시 더한 fact 와 지금 스냅샷에 있는 fact 는 빠진다. 해석 안 되는 줄은 수로 센다 |
| L5k | 턴 기록과 반영 기록의 store 검증(`Keeper_durable_store` 의 `Turn_log`, `Memory_log`). 반영 기록과 쓰는 쪽 잠금의 blob GC 분류. 턴 기록을 처음부터 읽는 것(`Keeper_turn_log_store.fold`) | 턴 기록의 해석 안 되는 줄은 offset 과 함께 거절된다. 끊긴 꼬리는 줄이 아니다. 반영 기록의 해석 안 되는 마지막 줄은 거절되고, 맡긴 뒤에는 행으로 센다. 해석 안 되는 줄 뒤에 반영 줄이 오면 거절된다. 쓰는 쪽이 한 번 반영한 workspace 에서 blob sweep 이 분류 안 된 이름을 0개로 알린다 |
| L5l | Keeper 삭제 계획이 반영 기록, 그 잠금, 쓰는 쪽 잠금을 지운다. 쓰는 쪽을 먼저 끝내는 것은 전환 층이 잇는다 | 삭제 계획에 세 파일이 든다 |
| L5m | working-context pass 하나를 `keeper_librarian_queue_refresh` 에서 `keeper_working_context_pass` 로 옮긴다. 동작은 같다 | 옛 모듈의 pass 가 새 모듈을 부른다. 기존 시험 둘이 새 이름으로 같은 것을 단언한다 |
| L5n | Keeper 의 `keeper_memory_write` 가 admission queue 에 넣지 않고 지금 스냅샷에 바로 쓴다. queue 에 넣는 곳은 이 도구 하나였다. 이미 든 줄은 옛 admission pass 가 비우고, 파일은 컷에서 지운다 | 평범한 관찰이 바로 지금 Memory 에 든다. 같은 claim 을 다시 쓰면 `reobserved` 다. 옛 admission 경로의 시험은 queue 를 직접 채운다 |
| L5o | 서버가 큐 신호에 working-context pass 만 싣는다. launch, boot, checkpoint purge 가 durable catch-up 을 싣지 않는다 | launch 가 memory lane 에 아무것도 싣지 않는다. 돌고 있는 unit 뒤에 쌓이는 것이 없다 |
| L5p | 운영자가 옛 durable pass 를 싣던 두 길을 지운다. `memory-catch-up` route 와 TUI 의 `/memory sync`, history original resolution route 다 | `/memory sync` 는 모르는 명령이다. 두 경로에 route 가 없다 |
| L5q | workspace 마다 쓰는 쪽의 표 하나를 쥐는 모듈(`keeper_memory_writers`). 표는 서버가 시작하고, 시작한 switch 와 같이 끝난다. 이 층에서는 서버가 아직 시작하지 않는다 | 등록부에 없는 Keeper 는 쓰는 쪽이 없다. 스냅샷과 반영 기록이 Keeper config 디렉터리에 생긴다. 턴 기록이 없는 Keeper 의 저장소는 선다. 시작하지 않은 workspace 에는 표가 없다 |
| L5r | 쓰는 쪽이 스냅샷의 새 revision 을 알린다(`Keeper_memory_commit_notifications`). 옛 쓰기 경로가 반영 뒤에 하던 일이다 | 저장소가 열릴 때와 반영마다 revision 하나가 들린다. 아무것도 쓰지 않은 답과 선 저장소는 알리지 않는다 |
| L5s | 서버가 workspace 의 쓰는 쪽 표를 시작하고 maintenance tick 이 pulse 한다. Keeper 의 `keeper_memory_write` 와 `keeper_memory_retract` 가 쓰는 쪽으로 쓴다. 운영자 cleanup route 와 Keeper 삭제는 다음 층이다 | 도구 시험이 영수증, 스냅샷, 반영 기록을 본다. Librarian 이 넣은 fact 를 `supersedes` 한다. 없는 대상은 claim 이 이미 있으면 `already_superseded` 이고 아니면 거절이다. 쓰는 쪽이 없으면 `memory_unwritable` 이다 |
| L5t | 운영자의 철회 route 가 철회마다 쓰는 쪽에 `Retract` 하나를 쓴다. 요청은 스냅샷의 revision 과 sha 를 싣지 않는다. Keeper 삭제가 파일을 지우기 전에 쓰는 쪽을 끝낸다 | 운영자의 철회가 반영 기록의 줄이 되고, 그 뒤에 Keeper 의 쓰기가 반영된다. 같은 요청을 다시 보내면 줄이 늘지 않는다. 등록된 Keeper 의 파일은 지우지 않는다 |
| L5u | 운영자 route `POST <k>/memory/act` 가 `Resume` 과 `Adopt` 를 쓰는 쪽에 보낸다. 답은 `Done` 과 그 뒤 저장소의 상태이거나 거절한 이유다 | 밖에서 바뀐 스냅샷으로 멈춘 저장소를 `Resume` 하면 같은 이유로 멈춘다. 파일의 sha 로 `Adopt` 하면 열리고 줄이 하나 붙는다. 열린 저장소는 둘 다 거절한다 |
| L5 | **전환.** 운영자 행동 route 와 TUI 진입, 반영 기록을 읽는 `memory_search`. Keeper 의 쓰기·철회 도구가 이것을 쓴다. 옛 durable, admission, cleanup consumer 는 이 층부터 시작하지 않는다 | 단계마다 crash 를 넣는 시험. 두 번 복구. 밖에서 바꾼 스냅샷은 `Log_diverged` 가 되고 `Adopt` 가 푼다. 같은 fact 에 옛 codec 과 바이트가 같다. 둘째 프로세스는 잠금을 못 잡는다. 껐다가 다시 켠 Keeper 의 쓰기가 거절되지 않는다. Keeper 를 띄우는 코드와 등록부에서 빼는 코드가 쓰는 쪽 모듈을 부르지 않는다. 꼬리를 읽지 못한 반영 기록을 맡기면 턴 기록의 처음부터 읽는다. 묻는 중인 Keeper 를 지운 뒤에 스냅샷 파일이 다시 생기지 않는다. 반영 기록에 쓰는 코드가 끝을 확인하지 않는 덧붙임(`Fs_compat.append_jsonl`)을 부르지 않는다 |
| L6 | 묻기: 질문 만들기와 싣기, 만든 질문의 고정 corpus(합성 자료만. 단위의 타입이 L3a 에서 생기므로 여기서 넣는다), slot 결과 분류, 묻는 fiber 와 걷기, `Read` 반영, 다시 쓴 프롬프트 | 가짜 provider: 닫힌 턴 셋이 질문 하나, 반영 하나가 된다. 호출 중 재시작은 다시 묻기 하나다. §13 의 F2, F7, F10, F11 시험. L1c 채점기를 slot 마다 돌린 결과를 붙인다. corpus 를 만들 때 셋을 검사하고 어긋난 case 를 거절한다. merge 가 지울 수 있는 fact 가 모두 `must_keep` 에 있다. token 이 다른 낱말이나 수의 일부가 아니다. token 이 처음 Memory 의 claim 에 없다. 채점기는 처음 Memory 가 가진 token 을 어느 수에도 세지 않는다. 그래서 셋째 검사가 없으면 `planted` 가 조용히 줄어든다 |
| L6h | 저장소 시작의 첫 단계(§8.6). 턴 기록 writer 의 `start`, recorder 의 `record_start`, `Keeper_turn_log_store_start.run`. 쓰는 쪽이 boot 마다 먼저 부르고 서버가 그 함수를 넘긴다 | 턴 기록이 없는 Keeper 의 첫 boot 가 `Log_started` 를 쓰고 열린다. 첫 단계가 실패하면 `Stopped Store_unwritable` 이다. `Resume` 이 두 단계를 다시 한다. 열린 턴은 닫지 않는다. 턴이 먼저 시작한 기록에는 쓰지 않는다. 찢긴 첫 줄은 잘리고 0 자리에 쓴다. 메타데이터가 없는 Keeper 는 첫 줄을 쓰지 못한다 |
| L7 | 폭과 바닥: 폭 기억, 바닥의 크기 판정, 항목만 읽기, 자리 내기, 건너뜀, 쉼, 운영자의 건너뛰기 셋 | 가짜 tokenizer 시험(F6). 바닥의 끝마다 타입 있는 결과에 닿는다. 크기를 말하지 않는 slot 을 넣은 lane 은 그 slot 이 거절하면 E4 에서, 말이 없으면 W1 에서 선다. 가짜 시계로 쉼 시험. L2 의 slot 별 표에서, 운영 lane 이 한 항목 아래의 단계에 닿는지를 PR 에 적는다 |
| L8 | Keeper 와 만나는 곳, runtime 다섯: view, 읽은 곳의 끝, 요청이 뒤에서 시작했다는 표시, 하던 일. purge 규칙과 sweep 뿌리 | runtime 마다 §13 의 G11 시험. 읽지 않은 턴을 purge 해도 그 단위가 줄을 쓸 때의 내용으로 읽힌다. 쓰는 쪽이 `Stopped` 여도 purge 가 돈다. sweep 이 꼬리 줄의 턴 기록 id 가 다르면 모든 줄을 뿌리로 잡고, 턴 기록을 읽지 못하면 아무것도 지우지 않는다 |
| L9 | 화면과 경보: health 절, `keeper-memory-health` 행, TUI 해석, 수준 함수 | 생성자마다 해석 시험. health JSON 에 자유 글이 없다 |
| L10a~e | 컷. §19.2 의 삭제를 다섯 파일 이하 커밋으로. 시험을 가른다. release 목록, 프롬프트, 안내 문서. 옛 spec 을 지운다(§19.2). §21 의 모델은 이 RFC 와 같이 `specs/bug-models/` 에 들어와 있다 | 지운 이름을 `rg` 로 찾아 0. 타입 검사. L3~L9 의 기능 시험. working-context pass 시험: 끝난 턴 하나가 pass 하나를 만들고 Memory 를 쓰지 않는다 |
| L11 | 남은 등록: 배포 preflight 가 `keeper-librarian` add-on 을 거절한다. 설치 안내(§18)와 scope 경로 목록. changelog 의 「Fresh state required」 항목 하나. 밖에서 읽는 곳 확인 | fixture base path 에 시험 설치를 하면 쓰는 쪽이 모두 `Started` 로 boot 한다. Keeper 삭제가 새 파일만 지운다 |

- 층 하나는 PR 하나이고 출력 약 20k token 이하다. 맨 아래 PR 은 Core 빌드만 확인한다. CI 를 지켜보며 기다리지 않는다.
- L5 앞의 빌드에서는 옛 경로가 그대로 돈다. L5 부터 L6 앞까지의 빌드에서는 Librarian 이 읽지 않고 직접 쓰기만 Memory 를 바꾼다. 운영에는 스택 전체가 한 번에 들어가므로 이 중간 빌드는 운영에서 돌지 않는다.
- 평가 corpus 는 합성 자료다. Keeper 의 대화나 Memory 글은 공개 저장소에 넣지 않는다.
- 모델 검사는 dispatch 로 돌린다. PR 마다 도는 CI 를 더하지 않는다.

## 21. 모델 검사

설계의 규칙 가운데 순서와 되풀이에 달린 것은 TLA+ 모델로 확인했다. 모델은 셋이고 `specs/bug-models/` 에 있다.

| 모델 | 다루는 것 | 절 |
|---|---|---|
| `LibrarianWidth` | 폭 기억. 거절, 반영, 다음 폭 | §7.6 |
| `LibrarianWriter` | 쓰는 쪽의 상태 기계, 등록부와 `ensure`, boot, 묻기의 끝, 운영자 행동, 경보 | §8, §9, §12 |
| `LibrarianTurnLog` | 턴 기록의 줄, reset, purge, sweep, 읽는 쪽의 결함 | §5 |

### 21.1 읽는 법

- 설정(cfg) 이름에 `-buggy` 가 없으면 정상 설정이다. TLC 가 닿을 수 있는 상태를 다 돌고 오류 없이 끝나야 한다.
- `-buggy` 설정은 규칙 하나를 옛 것이나 틀린 것으로 바꾼다. 이름 붙은 속성 하나를 어겨야 한다. 어기지 않으면 그 속성은 아무것도 지키지 않는 것이다.
- `-reachable-buggy` 설정은 「이 가지에는 닿지 않는다」는 속성을 건다. 어겨야 한다. 정상 설정의 통과가 닿지 않는 가지의 통과가 아님을 보인다.
- `specs/Makefile` 의 규칙이 그대로 이것이다. `make -C specs check-bug-models` 가 정상 설정은 종료 코드 0, `-buggy` 설정은 12 나 13 인지 본다.
- 저장소에는 180초 안에 끝나는 설정만 둔다. 설계하면서는 더 큰 설정도 돌렸다. 시간 한도에서 멈춘 설정은 통과로 세지 않았다.
- 돌린 도구는 `tla2tools-1.8.0.jar` 다. 그 jar 는 자기를 `TLC2 Version 2026.05.26.235334` 라고 적는다. Java 는 OpenJDK 21.0.9 다.

모델은 설계를 확인한다. 코드를 확인하지 않는다. 코드는 층마다의 시험이 확인한다(§13, §20). 구현하면서 규칙이 바뀌면 그 층의 PR 이 모델을 같이 고친다.

### 21.2 `LibrarianWidth`

한 걸음이 묻기 하나다. lane 의 답은 셋이다. 실은 범위의 무게가 `Capacity` 이하면 답하고, 넘으면 거절하고, 언제든 말이 없을 수 있다.
쓰는 쪽이 기억하는 범위 옆에, 기준 규칙으로 따로 적는 범위를 둔다. 버그를 심은 쓰는 쪽이 범위를 잊어도 속성이 그것을 본다.

| 속성 | 뜻 |
|---|---|
| `NeverPassesRefusedEnd` | 거절된 범위 안에서 시작한 묻기는 그 범위의 끝을 넘지 않는다 |
| `NeverWholeRefusedRangeAgain` | 거절된 범위 전체를 다시 묻지 않는다 |
| `NotRefusedBefore` | 같은 자리에서 거절된 범위를 그대로 다시 묻지 않는다 |
| `HalfStep` | 거절 한 번은 절반(내림)까지만 줄이고, 0 으로 줄이지 않는다 |
| `SilenceChangesNothing` | 말 없음은 기억도 다음 폭도 바꾸지 않는다 |
| `NoEntryOffersAll` | 기억한 범위가 없으면 안 읽은 것 전부를 묻는다 |
| `MemoryIsReference` | 쓰는 쪽의 기억이 기준 규칙의 기억과 같다 |
| `Drains` | 답과 거절이 공정하게 오면 안 읽은 것이 빈다. 말 없음은 몇 번이든 올 수 있다 |

정상 설정 다섯이 여덟 속성을 모두 지킨다.

| 설정 | 모양 | 상태 수 |
|---|---|---|
| `LibrarianWidth` | 무거운 항목이 앞에 있는 단위 넷, 도착 둘, `Capacity` 2 | 550 |
| `-units` | 한 항목짜리 단위 여덟 | 128 |
| `-items` | 다섯 항목짜리 단위 하나와 두 항목짜리 하나 | 133 |
| `-cap3` | 첫 설정에 `Capacity` 3 | 407 |
| `-items-cap3` | 셋째 설정에 `Capacity` 3. 일부를 읽은 범위의 나머지가 다시 거절된다 | 103 |

| 심은 버그 | 어긴 속성 | 반례의 상태 수 |
|---|---|---|
| `skip-push-when-left-is-n`: 가장 안쪽 범위의 남은 양이 n 이면 올리지 않는다 | `NotRefusedBefore`. `-live` 설정에서는 `Drains` | 8, 11 |
| `release-on-commit`: 반영할 때 기억을 비운다 | `NeverPassesRefusedEnd` | 5 |
| `no-carry`: 거절을 기억하지 않는다 | `Drains` | 6 |
| `narrow-on-silence`: 말 없음에 폭을 줄인다 | `SilenceChangesNothing` | 2 |

닿는다는 것을 보인 가지는 둘이다. 항목 층을 쓴다(`item-level-reachable`). 거절된 범위 둘을 같이 든다(`two-ranges-reachable`).

다루지 않는 것: 어느 slot 에도 안 들어가는 한 항목(§21.5), slot, Memory, 기억을 비우는 사건(boot, 선언 변경).

### 21.3 `LibrarianWriter`

Keeper 하나와 그 쓰는 쪽이다. Memory 는 fact 이름의 집합이고, 턴 기록은 종류가 붙은 단위의 줄이다.
걸음은 사건이다. 턴이 닫힌다, 묻기가 끝난다, 쓰기가 온다, pulse 가 돈다, Keeper 를 끄고 켠다, 프로세스가 죽는다, 운영자가 행동한다.
경보 E1~E5 와 W1 은 쓰는 쪽 기억의 함수로 둔다.

| 속성 | 뜻 |
|---|---|
| `Chain` | 줄의 `basis` 는 앞 줄의 `after` 다 |
| `SnapshotLag` | 스냅샷은 반영 기록보다 많아야 한 줄 늦다 |
| `PositionMoves` | 읽기, 건너뛰기, 처음부터 다시 읽기만 읽은 자리를 옮긴다. 범위는 이어진다 |
| `PositionHasLine` | 쓰는 쪽이 든 읽은 자리는 꼬리 줄의 것이다 |
| `PassedAccounted` | 읽은 자리가 지난 단위는 모두 읽기 줄이나 건너뛰기 줄에 이름이 있다. 맡김도 같다 |
| `AnswerAtMostOnce`, `AnswerOnlyWhenCurrent` | 답은 많아야 한 번, 지금 묻기의 답만 반영된다 |
| `NoUndoRetract` | 질문을 만든 뒤에 철회한 fact 를 그 답이 되살리지 않는다 |
| `OneLiveWriter` | 등록부가 산 쓰는 쪽을 밀어내지 않는다 |
| `RegisteredHasWriter` | 등록된 채 있는 Keeper 는 산 쓰는 쪽을 갖게 된다 |
| `RefusedRetiredOnlyAfterUnregister` | 등록된 Keeper 의 쓰기는 `Keeper_retired` 로 거절되지 않는다 |
| `UnregisteredNotRead` | 등록되지 않았고 쓰는 쪽이 물러난 Keeper 는 읽히지 않는다 |
| `BootingReadFlagged`, `UnmarkedReadIsChecked` | boot 중이거나 쓰는 쪽이 없을 때의 Memory 읽기는 「확인 전」을 싣는다. 표시 없는 읽기는 꼬리 줄의 Memory 를 본다 |
| `KeeperNeverWaits` | 쓰는 쪽의 어느 상태도 Keeper 의 턴을 붙잡지 않는다 |
| `NoSilentPark` | 안 읽은 것이 있고 도는 묻기가 없으면 경보가 켜져 있다 |
| `E3OnHeadLine` | E3 은 읽은 자리가 이미 지난 줄 위에 서지 않는다 |
| `QueuedWriteEnds`, `ReadsAllOnceRunning` | boot 를 기다린 쓰기는 끝난다. 쓰는 쪽이 계속 돌면 운영자 없이 다 읽는다 |

정상 설정 다섯이 지킨다.

| 설정 | 모양 | 상태 수 |
|---|---|---|
| `LibrarianWriter` | 등록부. Keeper 를 끄고 다시 켠다, 쓰기, 죽음, 쉼, pulse | 124,786 |
| `-asks` | 묻기. 범위, 항목만, 자리 내기, 쉼, 거절, 한 항목의 두 열, 실패한 묻기, 쓰기, `Resume` | 280,752 |
| `-boot` | boot. 멈추는 첫 boot(스냅샷, 잠금, `Started` 쓰기 실패), `Resume`, 해석되지 않는 꼬리 줄, `Adopt`, 죽음 | 121,949 |
| `-turnlog` | 턴 기록의 흠. 해석되지 않는 줄, 알리지 않은 reset, 없어진 내용, `Skip_line`, `Skip_item` | 46,668 |
| `-live` | 살아 있음 속성 셋 | 7,624 |

| 옛 규칙이나 심은 버그 | 어긴 속성 |
|---|---|
| Keeper 를 띄우는 길이 쓰는 쪽을 만들고, 길 하나가 빠뜨린다 | `RegisteredWriteReachesAWriter`, `RegisteredHasWriter` |
| `ensure` 가 등록부를 보지 않는다 | `UnregisteredNotRead` |
| `ensure` 가 찾기와 넣기를 두 걸음에 한다 | `OneLiveWriter` |
| 쓰는 쪽이 다시 켜진 Keeper 의 `Retire` 도 받는다 | `RefusedRetiredOnlyAfterUnregister` |
| `Booting` 의 읽기만 표시한다 | `UnmarkedReadIsChecked` |
| 읽지 못한 꼬리를 맡기면 턴 기록의 끝에서 시작한다 | `PassedAccounted` |
| 반영 기록이 없을 때 턴 줄을 잃은 기록으로 읽는다 | `PassedAccounted` |
| 줄이 들어가기 전에 읽은 자리를 옮긴다 | `PositionHasLine` |
| 받아들인 `Skip_line` 이 마지막 묻기의 결과를 남긴다 | `E3OnHeadLine` |
| 지금 묻기가 아닌 답을 반영한다 | `AnswerOnlyWhenCurrent` |
| 계획이 그사이의 철회를 보지 않는다 | `NoUndoRetract` |

닿는다는 것을 보인 가지는 다섯이다. 다시 켠 Keeper 의 쓰기를 새 쓰는 쪽이 반영한다, 맡긴 뒤에 단위를 처음부터 한 번 더 읽는다, 쓰기가 boot 를 기다렸다가 반영된다, boot 중에 턴이 닫힌다, `Retire` 가 boot 하는 쓰는 쪽의 mailbox 에서 기다린다.

다루지 않는 것: Keeper 여럿, 파일의 바이트, slot 별 크기 사실.

### 21.4 `LibrarianTurnLog`

head 하나와 턴 기록 하나, 그 기록을 읽는 쪽이다. 메시지는 이름이고, 열려 있거나 닫혀 있다.
걸음은 줄을 쓰는 쪽들이다. 받아들임, 닫는 저장, 끝남, 프로세스 시작 단계, head 를 줄이는 함수, 고쳐 쓰기만 하는 purge, session 을 지우는 정지, sweep, 읽는 쪽의 반영.
덧붙임과 닫는 저장은 실패할 수 있고, 프로세스는 어느 걸음 사이에서든 죽을 수 있다.

| 속성 | 뜻 |
|---|---|
| `NoSilentSkip`, `NoSkipOfHeadMessage` | 닫힌 메시지는 모두 줄에 이름이 있거나, 기록된 모르는 구간에 있거나, 없어진 파일과 함께 갔거나, 다음 단위 줄이 싣는다 |
| `NoOpenLost` | 열린 채로 head 를 떠나는 메시지는 없다. 줄에 구간을 적은 정지만 다르다 |
| `EveryClosedInOneUnit` | 닫힌 메시지는 단위 하나에 든다. 둘에 드는 것은 지우기가 남긴 메시지와 일어나지 않은 head 변경뿐이다 |
| `OwnNotClosedBefore` | 턴의 `own` 은 그 턴을 받아들일 때 이미 닫혀 있던 메시지를 싣지 않는다. 그때 열려 있던 메시지는 그 턴이 닫을 것이라 실을 수 있다 |
| `UnreadReadable`, `UndeliveredReadable` | 아직 읽지 않은 것은 줄이 이름 붙인 내용 그대로 저장소에 있다. 파일이 잘리거나 바뀐 뒤에도 같다 |
| `PurgeOnlyRewritesNamed` | purge 는 줄이 이름 붙인 것만 고쳐 쓴다 |
| `OnlyWrittenOrder` | 줄의 순서는 `Log_started ( Reset \| Opened Reset* Closed )*` 다 |
| `ShrinkOnlyByNamedPaths`, `MarksOnlyShrinkAtReset` | 닫힌 수는 줄을 먼저 쓴 head 변경, session 을 지우는 정지, 제품 밖의 수정으로만 준다. `Opened` 와 `Closed` 의 끝자리는 앞 줄보다 내려가지 않는다 |
| `NoDoubleRead`, `PassedAccounted`, `UnknownRecorded`, `SkipRecorded` | 읽는 쪽. 두 번 읽지 않고, 지난 것은 줄에 이름이 있고, 모르는 구간과 건너뜀은 기록된다 |

정상 설정 다섯이 지킨다.

| 설정 | 모양 | 상태 수 |
|---|---|---|
| `LibrarianTurnLog` | 턴 경로, 프로세스 시작 단계, 일어나지 않을 수 있는 알린 reset 하나. 메시지 셋, 줄 여섯 | 22,097 |
| `-purge` | 고쳐 쓰기만 하는 purge 와 프로세스 시작 때의 sweep | 23,587 |
| `-stop-removes-session` | session 을 지우는 정지 둘과 그 사이의 `Opened` 없는 턴 | 25,856 |
| `-file-replaced` | 읽는 쪽이 반영한 뒤 턴 기록을 지우고 새 파일이 자란다 | 1,729 |
| `-named-once` | 두 번 드는 원인 둘을 끈 모양. 어느 메시지도 두 번 이름 붙지 않는다 | 65,630 |

| 옛 규칙 | 어긴 속성 |
|---|---|
| head 를 줄이는 함수가 열린 메시지를 먼저 닫지 않는다 | `NoOpenLost` |
| `Opened` 뒤에 `Reset` 이 있는 `Closed` 의 범위가 전부 `own` 이다 | `OwnNotClosedBefore` |
| 정지가 줄 없이 session 을 지운다 | `NoSilentSkip` |
| 정지가 같은 `after` 의 줄이 있으면 줄을 쓰지 않는다 | `NoSilentSkip` |
| 일어나지 않은 reset 을 수로 가려 거둔다 | `NoSilentSkip` |
| purge 가 마지막 단위 줄의 끝자리 위를 고쳐 쓴다 | `UnreadReadable` |
| purge 가 열린 메시지도 고쳐 쓴다 | `UnreadReadable` |
| sweep 이 head 만 뿌리로 잡는다 | `UnreadReadable` |
| sweep 이 offset 을 확인 없이 쓴다 | `UndeliveredReadable` |

닿는다는 것을 보인 가지는 여덟이다. 설정 이름이 `-reachable-buggy` 로 끝난다.

턴 밖에서 열린 메시지를 두는 저장은 걸음으로 따로 두지 않았다. 닫는 저장이 실패한 턴이 같은 상태를 만든다. 받아들일 때 열려 있던 메시지가 그 턴의 `own` 에 드는 가지는 `-held-owned-reachable-buggy` 가 보인다.

다루지 않는 것: 메시지의 바이트, official-client 의 fragment, Keeper 여럿, 제품 밖에서 손으로 한 수정.

### 21.5 모델에 없는 것

- **한 항목에서의 slot 별 크기 사실(§7.4).** `LibrarianWriter` 의 `-asks` 설정은 항목만 읽기, 자리 내기, 두 열을 사건으로 다룬다. slot 마다의 사실과 그것을 접는 `decide`, E4 의 조건은 모델에 없다. 이 규칙들의 앞선 판은 설계하면서 모델로 돌렸다. 지금 글의 규칙으로는 다시 돌리지 않았다. 그 코드를 쓰는 층(L7)이 모델을 같이 넣는다.
- **head 를 줄이는 함수가 쥐는 잠금.** 모델은 줄과 head 변경 사이에 턴이 받아들여지지 않는다고 둔다. 그 잠금이 없으면 메시지 하나가 기록 없이 지나간다(8 상태). 코드에서 확인하는 곳은 §23.2 에 있다.
- **한 run 에 겹친 결함.** 늦은 닫는 저장, purge, reset, 실패한 덧붙임을 한 run 에 모두 넣은 설정은 시간 한도에서 멈췄다. 셋으로 나눈 설정은 통과했다. 넷이 한꺼번에 겹친 경우는 확인하지 못했다.

## 22. 규칙으로 정한 것

이 RFC 의 결정 가운데 운영자가 앞서 세운 규칙에서 나온 것을 모았다. 규칙을 따랐을 때 치르는 값을 같이 적는다. 뒤집으려면 여기서 뒤집는다.

### 22.1 운영자가 따로 정한 것 하나

**이 컷이 지나면, 컷 이전에 지운 claim 을 다시 찾을 수 없다. 운영자가 2026-11-18 에 받아들였다.**

- 지금 `memory_search source=dropped|absorbed` 는 `<k>.memory-journal.jsonl`(134.8 MB)과 `<k>.memory-absorbed.jsonl`(24.3 MB)을 읽는다(11-18 에 잰 크기).
- 컷 뒤에는 지운 fact 가 반영 기록에 남는다. 옛 두 파일을 읽는 코드는 없다.
- 이것을 정하는 규칙은 2026-11-03 의 하드컷 규칙이다. 옛 모양을 읽는 코드를 두지 않고, 나중을 위해 파일을 남겨 두지도 않는다. 그래서 「파일만 남긴다」는 선택지가 없다.
- 11-17 의 결정(「Memory 내용과 원본 턴은 남기고 장부만 새로 시작한다」)만으로는 이 삭제가 나오지 않는다. 그 결정은 지운 claim 의 기록을 말하지 않는다. 그래서 따로 물었다.
- 값: 컷 이전에 잘못 합친 fact 는 Memory 에서 찾거나 되돌릴 수 없다. 원본 턴은 남는다.
- 고르지 않은 쪽: 옛 두 파일의 줄을 새 반영 기록의 줄로 옮기는 단계를 한 번 둔다. 11-03 규칙을 이 두 파일에 한해 푸는 일이다.
- 옛 지운 claim 을 얼마나 찾는지는 재지 못했다. 기록된 검색 576번 가운데 `source` 를 준 것이 134번인데, 어느 값을 줬는지는 기록에 없다.

### 22.2 규칙과 그 결과

| 규칙 | 이 RFC 에서 정해진 것 | 치르는 값 |
|---|---|---|
| 하드컷은 fresh state 다. 옛 모양을 읽는 코드, 변환, 치워 두는 단계를 만들지 않는다(11-03) | 옛 Librarian 파일을 지우고 설치한다(§18). 옛 admission 큐에서 기다리던 명시적 쓰기는 없어진다 | 11-18 에 45개가 기다리고 있었다. 같은 claim 은 쓰기 도구로 다시 쓸 수 있다 |
| 같은 규칙 | 컷 때 Keeper 의 창 밖에 있던 안 읽은 턴은 읽지 않는다. 옛 이력의 bundle 을 가리키는 단위를 만드는 단계를 두지 않는다 | 그 턴에서 나왔을 fact 는 Memory 에 없다. 원본 턴은 남는다 |
| 어느 client 에도 바이트 상한을 두지 않는다(10-06) | `facts_max_bytes` 와 `check_facts_budget` 를 지운다. 쓰기를 크기로 거절하지 않는다. 파일에 묶인 저장소도 바이트로 묶지 않는다 | Memory 는 Librarian 이 줄이거나 창에 닿을 때까지 자란다. 크기는 화면에 보인다 |
| Librarian 은 같이 도는 수를 정하지 않는다(11-18) | 묻기가 턴 도착을 따른다. Keeper 마다 하나이고 provider 자리가 묶는다 | 하루 생성이 지금의 12~16배다. GLM 요금제 한도와는 견주지 못했다(§23) |
| 바깥 판정자는 반영 경로 밖에 둔다(11-17) | 답을 받으면 바로 반영한다. gate 와 preflight 를 지운다 | 잘못된 merge 가 누가 보기 전까지 Memory 에 있다. 원본은 줄에 남는다 |
| heuristic 을 두지 않는다. masc 는 자기 판단으로 slot 을 쉬게 하지 않는다(프로젝트 지침) | 매번 실패하는 slot 은 운영자가 lane 에서 뺀다. 설치 전에 하나를 빼야 한다. 11-18 20:13(KST)의 runtime 파일에는 세 목록에 그대로 있다. slot 의 id 는 여기에 적지 않는다. 공개 저장소이고 binding id 가 계정 이름을 싣는다. 컷 전에 운영자에게 따로 알린다(§18.1) | 그런 slot 이 다시 생기면 걷기가 끌려간다(§15.2). 운영자가 행에서 보고 빼야 한다 |
| 건너뛰기를 400 으로 넓히지 않는다(11-12) | 바닥에서도 400 과 422 는 기억하지 않는다. 그 slot 에는 pulse 마다 다시 묻는다 | 400 이면 요청 하나씩이 들고 생성은 없다. 모델이 내용을 거절한 stop reason 이면 생성 하나씩이다. 선언한 slot 이 모두 그렇게 거절하면 E4 가 켜진다(§12.2) |
| 기존 Gate 가 없어도 durable truth 가 유지되면 지운다(프로젝트 지침) | purge 가 Librarian 의 읽은 자리를 기다리던 거절을 지운다(§5.6). 안 읽은 줄은 bundle 로 자기 내용을 읽는다 | 안 읽은 줄이 가리키는 bundle 이 읽힐 때까지 디스크에 남는다 |
| 새 Gate 는 없으면 durable truth 가 손상될 때만 더한다(같은 지침) | Keeper 의 턴을 Librarian 의 파일에 묶는 곳을 두지 않는다. 반영 기록이 없으면 언제나 첫 boot 로 읽어서, Keeper 가 쓰는 쪽보다 먼저 돌아도 안 읽고 지나가는 턴이 없다(§8.6) | 없어진 반영 기록은 「잃었다」로 보이지 않고 첫 boot 로 읽힌다. 턴 기록을 처음부터 한 번 더 읽는다. 철회한 claim 이 다시 들어올 수 있다 |
| 재시도 간격은 고정 maintenance pulse 다. provider 가 시각을 말했으면 그때까지만 더 기다린다(constitution) | 쉬는 Keeper 는 pulse(60초, 코드 상수)마다 다시 묻는다. provider 가 잡아 둔 slot 은 부르지 않는다 | 반영 없이 끝난 Keeper 는 60초마다 질문을 다시 만든다 |
| 지식 하나에 맞는 fact 하나(11-09) | Librarian 이 `Drop`, `Merge`, `Revise` 로 지킨다 | Memory 가 어느 항목과도 함께 들어가지 않는 동안은 지키지 못한다(§7.4). Memory 없이 읽는 동안은 warn, Memory 가 어느 slot 에도 안 들어가면 error(E5)로 보인다(§12.2) |

11-12 의 결정보다 넓힌 곳이 하나 있다. 그때의 건너뛰기는 입력 크기 거절만, HTTP slot 만, 쉬는 slot 이 있을 때만이었다.
이 RFC 는 바닥에서 타입 있는 크기 사실 셋 모두에, CLI slot 에도, 같은 질문을 다시 보내게 되는 모든 때에 건너뛴다(§7.4).
한 항목에서 출력이 잘리는 slot 은 물을 때마다 생성 하나를 쓴다. Librarian 자신의 대기 줄이 없어서 이것을 달리 묶는 것이 없다. 그래서 넓혔다.
출력이 잘렸다는 사실은 그 한 번의 생성에 대한 것이다. 같은 질문에 다시 물으면 들어갈 수도 있다. 그래서 그 사실로 선 읽기는 표본 하나에 기대고 있다. `Resume` 이 다시 묻게 한다.

### 22.3 운영자가 선언으로 정하는 것

이 RFC 가 고르지 않는 값이다. 잰 것만 적었다.

| 선언 | RFC 가 적은 것 |
|---|---|
| Librarian lane 의 slot 목록 | Keeper 턴과 계정을 나누지 않는 slot 이 있느냐가 Keeper 턴의 대기를 가른다(§15.2) |
| Keeper 턴과 나눠 쓰는 계정의 run limit | Librarian 호출은 GLM 자리를 약 14배 오래 잡는다. 그보다 작은 값은 선언이 없는 것보다 Keeper 턴에 나쁘다(§15.3) |
| 출력 몫 R | 켠 lane 은 적어야 로드된다. 정할 때 볼 한도 둘(§6.4) |
| slot 별 창 | tinker binding 에는 `max-context` 선언이 없다. 컷 전에 넣는다(§18.1) |

### 22.4 판단으로 정한 것

규칙에서 나오지 않아 이 RFC 가 고른 것이다. 다르게 정해도 설계의 나머지는 그대로다.

| 고른 것 | 다르게 하면 |
|---|---|
| 한 항목에서 말 없는 slot 때문에 쉬는 Keeper 는 warn 이다 | error 로 올리면 자리나 quota 가 돌아오면 끝나는 일도 error 로 보인다 |
| 선언한 slot 이 모두 판정했는데 크기 사실이 다 모이지 않은 Keeper 는 error 다(E4) | warn 으로 두면, 운영자가 slot 을 빼야만 끝나는 정지가 재시작 직후의 warn 과 같은 수준으로 보인다 |
| 판정에 기대는 경보는 그 판정이 지금의 Memory 와 lane 값에 대한 것일 때만 켠다 | 켜 둔 채로 두면, 운영자가 Memory 를 줄인 뒤에도 재시작 전까지 오류가 남는다 |
| Memory 없이 읽는 동안은 warn 이다. Memory 가 어느 slot 에도 안 들어가면 error 다 | 앞의 것도 error 로 올릴 수 있다. 그동안 합치기와 고치기가 멈춰 있다 |
| 반영 기록이 없으면 턴 기록에 무엇이 있든 첫 boot 다 | 「턴 줄이 있으면 잃은 기록」으로 가르면 손으로 지운 기록이 `Stopped` 로 보인다. 그러려면 Keeper 의 첫 턴을 `Started` 뒤로 묶어야 하고, Keeper 를 띄우는 길마다 같은 검사를 넣어야 한다 |
| 알린 head 변경이 일어났는지를 가리지 않는다. 다음 단위는 언제나 그 줄의 `after` 에서 시작한다 | head 가 적어 둔 chain 을 줄에 싣고 견주면, 일어나지 않은 변경 뒤의 「한 번 더 읽기」 하나를 아낀다. 그 값은 Agent-Core 부분만 말하고, 턴 64개가 segment 로 묶이면 없어지고, official-client 만 쓰는 Keeper 에는 없다. 필드 하나, 생성자 하나, purge 의 순서 규칙 하나가 든다. 수로 가리면 일어난 지우기를 거둔 것으로 읽고 턴을 건너뛸 수 있다 |
| 열린 메시지는 닫힌 뒤의 첫 단위에 든다. 받아들임은 닫지 않는다. 프로세스 시작 단계와 head 를 줄이는 함수만 줄 앞에서 닫는다 | 받아들임도 닫게 하면 닫는 저장이 실패한 턴의 메시지가 Task 없이 실린다. 그 대신 멈췄다가 잇는 턴과 Keeper 의 첫 턴의 메시지도 Task 없이 실린다. 둘을 가르려면 열린 메시지를 누가 남겼는지를 head 에 적어야 한다. 값: 닫는 저장이 실패한 턴의 메시지가 다음 턴의 Task 와 함께 보인다 |
| 켠 Librarian lane 은 출력 몫 R 을 적어야 로드된다 | 적지 않고 provider 기본값에 맡길 수도 있다. 그러면 들어가는 조건의 R 이 lane 값 밖에 있어서, 기본값이나 catalog 가 바뀌어도 크기 사실이 남는다. 값: 운영자가 컷 전에 수 하나를 정한다 |
| session 을 지우는 정지가 지우기 전에 줄을 쓴다 | 쓰지 않으면 다음에 줄 쓰는 쪽이 수를 보고 알아내야 한다. 마지막 끝자리가 0 이거나 head 가 같은 수까지 다시 자라면 구멍이 기록 없이 지나간다. 값: 턴 기록에 쓰지 못하면 그 정지는 session 을 지우지 못한다 |
| 읽은 자리를 모르면 처음부터 읽는다. 꼬리를 읽지 못한 반영 기록을 맡길 때도 같다 | 끝에서 이어 읽으면 값이 들지 않는다. 그 대신 안 읽은 줄이 기록 없이 지나간다 |
| 쓰는 쪽은 처음 쓰일 때 만든다. Keeper 를 띄우는 길은 쓰는 쪽을 모른다 | 띄우는 길마다 만들면 pulse 한 번을 기다리지 않는다. 길 하나가 빠지면 그 Keeper 의 쓰기가 모두 거절되고 경보가 없다 |
| 받은 본문이 masc 의 읽기 경계를 넘으면 말 없음이다 | 거절로 읽으면 폭을 줄인다. 그 경계는 slot 의 것이 아니라서 폭을 줄여도 달라지지 않는다 |
| purge 는 Librarian 의 읽은 자리를 기다리지 않는다 | 기다리게 두면, 읽기가 선 Keeper 는 context 가 차도 이력을 고쳐 쓰지 못한다 |
| `Refused_at_bottom` 을 상태로 둔다 | `Resting` 에 합치면 상태가 하나 준다. 서 있는 Keeper 마다 pulse 마다 질문을 다시 짓게 된다 |
| Codex 가 타입으로 알린 요청 거절(bad request, 정책 위반)은 HTTP 400 처럼 거절로 읽는다 | 말 없음으로 읽으면, 그 slot 만 남은 항목에서 폭이 줄지 않고 pulse 마다 프로세스 하나를 띄운다 |
| 줄을 먼저 쓰고 head 를 바꾼다 | 순서를 뒤집으면 그사이에 죽었을 때 버린 메시지에 이름이 없다. 지금 순서는 그때 이력을 한 번 더 읽는다 |
| 재시작 직후 안 읽은 것이 있는 Keeper 는 첫 묻기가 끝날 때까지 warn 이다 | 그 절을 빼면 그사이 멈춘 Keeper 가 `Ok` 로 보인다 |

## 23. 확인하지 못한 것

이 RFC 가 근거 없이 말하지 않으려고 따로 적는 목록이다. 항목마다 무엇을 모르는지, 그것이 틀리면 무엇이 달라지는지, 어느 층에서 확인하는지를 적는다.

### 23.1 재지 못한 수

| 모르는 것 | 틀리면 달라지는 것 | 확인하는 곳 |
|---|---|---|
| GLM 요금제 한도가 하루 생성 1,450~1,850번과 입력 약 1.4억~1.7억 token 을 받는지. 지금은 하루 118번이다(§15.2) | 받지 못하면 Librarian 이 quota 로 쉬는 시간이 늘고, 같은 계정을 쓰는 Keeper 턴도 같이 쉰다. lane 의 slot 구성을 바꿔야 한다 | 컷 전에 운영자가 요금제 숫자와 견준다(§18.1) |
| ollama 가 Librarian 질문에 답하는 속도. 표본이 7개다 | tinker 가 없는 lane 에서 ollama 가 GLM 만큼 느리면 자리가 평균 도착에서 묶인다(§15.2 셋째 행) | 배포 뒤 slot 별 호출 시간 metric |
| 질문 크기와 호출 시간의 관계 | 단위를 묶어 물을 때의 호출 시간을 지금 표본(단위 약 1.3~1.6개)으로 넘겨짚을 수 없다 | 배포 뒤 metric. 재생은 호출 시간을 크기와 무관하게 뽑았다 |
| 턴 기록이 하루 약 1.4 MB, 반영 기록이 하루 약 27 MB 자란다는 추정 | 줄 크기 표본과 재생에서 나온 값이다. 실제 줄은 재지 않았다. 하루 2,960줄은 생성 수(1,450~1,850)보다 많다. 차이는 직접 쓰기와 건너뛰기의 줄이라고 보지만 그 비중을 따로 재지 않았다. 가장 바쁜 Keeper 의 1.15 GB 는 턴마다 한 줄을 쓴다고 본 상한이다 | 배포 뒤 파일 크기 |
| 새 프롬프트에서 slot 별로 답이 얼마나 유효하고 얼마나 바꾸는지 | 「아무것도 바꾸지 않는다」가 다시 안전한 답이 되는지는 프롬프트를 써 봐야 안다 | 평가 틀(L1)의 채점 결과를 묻기 층 PR 에 붙인다 |
| 운영 lane 의 slot 가운데 선언이나 probe 로 정한 입력 경계(`rejected_from`)가 있는 것이 있는지 | 있으면 그 slot 은 보내기 전에 `Input_too_large` 를 낸다. 없으면 provider 의 거절을 기다린다. 설계는 둘 다 다룬다 | 컷 전에 runtime 파일에서 읽는다 |

### 23.2 읽지 못한 코드

| 모르는 것 | 틀리면 달라지는 것 | 확인하는 곳 |
|---|---|---|
| registry 에서 Keeper 를 빼는 곳 여섯(파일 다섯, `unregister_exact` 를 부르는 곳)이 그 lane 이 끝난 뒤에 빼는지 | 아니면 도는 턴 아래에서 dashboard purge 가 고쳐 쓴다. 지금 purge 도 같다 | purge 층(L8) |
| 끝이 결과를 기다리는 tool 요청인 열린 메시지를 닫은 뒤에, 다음 턴이 그 이력을 지금처럼 읽는지. 지금은 턴이 시작할 때 메모리에서 닫는 메시지를 덧붙인다(`keeper_agent_run.ml:229-230`). 닫는 저장은 메시지 목록을 바꾸지 않고 닫힘의 경계만 옮긴다 | 다르게 읽으면 프로세스 시작 단계가 닫는 저장을 하기 전에 그 꼬리를 먼저 고쳐야 한다 | 프로세스 시작 단계의 층(L3a3b4c) |
| 메시지 codec 이 옛 빌드가 쓴 object 를 같은 바이트로 되돌려 주는지 | 아니면 purge 가 건드리지 않은 메시지의 digest 가 바뀐다. 시험은 풀어낸 값이 아니라 저장된 digest 를 견준다 | purge 층(L8) |
| bundle 이 다른 object 를 가리키는지 | 가리키면 sweep 이 줄의 bundle 에서 그 object 까지 따라가야 한다 | purge 층(L8) |
| Librarian 의 프롬프트를 파일에서 읽는 경우, 그 파일이 바뀐 것을 알리는 신호가 있는지 | 없으면 손으로 고친 프롬프트는 재시작 때 보인다. 설계는 그렇게 적었다 | 묻기 층(L6) |
| Codex 가 tool 을 쓰지 않고 알린 창 넘침이 생성 전의 거절인지. Codex 에는 응답을 냈는지 알리는 칸이 없다. 지금 코드의 읽기(`refused_for_input_size`)를 따랐다 | 생성 뒤의 넘침이면 `Window_reached` 여야 한다. `Input_too_large` 로 읽으면 한 항목에서 그 slot 이 「입력이 크다」 쪽에 선다 | 폭과 바닥 층(L7). slot 마다 창을 넘는 질문을 한 번 보내 타입 있는 결과를 기록한다 |
| 운영 lane 의 slot 가운데 Agent-Core 가 보내기 전에 세는 것이 어느 것인지, 창 넘침 code 를 문서로 정한 provider 가 어느 것인지. opencode 와 tinker slot 이 어느 wire codec 을 쓰는지도 읽지 않았다. 코드에서 provider 쪽 넘침을 타입으로 만드는 codec 이 GLM 하나라는 것만 확인했다 | 크기를 타입으로 말하지 않는 slot 이 운영 lane 에 남으면 그 lane 은 한 항목 아래의 단계에 닿지 않고 E4 나 W1 에서 선다 | Agent-Core 층(L2)의 slot 별 측정 표 |
| slot 결과 표의 생성자 176개 가운데 실제로 Exact 경로에 닿는 것이 어느 것인지. 표는 타입에서 만들었고 호출 경로를 따라가지 않았다 | 닿지 않는 생성자의 행은 쓰이지 않을 뿐이다. 닿는데 갈래가 틀린 행은 폭을 잘못 줄이거나 줄이지 않는다 | 끝맺음 타입 층(L2)과 묻기 층(L6). 생성자마다 분류 시험 |
| 계정별 Claude API provider 는 catalog 행이 없어 Exact slot 이 되지 못한다는 것. 다른 작업이 찾은 사실이고 여기서 확인하지 않았다(#53022) | Librarian lane 에 그런 provider 를 선언할 수 없다 | 그 작업의 RFC |

본문이 줄 번호로 인용한 코드는 읽은 것이다. 그 가운데 그 코드가 바뀌면 설계가 깨지는 전제는 셋이다. 턴은 등록된 Keeper 에게만 돈다(`keeper_turn.ml:227-236`, §8.6). object sweep 은 프로세스가 시작할 때 쓰는 쪽이 생기기 전에 한 번 돈다(`bin/main_eio.ml:350`, §5.6). 주기 작업으로 바뀌면 깨진다. 지금은 autoboot 가 띄우지 않은 Keeper 의 것도 따라잡는다(`server_bootstrap_loops.ml:2197-2206`, §9.3).

### 23.3 모델이 다루지 않은 것

| 다루지 않은 것 | 대신 확인하는 것 |
|---|---|
| 한 항목에서의 slot 별 크기 사실, 그것을 접는 판단, E4 의 조건(§21.5) | L7 이 그 코드와 모델을 같이 넣는다. 그때까지 §9.3 의 그 행들은 모델 밖이다 |
| 한 run 에 겹친 결함 넷(§21.5) | 결함 하나씩의 설정과 층마다의 crash 시험 |
| provider 자리와 자리를 기다리는 시간. 모델에서 자리를 기다리는 묻기는 경보 행이 없는 `Asking` 이다 | 자리 걷기는 #52986 의 시험이 확인한다. 기다리는 묻기는 fleet 행에 보인다(§12.1) |
| Memory 의 내용. 모델은 크기와 fact id 만 가진다 | 평가 틀(L1) |
| 줄 codec 과 파일 쓰기 | 층마다의 crash 시험(§13) |
| 제품 밖에서 손으로 한 수정 | 적힌 한계다(§5.4) |

### 23.4 정하지 않고 남긴 것

- 파일에 묶인 저장소의 무효 행은 늘기만 하고 턴마다 recall 에 실린다. 이 RFC 는 그 저장소의 쓰기 규칙을 바꾸지 않는다. 바이트 상한을 지우면 그 파일을 묶는 것이 없어진다(#53031).
- 쓰는 쪽 fiber 가 예상하지 못한 예외로 끝났을 때. 지금은 예외가 그 fiber 를 띄운 switch 를 실패시킨다. 예외를 잡아 그 Keeper 의 쓰는 쪽만 다시 만들게 하면, 매번 같은 곳에서 죽는 쓰는 쪽을 쓰기가 끝없이 다시 만든다. 그 상태를 무엇으로 보이고 언제 다시 만들지는 경보(§12.2)와 함께 정한다. 등록부에 어느 switch 를 줄지는 전환 층이 정한다.
- 반영 기록을 줄이는 방법. 가장 바쁜 Keeper 가 한 해 1.15 GB 까지 자란다(§10). 이 RFC 는 줄이지 않는다. 줄이는 일은 「지운 claim 을 언제까지 찾을 수 있어야 하는가」를 정해야 할 수 있다.
