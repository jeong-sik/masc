(** Tests for masc#23924.

    [Keeper_msg_async.submit]'s caller-supplied [f] is the sole owner of any
    terminal signal it emits on its own side channel while it runs (e.g.
    [process_single_turn]'s [worker_events] stream in
    server_routes_http_keeper_stream.ml). Before this fix, a turn cut off by
    an external [Eio.Cancel.Cancelled] left
    [f] mid-flight with no chance to push its own terminal event, so a
    consumer blocked on [Eio.Stream.take worker_events] hung forever even
    though [Keeper_msg_async]'s own polling table correctly recorded the
    turn as terminal.

    These tests exercise [Keeper_msg_async.submit] directly (not the SSE
    route) and assert on the new [on_worker_aborted] callback: it must fire
    exactly once, with a typed cancellation reason, precisely when [f] is
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
exception Synthetic_background_switch_closed

let keeper_request keeper_name =
  match Keeper_invocation_types.keeper_turn ~keeper_name ~prompt:"terminal event" with
  | Ok request -> request
  | Error reason -> fail reason
;;

let accepted_request_id = function
  | Ok
      ({ acceptance = Keeper_msg_async.Durably_accepted; request_id }
        : Keeper_msg_async.submit_outcome) ->
      request_id
  | Ok outcome ->
    fail
      (Keeper_msg_async.submit_outcome_to_json outcome |> Yojson.Safe.to_string)
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

let test_operator_cancel_running_worker_invokes_on_worker_aborted () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let aborted = ref [] in
        let settled = ref [] in
        let f_was_called = ref false in
        let worker_started, worker_started_resolver = Eio.Promise.create () in
        let never, _never_resolver = Eio.Promise.create () in
        let request_id =
          Keeper_msg_async.submit
            ~on_worker_aborted:(fun reason ->
              aborted := reason :: !aborted;
              Ok ())
            ~on_worker_settled:(fun settlement ->
              settled := settlement :: !settled)
            ~background_sw:sw
            ~base_path
            ~caller
            ~request:(keeper_request "terminal-event-operator-cancel")
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
          (match cancelled with
           | Keeper_msg_async.Cancellation_requested
               Keeper_msg_async.Durably_committed -> true
           | _ -> false);
        let fired =
          wait_until ~clock ~max_iterations:300 ~interval_sec:0.01 (fun () ->
            not (List.is_empty !aborted))
        in
        check bool "on_worker_aborted fired for an operator cancel" true fired;
        let settlement_fired =
          wait_until ~clock ~max_iterations:300 ~interval_sec:0.01 (fun () ->
            not (List.is_empty !settled))
        in
        check bool "durable settlement callback fired" true settlement_fired;
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
        (match !settled with
         | [ Keeper_msg_async.Status_settlement
               { status = Keeper_msg_async.Cancelled _
               ; durability = Keeper_msg_async.Durable
               ; origin = Keeper_msg_async.Transition_commit
               }
           ] ->
           ()
         | [ Keeper_msg_async.Status_settlement { status; _ } ] ->
           failf
             "unexpected settlement status=%s"
             (Keeper_msg_async.status_to_string status)
         | [ Keeper_msg_async.Settlement_projection_error _ ] ->
           fail "unexpected settlement projection error"
         | settlements ->
           failf "settlement callback count=%d, expected 1" (List.length settlements));
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
            ~on_worker_aborted:(fun _reason ->
              failwith "synthetic abort notification failure")
            ~background_sw:sw
            ~base_path
            ~caller
            ~request:(keeper_request "terminal-event-callback-failure")
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
          (match Keeper_msg_async.cancel ~base_path ~caller request_id with
           | Keeper_msg_async.Cancellation_requested
               Keeper_msg_async.Durably_committed -> true
           | _ -> false);
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
            ~on_worker_aborted:(fun reason ->
              aborted := reason :: !aborted;
              Ok ())
            ~background_sw:sw
            ~base_path
            ~caller
            ~request:(keeper_request "terminal-event-normal-completion")
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
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        let worker_called = ref false in
        match
          Keeper_msg_async.submit
            ~on_accepted:(fun _request_id -> Error "chat user append failed")
            ~background_sw:sw
            ~base_path
            ~caller
            ~request:(keeper_request "terminal-event-acceptance-failure")
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

let test_closed_background_switch_rejects_worker_acceptance () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun _env ->
      let submit_result = ref None in
      let aborted = ref [] in
      let settled = ref [] in
      (try
         Eio.Switch.run (fun sw ->
           Eio.Switch.fail sw Synthetic_background_switch_closed;
           submit_result :=
             Some
               (Eio.Cancel.protect (fun () ->
                  Keeper_msg_async.submit
                    ~on_worker_aborted:(fun reason ->
                      aborted := reason :: !aborted;
                      Ok ())
                    ~on_worker_settled:(fun settlement ->
                      settled := settlement :: !settled)
                    ~background_sw:sw
                    ~base_path
                    ~caller
                    ~request:(keeper_request "terminal-event-closed-background-switch")
                    ~f:(fun _request_sw ->
                      fail "worker ran on a closed background switch")
                    ())))
       with
       | Synthetic_background_switch_closed -> ()
       | Eio.Cancel.Cancelled Synthetic_background_switch_closed -> ());
      match !submit_result with
      | Some
          (Error
             (Keeper_msg_async.Background_fork_failed
                { request_id; reason = _ })) ->
        check int "never-started worker emits no abort callback" 0 (List.length !aborted);
        check int "never-started worker emits no settlement callback" 0
          (List.length !settled);
        (match Keeper_msg_async.poll ~base_path ~caller request_id with
         | Keeper_msg_async.Found { status = Keeper_msg_async.Lost _; _ } -> ()
         | Keeper_msg_async.Found { status; _ } ->
           failf
             "expected lost request after rejected background start, got %s"
             (Keeper_msg_async.status_to_string status)
         | Keeper_msg_async.Absent -> fail "rejected background start lost its record"
         | Keeper_msg_async.Unreadable reason -> fail reason
         | Keeper_msg_async.Rejected _ -> fail "request ownership rejected")
      | Some (Error error) ->
        fail
          (Keeper_msg_async.submit_error_to_json error
           |> Yojson.Safe.to_string)
      | Some (Ok outcome) ->
        failf
          "closed background switch produced submit outcome=%s"
          (Keeper_msg_async.submit_outcome_to_json outcome |> Yojson.Safe.to_string)
      | None -> fail "submit did not return before the background switch closed"))
;;

let () =
  run
    "keeper_msg_async_terminal_event"
    [ ( "on_worker_aborted"
      , [ test_case "operator cancel running worker invokes on_worker_aborted" `Quick
            test_operator_cancel_running_worker_invokes_on_worker_aborted
        ; test_case "abort callback failure stays inside the request lane" `Quick
            test_abort_callback_failure_does_not_fail_server_switch
        ; test_case "normal completion never invokes on_worker_aborted" `Quick
            test_normal_completion_never_invokes_on_worker_aborted
        ; test_case
            "acceptance failure prevents worker start"
            `Quick
            test_acceptance_failure_prevents_worker_start
        ; test_case
            "closed background switch rejects worker acceptance"
            `Quick
            test_closed_background_switch_rejects_worker_acceptance
        ] )
    ]
;;
