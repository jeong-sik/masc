(** Diagnostic accessor smoke tests for [Keeper_turn_slot.*_slot_holders].

    Goal: prove the holder snapshot API surfaces the keeper currently
    holding a slot, sorted by descending hold time. This is the data
    that operators need when [turn_available=0] starves the fleet — the
    longest-holding peer is the actual blocker.

    The tests run inside [Eio_main.run] because [with_keeper_turn_slot_for_test]
    requires an Eio fiber context (Eio.Mutex on holder_table). *)

module KK = Masc_mcp.Keeper_keepalive
module SW = Masc_mcp.Keeper_stale_watchdog

exception After_flag_injected

let with_fresh_state body () =
  Eio_main.run @@ fun _env ->
    KK.set_after_acquire_flag_hook_for_test None;
    KK.reset_autonomous_completion_for_test ();
    KK.reset_autonomous_turn_queue_for_test ();
    body ()

let assert_eq ~msg ~expected ~actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected=%d actual=%d" msg expected actual)

let assert_string_eq ~msg ~expected ~actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected=%S actual=%S" msg expected actual)

let test_turn_slot_holders_empty_when_no_slot_held () =
  let now = Time_compat.now () in
  let holders = KK.turn_slot_holders ~now in
  assert_eq ~msg:"turn holders empty" ~expected:0 ~actual:(List.length holders)

let test_format_slot_holders_truncates_and_rounds () =
  let rendered =
    KK.format_slot_holders
      ~limit:2
      [ "oldest", 12.4; "next", 3.6; "third", 1.0 ]
  in
  assert_string_eq
    ~msg:"holder summary"
    ~expected:"[oldest/12s, next/4s, +1 more]"
    ~actual:rendered

let test_slot_holders_summary_empty_pools () =
  let summary = KK.slot_holders_summary ~now:(Time_compat.now ()) () in
  assert_string_eq
    ~msg:"empty holder pool summary"
    ~expected:"turn_holders=[] autonomous_holders=[] reactive_holders=[]"
    ~actual:summary

let test_autonomous_slot_holders_records_during_acquire () =
  let result =
    KK.with_keeper_turn_slot_for_test
      ~keeper_name:"diagnostic-keeper"
      ~channel:Masc_mcp.Keeper_world_observation.Scheduled_autonomous
      (fun ~semaphore_wait_ms:_ ->
        let now = Time_compat.now () in
        let holders = KK.autonomous_slot_holders ~now in
        let names = List.map fst holders in
        if not (List.mem "diagnostic-keeper" names) then
          failwith
            (Printf.sprintf
              "expected 'diagnostic-keeper' in autonomous holders, got [%s]"
              (String.concat "; " names));
        (* Hold time should be non-negative and small (just acquired). *)
        let held_for = List.assoc "diagnostic-keeper" holders in
        if held_for < 0.0 || held_for > 5.0 then
          failwith
            (Printf.sprintf "unreasonable held_for=%.2fs" held_for);
        ())
  in
  match result with
  | Ok () -> ()
  | Error (`Semaphore_wait_timeout _) ->
      failwith "unexpected semaphore wait timeout in test"

let test_holders_released_after_slot_returned () =
  (* After the [with_keeper_turn_slot_for_test] block exits, the slot must
     be released and the holder dropped from the table. *)
  let result =
    KK.with_keeper_turn_slot_for_test
      ~keeper_name:"diag-release"
      ~channel:Masc_mcp.Keeper_world_observation.Reactive
      (fun ~semaphore_wait_ms:_ -> ())
  in
  (match result with
   | Ok () -> ()
   | Error (`Semaphore_wait_timeout _) ->
       failwith "unexpected semaphore wait timeout in test setup");
  let now = Time_compat.now () in
  let names = List.map fst (KK.reactive_slot_holders ~now) in
  if List.mem "diag-release" names then
    failwith "diag-release still in reactive holders after release"

(* PR #13099 review: pin that [slot_holders_summary] reflects the holder
   currently inside [with_keeper_turn_slot_for_test], so a regression where
   the WARN/last_blocker wiring drops the holder snapshot is caught
   directly (not just at the formatter level). *)
