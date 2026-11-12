---
rfc: "schedule-notes-live-outside-the-ledger"
title: "예약 notes 를 장부 밖 파일에 붙여 쓴다"
status: Draft
created: 2026-11-12
updated: 2026-11-12
author: claude
supersedes: []
superseded_by: null
related: ["main-domain-scheduler-latency"]
implementation_prs: []
---

# RFC: 예약 notes 를 장부 밖 파일에 붙여 쓴다 (schedule-notes-live-outside-the-ledger)

## 0. 요약

예약 장부(`schedules.json`)는 예약 하나가 바뀔 때마다 통째로 다시 쓰는 문서다.
그 문서의 65%가 notes 다. notes 는 붙이기만 하고 지우지 않는 기록이다.

이 RFC 는 notes 를 장부에서 빼서 예약마다 한 파일에 한 줄씩 붙여 쓴다.
장부에는 지금 상태(예약과 wake)만 남는다. note 를 붙여도 장부는 다시 쓰지 않는다.

옛 장부의 notes 는 새 파일로 옮기지 않는다(§5). 사용자가 정할 것은 §9 에 있다.

## 1. 배경 (측정)

운영 서버, build `e9f0b5561f10`, 2026-11-12 10:34~10:41. 행 수와 바이트만 셌다.

### 1.1 장부의 크기

| 구간 | 행 | 바이트 | 몫 |
|---|---|---|---|
| schedules | 1,512 (살아 있는 것 45) | 2.5 MB | 20% |
| wakes | 1,803 | 1.9 MB | 15% |
| notes | 9,061 | 8.0 MB | 65% |
| 합 | | 12.4 MB | |

- notes 4,767행(5.7 MB)은 살아 있는 예약의 것이다. 예약 하나에 2,397행, 다른 하나에 1,804행이 있다.
- notes 4,197행(2.2 MB)은 장부에 더는 없는 예약의 것이다.
- notes 는 전부 `automated_actor` 가 썼다. 나이는 중앙값 13일, 최대 58일이다.

장부는 2026-09-06 에 1.9 MB, 2026-09-16 에 4.3 MB 였다(`safe_ops.ml`, `schedule_store.ml` 주석).

### 1.2 쓰기 한 번의 비용

45초 추적(runtime events, load 66~82)에서 장부를 3번 썼다.

- 인코딩을 기다린 시간이 3번에 3.15초다. 12.4 MB 를 compact 로 인코딩한다.
- 쓰기마다 12.4 MB 를 파일 두 개(primary, `.last-good`)에 쓴다.
- 쓴 뒤 다시 해석하는 실행이 pool 도메인에서 10개·18.7초였다. 이 몫은 PR #51474 가 없앤다.

### 1.3 notes 를 읽고 쓰는 곳

- 쓰기: `Schedule_store.append_note` 한 곳. 예약 도구의 note 추가가 부른다(`tool_schedule.ml`).
- 읽기: `Schedule_store.notes_for_schedule` 한 곳. 예약 도구의 notes 목록이 부른다. 예약 하나의 notes 를 전부 읽어 쪽을 나눈다.
- `ledger_times` 가 notes 의 `created_at` 을 읽는다. 끝난 예약은 마지막 note 뒤 보존 기간이 지나야 잊힌다.

## 2. 문제

쓰기 한 번의 비용이 지금 상태(예약 45개)가 아니라 쌓인 기록 전체에 비례한다.
note 하나를 붙여도, 예약 하나가 due 가 되어도 12.4 MB 를 다시 쓴다. notes 는 계속 늘어난다.

wakes 는 2026-08-29 에 같은 문제로 예약마다 32개까지만 남기게 했다(`terminal_wakes_retained_per_schedule`).
notes 는 지우지 않기로 한 기록이라 같은 방법을 쓸 수 없다(`forget_finished_schedules` 의 "Notes stay").

## 3. 지금 코드가 하는 일

- `state` 는 `{ version; updated_at; schedules; wakes; notes }` 다. 다섯 필드가 한 JSON 문서다.
- `append_note` 는 장부 lock 을 잡고, 장부를 읽고, `notes @ [ note ]` 로 새 상태를 만들고, 장부를 통째로 쓴다.
- `note_id` 는 `string_of_int (state.version + 1)` 이다. 장부 버전에서 나온다.
- `append_note` 는 그 예약의 note 수를 같이 돌려준다.
- `forget_finished_schedules` 는 예약과 그 wakes 를 지우고 notes 는 남긴다.

## 4. 설계

### 4.1 저장 위치와 행

