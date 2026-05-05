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
    KK.clear_force_released_markers_for_test ();
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

(* Reviewer #13190: existing tests exercise force_release_stale_holder
   while the outer fiber's protect-finalizer eventually runs to
   completion.  The watchdog restart path looks different — the
   supervisor force-releases the slot from outside the stale fiber,
   the stale fiber raises before normal cleanup, and a replacement
   keeper takes the slot under the same keeper_name.  Pin that the
   replacement's acquire/release cycle is unaffected by any leftover
   marker from the previous generation: both semaphores must return
   to baseline even after the outer fiber exits via exception, and a
   fresh acquisition under the same keeper_name must complete cleanly
   with semaphores still at baseline. *)
let test_force_release_marker_does_not_leak_to_replacement () =
  let keeper_name = "diag-replacement-leak" in
  let turn_before = KK.turn_semaphore_value_for_test () in
  let reactive_before = KK.reactive_turn_semaphore_value_for_test () in
  let exception Outer_simulated_raise in
  (try
     let _ =
       KK.with_keeper_turn_slot_for_test
         ~keeper_name
         ~channel:Masc_mcp.Keeper_world_observation.Reactive
         (fun ~semaphore_wait_ms:_ ->
           let released = KK.force_release_stale_holder ~keeper_name in
           if not (List.mem "turn" released) then
             failwith "force release did not report turn slot";
           if not (List.mem "reactive" released) then
             failwith "force release did not report reactive slot";
           raise Outer_simulated_raise)
     in
     ()
   with Outer_simulated_raise -> ());
  assert_eq
    ~msg:"turn semaphore restored to baseline after outer raise"
    ~expected:turn_before
    ~actual:(KK.turn_semaphore_value_for_test ());
  assert_eq
    ~msg:"reactive semaphore restored to baseline after outer raise"
    ~expected:reactive_before
    ~actual:(KK.reactive_turn_semaphore_value_for_test ());
  let result =
    KK.with_keeper_turn_slot_for_test
      ~keeper_name
      ~channel:Masc_mcp.Keeper_world_observation.Reactive
      (fun ~semaphore_wait_ms:_ -> ())
  in
  (match result with
   | Ok () -> ()
   | Error (`Semaphore_wait_timeout _) ->
       failwith "replacement acquire timed out — leftover force-release \
                 marker may have skipped the previous release");
  assert_eq
    ~msg:"turn semaphore baseline preserved after replacement keeper run"
    ~expected:turn_before
    ~actual:(KK.turn_semaphore_value_for_test ());
  assert_eq
    ~msg:"reactive semaphore baseline preserved after replacement keeper run"
    ~expected:reactive_before
    ~actual:(KK.reactive_turn_semaphore_value_for_test ())

let test_force_released_autonomous_holder_does_not_stamp_completion () =
  let keeper_name = "diag-force-autonomous" in
  let turn_before = KK.turn_semaphore_value_for_test () in
  let autonomous_before = KK.autonomous_turn_semaphore_value_for_test () in
  let result =
    KK.with_keeper_turn_slot_for_test
      ~keeper_name
      ~channel:Masc_mcp.Keeper_world_observation.Scheduled_autonomous
      (fun ~semaphore_wait_ms:_ ->
         let released = KK.force_release_stale_holder ~keeper_name in
         if not (List.mem "turn" released) then
           failwith "force release did not report turn slot";
         if not (List.mem "autonomous" released) then
           failwith "force release did not report autonomous slot";
         assert_eq ~msg:"turn restored by force release" ~expected:turn_before
           ~actual:(KK.turn_semaphore_value_for_test ());
         assert_eq ~msg:"autonomous restored by force release"
           ~expected:autonomous_before
           ~actual:(KK.autonomous_turn_semaphore_value_for_test ()))
  in
  (match result with
   | Ok () -> ()
   | Error (`Semaphore_wait_timeout _) ->
       failwith "unexpected semaphore wait timeout in test");
  assert_eq ~msg:"turn not double-released by autonomous finalizer"
    ~expected:turn_before
    ~actual:(KK.turn_semaphore_value_for_test ());
  assert_eq ~msg:"autonomous not double-released by finalizer"
    ~expected:autonomous_before
    ~actual:(KK.autonomous_turn_semaphore_value_for_test ());
  let delay =
    let ticket = KK.enqueue_autonomous_waiter_for_test "diag-waiting-peer" in
    Fun.protect
      ~finally:(fun () -> KK.drop_autonomous_waiter_for_test ticket)
      (fun () ->
         KK.fairness_delay_sec_at ~keeper_name ~now:(Time_compat.now ()))
  in
  if delay <> 0.0 then
    failwith
      (Printf.sprintf
         "force-released autonomous holder stamped normal completion: delay=%.3f"
         delay)

