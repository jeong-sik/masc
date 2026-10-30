(** RFC spawn-a-process-that-outlives-the-call §5.

    No test here waits by sleeping. A test that slept would be asserting the
    thing this design removes, and it would pass on a fast machine for the same
    reason the [sleep 9] that motivated the RFC passed on one. Where a program
    under test sleeps, that is the subject: what is asserted is that the wait
    ended when the program said something, not when a clock did. *)

let with_eio f =
  Eio_main.run
  @@ fun env ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ()
;;

(* Long enough that reaching it means something is wrong, rather than that the
   machine was busy. A bound, not a cadence: nothing here waits for it. *)
let generous_bound_sec = 30.

(* Larger than anything these tests produce, except where the bound is the
   subject. *)
let ample_bytes = 1 lsl 16

let registry ?(run = "test-run") ?(output_limit_bytes = ample_bytes) () =
  match Spawn_registry.create ~run ~output_limit_bytes with
  | Some registry -> registry
  | None -> Alcotest.fail "the registry arguments must be accepted"
;;

let spawn_exn ~sw registry argv =
  match Spawn_registry.spawn ~sw registry argv with
  | Ok handle -> handle
  | Error message -> Alcotest.failf "spawn failed: %s" message
;;

let read_exn registry handle ~stream ~from =
  match Spawn_registry.read registry handle ~stream ~from with
  | Ok chunk -> chunk
  | Error `Unknown_handle -> Alcotest.fail "the handle must be known"
;;

let wait_exn registry handle ~until =
  match Spawn_registry.wait registry handle ~until ~timeout_sec:generous_bound_sec with
  | Ok waited -> waited
  | Error `Timed_out -> Alcotest.fail "the wait must end before its bound"
  | Error `Unknown_handle -> Alcotest.fail "the handle must be known"
;;

(* --- identity --- *)

let test_handles_are_never_reissued () =
  let registry = registry () in
  Eio.Switch.run
  @@ fun sw ->
  let first = spawn_exn ~sw registry [ "true" ] in
  let second = spawn_exn ~sw registry [ "true" ] in
  Alcotest.(check bool)
    "two spawns name two processes"
    false
    (Spawn_handle.equal first second)
;;

let test_a_handle_from_another_run_matches_nothing () =
  let mine = registry ~run:"run-a" () in
  let theirs = registry ~run:"run-b" () in
  Eio.Switch.run
  @@ fun sw ->
  let handle = spawn_exn ~sw theirs [ "true" ] in
  (* It parses -- it is a handle -- and it names nothing here. That is the
     difference between an identity and an index. *)
  match Spawn_registry.is_running mine handle with
  | Error `Unknown_handle -> ()
  | Ok _ -> Alcotest.fail "a handle from another run must not match a process here"
;;

let test_an_unknown_handle_is_an_answer () =
  let registry = registry () in
  match Spawn_handle.of_string "no-such-run-7" with
  | None -> Alcotest.fail "that text is a well-formed handle"
  | Some handle ->
    (match
       ( Spawn_registry.read registry handle ~stream:Spawn_registry.Stdout ~from:0
       , Spawn_registry.stop registry handle )
     with
     | Error `Unknown_handle, Error `Unknown_handle -> ()
     | _ -> Alcotest.fail "every operation answers Unknown_handle for a stale handle")
;;

(* --- liveness --- *)

let test_output_arrives_and_the_status_follows () =
  let registry = registry () in
  Eio.Switch.run
  @@ fun sw ->
  let handle = spawn_exn ~sw registry [ "printf"; "hello" ] in
  (match wait_exn registry handle ~until:Spawn_registry.Exit with
   | Spawn_registry.Exited (Unix.WEXITED 0) -> ()
   | Spawn_registry.Exited status ->
     Alcotest.failf "printf must exit zero, got %s"
       (match status with
        | Unix.WEXITED code -> "exit " ^ string_of_int code
        | Unix.WSIGNALED signal -> "signal " ^ string_of_int signal
        | Unix.WSTOPPED signal -> "stopped " ^ string_of_int signal)
   | Spawn_registry.Matched _ -> Alcotest.fail "waiting for Exit must answer Exited");
  let chunk = read_exn registry handle ~stream:Spawn_registry.Stdout ~from:0 in
  Alcotest.(check string) "the whole stream is there" "hello" chunk.Spawn_registry.bytes;
  Alcotest.(check int) "nothing was dropped" 0 chunk.Spawn_registry.dropped_before
;;

(* --- the wait is on the event --- *)

