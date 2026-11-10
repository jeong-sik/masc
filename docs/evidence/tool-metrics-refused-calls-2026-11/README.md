# 인자가 거절된 도구 호출이 대시보드 통계에서 빠진다 (2026-11)

대시보드 「도구 실행 통계」는 `<base>/.masc/tool-metrics.sqlite3` 의 `tool_metric_events` 를 읽는다(`/api/v1/tool-metrics/series`).
이 표에 쓰는 곳은 디스패치 observer 한 곳(`server_bootstrap_maintenance.ml`)이다.
Agent Core 가 인자를 거절한 호출은 핸들러가 돌기 전에 끝나서 디스패치에 안 들어가고, observer 도 못 본다.
장부(`<base>/.masc/tool_calls/<YYYY-MM>/*.jsonl`)에는 그 호출의 행이 있다. `output` 이 `Your call to "<tool>":` 로 시작하고 `disposition` 이 없다.

## 이 변경이 하는 일

`Keeper_hooks_agent_core` 의 `post_tool_use_failure` 가 `Validation_before_execution` 단계일 때 observer 를 한 번 부른다.
결과는 실패(`Policy_rejection`, 효과 시작 전 `Proven_pre_effect`)이고 도구 이름은 다른 observer 가 받는 내부 이름이다(`Read` → `tool_read_file`).
`Execution` 단계(핸들러가 돌았고 그 디스패치가 이미 observer 를 불렀다)와 `Cancelled_during_execution` 단계(결과가 없다)는 부르지 않는다.

## 기준선 (이 변경이 배포되기 전)

`store_vs_ledger.py` 로 장부와 저장소를 (UTC 날짜, 도구) 칸마다 견줬다.
창은 2026-11-02T00:00Z ~ 11-09T14:00Z(7일 14시간)이다. 결과 전체는 `store-vs-ledger-before-2026-11-02_11-09T14.json` 이다.

| 항목 | 값 |
|---|---|
| 장부 호출(비교한 도구 109개) | 193,922 |
| 장부의 인자 거절 | 1,607 (0.83%) |
| 저장소 호출 | 193,614 |
| 저장소 실패 | 2,411 |
| 거절이 한 건이라도 있는 도구 | 45 |

- 23개 도구(거절 457건)는 거절이 있는 (날짜, 도구) 53칸 모두에서 `저장소 호출 = 장부 호출 − 거절`이 맞는다. 예: `tool_read_file` 장부 5,460·저장소 5,341·거절 119, `keeper_memory_write` 장부 1,638·저장소 1,502·거절 136.
- 나머지 22개 도구(거절 1,150건)는 거절만으로 차이가 설명되지 않는다. `masc_board_comment` 는 저장소가 장부보다 거절 수만큼 적지 않고 133건 더 많다(장부 6,733·저장소 6,275·거절 591). `tool_execute` 는 장부가 저장소보다 973건 많고 거절은 118건이다. 이 도구들에서 저장소가 장부와 다른 이유(예: MCP 클라이언트가 부른 호출은 저장소에만 있을 수 있다)는 확인하지 않았다.
- 그래서 합계(장부 − 저장소 = 308, 거절 1,607)만 보면 거절이 빠진다는 사실이 가려진다. 도구별로 봐야 보인다.

## 배포 뒤에 확인하는 법

```
python3 docs/evidence/tool-metrics-refused-calls-2026-11/store_vs_ledger.py \
  --base-path ~/me --since <새 부팅 +60초, UTC> --end <지금, UTC> --json-out <경로>
```

- 기준선에서 거절이 갭의 전부였던 도구(`tools_where_refusals_are_the_whole_gap` 목록)는 `gap` 이 0 근처로 내려가야 한다.
- 같은 도구의 `store_failed` 는 그 창의 거절 수만큼 는다.
- 창 끝이 지금에 가까우면 저장소 쓰기 대기열 때문에 마지막 몇 건이 빠질 수 있다. 끝을 몇 분 앞으로 잡는다.
- 날짜 경계는 UTC 다. 장부의 `ts` 는 결과를 받은 뒤 행을 만드는 시각이라 호출이 끝난 시각과 같거나 조금 늦다(호출이 시작한 때가 아니다). 같은 턴에서 `ts` 순으로 이웃한 Execute 173쌍(앞 호출 60초 이상, 뒤 호출 20초 이하, 사이에 다른 도구 호출이 있을 수 있다) 중 116쌍은 두 행의 간격이 앞 호출의 시간보다 짧았고 뒤 호출의 시간보다 짧은 쌍은 없었다(`docs/evidence/tool-efficiency-1110-2026-11/ts_position.py`). 저장소의 `ts` 는 observer 가 불린 시각이라, 두 시각의 차이만큼 경계에서 한 칸 어긋날 수 있다.

