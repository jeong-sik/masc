open Masc
module Aux = Server_auxiliary_startup

exception Failed_start of Aux.component
exception Requested_stop

let starts run : Aux.starts =
  { ready_notification = (fun () -> run Aux.Ready_notification)
  ; scheduler_probe = (fun () -> run Aux.Scheduler_probe)
  ; full_health_refresh = (fun () -> run Aux.Full_health_refresh)
  ; heap_roots = (fun () -> run Aux.Heap_roots)
  ; owner_lanes = (fun () -> run Aux.Owner_lanes)
  ; discord_gateway = (fun () -> run Aux.Discord_gateway)
  ; slack_gateway = (fun () -> run Aux.Slack_gateway)
  ; slack_poll = (fun () -> run Aux.Slack_poll)
  ; imessage_gateway = (fun () -> run Aux.Imessage_gateway)
  ; telegram_gateway = (fun () -> run Aux.Telegram_gateway)
  ; startup_banner = (fun () -> run Aux.Startup_banner)
  ; grpc_listener = (fun () -> run Aux.Grpc_listener)
  ; grpc_client = (fun () -> run Aux.Grpc_client)
  ; websocket_handler = (fun () -> run Aux.Websocket_handler)
  ; transport_providers = (fun () -> run Aux.Transport_providers)
  ; execution_refresh = (fun () -> run Aux.Execution_refresh)
  ; transport_health_refresh = (fun () -> run Aux.Transport_health_refresh)
  ; execution_trust_refresh = (fun () -> run Aux.Execution_trust_refresh)
  ; mission_refresh = (fun () -> run Aux.Mission_refresh)
  ; operator_snapshot_refresh = (fun () -> run Aux.Operator_snapshot_refresh)
  ; operator_digest_refresh = (fun () -> run Aux.Operator_digest_refresh)
  ; shell_prewarm = (fun () -> run Aux.Shell_prewarm)
  }

let with_peer run =
  Eio_main.run @@ fun env ->
  let finished, signal_finished = Eio.Promise.create () in
  Eio.Fiber.first
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      let socket = Eio.Net.listen env#net ~sw ~reuse_addr:true ~backlog:128
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
      let requests = ref 0 in
      Eio.Fiber.fork ~sw (fun () ->
        let rec serve () =
          Eio.Net.accept_fork socket ~sw
            ~on_error:(fun exn -> Alcotest.fail (Printexc.to_string exn))
            (fun flow _ ->
              let reader = Eio.Buf_read.of_flow flow ~max_size:4096 in
              Alcotest.(check string) "actual sibling request" "GET /health HTTP/1.1"
                (Eio.Buf_read.line reader);
              incr requests;
              Eio.Flow.copy_string
                "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok" flow);
          serve ()
        in
        serve ());
      let probe () =
        Eio.Switch.run @@ fun request_sw ->
        let flow = Eio.Net.connect env#net ~sw:request_sw (Eio.Net.listening_addr socket) in
        Eio.Flow.copy_string "GET /health HTTP/1.1\r\nHost: local\r\n\r\n" flow;
        let reader = Eio.Buf_read.of_flow flow ~max_size:4096 in
        Alcotest.(check string) "actual sibling remains reachable" "HTTP/1.1 200 OK"
          (Eio.Buf_read.line reader)
      in
      run ~sw ~probe ~requests;
      Eio.Promise.resolve signal_finished ();
      Eio.Fiber.await_cancel ())
    (fun () -> Eio.Promise.await finished)

