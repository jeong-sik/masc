(* The verdicts, the level and the lag bar of the views' grid (RFC-0515 §2.4.2,
   §2.4.3).
   The columns and the words they draw are not checked here (constitution
   354-355); these are the decisions the columns draw from. *)

module Grid = Masc_tui_keeper_grid
module Decode = Masc.Tui_decode
module Pulse = Masc.Keeper_turn_pulse

let health raw = Option.get (Decode.keeper_health_of_string raw)

let runtime health : Decode.keeper_runtime =
  { kr_name = "keeper"
  ; kr_identity = Error "not needed"
  ; kr_portrait = Decode.Unavailable "test"
  ; kr_candle_account_revision = Ok None
  ; kr_health = health
  ; kr_paused = false
  ; kr_next_action = None
  ; kr_keepalive_running = true
  ; kr_activation_mode = Decode.Activation_autonomous
  ; kr_runtime_id = "test.runtime"
  ; kr_phase = Option.get (Decode.keeper_phase_of_string "running")
  ; kr_sandbox_profile = "docker"
  ; kr_runtime_blocker_summary = None
  ; kr_last_failure = None
  ; kr_runtime_blocker_signature = None
  ; kr_runtime_lane_observation = None
  ; kr_runtime_path_rest = Ok None
  ; kr_operator_disposition = Ok None
  ; kr_failing_since = None
  ; kr_recent_turns = None
  }

let now = 1_794_000_000.
let slot = float_of_int Pulse.slot_seconds

let slot_ago ?(ok = 0) ?(rested = 0) ?(failed = 0) slots : Pulse.slot =
  { starts_at = Pulse.slot_start (now -. (float_of_int slots *. slot))
  ; tally = { ok; rested; failed } }

let with_pulse slots (runtime : Decode.keeper_runtime) =
  { runtime with kr_recent_turns = Some { known_since = now -. (48. *. slot); slots } }

let resting : (Decode.keeper_path_rest option, string) result =
  Ok
    (Some
       (Decode.Path_rest_resting
          { runtime_id = "lane.a"; release_at = now +. 600.; release_basis = Decode.Stated_by_provider }))

let verdict_label = function
  | Grid.Failing { resting = false } -> "failing"
  | Grid.Failing { resting = true } -> "failing, resting"
  | Grid.Paused -> "paused"
  | Grid.Recovered -> "recovered"
  | Grid.Sound -> "sound"
  | Grid.Other -> "other"

let check name expected reading =
  Alcotest.(check string) name expected (verdict_label (Grid.verdict ~now reading))

let test_failing_comes_first () =
  let failing = runtime (health "failing") in
  check "a failing health reading is failing" "failing" (Some failing);
  check "a failing Keeper whose path rests is resting" "failing, resting"
    (Some { failing with kr_runtime_path_rest = resting });
  check "a path that serves is not a rest" "failing"
    (Some
       { failing with
         kr_runtime_path_rest = Ok (Some (Decode.Path_rest_serving { runtime_id = "lane.a" }))
       });
  check "a rest that did not read is not a rest" "failing"
    (Some { failing with kr_runtime_path_rest = Error "unreadable" });
  check "a paused failing Keeper is still failing" "failing"
    (Some { failing with kr_paused = true })

let test_the_pause_comes_before_the_pulse () =
  check "a paused Keeper with a failed half hour is paused" "paused"
    (Some (with_pulse [ slot_ago ~failed:1 0 ] { (runtime (health "healthy")) with kr_paused = true }));
  check "a paused offline Keeper is paused" "paused"
    (Some { (runtime (health "offline")) with kr_paused = true })

