---
rfc: "librarian-history-original-holds-what-it-read"
title: "Librarian history original 은 읽은 범위만 담고, 앞부분은 길이와 digest 로 가리킨다"
status: Draft
created: 2026-10-27
updated: 2026-10-27
author: claude
related: ["librarian-history-settles-finished-originals", "librarian-lifecycle"]
---

# Librarian history original 은 읽은 범위만 담고, 앞부분은 길이와 digest 로 가리킨다

## 0. 요약

Librarian 이 끝난 턴을 읽는 pass 하나는, 새로 읽을 내용이 한 턴뿐이어도 Keeper 의 대화 전체 크기만큼 비싸다. history original 이 출처 넷(checkpoint 원문, 같은 checkpoint 의 메시지, official trace 파일, 턴 경계 로그)을 통째로 담기 때문이다.

이 넷을 통째로 담는 이유는 하나다. 커밋 직전에 "지금 출처의 앞부분이 그때와 같은가"를 원소 하나씩 비교하려는 것이다. 이 비교는 앞부분의 길이와 digest 만 있으면 지금 출처에서 다시 계산할 수 있다.

그래서 original 은 Librarian 이 실제로 읽은 범위만 원문으로 담는다. 앞부분은 길이와 digest 로 가리킨다. 이렇게 하면 저장과 복원 비용이 읽을 범위를 따라가고, 남는 대화 크기 비용은 커밋 때 지금 출처를 한 번 해시하는 것뿐이다. 형식이 바뀌므로 하드컷이다.

## 1. 문제

### 1.1 측정

