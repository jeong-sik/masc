(** Tests for masc#23924.

    [Keeper_msg_async.submit]'s caller-supplied [f] is the sole owner of any
    terminal signal it emits on its own side channel while it runs (e.g.
    [process_single_turn]'s [worker_events] stream in
    server_routes_http_keeper_stream.ml). Before this fix, a turn cut off by
    [Eio.Time.with_timeout_exn] or an external [Eio.Cancel.Cancelled] left
    [f] mid-flight with no chance to push its own terminal event, so a
    consumer blocked on [Eio.Stream.take worker_events] hung forever even
    though [Keeper_msg_async]'s own polling table correctly recorded the
    turn as terminal.

    These tests exercise [Keeper_msg_async.submit] directly (not the SSE
    route) and assert on the new [on_worker_aborted] callback: it must fire
    exactly once, with a [Timeout]/[Cancelled] reason, precisely when [f] is
    cut off before reaching its own completion — and never on a normal
    [f] return. *)

open Alcotest
module Keeper_msg_async = Masc.Keeper_msg_async
module Keeper_types_profile = Masc.Keeper_types_profile

(* [Keeper_msg_async.submit] persists request records to disk via
   [Keeper_fs.save_json_atomic]; [test_keeper_mutex_coverage] exercises the
   same accepted-submit and persisted-terminal path. *)
let () = Mirage_crypto_rng_unix.use_default ()
let caller = "terminal-event-test-caller"

let accepted_request_id = function
  | Ok request_id -> request_id
  | Error error ->
    fail
      (Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string)
;;

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun e -> rm_rf (Filename.concat path e));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_base f =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-23924-terminal-event-%d-%06x" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir base 0o755;
  Fun.protect ~finally:(fun () -> rm_rf base) (fun () -> f base)
;;

(* Bounded busy-wait: polls [predicate] on a real clock instead of assuming a
   fixed sleep duration, but never blocks indefinitely if a regression makes
   the predicate never become true. *)
let wait_until ~clock ~max_iterations ~interval_sec predicate =
  let rec loop n =
    if predicate ()
    then true
    else if n <= 0
    then false
    else (
      Eio.Time.sleep clock interval_sec;
      loop (n - 1))
  in
  loop max_iterations
;;

let test_timeout_invokes_on_worker_aborted_exactly_once () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let aborted = ref [] in
        let request_id =
          Keeper_msg_async.submit
            ~clock
            ~timeout_sec:0.01
            ~on_worker_aborted:(fun reason ->
              aborted := reason :: !aborted;
              Ok ())
            ~background_sw:sw
            ~base_path
            ~caller
            ~keeper_name:"terminal-event-timeout"
            ~f:(fun _request_sw ->
              (* Sleeps far past the 0.01s timeout budget so
                 [Eio.Time.with_timeout_exn] cancels this fiber before it
                 ever returns — [f] never reaches its own completion. *)
              Eio.Time.sleep clock 5.0;
              Keeper_types_profile.tool_result_ok "unreachable")
            ()
          |> accepted_request_id
        in
        let fired =
          wait_until ~clock ~max_iterations:300 ~interval_sec:0.01 (fun () ->
            not (List.is_empty !aborted))
        in
        check bool "on_worker_aborted fired within budget (masc#23924 regression guard)" true fired;
        (* Grace period: give a buggy double-fire a chance to show up before
           we assert exactly-once. *)
        Eio.Time.sleep clock 0.05;
        (match !aborted with
         | [ Keeper_msg_async.Timeout { timeout_sec } ] ->
           check bool "timeout_sec matches the submitted timeout_sec" true
             (Float.equal timeout_sec 0.01)
         | [] -> fail "on_worker_aborted was never invoked"
         | reasons ->
           fail
             (Printf.sprintf "on_worker_aborted fired %d times, expected 1"
                (List.length reasons)));
        (* The pre-existing polling table must still record the timeout
           terminally — this fix must not regress that contract. *)
        match Keeper_msg_async.poll ~base_path ~caller request_id with
        | Keeper_msg_async.Found { status = Keeper_msg_async.Done { ok = false; _ }; _ } -> ()
        | Keeper_msg_async.Found { status; _ } ->
          fail
            (Printf.sprintf "expected a failed Done status, got %s"
               (Keeper_msg_async.status_to_string status))
        | Keeper_msg_async.Absent -> fail "request record unexpectedly absent"
        | Keeper_msg_async.Unreadable reason ->
          fail (Printf.sprintf "request record unreadable: %s" reason)
        | Keeper_msg_async.Rejected _ -> fail "request access unexpectedly rejected")))
