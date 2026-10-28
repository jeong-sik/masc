---
rfc: "0476"
title: "Keeper checkpoint 를 참조로 저장한다: media 는 blob 으로, history 는 메시지 단위로"
status: Draft
created: 2026-10-28
updated: 2026-10-28
author: vincent
related: ["36690", "46396", "46541", "0265"]
---

# RFC-0476 — Keeper checkpoint 를 참조로 저장한다

## 0. 요약

Keeper 의 agent-core checkpoint 는 저장할 때마다 history 전체를 다시 쓰고, 읽는 쪽 대부분도 매번 전체를 읽는다. 가장 큰 Keeper 는 179MB 파일을 tool 라운드마다 세 번 새로 쓴다. 기동 때는 40명 분 578MB 를 다 읽는다. #36690(쓰기)과 #46396(읽기)이 같은 원인이다.

이 RFC 는 컴팩션 없이 고친다. 모델이 보는 내용은 바뀌지 않는다. 바뀌는 것은 디스크에 놓는 방식이다.

1. **media 바이트는 언제나 참조로 둔다.** 이미지·문서·오디오 바이트는 content-addressed blob 저장소에 한 번만 쓰고, history 에는 digest 만 남긴다. 설명(caption)을 새로 만들지 않는다. 바이트는 provider 요청을 만들 때, 그 요청에 실리는 메시지에 대해서만 되돌린다.
2. **history 를 메시지 단위로 저장한다.** 메시지 하나를 digest 로 이름 붙여 한 번만 쓴다. checkpoint 파일(head)에는 나머지 필드와 메시지 digest 목록만 둔다. 어떤 편집이든 새 head 하나로 표현되고, 바뀌지 않은 메시지는 다시 쓰지 않는다.

| 층 | 내용 | 성공 기준(§8) |
|---|---|---|
| L0 | 측정 계기: 저장마다 쓴 바이트, 읽기마다 읽은 바이트를 같은 로그·bench 로 잰다 | 아래 기준을 전후로 잴 수 있다 |
| L1 | media 참조: 쓰기 경계에서 모든 media 바이트를 blob 으로 빼고, 요청을 만들 때만 되돌린다 | inline media 0바이트. msx-retro-mania checkpoint 가 약 3분의 1 크기 |
| L2 | 메시지 단위 저장과 head: 저장은 새 메시지와 head 만 쓴다 | tool 라운드당 쓴 바이트가 history 크기와 무관(새 메시지 + head) |
| L3 | 읽는 쪽이 필요한 만큼만 읽는다: 개수·목록·prefix 비교를 head 로 한다 | 기동 `transcript_tail`, 대시보드 `shell_light` 새로 고침 시간이 절반 이하 |
| L4 | 보관과 정리: 보관 snapshot 은 head 만, blob 정리는 head 가 가리키는 digest 로 한다 | 보관 사본 때문에 늘어나는 디스크 0 |

## 1. 측정 (2026-10-28, 라이브 상태)

- canonical checkpoint 35개, 합계 502MB. 그중 inline media 가 144MB(29%)이고, media 를 가진 Keeper 는 5명이다.
- 가장 큰 `msx-retro-mania`(`trace-1788882319100-00000`)는 179MB 다.
  - 메시지 9,017개 중 이미지 1,502장이 121MB(67%)다.
  - 이미지는 모두 `masc_dos_screen` 의 640×480 PNG 이고, base64 로 `tool_result` 안에 들어 있다.
