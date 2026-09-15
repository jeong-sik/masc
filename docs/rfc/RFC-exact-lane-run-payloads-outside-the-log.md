---
rfc: "exact-lane-run-payloads-outside-the-log"
title: "exact lane 실행 기록의 프롬프트와 응답은 로그 밖 파일에 둔다"
status: Draft
created: 2026-09-15
updated: 2026-09-15
author: claude
supersedes: []
superseded_by: null
related: []
---

# RFC: exact lane 실행 기록의 payload 는 로그 밖에 둔다

## 0. 요약

`exact-lane-runs-v5.jsonl` 한 파일에 실행 기록(누가, 어느 lane, 결과)과 payload(프롬프트
`registration.input`, 응답 `completion.output`)가 같은 줄에 들어 있다. payload 가 바이트의
대부분이라서 두 곳이 파일 전체를 읽는다.

- 서버 기동: replay 가 모든 줄을 파싱한다.
- 실행 상세 조회(`GET /api/v1/dashboard/exact-lane-runs/<id>`): run 하나를 찾으려고 모든 줄을
  파싱한다.

이 RFC 는 payload 를 run 마다 따로 파일로 쓰고, 로그 줄에는 payload 의 위치와 크기만 남긴다.
로그 파일 이름을 v6 으로 올리는 hard cut 이고, v5 를 읽는 코드는 만들지 않는다.

## 1. 현재 동작과 측정

측정: live `~/me/.masc/exact-lane-runs-v5.jsonl`, 2026-09-15.

| 항목 | 값 |
|---|---|
| 줄 수 | 12,407 |
| 크기 | 781,661,703 B |
| 줄 크기 p50 / p90 / p99 / 최대 | 3,054 / 152,676 / 263,810 / 4,569,071 B |

- 보존 규칙은 lane 마다 완료 run 2,000개다(`completed_retention = Latest 2000`,
  `lib/exact_lane_run_registry.ml`). 줄 수는 이 규칙대로 묶여 있다. 2026-09-05 에 12,079줄
  347MB 였고 열흘 뒤 12,407줄 782MB 가 됐다. 줄 수는 그대로인데 프롬프트가 커져서 바이트가
  두 배가 됐다.
- 같은 파일 주석은 이 보존 규칙으로 "boot replay 가 약 416ms" 가 된다고 적었다. 이 수치는
  347MB 시점의 것이다.
- 메모리에는 payload 를 뺀 사본만 둔다(`shed_registration`, `shed_completion`). 그래서 상세
  조회는 디스크를 다시 읽는다.
  - `Exact_lane_run_registry.get` → `load_payloads_from_disk` 가 `Fs_compat.fold_appended_lines
    ~from:0` 으로 모든 줄을 돌며 줄마다 `Yojson.Safe.from_string` 을 부르고 id 를 비교한다
    (`fold_payload_record`).
- 호출처: TUI 의 lane run 상세와 Librarian 실제 입력 보기(`bin/masc_tui_http.ml`), 대시보드
  상세. 사용자가 열 때마다 782MB 를 파싱한다. 계속 도는 비용은 아니고 한 번 열 때와 기동할
  때 드는 비용이다.

## 2. 설계

### 2.1 저장 모양

```
<masc_root>/exact-lane-runs-v6.jsonl          실행 기록. payload 는 참조만
<masc_root>/exact-lane-run-payloads/<run_id>/input.json
<masc_root>/exact-lane-run-payloads/<run_id>/output.json
```

로그 줄의 `registration.input` 과 `completion.output` 자리에는 다음을 쓴다.

```json
{ "payload": "input.json", "bytes": 152676, "sha256": "<hex>" }
```

- payload 파일은 로그 줄보다 먼저 durable 하게 쓴다(`Keeper_fs` durable atomic write). 로그
  줄이 가리키는 파일은 항상 존재한다.
- 로그 줄을 쓰지 못하면 payload 파일은 고아가 된다. 다음 replay 의 정리 단계(2.3)가 지운다.

### 2.2 읽기

- replay 는 작은 줄만 파싱한다. payload 는 열지 않는다.
- 상세 조회는 메모리 entry 의 run id 로 두 파일을 연다. 로그를 다시 돌지 않는다.
  - 파일이 없거나 `bytes`·`sha256` 이 다르면 지금의 `Unavailable` 계열로 답한다. 새 오류
    variant 가 필요하면 `payload_read_error` 에 닫힌 생성자로 추가한다.
- `Snapshot_changed` 판정(메모리 entry 가 읽는 동안 바뀌었는지)은 그대로 둔다.

### 2.3 보존과 정리

- 보존에서 빠진 run 은 로그 compaction 과 같은 시점에 payload 디렉터리도 지운다.
- replay 가 끝나면 로그가 가리키지 않는 payload 디렉터리를 지운다. 고아 정리는 이 한 곳이다.

### 2.4 hard cut

- `storage_filename` 을 `exact-lane-runs-v6.jsonl` 로 바꾼다. v5 파일은 읽지 않고, 변환기도
  두지 않는다(constitution `legacy_residue`).
- v5 파일은 운영자가 지운다. 기동 시 자동 삭제는 하지 않는다.

## 3. 바뀌지 않는 것

- 목록 projection, 보존 규칙(lane 마다 2,000), 커서 페이지.
- `Run_registry_core` 의 이벤트 모양(`Register` / `Complete`)과 replay 의 running → 종료 판정.
- fusion·verification registry. 이 RFC 는 exact lane registry 만 다룬다.

## 4. 트레이드오프

| 좋아지는 것 | 나빠지는 것 |
|---|---|
| 기동 replay 가 payload 를 파싱하지 않는다 | run 하나에 파일이 두 개 더 생긴다(lane 당 최대 2,000 run × 2) |
| 상세 조회가 파일 두 개만 읽는다 | 등록·완료마다 durable write 가 한 번씩 늘어난다 |
| payload 크기가 로그 크기와 무관해진다 | 로그와 payload 가 어긋날 수 있어서 고아 정리가 필요하다 |

## 5. 검증

- 단위: 등록 → 완료 → 상세 조회가 같은 payload 를 돌려준다. payload 파일을 지우거나 바꾸면
  `Unavailable` 로 답한다. 보존에서 빠진 run 의 디렉터리가 지워진다. 로그 줄 없이 남은
  디렉터리가 replay 뒤에 지워진다.
- 실측: 같은 크기(12,000줄 이상, 700MB 이상)의 fixture 로 기동 replay 시간과 상세 조회 시간을
  전후로 잰다. 결과는 PR 에 로그로 남긴다.

## 6. 단계

1. payload 파일 쓰기·읽기와 v6 로그 모양(2.1, 2.2). 테스트 포함.
2. 보존·고아 정리(2.3).
3. 실측(5)과 이 RFC status 갱신.