;;

let test_operator_cancel_running_worker_invokes_on_worker_aborted () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let aborted = ref [] in
        let f_was_called = ref false in
        let worker_started, worker_started_resolver = Eio.Promise.create () in
        let never, _never_resolver = Eio.Promise.create () in
        let request_id =
          Keeper_msg_async.submit
            ~clock
            ~timeout_sec:5.0
            ~on_worker_aborted:(fun reason ->
              aborted := reason :: !aborted;
              Ok ())
            ~background_sw:sw
            ~base_path
            ~caller
            ~keeper_name:"terminal-event-operator-cancel"
            ~f:(fun _request_sw ->
              f_was_called := true;
              Eio.Promise.resolve worker_started_resolver ();
              Eio.Promise.await never;
              Keeper_types_profile.tool_result_ok "unreachable")
            ()
          |> accepted_request_id
        in
        Eio.Promise.await worker_started;
        let cancelled = Keeper_msg_async.cancel ~base_path ~caller request_id in
        check bool "cancel accepted the running request" true
          (cancelled = Keeper_msg_async.Cancelled_request);
        let fired =
          wait_until ~clock ~max_iterations:300 ~interval_sec:0.01 (fun () ->
            not (List.is_empty !aborted))
        in
        check bool "on_worker_aborted fired for an operator cancel" true fired;
        Eio.Time.sleep clock 0.05;
        (match !aborted with
         | [ Keeper_msg_async.Worker_cancelled { cancelled_by; _ } ] ->
           check bool "cancel source is typed operator request" true
             (cancelled_by = Keeper_msg_async.Operator_request)
         | [] -> fail "on_worker_aborted was never invoked"
         | reasons ->
           fail
             (Printf.sprintf "on_worker_aborted fired %d times, expected 1"
                (List.length reasons)));
        check bool "f was running before cancellation" true !f_was_called)))
;;

let test_abort_callback_failure_does_not_fail_server_switch () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let worker_started, worker_started_resolver = Eio.Promise.create () in
        let never, _never_resolver = Eio.Promise.create () in
        let request_id =
          Keeper_msg_async.submit
            ~clock
            ~timeout_sec:5.0
            ~on_worker_aborted:(fun _reason ->
              failwith "synthetic abort notification failure")
            ~background_sw:sw
            ~base_path
            ~caller
            ~keeper_name:"terminal-event-callback-failure"
            ~f:(fun _request_sw ->
              Eio.Promise.resolve worker_started_resolver ();
              Eio.Promise.await never;
              Keeper_types_profile.tool_result_ok "unreachable")
            ()
          |> accepted_request_id
        in
        Eio.Promise.await worker_started;
        check bool
          "operator cancellation remains accepted"
          true
          (Keeper_msg_async.cancel ~base_path ~caller request_id
           = Keeper_msg_async.Cancelled_request);
        let reached_persistence_failure =
          wait_until ~clock ~max_iterations:300 ~interval_sec:0.01 (fun () ->
            match Keeper_msg_async.poll ~base_path ~caller request_id with
            | Keeper_msg_async.Found
                { status = Keeper_msg_async.Persistence_failed _; _ } -> true
            | _ -> false)
        in
        check bool
          "callback failure becomes durable persistence failure"
          true
          reached_persistence_failure;
        let released =
          wait_until ~clock ~max_iterations:300 ~interval_sec:0.01 (fun () ->
            Keeper_msg_async.For_testing.active_switch_count () = 0)
        in
        check bool
          "callback failure releases the request switch"
          true
          released)))