- 예약마다 파일 하나: `<masc_dir>/schedule-notes/<sha256(schedule_id) hex>.jsonl`.
- 한 줄이 note 하나다. 줄의 모양은 지금의 `schedule_note_to_yojson` 그대로다(`schedule_id` 포함).
- 파일 이름에 `schedule_id` 를 그대로 쓰지 않는다. `schedule_id` 는 비어 있지 않다는 것만 검사하는 문자열이다. 운영 장부에 `sched-<hex>` 가 아닌 이름이 있다.
- 붙이기는 `Fs_compat.append_private_jsonl_durable_locked_result` 로 한다. 새 저장 함수를 만들지 않는다. 이 함수는 아래를 이미 한다(`fs_compat_private_file_update.ml`, `fs_compat_durable_append.ml`).
  - 그 파일에 프로세스 간 배타 lock 을 잡는다. 같은 프로세스 안에서는 경로마다 mutex 를 잡는다.
  - 파일이 개행으로 끝나지 않으면 마지막 개행 뒤의 조각을 잘라내고 fsync 한다. 잘라낸 바이트 수를 WARN 으로 남긴다.
  - 한 줄을 쓰고 fsync 한다. 쓰기가 실패하면 파일을 원래 길이로 되돌린다. 되돌리기가 실패하면 그것도 오류에 담는다.
- 읽기는 `Fs_compat.read_private_jsonl_rows_locked_result` 로 한다. 쓰는 쪽과 같은 규칙으로 줄을 나눈다. 공유 lock 을 잡으므로 붙이는 도중의 바이트를 읽지 않는다.
- 이 저장 방식은 FileSystem backend 에서만 쓴다(§4.8).

### 4.2 `note_id`

- 그 예약 파일에서 몇 번째 줄인지(1부터)를 십진수 문자열로 쓴다.
- `before_note_id` 는 한 예약 안에서만 쓰인다("does not belong to this schedule"). 예약 안에서만 유일하면 된다.
- 지금은 장부 전체에서 유일하다. 그 성질에 기대는 코드는 없다(§1.3 의 두 호출처뿐이다).

### 4.3 쓰기

`append_note` 는 아래 순서로 한다.

1. 장부를 읽어 그 예약이 있는지 본다. 없으면 `Schedule_not_found` 다. 장부 lock 은 잡지 않는다.
2. 그 예약의 notes 파일 경로로 `Workspace_utils.with_file_lock` 을 잡는다. 장부 lock 과 같은 함수다. FileSystem backend 에서는 프로세스 사이에서도 한 번에 하나만 들어온다.
3. 파일의 완성된 줄 수를 센다(§4.7). 새 note 의 `note_id` 는 줄 수 + 1 이다.
4. 한 줄을 붙인다. 미완성 꼬리가 있으면 붙이기 함수가 먼저 잘라낸다.
5. note 와 줄 수 + 1 을 돌려준다.

세기와 붙이기는 `Fs_compat` 호출 둘이다. 2번의 lock 이 그 사이에 다른 붙이기가 끼어드는 것을 막는다.

장부는 다시 쓰지 않는다. 장부 `version` 도 안 오른다.

1번과 4번 사이에 그 예약이 지워질 수 있다. 그러면 장부에 없는 예약의 note 가 한 줄 생긴다.
지금도 notes 는 예약이 지워진 뒤에 남는다. 새로 생기는 상태가 아니다.

`.last-good` 로 장부를 되살릴 때도 같다. 되살린 장부는 마지막 쓰기보다 옛 상태일 수 있다(mirror 쓰기가 실패했던 경우).
장부는 notes 를 가리키지 않고 notes 파일도 장부를 가리키지 않는다. 어긋나는 모양은 하나뿐이다.
되살린 장부에 없는 예약의 notes 파일이 남는다. 위와 같은 상태다. 되살린 장부에 다시 나타난 예약은 자기 notes 파일을 그대로 읽는다.

### 4.4 읽기

`notes_for_schedule` 은 그 예약의 파일 하나를 읽어 완성된 줄마다 decode 한다. 장부를 읽지 않는다.
파일이 없으면 빈 목록이다. 개행으로 끝난 줄이 decode 되지 않으면 `Error` 다. 줄을 건너뛰지 않는다.
개행으로 끝나지 않은 꼬리는 줄이 아니다. 세지 않고 돌려주지 않는다(§4.7).

notes 목록 도구의 쪽 나누기(`make_notes_page`)는 그대로다.

### 4.5 끝난 예약을 잊는 규칙

