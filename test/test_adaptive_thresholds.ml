(** Tests for Handoff_quality and Adaptive_thresholds modules (P2-1) *)

open Alcotest

module HQ = Masc_mcp.Handoff_quality
module AT = Masc_mcp.Adaptive_thresholds

(* ============================================================
   Helper: create a handoff_outcome with defaults
   ============================================================ *)

let make_outcome
    ?(completion_rate = 0.90)
    ?(error_count = 0)
    ?(was_emergency = false)
    ?(duration_seconds = 5.0)
    ?(generation = 1)
    () : HQ.handoff_outcome =
  { completion_rate; error_count; was_emergency; duration_seconds; generation }

(* Approximate float equality *)
let near ?(eps = 0.0001) a b = Float.abs (a -. b) < eps

let float_near =
  testable (Fmt.float) (fun a b -> near a b)

(* ============================================================
   Handoff_quality tests
   ============================================================ *)

let test_high_completion_adjustment () =
  (* >= 95% completion + 0 errors => +0.01 + 0.005 = +0.015 *)
  let outcome = make_outcome ~completion_rate:0.96 ~error_count:0 () in
  let adj = HQ.compute_adjustment outcome in
  check float_near "95%+ completion + 0 errors" 0.015 adj

let test_good_completion_adjustment () =
  (* >= 85% completion + 0 errors => +0.005 + 0.005 = +0.01 *)
  let outcome = make_outcome ~completion_rate:0.88 ~error_count:0 () in
  let adj = HQ.compute_adjustment outcome in
  check float_near "85%+ completion + 0 errors" 0.01 adj

let test_mediocre_completion_adjustment () =
  (* >= 75% completion + 0 errors => -0.01 + 0.005 = -0.005 *)
  let outcome = make_outcome ~completion_rate:0.76 ~error_count:0 () in
  let adj = HQ.compute_adjustment outcome in
  check float_near "75%+ completion + 0 errors" (-0.005) adj

let test_low_completion_adjustment () =
  (* < 75% completion + 0 errors => -0.03 + 0.005 = -0.025 *)
  let outcome = make_outcome ~completion_rate:0.60 ~error_count:0 () in
  let adj = HQ.compute_adjustment outcome in
  check float_near "<75% completion + 0 errors" (-0.025) adj

let test_emergency_penalty () =
  (* 90% completion + emergency => +0.005 + (-0.02) + 0.005 = -0.01 *)
  let outcome = make_outcome ~completion_rate:0.90 ~was_emergency:true ~error_count:0 () in
  let adj = HQ.compute_adjustment outcome in
  check float_near "emergency penalty" (-0.01) adj

let test_error_penalty () =
  (* 90% completion + 3 errors => +0.005 + (-0.02) = -0.015 *)
  let outcome = make_outcome ~completion_rate:0.90 ~error_count:3 () in
  let adj = HQ.compute_adjustment outcome in
  check float_near "error penalty (>=3)" (-0.015) adj

let test_zero_error_bonus () =
  (* 90% completion + 0 errors => +0.005 + 0.005 = +0.01 *)
  let outcome = make_outcome ~completion_rate:0.90 ~error_count:0 () in
  let adj = HQ.compute_adjustment outcome in
  check float_near "zero error bonus" 0.01 adj

let test_clamp_delta_positive () =
  let clamped = HQ.clamp_delta 0.10 in
  check float_near "clamp positive to 0.03" 0.03 clamped

let test_clamp_delta_negative () =
  let clamped = HQ.clamp_delta (-0.10) in
  check float_near "clamp negative to -0.03" (-0.03) clamped

let test_clamp_delta_within_bounds () =
  let clamped = HQ.clamp_delta 0.02 in
  check float_near "within bounds stays" 0.02 clamped

(* ============================================================
   Adaptive_thresholds tests
   ============================================================ *)

let test_default_thresholds () =
  check float_near "default prepare" 0.50 AT.default_thresholds.prepare;
  check float_near "default handoff" 0.80 AT.default_thresholds.handoff

let test_safety_bounds () =
  check float_near "min_prepare" 0.20 AT.min_prepare;
  check float_near "max_handoff" 0.95 AT.max_handoff;
  check float_near "min_gap" 0.15 AT.min_gap

let test_clamp_thresholds_below_min () =
  let clamped = AT.clamp_thresholds { AT.prepare = 0.10; handoff = 0.30 } in
  check bool "prepare >= min_prepare" true (clamped.prepare >= AT.min_prepare -. 0.0001);
  check bool "gap maintained" true (clamped.handoff -. clamped.prepare >= AT.min_gap -. 0.0001)