;;

let test_normal_completion_never_invokes_on_worker_aborted () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let aborted = ref [] in
        let request_id =
          Keeper_msg_async.submit
            ~clock
            ~timeout_sec:5.0
            ~on_worker_aborted:(fun reason ->
              aborted := reason :: !aborted;
              Ok ())
            ~background_sw:sw
            ~base_path
            ~caller
            ~keeper_name:"terminal-event-normal-completion"
            ~f:(fun _request_sw -> Keeper_types_profile.tool_result_ok "ok")
            ()
          |> accepted_request_id
        in
        let reached_done =
          wait_until ~clock ~max_iterations:300 ~interval_sec:0.01 (fun () ->
            match Keeper_msg_async.poll ~base_path ~caller request_id with
            | Keeper_msg_async.Found { status = Keeper_msg_async.Done _; _ } -> true
            | _ -> false)
        in
        check bool "request reached Done within budget" true reached_done;
        (* Grace period: [on_worker_aborted] must not fire late either. *)
        Eio.Time.sleep clock 0.05;
        check int "on_worker_aborted never fired on a normal completion" 0
          (List.length !aborted))))
;;

let test_acceptance_failure_prevents_worker_start () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let worker_called = ref false in
        match
          Keeper_msg_async.submit
            ~clock:(Eio.Stdenv.clock env)
            ~on_accepted:(fun _request_id -> Error "chat user append failed")
            ~background_sw:sw
            ~base_path
            ~caller
            ~keeper_name:"terminal-event-acceptance-failure"
            ~f:(fun _request_sw ->
              worker_called := true;
              Keeper_types_profile.tool_result_ok "unreachable")
            ()
        with
        | Error
            (Keeper_msg_async.Acceptance_persistence_failed
               { request_id; reason }) ->
          check string "typed acceptance failure" "chat user append failed" reason;
          check bool "worker never starts" false !worker_called;
          (match Keeper_msg_async.poll ~base_path ~caller request_id with
           | Keeper_msg_async.Found
               { status = Keeper_msg_async.Persistence_failed _; _ } -> ()
           | Keeper_msg_async.Found { status; _ } ->
             failf
               "expected persistence_failed, got %s"
               (Keeper_msg_async.status_to_string status)
           | Keeper_msg_async.Absent -> fail "accepted record disappeared"
           | Keeper_msg_async.Unreadable reason -> fail reason
           | Keeper_msg_async.Rejected _ -> fail "request ownership rejected")
        | Error error ->
          fail
            (Keeper_msg_async.submit_error_to_json error
             |> Yojson.Safe.to_string)
        | Ok _ -> fail "acceptance failure returned a successful request id")))
;;

let () =
  run
    "keeper_msg_async_terminal_event"
    [ ( "on_worker_aborted"
      , [ test_case "timeout invokes on_worker_aborted exactly once" `Quick
            test_timeout_invokes_on_worker_aborted_exactly_once
        ; test_case "operator cancel running worker invokes on_worker_aborted" `Quick
            test_operator_cancel_running_worker_invokes_on_worker_aborted
        ; test_case "abort callback failure stays inside the request lane" `Quick
            test_abort_callback_failure_does_not_fail_server_switch
        ; test_case "normal completion never invokes on_worker_aborted" `Quick
            test_normal_completion_never_invokes_on_worker_aborted
        ; test_case
            "acceptance failure prevents worker start"
            `Quick
            test_acceptance_failure_prevents_worker_start
        ] )
    ]
;;
