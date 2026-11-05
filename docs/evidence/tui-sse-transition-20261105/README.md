# TUI SSE 전환 실측 (2026-11-05)

## 판정

이 번들의 최종 측정 source는 `473386e4609917d3129867a895637bb9ed969879`다. Browser·Memory·Skill 관련 cache·Lane·Machine의 **알림 후 정본 읽기**는 구현했고, 해당 PTY에서는 주기 HTTP 읽기를 제거했다. 그러나 **전체 TUI의 SSE Fully/native push 전환은 완료가 아니다**.

- Play room은 활성 상태에서 아직 2초마다 `POST /api/v1/play/room`을 호출한다. 읽기와 presence 갱신을 함께하므로, 서버 소유 presence·변경 알림 설계가 별도로 필요하다.
- Browser 변경 감지는 backend native event가 아니라 **서버가 선택 대상을 2초마다 관측해 revision이 바뀔 때만 알리는 방식**이다.
- 측정 시점에 PR #48180은 닫혀 있고 같은 브랜치의 open replacement는 없다. merge·rebase·충돌 해결·운영 설치·재시작·`~/me/.masc` 변경은 이 작업에서 하지 않았다.

TUI 렌더링 최적화는 별도 완료 증거인 [`tui-smoothness-20261104`](../tui-smoothness-20261104/README.md)을 따른다. SSE 요청 수 감소가 UI 입력 지연 감소를 자동으로 의미하지는 않는다.

## 최종 후보와 검증

- production source: `473386e4609917d3129867a895637bb9ed969879`
- macOS native proof run: `41960928980`
- TUI SHA-256: `02f9cec046fdd0f07b5ba0abc762c460ce3eef716b4695f842fba745796394b2`
- embedded `--build-commit`: 위 production source와 동일
- `41960925440`: `pr-type-check.yml`, **성공**
- `41961038163`: 첫 20개 targeted suite, Browser hidden 경합 1건과 Lane cold-build 600초 초과로 **실패**
- `41963750774`: hidden 진입을 보정한 20개 targeted suite, **실행 중**
- `41963753486`: test-only head `5c1420fb9703c78ff403929d3f04563539a4a478`의 `pr-type-check.yml`, **성공**
- 독립 whole-branch review: **대기**

최종 후보의 `--help`에는 `--refresh`가 없다(`candidate-help.txt`). 시작·명시적 `r`·실패 재시도·재연결·표시 전용 애니메이션·로그인 마감은 별개다.

## 요청 수 실측

모든 최종 PTY는 위 native 실행 파일 하나와 35x200 terminal, isolated HTTP/SSE fixture를 사용했다. Browser backend나 운영 서버는 사용하지 않았다. 각 surface는 한 번씩 실행했으며, 결과 JSON이 phase별 실제 요청·응답 수를 보존한다.

| Surface | Idle/무관한 알림 | 정확한 변경 | burst | 실패 재시도 | reconnect | 숨은 화면 |
|---|---:|---:|---:|---:|---:|---:|
| Browser 선택 tab read | open 1, unrelated 0 | 1 | 첫 read 포함 총 2 | 총 2 | 총 2 | 0 |
| Memory health | open 1, unrelated 0 | 1 | 총 2 | 총 2 | 총 2 | 0 |
| Lane `/api/v1/lanes` | open 1 | inspect Add-on 1 | 총 2 | 총 2 | 해당 suite의 별도 reconnect 없음 | hidden Lane/Add-on 0 |
| MSX live | open 1, 다른 machine 0 | push 1 | 해당 없음 | 해당 없음 | Control `observer:msx` 1 → Watch `observer:watch` 1 | `/api/v1/msx/tick` 0 |

### Browser 고정 idle 비교

초기 선택 tab 응답을 기다린 뒤 같은 2.4초 drain을 한 번씩 측정했다.

| Binary | 실제 drain | 선택 tab read | clients GET | scoped observer |
|---|---:|---:|---:|---:|
| baseline `b7a4aa5a81f5fe935fd19a9f4a7b1fb23752be7d` | 2.434742s | 2 | 3 | 0 |
| final `473386e4609917d3129867a895637bb9ed969879` | 2.401141s | 1 | 2 | 1 |

