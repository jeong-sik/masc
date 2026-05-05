(** Diagnostic accessor smoke tests for [Keeper_turn_slot.*_slot_holders].

    Goal: prove the holder snapshot API surfaces the keeper currently
    holding a slot, sorted by descending hold time. This is the data
    that operators need when [turn_available=0] starves the fleet — the
    longest-holding peer is the actual blocker.

    The tests run inside [Eio_main.run] because [with_keeper_turn_slot_for_test]
    requires an Eio fiber context (Eio.Mutex on holder_table). *)

module KK = Masc_mcp.Keeper_keepalive

let with_fresh_state body () =
  Eio_main.run @@ fun _env ->
    KK.reset_autonomous_completion_for_test ();
    KK.reset_autonomous_turn_queue_for_test ();
    body ()

let assert_eq ~msg ~expected ~actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected=%d actual=%d" msg expected actual)

let test_turn_slot_holders_empty_when_no_slot_held () =
  let now = Time_compat.now () in
  let holders = KK.turn_slot_holders ~now in
  assert_eq ~msg:"turn holders empty" ~expected:0 ~actual:(List.length holders)

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

let () =
  let cases =
    [
      "turn slot holders empty when nothing held",
        test_turn_slot_holders_empty_when_no_slot_held;
      "autonomous slot holders records keeper during acquire",
        test_autonomous_slot_holders_records_during_acquire;
      "holders dropped after with_keeper_turn_slot exits",
        test_holders_released_after_slot_returned;
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