let field name = function
  | `Assoc fields ->
      (match List.assoc_opt name fields with
       | Some value -> value
       | None -> Alcotest.fail ("missing field " ^ name))
  | _ -> Alcotest.fail "expected object"

let test_each_start_failure_keeps_real_siblings_available () =
  with_peer @@ fun ~sw:_ ~probe ~requests ->
  List.iter
    (fun failing ->
      let registry = Aux.create () in
      let private_failure = Failed_start failing in
      let before = !requests in
      let callbacks = starts (fun component ->
        if component = failing then raise private_failure else probe ()) in
      let failures = Aux.run_all registry callbacks in
      (match failures with
       | [ component, failure ] ->
           Alcotest.(check bool) "exact component failure" true (component = failing);
           Alcotest.(check bool) "original private cause" true
             (failure.Aux.cause == private_failure);
           Alcotest.(check bool) "throwing evidence captured" true
             (String.length (Printexc.raw_backtrace_to_string failure.backtrace) > 0)
       | [] | _ :: _ :: _ -> Alcotest.fail "failure evidence lost or duplicated");
      Alcotest.(check int) "all independent callbacks completed actual HTTP"
        (List.length (Aux.components callbacks) - 1) (!requests - before);
      List.iter
        (fun (component, attempt) ->
          match attempt with
          | Aux.Failed failure ->
              Alcotest.(check bool) "only injected component failed" true (component = failing);
              Alcotest.(check bool) "snapshot retains original evidence" true
                (failure.cause == private_failure)
          | Returned ->
              Alcotest.(check bool) "failed start was not called ready/returned" false
                (component = failing)
          | Not_attempted | Starting | Cancelled ->
              Alcotest.fail "a synchronous failure skipped a sibling")
        (Aux.snapshot registry))
    (Aux.components (starts (fun _ -> ())))

let test_inflight_and_multiple_failure_evidence () =
  with_peer @@ fun ~sw ~probe ~requests:_ ->
  let registry = Aux.create () in
  let entered, signal_entered = Eio.Promise.create () in
  let release, signal_release = Eio.Promise.create () in
  let first = Failed_start Aux.Ready_notification in
  let last = Failed_start Aux.Shell_prewarm in
  let work = Eio.Fiber.fork_promise ~sw (fun () ->
    Aux.run_all registry (starts (function
      | Aux.Ready_notification -> raise first
      | Scheduler_probe ->
          Eio.Promise.resolve signal_entered ();
          Eio.Promise.await release;
          probe ()
      | Shell_prewarm -> raise last
      | Full_health_refresh | Heap_roots | Owner_lanes | Discord_gateway
      | Slack_gateway | Slack_poll | Imessage_gateway | Telegram_gateway | Startup_banner
      | Grpc_listener | Grpc_client | Websocket_handler | Transport_providers
      | Execution_refresh | Transport_health_refresh | Execution_trust_refresh
      | Mission_refresh | Operator_snapshot_refresh | Operator_digest_refresh -> probe ()))) in
  Eio.Promise.await entered;
  let observed = Aux.snapshot registry in
  (match List.assoc Aux.Scheduler_probe observed with
   | Aux.Starting -> ()
   | Not_attempted | Returned | Failed _ | Cancelled ->
       Alcotest.fail "an in-flight callback was presented as returned");
  (match List.assoc Aux.Shell_prewarm observed with
   | Aux.Not_attempted -> ()
   | Starting | Returned | Failed _ | Cancelled ->
       Alcotest.fail "a later callback was presented as attempted");
  Alcotest.(check bool) "earlier failure is visible during later work" true
    (field "status" (Aux.to_yojson registry) = `String "degraded");
  Eio.Promise.resolve signal_release ();
  let failures = Eio.Promise.await_exn work in
  (match failures with
   | [ (first_component, earlier); (last_component, later) ] ->
       Alcotest.(check bool) "first failed component" true
         (first_component = Aux.Ready_notification);
       Alcotest.(check bool) "last failed component" true
         (last_component = Aux.Shell_prewarm);
       Alcotest.(check bool) "first failure was not overwritten" true (earlier.cause == first);
       Alcotest.(check bool) "later failure also retained" true (later.cause == last)
   | [] | [ _ ] | _ :: _ :: _ :: _ -> Alcotest.fail "ordered failure evidence changed")

