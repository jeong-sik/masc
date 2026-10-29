---
rfc: "0476"
title: "Keeper checkpoint 를 참조로 저장한다: media 는 blob 으로, history 는 턴 묶음으로"
status: Draft
created: 2026-10-28
updated: 2026-10-29
author: vincent
related: ["36690", "46396", "46541", "0265"]
---

# RFC-0476 — Keeper checkpoint 를 참조로 저장한다

## 0. 요약

Keeper 의 agent-core checkpoint 는 저장할 때마다 history 전체를 다시 쓰고, 읽는 쪽 대부분도 매번 전체를 읽는다. 가장 큰 Keeper 는 179MB 파일을 tool 라운드마다 세 번 새로 쓴다. 기동 때는 약 500MB 를 다 읽는다. #36690(쓰기)과 #46396(읽기)이 같은 원인이다.

이 RFC 는 컴팩션 없이 고친다. 모델이 보는 내용은 바뀌지 않는다. 바뀌는 것은 디스크에 놓는 방식이다. 모양은 Git 객체 저장소를 따른다(§3.1).

1. **media 바이트는 언제나 참조로 둔다.** 이미지·문서·오디오 바이트는 blob 저장소에 한 번만 쓰고, history 에는 digest 만 남긴다. 설명을 새로 만들지 않는다. 바이트가 필요한 곳은 resolver 하나로 되돌린다.
2. **history 는 턴 묶음과 작은 head 로 둔다.** 닫힌 턴은 묶음 파일 하나다. 진행 중인 턴은 메시지 파일 하나씩 쓰다가, 턴이 닫히면 묶는다. head 에는 나머지 필드와 묶음·메시지 digest 목록만 둔다. 어떤 편집이든 새 head 하나로 표현되고, 바뀌지 않은 묶음은 다시 쓰지 않는다.

둘 다 checkpoint 형식을 바꾼다. media 참조는 `checkpoint_version` 16 으로 먼저 배포됐다(L1-1·L1-2). head 와 객체는 17 로 한 번 더 하드컷한다(D7). 하드컷마다 모든 Keeper 의 agent-core history 는 새로 시작한다(D1, 결정됨).

| 순서 | 내용 | 성공 기준(§8) |
|---|---|---|
| L0 | 측정 계기와 bench. 형식은 바꾸지 않는다 | 아래 기준을 전후로 잴 수 있다 |
| L1-1·L1-2 | 형식 v16 하드컷: history·provider media 타입 분리, media 를 참조로 저장. 병합·배포됐다 | inline media 0바이트 |
| L1-3~L1-5 | 형식 v17 하드컷. native stack 하나로 들어간다: head 와 객체, store 쓰기·읽기, head 로 읽기, 객체 정리 | tool 라운드당 쓴 바이트가 지난 턴 크기와 무관. 기동 `transcript_tail` 과 대시보드 `shell_light` 시간이 절반 이하 |
| L2 | 보관 snapshot 을 head 사본으로 바꾸고, 정리 경로를 head 를 따라가게 한다 | 보관 사본 때문에 늘어나는 디스크 0 |

## 1. 측정 (2026-10-28, 라이브 상태)

- **checkpoint 전체:** canonical checkpoint 35개, 합계 502MB 다. 기동 tail 복구가 읽는 파일이 이것이다.
  - 처음 #46541 에 적은 578MB 는 trace 폴더 40개에서 가장 새 snapshot 을 하나씩 합친 값이다. 잰 시각이 다르고, canonical 이 없는 폴더 5개도 들어 있다.
  - inline media 는 144MB(29%)이고, media 를 가진 Keeper 는 5명이다.
- **가장 큰 Keeper:** `msx-retro-mania`(`trace-1788882319100-00000`)는 179MB 다.
  - 메시지 9,017개 중 이미지 1,502장이 121MB(67%)다.
  - 이미지는 모두 `masc_dos_screen` 의 640×480 PNG 이고, base64 로 `tool_result` 안에 들어 있다.
  - 같은 화면이 다시 찍혀 중복된 이미지가 27MB 다(1,572장 중 서로 다른 것 1,236장).
- **메시지 크기:** 다른 Keeper 는 글자만으로 크다.
  - 둘째로 큰 것은 37MB 인데 media 가 없고 메시지가 15,940개다.
  - media 를 뺀 메시지 하나는 중앙값 1.3KB, p90 6.9KB, p99 24.9KB 다(전체 130,653개).
- **턴 크기:** user 메시지를 경계로 나누면 턴은 4,373개다.
  - 턴 하나는 중앙값 52KB, p90 207KB, p99 649KB, 최대 4.5MB 다.
  - 메시지 수로는 중앙값 14개, 최대 3,341개다.
  - Keeper 하나의 턴은 최대 525개다.
