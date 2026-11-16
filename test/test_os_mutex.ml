open Alcotest

(* RFC a-fiber-that-suspends-while-holding-an-os-mutex-fails-at-unlock, §6.1.
   Case 8 lives in test_keeper_efficiency.ml, next to the read it changes.
   The cases inside Eio run on the posix backend, the one masc pins (D6).
   Where two fibers take part, a promise orders them, so no case depends on
   which fiber Eio starts first. *)

let () = Printexc.record_backtrace true

let suspension_name = function
  | Os_mutex.Suspend -> "Suspend"
  | Os_mutex.Fork -> "Fork"
  | Os_mutex.Run_in_systhread -> "Run_in_systhread"
  | Os_mutex.Await_readable -> "Await_readable"
  | Os_mutex.Await_writable -> "Await_writable"
  | Os_mutex.Other -> "Other"
;;

let suspension =
  testable (fun ppf s -> Format.pp_print_string ppf (suspension_name s)) ( = )
;;

let contains ~needle haystack = Agent_core_strings.contains_substring ~haystack ~needle

(* The handler runs on the stack [protect] was called on, so the caller
   stack of a record reaches the line in this file that called it. *)
let reaches_this_file backtrace =
  let here = Filename.basename __FILE__ in
  match Printexc.backtrace_slots backtrace with
  | None -> false
  | Some slots ->
    Array.exists
      (fun slot ->
        match Printexc.Slot.location slot with
        | Some location -> String.equal (Filename.basename location.Printexc.filename) here
        | None -> false)
      slots
;;

(* [f] must end in [Held_across_suspension] without an exception of the
   section's own. *)
let expect_held ?by ~mutex what f =
  match f () with
  | () -> failf "%s: the section ran to the end" what
  | exception Os_mutex.Held_across_suspension { record; body_raised = None } ->
    check string (what ^ ": mutex") mutex record.Os_mutex.mutex_name;
    Option.iter
      (fun expected ->
        check suspension (what ^ ": effect") expected record.Os_mutex.suspension)
      by;
    check
      bool
      (what ^ ": the caller stack reaches the line that called protect")
      true
      (reaches_this_file record.Os_mutex.protect_called_at)
  | exception Os_mutex.Held_across_suspension { body_raised = Some (exn, _); _ } ->
    failf "%s: the section raised %s" what (Printexc.to_string exn)
;;

(* The calls of §6.1 case 1. Where a call performs one kind of switching
   effect, the record must name it. *)
let switching_calls env =
  [ ( "Fs_compat.Systhread_host.run"
    , None
    , fun () -> Fs_compat.Systhread_host.run ignore )
  ; ( "Eio.Path.stat"
    , None
    , fun () ->
        ignore
          (Eio.Path.stat
             ~follow:true
             Eio.Path.(Eio.Stdenv.fs env / Filename.get_temp_dir_name ())) )
  ; "Eio.Fiber.yield", Some Os_mutex.Suspend, Eio.Fiber.yield
  ; ( "Eio.Process.run"
    , None
    , fun () -> Eio.Process.run (Eio.Stdenv.process_mgr env) [ "true" ] )
  ; ( "Eio_unix.run_in_systhread"
    , Some Os_mutex.Run_in_systhread
    , fun () -> Eio_unix.run_in_systhread ignore )
  ; ( "Eio.Fiber.fork"
    , Some Os_mutex.Fork
    , fun () -> Eio.Switch.run (fun sw -> Eio.Fiber.fork ~sw ignore) )
  ]
;;

(* §6.1 case 1. *)
let switching_sections () =
  Eio_posix.run
  @@ fun env ->
  List.iter
    (fun (what, by, call) ->
      let mutex = Os_mutex.create ~name:what () in
      expect_held ?by ~mutex:what what (fun () -> Os_mutex.protect mutex call))
    (switching_calls env)
;;

(* §6.1 case 2. *)
let non_switching_sections () =
  Eio_posix.run
  @@ fun env ->
  let mutex = Os_mutex.create ~name:"non-switching" () in
  let value =
    Eio.Switch.run
    @@ fun sw ->
    Os_mutex.protect mutex (fun () ->
      Eio.Fiber.check ();
      ignore (Eio.Time.Mono.now (Eio.Stdenv.mono_clock env));
      ignore (Eio_unix.pipe sw);
      42)
  in
  check int "the section's value" 42 value
;;

(* §6.1 case 3. *)
let own_exception_after_switch () =
  Eio_posix.run
  @@ fun _env ->
  let mutex = Os_mutex.create ~name:"own-exception" () in
  match
    Os_mutex.protect mutex (fun () ->
      Eio.Fiber.yield ();
      failwith "the section's own")
  with
  | () -> fail "the section ran to the end"
  | exception
      Os_mutex.Held_across_suspension
        { body_raised = Some (Failure message, backtrace); _ } ->
    check string "the section's exception" "the section's own" message;
    check bool "its backtrace is kept" true (Printexc.raw_backtrace_length backtrace > 0)
  | exception Os_mutex.Held_across_suspension { body_raised = (None | Some _); _ } ->
    fail "Held_across_suspension did not carry the section's Failure"
;;

(* §6.1 case 4. *)
let released_after_failure () =
  Eio_posix.run
  @@ fun _env ->
  let mutex = Os_mutex.create ~name:"released" () in
  expect_held ~mutex:"released" "Fiber.yield" (fun () ->
    Os_mutex.protect mutex Eio.Fiber.yield);
  check
    (option unit)
    "taken at once after the failure"
    (Some ())
    (Os_mutex.try_protect mutex ignore);
  check
    (option unit)
    "not taken while held"
    None
    (Os_mutex.protect mutex (fun () -> Os_mutex.try_protect mutex ignore))
;;

(* §6.1 case 5. Eio.Mutex and Eio.Stream suspend while holding a lock of
   their own and release it from the scheduler. A handler that refused the
   effect would leave that lock held. *)
let eio_locks_survive () =
  Eio_posix.run
  @@ fun _env ->
  let eio_mutex = Eio.Mutex.create () in
  let holding, set_holding = Eio.Promise.create () in
  let section = Os_mutex.create ~name:"waits-for-eio-mutex" () in
  Eio.Fiber.both
    (fun () ->
      Eio.Mutex.use_rw ~protect:false eio_mutex (fun () ->
        Eio.Promise.resolve set_holding ();
        Eio.Fiber.yield ()))
    (fun () ->
      Eio.Promise.await holding;
      expect_held ~mutex:"waits-for-eio-mutex" "Eio.Mutex held elsewhere" (fun () ->
        Os_mutex.protect section (fun () ->
          Eio.Mutex.use_rw ~protect:false eio_mutex ignore)));
  Eio.Mutex.use_rw ~protect:false eio_mutex ignore;
  let stream = Eio.Stream.create 1 in
  let waiting, set_waiting = Eio.Promise.create () in
  let section = Os_mutex.create ~name:"waits-for-stream" () in
  Eio.Fiber.both
    (fun () ->
      expect_held ~mutex:"waits-for-stream" "empty Eio.Stream" (fun () ->
        Os_mutex.protect section (fun () ->
          Eio.Promise.resolve set_waiting ();
          ignore (Eio.Stream.take stream : int))))
    (fun () ->
      Eio.Promise.await waiting;
      Eio.Stream.add stream 1);
  Eio.Stream.add stream 2;
  check int "the stream still carries values" 2 (Eio.Stream.take stream)
;;

(* fd 2 goes to a fresh file while [f] runs. Returns what reached it. *)
let stderr_of f =
  let path = Filename.temp_file "os_mutex" ".stderr" in
  flush stderr;
  let saved = Unix.dup ~cloexec:true Unix.stderr in
  let file = Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC; Unix.O_CLOEXEC ] 0o600 in
  Unix.dup2 ~cloexec:false file Unix.stderr;
  Unix.close file;
  Fun.protect f ~finally:(fun () ->
    flush stderr;
    Unix.dup2 ~cloexec:false saved Unix.stderr;
    Unix.close saved);
  let written = In_channel.with_open_bin path In_channel.input_all in
  Sys.remove path;
  written
