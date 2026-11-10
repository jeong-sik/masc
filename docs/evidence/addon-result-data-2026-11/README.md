# Add-on 도구 결과가 이미지를 두 번 싣는다 (2026-11)

DOS 화면을 읽는 `masc_dos_screen` 한 번이 도구 호출 장부에 평균 94,820 바이트로 남는다.
거의 전부 PNG 의 base64 이다. 모델은 그 PNG 를 이미지 블록으로 따로 받는다.

## 어떻게 두 번 실리나

`Keeper_lane_addon_runtime.call` 은 Add-on worker 의 답을 두 곳에 넣는다.

- `content_blocks`: 답의 `content` 블록(글 하나, 이미지 하나). 인코더는 `content_blocks` 가 있으면 이것을 도구 결과 전체로 보내고 `content` 문자열은 안 보낸다(`runtime_agent.ml` 의 주석, `backend_openai_serialize.ml` 의 `tool_result_content_string`).
- `data`: 답 전체(`_meta`, `structuredContent`, `isError`, `content`). `Tool_result.message` 가 이 JSON 문자열이다.

그래서 이미지 base64 가 `data` 에도 들어가 `message` 가 레인의 인라인 한도를 넘고, 호출마다 같은 PNG 가 블롭 저장소에 한 번 더 쓰인다. 한도는 레인마다 다르다. agent_core 는 64 KiB(`Common.max_agent_core_inline_result_bytes`), Claude Code 는 32 KiB, 나머지는 16 KiB(`Common.max_tool_result_wire_bytes`)이다(`runtime_execution.ml` 의 `tool_result_inline_ceiling_bytes`). 모델이 읽는 쪽은 안 바뀐다.

## 이 변경이 하는 일

`data_of_worker_result` 가 `data` 의 이미지·오디오 블록을 `{type, mimeType, base64_chars}` 로 줄인다. 바이트는 `content_blocks` 에만 남는다. 글 블록, `structuredContent`, `isError`, `_meta` 는 그대로다. 미디어가 없는 답은 `tool_result_to_yojson` 결과와 같다.

## 기준선 (이 변경이 배포되기 전)

`ledger_result_bytes.py` 로 장부의 2026-11-04T00:00Z ~ 11-09T17:00Z(5일 17시간)를 셌다. 결과 전체는 `before-2026-11-04_11-09T17.json` 이다.

| 항목 | 값 |
|---|---|
| 장부 행(result_bytes 있는 행) | 136,507 |
| 장부 result_bytes 합 | 841,940,544 |
| 블롭으로 나간 행 / 서로 다른 블롭 바이트 | 4,876 / 420,845,113 |
| `masc_dos_screen` 행 / result_bytes 합 | 3,323 / 315,087,992 (장부 합의 37.4%) |
| `masc_dos_screen` 블롭 행 / 서로 다른 블롭 / 바이트 | 3,161 / 2,980 / 287,505,680 (블롭 바이트의 68.3%) |
| `masc_dos_screen` 평균 result_bytes | 94,820 |

- 저장된 화면 결과 하나(104,592 바이트)를 풀면 base64 가 92,980 글자, 나머지가 11.6 KB 안팎이다. 배포 뒤 `masc_dos_screen` 평균은 이 값 근처로 내려가야 한다. 표본이 하나라서 예측일 뿐이고 배포 뒤 다시 잰다.
- 같은 결과의 `structuredContent` 와 `content[0].text` 는 같은 JSON(각 5,607 바이트)이다. `masc_dos_press`·`step`·`type` 의 11.47 KB 는 이 둘 + `_meta` 이다. 이 변경은 이 중복을 건드리지 않는다.

## 배포 뒤에 확인하는 법

```
python3 docs/evidence/addon-result-data-2026-11/ledger_result_bytes.py \
  --base-path ~/me --since <새 부팅 +60초, UTC> --end <지금, UTC> --top 12 --tool masc_dos_screen
```

- `masc_dos_screen` 의 `blob_rows` 가 0 근처, `mean_result_bytes` 가 1만 몇천 바이트이면 맞다.
- 창 안에 이전 빌드 호출이 섞이지 않게 `--since` 를 부팅 뒤로 잡는다.

## 확인한 것