초기 read는 두 쪽 모두 유지된다. 기준선은 drain 중 한 번 더 읽었고 최종 후보는 읽지 않았다. 한 샘플씩이며 전체 UI latency나 모든 화면의 요청률로 일반화하지 않는다. 기존 Machine 1.2초 초기 화면은 live 응답 4회였고, 최종 후보는 1회다. Memory 기준선도 고정 idle health 2회에서 최종 1회가 됐다.

## 확인한 결함과 수정

- Browser 실패 상태를 매 loop마다 다시 실패 처리해 2·4·8·16·30초 backoff가 실제 응답 없이도 증가했다. `browser-retry-red.json`은 첫 실패 후 `now=7.932`의 `retry_at=9.915`가 이어 `11.932`, `15.949`, `23.967`로 밀린 진단을 보존한다. 최종 코드는 `Settled/Reading`에서만 실패 전이하고 `Owed/Waiting`을 보존한다. 권한 미확인 동안 `Reading`으로 표시하지도 않는다.
- Machine fixture는 scope 교체를 서버 재시작으로 잘못 알려 두 번째 F5 전에 machine 화면을 닫게 했다. scope 교체는 같은 instance로 수정하고, 명시적 reconnect의 재시작 시나리오는 남겼다.
- 여러 observer가 하나의 queue를 공유해 취소된 연결이 알림을 가로채던 fixture는 구독자별 broadcast queue로 바꿨다. palette Enter, Add-ons `o`, 초기 detail 읽기와 변경 읽기의 수도 실제 키/요청 계약에 맞췄다.

## native proof의 한계

`41960928980`의 artifact는 exact source와 binary identity를 증명하지만 `behavior_passed=false`다. `test_browser_addon_tool`, `test_browser_ego_peer`, `test_browser_native_workflow`, `test_keeper_vision_tool`이 실패했다. Node fixture module 부재와 Browser tool/vision assertion 실패가 있으며, 이 번들에서 기존 결함이라고 단정하지 않는다. 이 artifact로 수행한 PTY 통과를 native 전체 통과나 실제 Browser backend 검증으로 부르지 않는다.

## 재현과 파일

```sh
PYTHONPATH=test python3 docs/evidence/tui-sse-transition-20261105/measure_suite_requests.py \
  test_tui_browser_push BrowserPushTest /path/to/masc-tui /tmp/browser-requests.json
PYTHONPATH=test python3 docs/evidence/tui-sse-transition-20261105/measure_suite_requests.py \
  test_tui_memory_push MemoryPushTest /path/to/masc-tui /tmp/memory-requests.json
PYTHONPATH=test python3 docs/evidence/tui-sse-transition-20261105/measure_suite_requests.py \
  test_tui_spectator_push SpectatorPushTest /path/to/masc-tui /tmp/spectator-requests.json
PYTHONPATH=test python3 docs/evidence/tui-sse-transition-20261105/measure_suite_requests.py \
  test_tui_lane_inventory_push LaneInventoryPushTest /path/to/masc-tui /tmp/lane-requests.json
PYTHONPATH=test python3 docs/evidence/tui-sse-transition-20261105/measure_browser_idle.py /path/to/masc-tui
```

- `candidate-{browser,memory,spectator,lane}-requests.json`: 최종 phase별 요청 수와 통과 여부
- `candidate-{browser,memory,spectator,lanes}-result.log`: 최종 PTY 결과
- `candidate-browser-idle-result.log`, `candidate-help.txt`: 고정 idle와 CLI 결과
- `baseline-{browser,browser-idle,spectator,memory}-result.log`: 기준선 결과와 실패를 그대로 보존
- `browser-retry-red.json`: 수정 전 backoff 증폭 진단
- `summary.json`: source·hash·측정값·남은 범위의 기계 판독용 요약

원본 크기가 큰 PTY/native artifact는 `artifacts/tui-sse-lanes-20261104/`에 둔다. 공유 main-worktree binary가 측정 중 바뀐 `f6d50a3…` v2 capture는 비교에서 제외했다. 실제 backend, 설치 상태, Play room, 그리고 위에 적은 native 실패는 미검증 또는 미완료 범위로 남는다.