let test_a_wait_ends_when_the_program_speaks () =
  let registry = registry () in
  Eio.Switch.run
  @@ fun sw ->
  (* The program sleeps far longer than the assertion below allows. If the wait
     were on a clock it would either fire early -- before "ready" -- or run to
     the bound. It ends when the bytes arrive. *)
  let handle =
    spawn_exn ~sw registry [ "sh"; "-c"; "printf ready; exec sleep 60" ]
  in
  (match wait_exn registry handle ~until:(Spawn_registry.Output_contains
                                            { stream = Spawn_registry.Stdout
                                            ; needle = "ready"
                                            })
   with
   | Spawn_registry.Matched offset ->
     Alcotest.(check int) "the offset is past the needle" 5 offset
   | Spawn_registry.Exited _ ->
     Alcotest.fail "the program must still be running when its output matched");
  (match Spawn_registry.is_running registry handle with
   | Ok true -> ()
   | Ok false -> Alcotest.fail "matching output must not require the process to end"
   | Error `Unknown_handle -> Alcotest.fail "the handle must be known");
  ignore (Spawn_registry.stop registry handle)
;;

let test_a_bound_that_is_reached_is_reported () =
  let registry = registry () in
  Eio.Switch.run
  @@ fun sw ->
  let handle = spawn_exn ~sw registry [ "sleep"; "60" ] in
  match
    Spawn_registry.wait
      registry
      handle
      ~until:Spawn_registry.Exit
      ~timeout_sec:0.05
  with
  | Error `Timed_out -> ignore (Spawn_registry.stop registry handle)
  | Ok _ -> Alcotest.fail "a process that has not ended must not report a status"
  | Error `Unknown_handle -> Alcotest.fail "the handle must be known"
;;

(* --- reading --- *)

let test_reads_resume_without_a_gap_or_a_repeat () =
  let registry = registry () in
  Eio.Switch.run
  @@ fun sw ->
  let handle = spawn_exn ~sw registry [ "printf"; "abcdef" ] in
  ignore (wait_exn registry handle ~until:Spawn_registry.Exit);
  let first = read_exn registry handle ~stream:Spawn_registry.Stdout ~from:0 in
  let again =
    read_exn registry handle ~stream:Spawn_registry.Stdout ~from:first.Spawn_registry.next
  in
  Alcotest.(check string) "the first read has it all" "abcdef" first.Spawn_registry.bytes;
  Alcotest.(check string) "the second read repeats nothing" "" again.Spawn_registry.bytes;
  Alcotest.(check int) "and it is still at the end" first.Spawn_registry.next
    again.Spawn_registry.next
;;

let test_the_buffer_bound_says_what_it_cost () =
  let kept = 4 in
  let registry = registry ~output_limit_bytes:kept () in
  Eio.Switch.run
  @@ fun sw ->
  let handle = spawn_exn ~sw registry [ "printf"; "abcdefghij" ] in
  ignore (wait_exn registry handle ~until:Spawn_registry.Exit);
  let chunk = read_exn registry handle ~stream:Spawn_registry.Stdout ~from:0 in
  (* The tail is kept, not a prefix: a reader that fell behind sees what the
     process said most recently, and is told how much it missed. *)
  Alcotest.(check string) "the tail survives" "ghij" chunk.Spawn_registry.bytes;
  Alcotest.(check int) "and the cost is reported" 6 chunk.Spawn_registry.dropped_before;
  Alcotest.(check int) "the offset still counts the whole stream" 10
    chunk.Spawn_registry.next
;;

(* --- teardown --- *)

let test_a_process_does_not_outlive_its_switch () =
  let registry = registry () in
  let handle = ref None in
  Eio.Switch.run (fun sw -> handle := Some (spawn_exn ~sw registry [ "sleep"; "60" ]));
  (* The switch has ended. Nothing was stopped by hand. *)
  match !handle with
  | None -> Alcotest.fail "the spawn must have produced a handle"
  | Some handle ->
    (match Spawn_registry.is_running registry handle with
     | Ok false -> ()
     | Ok true -> Alcotest.fail "a spawned process must not outlive its switch"
     | Error `Unknown_handle -> Alcotest.fail "the handle must be known")
;;

(* --- arguments --- *)

let test_the_registry_refuses_what_it_cannot_mean () =
  Alcotest.(check bool)
    "an empty run issues nothing"
    true
    (Option.is_none (Spawn_registry.create ~run:"" ~output_limit_bytes:ample_bytes));
  Alcotest.(check bool)
    "a buffer that holds nothing is not a buffer"
    true
    (Option.is_none (Spawn_registry.create ~run:"r" ~output_limit_bytes:0))