`test/bench_keeper_librarian_pass.ml`(#46371)로 쟀다. 새로 읽을 내용은 210 B 한 턴으로 두고, 이미 읽은 대화만 키웠다. 소스는 `fbf2f55ae0a` 이고, 둘째 줄은 그 위에 #46247 을 얹은 값이다.

| 이미 읽은 대화 | checkpoint | pass 할당 | 저장 | 시간 |
|---|---|---|---|---|
| 1 MB | 1.05 MB | 2.01 GB → 1.51 GB | 6.8 MB → 2.3 MB | 3.4 s → 1.8 s |
| 5 MB | 5.27 MB | 8.34 GB → 6.16 GB | 32.3 MB → 10.8 MB | 9.3 s → 6.9 s |
| 20 MB | 21.1 MB | 32.93 GB → 24.28 GB | 127.8 MB → 42.7 MB | 32.0 s → 28.8 s |

#46247 뒤에도 pass 하나가 checkpoint 크기의 약 1,150배를 할당하고 약 2배를 저장한다. 읽을 양과는 상관없다.

### 1.2 라이브

- 2026-10-27 12:2x KST, 가장 큰 gate 기록은 30.7 MB 였다. 그 안의 capture 에서 checkpoint `canonical_bytes` 가 5.0 MB, 같은 checkpoint 의 `messages` 가 4.7 MB, `traces` 가 4.6 MB, `boundaries` 가 1.9 MB 였다. `input_text` 의 `messages` 4.8 MB 는 그 pass 가 읽을 범위였다.
- #46247 배포(`eff0a3bd28b`, 13:18 KST) 뒤 memprof 할당 상위는 `Keeper_librarian_durable_request.of_json`·`restore`(약 16%)와 `Lane_addon_tool_request_owner.retain`·`load`(약 12%)다. history original 을 다시 읽고 검증하는 경로다.
- 같은 서버의 live heap(7~9 GB)도 대부분 이 경로다. memprof 를 15초 간격으로 읽어 live 표가 `gc.live_words` 를 거의 덮게 한 뒤 보니, 약 70% 이상이 history original 을 읽는 도중의 데이터였다. 기록 본문 파싱(`request_of_body`) 34~41%, 복원 때 문자열 파싱과 다시 인코딩 19~25%, 원본 바이트 8~12% 다. checkpoint lineage 메모는 2~3% 다(`docs/evidence/2026-10-27-librarian-live-heap/`). 그래서 상주 메모리는 동시에 도는 pass 수와 기록 크기를 곱한 만큼 커진다.
- Librarian lane 은 Keeper 마다 하나다. 턴이 끝날 때마다 pass 가 돌고, 이 비용이 Keeper 수만큼 겹친다. 운영자가 Keeper 300명을 돌렸을 때 메모리가 약 150 GB 까지 올라 서버가 죽었다고 보고했다. 그 실행의 기록은 없어서 원인을 이것으로 단정하지는 않는다.

## 2. 지금 original 이 담는 것

`origin/main` `fdda2724cba` 기준. `cap` 는 `lib/keeper/keeper_librarian_durable_capture.ml`, `lock` 은 `keeper_librarian_durable_source_lock.ml`, `req` 는 `keeper_librarian_durable_request.ml` 이다.

| 필드 | 크기가 따라가는 것 | 누가 읽나 |
|---|---|---|
| checkpoint `canonical_bytes` | 대화 전체 | 복원(`checkpoint_of_json`)만. 파일을 디코딩해 `{trace_id, turn_count, sha256}` 와 `messages` 가 맞는지 본다 |
| checkpoint `messages` | 대화 전체 | 복원 때 위 디코딩과 비교한다. `validate` 가 `Keeper_librarian_range.select` 를 다시 돌린다. 커밋 직전 `lock` 이 지금 checkpoint 의 앞부분과 원소별로 비교한다 |
| official `traces` (`main`, `internal`) | 고른 trace 파일 전체 행 | `validate` 가 고른 행이 이어지는지 본다. `lock` 이 지금 파일의 앞부분과 원소별로 비교한다 |
| `boundaries` | 턴 경계 로그 전체 | `select`, `witness_line`, 시간 경계에 쓴다. `lock` 이 지금 로그의 앞부분과 원소별로 비교한다 |
| `input_text` | 읽을 범위 | `project_source` 결과와 같아야 한다. 모델에 보내는 프롬프트가 여기서 나온다 |
| `range`, `positions`, `counterparts_text` | 작다 | 범위와 커서 검증 |

- 작업자(Python)와 Exact 실행기는 `rendered_prompt` 만 받는다. 위 넷을 읽지 않는다.
- 요청은 이 capture 를 문자열(`source_text`)로 담는다. 복원 때마다 그 문자열을 파싱하고, 다시 인코딩해 같은지 보고(`req` 258줄), 요청 전체를 다시 인코딩해 비교한다(263줄). pass 하나에서 복원은 `discover`, `check_request`, `validate_with` 로 여러 번 불린다. 그래서 담는 양이 크면 할당이 그 몇 배가 된다.

## 3. 왜 전부 담았나

코드 주석이 말하는 이유는 이렇다.

- `cap.mli`: "Retain bytes, reference and full messages from the same actual read. A restored checkpoint never becomes an exact-source or source-lock token."
- `cap.mli`: original 은 바뀌는 저장소를 다시 읽지 않고 일관성을 확인한다. 고른 기록과 입력은 나중에 출처가 바뀌어도 남는다.
- `Keeper_librarian_range.mli`: range 는 메시지 목록 안의 atom 번호 두 개라서, 다른 목록에 대면 아무 말 없이 다른 내용을 자른다.

checkpoint 의 sha256 은 파일 전체에 대한 해시 하나다. atom digest(`Runtime_model_input_tail_window.atom_opening_digest`)는 atom 의 첫 메시지 하나만 해시하고 앞 digest 를 잇지 않는다. 그래서 지금 형식으로는 "이 조각이 그 checkpoint 의 그 자리에서 왔다"를 원문 없이 보일 수 없다. 원문을 통째로 담은 것은 이 때문으로 본다.

## 4. 설계

### 4.1 원칙

original 은 Librarian 이 읽은 것의 기록이다. Librarian 은 범위만 읽었고 앞부분은 읽지 않았다. 그러니 앞부분은 원문이 아니라 "얼마만큼이었고 무엇이었나"만 남기면 된다.

- 읽은 범위: 원문 그대로 담는다. 지금 `input_text` 가 이미 그렇다.
- 앞부분: 출처마다 `{count, digest}` 를 담는다. `count` 는 원소 수, `digest` 는 그 원소들의 SHA-256 이다.
- 커밋 직전 검사(`lock`)는 지금 출처의 첫 `count` 원소로 같은 digest 를 계산해 비교한다. 지금의 원소별 `prefix` 비교와 같은 것을 확인한다.

### 4.2 digest 정의

출처마다 지금 `lock` 이 비교에 쓰는 표현을 그대로 해시한다. 비교 대상이 바뀌지 않게 하려는 것이다.

| 출처 | 원소 | 원소 표현 |
|---|---|---|
| checkpoint | 메시지 | `Agent_core.Checkpoint.message_to_json` 의 `Yojson.Safe.to_string` (`lock` 의 `same_message` 와 같다) |
| official trace | `main`·`internal` 행 | `Keeper_turn_fragments` 가 읽은 행의 canonical 인코딩 |
| 턴 경계 | 경계 줄 | `Keeper_turn_boundaries` 가 읽은 기록의 canonical 인코딩 |

digest 는 원소마다 `길이(8바이트) ‖ 바이트` 를 이어 붙여 SHA-256 으로 스트리밍 해시한다. 길이를 붙이는 것은 원소 경계가 다른 두 목록이 같은 digest 가 되지 않게 하려는 것이다.

### 4.3 출처별로 담는 것

- **checkpoint**: `canonical_bytes` 와 전체 `messages` 를 뺀다. `{trace_id, turn_count, sha256}` 는 이름표로 남긴다. 복원에서는 이 값을 파일과 대조하지 않는다. 앞부분 `{count, digest}` 와, 읽은 범위의 메시지를 담는다. `select` 가 범위 위치를 확인하는 데 쓰는 atom 경계 digest(시작 앞 atom, 시작, 끝, `All_unread` 의 마지막 일치)를 함께 담는다.
- **official trace**: 고른 턴의 행만 원문으로 담는다. 파일마다 앞부분 `{count, digest}` 를 담는다.
- **턴 경계**: 고른 구간과 `select`·`witness_line` 이 보는 줄만 원문으로 담는다. 로그 앞부분 `{count, digest}` 를 담는다.
- **`input_text`**, `range`, `positions`, `counterparts_text`: 지금 그대로.

### 4.4 검사가 옮겨 가는 곳

| 검사 | 지금 | 바뀐 뒤 |
|---|---|---|
| 조각이 checkpoint 파일에서 왔는가 | 복원 때 원문을 디코딩해 sha256 과 메시지를 대조 | 커밋 직전 `lock` 이 지금 checkpoint 로 앞부분 digest 와 범위 메시지를 대조 |
| range 위치 | 복원 때 전체 메시지로 `select` 를 다시 돈다 | 복원 때 담은 범위와 atom 경계 digest 로 `select` 가 보는 지점만 확인한다. 출처와의 대조는 `lock` |
| 앞부분이 바뀌었나 | `lock` 이 원소별 `prefix` 비교 | `lock` 이 digest 비교 |
| 입력이 범위의 투영인가 | 복원 때 `project_source` | 그대로 |

`cap.mli` 의 "restored checkpoint never becomes an exact-source or source-lock token" 은 그대로 지킨다. 복원은 출처를 주장하지 않고, 출처와의 대조는 `lock` 만 한다.

### 4.5 남는 대화 크기 비용

- capture 때: 출처를 읽어 앞부분 digest 를 계산한다. 지금도 출처는 통째로 읽는다. 바뀐 뒤에는 그 바이트를 저장하거나 다시 인코딩하지 않는다. checkpoint 메시지의 인코딩은 `Keeper_checkpoint_store` 의 lineage 메모가 이미 들고 있으면 그것을 쓸 수 있다(구현 층에서 확인).
- 커밋 직전 `lock`: 지금 checkpoint 의 앞부분을 한 번 인코딩해 해시한다. 지금도 원소별 비교를 위해 같은 일을 한다.

복원과 그 반복 검증은 읽을 범위 크기를 따라간다.

## 5. 고르지 않은 안

- **checkpoint 원문을 sha256 주소로 따로 보관하고 참조만 담기**(`accepted-checkpoints/<sha256>.json` 을 Librarian 이 붙잡기). original 의 크기는 줄지만 pass 마다 대화 전체를 한 번 더 저장한다. Librarian 이 읽지 않은 바이트를 증거로 붙잡는 것이고, 보관 정리(`keeper_retained_checkpoint_sweep`)에 새 소유자를 더해야 한다.
- **checkpoint 에 atom 사슬 digest(또는 Merkle) 저장**. 조각 하나로 위치를 증명할 수 있지만 Agent Core checkpoint 형식이 바뀐다. 이 문제는 capture 와 커밋 양쪽이 지금 출처를 읽을 수 있어서, 앞부분 digest 로 충분하다.
- **복원 결과를 digest 로 메모하기**. 반복 검증은 줄지만 담는 양과 저장은 그대로이고, 메모가 대화 전체를 메모리에 붙잡는다.
- **`source_text` 를 문자열 대신 JSON 값으로 담기**. 이스케이프는 줄지만 담는 양이 작아지면 차이가 작다. 문자열로 정확한 인코딩을 고정하는 지금 검사(`req` 258줄)도 그대로 둔다.

## 6. 층

| 층 | 내용 | 시험 |
|---|---|---|
| L1 | 이 RFC | — |
| L2 | 앞부분 digest 함수(출처 셋), capture 형식 다음 버전, `select`·`validate`·`lock` 을 4.4 대로, 하드컷 | 기존 `test_keeper_librarian_durable_execution`, `test_keeper_librarian_durable_capture`, `test_keeper_librarian_addon_owner`. 앞부분 원소 하나를 바꾸면 `lock` 이 거절하는 시험(출처 셋 각각), 범위 메시지를 바꾸면 복원이 거절하는 시험 |
| L3 | 측정: `bench_keeper_librarian_pass` 1/5/20 MB, 라이브 `server_memory_sampler.py`, RFC status 갱신 | 7절 |

형식 변경은 출처 셋을 한 층에서 한 번에 바꾼다. 하드컷을 여러 번 나누면 배포 절차를 여러 번 밟아야 한다.

## 7. 수용 기준

`bench_keeper_librarian_pass`, 읽을 내용 210 B, 이미 읽은 대화 1/5/20 MB:

- pass 저장: 이미 읽은 대화 크기와 상관없이 거의 같다. 20 MB 에서 checkpoint 의 1% 아래.
- pass 할당: checkpoint 의 20배 아래. 지금은 약 1,150배다.
- 기존 Librarian 시험 세 묶음이 모두 통과한다.

라이브에서는 배포 뒤 기동 15분 전후의 초당 할당 p50 과 memprof 상위를 #46247 배포 뒤 값(초당 1.1 GB, `Keeper_librarian_durable_request` 약 16%)과 비교해 기록한다.

## 8. 배포 (하드컷)

#46247 과 같은 절차를 쓴다.

1. 바뀐 형식을 읽지 못하는 옛 history original 이 남지 않게, 배포 전 서버에서 끝난 체인이 settle 됐는지 본다.
2. 서버를 멈춘다.
3. `keeper-librarian-history-execution-*` 와 그 gate scope(`keeper-librarian-durable-gate/*`) 디렉터리를 `tool-request-owners/` 와 `tool-request-bodies/` 양쪽에서 옮긴다. 읽기 위치는 커밋한 범위까지만 나아가 있으므로, 다음 pass 가 남은 범위를 새 original 로 다시 잡는다.
4. 새 바이너리로 띄운다.

2026-10-27 하드컷에 쓴 스크립트(정지, 남은 commit 확인, 옮기기, 되돌리기)를 그대로 쓸 수 있다. admission scope 는 이 형식을 쓰지 않으면 옮기지 않는다. L2 에서 확인한다.

## 9. 열린 질문

- `select` 가 원문 없이 확인해야 하는 지점이 4.3 의 atom 경계 digest 로 충분한지. `All_unread` 와 `To_first_cut_point` 각각을 L2 에서 코드로 확인한다.
- `same_generation` 은 `boundary_lines_seen` 앞의 줄을 무시하고 그 뒤의 재시작을 거절한다. 담는 경계 줄 범위로 이 판단이 되는지.
- checkpoint 메시지에는 lineage 와 다른 `ToolResult.json` 이 있을 수 있다(`cap` 주석). digest 는 `lock` 처럼 `message_to_json` 투영으로 계산하므로 지금 비교와 같은 결과여야 한다. 시험으로 확인한다.
- 대체 체인의 `Replacement_intended` 는 자식 요청 전체를 담는다. 요청이 작아지면 이 사본도 작아진다. 따로 바꾸지 않는다.

## 10. 확신도

- 2절의 필드와 읽는 곳: 높음. 코드에서 확인했다. 라인 번호는 `fdda2724cba` 기준이다.
- 4절 설계로 `lock` 이 같은 것을 확인한다는 점: 중간. digest 비교는 원소별 비교와 같은 결과를 낸다. 다만 `select` 와 `same_generation` 이 원문 없이 같은 판단을 하는지는 L2 에서 확인해야 한다.
- 7절 할당 목표(20배 아래): 낮음. 커밋 때 해시 비용과 남은 반복 검증을 재 보지 않았다. L2 뒤 측정으로 고친다.