let test_clamp_thresholds_above_max () =
  let clamped = AT.clamp_thresholds { AT.prepare = 0.85; handoff = 0.99 } in
  check bool "handoff <= max_handoff" true (clamped.handoff <= AT.max_handoff);
  check bool "gap maintained" true (clamped.handoff -. clamped.prepare >= AT.min_gap -. 0.0001)

let test_adapt_high_completion () =
  let state = AT.initial_state () in
  let outcome = make_outcome ~completion_rate:0.96 ~error_count:0 () in
  let new_state = AT.adapt state outcome in
  check bool "handoff increased" true
    (new_state.thresholds.handoff > state.thresholds.handoff);
  check bool "session_count incremented" true (new_state.session_count = 1)

let test_adapt_low_completion () =
  let state = AT.initial_state () in
  let outcome = make_outcome ~completion_rate:0.60 ~error_count:0 () in
  let new_state = AT.adapt state outcome in
  check bool "handoff decreased" true
    (new_state.thresholds.handoff < state.thresholds.handoff)

let test_adapt_emergency () =
  let state = AT.initial_state () in
  let outcome = make_outcome ~completion_rate:0.90 ~was_emergency:true ~error_count:0 () in
  let new_state = AT.adapt state outcome in
  (* Emergency: +0.005 (base) -0.02 (emergency) +0.005 (zero errors) = -0.01 *)
  check bool "handoff decreased from emergency" true
    (new_state.thresholds.handoff < state.thresholds.handoff)

let test_adapt_error_penalty () =
  let state = AT.initial_state () in
  let outcome = make_outcome ~completion_rate:0.90 ~error_count:5 () in
  let new_state = AT.adapt state outcome in
  (* +0.005 -0.02 = -0.015 *)
  check bool "handoff decreased from errors" true
    (new_state.thresholds.handoff < state.thresholds.handoff)

let test_prepare_never_below_min () =
  (* Start with low thresholds and push down repeatedly *)
  let state = ref (AT.initial_state ()) in
  state := { !state with thresholds = { AT.prepare = 0.25; handoff = 0.45 } };
  for _ = 1 to 20 do
    let outcome = make_outcome ~completion_rate:0.50 ~error_count:5 ~was_emergency:true () in
    state := AT.adapt !state outcome;
    (* Reset cumulative_delta to allow further adaptation *)
    state := { !state with cumulative_delta = 0.0 }
  done;
  check bool "prepare >= min_prepare" true
    ((!state).thresholds.prepare >= AT.min_prepare -. 0.0001)

let test_handoff_never_above_max () =
  let state = ref (AT.initial_state ()) in
  state := { !state with thresholds = { AT.prepare = 0.75; handoff = 0.93 } };
  for _ = 1 to 20 do
    let outcome = make_outcome ~completion_rate:0.99 ~error_count:0 () in
    state := AT.adapt !state outcome;
    state := { !state with cumulative_delta = 0.0 }
  done;
  check bool "handoff <= max_handoff" true
    ((!state).thresholds.handoff <= AT.max_handoff +. 0.0001)

let test_min_gap_maintained () =
  (* Push prepare close to handoff *)
  let t = AT.clamp_thresholds { AT.prepare = 0.78; handoff = 0.80 } in
  check bool "gap >= min_gap" true (t.handoff -. t.prepare >= AT.min_gap -. 0.0001)

let test_session_delta_clamped () =
  let state = AT.initial_state () in
  (* Apply multiple extreme outcomes — cumulative should be clamped *)
  let outcome1 = make_outcome ~completion_rate:0.99 ~error_count:0 () in
  let s1 = AT.adapt state outcome1 in
  let outcome2 = make_outcome ~completion_rate:0.99 ~error_count:0 () in
  let s2 = AT.adapt s1 outcome2 in
  (* cumulative_delta should be clamped to max_session_delta *)
  check bool "cumulative delta bounded" true
    (Float.abs s2.cumulative_delta <= HQ.max_session_delta +. 0.0001)

let test_multiple_adaptations_compound () =
  let state = AT.initial_state () in
  (* First: good outcome *)
  let o1 = make_outcome ~completion_rate:0.96 ~error_count:0 () in
  let s1 = AT.adapt state o1 in
  check bool "first adaptation increases" true
    (s1.thresholds.handoff > state.thresholds.handoff);
  (* Second: bad outcome (but session delta may limit) *)
  let o2 = make_outcome ~completion_rate:0.50 ~error_count:5 ~was_emergency:true () in
  let s2 = AT.adapt s1 o2 in
  check bool "session_count = 2" true (s2.session_count = 2)

