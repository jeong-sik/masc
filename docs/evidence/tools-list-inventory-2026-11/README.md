# `keeper_tools_list` 결과가 모든 레인의 inline 상한을 넘는 문제 (2026-11)

Keeper `keeper_tools_list` 호출이 돌려준 결과의 크기를 재고, 도구·스킬 이름과 사용 가능 여부만 담은 목록(inventory)으로 바꾸면 같은 호출이 얼마나 작아졌을지 같은 원장으로 다시 계산해요.

## 왜 재나요

`keeper_tools_list` 는 도구 한 개마다 열아홉 개 안팎의 필드(설명 전문, 입력 스키마 요약, 정책, 실행기)를 담은 행을 돌려줬어요. 도구 203개와 스킬 52개면 한 번에 약 290 KB 예요(아래 창에서 253,258~292,878 B).

결과가 레인의 inline 상한을 넘으면 모델은 `[masc:blob sha256=… preview="…"]` 표식과 200자 미리보기만 받아요(`lib/tool_blob_store/tool_output.ml`). 상한은 레인마다 달라요(`lib/runtime/runtime_execution.ml`): codex·antigravity·muse 16,384 B, claude_code 32,768 B, agent_core 65,536 B. 원장 `output` 이 `{"_blob": …}` 인 호출은 레인에 표식이 나간 호출이에요(`lib/keeper_tool_call_log.ml` 의 `blob_aware_output_json`).

그래서 모델은 도구 목록을 한 번 불러도 목록을 못 읽어요. 저장된 파일을 `Grep` 으로 찾아야 하는데, 그 파일이 줄바꿈 없는 JSON 한 줄이라 `Grep` 도 한 줄 285 KB 를 돌려줘서 다시 표식만 받았어요(#49794 에서 `Grep` 쪽은 고쳤어요).

## 결과 (2026-11-06T09:52Z ~ 11-07T09:52Z, UTC)

`keeper_tools_list` 호출 53건이에요(wkbl-front 32, wkbl-growth 12, wkbl-data 9). 53건 모두 blob 에서 읽었어요. 표면(surface)은 12종이고 호출마다 도구 행 197개 안팎, 스킬 행 52개 안팎이에요.

| | 호출 | 바이트 |
|---|---|---|
| 지금 | 53 | 15,122,836 (그 창의 도구 결과 163,694,795 B 중 9.2%, 호출당 최소 253,258, 중앙값 284,819, 최대 292,878) |
| inventory | 53 | 513,467 (호출당 최소 8,623, 중앙값 9,655, 최대 9,888) |

inline 상한을 넘은 호출은 이래요.

| inline 상한 | 지금 | inventory |
|---|---|---|
| 16,384 | 53 | 0 |
| 32,768 | 53 | 0 |
| 65,536 | 53 | 0 |

- 가장 큰 표면의 도구 행 203개는 사용 가능(active) 163, 모델이 못 부름(not_model_invocable) 36, 샌드박스가 거부(refused_by_sandbox) 4 예요. 스킬 행 52개는 모두 active 예요.
- inventory 에서 빠지거나 늘어난 도구 이름과 스킬 이름은 없어요(53건 모두 이름별 횟수를 비교했어요).
- 도구 행의 필드는 21종에서 3종(`name`, `transport_alias_of`, `sandbox_refusal`)으로 줄어요. 스킬 행은 `name`, `kind`, `tool_name`(합성 스킬)이고, 도구가 빠진 합성 스킬에는 `outside_node_tools` 가 붙어요.
- 같은 창에서 결과가 65,536 B 를 넘은 `Grep` 호출은 67건이고, 그중 66건이 이 목록을 저장한 파일을 찾은 호출이에요(#49794). 패턴 51종 중 두 번 이상 나온 8종은 모두 도구 이름이나 `"name":` 키예요(`"name":` 5, `masc_board_[a-z_]+` 4, `board_post_get` 3, `board` 3, `board_` 3, `Execute` 2, `"Execute"` 2, `execute` 2). 이 패턴 집계는 스크립트 밖에서 센 값이고 이 폴더에는 없어요.

## 고친 것

- `keeper_tools_list` 가 `Keeper_capability_surface.inventory_to_yojson` 을 돌려줘요. 도구와 스킬을 `tools.<availability>`, `skills.<availability>` 아래에 이름으로 늘어놓아요. 설명과 스키마는 `keeper_capability_search` 가 이름이나 문구로 돌려줘요.
- 스키마 이름이 `masc.keeper.capability_surface.v1` 에서 `masc.keeper.capability_inventory.v1` 로 바뀌어요. 필드 이름 `descriptor_surface` 는 사라져요.
- `Compatibility_meta` 경로(plan 실행기·합성 노드)의 `keeper_tools_list` 는 그대로예요. 그 경로는 frozen surface 가 없어서 availability 를 몰라요.

## 못 잰 것

- 모델이 새 목록을 받은 뒤 무엇을 하는지는 안 봤어요. 목록 호출 뒤의 `Grep` 연쇄가 줄어드는지는 배포 뒤 같은 스크립트와 #49794 의 집계로 다시 재야 해요.
- 호출 하나가 모델 맥락에 싣는 양은 늘어요. 지금은 표식과 미리보기뿐이었고, 새 결과는 8.6~9.9 KB 를 통째로 실어요. 토큰으로는 안 쟀어요.
- `description`, `schema_shape`, `policy` 같은 필드를 쓰던 호출이 있는지는 안 봤어요. 위의 `Grep` 패턴은 이름을 찾는 쪽이에요.
- 시험(`test/test_keeper_tool_bundle_classifiable.ml`, `test_keeper_tool_dispatch_runtime.ml`, `test_keeper_skill_inventory.ml`)은 로컬에서 실행하지 않았어요. 타입 검사만 했어요.

## 다시 만들기

```bash
python3 docs/evidence/tools-list-inventory-2026-11/measure_tools_list_inventory.py \
  --base-path ~/me --since 2026-11-06T09:52:00 --until 2026-11-07T09:52:00 \
  --json-out docs/evidence/tools-list-inventory-2026-11/result-2026-11-06_11-07.json
```

원장 파일은 UTC 날짜로 잘려 있어요. 시험:

```bash
python3 -m unittest discover -s docs/evidence/tools-list-inventory-2026-11
```

`inventory_of` 는 OCaml `inventory_to_yojson` 을 저장된 행에 옮긴 것이에요. 합성 표면으로 분류 순서, 도구 행 이름(Keeper 가 부르는 이름), 별칭, 거부 사유, 스킬 이름, 창 거르기, 읽지 못한 호출을 확인하는 시험 12개예요. 저장된 표면 12종의 도구 행 2,354개 중 `public_name` 과 `internal_name` 이 다른 156개는 모두 `preferred_public_name` 이라서 행 이름은 `public_name` 그대로고, 결과 JSON 은 바뀌지 않아요.