- 나머지 Keeper 는 글자만으로 크다. 둘째로 큰 것은 37MB 인데 media 가 없고 메시지가 15,940개다. media 참조만으로는 이런 Keeper 의 통째 재작성이 남는다.
- media 를 뺀 메시지 하나의 크기는 중앙값 1.3KB, p90 6.9KB, p99 24.9KB 다(전체 130,653개).
- 같은 화면이 다시 찍혀 중복된 이미지가 27MB 다(1,572장 중 서로 다른 것 1,236장).
- 쓰기 쪽: 04:33:37~38Z 사이 1.2초 동안 msx-retro-mania 가 179MB 를 세 번 새로 썼다. #36690 의 10-07 측정에서는 3시간 동안 저장 7,781번, `canonical_bytes` 합계 297GB 였다.
- 보관 snapshot 3개는 inode 가 서로 다르다. canonical 파일을 rename 으로 갈아 끼우기 때문에, hardlink 가 예전 내용을 따로 붙잡는다. 그래서 보관 개수만큼 전체 사본이 디스크에 남는다.
- 읽기 쪽: 기동 단계 `transcript_tail` 이 40명 분 578MB 를 읽어 6.3초 걸렸다(#46541). 대시보드 `shell_light` 새로 고침은 평소에도 5~7초, 길게는 19.9초 걸린다. 25초 `sample` 에서 CPU 를 가장 많이 쓴 것은 worker domain 의 Yojson 긴 문자열 해석이다. 호출자는 unwinder 가 잃어서 확인하지 못했다.

측정 스크립트는 #46396 댓글(issuecomment-6460776900)과 같은 방식이다. 파일을 읽기만 한다.

## 2. 지금 코드가 하는 일

줄 번호는 2026-10-28 main 기준이다. `*` 표시는 직접 열어 확인한 것이고, 나머지는 조사 보고를 옮겼다. 리뷰에서 함께 확인해 주면 좋겠다.

### 2.1 저장

- tool 라운드마다 세 단계에서 checkpoint 전체를 새로 만든다. `After_assistant_collected`, `After_tool_results_appended`, `After_context_injection` 이다(packages/agent_core/lib/agent/pipeline.ml:372, :504, :548). 턴 끝에 `finalize` 저장이 한 번 더 있다.
- store 는 바뀌지 않은 메시지의 인코딩을 재사용하지만, 파일은 매번 전부 쓴다. 임시 파일에 쓰고 fsync 한 뒤 `<trace>/<trace>.json` 으로 rename 한다(`*`lib/keeper/keeper_checkpoint_store.ml:16-17, `*`lib/keeper/keeper_fs.ml:79).
- 저장마다 canonical 을 `agent-core-snapshot-<ms>.json` 으로 hardlink 하고 최근 N개만 둔다. N 은 `keeper.checkpoint_history_retained` 이고 기본값은 3이다(`*`lib/runtime_settings.ml:250).

### 2.2 history 는 덧붙기만 하지 않는다

append-only 로그가 맞지 않는 이유다.

- 한 tool 라운드 안에서는 덧붙이기만 한다.
- 끝부분을 고치는 경우가 있다.
  - 거절된 응답을 버린다(keeper_turn_driver_try_provider.ml:3213).
  - 턴 마무리 때 끝의 assistant 메시지를 버리거나, 그 Text 를 그 자리에서 고친다(keeper_replay_checkpoint.ml:143-251).
- 중간에 끼워 넣는 경우도 있다. 턴 시작 때 `close_open_cycles` 가 닫히지 않은 tool 호출의 닫는 메시지를 history 중간에 넣는다(`*`lib/keeper/keeper_transcript_unit.ml:388).
- purge 는 옛 tool 결과 본문을 비우고, history clear 는 대부분을 지운다.

### 2.3 읽기

- 턴마다 history 전체를 history 로 쓴다. 같은 프로세스가 마지막에 쓴 파일이면 메모리 사본을 다시 쓰고, 아니면 전부 다시 읽는다.
- exact snapshot 을 읽는 쪽은 매번 파일 전체를 읽고 SHA-256 을 계산한다. Librarian, continuation, 기동 tail 복구가 여기에 해당한다. 비교 대상인 `expected_source_ref` 가 파일 전체의 해시이기 때문이다.
- heartbeat 와 `keeper_status` 는 메시지 개수만 필요한데, 캐시가 없으면 전체를 읽는다.
- 대시보드 checkpoint 목록은 보관 snapshot 마다 전체를 해석한다. 정작 쓰는 것은 개수·시각·미리보기뿐이다.

### 2.4 provider 요청에 실리는 범위

- 요청은 `choose_range_start` 가 고른 메시지부터 끝까지 싣는다. 시작점은 Librarian continuity, 읽은 위치, 지난 요청의 시작, 마지막 완료 턴 순서로 정한다. 바이트 상한은 없다.
- 요청 크기 상한은 기록만 한다(`*`keeper_turn_driver_try_provider.ml:1737-1742, "neither changes what is sent").
- 옛 tool 결과를 참조로 내리는 demotion 은 이미지가 든 결과를 건너뛴다(`*`lib/keeper/keeper_model_input_demotion.ml:145-160).
- 그래서 범위 밖의 옛 이미지는 모델에 가지 않는다. 그래도 디스크와 메모리에는 계속 남아 있다.

### 2.5 이미지가 저장소를 비켜 가는 곳

- `masc_dos_screen` 은 `[Text json; Image base64]` 를 돌려준다(lib/dos_tools/dos_machine_tools.ml:429-438).
- `Tool_projection` 은 글자 `message` 만 blob 으로 뺀다. `content_blocks` 는 그대로 붙인다(`*`lib/tool_projection/tool_projection.ml:407, :428).
- checkpoint 쓰기 경계의 vision eviction(`*`lib/keeper/keeper_context_core.ml:64-71)에는 두 가지 제한이 있다.
  - 레인에 이미지를 받는 runtime 이 하나도 없을 때만 동작한다.
  - 맨 위의 `Image` 만 바꾸고, `ToolResult` 안의 이미지는 그대로 둔다(`*`lib/keeper/keeper_vision_ingest.ml:235).
- `keeper_image_read` 는 kept 저장소에 쓰고 inline 으로도 넣어서, 같은 바이트를 두 번 저장한다(lib/keeper/keeper_image_read.ml:62, :80-82).

## 3. 설계

### 3.1 원칙

- media 바이트는 history 안에 두지 않는다. 언제나 참조다. 설명을 만들어 대신 두지 않는다. 도구가 함께 돌려준 텍스트는 지금처럼 남는다. 예를 들어 `masc_dos_screen` 의 `screen_text`·`video_mode` 다.
- 모델이 보는 것은 바꾸지 않는다. 요청 범위, demotion, degrade 규칙은 그대로다.
- 형식의 경계는 타입으로 둔다. 문자열 표식을 해석하는 분기를 만들지 않는다.

### 3.2 L1 — media 참조

**타입.** 지금 `Image`/`Document`/`Audio` 는 `{media_type; data; source_type}` 이고, `data` 의 뜻이 `source_type` 에 따라 바뀐다(packages/agent_core/lib/llm_provider/types.mli:296). 이것을 payload 를 가진 합타입으로 바꾼다.

```ocaml
type media_source =
  | Base64 of string
  | Url of string
  | File_id of string
  | Stored of { sha256 : string; bytes : int }

| Image of { media_type : string; source : media_source }
```

- `Stored` 는 masc 의 blob 저장소를 가리킨다.
- provider backend 가 `Stored` 를 받으면 typed 오류로 거절한다. backend 에 오기 전에 되돌려야 하는 값이기 때문이다.
- 기존 `match` 들은 컴파일러가 모두 찾아 준다.

**쓰기.** checkpoint 쓰기 경계에서, 모든 runtime 에 대해 메시지 안의 모든 `Base64` media 를 blob 으로 옮기고 `Stored` 로 바꾼다. `ToolResult` 의 `content_blocks` 안도 같다.
- 저장소는 `Tool_blob_store` 를 쓴다(`put_durable`, SHA-256 주소, 읽을 때 무결성 검사).
- 이미 `Stored` 인 블록은 그대로 지나간다. 그래서 다음 저장 한 번이면 지금 inline 으로 들어 있는 이미지도 함께 바뀐다. 따로 변환하는 코드는 없다.
- Vision 저장소의 frames 는 쓰지 않는다. 항목 500개·20MB 를 넘으면 mtime 순으로 지워서, checkpoint 가 아직 가리키는 frame 을 지울 수 있다(`*`lib/multimodal/vision_artifact_store.ml:39-40).

**읽기.** 요청을 만드는 한 곳에서, 그 요청에 실리는 메시지의 `Stored` 만 `Base64` 로 되돌린다. backend 와 tool 결과 media projector 보다 앞이다(keeper_turn_driver_try_provider.ml 의 `bounded_model_input_projection` 부근).
- blob 이 없으면 typed 오류다. 그 이미지를 조용히 빼지 않는다.
- 범위 밖의 이미지는 되돌리지 않는다.

**효과.** inline media 144MB 가 history 에서 빠지고, 중복 27MB 는 한 번만 저장된다. `keeper_image_read` 의 이중 저장도 같이 사라진다.

**형식.** checkpoint JSON 에 `Stored` 가 추가된다. `Base64` 는 도구가 지금도 만드는 살아 있는 형태라서, 이 층에는 하드컷이 필요 없다.

### 3.3 L2 — 메시지 단위 저장과 head

**배치.**

```
<trace>/<trace>.json                 head: 메시지 외 필드 + 메시지 digest 목록
<trace>/messages/<aa>/<sha256>.json  메시지 하나 (media 는 L1 의 Stored)
```

**저장.**
1. head 에 없는 새 메시지 파일만 쓰고 fsync 한다.
2. 그다음 head 를 지금처럼 임시 파일·fsync·rename·디렉터리 fsync 로 바꾼다.

순서 때문에 head 는 항상 이미 내구화된 메시지만 가리킨다. 끝을 고치든 중간에 끼우든 purge 하든, 새 메시지 목록의 head 하나로 표현된다. 바뀐 메시지만 새 파일이 된다.

**exact ref.** `expected_source_ref` 는 head 바이트의 SHA-256 이 된다. head 가 모든 메시지 digest 를 담으므로 history 전체를 가리키는 값이다. 비교 비용은 head 크기를 따른다.

**크기 추정.** 메시지 15,940개인 Keeper 의 head 는 digest 목록만 약 1.3MB 다(16진 64자 + 구분자). 지금 37MB 를 쓰던 저장이 head 1.3MB + 새 메시지 몇 KB 가 된다. head 도 줄이려면 턴 단위 구간의 digest 를 한 단계 더 둘 수 있다. 처음에는 한 단계로 두고 L0 측정으로 정한다(결정 D4).

**하드컷.** 형식이 바뀐다. masc 규칙대로 호환 reader·변환 코드는 만들지 않는다. 이전 형식의 checkpoint 는 지금도 있는 `Superseded` 로 읽혀서, 각 Keeper 의 다음 턴은 새 history 로 시작한다(lib/keeper/keeper_run_context.ml:127). Keeper 대화 기록(`keeper_chat`), Librarian 기억, 게시판은 그대로다(결정 D1).

### 3.4 L3 — 필요한 만큼 읽기

- 메시지 개수(heartbeat, `keeper_status`)는 head 의 목록 길이로 답한다.
- 대시보드 checkpoint 목록은 보관 head 만 읽는다. 미리보기가 필요하면 마지막 메시지 하나만 읽는다.
- Librarian 과 continuation 의 "앞부분이 그대로인가" 비교는 메시지 JSON 대신 digest 를 비교한다. 지금은 메시지마다 전체를 인코딩해서 비교한다.
- 기동 tail 복구는 head 와 메시지를 읽되 media 는 읽지 않는다. 끝의 tool 라운드만 읽어도 되는지는 `close_open_tail` 의 `partition` 규칙을 따로 확인한 뒤 정한다. 이 RFC 에서 약속하지 않는다.

### 3.5 L4 — 보관과 정리

- 보관 snapshot 은 head 사본만 둔다. 메시지와 blob 은 공유한다.
- 정리는 보관 head 와 `accepted-checkpoints` head 가 가리키는 digest 를 따라간다. 메시지 파일과 그 안의 `Stored` digest 다.
- 가리키는 것이 없는 메시지 파일만 지운다. 파일 내용을 문자열로 훑지 않는다.
- `Tool_blob_store` 의 blob 은 지금의 정리 경로(`Tool_blob_maintenance`)가 head 와 메시지 파일에서 참조를 찾도록 맞춘다.

## 4. 고려했다 버린 것

- **append-only 연산 로그.** agent_core 의 `Checkpoint_delta` 를 쓰는 방식이다(splice 연산). §2.2 의 편집을 표현할 수는 있다. 하지만 검증 해시가 checkpoint 전체에 대한 MD5 라서 쓸 때마다 전체 비용이 든다. 다시 만들 때 처음부터 재생해야 하고, 로그를 접는 일도 따로 필요하다. masc 에서는 쓰는 곳이 없다.
- **컴팩션·요약.** 모델이 보는 내용이 바뀐다. 이 문제의 원인은 저장 방식이지 history 길이가 아니라서 범위 밖이다.
- **이미지 설명 생성.** 이미지마다 모델 호출이 늘고, 같은 이미지에도 결과가 달라질 수 있다. 원본 대신 요약을 저장하게 된다. 사용자 결정으로 하지 않는다.
- **URL 참조.** provider 가 직접 가져가려면 로컬 이미지를 밖에 공개해야 한다.
- **Vision artifact 저장소.** frames 는 개수·크기 순으로 지워진다. kept 는 handle 마다 소비처 전체를 문자열로 훑는다. 이미지 1,500장 규모에는 맞지 않는다고 판단했다(측정하지 않았다).

## 5. 순서

1. L0: 측정 계기. 저장마다 쓴 바이트, 읽기마다 읽은 바이트, 기동 단계 시간을 같은 이름으로 남긴다. checkpoint 저장·읽기 bench 를 `test/` 에 둔다.
2. L1: media 참조. 하드컷 없이 들어간다.
3. L2: 메시지 단위 저장. 하드컷이다. D1 이 정해진 뒤에 한다.
4. L3: 읽는 쪽을 하나씩 head 로 옮긴다. 읽는 쪽마다 PR 을 따로 낸다.
5. L4: 보관·정리.

층마다 PR 을 나누고, 앞 층의 측정이 기준을 넘긴 것을 본 뒤 다음 층으로 간다.

## 6. 하지 않는 것

- 요청 범위·demotion·degrade 규칙 변경
- 컴팩션, 요약, 이미지 설명 생성
- `masc_dos_screen` 이 텍스트 모드 화면에서 이미지를 빼는 것(도구 쪽 결정이다)
- Librarian 의 읽기 범위 설계 변경. digest 비교로 바꾸는 것만 한다.

## 7. 위험

- **파일 수.** L2 에서 메시지 파일이 지금 기준 약 13만 개 생긴다. APFS 에서 문제가 되는지는 L0 bench 로 확인한다. 문제가 되면 메시지를 턴 단위로 묶은 파일로 바꾼다(결정 D2).
- **fsync 횟수.** 저장 한 번에 새 메시지 파일 1~3개와 head 를 fsync 한다. 지금은 179MB 하나다. 작은 파일 여러 번이 더 느린지는 bench 로 잰다.
- **정리 오류.** 보관 head 가 가리키는 blob 을 지우면, 그 이미지가 범위에 들어온 요청이 typed 오류로 실패한다. 정리는 head 를 따라가서만 지운다.
- **다른 프로세스.** CLI 가 head 를 읽는 동안 저장이 일어날 수 있다. 메시지를 head 보다 먼저 내구화하므로, 읽은 head 가 가리키는 메시지는 언제나 있다. 지워지는 것은 L4 정리뿐이고, 정리는 서버 정지 중에 한다.
- **되돌리기.** L1 을 배포한 뒤 그 전 binary 로 되돌리면, `Stored` 가 든 checkpoint 를 읽지 못한다. 기존 `Base64` 의 JSON 모양은 바뀌지 않으니 되돌려도 문제가 되는 것은 `Stored` 블록뿐이다.
- **하드컷.** L2 배포 때 모든 Keeper 의 agent-core history 가 새로 시작한다.

## 8. 측정 방법

- 저장: `checkpoint_save` 로그의 `canonical_bytes` 와, L0 에서 더하는 실제로 쓴 바이트. tool 라운드당 합을 본다.
- 크기: §1 의 측정 스크립트로 inline media 바이트와 checkpoint 크기를 본다.
- 기동: `keeper_persistence_prepare: stage=transcript_tail elapsed_seconds`.
- 대시보드: `dashboard_snapshot heavy refresh: component=shell_light elapsed_s`. 같은 시간대 30분의 중앙값을 비교한다.
- CPU: 25초 `sample` 의 `caml_lex_engine` 몫.
- 디스크: `~/me/.masc/traces` 와 `tool_blobs/` 합계.

## 9. 정해야 할 것

- **D1. L2 하드컷.** 배포 때 Keeper 의 agent-core history 가 새로 시작해도 되는가. 대화 기록과 Librarian 기억은 남는다. Librarian continuity 가 옛 checkpoint 의 위치를 가리키는 부분이 어떻게 되는지는 아직 확인하지 않았다. L2 설계 때 확인한다.
- **D2. 메시지 파일 배치.** 메시지당 파일 하나로 갈지, 턴 단위 묶음 파일로 갈지. 앞쪽은 단순하고, 뒤쪽은 파일 수가 적다. L0 bench 뒤에 정한다.
- **D3. 범위.** 문서·오디오도 같은 참조 규칙에 넣는가. 이 RFC 는 넣는 쪽이다. 사용자가 첨부한 문서·오디오도 지금 inline base64 로 남는다(lib/keeper/keeper_multimodal_input.ml:625-637).
- **D4. head 단계.** 한 단계 digest 목록으로 시작하고, 측정 결과로 턴 구간 단계를 더할지 정한다.