let test_json_roundtrip () =
  let state = AT.initial_state () in
  let json = AT.state_to_json state in
  let restored = AT.state_of_json json in
  check bool "roundtrip succeeds" true (Option.is_some restored);
  let s = Option.get restored in
  check float_near "prepare preserved" state.thresholds.prepare s.thresholds.prepare;
  check float_near "handoff preserved" state.thresholds.handoff s.thresholds.handoff;
  check (int) "session_count preserved" state.session_count s.session_count

let test_save_load_roundtrip () =
  let tmp_dir = Filename.get_temp_dir_name () in
  let room = Printf.sprintf "test_room_%d" (Random.int 100000) in
  (* Override HOME to use temp dir *)
  let old_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" tmp_dir;
  let state = AT.initial_state () in
  let state = { state with thresholds = { AT.prepare = 0.55; handoff = 0.85 } } in
  AT.save_state ~room state;
  let loaded = AT.load_state ~room in
  (* Restore HOME *)
  (match old_home with
   | Some h -> Unix.putenv "HOME" h
   | None -> ());
  check bool "load succeeds" true (Option.is_some loaded);
  let s = Option.get loaded in
  check float_near "prepare preserved" 0.55 s.thresholds.prepare;
  check float_near "handoff preserved" 0.85 s.thresholds.handoff;
  (* Cleanup *)
  let path = Filename.concat (Filename.concat tmp_dir ".masc")
    (Printf.sprintf "adaptive_thresholds_%s.json" room) in
  (try Sys.remove path with Sys_error _ -> ())

let test_get_effective_disabled () =
  (* When disabled and no env vars, should return defaults *)
  let t = AT.get_effective_thresholds ~enabled:false ~room:"nonexistent" in
  check float_near "disabled returns default prepare" 0.50 t.prepare;
  check float_near "disabled returns default handoff" 0.80 t.handoff

let test_state_of_json_invalid () =
  let invalid = `String "not an object" in
  let result = AT.state_of_json invalid in
  check bool "invalid json returns None" true (Option.is_none result)

let test_state_of_json_missing_fields () =
  let partial = `Assoc [("prepare_threshold", `Float 0.5)] in
  let result = AT.state_of_json partial in
  check bool "partial json returns None" true (Option.is_none result)

(* ============================================================
   Test Runner
   ============================================================ *)

let () =
  run "Adaptive Thresholds (P2-1)" [
    "handoff_quality", [
      test_case "high completion adjustment" `Quick test_high_completion_adjustment;
      test_case "good completion adjustment" `Quick test_good_completion_adjustment;
      test_case "mediocre completion adjustment" `Quick test_mediocre_completion_adjustment;
      test_case "low completion adjustment" `Quick test_low_completion_adjustment;
      test_case "emergency penalty" `Quick test_emergency_penalty;
      test_case "error penalty (>=3)" `Quick test_error_penalty;
      test_case "zero error bonus" `Quick test_zero_error_bonus;
      test_case "clamp delta positive" `Quick test_clamp_delta_positive;
      test_case "clamp delta negative" `Quick test_clamp_delta_negative;
      test_case "clamp delta within bounds" `Quick test_clamp_delta_within_bounds;
    ];
    "adaptive_thresholds", [
      test_case "default thresholds" `Quick test_default_thresholds;
      test_case "safety bounds constants" `Quick test_safety_bounds;
      test_case "clamp below min" `Quick test_clamp_thresholds_below_min;
      test_case "clamp above max" `Quick test_clamp_thresholds_above_max;
      test_case "adapt high completion" `Quick test_adapt_high_completion;
      test_case "adapt low completion" `Quick test_adapt_low_completion;
      test_case "adapt emergency" `Quick test_adapt_emergency;
      test_case "adapt error penalty" `Quick test_adapt_error_penalty;
      test_case "prepare never below min" `Quick test_prepare_never_below_min;
      test_case "handoff never above max" `Quick test_handoff_never_above_max;
      test_case "min gap maintained" `Quick test_min_gap_maintained;
      test_case "session delta clamped" `Quick test_session_delta_clamped;
      test_case "multiple adaptations compound" `Quick test_multiple_adaptations_compound;
    ];
    "persistence", [
      test_case "JSON roundtrip" `Quick test_json_roundtrip;
      test_case "save/load roundtrip" `Quick test_save_load_roundtrip;
      test_case "get_effective disabled" `Quick test_get_effective_disabled;
      test_case "invalid JSON returns None" `Quick test_state_of_json_invalid;
      test_case "missing fields returns None" `Quick test_state_of_json_missing_fields;
    ];
  ]
