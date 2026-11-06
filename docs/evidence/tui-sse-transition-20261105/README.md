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
- `41963750774`: hidden 진입을 보정한 20개 targeted suite, **성공**
- `41963753486`: test-only head `5c1420fb9703c78ff403929d3f04563539a4a478`의 `pr-type-check.yml`, **성공**
- 독립 whole-branch review: **With fixes**; 후속 수정의 독립 review는 아래 실행과 별도로 진행

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
- Skill은 첫 ledger 읽기 실패를 영구 캐시해 복구 후에도 재시도하지 않았다. `41965753071`에서 RED를 확인하고 `bea45f2c591`에서 실패 cold read만 재시도하도록 고쳤다. GREEN `41966485936`은 **성공**이다. 이전 type-check `41966489387`은 최신 head로 자동 취소됐고, 최종 head 검사로 대체한다.
- Memory도 첫 `read_error`가 남아 유효한 스냅샷 복구를 보지 못했다. `41966147270`에서 RED를 확인하고 `881854d58d2`에서 `read_error=None`인 health만 재사용하도록 고쳤다. GREEN `41966803734`과 type-check `41966807144`는 **성공**이다.

## 후속 수정과 검증 상태

위 실측 source 이후의 독립 review에서 발견한 결함은 별도 RED/GREEN으로 추적한다. 이 항목의 현재 후속 head는 `2329a5b18e0`다.

- `41976321616`: Skill·Memory lock-order, exact-limit log, transient Machine step, private Add-on 권한의 **실제 native RED**. 이전 실행들의 test type 오류와 cold-build timeout은 제품 RED로 세지 않는다.
- `e6d923a0734`: 두 cold read를 cache mutex 밖으로 옮기고 commit generation으로 stale overwrite를 막았다. `41977170917` **성공**; Skill 44개·Memory 27개 테스트에서 writer 완료와 최신 commit을 확인했다.
- `68cd397b9be`: Watch `r`이 global refresh보다 먼저 소비돼 repaint만 하던 경로에 visible machine owed-read를 추가했다.
- `c9b89f65b3b`: Machine step은 `Unavailable`만 재시도하고 `Outcome_unknown`·`Host_refusal`은 중단한다. Log는 `limit+1` lookahead로 exact page를 append하고 overflow만 최신 page로 reset한다.
- `843119b65f4`: Add-on 알림에 durable visibility를 포함하고, live·replay는 등록 시 검증된 `agent_name`·`role`로 제한한다. identity 없는 external은 shared만 받고, 누락·중복·비정상 visibility는 거부한다.
- `41977992916`: 후속 head의 type-check **성공**.
- `41977989608`: 10 suite 중 7개 **성공**, 3개 **실패**. manual `r` 재읽기는 Machine·Add-on 모두 성공했다. replay gap은 `Last-Event-ID`보다 작은 fixture gap이라 TUI가 거부했고, privacy는 owner stream을 assertion마다 반복 drain한 테스트 오류였다.
- `33721ddc4d1`: 유효한 gap(`Last-Event-ID + 1`)과 한 번만 drain하는 live fixture로 보정했다. `41980035709`의 3 suite는 **성공**했다.
- 독립 후속 review: **With fixes**. replay가 현재 `session_id`의 identity를 상속해 credential 교체 후 이전 연결에 새 credential을 적용할 수 있는 P1을 추가로 확인했다. 반복 drain 지적은 `33721ddc4d1`에서 해소했다. `7909513a9f9`의 교체 회귀는 `41981658955`에서 기대 `[false; false; true]` 대신 `[true; true; true]`로 RED였다. `2329a5b18e0`은 exact `client_id`가 현재 등록과 일치할 때만 private를 허용하고, absent/stale ID는 shared만 남긴다. GREEN `41982732418`과 type-check `41982736264`는 **성공**, 독립 재검토는 **Approve**다. 최종 24 suite `41983585123`도 **24/24 OK, 실패·timeout 0**으로 완료했다.
- `41979508701`: production `843119b65f4`의 macOS binary와 `24b75a43376c2690b70f572eaf4c1b6d5caedcb21109662436da41ef8f78f307`를 확보했다. native behavior 12개 중 8개만 통과해 전체는 **실패**다. 같은 binary의 수정된 replay PTY는 Machine **9.185초**, Add-on **17.527초**로 성공했고, manual/reconnect가 각각 정확히 1회 읽힌 것을 JSON으로 확인했다.

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
- `remote-targeted-suites.txt`: 20/20 `OK`와 Lane 498초·spectator 20초·Memory 23초·Browser 21초를 확인한 suite 요약
- `followup-targeted-suites.txt`: 후속 24/24 `OK`, Lane 709초·spectator 22초·Memory 27초·Browser 25초를 확인한 suite 요약
- `candidate-{browser,memory,spectator,lanes}-result.log`: 최종 PTY 결과
- `candidate-browser-idle-result.log`, `candidate-help.txt`: 고정 idle와 CLI 결과
- `baseline-{browser,browser-idle,spectator,memory}-result.log`: 기준선 결과와 실패를 그대로 보존
- `browser-retry-red.json`: 수정 전 backoff 증폭 진단
- `summary.json`: source·hash·측정값·남은 범위의 기계 판독용 요약
- `independent-review.json`, `followup-independent-review.json`: 원래 whole-branch와 후속·재검토 판정 및 non-blocking 잔여 범위
- `artifacts/tui-sse-lanes-20261104/41979508701/followup-{spectator,lane}-requests.json`: 후속 macOS PTY의 manual/reconnect 각 1회 요청 증거

원본 크기가 큰 PTY/native artifact는 `artifacts/tui-sse-lanes-20261104/`에 둔다. 공유 main-worktree binary가 측정 중 바뀐 `f6d50a3…` v2 capture는 비교에서 제외했다. 실제 backend, 설치 상태, Play room, 그리고 위에 적은 native 실패는 미검증 또는 미완료 범위로 남는다.
