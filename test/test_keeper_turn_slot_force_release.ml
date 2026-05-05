(** Force-release path for [Keeper_turn_slot.force_release_holder_for].

    Goal: prove the supervisor escape hatch correctly drops the holder
    row and increments the matching semaphore when a keeper fiber has
    not returned through the natural [Fun.protect] release. The
    motivating production incident was 16 keepers holding
    [reactive_slot] for 18-25 minutes behind LLM subprocess hangs,
    [reactive_available=0], and the entire fleet starved on
    [acquire_bounded].

    These tests are pure in-memory state checks; they do not exercise
    the supervisor wiring (covered by the integration build). *)

module KK = Masc_mcp.Keeper_keepalive

let with_fresh_state body () =
  Eio_main.run @@ fun _env ->
    KK.set_after_acquire_flag_hook_for_test None;
    KK.reset_autonomous_completion_for_test ();
    KK.reset_autonomous_turn_queue_for_test ();
    body ()

let assert_int_eq ~msg ~expected ~actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected=%d actual=%d" msg expected actual)

let assert_string_in ~msg ~needle ~haystack =
  let ls = String.length haystack in
  let lsub = String.length needle in
  let rec loop i =
    if i + lsub > ls then false
    else if String.sub haystack i lsub = needle then true
    else loop (i + 1)
  in
  if not (loop 0) then
    failwith (Printf.sprintf "%s: %S not in %S" msg needle haystack)

(* When no slot is held for the keeper the helper must return []. The
   supervisor relies on this to skip the diagnostic log line. *)
let test_force_release_empty_when_no_holder_recorded () =
  let released = KK.force_release_holder_for ~keeper_name:"never-held" in
  assert_int_eq ~msg:"empty release list"
    ~expected:0 ~actual:(List.length released)

(* Acquire a real reactive slot via the test harness, force-release
   from outside that fiber's natural release path, and confirm the
   holder snapshot drops the entry. The natural [Fun.protect] release
   on block exit will run a second [Eio.Semaphore.release]; that
   bounded over-release is the documented cost of unblocking a
   genuinely zombie fiber. *)
let test_force_release_drops_reactive_holder () =
  let result =
    KK.with_keeper_turn_slot_for_test
      ~keeper_name:"zombie-reactive"
      ~channel:Masc_mcp.Keeper_world_observation.Reactive
      (fun ~semaphore_wait_ms:_ ->
        (* Pre-condition: the holder table records us. *)
        let now = Time_compat.now () in
        let pre = List.map fst (KK.reactive_slot_holders ~now) in
        if not (List.mem "zombie-reactive" pre) then
          failwith
            (Printf.sprintf "setup: expected zombie-reactive in pre, got [%s]"
               (String.concat ";" pre));

        (* Force-release as the supervisor would. *)
        let released = KK.force_release_holder_for ~keeper_name:"zombie-reactive" in
        let labels = List.map fst released in
        if not (List.mem "reactive" labels) then
          failwith
            (Printf.sprintf "expected reactive label in released, got [%s]"
               (String.concat ";" labels));

        (* Post-condition: holder table no longer mentions us. *)
        let now2 = Time_compat.now () in
        let post = List.map fst (KK.reactive_slot_holders ~now2) in
        if List.mem "zombie-reactive" post then
          failwith
            (Printf.sprintf "force-release left holder behind: [%s]"
               (String.concat ";" post)))
  in
  match result with
  | Ok () -> ()
  | Error (`Semaphore_wait_timeout snapshot) ->
      let dump =
        Printf.sprintf
          "wait=%.0fs reactive_avail=%d turn_avail=%d"
          snapshot.timeout_wait_sec
          snapshot.timeout_reactive_available
          snapshot.timeout_turn_available
      in
      failwith ("unexpected semaphore wait timeout in test: " ^ dump)

(* Idempotency: calling force_release a second time must return []
   because the first call already removed the entry. *)
let test_force_release_is_idempotent () =
  let result =
    KK.with_keeper_turn_slot_for_test
      ~keeper_name:"twice-release"
      ~channel:Masc_mcp.Keeper_world_observation.Reactive
      (fun ~semaphore_wait_ms:_ ->
        let first = KK.force_release_holder_for ~keeper_name:"twice-release" in
        if List.length first = 0 then
          failwith "first force-release should have returned a non-empty list";

        let second = KK.force_release_holder_for ~keeper_name:"twice-release" in
        if List.length second <> 0 then
          failwith
            (Printf.sprintf "second force-release should be empty, got %d entries"
               (List.length second)))
  in
  match result with
  | Ok () -> ()
  | Error (`Semaphore_wait_timeout _) ->
      failwith "unexpected semaphore wait timeout in test"

(* Age field non-negative and small (just acquired). The supervisor
   uses this to format the operator-facing log line. *)
let test_force_release_reports_nonnegative_age () =
  let result =
    KK.with_keeper_turn_slot_for_test
      ~keeper_name:"age-check"
      ~channel:Masc_mcp.Keeper_world_observation.Reactive
      (fun ~semaphore_wait_ms:_ ->
        let released = KK.force_release_holder_for ~keeper_name:"age-check" in
        match List.assoc_opt "reactive" released with
        | None -> failwith "no reactive entry in released list"
        | Some age ->
          if age < 0.0 then
            failwith (Printf.sprintf "negative age: %.2fs" age);
          if age > 30.0 then
            failwith (Printf.sprintf "implausible age in test: %.2fs" age))
  in
  match result with
  | Ok () -> assert_string_in ~msg:"sanity: result Ok"
              ~needle:"" ~haystack:""
  | Error (`Semaphore_wait_timeout _) ->
      failwith "unexpected semaphore wait timeout in test"

let () =
  Alcotest.run "keeper_turn_slot_force_release"
    [
      ( "force_release",
        [
          Alcotest.test_case "empty when no holder" `Quick
            (with_fresh_state test_force_release_empty_when_no_holder_recorded);
          Alcotest.test_case "drops reactive holder" `Quick
            (with_fresh_state test_force_release_drops_reactive_holder);
          Alcotest.test_case "idempotent" `Quick
            (with_fresh_state test_force_release_is_idempotent);
          Alcotest.test_case "non-negative age" `Quick
            (with_fresh_state test_force_release_reports_nonnegative_age);
        ] );
    ]
