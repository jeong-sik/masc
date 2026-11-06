---
rfc: "dos-input-calls-return-the-screen"
title: "DOS 입력 도구가 입력 뒤 화면을 같은 호출에 돌려준다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: claude
related: []
---

# RFC: DOS 입력 도구가 입력 뒤 화면을 같은 호출에 돌려준다

## 배경

`masc_dos_step`, `masc_dos_press`, `masc_dos_click`, `masc_dos_type` 은 기계를 움직이고 텍스트로 답한다.
화면은 `masc_dos_screen` 으로 따로 읽는다.
입력 뒤에 화면을 읽는 Keeper 는 입력마다 도구 호출 한 번과 모델 요청 한 번을 더 쓴다.

## 측정

원장 `.masc/tool_calls` 의 2026-11-01 ~ 11-04(UTC, 끝난 날), 읽은 시각 2026-11-05T18:19Z 이다.
쌍은 한 Keeper 의 `masc_dos_*` 호출 중 서로 이어지고 같은 턴(`trace_id`, `keeper_turn_id`)이며, 앞이 입력이고 뒤가 `masc_dos_screen` 인 두 호출이다.
측정 도구와 결과 파일은 [`docs/evidence/dos-input-then-screen-2026-11/`](../evidence/dos-input-then-screen-2026-11/README.md) 에 있다.

| 입력 도구 | 호출 | 화면이 바로 이어진 호출 | 비율 | 입력 행과 화면 행 사이 시간(중앙값) |
|---|---:|---:|---:|---:|
| `masc_dos_step` | 272 | 189 | 69.5% | 12.4초 |
| `masc_dos_press` | 2,074 | 1,490 | 71.8% | 10.4초 |
| `masc_dos_type` | 123 | 28 | 22.8% | 10.5초 |
| `masc_dos_click` | 0 | 0 | | |
| 합계 | 2,469 | 1,707 | 69.1% | |

- `masc_dos_*` 호출 4,704개 중 `masc_dos_screen` 이 1,940개이고, 그중 1,707개(88.0%)가 입력 바로 뒤에 왔다.
- 쌍 1,707개 모두에서 입력 호출이 자기 배치에 혼자(`batch_size` 1) 있었다. 화면 읽기는 모두 다음 모델 요청에서 일어났다.
- 입력 행과 화면 행 사이 시간의 합은 12.45시간이다. 모델이 생각하는 시간이 들어 있어서 줄어드는 시간이 아니다.
- 쌍의 화면 결과는 159.8 MB 이다. 이 바이트는 줄지 않는다. 이미지가 입력 결과로 옮겨 올 뿐이다.
- 호출 4,704개는 모두 `msx-retro-mania` 한 Keeper 의 것이다. 이 Keeper 의 마지막 DOS 호출은 2026-11-05T10:17Z 이다. 한 Keeper, 4일 표본이다.
- 같은 Keeper 의 저장된 요청에는 화면 이미지가 중앙값 113장, 최대 1,186장 실린다([2026-11-05 보고서](../reports/2026-11-05-tool-efficiency.md) §1.5).

## 결정

입력 도구 넷에 `include_frame`(boolean, 기본 false)을 둔다. `true` 이면 응답 content 에 `masc_dos_screen` 이 주는 PNG 가 붙는다.

- 구조화 데이터(`structured_content`)는 `include_frame` 과 상관없이 같다. 데이터만 읽는 호출자는 영향이 없다.
- 거절된 입력(`is_error`)에는 프레임이 붙지 않는다.
- 입력은 들어갔는데 프레임을 못 찍으면 호출은 성공이고, content 에 "입력은 적용됐고 프레임이 없다"는 한 줄이 붙는다. 이미 들어간 입력을 호출자가 되풀이하지 않게 하려는 것이다.
- 입력 도구 목록은 `Machine_controller_contract.dos_tool` 전체에 대한 exhaustive `match`(`frame_after_input`)로 정한다. 새 도구가 생기면 컴파일러가 분류를 묻는다.
- Keeper 에게 가는 길은 `masc_dos_screen` 과 같다. `Keeper_lane_addon_runtime.call` 이 워커 응답의 모든 content 를 블록으로 옮긴다.
- 도구 설명(`config/tools/masc_dos_*.toml`)과 `addons/dos-machine/skills/dos-play/SKILL.md` 에 `include_frame` 을 쓴다.

