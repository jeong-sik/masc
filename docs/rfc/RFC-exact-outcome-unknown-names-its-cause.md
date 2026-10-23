---
rfc: "exact-outcome-unknown-names-its-cause"
title: "호스트 Exact 기록이 결과를 모르는 까닭을 남기고, Curator 는 서버가 멈춰 끊긴 호출만 다시 준비한다"
status: Draft
created: 2026-10-23
updated: 2026-10-23
author: claude
related: ["workspace-curator-curates-changed-facts"]
---

# 호스트 Exact 기록이 결과를 모르는 까닭을 남기고, Curator 는 서버가 멈춰 끊긴 호출만 다시 준비한다

## 1. 문제

2026-10-23 에 서버를 세 번 다시 띄우거나 멈췄다. 그때마다 Workspace Curator 원본 하나가 모델을 부르는 중이었다(#45401).

| 원본 | 종류 | 만든 시각(UTC) | 고른 것 | 호스트 Exact 기록 |
|---|---|---|---|---|
| `01a1672c…` | 분류 | 05:11:45 | 사실 447개 | `25f4c4b5…` |
| `01a16750…` | 분류 | 05:51:47 | 사실 248개 | `401b5d28…` |
| `01a1676d…` | Briefing | 06:22:53 | 출처 796개 | `25711699…` |

- 다음에 그 요청을 읽을 때 호스트 복구가 Exact 기록을 `outcome_unknown` 으로 끝냈다.
- Curator 는 세 원본을 `Rejected` 로 끝냈다.
  - `Rejected` 분류 원본은 자기가 고른 사실을 다음 묶음에서 뺀다. 그래서 사실 695개가 빠졌다.
  - `Rejected` Briefing 원본은 같은 상태를 준비하는 Briefing 패스를 막는다.

사실을 빼는 규칙은 같은 입력 때문에 계속 실패하는 호출을 되풀이하지 않으려고 있다. 서버를 다시 띄운 것은 입력 탓이 아니다. 그런데 `outcome_unknown` 은 세 경우에 생기고, Curator 는 셋을 구분하지 못한다.

1. **서버 프로세스가 멈췄다.** 재시작, 종료, kill 이다. 입력과 상관없다.
2. **이 프로세스 안에서 호출을 끊었다.** worker 가 죽거나 detach 되어 runtime 이 호출을 취소했거나, 호출 뒤 proof 나 결과를 저장하지 못했다. worker 가 이 묶음 때문에 죽었을 수 있다(#45456 의 OOM).
3. **호출이 이 프로세스 안에서 예외를 냈다.** 호스트 코드의 결함이다. 같은 입력에서 다시 날 수 있다.

어느 한쪽으로 정하면 틀린다.

- 모두 막으면 서버를 다시 띄울 때마다 그때 돌던 묶음이 막힌다. 오늘 세 번 그랬다.
- 모두 풀면 2·3 이 같은 입력으로 되풀이될 때 패스마다 새 원본을 만들고 다시 호출한다. 멈추는 장치가 없다.

### 1.1 세 경우가 남기는 기록 (main `6435a8858e6`)

| 경우 | 기록에 남는 것 | 결과(final) |
|---|---|---|
| 서버가 멈출 때 호출이 끝나지 않았고 proof 도 없음 | 시작 표시 `null` 이 남는다(`lib/lane_addon/lane_addon_exact.ml:722`, 취소 전파 `:729`). 다음 프로세스가 읽을 때 복구가 결과를 쓴다(`:659-666`) | `outcome_unknown`, 마지막 시도 `null` |
| 프로세스 안에서 끊김 | 취소는 Exact 를 지나 위로 올라간다(`:729`). 저장 실패는 `Error` 로 끝난다(`:734-746`). 어느 쪽이든 시작 표시만 남고, 같은 프로세스가 다시 읽을 때 복구가 결과를 쓴다 | `outcome_unknown`, 마지막 시도 `null` |
| 예외 | 그 자리에서 쓴다(`:726-733`, `:740-742`) | `outcome_unknown`, 마지막 시도 `{"status":"outcome_unknown","exception":"<문구>"}` |

앞의 두 경우는 같은 기록을 남긴다. 그래서 지금은 구분할 방법이 없다.

- 서버는 `Sys.set_signal` 로 SIGTERM·SIGINT 처리기를 설치한다(`bin/main_eio.ml:773-780`). 처리기는 종료 중임을 표시하고, watcher 는 알림·shutdown hooks 뒤 Eio 로 서버와 배경 fiber 를 취소한다(`:829-928`). takeover 도 이전 서버에 SIGTERM 을 보낸다(`lib/server/server_startup_takeover.ml:765`). 종료 절차 중 호출이 끝나 proof 를 쓰면 그 결과를 복구한다. Eio 취소는 Exact 를 지나 전파되므로(`lane_addon_exact.ml:729`), proof 없이 시작 표시가 남을 수도 있다. SIGKILL 이나 프로세스의 급작스러운 종료도 같은 표시를 남길 수 있다. 재시작이라고 반드시 시작 표시만 남는 것은 아니다.
- 프로세스 안에서 호출을 끊는 곳은 여럿이다.
  - runtime 은 Exact 호출을 `Eio.Cancel.sub` 로 감싸고, 자기가 건 취소만 삼킨다(`lib/lane_addon/lane_addon_runtime.ml:1062-1085`).
  - `retire_admission`(`:194-196`)이 호출을 `Worker_detached` 로 취소한다. 부르는 곳은 여섯이다. 요청 감시 실패(`:1252`), 상태 저장 실패(`:1282`), worker 프로세스 종료(`:1314`), browser 호출 취소(`:1948`), Keeper 의 export 도구 호출 취소(`:2173`), detach(`:3007`).
  - worker 가 요청을 목록에서 뺐으면 `Host_request_withdrawn` 으로 취소한다(`:1246`).

### 1.2 결과를 받는 쪽이 보는 것

- worker 가 받는 결과는 `{"status":"outcome_unknown"}` 하나다(`lane_addon_exact.ml:182`). Curator, Candle, Librarian worker 가 같은 `addons/exact_worker.py` 로 이 값을 저장하고 돌려준다(`final_of_json`, `:128-151`).
- 공용 consumer 흐름 `Lane_addon_submit_once` 를 Curator 와 Librarian 이 쓴다.
  - 호스트 기록이 끝났으면 `observe_retained` 의 결과를 쓴다(`lib/lane_addon/lane_addon_submit_once.ml:186-190`).
  - 아니면 worker 의 `read` 답을 쓴다(`:52-54`).
  - 어느 쪽이든 거절을 `Progress.Refused {stage=Execution; evidence=final_to_json result}` 로 남긴다(`:102-110`).
- `observe_retained` 도 결과만 돌려준다(`Retained_terminal of final`, `lane_addon_exact.mli:220`).

## 2. 지금 있는 것

- 호스트 Exact 기록은 `{declaration_id, request_id, digest, request, attempts, final}` 이다(`lane_addon_exact.ml:282-297`). 시도 하나는 결과 객체, not_final 객체, 시작 표시 `null` 중 하나다.
- 기록 검사 `validate_record`(`:346-370`)는 `exception` 이 `outcome_unknown` 시도에만 붙게 한다. 배포 전 저장소 검사 `validate-stores` 가 같은 검사를 `check_retained_record`(`:374`)로 쓴다(`lib/lane_addon/lane_addon_store_preflight.ml:276`).
- `in_flight`(`:593-603`)는 이 프로세스가 지금 돌리는 요청이다. `run` 은 요청을 claim 한 뒤에만 복구한다(`:624`). base-path lease 를 가진 서버 하나만 `run` 을 부른다.
- 거절 증거를 `final_of_json` 으로 다시 읽는 곳은 일곱이다.
  - 공용 흐름: `lane_addon_submit_once.ml:164`
  - Curator: `server_workspace_memory_curator.ml:29`, `server_workspace_memory_addon.ml:323`, `workspace_memory_execution_capture.ml:310`, `workspace_memory_observation_receipt.ml:89`
  - Librarian: `keeper_librarian_admission_commit.ml:113`, `keeper_librarian_durable_commit.ml:237`
- Curator 가 막는 곳
  - 사실: `classification_blocked`(`server_workspace_memory_curator.ml:116-122`)
  - Briefing 패스: `briefing_blocked`(`:160-169`)
  - 둘 다 `Rejected` 원본이면 거절 내용과 상관없이 막는다.
- 끝난 사슬 옮기기 `settled_chains`(`workspace_memory_execution_capture.ml:402-441`)는 잎이 답을 받은 사슬(`Finished`, `Conflicted`)만 옮긴다. `Rejected` 잎은 막는 역할이라 남긴다.

## 3. 결정

### 3.1 worker 가 받는 결과는 그대로 둔다

- `final` 타입과 JSON 은 바꾸지 않는다. `outcome_unknown` 은 지금처럼 `{"status":"outcome_unknown"}` 이다.
- Python worker, 패키지 revision, worker 상태 볼륨도 그대로다.
- 원인은 호스트 Exact 기록과 그 기록을 읽는 호스트 코드에만 있다. 원인에 따라 다르게 움직이는 쪽은 Curator 하나다.

### 3.2 시작 표시가 그 시도를 시작한 프로세스를 적는다

- 서버 프로세스는 처음 Exact 호출을 시작하기 전에 incarnation 을 하나 만든다. 128비트 무작위 값이고 메모리에만 둔다.
- 시작 표시는 `null` 대신 `{"started":"<incarnation>"}` 이다.
- 복구는 마지막 시도가 시작 표시이고 그 시도의 proof 가 없을 때 원인을 정한다.
  - 표시의 incarnation 이 이 프로세스와 다르면 `interrupted` 다. 시작한 프로세스가 끝나기 전에 멈췄다.
  - 같으면 `cut` 이다. 이 프로세스가 시작했는데 지금 돌리지 않는다(claim 했으므로). 취소됐거나 호출 뒤 저장이 실패했다.
- proof 가 있으면 지금처럼 proof 로 끝낸다(`:667-671`). 원인이 필요 없다.
- graceful shutdown 중에도 같은 규칙을 쓴다. 종료 중임을 보고 원인을 덮어쓰지 않는다. 같은 incarnation 이 취소된 호출을 복구하면 `cut` 이고, 복구하지 못한 시작 표시를 다음 프로세스가 읽으면 `interrupted` 다. shutdown 알림·hooks 중 끝난 호출의 proof 는 어느 경우든 우선한다.
- 복구는 시작 표시를 원인을 적은 시도로 바꾸고 결과를 쓴다.
  - `{"status":"outcome_unknown","cause":"interrupted"}`
  - `{"status":"outcome_unknown","cause":"cut"}`
- 예외는 그 자리에서 `{"status":"outcome_unknown","cause":"raised","exception":"<문구>"}` 를 쓴다.

이 방식은 프로세스 안에서 호출을 끊는 길을 하나하나 알 필요가 없다. 나중에 새로 생긴 길도 같은 프로세스 안이면 `cut` 이 된다.

틈이 하나 있다. 프로세스 안에서 끊긴 요청을 같은 프로세스가 다시 읽기 전에 서버가 멈추면, 다음 프로세스는 `interrupted` 로 읽는다. 그 입력은 한 번 더 시도된다. 다음 시도가 같은 프로세스 안에서 끊기면 `cut` 으로 막힌다. 그래서 이 틈으로 늘어나는 시도는 그런 재시작 한 번에 한 번이다.

### 3.3 기록 규칙

- 시도 하나는 다음 중 하나다.
  - not_final 객체(지금과 같다)
  - `outcome_unknown` 이 아닌 결과 객체(지금과 같다)
  - 원인을 적은 `outcome_unknown` 객체
  - 시작 표시
- 시작 표시는 결과가 없는 기록의 마지막 시도로만 온다.
- 결과가 `outcome_unknown` 이면, 결과를 정한 시도가 원인을 적은 `outcome_unknown` 시도다. 결과를 정한 시도는 결과가 정해진 뒤 선택 변경으로 붙은 `not_allowed` 시도(`:676-681`)를 뺀 마지막 시도다.
- `exception` 은 `cause` 가 `raised` 일 때만 있고, 비어 있지 않다.
- 기록 검사는 다음을 거절한다.
  - `null` 시도
  - `cause` 가 없거나 세 값이 아닌 `outcome_unknown` 시도
  - `raised` 가 아닌데 `exception` 이 있거나, `raised` 인데 없는 시도
  - 마지막이 아니거나 결과가 있는 기록의 시작 표시
- `check_retained_record` 가 같은 규칙을 쓰므로, `validate-stores` 가 옛 모양 기록을 파일마다 알려 준다.

### 3.4 호스트는 원인을 타입으로 돌려준다

```ocaml
(** Why a call that may have been sent has no retained outcome. Only the
    host record and host code see it; a worker receives [Outcome_unknown]. *)
type unknown_cause =
  | Interrupted
      (** The process that started the attempt stopped before it ended. *)
  | Cut
      (** This process started the attempt and stopped waiting for it: the
          call was cancelled, or its proof or outcome could not be saved. *)
  | Raised
      (** The call raised in this process. The text stays in the attempt. *)

(** How the host retains the end of a request. *)
type retained_final =
  | Retained_call of call_final
  | Retained_unknown of unknown_cause
  | Retained_not_allowed of { reason : string }
  | Retained_request_id_reused

val delivered : retained_final -> final
(** What the worker receives. *)

type retained_observation =
  | Retained_absent
  | Retained_open
  | Retained_terminal of retained_final
```

- 원인 없는 `outcome_unknown` 은 이 타입으로 만들 수 없다.
- `retained_final_to_json` 과 `retained_final_of_json ~schema` 를 Exact 에 둔다. `Retained_unknown` 은 `{"status":"outcome_unknown","cause":"<원인>"}` 이고, 나머지는 `final_to_json` 과 같은 바이트다.

### 3.5 결과를 받는 쪽은 원인을 호스트 기록에서 받는다

- 공용 흐름은 거절 증거를 `retained_final_to_json` 으로 남긴다.
- 호스트 기록이 끝났으면 그 값을 쓴다(지금 `:186-190` 처럼).
- worker 가 `finished` 와 `outcome_unknown` 을 답하면(`:52-54`), worker 의 사본을 증거로 쓰지 않는다. `observe_retained` 로 호스트 기록을 다시 읽어 `Retained_unknown cause` 를 쓴다.
  - worker 는 `outcome_unknown` 을 스스로 만들지 않는다. 호스트는 기록에 결과를 쓴 뒤에 worker 에 넘긴다(`lane_addon_exact.ml:665-666`, `:745`, `lane_addon_runtime.ml:1089-1091`). 그래서 이때 호스트 기록은 끝나 있다.
  - 호스트 기록이 끝나 있지 않거나 원인 없는 값이면 모순으로 거절한다.
- 거절 증거를 읽는 일곱 곳(2장)은 `retained_final_of_json` 으로 읽는다. worker 결과가 필요한 곳은 `delivered` 로 바꾼다.
- 원인 없는 옛 증거는 읽지 않는다(3.8).

### 3.6 Curator 는 `interrupted` 만 막지 않는다

- `classification_blocked` 와 `briefing_blocked` 는 `Rejected` 원본 중 증거가 `Retained_unknown Interrupted` 인 것을 막지 않는다. 다른 `Rejected` 원본은 지금처럼 막는다.
  - 증거는 닫힌 variant 로 읽고 생성자를 모두 적는다.
  - 새로 저장하는 값은 없다. 패스가 원본 기록을 읽을 때마다 증거에서 정한다.
- `cut` 과 `raised` 는 막는다.
  - `cut` 은 worker 가 이 묶음 때문에 죽은 경우일 수 있다(#45456).
  - `raised` 는 호스트 결함이라 같은 입력에서 다시 날 수 있다.
- 크기 거절 판정(`size_refusal`, `server_workspace_memory_curator.ml:27-38`)에서 세 원인 모두 크기 거절이 아니다. 지금과 같다.
- `interrupted` 로 끝난 잎의 사슬은 아무것도 막지 않으므로, 답을 받은 잎의 사슬처럼 옮긴다(`settled_chains`).
  - 관찰 영수증이 모두 확인된 뒤에만 옮기는 조건은 같다.
  - 다음 묶음 크기의 근거(마지막으로 답을 받은 분류)는 아니다.
  - Briefing 사슬은 준비한 상태와 상관없이 옮긴다.
- `interrupted` 가 같은 입력으로 되풀이되려면, 그 호출마다 서버 프로세스가 멈춰야 한다.

### 3.7 다른 소비자는 동작을 바꾸지 않는다

- Librarian
  - `observe_retained` 를 쓰는 두 곳(`keeper_librarian_durable_request.ml:314-320`, `keeper_librarian_admission_capture.ml:369-375`)은 `delivered` 로 worker 결과와 비교한다.
  - `outcome_unknown` 을 기다림으로 다루는 동작(`keeper_librarian_durable_owner.ml:171`)은 원인과 상관없이 그대로다.
  - 공용 흐름의 증거 모양이 바뀌므로 Librarian 원본 기록도 3.8 의 조건부 하드컷 대상이다. 2026-10-23 라이브 스냅샷에는 Librarian 설치가 없었다. 배포 때는 설치 유무와 별도로 남아 있는 원본 기록도 확인한다.
- Candle Appraiser 는 자기 흐름을 쓰고 worker 결과만 본다(`server_candle_appraiser.ml:57`, `:179`). 바뀌지 않는다.
- browser 모델 요청(`browser_addon_models.ml:122-127`, `browser_addon_locate.ml:50`)은 `run` 이 돌려주는 worker 결과만 본다. 바뀌지 않는다.
- operator-quiz 는 worker 결과의 `status` 만 본다. 바뀌지 않는다.

### 3.8 하드컷

바뀌는 저장 모양은 둘이다. 호스트 Exact 기록의 시도(시작 표시, `outcome_unknown` 시도의 `cause`)와, 공용 흐름이 남기는 거절 증거(`outcome_unknown` 의 `cause`)다. 옛 모양을 읽는 코드는 만들지 않는다. 배포할 때 서버를 멈추고 다음을 옮긴다.

1. 옛 모양 호스트 Exact 기록(`lane-addons/exact-requests/<선언 digest>/`). 새 빌드의 `validate-stores` 가 파일마다 알려 준다.
   - 결과가 `outcome_unknown` 인 기록과, 결과 없이 `null` 시작 표시로 끝나는 기록이다.
2. 1번 기록을 가리키는 Curator 사슬. 진행 기록(`lane-addons/tool-request-owners/5e5665b7…/`)과 본문(`lane-addons/tool-request-bodies/5e5665b7…/`)을 사슬째 옮긴다.
   - 옮기면 그 사슬이 막던 사실과 Briefing 패스가 다음 패스에 다시 준비된다.
3. Librarian 기록이 있는 배포에서는 admission·history 원본도 확인한다. 1번 Exact 기록을 가리키거나 원인 없는 `outcome_unknown` 거절 증거가 있는 원본을 찾고, 그 원본의 물리 소유자별로 아래 scope 묶음을 옮긴다. 현재 설치가 없어도 저장된 기록은 대상이다.
   - admission 의 물리 소유자는 원본의 `owner` 이다. workspace·keepers 의 경로/device/inode, Keeper ID, queue generation 으로 `Keeper_librarian_admission_capture.scope_identity` 와 `scope_hash` 가 정하는 값을 `A` 라 한다(`keeper_librarian_admission_capture.ml:45-51`). 영향받은 admission 소유자에 대해 다음 네 scope 전체를 함께 옮긴다.
     - `keeper-librarian-parts/<A>`
     - `keeper-librarian-partitions/<A>`
     - `keeper-librarian-execution-<A>`
     - `keeper-librarian-admission-gate/<A>`
   - parts 와 partitions 는 부모·자식·supersession frontier 를 서로 가리키고, execution 은 `parent_part_id` 를, gate 는 `execution_id` 와 이전 gate 를 가리킨다(`keeper_librarian_admission_parts.ml:129-180`, `:473-536`, `keeper_librarian_admission_owner.ml:80-103`). 실패한 execution 하나만 빼면 남은 원본을 복구할 수 없으므로, 이 하드컷은 해당 소유자의 admission 원본 묶음을 다시 준비하는 범위다.
   - history 는 원본의 workspace·keepers·runtime 의 경로/device/inode 와 Keeper ID 로 `Keeper_librarian_durable_request.scope` 가 정하는 전체 문자열을 `H` 라 한다(`keeper_librarian_durable_request.ml:53-61`). 영향받은 history 소유자에 대해 다음 두 scope 전체를 함께 옮긴다.
     - `H` (`keeper-librarian-history-execution-<owner hash>`)
     - `keeper-librarian-durable-gate/<SHA256(H)>`
   - history execution 의 predecessor·replacement intent 와 gate 의 execution·predecessor 참조를 남기지 않도록 묶음째 옮긴다(`keeper_librarian_durable_execution.ml:175-214`, `keeper_librarian_durable_gate.ml:6-8`, `keeper_librarian_original_gate.ml:52-79`, `:257-307`).
   - scope 마다 `lane-addons/tool-request-owners/<digest(scope)>/` 와 `lane-addons/tool-request-bodies/<digest(scope)>/` 를 함께 옮긴다. 경로는 위 문자열과 `Lane_addon_store.digest` 로 계산하고, 실제 원본의 `scope` 와 대조한다. Keeper 이름만으로 hash 나 경로를 추측하지 않는다. 본문에는 아직 게시하지 않은 successor·replacement intent 가 가리키는 값도 있으므로, 게시된 JSON 파일만 골라 옮기지 않는다.
   - 원본 queue·current memory·이미 커밋한 candidate receipt, history source 와 소비 확인 위치는 옮기지 않는다. 다음 패스가 이 정본에서 미처리 입력을 다시 준비한다. 기존 원본의 cause 를 추측해 채우거나 다른 모양으로 고치는 코드는 만들지 않는다.
   - 공용 `validate-stores` 의 owner 검사는 원본과 본문의 envelope 를 검사하며, Librarian 거절 증거의 의미까지 검사하지 않는다(`lane_addon_tool_request_owner.ml:150-154`). 따라서 이 조건부 목록은 별도로 읽어 배포 영수증에 남긴다. 재시작 전에는 남겨 둔 admission/history 원본의 복구 검사도 성공해야 한다.

2026-10-23 08:30Z 에 라이브를 읽기만 해서 셌다. 1번은 셋(`25f4c4b5…`, `401b5d28…`, `25711699…`)이고, 결과 없이 `null` 로 끝나는 기록은 없었다. 2번은 1장 표의 원본 셋이다. 이 스냅샷에는 Librarian 설치가 없었지만, 그것을 3번 원본 기록이 0건이라는 실측으로 대신하지 않는다. 배포 직전에 1·2·3번을 다시 세고, Librarian 대상이 없으면 그 조회 범위와 0건을 영수증에 적는다.

worker 상태 볼륨, 실행 기록 payload, 관찰 영수증은 그대로 둔다. 셋 다 worker 가 받는 결과 모양만 담는다.

## 4. 다른 방법과 비교

| 방법 | 좋은 점 | 나쁜 점 |
|---|---|---|
| 모두 막는다 (지금) | 반복이 없다 | 재시작할 때마다 그때 돌던 묶음이 막힌다. 오늘 세 번 |
| 모두 푼다 | 고칠 곳이 적다 | 프로세스 안 끊김이나 예외가 같은 입력으로 되풀이되면 패스마다 다시 호출한다. 멈추는 장치가 없다 |
| worker 가 받는 결과 타입에 원인을 싣는다 | 결과를 받는 모든 곳이 원인을 안다 | Python worker 셋, 패키지 revision, worker 상태 볼륨까지 바꾼다. 원인을 쓰는 곳은 Curator 하나다 |
| 프로세스 안에서 끊는 길마다 원인을 쓴다 | 시작 표시 모양이 그대로다 | 길을 하나 놓치면 그 끊김이 `interrupted` 로 읽혀 풀린다. 놓친 길이 같은 입력에서 매번 생기면 멈추는 장치가 없다. 지금 길은 일곱 곳이 넘는다 |
| Curator 가 패스마다 호스트 기록을 읽는다 | 저장 모양이 그대로다 | 호스트 기록은 요청을 품어서 라이브에서 1~4MB 다. 끊긴 원본마다 패스마다 읽는다. 원인을 가리는 코드가 Exact 밖에 생긴다 |
| 이 RFC: 시작 표시에 프로세스를 적고 복구가 원인을 정한다 | 끊는 길을 몰라도 된다. worker 와 결과 JSON 이 그대로다 | 끊긴 뒤 다시 읽기 전에 서버가 멈추면 한 번 더 시도한다. 호스트 기록과 공용 증거 모양이 바뀌어 하드컷이 있다 |

## 5. 나눠 올리는 순서

스택으로 올린다. 층마다 draft PR 이다.

1. Exact: incarnation, 시작 표시, 복구의 원인 판정, 기록 규칙, `retained_final`, `observe_retained`, codec. worker 가 받는 결과는 그대로다. 소비자는 컴파일만 맞추고 동작은 그대로 둔다.
2. 공용 흐름과 Curator: 거절 증거에 원인을 남기고, `interrupted` 원본은 막지 않고 옮긴다.
3. 설계 문서(`docs/design/workspace-curator-addon-execution.md`)와 배포 안내. changelog 조각에 하드컷 단계를 적는다.

## 6. 정할 것

- **Q1. 원인 이름.** `interrupted`, `cut`, `raised`.
  - 권고: 이대로 쓴다. `interrupted` 는 프로세스가 멈춘 경우만, `cut` 은 이 프로세스가 기다리기를 그만둔 경우만 뜻한다.
- **Q2. `cut` 을 풀지.** detach 나 Keeper 도구 호출 취소처럼 입력과 상관없는 `cut` 도 있다.
  - 권고: 막는다. worker 가 묶음 때문에 죽은 경우와 구분할 수 없다. 원인을 고친 운영자가 그 사슬을 옮기면 풀린다.
- **Q3. `raised` 로 막힌 사실.** 결함을 고친 뒤에도 사실은 막힌 채 남는다.
  - 권고: 지금처럼 남긴다. 결함을 고친 운영자가 그 사슬을 옮기면 풀린다.

## 7. 검증

모델 없이 테스트한다.

- Exact
  - 다른 incarnation 이 남긴 시작 표시를 복구하면 `interrupted` 가 되고, 시작 표시가 원인 시도로 바뀐다.
  - 같은 프로세스에서 취소된 호출을 다시 읽으면 `cut` 이다.
  - SIGTERM graceful shutdown 의 취소 경로를 확인한다. 종료 중 같은 incarnation 에서 proof 없는 시작 표시를 복구하면 `cut`, 그 표시를 미복구 상태로 남겨 다음 프로세스가 복구하면 `interrupted` 다. 종료 알림·hooks 중 proof 가 남았으면 원인 판정 대신 그 결과로 끝낸다.
  - 호출 뒤 proof 저장이 실패한 시도를 같은 프로세스가 다시 읽으면 `cut` 이다. proof 가 있으면 지금처럼 proof 로 끝낸다.
  - 예외는 `raised` 와 문구를 남긴다. worker 가 받는 결과는 지금과 같은 바이트다.
  - 기록 검사는 3.3 의 거절 목록을 모두 거절한다.
  - `observe_retained` 는 세 원인을 `Retained_unknown` 으로 돌려주고, 시작 표시로 끝나는 기록은 `Retained_open` 으로 돌려준다.
  - `validate-stores` 가 옛 모양 기록을 파일마다 알려 준다.
- 공용 흐름
  - worker 가 `finished` 와 `outcome_unknown` 을 답하면, 호스트 기록의 원인을 증거에 남긴다.
  - 그때 호스트 기록이 끝나 있지 않으면 거절한다.
- Curator
  - `interrupted` 로 끝난 분류 원본의 사실을 다음 뿌리가 다시 고른다. 그 사슬은 관찰 영수증이 확인된 뒤 옮긴다.
  - `interrupted` 로 끝난 Briefing 은 같은 상태의 패스를 막지 않는다.
  - `cut` 이나 `raised` 로 끝난 원본의 사실은 다시 고르지 않는다.
- 하드컷
  - Librarian admission 의 부모·partition·execution·gate 와 history 의 predecessor·replacement·gate 가 있는 저장소에서, 3.8 의 조건부 묶음을 옮긴 뒤 남은 원본을 복구할 수 있다. queue·커밋 receipt·history 소비 확인 위치는 보존되고, 미처리 입력만 다시 준비된다.
- 규칙을 하나씩 깨뜨린 mutant 가 위 테스트에서 실패한다.
  - `interrupted` 도 막기
  - `cut` 도 풀기
  - 같은 incarnation 을 `interrupted` 로 읽기
  - Briefing 만 규칙 무시
  - worker 사본의 원인 없는 결과를 증거로 받기

배포 뒤 라이브에서 본다.

- 세 사슬을 옮기면 분류 사실 695개가 그 거절 때문에 제외되지 않는다. 다음 분류는 남은 pending 사실 중 오래된 순으로 고르며, 한 묶음은 현재 프레임과 최근 응답의 배치 크기를 따른다. 배포 직전의 695개 ID 목록을 기준으로 여러 패스에 걸친 재선택·처리 수와 아직 pending 인 수를 잰다. 첫 패스에 695개 전부가 들어간다고 가정하지 않는다. Briefing 패스도 같은 거절 때문에 막히지 않고 다시 준비된다.
- 원인별 `outcome_unknown` 수.

## 8. 다루지 않는 것

- worker 가 받는 결과 모양과 Python worker.
- Candle, operator-quiz, browser 의 동작.
- `cut` 이나 `raised` 를 낸 결함 자체. 생기면 따로 고친다.
- worker 가 끝난 요청 본문을 지우지 않는 일(#45495).