let test_retry_control_releases_and_reacquires_reactive_slot () =
  let keeper_name = "diag-retry-reactive" in
  let turn_before = KK.turn_semaphore_value_for_test () in
  let reactive_before = KK.reactive_turn_semaphore_value_for_test () in
  let result =
    KK.with_keeper_turn_slot_control_for_test
      ~keeper_name
      ~channel:Masc_mcp.Keeper_world_observation.Reactive
      (fun ~semaphore_wait_ms:_ ~slot_control ->
         assert_eq ~msg:"turn acquired before retry release"
           ~expected:(turn_before - 1)
           ~actual:(KK.turn_semaphore_value_for_test ());
         assert_eq ~msg:"reactive acquired before retry release"
           ~expected:(reactive_before - 1)
           ~actual:(KK.reactive_turn_semaphore_value_for_test ());
         slot_control.release_for_retry ();
         assert_eq ~msg:"turn restored during retry release"
           ~expected:turn_before
           ~actual:(KK.turn_semaphore_value_for_test ());
         assert_eq ~msg:"reactive restored during retry release"
           ~expected:reactive_before
           ~actual:(KK.reactive_turn_semaphore_value_for_test ());
         let names =
           List.map fst (KK.reactive_slot_holders ~now:(Time_compat.now ()))
         in
         if List.mem keeper_name names then
           failwith "reactive holder remained after retry release";
         let nested =
           KK.with_keeper_turn_slot_for_test
             ~keeper_name:"diag-retry-reactive-peer"
             ~channel:Masc_mcp.Keeper_world_observation.Reactive
             (fun ~semaphore_wait_ms:_ -> ())
         in
         (match nested with
          | Ok () -> ()
          | Error (`Semaphore_wait_timeout _) ->
              failwith "nested keeper could not acquire released slot");
         (match slot_control.reacquire_after_retry () with
          | Error (`Semaphore_wait_timeout _) ->
              failwith "retry reacquire unexpectedly timed out"
          | Ok retry_wait_ms when retry_wait_ms < 0 ->
              failwith "retry reacquire returned negative wait"
          | Ok _ -> ());
         assert_eq ~msg:"turn reacquired after retry release"
           ~expected:(turn_before - 1)
           ~actual:(KK.turn_semaphore_value_for_test ());
         assert_eq ~msg:"reactive reacquired after retry release"
           ~expected:(reactive_before - 1)
           ~actual:(KK.reactive_turn_semaphore_value_for_test ()))
  in
  (match result with
   | Ok () -> ()
   | Error (`Semaphore_wait_timeout _) ->
       failwith "unexpected semaphore wait timeout in test");
  assert_eq ~msg:"turn baseline after retry control finalizer"
    ~expected:turn_before
    ~actual:(KK.turn_semaphore_value_for_test ());
  assert_eq ~msg:"reactive baseline after retry control finalizer"
    ~expected:reactive_before
    ~actual:(KK.reactive_turn_semaphore_value_for_test ())

let test_retry_control_autonomous_release_skips_completion_stamp () =
  let keeper_name = "diag-retry-autonomous" in
  let turn_before = KK.turn_semaphore_value_for_test () in
  let autonomous_before = KK.autonomous_turn_semaphore_value_for_test () in
  let result =
    KK.with_keeper_turn_slot_control_for_test
      ~keeper_name
      ~channel:Masc_mcp.Keeper_world_observation.Scheduled_autonomous
      (fun ~semaphore_wait_ms:_ ~slot_control ->
         assert_eq ~msg:"turn acquired before autonomous retry release"
           ~expected:(turn_before - 1)
           ~actual:(KK.turn_semaphore_value_for_test ());
         assert_eq ~msg:"autonomous acquired before retry release"
           ~expected:(autonomous_before - 1)
           ~actual:(KK.autonomous_turn_semaphore_value_for_test ());
         slot_control.release_for_retry ();
         assert_eq ~msg:"turn restored by autonomous retry release"
           ~expected:turn_before
           ~actual:(KK.turn_semaphore_value_for_test ());
         assert_eq ~msg:"autonomous restored by retry release"
           ~expected:autonomous_before
           ~actual:(KK.autonomous_turn_semaphore_value_for_test ());
         let delay =
           let ticket =
             KK.enqueue_autonomous_waiter_for_test "diag-retry-waiting-peer"
           in
           Fun.protect
             ~finally:(fun () -> KK.drop_autonomous_waiter_for_test ticket)
             (fun () ->
                KK.fairness_delay_sec_at
                  ~keeper_name ~now:(Time_compat.now ()))
         in
         if delay <> 0.0 then
           failwith
             (Printf.sprintf
                "retry release stamped normal autonomous completion: delay=%.3f"
                delay);
         (match slot_control.reacquire_after_retry () with
          | Error (`Semaphore_wait_timeout _) ->
              failwith "autonomous retry reacquire unexpectedly timed out"
          | Ok _ -> ());
         assert_eq ~msg:"turn reacquired after autonomous retry release"
           ~expected:(turn_before - 1)
           ~actual:(KK.turn_semaphore_value_for_test ());
         assert_eq ~msg:"autonomous reacquired after retry release"
           ~expected:(autonomous_before - 1)
           ~actual:(KK.autonomous_turn_semaphore_value_for_test ()))
  in
  (match result with
   | Ok () -> ()
   | Error (`Semaphore_wait_timeout _) ->
       failwith "unexpected semaphore wait timeout in test");
  assert_eq ~msg:"turn baseline after autonomous retry control"
    ~expected:turn_before
    ~actual:(KK.turn_semaphore_value_for_test ());
  assert_eq ~msg:"autonomous baseline after retry control"
    ~expected:autonomous_before
    ~actual:(KK.autonomous_turn_semaphore_value_for_test ())

let test_force_release_marker_ttl_bounds_unfinalized_fibers () =
  KK.clear_force_released_markers_for_test ();
  let marked_at = 1_000.0 in
  KK.add_force_released_marker_for_test
    ~label:"turn"
    ~keeper_name:"diag-orphan-marker"
    ~acquisition_id:42
    ~marked_at;
  assert_eq ~msg:"orphan marker recorded" ~expected:1
    ~actual:(KK.force_released_marker_count_for_test ());
  KK.purge_force_released_markers_for_test
    ~now:(marked_at +. KK.force_released_marker_ttl_sec_for_test +. 1.0);
  assert_eq ~msg:"expired orphan marker purged" ~expected:0
    ~actual:(KK.force_released_marker_count_for_test ())

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
      "force release marker does not leak to replacement",
        test_force_release_marker_does_not_leak_to_replacement;
      "force released autonomous holder skips completion stamp",
        test_force_released_autonomous_holder_does_not_stamp_completion;
      "retry control releases and reacquires reactive slot",
        test_retry_control_releases_and_reacquires_reactive_slot;
      "retry control autonomous release skips completion stamp",
        test_retry_control_autonomous_release_skips_completion_stamp;
      "force release marker ttl bounds unfinalized fibers",
        test_force_release_marker_ttl_bounds_unfinalized_fibers;
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