- **쓰기:** 04:33:37~38Z 사이 1.2초 동안 msx-retro-mania 가 179MB 를 세 번 새로 썼다. #36690 의 10-07 측정에서는 3시간 동안 저장 7,781번, `canonical_bytes` 합계 297GB 였다.
- **보관 snapshot:** 3개의 inode 가 서로 다르다. canonical 을 rename 으로 갈아 끼워서 hardlink 가 예전 내용을 따로 붙잡는다.
- **읽기:**
  - 기동 단계 `transcript_tail` 이 6.3초 걸렸다(#46541).
  - 대시보드 `shell_light` 새로 고침은 평소 5~7초, 길게는 19.9초다.
  - 25초 `sample` 에서 CPU 를 가장 많이 쓴 것은 worker domain 의 Yojson 긴 문자열 해석이다. 호출자는 unwinder 가 잃어서 확인하지 못했다.

## 2. 2026-10-28 의 코드가 하는 일

줄 번호는 2026-10-28 main(`d7d97a28b41`) 기준이다. 맥락 없는 적대 리뷰가 §2 의 인용을 다시 확인했다.

### 2.1 저장

- tool 라운드마다 세 단계에서 checkpoint 전체를 새로 만든다. 위치는 packages/agent_core/lib/pipeline/pipeline.ml:375, :504, :551 이다. 턴 끝에 `finalize` 저장이 한 번 더 있다.
- store 는 바뀌지 않은 메시지의 인코딩을 재사용하지만, 파일은 매번 전부 쓴다. `save_encoded_durable_atomic_from` 이 임시 파일에 쓰고 fsync 한 뒤 `<trace>/<trace>.json` 으로 rename 한다(lib/keeper/keeper_fs.ml:603, lib/keeper/keeper_checkpoint_store.ml:16-17).
- 저장마다 canonical 을 `agent-core-snapshot-<ms>.json` 으로 hardlink 하고 최근 N개만 둔다. N 은 `keeper.checkpoint_history_retained` 이고 기본값 3이다(lib/runtime_settings.ml:250).
- 모든 저장은 store 의 encoder 세 곳 중 하나를 지난다.
  - 일반 저장(keeper_checkpoint_store.ml:2205)
  - CAS 저장 `save_agent_core_if_source`(:1719)
  - exact snapshot 을 만드는 `exact_snapshot_of_value`(:1413)

### 2.2 history 는 덧붙기만 하지 않는다

- 한 tool 라운드 안에서는 덧붙이기만 한다.
- 끝부분을 고치는 경우가 있다.
  - 거절된 응답을 버린다(keeper_turn_driver_try_provider.ml:3213).
  - 턴 마무리 때 끝의 assistant 메시지를 버리거나, 그 Text 를 그 자리에서 고친다(keeper_replay_checkpoint.ml:143-251).
- 중간에 끼워 넣는 경우도 있다. 턴 시작 때 `close_open_cycles` 가 닫히지 않은 tool 호출의 닫는 메시지를 history 중간에 넣는다(lib/keeper/keeper_transcript_unit.ml:388).
- purge 는 옛 tool 결과 본문을 비우고, history clear 는 대부분을 지운다.

### 2.3 읽기

- 턴마다 history 전체를 history 로 쓴다. 같은 프로세스가 마지막에 쓴 파일이면 메모리 사본을 다시 쓰고, 아니면 전부 다시 읽는다.
- exact snapshot 을 읽는 쪽은 매번 파일 전체를 읽고 SHA-256 을 계산한다. Librarian, continuation, 기동 tail 복구가 여기에 해당한다. 비교 대상인 `expected_source_ref` 가 파일 전체의 해시이기 때문이다.
- Librarian continuity 는 덮은 메시지마다 `message_to_json` 을 해시해서 앞부분이 그대로인지 본다(lib/librarian_continuity_snapshot.ml:227).
- 메시지 개수만 필요한 heartbeat 와 `keeper_status` 도 캐시가 없으면 전체를 읽는다(store.ml:752-771). 대시보드 checkpoint 목록은 보관 snapshot 마다 전체를 해석한다.

### 2.4 provider 요청에 실리는 범위

- 요청은 `choose_range_start` 가 고른 메시지부터 끝까지 싣는다. 바이트 상한은 없다. 요청 크기 상한은 기록만 한다(keeper_turn_driver_try_provider.ml:1737-1742).
- demotion 은 이미지가 든 tool 결과를 건너뛴다(lib/keeper/keeper_model_input_demotion.ml:145-160).

### 2.5 media 바이트를 읽는 곳과 저장소를 비켜 가는 곳

- `masc_dos_screen` 은 `[Text json; Image base64]` 를 돌려준다(lib/dos_tools/dos_machine_tools.ml:429-438). `Tool_projection` 은 글자만 blob 으로 빼고 `content_blocks` 는 그대로 붙인다(lib/tool_projection/tool_projection.ml:407, :428).
- vision eviction(lib/keeper/keeper_context_core.ml:64-71)은 두 가지 제한이 있다.
  - 이미지를 받는 runtime 이 레인에 없을 때만 동작한다.
  - `ToolResult` 안의 이미지는 그대로 둔다(lib/keeper/keeper_vision_ingest.ml:235).
  - 중간 저장, finalize, CAS 저장도 이 자리를 지나지 않는다.
- `keeper_image_read` 는 kept 저장소에 쓰고 inline 으로도 넣는다(lib/keeper/keeper_image_read.ml:62, :80-82).
- checkpoint codec 은 media `source` 의 type 을 `base64`·`url`·`file_id` 셋으로 고정한다(packages/agent_core/lib/checkpoint_contract.ml:565). `checkpoint_version` 은 15 다.
- 요청 범위 밖에서 media 바이트를 읽는 곳이 있다.
  - text 전용 후보를 위한 이미지 위임과 media 읽기는 run 전에 checkpoint 전체를 훑는다(keeper_turn_driver.ml:1261-1294, :1349-1364, keeper_media_reading.ml:349).
  - official client 는 history 를 외부 CLI 로 보낸다(keeper_official_client_context_projection.ml:22, codec.ml:72-86).
  - Librarian 입력 캡처 codec 도 세 source 만 받는다(keeper_librarian_input_capture.ml:10-12).
  - metrics 는 `String.length data` 로 크기를 잰다(keeper_wake_telemetry.ml:53, keeper_agent_prompt_metrics.ml:353).

## 3. 설계

### 3.1 원칙과 선배들

- media 바이트는 history 안에 두지 않는다. 언제나 참조다. 설명을 만들어 대신 두지 않는다. 도구가 함께 돌려준 텍스트는 지금처럼 남는다(예: `masc_dos_screen` 의 `screen_text`).
- 모델이 보는 것은 바꾸지 않는다. 요청 범위, demotion, degrade 규칙은 그대로다.
- 모양은 Git 객체 저장소를 따른다.
  - Git 은 content-addressed 객체를 쓰고, 아직 묶지 않은 객체(loose)를 나중에 packfile 로 묶는다.
  - ref 는 객체를 다 쓴 뒤에 바꾼다.
  - 정리는 ref 에서 닿는 객체만 남긴다.
  - 여기서는 진행 중인 턴의 메시지가 loose 객체, 닫힌 턴의 묶음이 pack, head 가 ref 다.
- LangGraph 의 Postgres checkpointer 도 같은 생각이다. 상태 key 마다 버전별 blob 을 따로 두고, checkpoint 행에는 버전 목록만 둔다. 그래서 바뀐 key 만 쓴다.

### 3.2 배치

```
<session_dir>/<session_id>.json         head: 작은 머리 필드 + 머리 객체 digest + 마지막 segment + 최근 turns + open
<session_dir>/objects/<aa>/<sha256>     닫힌 턴 묶음, 진행 중 턴의 메시지 하나, 머리 객체(tools, system_prompt), turn segment
<base>/.masc/tool_blobs/<aa>/<sha256>   media 바이트 (기존 Tool_blob_store)
```

- 객체는 `Tool_blob_store.put_durable` 과 같은 방식으로 쓴다. 임시 파일에 쓰고, rename 하고, 디렉터리를 fsync 한다. 읽을 때 digest 를 검사한다. 같은 이름의 파일이 있어도 다시 쓴다. 실패한 저장이 남긴 파일은 디렉터리 항목이 sync 되지 않았을 수 있어서다(#46791).
  - 내구성은 그 쓰기 함수가 주는 만큼이다. 프로세스가 죽어도 남는다. macOS 의 `fsync` 는 디스크 캐시까지 비우지 않아서, 전원이 끊길 때도 남는지는 `Fs_compat` 의 `F_FULLFSYNC` 사용 여부를 따른다.
- head 는 지금 checkpoint 파일과 같은 경로에 둔다. 경로만 쓰는 곳은 그대로다.
- 객체 digest 는 codec 이 만든 바이트의 SHA-256 이다. 그래서 인코딩이 결정적이어야 한다. 필드 순서를 고정하고, 실수 표기도 하나로 정한다(`0.0`/`-0.0` 같은 함정은 `prefix_digest` 주석에 이미 적혀 있다). `encode (decode bytes) = bytes` 를 시험으로 고정한다.
- 메시지 객체의 바이트는 checkpoint codec 이 그 메시지 하나를 검증하고 인코딩한 바이트다.
- 묶음은 JSON 머리 한 줄 `{"messages":[{"sha256":..,"bytes":n},...]}` 뒤에 메시지 바이트를 한 줄에 하나씩 둔 것이다. compact JSON 에는 줄바꿈 문자가 없으므로 파일 전체가 JSON lines 로 읽힌다. 그래서 blob 정리의 파일 훑기와 운영자의 `jq` 가 그대로 읽는다. 읽을 때 파일 전체의 SHA-256 이 객체 이름과 같은지, 머리가 말한 조각마다 SHA-256 이 같고 줄로 끝나는지 확인한다. 메시지를 다시 인코딩하지 않는다.
- head 는 `{"format":"masc.checkpoint.head","checkpoint":{..},"header_objects":{"system_prompt":d,"tools":d},"history":{"segment":null|{"segment","messages","chain"},"turns":[{"bundle","messages","chain"}],"open":[..]}}` 다.
  - `checkpoint` 는 메시지와 머리 객체 두 필드(`system_prompt`, `tools`)를 뺀 나머지 필드이고, 메시지 목록은 비어 있어야 한다.
  - 머리 객체는 그 필드의 JSON 값(compact)을 바이트로 한 객체다. 값이 이전 head 와 같으면 다시 쓰지 않는다.
  - turns 에는 묶음마다 메시지 수와, 묶음이 끝나는 자리의 해시 체인 값을 담는다(§3.5).
  - 닫힌 턴이 64개 모이면 그 64개를 turn segment 객체 `{"previous":null|d,"turns":[..]}` 로 쓰고 head 에서 뺀다. segment 는 바로 앞 segment 의 digest 를 든다. head 의 `segment` 는 마지막 segment 의 digest, 거기까지의 메시지 수, 그 자리의 chain 값이다. 그래서 head 에는 닫힌 턴이 63개까지만 남는다.
- checkpoint ref 의 digest 는 내용 digest 다. 고정 태그, `{"checkpoint":..,"header_objects":..}`(head 에 쓰는 그대로), 모든 메시지에 대한 `chain(n)` 을 이어 붙인 것의 SHA-256 이다. 턴을 어떻게 나눴든 값 하나에 하나다. 그래서 값으로 만든 ref 와 그 값을 쓴 head 의 ref 가 같고, 둘 다 객체를 읽지 않고 계산한다. `Keeper_checkpoint_ref` 의 모양은 바뀌지 않는다.
- exact snapshot 은 바이트를 들고 다니지 않는다. 값과 ref 만 든다. 저장(정상 저장, CAS, accepted-checkpoints)은 잠금 안에서 그때의 canonical head 를 읽고, 그 history 를 기준으로 배치를 정한다.
- 턴 경계는 Keeper 턴이다. 턴 마무리(`finalize`) 저장 때 `open` 의 메시지를 묶음 하나로 묶고, 그 digest 를 `turns` 에 붙인다.
- **head 크기:** v17 head 를 라이브에서 재 보니(2026-10-29 20:16 KST, 턴 0개, open 3개) 202,522바이트였다. `tools`(도구 schema 38개)가 112,422, `system_prompt` 가 88,468, history 가 222바이트였다. 저장마다 head 를 다시 쓰므로 라운드(저장 세 번)마다 약 600KB 를 같은 내용으로 다시 썼다. 닫힌 턴은 턴마다 약 166바이트씩 쌓였다. 그래서 두 필드를 머리 객체로 빼고 닫힌 턴을 segment 로 묶는다(D8). 이제 head 는 작은 머리 필드, 닫힌 턴 63개 이하(약 10KB), `open` 만 든다. `open` 은 진행 중인 턴의 메시지 수를 따른다(중앙값 14개, 최대 3,341개면 약 224KB).

### 3.3 저장

1. 새 객체를 먼저 내구화한다. 진행 중 턴의 새 메시지, 턴이 닫히면 그 묶음, 새 media blob 이다.
2. 그다음 head 를 지금처럼 임시 파일·fsync·rename·디렉터리 fsync 로 바꾼다.

이 순서라서 head 는 언제나 이미 내구화된 객체만 가리킨다.

- 진행 중인 턴의 끝을 고치면 그 메시지 객체만 새로 생긴다(응답 버리기, Text 고치기).
- 저장은 이전 head 의 턴을 앞에서부터 보면서, 그 턴이 끝나는 자리의 chain 값이 새 메시지 목록의 같은 자리 값과 같은 동안 그 턴을 그대로 둔다. 마지막 segment 도 같다. 그 자리의 chain 이 같으면 segment 와 그 앞의 모든 segment 를 그대로 두고, 다르면 segment 에 든 턴부터 뒤의 메시지는 모두 새로 쓴다. 저장은 segment 객체를 읽지 않는다.
- 닫힌 턴 중간을 바꾸면(`close_open_cycles`, purge, history clear) 그 턴부터 뒤의 메시지는 모두 open 으로 돌아가고, 다음 턴 마무리 저장 때 묶음 하나로 다시 쓰인다. 바뀐 턴 하나만 다시 쓰는 것보다 더 쓴다. 이런 저장이 얼마나 자주 일어나는지는 아직 재지 않았다.
- purge 는 내용을 지우려는 운영자 의도라서, 옛 묶음을 가리키는 보관 head 도 함께 지운다.

**참조로 바꾸는 자리.** media 가 history 에 들어오는 순간 바꾼다. 저장할 때 바꾸면 메모리의 history 는 `Base64`, 다시 읽은 history 는 `Stored` 가 된다. 그러면 같은 대화가 프로세스 안팎에서 다른 모양이 되고, 앞부분 비교가 재시작마다 어긋난다.
- 들어오는 곳은 다음과 같다. history 타입에 `Base64` 가 없으므로(D5) 컴파일러가 나머지를 찾아 준다.
  - tool 결과(`Tool_projection.to_agent_core_typed_result` 의 `content_blocks`)
  - 사용자가 첨부한 media(keeper_multimodal_input.ml:625-637, :685-692)
  - 레인 add-on MCP 의 media(keeper_lane_addon_runtime.ml:15-21)
  - `keeper_image_read`, 검증 도구의 렌더 페이지
- history 타입에는 `Base64` 가 없으므로, store 의 encoder 세 곳(§2.1)이 바꾸거나 거절할 일이 없다.

**exact ref.** `expected_source_ref` 와 accepted-checkpoints, Gate 의 `canonical_checkpoint_bytes` 는 head 바이트가 된다. head 가 모든 객체 digest 를 담으므로 history 전체를 가리키는 값이다. 비교 비용은 head 크기를 따른다.

### 3.4 media 참조와 resolver

**타입(D5).** history 의 media 와 provider 로 가는 media 를 다른 타입으로 둔다.
- history 쪽 media 는 `Stored of { sha256 : string; bytes : int }` 하나뿐이다.
- provider 쪽 media 는 지금의 `Base64`·`Url`·`File_id` 를 payload 를 가진 합타입으로 둔다. 지금처럼 `source_type` 이 `data` 의 뜻을 정하는 모양은 버린다.
- 둘 사이는 resolver 만 건넌다. 그래서 backend 에 `Stored` 가 가는 상태도, history 에 `Base64` 가 남는 상태도 컴파일되지 않는다.

**resolver 는 하나다.** `Stored` 를 바이트로 되돌리는 함수 하나를 둔다. blob 이 없으면 typed 오류다. 그 이미지를 조용히 빼지 않는다. 부르는 자리는 아래와 같다. 타입이 바뀌면 컴파일러가 빠짐없이 찾아 준다.
- provider 요청: 범위 안 메시지만 되돌린다. backend 와 tool 결과 media projector 보다 앞이다.
- 이미지 위임과 media 읽기(text 전용 후보): 지금처럼 범위 밖까지 읽는다. 읽는 이미지마다 되돌린다.
- official client: 외부 CLI 로 보내기 전에 되돌린다.
- Librarian 입력 캡처: codec 이 `Stored` 를 받는다. 바이트가 필요한 곳에서만 되돌린다.
- metrics: `Stored.bytes` 로 원래 크기를 센다. 되돌리지 않는다.

### 3.5 읽기

- 메시지 개수(heartbeat, `keeper_status`)는 head 로 답한다. 묶음마다 메시지 수를 head 에 같이 둔다.
- 대시보드 checkpoint 목록은 보관 head 만 읽는다. 미리보기는 마지막 객체 하나만 읽는다.
- Librarian 과 continuation 의 앞부분 비교는 해시 체인으로 한다. 지금의 `prefix_digest` 는 덮은 메시지의 JSON 을 이어 붙인 한 덩어리의 SHA-256 이라서(lib/librarian_continuity_snapshot.ml:227), 묶음 digest 로는 만들 수 없다. 턴 중간까지 덮은 경우도 비교할 수 없다.
  - 정의: `chain(0) = SHA-256("masc.rfc-0476.chain.v1")` 이고, `chain(i+1) = SHA-256(hex(chain(i)) ‖ hex(digest(message i)))` 다. 저장도 hex 로 한다.
  - 앞부분 k 개의 값은 `chain(k)` 다. head 에 있는 "k 바로 앞 묶음의 끝 체인 값"에서 시작해, 그 묶음 머리의 메시지 digest 를 k 까지 이어 계산한다. 메시지를 다시 인코딩하지 않는다.
  - Librarian continuity snapshot 은 `prefix_sha256` 대신 `chain(k)` 를 저장한다. 옛 snapshot 은 하드컷 때 버려진다(§3.7). 임의의 k 에서 두 방법(전체 history 를 처음부터 잇기, head 와 묶음에서 이어 계산하기)이 같은 값을 내는지 시험으로 고정한다.
- 턴 하나를 쓰는 history 읽기는 지금처럼 전체를 메모리에 올린다. 다만 media 를 빼면 msx-retro-mania 가 179MB 에서 약 58MB 가 된다. 같은 프로세스 안에서는 메모리 사본을 그대로 쓴다.
- 기동 tail 복구는 마지막 묶음과 진행 중 턴만 읽어도 되는지 `close_open_tail` 의 규칙을 확인해서 정한다. 이 RFC 에서 약속하지 않는다.

### 3.6 정리와 기준점

정리는 두 가지다. media blob 정리와 checkpoint 객체 정리다. 둘 다 쓰는 쪽이 없을 때, BasePath lease 를 잡고만 돈다. 그래서 "이미 있으니 안 쓴다"와 "아무도 안 가리키니 지운다"가 같은 시각에 일어나지 않는다. 저장은 같은 이름의 파일이 있어도 객체를 다시 쓴다(§3.2). 크래시로 잘린 파일이나 sync 되지 않은 디렉터리 항목을 믿지 않는다.

**media blob 정리.** `Tool_blob_maintenance` 가 배포 사전 점검 때(서버 정지 중) 돈다. 이 인터페이스는 참조를 저장하는 변경과 같은 변경에서 consumer 를 등록하라고 요구한다.
- `.masc` 아래 등록된 파일을 모두 JSON 으로 해석해서 `Stored` digest 를 모은다. 파일 내용을 문자열로 훑지 않는다.
- 메시지 객체, 묶음, 머리 객체, segment 는 모두 JSON 으로 읽힌다. 그래서 그 안의 `Stored` 참조가 그대로 기준점이 된다. 아직 지우지 않은 객체도 훑으므로 blob 은 그 객체가 지워질 때까지 남는다.
- official client session store 가 저장한 history 도 기준점이다.
- purge 와 Keeper 별 삭제는 "어느 head 에서도 닿지 않게 만드는 것"이다. blob 저장소는 전역이라 서로 다른 Keeper 의 같은 바이트가 한 파일을 함께 쓴다. 그래서 파일은 다음 정리 때 지워진다. purge 를 기록하는 쪽은 "닿지 않게 된 시각"과 "파일이 지워진 시각"을 따로 적는다.

**checkpoint 객체 정리.** `Keeper_checkpoint_object_sweep` 이 서버 기동 때 돈다.
- 도는 때는 서버가 BasePath lease 를 쥔 뒤, 스케줄러와 Keeper 가 시작하기 전이다. accepted-checkpoints 정리(`Keeper_retained_checkpoint_sweep`) 바로 뒤다. 그때는 세션을 읽거나 쓰는 쪽이 없다. 그래서 head 는 잠금 안에서, 객체는 잠금 밖에서 읽는 `decode_changed_bytes` 와도 겹치지 않는다.
- 배포 사전 점검에서는 돌리지 않는다. 배포 뒤에는 늘 기동이 따른다.
- 세션마다 기준점 head 가 닿는 객체를 남기고 `objects/` 의 나머지를 지운다. 지울 후보를 적어 두었다가 다음 번에 지우는 두 단계는 두지 않는다. 기준점이 다 모였으면 닿지 않는 객체를 다시 찾는 읽기는 없다.
- 기준점(root)은 다음과 같다.
  - canonical head `<session>/<session_id>.json`
  - 보관 head `<session>/agent-core-snapshot-*.json`
  - `<session>/accepted-checkpoints/*.json`
  - Keeper chat-operations SQLite 에 Gate 준비가 든 `Prepared_agent_core` head. 세션은 그 reference 의 trace id 다.
  - journal 준비 도구가 `upgrades/journal-inputs/<id>/checkpoint.json` 에 복사한 head. 세션은 head 의 session id 다.
- head 에서 닿는 객체는 head 가 직접 가리키는 것(머리 객체, 마지막 segment, 그 뒤의 묶음, 열린 메시지)과, 마지막 segment 부터 `previous` 를 따라가며 만나는 segment 와 그 묶음이다. `walk_segments` 가 이 순서로 읽는다.
- `checkpoint_version` 이 더 낮은 head 는 기준점이 아니다. 이 binary 는 그 head 를 다시 읽지 않는다(§3.7). 그래서 하드컷 뒤 첫 기동이 이전 버전의 객체를 지운다.
- 기준점을 하나라도 읽지 못하면 아무것도 지우지 않는다. 해석되지 않는 head, 더 높은 버전의 head, 끝까지 따라갈 수 없는 segment, 읽지 못한 Keeper store 도 같다. 그 head 가 무엇을 가리키는지 모르기 때문이다. 이유는 기동 로그에 남는다.
- `objects/<aa>/<sha256>` 모양이 아닌 항목은 건드리지 않는다.
- 진행 중 턴의 메시지 객체는 턴이 닫혀 묶음으로 다시 쓰인 뒤 다음 기동 때 지워진다. 그때까지 쌓이는 양은 서버가 한 번 뜬 동안 쓴 객체 수다.
- 기동에 더해지는 비용은 기준점 head 와 segment 읽기, `objects/` 목록 읽기다. 걸린 시간을 기동 로그에 남긴다.

### 3.7 하드컷

- media 참조는 `checkpoint_version` 16 으로 들어갔다(L1-2b, #46729). head 와 객체는 17 로 올렸다(D7, #46776, 2026-10-29 20:11 KST 라이브). 머리 객체와 turn segment 는 18 로 올린다(D8). 이전 파일은 지금도 있는 `Superseded` 로 읽혀서, 각 Keeper 의 다음 턴은 새 history 로 시작한다(lib/keeper/keeper_run_context.ml:127).
- 호환 reader 나 변환 코드는 만들지 않는다.
- Librarian continuity snapshot 은 이전 history 를 가리키므로 함께 버려진다. Keeper 대화 기록(`keeper_chat`), Librarian 기억, 게시판은 그대로다.

## 4. 고려했다 버린 것

- **객체를 SQLite 에 담기.** OpenAI Agents SDK 의 `SQLiteSession` 처럼 DB 에 두는 방식이다. 같은 객체·head 모델을 DB 행으로 담을 수 있으므로 "값 하나 = 해시 하나"는 어느 쪽이든 지켜진다. 고르는 것은 그릇이다(D6).
  - 얻는 것: 객체와 head 를 transaction 하나로 commit 한다. checkpoint 객체 정리를 서버를 켠 채로 할 수 있다.
  - 잃는 것:
    - media 는 여전히 파일이라 그릇이 둘이 된다.
    - 쓰는 쪽과 읽는 쪽이 잠금을 다툰다. chat-operations 저장소는 SQLITE_BUSY 로 chat 이 막힌 적이 있다(keeper_chat_operation_store.ml:722-727 주석).
    - 지워도 파일이 줄지 않아 공간 회수 작업이 하나 더 생긴다.
    - 운영자가 jq·rg 로 바로 볼 수 없다.
  - fsync 도 크게 줄지 않는다. masc 의 SQLite 규약은 `journal_mode=DELETE`, `synchronous=EXTRA` 라서 commit 한 번에 fsync 를 여러 번 한다(:728-738).
  - "바뀌지 않는 객체를 먼저 쓰고 head 를 마지막에 rename" 하면 한 번에 commit 하는 것과 같은 보장을 얻는다. Git 과 `Tool_blob_store` 가 쓰는 방식이다.
- **append-only 연산 로그.** 메시지 splice 연산을 덧붙이는 방식이다. 처음부터 재생해야 하고 로그를 접는 일이 따로 필요하다.
- **메시지마다 파일 하나.** 약 13만 개 파일이 생기고, head 가 메시지 수만큼 커진다. 사용자 판단(D2)대로 닫힌 턴을 묶는다.
- **진행 중인 턴도 묶음 하나로 다시 쓰기.** 메시지 3,341개 턴에서는 그 턴 안에서만 GB 단위를 쓴다. 그래서 진행 중인 턴은 loose 객체로 둔다.
- **컴팩션, 이미지 설명 생성, URL 참조, Vision artifact 저장소.**
  - 컴팩션은 모델이 보는 것을 바꾼다.
  - 설명 생성은 사용자 결정으로 하지 않는다.
  - URL 은 로컬 이미지를 밖에 공개해야 한다.
  - Vision frames 는 500개·20MB 를 넘으면 mtime 순으로 지워서, 참조가 끊길 수 있다.

## 5. 순서

1. **L0.**
   - 저장마다 쓴 바이트, 읽기마다 읽은 바이트, 기동 단계 시간을 같은 이름으로 남긴다.
   - checkpoint 저장·읽기 bench 를 `test/` 에 둔다. 지금 형식으로 먼저 잰다.
2. **L1-1·L1-2, v16.** 병합·배포됐다.
   - L1-1(#46651): media 를 payload 합타입으로 싣는다. 동작은 바뀌지 않는다.
   - L1-2a(#46728): media 를 참조로 드는 history 타입(D5).
   - L1-2b(#46729): history 와 checkpoint 가 media 를 참조로만 들고, 바이트는 resolver 로 되돌린다(§3.4). 리뷰 지적은 #46738, #46758 로 고쳤다.
3. **L1-3, v17.** 병합됐다(2026-10-29). L1-4·L1-5 보다 먼저 들어가서, 배포하면 정리 없이 하드컷이 일어난다.
   1. L1-3a(#46775): agent_core `Checkpoint_objects`. 저장 계획, head·묶음 인코딩, chain, 읽기. I/O 는 하지 않는다. 쓰지 않는 delta API 와 `Agent_core.Checkpoint_store` 를 지운다.
   2. L1-3b(#46776): Keeper store 와, store 밖에서 checkpoint 바이트를 다루는 곳. 객체 쓰기, head 쓰기, 턴 마무리 저장(`Turn_closes`) 인자, CAS 경로, 보관, accepted-checkpoints, v17. exact snapshot 이 바이트를 들지 않게 되므로 바이트를 비교하거나 풀던 곳(Gate, journal 준비, history clear, input history cut, input wait response, semantic execution, 대시보드 purge, bin 도구)이 같은 층에서 바뀐다. bench 를 턴 단위 저장으로 바꾼다.
   3. 리뷰 수정(#46790, #46791): purge 백업은 head 와 객체를 세션 경로 그대로 복사한다. head 만 해석한 저장은 객체가 있는지 보고 없는 것을 다시 쓴다. CAS 출처 확인은 head 를 늘 읽는다.
4. **L1-4: head 로 읽기(§3.5).**
   1. L1-4a(#46795): `plan_save` 와 load 가 메시지마다의 chain 값을 memo 에 남기고, 다음 저장은 물리적으로 같은 앞부분의 값을 이어 쓴다. 16000 메시지에서 라운드 저장이 메시지 수에 비례하지 않게 된다.
   2. L1-4b(#46802), v18: 머리 객체와 turn segment(D8). head 크기가 머리 필드의 크기와 턴 수에 따라 늘지 않는다.
   3. 개수·미리보기, Librarian `chain(k)`.
5. **L1-5: 객체 정리와 기준점(§3.6).**
   1. L1-5a: 기동 때 객체 정리. Keeper 가 시작하기 전에 돌아서, 잠금 밖에서 객체를 읽는 `decode_changed_bytes` 와 겹치지 않는다.
   2. L1-5b: purge 가 옛 묶음을 가리키는 보관 head 도 지운다. 그 전에는 purge 한 내용의 객체가 보관 head 가 바뀔 때까지 남는다.
6. **L2.** 보관 snapshot 을 head 사본으로 바꾸고, 정리를 head 를 따라가게 한다.

## 6. 하지 않는 것

- 요청 범위·demotion·degrade 규칙 변경
- 컴팩션, 요약, 이미지 설명 생성
- `masc_dos_screen` 이 텍스트 모드 화면에서 이미지를 빼는 것(도구 쪽 결정이다)
- Librarian 의 읽기 범위 설계 변경. digest 비교로 바꾸는 것만 한다.

## 7. 위험

- **되돌리기.** v17 을 배포한 뒤 v16 binary 로 되돌리면, 이전 binary 는 v17 head 를 읽지도 쓰지도 못한다.
  - 읽으면 `checkpoint version 17 was written by a later binary; this one reads 16` 오류가 난다(keeper_checkpoint_store.ml:868).
  - 저장은 기존 파일을 읽지 못해 `Existing_checkpoint_unreadable` 로 실패한다(:2255-2264).
  - 되돌릴 때는 `traces/` 를 옮겨 두고 새로 시작해야 한다.
  - 새 binary 가 한 번 기동하면 객체 정리가 이전 버전 head 의 객체를 지운다. 그 뒤 이전 binary 로 되돌려도 그 head 는 객체가 없어 읽히지 않는다. 되돌리는 방법은 위와 같다.
- **fsync 횟수.** 저장 한 번에 새 객체 1~3개와 head 를 fsync 한다. 작은 파일 여러 번이 179MB 한 번보다 느린지는 L0 bench 로 잰다.
- **정리 오류.** 기준점이 빠지면 쓰는 blob 이나 객체를 지운다.
  - blob 이 지워지면 그 이미지가 범위에 들어온 요청은 typed 오류로 실패하고, 범위 시작이 그 뒤로 넘어갈 때까지 계속 실패한다.
  - 객체가 지워지면 그 head 는 `Objects_invalid` 로 읽히지 않는다.
  - 그래서 기준점은 §3.6 목록을 시험으로 고정하고, 정리는 쓰는 쪽이 없을 때만 한다. blob 은 서버 정지 중에, 객체는 기동 때 Keeper 시작 전에 정리한다.
- **다른 프로세스.** 객체를 head 보다 먼저 내구화하므로, CLI 가 읽은 head 가 가리키는 객체는 언제나 있다.
- **하드컷.** 배포 때 모든 Keeper 의 agent-core history 가 새로 시작한다(D1 에서 받아들였다).

## 8. 측정 방법

- 저장: `checkpoint_save` 로그의 `canonical_bytes` 와, L0 에서 더하는 실제로 쓴 바이트. tool 라운드당 합을 본다.
- 크기: inline media 바이트와 checkpoint 크기. §1 과 같은 읽기 전용 스크립트를 쓴다.
- 기동: `keeper_persistence_prepare: stage=transcript_tail elapsed_seconds`.
- 대시보드: `dashboard_snapshot heavy refresh: component=shell_light elapsed_s`. 같은 시간대 30분의 중앙값을 비교한다.
- CPU: 25초 `sample` 의 `caml_lex_engine` 몫.
- 디스크: `~/me/.masc/traces` 와 `tool_blobs/` 합계.

## 9. 결정

- **D1. 하드컷.** 결정됨(2026-10-28, 사용자). Keeper 의 agent-core history 가 새로 시작해도 된다.
- **D2. 묶음.** 결정됨(2026-10-28, 사용자 판단 "묶어야"). 닫힌 턴은 묶고, 진행 중인 턴은 메시지 객체로 둔다.
- **D3. 문서·오디오.** 결정됨(2026-10-28, 사용자). 같은 참조 규칙에 넣는다.
- **D4. head 단계.** D2 로 풀렸다. head 는 턴 묶음 목록이다.
- **D5. 타입 경계.** 결정됨(2026-10-28, 사용자). history 의 media 와 provider 로 가는 media 를 다른 타입으로 둔다. backend 에 `Stored` 가 가는 상태도, history 에 `Base64` 가 남는 상태도 표현할 수 없다. agent_core 의 메시지 타입을 쓰는 곳을 모두 바꾸는 비용을 받아들인다.
- **D6. 그릇.** 결정됨(2026-10-28, 사용자). 객체마다 파일 하나와 head 파일 하나로 둔다(§3.2). SQLite 를 버린 이유는 §4 에 있다. L0 bench 에서 파일 방식의 저장 지연이 문제로 나오면 다시 연다.
- **D7. 두 번째 하드컷.** 결정됨(2026-10-29, 사용자). L1-1·L1-2 가 v16 으로 먼저 배포됐으므로, head 와 객체는 `checkpoint_version` 17 로 한 번 더 하드컷한다. L1-3 은 L1-4·L1-5 보다 먼저 병합·배포됐다.
- **D8. 세 번째 하드컷.** 결정됨(2026-10-29, 사용자 "지금 v18 로 줄이기"). v17 head 가 저장마다 머리 필드 약 200KB 를 다시 써서, `tools`·`system_prompt` 를 머리 객체로 빼고 닫힌 턴을 segment 로 묶는다. v17 history 가 생긴 지 몇 분밖에 안 됐을 때 바꾸는 것이 재시작 비용이 가장 작다.
