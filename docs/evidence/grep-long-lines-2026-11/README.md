# Grep 결과에서 줄 하나가 결과 크기를 정하는 문제 (2026-11)

Keeper `Grep` 결과의 매치 줄 길이를 재고, 줄마다 2,000 B 로 자르면 결과가 얼마나 줄었을지 같은 원장으로 다시 계산해요.

## 왜 재나요

`lines_to_json` 은 매치 줄을 최대 `limit`(기본 40)줄, 합계 32,000 B 까지만 담아요. 그런데 바이트 예산 검사에 `acc <> []` 조건이 있어서 첫 줄은 크기와 상관없이 통과해요(`lib/keeper/keeper_tool_shared_runtime.ml`). 파일 하나가 줄바꿈 없는 JSON 한 줄이면 그 줄 전체가 매치 하나로 나가요.

결과가 레인의 inline 상한을 넘으면 모델은 `[masc:blob sha256=… preview="…"]` 표식과 200자 미리보기만 받아요(`lib/tool_blob_store/tool_output.ml`). 상한은 레인마다 달라요(`lib/runtime/runtime_execution.ml`): codex·antigravity·muse 16,384 B, claude_code 32,768 B, agent_core 65,536 B. 원장 `output` 이 `{"_blob": …}` 인 호출은 레인에 표식이 나간 호출이에요(`lib/keeper_tool_call_log.ml` 의 `blob_aware_output_json`).

## 결과 (2026-11-06T09:52Z ~ 11-07T09:52Z, UTC)

`Grep` 호출 753건, 결과 22.72 MB 예요. 원장은 긴 inline `output` 을 몇 KB 로 잘라 두는데, 잘린 발췌만 남은 111건은 매치 줄을 읽지 못했어요. 읽은 호출은 642건, 매치 줄은 3,745개예요.

| 매치 줄 길이 | 바이트 |
|---|---|
| p50 | 84 |
| p90 | 218 |
| p99 | 282,960 |
| 최대 | 291,236 |

- 2,000 B 넘는 줄은 80개(2.1%)이고 69개 호출에 있어요. 80개 중 67개는 11,147 B 이상이고 호출 하나에 하나씩이에요. 중앙값은 282,960 B 예요.
- 큰 줄 67개 중 66개는 `{"schema":"masc.keeper.capability_surface.v1"…` 로 시작해요. `keeper_tools_list` 결과를 파일로 저장해 두고 `Grep` 으로 찾은 호출이에요(예: wkbl-front 의 `work/tools_list.json`, wkbl-growth 의 `evidence/task-3215/tools_surface.json`). 나머지 하나는 HTML 한 줄(`rcg.html:163`)이에요.
- 69개 호출의 Keeper 는 wkbl-front 48건, wkbl-data 11건, wkbl-growth 10건이에요. 세 Keeper 모두 `keeper_tools_list` 를 부른 Keeper 예요.
- 같은 턴의 바로 다음 호출도 `Grep` 인 경우가 이 67건 중 44건이에요(스크립트 밖에서 센 값이고 이 폴더에는 없어요). 예를 들어 wkbl-front 는 11-07T03:00:42Z~03:00:51Z 에 `board_post_get`, `"tool_name":`, `Execute` 패턴으로 세 번을 이어 불렀고 세 번 모두 315 KB 가 나왔어요.

결과 크기가 inline 상한을 넘은 호출은 이래요. 아래 표의 "자른 뒤"는 줄을 2,000 B 로, `error_detail` 을 32,000 B 로 잘라 JSON 을 다시 만든 크기예요.

| inline 상한 | 지금: 호출 | 지금: 바이트 | 자른 뒤(하한): 호출 | 자른 뒤(하한): 바이트 |
|---|---|---|---|---|
| 16,384 | 71 | 21,460,956 | 3 | 79,512 |
| 32,768 | 67 | 21,348,475 | 1 | 32,923 |
| 65,536 | 67 | 21,348,475 | 0 | 0 |