let test_actual_cancellation_preserves_provenance_and_stops_new_starts () =
  with_peer @@ fun ~sw ~probe ~requests ->
  let registry = Aux.create () in
  let context, signal_context = Eio.Promise.create () in
  let propagated, signal_propagated = Eio.Promise.create () in
  let inside = ref None in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      try
        Eio.Cancel.sub (fun cancellation ->
          ignore (Aux.run_all registry (starts (function
            | Aux.Ready_notification -> probe ()
            | Scheduler_probe ->
                Eio.Promise.resolve signal_context cancellation;
                (try Eio.Fiber.await_cancel () with
                 | Eio.Cancel.Cancelled _ as exn ->
                     let backtrace = Printexc.get_raw_backtrace () in
                     inside := Some (exn, Printexc.raw_backtrace_to_string backtrace);
                     Printexc.raise_with_backtrace exn backtrace)
            | Full_health_refresh | Heap_roots | Owner_lanes | Discord_gateway
            | Slack_gateway | Slack_poll | Imessage_gateway | Telegram_gateway | Startup_banner
            | Grpc_listener | Grpc_client | Websocket_handler | Transport_providers
            | Execution_refresh | Transport_health_refresh | Execution_trust_refresh
            | Mission_refresh | Operator_snapshot_refresh | Operator_digest_refresh
            | Shell_prewarm -> Alcotest.fail "cancelled sequence started later work"))));
        None
      with
      | Eio.Cancel.Cancelled _ as exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          Some (exn, Printexc.raw_backtrace_to_string backtrace)
    in
    Eio.Promise.resolve signal_propagated result);
  Eio.Cancel.cancel (Eio.Promise.await context) Requested_stop;
  let propagated = Eio.Promise.await propagated in
  (match !inside, propagated with
   | Some (original, frames), Some (propagated, observed) ->
       Alcotest.(check bool) "same cancellation reaches the caller" true
         (original == propagated);
       Alcotest.(check bool) "original cancellation frames retained" true
         (String.starts_with ~prefix:frames observed)
   | None, _ | _, None -> Alcotest.fail "cancellation was swallowed");
  List.iter
    (fun (component, attempt) ->
      match attempt with
      | Aux.Returned ->
          Alcotest.(check bool) "only the earlier callback returned" true
            (component = Aux.Ready_notification)
      | Cancelled ->
          Alcotest.(check bool) "the in-flight callback was cancelled" true
            (component = Aux.Scheduler_probe)
      | Not_attempted ->
          Alcotest.(check bool) "later callbacks were not attempted" true
            (component <> Aux.Ready_notification && component <> Aux.Scheduler_probe)
      | Starting | Failed _ -> Alcotest.fail "cancellation changed another attempt")
    (Aux.snapshot registry);
  Alcotest.(check int) "only earlier real sibling was contacted" 1 !requests;
  probe ()

let test_cancellation_between_callbacks_starts_no_new_work () =
  with_peer @@ fun ~sw:_ ~probe ~requests ->
  List.iter
    (fun cancel_after ->
      let registry = Aux.create () in
      let before = !requests in
      let cancelled_inside = ref false in
      let runner_returned = ref false in
      let cancelled =
        try
          Eio.Cancel.sub (fun cancellation ->
            ignore (Aux.run_all registry (starts (fun component ->
              if !cancelled_inside then
                Alcotest.fail "pending cancellation started another callback";
              probe ();
              if component = cancel_after then (
                cancelled_inside := true;
                Eio.Cancel.cancel cancellation Requested_stop))));
            runner_returned := true);
          false
        with Eio.Cancel.Cancelled _ -> true
      in
      Alcotest.(check bool) "between-callback cancellation propagated" true cancelled;
      Alcotest.(check bool) "runner delivered cancellation before returning" false
        !runner_returned;
      let returned = ref 0 in
      List.iter
        (fun (_, attempt) ->
          match attempt with
          | Aux.Returned -> incr returned
          | Not_attempted -> ()
          | Starting | Failed _ | Cancelled ->
              Alcotest.fail "an unentered callback was reported as entered")
        (Aux.snapshot registry);
      Alcotest.(check int) "only work before cancellation contacted the peer"
        !returned (!requests - before);
      (match List.assoc cancel_after (Aux.snapshot registry) with
       | Aux.Returned -> ()
       | Not_attempted | Starting | Failed _ | Cancelled ->
           Alcotest.fail "the completed callback lost its actual return"))
    (Aux.components (starts (fun _ -> ())));
  probe ()