## 배포 뒤 결과 (2026-11-10)

서버 빌드 `227056a94eed`(부팅 08:00:32Z)와 그 뒤 `f587687402c8`(부팅 09:33:27Z)이 창을 나눠 돌았다. 두 빌드 모두 #50716(인자 거절 호출을 observer 에 알림)과 #50990(연결 도구 호출을 observer 에 알림)을 포함한다(`git merge-base --is-ancestor` 로 확인했다).
창은 2026-11-10T08:01:00Z ~ 10:10:38Z(2시간 10분)이고 결과 전체는 `store-vs-ledger-after-2026-11-10T08-01_10-10.json` 이다.

| 항목 | 값 |
|---|---|
| 장부 호출(비교한 도구 59개) | 5,099 |
| 장부의 인자 거절 | 6 |
| 저장소 호출 | 5,128 |
| 저장소 실패 | 41 |
| 거절이 한 건이라도 있는 도구 | 4 |
| `unmapped_ledger_tools` | 없음 |

- `unmapped_ledger_tools` 가 비었다. 장부에 이름이 나온 도구는 모두 저장소에도 이름이 있다. #50990 이전 측정에서는 연결 도구 66개가 저장소에 이름이 없었다.
- 거절이 있는 도구 넷 가운데 `masc_browser_interact`(거절 2건), `masc_schedule_create`(1건), `masc_wiki_update`(1건)는 장부 호출과 저장소 호출이 같다(`gap` 0). 거절된 호출이 저장소에 들어 있다고 읽을 수 있다(저장소에만 있는 다른 호출이 차이를 상쇄했을 수도 있다).
- `tool_execute` 는 장부 3,643·저장소 3,639로 `gap` 이 4이고 장부의 거절은 2건이다. 4건이 어떤 호출인지(거절이 몇 건 섞였는지 포함)는 가르지 않았다. `tool_read_file` 은 장부 102·저장소 101(거절 0)이다. 두 도구 모두 원인을 안 봤다. 창 끝을 실행 시각(10:10:38Z)에 맞췄으므로 마지막 몇 건이 저장소 쓰기 대기열에 있었을 수 있다. 확인하지 않았다.
- 저장소가 장부보다 많은 도구가 있다(저장소·장부 순): `masc_keeper_delegate_status` 28·2, `masc_keeper_list` 8·1, `masc_board_post` 3·2. 기준선과 같은 방향(장부에 남지 않는 호출이 저장소에는 남는다)이지만 호출자는 가리지 않았다.
- 표본이 2시간 10분이고 거절이 6건이다. 비율로 읽을 수 없고, 같은 도구에 대해 기준선의 `gap = 거절` 관계가 사라졌다는 것까지만 말한다.

## 확인한 것

- 오프라인 링크 실행(11-09 04:47Z 스냅숏 `2d9d4c7c9250` 트리에 이 변경을 얹음): `test_keeper_run_tools_hooks` 70개 통과, 새 시험 3개 포함. 변이 8개(observer 호출 빼기, 실행 단계도 부르기, 취소 단계도 부르기, 공개 이름 그대로 두기, 클래스를 `Runtime_failure` 로 바꾸기, 두 번 부르기, 메시지 바꾸기, `No_handler` 로 부르기)를 모두 시험이 잡았다.
- `test_store_vs_ledger.py` 12개 통과, 변이 10개를 모두 잡았다.
- 현재 main 에서의 컴파일과 시험 실행은 CI 가 맡는다.

## 못 한 것과 모르는 것

- OTel 이 켜진 환경에서 `Otel_dispatch_hook` 이 이 호출의 상태를 어느 span 에 붙이는지는 안 봤다(`handle_validation_error` 가 같은 방식으로 observer 를 부른다).
- 장부의 `disposition` 이 없는 오류 행(Execute 의 빈 입력 거절 등)은 건드리지 않았다. 그 호출은 저장소가 이미 센다.
- `tool_execute` 의 장부 − 저장소 855건(거절을 뺀 값)의 원인은 모른다.
