open Alcotest

(** Unit tests for [Actor_mailbox] — RFC-0059 Phase 2 PR-5.

    Tests run inside [Eio_main.run] because [Actor_mailbox.run]
    consumes from an [Eio.Stream.t] which only makes sense inside an
    Eio scheduler.  Each test runs in its own [Eio.Switch.run] so a
    cancellation in one test does not leak fibers into the next. *)

module M = Actor_mailbox
module T = Actor_types

(* ── create ────────────────────────────────────────────── *)

let test_create_default_capacity () =
  Eio_main.run (fun _env ->
    let actor = M.create "default" in
    check int "starts empty" 0 (M.length actor))

let test_create_explicit_capacity () =
  Eio_main.run (fun _env ->
    let actor = M.create ~capacity:1 "tiny" in
    check int "starts empty" 0 (M.length actor))

let test_create_zero_capacity_rejected () =
  Eio_main.run (fun _env ->
    check_raises "zero capacity raises Invalid_argument"
      (Invalid_argument
         "Actor_mailbox.create: capacity must be >= 1, got 0")
      (fun () -> ignore (M.create ~capacity:0 "rejected")))

let test_create_negative_capacity_rejected () =
  Eio_main.run (fun _env ->
    check_raises "negative capacity raises Invalid_argument"
      (Invalid_argument
         "Actor_mailbox.create: capacity must be >= 1, got -3")
      (fun () -> ignore (M.create ~capacity:(-3) "rejected")))

(* ── send / length / run ───────────────────────────────── *)

let test_send_increments_length () =
  Eio_main.run (fun _env ->
    let actor = M.create ~capacity:8 "buffer" in
    M.send actor "a";
    M.send actor "b";
    check int "two messages enqueued" 2 (M.length actor))

let test_run_processes_messages_and_stops () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let actor = M.create ~capacity:8 "echo" in
      let received = ref [] in
      Eio.Fiber.fork ~sw (fun () ->
        M.run actor ~init:()
          ~handle:(fun () msg ->
            received := msg :: !received;
            if String.equal msg "STOP" then ((), T.Stop)
            else ((), T.Continue)));
      M.send actor "first";
      M.send actor "second";
      M.send actor "STOP"));
  ()

let test_run_threads_state () =
  let final_count = ref 0 in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let actor = M.create ~capacity:8 "counter" in
      Eio.Fiber.fork ~sw (fun () ->
        M.run actor ~init:0
          ~handle:(fun count msg ->
            match msg with
            | `Inc -> (count + 1, T.Continue)
            | `Snapshot ->
                final_count := count;
                (count, T.Stop)));
      M.send actor `Inc;
      M.send actor `Inc;
      M.send actor `Inc;
      M.send actor `Snapshot));
  check int "state threaded across messages" 3 !final_count

(* ── stop_signal ────────────────────────────────────────── *)

let test_stop_observed_between_messages () =
  let processed = ref 0 in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let actor = M.create ~capacity:8 "stoppable" in
      Eio.Fiber.fork ~sw (fun () ->
        M.run actor ~init:()
          ~handle:(fun () _msg ->
            incr processed;
            ((), T.Continue)));
      M.send actor "one";
      Eio.Fiber.yield ();
      M.stop actor;
      M.send actor "two"));
  (* The actor processed at least the first message; [stop] flips the
     signal between iterations so the loop exits after the in-flight
     handler returns.  The contract is "post-message observation" —
     we do not assert exact count because the second message may or
     may not be drained depending on fiber scheduling. *)
  check bool "actor exited" true (!processed >= 1)

(* ── Suite ──────────────────────────────────────────────── *)

let () =
  Alcotest.run "Actor_mailbox" [
    "create", [
      test_case "default capacity" `Quick test_create_default_capacity;
      test_case "explicit capacity" `Quick test_create_explicit_capacity;
      test_case "zero capacity rejected" `Quick test_create_zero_capacity_rejected;
      test_case "negative capacity rejected" `Quick test_create_negative_capacity_rejected;
    ];
    "send_run", [
      test_case "send increments length" `Quick test_send_increments_length;
      test_case "run processes and stops" `Quick test_run_processes_messages_and_stops;
      test_case "run threads state" `Quick test_run_threads_state;
    ];
    "stop_signal", [
      test_case "stop observed between messages" `Quick test_stop_observed_between_messages;
    ];
  ]