let test_slot_holders_summary_reflects_active_holder () =
  let result =
    KK.with_keeper_turn_slot_for_test
      ~keeper_name:"diag-summary"
      ~channel:Masc_mcp.Keeper_world_observation.Scheduled_autonomous
      (fun ~semaphore_wait_ms:_ ->
        let summary = KK.slot_holders_summary ~now:(Time_compat.now ()) () in
        let mentions s sub =
          let ls = String.length s in
          let lsub = String.length sub in
          let rec loop i =
            if i + lsub > ls then false
            else if String.sub s i lsub = sub then true
            else loop (i + 1)
          in
          loop 0
        in
        if not (mentions summary "diag-summary") then
          failwith
            (Printf.sprintf
              "expected slot_holders_summary to mention 'diag-summary'; got %S"
              summary);
        ())
  in
  match result with
  | Ok () -> ()
  | Error (`Semaphore_wait_timeout _) ->
      failwith "unexpected semaphore wait timeout in test"

let test_reactive_slot_released_when_hook_raises_after_flag () =
  let keeper_name = "diag-after-flag" in
  let before = KK.reactive_turn_semaphore_value_for_test () in
  KK.set_after_acquire_flag_hook_for_test
    (Some
       (fun ~label ~keeper_name:seen ->
          if label = "reactive" && seen = keeper_name then
            raise After_flag_injected));
  let clear_hook () = KK.set_after_acquire_flag_hook_for_test None in
  (try
     ignore
       (KK.with_keeper_turn_slot_for_test
          ~keeper_name
          ~channel:Masc_mcp.Keeper_world_observation.Reactive
          (fun ~semaphore_wait_ms:_ ->
             failwith "hook should raise before user callback"));
     clear_hook ();
     failwith "expected injected hook to raise"
   with
   | After_flag_injected -> clear_hook ()
   | exn ->
       clear_hook ();
       raise exn);
  let after = KK.reactive_turn_semaphore_value_for_test () in
  assert_eq ~msg:"reactive slot released after injected failure"
    ~expected:before ~actual:after;
  let names = List.map fst (KK.reactive_slot_holders ~now:(Time_compat.now ())) in
  if List.mem keeper_name names then
    failwith "reactive holder leaked after injected failure"

let test_watchdog_slot_holder_age_reflects_active_holder () =
  let keeper_name = "diag-watchdog-holder" in
  let result =
    KK.with_keeper_turn_slot_for_test
      ~keeper_name
      ~channel:Masc_mcp.Keeper_world_observation.Reactive
      (fun ~semaphore_wait_ms:_ ->
        match
          SW.slot_holder_age_for_test ~now:(Time_compat.now ()) ~keeper_name
        with
        | None -> failwith "expected watchdog holder age for active holder"
        | Some age ->
            if age < 0.0 || age > 5.0 then
              failwith
                (Printf.sprintf "unreasonable watchdog holder age=%.2fs" age))
  in
  match result with
  | Ok () -> ()
  | Error (`Semaphore_wait_timeout _) ->
      failwith "unexpected semaphore wait timeout in test"