- 줄을 자르는 호출은 69건이고 합계가 20,401,456 B 에서 202,312 B 이상으로 줄어요. "이상"인 까닭은 옛 코드가 첫 줄 뒤의 줄을 모두 버려서(`…[N more lines omitted]`), 새 코드가 더 담을 줄이 원장에 없기 때문이에요. 상한은 호출당 32,000 B 에 봉투 크기를 더한 값이고, 69건이면 2,222,007 B 예요.
- `rg` 가 종료 코드 2 로 끝난 호출은 출력 전체를 `error_detail` 에 담아요. 이 창에 1,041,248 B 짜리 호출이 한 건 있었어요(wkbl-front, `pattern=".*"`, 공유 트리). 32,000 B 로 자르면 32,923 B 예요. claude_code 상한을 155 B 넘어요.
- 다시 만든 크기가 `result_bytes` 와 같은 호출은 642건 중 641건이에요. 다른 한 건은 37 B 차이가 나고 원인은 보지 않았어요.

줄 상한을 바꿨을 때 잘리는 줄이에요(읽은 3,745줄 기준).

| 줄 상한 | 잘리는 줄 | 그 줄이 든 호출 | 자른 뒤 하한 |
|---|---|---|---|
| 500 | 181 | 119 | 159,443 B |
| 1,000 | 92 | 75 | 144,024 B |
| 2,000 | 80 | 69 | 202,312 B |
| 4,000 | 72 | 68 | 341,074 B |
| 8,000 | 67 | 67 | 620,947 B |

2,000 B 를 골랐어요. 8,000 B 이상인 줄은 67개이고 2,000~8,000 B 인 줄은 13개예요. 상한을 8,000 B 로 해도 큰 줄 67개는 똑같이 잘려요. 2,000 B 는 그 13개를 더 자르는 대신, 잘린 큰 줄 하나가 모델 맥락에 싣는 양이 4분의 1 이에요. 맥락 몫은 바이트로만 쟀어요. 토큰으로는 안 쟀어요.

## 고친 것

- `lines_to_json` 이 줄마다 `max_line_bytes`(기본 2,000, `max_bytes` 보다 크지 않게) 로 UTF-8 경계에서 자르고 `...[cut: K of N bytes kept]` 를 붙여요.
- `rg` 의 `error_detail` 도 같은 함수(`cut_to_bytes`)로 32,000 B 에서 잘라요.
- 시험(`test/test_keeper_workspace_ops.ml`)은 300,000 B 한 줄, 예산보다 작은 `max_bytes`, 긴 줄 앞뒤 줄 유지, 한글 경계, 딱 맞는 길이를 확인해요.

## 못 잰 것

- 모델이 잘린 줄을 보고 다음에 무엇을 하는지는 안 봤어요. 잘린 줄 안에서 찾던 문자열은 이제 보이지 않아요. `Execute` 로 `rg -o` 나 `jq` 를 써야 해요.
- 원장에 남지 않은 첫 줄 뒤의 줄 수와 크기는 몰라요. 그래서 "자른 뒤"는 하한이에요.
- 16,384 B 레인(codex·antigravity·muse)에서는 32,000 B 예산이 상한보다 커요. 이 PR 은 예산을 안 바꿨어요.
- 읽지 못한 111건의 줄 길이는 몰라요.

## 다시 만들기

```bash
python3 docs/evidence/grep-long-lines-2026-11/measure_grep_long_lines.py \
  --base-path ~/me --since 2026-11-06T09:52:00 --until 2026-11-07T09:52:00 \
  --json-out docs/evidence/grep-long-lines-2026-11/result-2026-11-06_11-07.json
```

`--cap`, `--budget` 으로 상한을 바꿔 볼 수 있어요. 원장 파일은 UTC 날짜로 잘려 있어요. 시험:

```bash
python3 -m unittest discover -s docs/evidence/grep-long-lines-2026-11
```

합성 원장과 blob 으로 줄 길이 집계, 발췌 처리, 창 거르기, 없는 blob 을 확인하는 시험 10개예요.
