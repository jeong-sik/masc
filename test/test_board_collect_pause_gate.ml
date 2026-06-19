(** Regression: a paused keeper must not collect board events.

    [Keeper_heartbeat_loop_board_events.collect_keepalive_board_events] advances
    and acks the per-keeper board cursor as a side effect of collection. A
    paused keeper is not scheduled to run a turn, so collecting (and advancing
    the cursor) for it would step the cursor past posts it never processed —
    silently dropping them with no requeue. This pins the pure decision gate
    [should_collect_board_events] that guards that side effect. *)

open Alcotest
module BE = Masc.Keeper_heartbeat_loop_board_events

let gate ~warm ~paused =
  BE.should_collect_board_events ~proactive_warmup_elapsed:warm ~paused

let test_warm_unpaused_collects () =
  check bool "warmed + unpaused keeper collects board events" true
    (gate ~warm:true ~paused:false)

(* The regression: before the fix, a warmed keeper collected (and advanced the
   cursor) regardless of pause state, dropping board posts for paused keepers. *)
let test_warm_paused_skips () =
  check bool "warmed + PAUSED keeper must not collect (cursor stays put)" false
    (gate ~warm:true ~paused:true)

let test_cold_unpaused_skips () =
  check bool "not-yet-warmed keeper does not collect" false
    (gate ~warm:false ~paused:false)

let test_cold_paused_skips () =
  check bool "not-yet-warmed + paused keeper does not collect" false
    (gate ~warm:false ~paused:true)

let () =
  run "board_collect_pause_gate"
    [
      ( "should_collect_board_events",
        [
          test_case "warm + unpaused -> collect" `Quick test_warm_unpaused_collects;
          test_case "warm + paused -> skip" `Quick test_warm_paused_skips;
          test_case "cold + unpaused -> skip" `Quick test_cold_unpaused_skips;
          test_case "cold + paused -> skip" `Quick test_cold_paused_skips;
        ] );
    ]