let test_public_health_projection_and_rollup () =
  let registry = Aux.global in
  let private_detail = "private auxiliary evidence" in
  let failures = Aux.run_all registry (starts (function
    | Aux.Discord_gateway -> failwith private_detail
    | Ready_notification | Scheduler_probe | Full_health_refresh | Heap_roots
    | Owner_lanes | Slack_gateway | Slack_poll | Imessage_gateway | Telegram_gateway | Startup_banner
    | Grpc_listener | Grpc_client | Websocket_handler | Transport_providers
    | Execution_refresh | Transport_health_refresh | Execution_trust_refresh
    | Mission_refresh | Operator_snapshot_refresh | Operator_digest_refresh
    | Shell_prewarm -> ())) in
  Alcotest.(check int) "one private failure" 1 (List.length failures);
  let observed = Aux.to_yojson registry in
  Alcotest.(check bool) "private exception stays out of public JSON" false
    (Astring.String.is_infix ~affix:private_detail (Yojson.Safe.to_string observed));
  let summary = Server_health_rollup.operator_summary
    ~sections:[ "auxiliary_startup", observed ]
    ~runtime_startup_degradation:(`Assoc []) ~keeper_config_schema_status:"ok"
    ~keeper_config_schema_blocking:false ~keeper_config_schema_terminal_reason:""
    ~keeper_config_operator_action_required:false in
  Alcotest.(check string) "actual health rollup degrades" "degraded" summary.overall_status;
  Alcotest.(check bool) "actual rollup retains repair requirement" true
    summary.operator_action_required;
  let base_path = Filename.temp_dir "aux-start-health-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    Masc_test_deps.with_process_env "MASC_BASE_PATH" (Some base_path) @@ fun () ->
    let authority =
      match Server_request_authority.of_host_port ~host:"localhost" ~port:8935 with
      | Ok value -> value
      | Error `Malformed -> Alcotest.fail "fixture authority malformed" in
    let probe = Server_routes_http_runtime.make_health_response_json
      ~request_authority:authority (Httpun.Request.create `GET "/health") in
    Alcotest.(check bool) "real probe exposes the same attempt evidence" true
      (Yojson.Safe.equal observed (field "auxiliary_startup" probe));
    Server_routes_http_runtime.For_testing.reset_full_health_snapshot ();
    let full = Server_routes_http_runtime.make_health_response_json
      ~request_authority:authority (Httpun.Request.create `GET "/health?full=1") in
    Alcotest.(check bool) "warming full health retains actual attempt evidence" true
      (Yojson.Safe.equal observed (field "auxiliary_startup" full));
    List.iter (function
      | `Assoc fields ->
          Alcotest.(check int) "health wire has one attempt field" 1
            (List.length (List.filter (fun (name, _) -> name = "auxiliary_startup") fields))
      | _ -> Alcotest.fail "health response is not an object") [ probe; full ])

let () =
  Printexc.record_backtrace true;
  Mirage_crypto_rng_unix.use_default ();
  Alcotest.run "auxiliary startup failure isolation"
    [ "behavior",
      [ Alcotest.test_case "every synchronous failure preserves real siblings" `Quick
          test_each_start_failure_keeps_real_siblings_available
      ; Alcotest.test_case "inflight and multiple failures remain observable" `Quick
          test_inflight_and_multiple_failure_evidence
      ; Alcotest.test_case "actual cancellation propagates without later starts" `Quick
          test_actual_cancellation_preserves_provenance_and_stops_new_starts
      ; Alcotest.test_case "between-callback cancellation starts no new work" `Quick
          test_cancellation_between_callbacks_starts_no_new_work
      ; Alcotest.test_case "actual health projection and rollup preserve scope" `Quick
          test_public_health_projection_and_rollup
      ] ]