## 하지 않는 것

- 기본값을 `true` 로 바꾸지 않는다. 입력 2,469개 중 762개(30.9%)는 화면이 바로 이어지지 않았다. 이 입력에까지 PNG 를 붙이면 그 수만큼 이미지가 컨텍스트에 쌓인다. 쌍의 평균 93.6 KB 로 치면 71 MB 쯤이다(추정). 이미지 누적은 이 Keeper 의 요청 크기를 정하는 값이라서(보고서 §1.5), 채택 여부를 측정한 뒤에 정한다.
- `masc_dos_press_and_look` 같은 새 도구를 만들지 않는다. 입력 도구 넷을 한 벌 더 두는 일이고, 도구 목록에 항목이 늘어난다.
- 이미지를 컨텍스트에서 줄이는 일은 하지 않는다. [RFC-tool-results-age-out-of-context](RFC-tool-results-age-out-of-context.md) 의 몫이다.
- `masc_dos_load` 와 `masc_dos_restore` 는 건드리지 않는다. 뒤에 화면이 이어진 호출이 `load` 1건, `restore` 10건뿐이다.
- MSX 도구는 건드리지 않는다. `masc_msx_step` 에는 이미 `include_frame` 이 있고, 같은 기간 원장에 `masc_msx_*` 호출은 `masc_msx_meta` 49건뿐이다.

## 배포

워커가 스키마를 가진다([lane-addon-tool-exports](../design/lane-addon-tool-exports.md)). Keeper 가 보는 `include_frame` 은 워커 이미지가 정한다.
이 소스로 이미지를 다시 빌드해 교체해야 쓸 수 있다. 옛 이미지의 워커는 목록에 없는 인자를 거절한다(`additional_properties = false`). 워커 시험이 이 거절을 확인한다.
호환 코드는 두지 않는다.

## 측정 계획

배포 뒤 같은 규칙으로 같은 스크립트를 돌린다. 같은 런타임 프로필끼리 `followed_by_screen / calls` 와 `with_frame / calls` 를 견준다. 프로필마다 입력 뒤 화면을 읽는 비율이 달라서 전체 값은 프로필 구성에 따라 움직인다. 결과 파일의 `by_profile` 에서 `ollama_cloud.ollama-cloud-deepseek-v4-1-flash` 는 입력 1,624개 중 1,238개(76.2%), `glm-coding.glm-5.3-flash` 는 383개 중 235개(61.4%)다.

- 지금은 배포 뒤 값이 없다. 이 Keeper 가 11-05T10:17Z 이후 DOS 도구를 부르지 않았다.
- `with_frame` 호출이 거의 없는데 `followed_by_screen` 비율이 그대로면, 설명만으로는 쓰이지 않은 것이다. 그때 기본값 변경을 이미지 누적 측정과 함께 다시 본다.
- 한 호출이 길어지는 정도(PNG 인코딩 시간)는 재지 않았다. 배포 뒤 `include_frame` 호출의 `duration_ms` 로 본다.

## 위험

- 호출자가 `include_frame=true` 로 입력하고 `masc_dos_screen` 도 부르면 이미지가 두 장 쌓인다. 스킬 문서에 "화면이 같이 오면 다시 읽지 않는다"를 쓴다. 이 행동이 실제로 줄었는지는 측정 계획의 `followed_by_screen` 이 보여 준다.
- 실패 줄("프레임이 없다")이 나오는 경로는 시험으로 만들지 못했다. 입력이 성공한 직후 같은 호출 안에서 캡처가 실패하려면 워커 락 안에서 기계가 사라져야 하고, 그 길이 지금은 없다.
