root가 제시한 두 시각 안은 앞 분석의 Background cadence 비용을 피합니다. 이것은 초기 single-clock 제안에 대한 후속 설계 검토이며 C 구현·실행 검증이 아닙니다.

| pending/상태 | 기준과 결정 |
| --- | --- |
| None | Idle, input timeout은 기존 maximum |
| Force | ready 여부와 deadline을 무시하고 Render |
| Input + ready=false | 즉시 Render |
| Input + ready=true | `(최신 Completed가 있으면 Completed, 없으면 Started) + 기존 interval` |
| Background | take와 input timeout 모두 Started + 기존 interval |
| take가 Render 선택 | pending 소비, Started=now, 이전 Completed 제거 |
| completed | Completed만 갱신. Started·pending·우선순위 보존 |

예를 들어 Started0/Completed64이면 Background@65는 기존처럼 Render이고 Input+ready@65는 Wait_until80입니다. Input+drained@65와 Force는 즉시 Render입니다. 따라서 pending Input이 생긴 backlog에는 drain 창을 주면서 Background-only의64→80ms 변화는 만들지 않습니다. 새 Render 때 Completed를 비우므로 Build가 없는 owned deferral/image 분기도 현재 attempt의 start fallback을 쓰며 이전 frame의 완료 시각을 빌리지 않습니다.

`completed` 위치는 앞 검토와 같습니다. main의 normal Render branch `time_present` 반환 직후에만 두고 Unchanged도 포함합니다. whole match 뒤, image/MSX, owned deferral, Idle/Wait에는 두지 않습니다. 현재 production take 호출은 main 한 곳이고 그 normal Build/Present가 동기적으로 반환한 뒤 완료를 기록하므로 서로 다른 frame 완료가 경합하는 호출 경로는 발견하지 않았습니다. render 도중 생긴 Input/Force 요청을 완료가 지우지 않아야 합니다.

새 반례로 볼 만한 semantic 회귀는 찾지 못했습니다. 한계는 남습니다. pending=Background인 상태에서 이번 loop의 read 이후에 ready input이 도착하면 start deadline을 따라 Render할 수 있습니다. 이는 기존 동작을 의도적으로 남긴 것이며, 이 정책은 Input 요청을 이미 세운 backlog부터 개선합니다. 이벤트 handler 자체의 긴 동기 작업, 다음 heavy frame 중 재축적되는 입력, Force-heavy 또는 외부 image/MSX 경로는 해결하지 않습니다.

상태 invariant는 「Completed는 가장 최근 Started의 완료」입니다. 제품 구현에서 이를 두 optional 값으로 흩어 놓기보다 private `Started`/`Completed {started;completed}` 합타입, 또는 Started가 필수인 outer option으로 표현할 수 있습니다. 어느 표현이든 새 take에서 이전 완료를 제거하고 completed에서 pending을 건드리지 않는 결정 계약이 핵심입니다. 별도 timer·knob·budget이 필요하지 않습니다.

[추천 state-decision 사례8개](TWO-CLOCK-FOLLOWUP.json)는 slow Input-ready window, 기존 Background cadence, drained/Force 즉시성, 새 attempt의 완료 초기화, render 중 새 요청 보존, idle 무작업, 고정 due에서 continuous input의 frame 보장, Unchanged 비용과 authority 분리를 검증합니다. 화면 문구·배치·row 또는 frame 개수 검사가 아닌 논리 clock과 결정 결과입니다. 제품 tests는 아직 작성·실행하지 않았습니다.

B native 측정이 이 병목을 여전히 보여 줄 때 C를 구현해 비교하는 순서가 맞습니다. 이 후속 설계 자체가 GC/latency 감소나 queue 안정성을 증명하지 않습니다.