- 오프라인 링크 실행(11-09 04:47Z 스냅숏 `2d9d4c7c9250` 트리에 이 변경을 얹음): 순수 시험 2개 통과(미디어 바이트가 빠지는 것, 미디어 없는 답이 그대로인 것). 변이 8개(이미지 바이트 남기기, 오디오 바이트 남기기, 크기 반으로, 글 블록 비우기, `structuredContent` 지우기, MIME 바꾸기, `content` 통째 지우기, 아무것도 안 하기)를 모두 시험이 잡았다. 실제 worker 를 쓰는 시험에 더한 두 줄은 따로 링크해 통과를 봤다.
- `test_ledger_result_bytes.py` 11개 통과.
- `test_keeper_screen_carries_the_frame`(실제 worker, 구조 사본에 이미지 바이트가 없고 크기만 있는 것) 전체는 돌리지 못했다. PR 이벤트에 걸리는 워크플로는 `pr-type-check`(`dune build @check`), `changelog-fragments`, `approval-merge-request` 셋이다. `@check` 는 `test/` 를 타입 검사하지만 링크도 실행도 하지 않는다(`test.yml` 머리 주석). 이 시험은 야간 `Test` 실행(02:43 KST)이나 운영자가 dispatch 한 `Test`·`leader-ci` 가 돌린다. `test_dos_vision` stanza 에 `mcp_protocol` 을 더했다(`implicit_transitive_deps false`).
- 독립 리뷰(읽기 전용, 별도 컨텍스트)는 `lib/`, `packages/`, `bin/`, `dashboard/`, `test/` 에서 `data` 나 `message` 의 이미지 바이트나 `content[i]` 를 파싱하는 곳을 못 찾았고, 저널이 `data` 와 `content_blocks` 를 같이 저장한다고 보고했다. 이 둘은 리뷰어의 `rg` 와 읽기 결과이고 내가 다시 돌려 보지 않았다.
- 내가 `rg` 로 확인한 것: `content_blocks` 를 읽는 제공자 인코더 파일은 `backend_anthropic.ml`, `backend_openai_serialize.ml`, `backend_openai_responses.ml`, `backend_gemini.ml` 이다. 제공자마다 이미지가 모델에 실제로 닿는지는 실행으로 확인하지 않았다.

## 못 한 것과 모르는 것

- 모델이 받는 글자 수는 안 바뀐다. 줄어드는 것은 장부의 result_bytes 와 블롭 저장소 쓰기이다.
- DOS 화면 블롭을 읽는 곳을 `rg` 로 찾았다(`dashboard/`, `bin/`, `scripts/` 의 `masc_dos`, `lib/server`·`lib/dashboard` 의 `_blob`). DOS 전용으로 읽는 곳은 없다. 놀이 페이지와 관전 경로는 `Machine_addon_host.call_shared` 를 직접 부른다. 장부 행의 블롭을 도구 구분 없이 보여 주는 범용 화면이 있는지는 안 봤다.
- 지금 도는 DOS 레인 이미지는 0.2.2(2026-10-27 빌드)이고 `lane.toml` 은 0.2.3(#50128)이다. 로컬에 0.2.3 이미지가 없다. 그래서 `screen_text` 끝 공백을 떼는 #48519(11-05 병합)가 아직 안 돈다. 저장된 화면 하나는 `screen_text` 2,052 바이트 중 2,000 바이트가 끝 공백이었다. 이미지를 새로 빌드하면 글자 없는 화면(그래픽 모드 게임)에서 모델이 받는 글자가 호출마다 그만큼 준다. 이 PR 은 이미지 빌드와 설치를 하지 않는다.
- `result_bytes` 순위로 컨텍스트 비용을 볼 때 Add-on 도구는 두 번 센 값이다(위 중복).
- 11월 장부(`~/me/.masc/tool_calls/2026-11`, 마지막 행 2026-11-10T06:40 KST)의 `tool_call` 276,519행은 모두 `lane` 이 `tool_optional`(Keeper 도구 표면 이름)이다. `masc_dos_screen` 4,980행은 모두 `msx-retro-mania` 한 Keeper 의 행이고, 그중 4,674행(94%)의 출력이 블롭이다. Add-on 호출이 지나는 `Keeper_lane_addon_runtime.call` 의 호출처는 `keeper_tool_runtime.ml:282` 하나이다(`rg` 로 `lib`, `bin`, `packages` 를 셈).
- 같은 `tool_result_to_yojson` 로 답 전체를 `data` 에 넣는 곳이 더 있다. 이 PR 은 건드리지 않는다.
  - 브라우저 lane 은 답 전체를 `data` 에 넣는 곳이 실패 경로에만 있다(`browser_addon_host.ml:472,479,497`, `browser_addon_tools.ml:335`). 성공 경로는 `data` 와 `content_blocks` 를 따로 만든다(`browser_addon_tools.ml:327-328`). 스크린샷은 Keeper 작업공간이 있으면 파일로 저장하고 `data` 에 그 기록을 넣는다. 없으면 PNG 는 이미지 블록에만 두고 `data` 에는 이미지 키를 뺀 관찰 필드를 넣는다(`browser_addon_tools.ml:254-266`).
  - `mcp_server_eio_protocol.ml:1258` 은 MCP 서버가 Add-on 도구 호출을 받을 때 같은 모양으로 답 전체를 `data` 에 넣는다. 원본 답은 `wire_result` 에 따로 담긴다. 이 길에서 Keeper 가 주인인 호출은 `lane` 이 `runtime_mcp` 인 장부 행으로 남는다(`mcp_server_eio_call_tool.ml:459`). 11월 장부에는 그런 행이 0건이라, 이 길이 PNG 를 블롭에 쓰는지와 응답에 두 번 싣는지는 재지 못했다. 이 PR 은 이 길을 건드리지 않는다.
- 오류 답(`isError` 가 true)은 `content_blocks` 가 없다. 오류 답에 든 이미지의 바이트는 전에는 `data` 의 base64 글자였고 지금은 크기 기록이라서, 어느 경우든 모델이 이미지로 읽지 못한다. DOS 와 MSX worker 는 이미지를 성공 답에만 붙인다.
