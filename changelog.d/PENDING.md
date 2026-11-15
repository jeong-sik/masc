### Internal

- The `direct_gate_resume` case "official-client Gate preserves authoritative
  denial" builds its unrelated second resolution as an approved one. It used
  to copy the admitted denial and attach a replay to it, so building the test
  input failed with `Replay_for_rejected_resolution` before the case reached
  its check that `observe_native_input` refuses a second resolution with no
  evidence projection (#52213, #PENDING).