`last_written_if_finished` 는 마지막 wake 가 끝난 시각과 마지막 note 시각 중 늦은 쪽을 쓴다.
note 시각을 장부에 다시 적지 않는다. 적으면 note 를 붙일 때마다 장부를 써야 한다.

잊는 pass 는 wake 시각만으로 보존 기간이 지난 예약을 먼저 고른다.
고른 예약에 대해서만 notes 파일의 마지막 완성된 줄을 읽어 `created_at` 을 본다.
wake 시각으로는 지났는데 최근 note 때문에 남는 예약은, 남아 있는 동안 pass 마다 마지막 줄을 다시 읽는다.
운영 장부에서 끝난 예약에 달린 notes 는 97행이다.

`oldest_finished_last_written` 지름길은 wake 시각만으로 계산한다. 이 값이 보존 기간 안이면 pass 는 파일을 읽지 않는다.

### 4.6 장부에서 빠지는 것

- `state.notes` 필드, `state_to_yojson`·`state_of_yojson` 의 `notes`, `bump_state` 의 `~notes` 인자.
- `prepared_state.notes_by_schedule_id` 와 `build_notes_by_schedule_id`.
- `state_of_yojson` 의 "ledgers written before task-381 carry no [notes] list" 갈래.

### 4.7 미완성 꼬리

붙이는 도중 프로세스가 죽으면 마지막 줄이 개행 없이 잘린 채 남을 수 있다. 디스크가 차서 쓰기가 끊기고 되돌리기도 실패한 경우에도 남는다.
장부는 temp 파일을 쓴 뒤 rename 하므로 이 상태가 없다. 이 RFC 가 새로 만드는 상태다.

- 꼬리는 note 가 아니다. 그 붙이기는 호출자에게 note 를 돌려준 적이 없다.
- 읽기는 꼬리를 세지 않고 돌려주지 않는다. 오류로도 보지 않는다. 목록은 꼬리 앞 줄까지 그대로 읽힌다.
- 읽기는 파일을 고치지 않는다. 꼬리를 자르는 것은 다음 붙이기뿐이다(§4.1).
- `note_id` 는 완성된 줄 수로 센다. 꼬리가 있어도 번호가 어긋나지 않고, 새 note 가 꼬리 뒤에 이어 붙지 않는다.
- 개행으로 끝났는데 decode 되지 않는 줄은 꼬리가 아니다. 그 파일은 `Error` 다(§4.4).

### 4.8 backend 별 동작

장부 backend 는 둘이다(`Workspace_utils.storage_backend`).

- 서버는 FileSystem 으로 돈다. §4.1~§4.7 은 FileSystem 의 동작이다.
- Memory 는 Eio 파일 시스템이 없을 때 대신 쓰는 backend 다(`create_backend`). 시험과 Eio 밖 호출이 여기에 든다. Memory 의 장부는 프로세스 안에만 있고 재시작하면 사라진다.

Memory backend 에서 `append_note` 와 `notes_for_schedule` 은 `Error` 를 돌려준다. 로컬 파일에 쓰지 않는다.

- notes 는 지우지 않는 기록이다. 파일에 남아야 뜻이 있다. Memory 장부는 그것을 줄 수 없다.
- Memory 에서 로컬 파일에 쓰면 권위가 둘이 된다. 장부는 Memory 에, notes 는 디스크에 있게 된다.
- 선례가 둘 있다. `goal_criterion_review.ml` 은 Memory 에서 "Criterion reviews require filesystem durability" 로 거절한다. `goal_verification.ml` 은 `Memory_proof_authority_unavailable` 을 돌려준다.
- 잊는 pass(§4.5)는 Memory 에서 wake 시각만 쓴다. 읽을 notes 가 없다.

대가: Memory backend 에서는 note 도구를 쓸 수 없다. 지금은 쓸 수 있다. Memory 로 notes 를 다루는 시험이 있으면 FileSystem backend 로 옮긴다.

## 5. hard cut

새 decoder 는 `notes` 를 모른다. 옛 장부를 읽으면 schedules 와 wakes 만 읽는다.
그 뒤 첫 쓰기에서 장부의 notes 9,061행이 빠진다. 새 파일로 옮기지 않는다.

- 옛 형식을 읽는 코드, 변환 코드, 옮기는 코드는 만들지 않는다.
- 예약 45개와 wakes 는 그대로 남는다.
- Keeper 가 예약에 적어 둔 작업 기록은 이 배포 뒤에 다시 쌓인다.

## 6. 고르지 않은 것

