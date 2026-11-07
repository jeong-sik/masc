# `BrowserTabs` 결과가 레인의 inline 상한을 넘는 문제 (2026-11)

`BrowserTabs` 호출이 돌려준 결과의 크기를 재고, 제약 문구(`constraints`)를 `requiredActions` 에 준 동작에만 붙이면 같은 호출이 얼마나 작아졌을지 같은 원장으로 다시 계산해요.

## 왜 재나요

`BrowserTabs` 는 탭 목록(`tabs`)과 함께 이 브라우저가 구현한 동작의 카탈로그(`browserCapabilities`)를 돌려줬어요. 아래 창에서 카탈로그는 호출마다 61~69개 행이에요. 행에는 호출할 도구(`tool`, `action`, `mode`)가 있고, 조건부(conditional) 행에는 제약 문구도 붙어요. 문구는 호출마다 같은 글이에요. 카탈로그는 31,315~33,387 B 이고 탭 목록은 200~2,843 B(p50 1,400 B)예요.

결과가 레인의 inline 상한을 넘으면 모델은 `[masc:blob sha256=… preview="…"]` 표식과 200자 미리보기만 받아요(`lib/tool_blob_store/tool_output.ml`). 상한은 레인마다 달라요(`lib/runtime/runtime_execution.ml`): codex·antigravity·muse 16,384 B, claude_code 32,768 B, agent_core 65,536 B. 카탈로그가 결과의 맨 앞에 있어서 탭 목록은 저장된 파일의 끝에 있어요. 상한을 넘은 `BrowserTabs` 호출 뒤에 같은 Keeper 가 바로 `keeper_artifact_read` 를 부른 경우가 앞 세션에서 센 20건 중 11건이었어요(이 폴더에는 그 집계가 없어요).

## 결과 (2026-11-03T00:00Z ~ 11-07T14:00Z, UTC)

`BrowserTabs` 호출 346건이에요(kidsnote-slack-reader 159, kidsnote-incoming-dd-manager 122, wkbl-data 34, ocaml-agent-ic 15, wkbl-web-leader 9, wkbl-front 4, 나머지 Keeper 3명 1건씩). 결과 크기의 합은 7,536,915 B 이고, 그 창의 도구 결과 532,524,855 B 의 1.4% 예요.

원장의 `result_bytes` 가 16,384 B 를 넘은 호출은 221건, 32,768 B 를 넘은 호출은 196건, 65,536 B 를 넘은 호출은 0건이에요. 원장이 결과를 읽을 수 있게 남긴 정도는 이래요.

| | 호출 |
|---|---|
| 카탈로그가 있고 전체를 읽은 호출(blob) | 49 |
| 원장이 앞부분만 남긴 호출(`cut_excerpt`) | 180 (그중 16,384 B 초과 172) |
| 카탈로그가 없는 결과(`mode=connections`, 실패) | 117 |

전체를 읽은 49건에 고친 규칙을 옮겨 다시 계산했어요.

| | 최소 | p50 | 최대 | 합 |
|---|---|---|---|---|
| 지금 | 32,889 | 33,992 | 35,394 | 1,660,064 |
| 고친 뒤 | 6,988 | 9,134 | 10,683 | 428,353 |
| 카탈로그만, 지금 | 31,315 | 32,230 | 33,387 | |
| 카탈로그만, 고친 뒤 | 6,457 | 7,299 | 7,519 | |

| inline 상한 | 지금 | 고친 뒤 |
|---|---|---|
| 16,384 | 49 | 0 |
| 32,768 | 49 | 0 |
| 65,536 | 0 | 0 |

