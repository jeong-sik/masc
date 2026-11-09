가설은 소스상 성립합니다. 고정 source는 `16dd4aa47803259dc516a1c2acbc244d9985c0cd`이고, 이번 핵심 main/schedule/input-reader 파일들은 B `bae45a3e0e70de9c238e2a16410ccf15d295a4be`와 같습니다. C를 구현하거나 실행하지 않았습니다.

`Render_schedule.take`는 Render를 선택할 때 pending을 비우고 Build 전 `now_ns`를 마지막 시각에 저장합니다(`render_schedule.ml:38`). main은 한 loop에서 `read_input` 이벤트 하나를 받아 처리한 뒤 Input 요청을 세웁니다(`masc_tui.ml:32121`, `:33806`). 16ms interval보다 긴 normal Build+Present가 끝난 다음에는 그 deadline이 이미 지났으므로, 다음 이벤트 하나를 처리하고도 ready input이 남아 있으면 바로 또 Render를 선택할 수 있습니다. 단, paste는 여러 bytes를 하나의 이벤트로 받을 수 있으므로 이를 모든 byte마다 frame이 생긴다는 주장으로 넓히지 않습니다.

최소 변경 후보는 `.mli`에 `val completed : t -> now_ns:int64 -> unit`을 먼저 선언하고, 이 함수가 timestamp만 갱신하도록 하는 것입니다. `take`의 기존 start 기록은 유지합니다. main의 normal Render 분기에서 현재 `time_present` 호출이 반환한 바로 뒤(`masc_tui.ml:42639` 뒤)에 한 번 호출하는 배치가 맞습니다. 전체 match 바깥에 놓으면 Idle/Wait나 Build를 건너뛴 분기도 완료로 기록하므로 틀립니다.

```ocaml
(* existing normal Render branch, after all its current work *)
Masc_tui_frame_timing.time_present
  (* existing arguments and present_frame call *);
Render_schedule.completed render_schedule
  ~now_ns:(Mtime_clock.elapsed_ns ())
```

현재 interval16ms, frame 시작0ms·완료64ms라는 논리 clock으로 보면 다음 Input+ready at65ms는 기존 Render에서 Wait_until80ms로 바뀝니다. 이어지는 loop들은 pending Input의 timeout0을 유지해 이미 온 입력을 계속 읽습니다. queue가67ms에 비면 기존 Input+not-ready 분기가 바로 Render하므로 무조건16ms를 더 기다리지 않습니다. 입력이 계속 있으면80ms에는 Render해 paint가 무한히 굶지 않게 됩니다. 이것은 기존 요청·deadline·input timeout을 재사용하며 별도 timer/knob를 요구하지 않습니다.

완료는 pending을 비우면 안 됩니다. `present_frame` 자체가 preset confirmation을 보여 준 뒤 추가 Input 요청을 세울 수 있습니다(`masc_tui.ml:30089`–`:30096`). 완료 처리에서 이를 지우면 필요한 후속 frame이 없어집니다. Force도 보존해야 합니다. resize/console damage의 Force는 deadline과 ready input을 모두 무시하는 기존 우선순위를 유지합니다.

`Frame_presenter.Unchanged`도 normal Build 비용을 이미 지불했으므로 같은 완료 시각으로 pace해야 합니다. 다만 Unchanged를 Presented로 바꾸거나 input authority를 새로 확정하면 안 됩니다(`frame_presenter.mli:77`). normal 분기 마지막에는 title 출력, presenter flush, portrait flush 및 post-output input/ownership bookkeeping이 모두 끝나 있습니다. presenter 함수 내부 직후에 checkpoint를 두면 뒤의 picture writes를 빼먹습니다. write/flush 예외가 나면 성공 완료를 호출하지 않고 기존 예외 경로를 유지합니다.

image/MSX가 terminal을 가진 Render 분기와 `defer_owned_frame` 분기는 별도입니다(`masc_tui.ml:42523`, `:42534`). 이 둘에는 새 normal-frame completed를 붙이지 않는 것이 최소 범위입니다. 특히 take의 start 기록을 제거해 completion만 기준으로 삼으면 실제 Build가 없는 owned deferral에서 옛 deadline을 계속 쓰며 Background 재시도를 돌릴 수 있습니다. 기존 fallback을 남기면 skip/defer 정책과 interval이 유지됩니다. ready-input 검사에 incomplete sequence·paste 전체 상태를 새로 섞지 않아야 recovery frame과 ownership quarantine 의미도 그대로입니다.

효과의 반례와 비용도 분명합니다. ready input이 한 개뿐이면 처리 뒤 ready=false가 되어 기존 코드도 즉시 그리므로 개선할 backlog가 없습니다. Force가 반복되거나 이벤트 handler 자체가16ms보다 무거우면 이 변경으로 drain이 보장되지 않습니다. 다음 heavy frame은 계속 동기적으로 UI domain을 막습니다. image/MSX의 외부 출력 병목도 이 normal checkpoint로 해결되지 않습니다.

Background-only cadence는 정책이 달라집니다. 다른 비용을 무시하면 기존 주기는 대략 `max(interval,work)`이고 제안은 `work+interval`입니다. 예를 들어 work64ms이면64→80ms, work3ms이면16→19ms입니다. 새 숫자 knob는 없지만 animation/background 처리율은 떨어질 수 있습니다. 따라서 frame 수 감소를 latency 개선으로 바꾸어 말하지 말고, B 측정 후 이 tradeoff가 필요한지 결정해야 합니다.

의미 있는 검증은 화면 문구나 row 순서가 아닌 clock/state decision입니다. [추천8개 사례](recommended-state-decision-tests.json)는 heavy completion 뒤 Wait_until, final drained input의 즉시 Render, continuous input의 기존 deadline 보장, render 도중 새 요청 보존과 Force 우선순위, owned deferral fallback, idle 무작업, background cadence, Unchanged render pacing을 다룹니다. 기존 `test/test_tui_render_schedule.ml:77` 및 `:98`의 burst/final-input 사례를 확장하고 console Force 검증을 유지하는 범위가 적절합니다. 지금 이 tests를 제품에 쓰거나 실행한 것은 아닙니다.

채택 전 실측에서는 B와 같은 binary provenance·history·key workload·helper hash를 맞추고, key-to-prefix latency와 실제 입력 간격·누락, frame Build/Present 비용을 분리해야 합니다. 한 worker의 background decode/local read가 실제로 진행되는지도 함께 봐야 합니다. 이 분석은 source 메커니즘과 위험을 정리하며 GC/latency 개선이나 input loss 해소를 판정하지 않습니다. 근거는 [고정 source 좌표](source-excerpts.json), [identity](source-identities.json), [구조화된 분석](ANALYSIS.json)에 있습니다.

후속: Background cadence를 유지하는 root의 두 시각 설계는 [TWO-CLOCK-FOLLOWUP.md](TWO-CLOCK-FOLLOWUP.md)에서 따로 검토했습니다. 구현 후보를 결정할 때는 이 후속 계약을 우선 봅니다. 초기 single-clock의 비용 분석은 원래 제안의 기록으로 남겼습니다.