- **notes 에 예약마다 상한을 둔다.** wakes 처럼 최근 N개만 남긴다. notes 는 지우지 않기로 한 기록이라 뜻이 바뀐다. 상한 값도 고른 숫자가 된다.
- **notes 를 하나의 날짜별 JSONL 에 쓴다.** 예약 하나의 notes 를 읽으려면 모든 날짜 파일을 읽어야 한다. 읽기는 늘 예약 하나 단위다.
- **장부 전체를 SQLite 로 옮긴다.** schedules 와 wakes 까지 바뀐다. 이 RFC 가 고치려는 것은 notes 65% 다. 나머지 35%가 문제로 측정되면 따로 다룬다.
- **`note_id` 를 줄의 바이트 위치로 쓴다.** 붙일 때 줄 수를 세지 않아도 된다. 대신 도구가 돌려주는 note 수를 세려면 어차피 파일을 읽는다. §7 의 측정에서 줄 세기가 길면 다시 본다.

- **Memory backend 에서는 notes 를 backend 값 하나로 둔다.** note 도구가 Memory 에서도 돈다. 대신 저장 구현이 둘이 되고, 붙일 때마다 그 예약의 notes 전체를 다시 쓴다. 재시작하면 사라지는 곳에 지우지 않는 기록을 두게 된다.
- **Memory backend 에서는 notes 를 전처럼 장부 안에 둔다.** `state.notes` 와 그 decoder 가 남는다. §4.6 을 할 수 없고 notes 의 표현이 둘이 된다.

## 7. 하네스

- 벤치: `test/bench_schedule_ledger_write_read.ml`(#51474)에 note 붙이기 시간을 잰다. notes 9,000행(각 1,100바이트)인 상태에서 main 과 비교한다. 이 파일은 #51474 가 만든다. #51474 가 먼저 병합되지 않으면 구현 PR 을 #51474 위에 쌓는다.
- 가장 큰 예약(2,397행)의 파일에서 note 붙이기와 목록 읽기 시간을 잰다.
- 시험:
  - note 를 붙여도 장부 파일의 inode·크기·mtime 이 그대로다.
  - 두 예약의 notes 는 서로 섞이지 않는다. `schedule_id` 가 경로 조각을 담아도 `schedule-notes/` 밖에 파일이 생기지 않는다.
  - 잊는 pass 는 마지막 note 가 보존 기간 안인 예약을 남긴다.
  - 개행으로 끝난 줄이 decode 되지 않는 파일은 `Error` 다.
  - 마지막 줄이 잘린 파일: 목록은 꼬리 앞 줄만 돌려준다. 다음 note 의 `note_id` 는 완성된 줄 수 + 1 이다. 붙인 뒤 파일에 꼬리가 없다. 시험은 꼬리가 있는 파일을 직접 만들어 넣는다.
  - Memory backend 에서 `append_note` 와 `notes_for_schedule` 은 `Error` 다. 로컬에 notes 파일이 생기지 않는다.
- 운영: 배포 뒤 45초 추적에서 장부 쓰기의 인코딩 대기와 파일 크기를 §1.2 와 비교한다.

## 8. 구현 순서

1. notes 파일 저장(쓰기·읽기)과 시험. `append_note`·`notes_for_schedule` 이 이 파일을 쓴다.
2. 장부에서 `notes` 를 뺀다(§4.6). 잊는 규칙을 §4.5 로 바꾼다.
3. 벤치와 운영 측정을 PR 본문에 적는다.

1과 2는 한 스택으로 올린다. 1만 들어가면 notes 가 두 곳에 있게 된다.

## 9. 사용자 결정

1. **옛 notes 9,061행을 버린다(§5).** 정석은 버리는 쪽이다. 대가: Keeper 가 예약마다 적어 둔 작업 기록을 한 번 잃는다. 살아 있는 예약의 것이 4,767행이다.
2. **장부에 없는 예약의 notes 파일을 언제 지울지.** 이 RFC 는 지우지 않는다. 파일은 다시 쓰지 않으므로 드는 것은 디스크뿐이다.
3. **Memory backend 에서 note 도구가 `Error` 를 돌려준다(§4.8).** 정석은 이쪽이다. 근거는 같은 선택을 한 저장소 둘이다. 대가: Memory backend 에서 지금 되는 note 추가와 목록이 안 된다. 서버는 FileSystem 으로 돌아서 운영에는 차이가 없다. 다른 길 둘은 §6 에 있다.
4. **한 번도 안 돈 채 취소·만료된 예약을 언제 잊을지.** 끝난 예약 1,467개가 2.4 MB 다. 그중 841개는 끝난 wake 가 없어서 지금 규칙으로는 잊히지 않는다. 이 RFC 범위 밖이고 이슈 #51476 에 적었다.