;;

(* --- the handle itself --- *)

let test_a_handle_round_trips () =
  match Spawn_handle.issuer ~run:"run" with
  | None -> Alcotest.fail "a non-empty run must issue"
  | Some issuer ->
    let handle = Spawn_handle.issue issuer in
    (match Spawn_handle.of_string (Spawn_handle.to_string handle) with
     | Some parsed ->
       Alcotest.(check bool) "rendered and parsed is the same handle" true
         (Spawn_handle.equal handle parsed)
     | None -> Alcotest.fail "a handle this module rendered must parse")
;;

let test_a_run_may_contain_the_separator () =
  (* The run is read back from the last separator, so a run named after a
     branch or a date still round-trips. *)
  match Spawn_handle.issuer ~run:"2026-08-25-a" with
  | None -> Alcotest.fail "that run must issue"
  | Some issuer ->
    let handle = Spawn_handle.issue issuer in
    Alcotest.(check string) "the run survives" "2026-08-25-a" (Spawn_handle.run handle)
;;

let test_text_that_is_not_a_handle () =
  List.iter
    (fun text ->
       Alcotest.(check bool)
         ("not a handle: " ^ text)
         true
         (Option.is_none (Spawn_handle.of_string text)))
    [ ""
    ; "run"           (* no separator *)
    ; "-1"            (* no run *)
    ; "run-"          (* no number *)
    ; "run-0"         (* issued numbers start at one *)
    ; "run-x"
    ]
;;

let test_a_run_ending_in_the_separator_is_still_a_run () =
  (* [run--1] is [run-] and [1], not a malformed anything: reading from the
     last separator makes that unambiguous, and an issuer named [run-] renders
     exactly this. Asserted because the first draft of the test above claimed
     the opposite. *)
  match Spawn_handle.of_string "run--1" with
  | Some handle -> Alcotest.(check string) "the run keeps its tail" "run-" (Spawn_handle.run handle)
  | None -> Alcotest.fail "that is a well-formed handle"
;;

let test_an_empty_run_issues_nothing () =
  Alcotest.(check bool) "an issuer needs a run" true
    (Option.is_none (Spawn_handle.issuer ~run:""))
;;

let () =
  with_eio
  @@ fun () ->
  Alcotest.run
    "spawn_registry"
    [ ( "handle"
      , [ Alcotest.test_case "a handle round trips" `Quick test_a_handle_round_trips
        ; Alcotest.test_case
            "a run may contain the separator"
            `Quick
            test_a_run_may_contain_the_separator
        ; Alcotest.test_case "text that is not a handle" `Quick test_text_that_is_not_a_handle
        ; Alcotest.test_case
            "a run ending in the separator is still a run"
            `Quick
            test_a_run_ending_in_the_separator_is_still_a_run
        ; Alcotest.test_case
            "an empty run issues nothing"
            `Quick
            test_an_empty_run_issues_nothing
        ] )
    ; ( "identity"
      , [ Alcotest.test_case "handles are never reissued" `Quick test_handles_are_never_reissued
        ; Alcotest.test_case
            "a handle from another run matches nothing"
            `Quick
            test_a_handle_from_another_run_matches_nothing
        ; Alcotest.test_case
            "an unknown handle is an answer"
            `Quick
            test_an_unknown_handle_is_an_answer
        ] )
    ; ( "liveness"
      , [ Alcotest.test_case
            "output arrives and the status follows"
            `Quick
            test_output_arrives_and_the_status_follows
        ; Alcotest.test_case
            "a wait ends when the program speaks"
            `Quick
            test_a_wait_ends_when_the_program_speaks
        ; Alcotest.test_case
            "a bound that is reached is reported"
            `Quick
            test_a_bound_that_is_reached_is_reported
        ] )
    ; ( "reading"
      , [ Alcotest.test_case
            "reads resume without a gap or a repeat"
            `Quick
            test_reads_resume_without_a_gap_or_a_repeat
        ; Alcotest.test_case
            "the buffer bound says what it cost"
            `Quick
            test_the_buffer_bound_says_what_it_cost
        ] )
    ; ( "lifetime"
      , [ Alcotest.test_case
            "a process does not outlive its switch"
            `Quick
            test_a_process_does_not_outlive_its_switch
        ; Alcotest.test_case
            "the registry refuses what it cannot mean"
            `Quick
            test_the_registry_refuses_what_it_cannot_mean
        ] )
    ]
;;