let test_a_failed_half_hour_in_the_last_twelve_hours_is_a_recovery () =
  let healthy = runtime (health "healthy") in
  let idle = runtime (health "idle") in
  check "a failed turn in the current half hour" "recovered"
    (Some (with_pulse [ slot_ago ~ok:2 ~failed:1 0 ] healthy));
  check "a rested turn counts as failed" "recovered"
    (Some (with_pulse [ slot_ago ~rested:1 3 ] idle));
  check "the oldest of the 24 half hours still counts" "recovered"
    (Some (with_pulse [ slot_ago ~failed:1 (Grid.recovery_slots - 1) ] healthy));
  check "a slot stamped after now counts as the newest" "recovered"
    (Some (with_pulse [ slot_ago ~failed:1 (-1) ] healthy));
  check "one half hour further back does not" "sound"
    (Some (with_pulse [ slot_ago ~failed:1 Grid.recovery_slots ] healthy));
  check "ok turns alone are sound" "sound" (Some (with_pulse [ slot_ago ~ok:3 0 ] healthy));
  check "no pulse is no failed half hour" "sound" (Some idle)

let test_offline_and_unread_are_other () =
  check "an offline Keeper with a failed half hour is not recovered" "other"
    (Some (with_pulse [ slot_ago ~failed:1 0 ] (runtime (health "offline"))));
  check "a Keeper the roster did not read" "other" None

let test_the_level_rises_with_the_value () =
  let level peak value = Grid.level_glyph ~peak value in
  let lowest = level 8 0 and highest = level 8 8 in
  Alcotest.(check bool) "the lowest and the highest differ" false (String.equal lowest highest);
  Alcotest.(check string) "zero is the lowest" lowest (level 8 0);
  Alcotest.(check string) "a negative value is the lowest" lowest (level 8 (-3));
  Alcotest.(check string) "an eighth of the peak is the lowest" lowest (level 8 1);
  Alcotest.(check bool) "a little over an eighth is one step up" false
    (String.equal lowest (level 80 11));
  Alcotest.(check string) "the peak is the highest" highest (level 236 236);
  Alcotest.(check string) "a value over a smaller peak stops at the highest" highest (level 3 9);
  Alcotest.(check string) "a peak of zero reads the value as the peak" highest (level 0 5);
  let steps = List.sort_uniq String.compare (List.init 8 (fun i -> level 8 (i + 1))) in
  Alcotest.(check int) "eight values over a peak of eight draw eight levels" 8 (List.length steps)

let test_the_lag_bar_fills_its_share_of_the_peak () =
  let fill cells peak lag = Grid.lag_fill ~cells ~peak lag in
  Alcotest.(check int) "no lag fills nothing" 0 (fill 25 40 0);
  Alcotest.(check int) "a negative lag fills nothing" 0 (fill 25 40 (-2));
  Alcotest.(check int) "the peak fills the bar" 25 (fill 25 40 40);
  Alcotest.(check int) "a quarter of the peak rounds down" 6 (fill 25 40 10);
  Alcotest.(check int) "half the peak rounds half a cell up" 13 (fill 25 40 20);
  Alcotest.(check int) "a lag too small for a cell still fills one" 1 (fill 25 1000 1);
  Alcotest.(check int) "a lag over a smaller peak stops at the end" 25 (fill 25 3 9);
  Alcotest.(check int) "a peak of zero reads the lag as the peak" 17 (fill 17 0 5);
  Alcotest.(check int) "a bar of no cells fills none" 0 (fill 0 40 40)

let () =
  Alcotest.run "tui_keeper_grid"
    [ ( "verdict"
      , [ Alcotest.test_case "failing comes first" `Quick test_failing_comes_first
        ; Alcotest.test_case "the pause comes before the pulse" `Quick
            test_the_pause_comes_before_the_pulse
        ; Alcotest.test_case "a failed half hour in the last twelve hours is a recovery" `Quick
            test_a_failed_half_hour_in_the_last_twelve_hours_is_a_recovery
        ; Alcotest.test_case "offline and unread are other" `Quick test_offline_and_unread_are_other
        ] )
    ; ( "level"
      , [ Alcotest.test_case "the level rises with the value" `Quick
            test_the_level_rises_with_the_value
        ] )
    ; ( "lag bar"
      , [ Alcotest.test_case "the lag bar fills its share of the peak" `Quick
            test_the_lag_bar_fills_its_share_of_the_peak
        ] )
    ]
