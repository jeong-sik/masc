# 라이브 서버 live heap 을 누가 쥐고 있나 (2026-10-27)

[RFC librarian-history-original-holds-what-it-read](../../rfc/RFC-librarian-history-original-holds-what-it-read.md) 1.2절의 근거다.

## 대상

- 서버 PID 24546, 바이너리 `eff0a3bd28b`(#46247 하드컷 배포 뒤). 2026-10-27 13:18 KST 기동.
- 측정 시각 13:5x KST(기동 뒤 약 35분). Keeper 42명.

## 방법

`GET /api/v1/diagnostics/memprof`(상시 켜진 `Alloc_profile`, sampling rate 1e-5)를 15초 간격으로 세 번 읽었다. 읽을 때마다 profile 의 이벤트를 비운다. 처음 읽기에는 밀린 이벤트가 있어서 live 표가 1.09 GB 만 보였다. 두 번째와 세 번째는 새로 버린 샘플이 없었고 live 표가 `/health` `gc.live_words` 를 거의 덮었다.

| 읽기 | memprof live | `gc.live_words` × 8 |
|---|---|---|
| 1 | 1.09 GB(밀린 이벤트) | 13.82 GB |
| 2 | 8.69 GB | 9.36 GB |
| 3 | 6.82 GB | 7.44 GB |

`memprof-live-by-site.tsv` 는 2·3번째 읽기의 live 표를 masc 프레임 앞 세 개로 묶은 것이다. 원문 JSON 은 커서 넣지 않았다. 호출 스택 외의 내용(대화 본문, 토큰)은 없다.

## 결과

두 번 모두 live 의 약 70% 이상이 Librarian history original 을 읽는 도중의 데이터였다.

- `Lane_addon_tool_request_owner.request_of_body`(기록 본문 JSON 파싱). 호출자는 `Keeper_librarian_original_gate.current_reading`, `Keeper_librarian_durable_commit.reload`, `load_listed` 다. 2번째 읽기 41%, 3번째 34%.
- `Lane_addon_store.record_bytes`(원본 바이트 읽기와 검증). 약 8~12%.
- `Keeper_librarian_durable_request.parse`·`of_json`, `Keeper_librarian_durable_capture.decode_text`·`json_text`(복원 때 문자열 파싱과 다시 인코딩). 약 19~25%.
- `Agent_core.Checkpoint_codec.of_string_with_encoding_memo`(checkpoint lineage 메모)는 약 2~3%.

## 읽는 법

- live heap 이 몇 초 사이에 7~14 GB 를 오르내리는 것과 맞다. 오래 붙잡힌 상태보다, 처리 중인 Librarian pass 가 큰 기록을 읽어 들고 있는 양이 대부분이다.
- 그래서 동시에 도는 pass 수(Keeper 수)와 기록 크기(대화 길이)가 곱해져 상주 메모리가 된다.
- `GET /api/v1/diagnostics/heap-roots` 는 쓰지 않았다. 등록된 root 는 레지스트리 몇 개뿐이고, 문서대로 fiber 위에만 있는 데이터는 보이지 않는다. 걷는 동안 서버도 멈춘다.