- 49건 모두 다시 직렬화한 크기가 원장의 `result_bytes` 와 같아요. 이 크기 계산(compact UTF-8 JSON)이 원장과 맞아요.
- 7개 검사가 49건 모두 통과했어요: 카탈로그에 `scope` 와 `operations` 만 있음, `scope` 가 옛 문구, 행의 순서와 필드, `constraints` 가 붙는 행, 지명한 행의 문구, 나머지 필드의 값과 순서, 카탈로그와 `requiredActions` 가 맨 뒤.
- 원장이 앞부분만 남긴 172건(16,384 B 초과)은 31,975~35,681 B 였어요. 읽은 49건 중 가장 작게 줄어든 크기(23,900 B)만큼은 줄어든다고 가정하면 고친 뒤에는 8,075~11,781 B 이하이고, 상한을 넘는 호출은 없어요. 이 가정은 이 172건의 카탈로그가 읽은 49건 중 가장 작은 카탈로그보다 작지 않다는 뜻이에요.
- 16,384 B 를 넘은 221건의 합은 7,433,307 B 에서 2,090,796 B 이하로 줄어요. 줄어드는 양은 5,342,511 B 이상(71.9% 이상)이에요.
- 가장 큰 결과의 조건부 동작 48개는 동작마다 `constraints` 가 148~1,095 B(p50 484 B)예요. 읽은 49건에서 `requiredActions` 를 준 호출은 0건이었어요.

## 고친 것

- `BrowserTabs` 결과에서 `tabs`, `browserSelection`, `clientId` 가 앞에 오고 `browserCapabilities`, `requiredActions` 가 뒤에 와요.
- `browserCapabilities.operations` 의 행은 동작, 상태, 도구(`tool`, `action`, `mode`)를 그대로 담아요. 조건부 행의 `constraints` 는 그 동작이 `requiredActions` 에 있을 때만 붙어요.
- `scope` 문구 끝에 이 규칙을 적어요.
- 다른 동작의 `constraints` 는 그 동작을 `requiredActions` 에 넣고 같은 lane·clientId 로 `BrowserTabs` 를 다시 불러서 읽어요. 이 경로는 코드를 읽어서 확인했어요(`Browser_addon_host.resolve` 는 `Tabs_list` 의 `requiredActions` 를 거절하지 않고, 명시한 클라이언트는 `Browser_selection.require` 만 거쳐요).

## 못 잰 것

- 모델이 새 결과를 받은 뒤 무엇을 하는지는 안 봤어요. `constraints` 를 따로 불러 읽는 일이 늘어나는지, 동작의 조건을 놓친 호출이 늘어나는지는 배포 뒤 같은 스크립트로 다시 재야 해요.
- 상한 아래에서 모델이 전체를 받은 호출(원장이 앞부분만 남긴 것)이 `constraints` 를 보고 행동을 바꿨는지는 안 봤어요.
- `Browser_capabilities.to_json` 의 OCaml 코드와 이 스크립트의 `reproject` 가 같은 결과를 내는지는 기계로 맞춰 보지 않았어요. 스크립트는 저장된 결과를 규칙대로 옮긴 것이고, `scope` 문구만 OCaml 소스에 있는 글과 같은지 시험이 확인해요.
- 시험(`test/test_browser_task_capabilities.ml` 의 새 시험)은 로컬에서 실행하지 않았어요. 타입 검사만 했어요.

## 다시 만들기

```bash
python3 docs/evidence/browser-tabs-catalog-2026-11/measure_browser_tabs_catalog.py \
  --base-path ~/me --since 2026-11-03T00:00:00 --until 2026-11-07T14:00:00 \
  --json-out docs/evidence/browser-tabs-catalog-2026-11/result-2026-11-03_11-07.json
```

원장 파일은 UTC 날짜로 잘려 있어요. 시험:

```bash
python3 -m unittest discover -s docs/evidence/browser-tabs-catalog-2026-11
```

`reproject` 는 OCaml `Browser_addon_tools.project` 의 Inventory 갈래와 `Browser_capabilities.to_json ~constraints_for` 를 저장된 결과에 옮긴 것이에요. 시험 14개는 합성 결과로 행 규칙, 필드 순서, 검사 함수가 위반을 잡는지, 원장 읽기(blob 없음, 앞부분만 남은 호출, 카탈로그 없는 결과, 창 거르기), 상한과 같은 크기, 잘린 호출의 위쪽 한계를 확인해요.