;;

(* §6.1 case 6. Eio does not report a cancellation, and [Fiber.first] would
   raise any other exception the loser ended in. *)
let cancelled_section () =
  let mutex_name = "fiber-first-loser" in
  let mutex = Os_mutex.create ~name:mutex_name () in
  let written =
    stderr_of (fun () ->
      Eio_posix.run
      @@ fun _env ->
      let entered, set_entered = Eio.Promise.create () in
      let never, _ = Eio.Promise.create () in
      let winner =
        Eio.Fiber.first
          (fun () ->
            Os_mutex.protect mutex (fun () ->
              Eio.Promise.resolve set_entered ();
              Eio.Promise.await never;
              "the loser"))
          (fun () ->
            Eio.Promise.await entered;
            "the winner")
      in
      check string "Fiber.first" "the winner" winner)
  in
  check bool "the loser's record is on stderr" true (contains ~needle:mutex_name written);
  check (option unit) "the mutex is free" (Some ()) (Os_mutex.try_protect mutex ignore)
;;

(* §6.1 case 6, the Switch.fail path from probe case 10. The promise is
   resolved before the section suspends, so the switch fails only after
   that section has entered. Eio ignores its Cancelled when reporting the
   switch's own failure; replacing it with Held would create Multiple. *)
let switch_failure_preserves_cancellation () =
  let mutex_name = "switch-fail-cancelled-section" in
  let mutex = Os_mutex.create ~name:mutex_name () in
  let cause = Failure "the switch's own failure" in
  let written =
    stderr_of (fun () ->
      Eio_posix.run
      @@ fun _env ->
      let entered, set_entered = Eio.Promise.create () in
      let never, _ = Eio.Promise.create () in
      match
        Eio.Switch.run (fun sw ->
          Eio.Fiber.fork ~sw (fun () ->
            Os_mutex.protect mutex (fun () ->
              Eio.Promise.resolve set_entered ();
              Eio.Promise.await never));
          Eio.Promise.await entered;
          Eio.Switch.fail sw cause)
      with
      | () -> fail "the switch did not report its failure"
      | exception exn ->
        check bool "only the switch's original exception is reported" true (exn == cause))
  in
  check bool "the cancelled section's record is on stderr" true
    (contains ~needle:mutex_name written);
  check (option unit) "the cancelled section released its mutex" (Some ())
    (Os_mutex.try_protect mutex ignore)
;;

(* §6.1 case 7. A fiber waits for a Cross_context_mutex as a fiber, so a
   section of one may switch. *)
let cross_context_sections () =
  Eio_posix.run
  @@ fun env ->
  let lock = Cross_context_mutex.create () in
  List.iter
    (fun (what, _, call) ->
      match Cross_context_mutex.with_lock lock call with
      | () -> ()
      | exception exn -> failf "%s: %s" what (Printexc.to_string exn))
    (switching_calls env)
;;

(* §6.1 case 9, the child. A system-thread job takes the mutex its fiber
   holds, and the fiber waits for that job, so neither ever ends. *)
let hang_child_argument = "os-mutex-hang-child"
let hang_mutex_name = "os-mutex-hang"

let run_hang_child () =
  Eio_posix.run
  @@ fun _env ->
  let mutex = Os_mutex.create ~name:hang_mutex_name () in
  Os_mutex.protect mutex (fun () ->
    Eio_unix.run_in_systhread (fun () -> Os_mutex.protect mutex ignore))
;;

(* The record comes out before the child waits for anything. The limit only
   ends a run in which it never does. *)
let hang_record_limit_seconds = 60.
let stderr_line_limit_bytes = 1 lsl 20

type child_stderr =
  | Recorded
  | Closed_without_record

(* §6.1 case 9. The child is still running when it is killed, so the record
   on its stderr is all a hang like this leaves behind. *)
let hang_leaves_its_record () =
  Eio_posix.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let reader, writer = Eio_unix.pipe sw in
  let child =
    Eio.Process.spawn
      ~sw
      (Eio.Stdenv.process_mgr env)
      ~stderr:writer
      [ Sys.executable_name; hang_child_argument ]
  in
  Eio.Resource.close writer;
  let lines = Eio.Buf_read.of_flow reader ~max_size:stderr_line_limit_bytes in
  let rec read_until_record () =
    match Eio.Buf_read.line lines with
    | line when contains ~needle:hang_mutex_name line -> Ok Recorded
    | _ -> read_until_record ()
    | exception End_of_file -> Ok Closed_without_record
  in
  let seen =
    Eio.Time.with_timeout
      (Eio.Stdenv.clock env)
      hang_record_limit_seconds
      read_until_record
  in
  Eio.Process.signal child Sys.sigkill;
  let status = Eio.Process.await child in
  (match seen with
   | Ok Recorded -> ()
   | Ok Closed_without_record -> fail "the child closed stderr without the record"
   | Error `Timeout -> failf "no record within %.0f s" hang_record_limit_seconds);
  match status with
  | `Signaled _ -> ()
  | `Exited code -> failf "the child ended by itself with %d" code
;;

(* §6.1 case 10. Code that tells Eio from no Eio by [Effect.Unhandled] still
   can inside a section. *)
let outside_eio () =
  let mutex = Os_mutex.create ~name:"outside-eio" () in
  let value =
    Os_mutex.protect mutex (fun () ->
      (match Fs_compat.execution_context () with
       | Fs_compat.Non_eio -> ()
       | Fs_compat.Eio_fiber -> fail "Fs_compat.execution_context answered Eio_fiber");
      Fs_compat.Systhread_host.run (fun () -> 41) + 1)
  in
  check int "the section's value" 42 value
;;

let () =
  match Sys.argv with
  | [| _; argument |] when String.equal argument hang_child_argument -> run_hang_child ()
  | _ ->
    run
      "os_mutex"
      [ ( "inside Eio"
        , [ test_case
              "a section that switches fails when it ends"
              `Quick
              switching_sections
          ; test_case
              "a section that does not switch runs to the end"
              `Quick
              non_switching_sections
          ; test_case
              "the section's own exception rides on the failure"
              `Quick
              own_exception_after_switch
          ; test_case
              "a failed section has released the mutex"
              `Quick
              released_after_failure
          ; test_case
              "Eio.Mutex and Eio.Stream keep working after a failed section"
              `Quick
              eio_locks_survive
          ; test_case
              "a cancelled section re-raises Cancelled and leaves its record"
              `Quick
              cancelled_section
          ; test_case
              "Switch.fail does not replace a section's cancellation with Held"
              `Quick
              switch_failure_preserves_cancellation
          ; test_case
              "a Cross_context_mutex section may switch"
              `Quick
              cross_context_sections
          ; test_case
              "a hung section leaves its record on stderr"
              `Quick
              hang_leaves_its_record
          ] )
      ; "outside Eio", [ test_case "protect is Mutex.protect" `Quick outside_eio ]
      ]
;;