let test_force_release_stale_holder_restores_slots_once () =
  let keeper_name = "diag-force-release" in
  let turn_before = KK.turn_semaphore_value_for_test () in
  let reactive_before = KK.reactive_turn_semaphore_value_for_test () in
  let result =
    KK.with_keeper_turn_slot_for_test
      ~keeper_name
      ~channel:Masc_mcp.Keeper_world_observation.Reactive
      (fun ~semaphore_wait_ms:_ ->
        assert_eq ~msg:"turn acquired" ~expected:(turn_before - 1)
          ~actual:(KK.turn_semaphore_value_for_test ());
        assert_eq ~msg:"reactive acquired" ~expected:(reactive_before - 1)
          ~actual:(KK.reactive_turn_semaphore_value_for_test ());
        let released = KK.force_release_stale_holder ~keeper_name in
        if not (List.mem "turn" released) then
          failwith "force release did not report turn slot";
        if not (List.mem "reactive" released) then
          failwith "force release did not report reactive slot";
        if List.mem "autonomous" released then
          failwith "force release unexpectedly reported autonomous slot";
        assert_eq ~msg:"turn restored by force release" ~expected:turn_before
          ~actual:(KK.turn_semaphore_value_for_test ());
        assert_eq ~msg:"reactive restored by force release"
          ~expected:reactive_before
          ~actual:(KK.reactive_turn_semaphore_value_for_test ());
        let nested =
          KK.with_keeper_turn_slot_for_test
            ~keeper_name
            ~channel:Masc_mcp.Keeper_world_observation.Reactive
            (fun ~semaphore_wait_ms:_ ->
              let released_again =
                KK.force_release_stale_holder ~keeper_name
              in
              if not (List.mem "turn" released_again) then
                failwith "second force release did not report turn slot";
              if not (List.mem "reactive" released_again) then
                failwith "second force release did not report reactive slot")
        in
        (match nested with
         | Ok () -> ()
         | Error (`Semaphore_wait_timeout _) ->
             failwith "unexpected nested semaphore wait timeout");
        assert_eq ~msg:"nested force release preserved turn count"
          ~expected:turn_before
          ~actual:(KK.turn_semaphore_value_for_test ());
        assert_eq ~msg:"nested force release preserved reactive count"
          ~expected:reactive_before
          ~actual:(KK.reactive_turn_semaphore_value_for_test ()))
  in
  (match result with
   | Ok () -> ()
   | Error (`Semaphore_wait_timeout _) ->
       failwith "unexpected semaphore wait timeout in test");
  assert_eq ~msg:"turn not double-released by finalizer" ~expected:turn_before
    ~actual:(KK.turn_semaphore_value_for_test ());
  assert_eq ~msg:"reactive not double-released by finalizer"
    ~expected:reactive_before
    ~actual:(KK.reactive_turn_semaphore_value_for_test ())

let test_force_release_marker_is_acquisition_scoped () =
  let keeper_name = "diag-force-generation" in
  let turn_before = KK.turn_semaphore_value_for_test () in
  let reactive_before = KK.reactive_turn_semaphore_value_for_test () in
  let result =
    KK.with_keeper_turn_slot_for_test
      ~keeper_name
      ~channel:Masc_mcp.Keeper_world_observation.Reactive
      (fun ~semaphore_wait_ms:_ ->
        let released = KK.force_release_stale_holder ~keeper_name in
        if not (List.mem "turn" released) then
          failwith "force release did not report turn slot";
        if not (List.mem "reactive" released) then
          failwith "force release did not report reactive slot";
        assert_eq ~msg:"turn restored by force release" ~expected:turn_before
          ~actual:(KK.turn_semaphore_value_for_test ());
        assert_eq ~msg:"reactive restored by force release"
          ~expected:reactive_before
          ~actual:(KK.reactive_turn_semaphore_value_for_test ());
        let nested =
          KK.with_keeper_turn_slot_for_test
            ~keeper_name
            ~channel:Masc_mcp.Keeper_world_observation.Reactive
            (fun ~semaphore_wait_ms:_ -> ())
        in
        (match nested with
         | Ok () -> ()
         | Error (`Semaphore_wait_timeout _) ->
             failwith "unexpected nested semaphore wait timeout");
        assert_eq
          ~msg:"nested normal finalizer did not consume stale turn marker"
          ~expected:turn_before
          ~actual:(KK.turn_semaphore_value_for_test ());
        assert_eq
          ~msg:"nested normal finalizer did not consume stale reactive marker"
          ~expected:reactive_before
          ~actual:(KK.reactive_turn_semaphore_value_for_test ()))
  in
  (match result with
   | Ok () -> ()
   | Error (`Semaphore_wait_timeout _) ->
       failwith "unexpected semaphore wait timeout in test");
  assert_eq ~msg:"old turn marker consumed by old finalizer"
    ~expected:turn_before
    ~actual:(KK.turn_semaphore_value_for_test ());
  assert_eq ~msg:"old reactive marker consumed by old finalizer"
    ~expected:reactive_before
    ~actual:(KK.reactive_turn_semaphore_value_for_test ())

let () =
  let cases =
    [
      "turn slot holders empty when nothing held",
        test_turn_slot_holders_empty_when_no_slot_held;
      "format slot holders truncates and rounds",
        test_format_slot_holders_truncates_and_rounds;
      "slot holders summary reports empty pools",
        test_slot_holders_summary_empty_pools;
      "autonomous slot holders records keeper during acquire",
        test_autonomous_slot_holders_records_during_acquire;
      "holders dropped after with_keeper_turn_slot exits",
        test_holders_released_after_slot_returned;
      "slot_holders_summary mentions the active holder",
        test_slot_holders_summary_reflects_active_holder;
      "reactive slot releases when hook raises after acquired flag",
        test_reactive_slot_released_when_hook_raises_after_flag;
      "watchdog holder fallback sees active holder",
        test_watchdog_slot_holder_age_reflects_active_holder;
      "force release restores stale holder slots once",
        test_force_release_stale_holder_restores_slots_once;
      "force release markers are acquisition scoped",
        test_force_release_marker_is_acquisition_scoped;
    ]
  in
  List.iter
    (fun (name, body) ->
      try
        with_fresh_state body ();
        Printf.printf "ok   %s\n" name
      with exn ->
        Printf.printf "FAIL %s: %s\n" name (Printexc.to_string exn);
        exit 1)
    cases
