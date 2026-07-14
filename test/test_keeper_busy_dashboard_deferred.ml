(* test_keeper_busy_dashboard_deferred.ml

   A dashboard message that arrives while a keeper turn is already in flight
   must not park a new HTTP/SSE request behind the turn slot. It is accepted
   into the durable chat queue instead; the standalone consumer drains it when
   the slot frees. *)

open Masc

let failures = ref 0

let check name cond =
  if cond
  then Printf.printf "  ok: %s\n%!" name
  else (
    incr failures;
    Printf.printf "  fail: %s\n%!" name)
;;

let keeper_name = "busy-dashboard-keeper"
let thread_id = "busy-dashboard-thread"

let payload ?(name = keeper_name) ?(content = "are you there?") ()
    : Server_routes_http_keeper_stream.keeper_chat_stream_request =
  { name
  ; message = content
  ; user_blocks = []
  ; turn_instructions = None
  ; surface_context = None
  ; channel = ""
  ; channel_user_id = ""
  ; channel_user_name = ""
  ; channel_workspace_id = ""
  ; attachments = []
  }
;;

let with_env body =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-busy-dashboard-%d-%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base)
    (fun () ->
      Eio_main.run
      @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock = Eio.Stdenv.clock env in
      let config = Workspace.default_config base in
      ignore (Workspace.init config ~agent_name:(Some keeper_name));
      Keeper_turn_admission.For_testing.reset ();
      Keeper_chat_queue.For_testing.reset ();
      let report = Keeper_chat_queue.configure_persistence ~base_path:base in
      check "chat queue persistence configured without load errors"
        (report.load_errors = []);
      Eio.Switch.run (fun sw ->
        Eio.Switch.on_release sw Keeper_chat_queue.For_testing.reset;
        body ~base ~clock))
;;

let with_busy_slot ~base ~sw ?(keeper_name = keeper_name) f =
  let started, set_started = Eio.Promise.create () in
  let release, set_release = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    ignore
      (Keeper_turn_admission.run_serialized ~base_path:base ~keeper_name (fun () ->
         Eio.Promise.resolve set_started ();
         Eio.Promise.await release)));
  Eio.Promise.await started;
  Fun.protect
    ~finally:(fun () -> Eio.Promise.resolve set_release ())
    f
;;

let with_busy_slots ~base ~sw keeper_names f =
  let slots =
    List.map
      (fun keeper_name ->
         let started, set_started = Eio.Promise.create () in
         let release, set_release = Eio.Promise.create () in
         Eio.Fiber.fork ~sw (fun () ->
           ignore
             (Keeper_turn_admission.run_serialized ~base_path:base ~keeper_name
                (fun () ->
                   Eio.Promise.resolve set_started ();
                   Eio.Promise.await release)));
         (started, set_release))
      keeper_names
  in
  List.iter (fun (started, _) -> Eio.Promise.await started) slots;
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (_, set_release) -> Eio.Promise.resolve set_release ()) slots)
    f
;;

let test_busy_dashboard_enqueues () =
  Printf.printf "Test: busy dashboard dispatch enqueues onto Keeper_chat_queue\n%!";
  with_env
  @@ fun ~base ~clock ->
  Eio.Switch.run
  @@ fun sw ->
  with_busy_slot ~base ~sw
  @@ fun () ->
  (match
     Server_routes_http_keeper_stream.For_testing.defer_dashboard_payload_if_busy
       ~base_path:base
       ~clock
       ~thread_id
       (payload ())
   with
   | `Queued len -> check "queue length is reported" (len = 1)
   | `Not_busy | `Queue_error _ -> check "busy keeper was deferred" false);
  let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
  check "exactly one dashboard receipt is pending"
    (List.length snapshot.pending = 1);
  check "dashboard queue has no inflight receipt" (snapshot.inflight = []);
  check "dashboard queue revision advances" (snapshot.revision = 1L);
  (match snapshot.pending with
   | [ { Keeper_chat_queue.message =
           { Keeper_chat_queue.content
           ; source = Dashboard { thread_id = queued_thread_id }
           ; user_row_origin
           ; _
           }
       ; _
       } ] ->
     check "queued content is the user's message" (String.equal content "are you there?");
     check "queued dashboard thread is exact" (String.equal queued_thread_id thread_id);
     check "queued dashboard user row remains route-owned"
       (match user_row_origin with
        | Keeper_chat_store.Needs_append -> true
        | Keeper_chat_store.Already_persisted _
        | Keeper_chat_store.Already_persisted_upstream -> false)
   | _ -> check "queue holds one dashboard receipt" false)
;;

let test_free_dashboard_not_enqueued () =
  Printf.printf "Test: free dashboard dispatch is not deferred\n%!";
  with_env
  @@ fun ~base ~clock ->
  (match
     Server_routes_http_keeper_stream.For_testing.defer_dashboard_payload_if_busy
       ~base_path:base
       ~clock
       ~thread_id
       (payload ~content:"run now" ())
   with
   | `Not_busy -> check "free keeper stays on direct stream path" true
   | `Queued _ | `Queue_error _ -> check "free keeper must not enqueue" false);
  let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
  check "queue remains empty" (snapshot.pending = [] && snapshot.inflight = [])
;;

let test_existing_backlog_defers_new_dashboard_message () =
  Printf.printf "Test: existing dashboard backlog keeps newer messages queued\n%!";
  with_env
  @@ fun ~base ~clock ->
  (match
     Keeper_chat_queue.enqueue ~keeper_name
       { Keeper_chat_queue.content = "older queued message"
       ; user_blocks = []
       ; attachments = []
       ; timestamp = Eio.Time.now clock
       ; source = Dashboard { thread_id }
       ; user_row_origin = Keeper_chat_store.Needs_append
       }
   with
   | Ok receipt ->
     check "older message receives the first durable revision"
       (receipt.revision = 1L)
   | Error _ -> check "older message enqueue succeeds" false);
  (match
     Server_routes_http_keeper_stream.For_testing.defer_dashboard_payload_if_busy
       ~base_path:base
       ~clock
       ~thread_id
       (payload ~content:"newer dashboard message" ())
   with
   | `Queued len -> check "newer message joins existing backlog" (len = 2)
   | `Not_busy | `Queue_error _ ->
     check "existing backlog should force queue path" false);
  let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
  let pending_contents =
    List.map
      (fun (receipt : Keeper_chat_queue.active_receipt) ->
         receipt.message.content)
      snapshot.pending
  in
  check "durable snapshot preserves FIFO order"
    (pending_contents = [ "older queued message"; "newer dashboard message" ])
;;

let test_concurrent_busy_dashboard_enqueues_are_per_keeper () =
  Printf.printf
    "Test: concurrent busy dashboard dispatches enqueue per keeper\n%!";
  with_env
  @@ fun ~base ~clock ->
  Eio.Switch.run
  @@ fun sw ->
  let keeper_names =
    List.init 8 (fun i -> Printf.sprintf "%s-%02d" keeper_name i)
  in
  with_busy_slots ~base ~sw keeper_names
  @@ fun () ->
  let results = Array.make (List.length keeper_names) None in
  let done_promises = Array.make (List.length keeper_names) None in
  keeper_names
  |> List.iteri (fun i keeper_name ->
    let done_, set_done = Eio.Promise.create () in
    done_promises.(i) <- Some done_;
    Eio.Fiber.fork ~sw (fun () ->
      let result =
        Server_routes_http_keeper_stream.For_testing.defer_dashboard_payload_if_busy
          ~base_path:base
          ~clock
          ~thread_id:(Printf.sprintf "%s-%d" thread_id i)
          (payload ~name:keeper_name
             ~content:(Printf.sprintf "burst message %d" i)
             ())
      in
      results.(i) <- Some result;
      Eio.Promise.resolve set_done ()));
  Array.iter
    (function
      | Some done_ -> Eio.Promise.await done_
      | None -> ())
    done_promises;
  keeper_names
  |> List.iteri (fun i keeper_name ->
    match results.(i) with
    | Some (`Queued 1) ->
      check
        (Printf.sprintf "keeper %s queued exactly one message" keeper_name)
        (List.length (Keeper_chat_queue.snapshot ~keeper_name).pending = 1)
    | Some (`Queued n) ->
      check
        (Printf.sprintf "keeper %s queued exactly one message (got %d)" keeper_name n)
        false
    | Some `Not_busy ->
      check
        (Printf.sprintf "keeper %s was busy and should defer" keeper_name)
        false
    | Some (`Queue_error message) ->
      check
        (Printf.sprintf "keeper %s enqueue succeeded: %s" keeper_name message)
        false
    | None ->
      check
        (Printf.sprintf "keeper %s defer fiber completed" keeper_name)
        false);
  let total_queued =
    keeper_names
    |> List.fold_left
         (fun acc keeper_name ->
            acc + List.length (Keeper_chat_queue.snapshot ~keeper_name).pending)
         0
  in
  check "all busy dashboard messages are preserved" (total_queued = 8)
;;

let test_busy_dashboard_persist_failure_is_explicit () =
  Printf.printf "Test: busy dashboard durable enqueue failure is explicit\n%!";
  with_env
  @@ fun ~base ~clock ->
  Eio.Switch.run
  @@ fun sw ->
  with_busy_slot ~base ~sw
  @@ fun () ->
  Keeper_chat_queue.For_testing.fail_transaction_at_stages [ Mutation_applied ];
  (match
     Server_routes_http_keeper_stream.For_testing.defer_dashboard_payload_if_busy
       ~base_path:base
       ~clock
       ~thread_id
       (payload ~content:"do not acknowledge this as queued" ())
   with
   | `Queue_error message ->
     check "dashboard receives the persistence error" (String.length message > 0)
   | `Queued _ | `Not_busy ->
     check "dashboard persistence failure never claims queued" false);
  let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
  check "dashboard failed enqueue leaves no pending receipt"
    (snapshot.pending = []);
  check "dashboard failed enqueue leaves revision unchanged"
    (snapshot.revision = 0L)
;;

let test_stream_headers_close_per_turn_response () =
  Printf.printf "Test: dashboard stream response advertises connection close\n%!";
  let headers =
    Server_routes_http_keeper_stream.For_testing.keeper_chat_stream_headers ""
  in
  check "content type is event-stream"
    (Httpun.Headers.get headers "content-type" = Some "text/event-stream");
  check "per-turn stream uses close-delimited response"
    (Httpun.Headers.get headers "connection" = Some "close")
;;

let test_shutdown_fenced_dashboard_ack_preserves_cause () =
  Printf.printf
    "Test: shutdown-fenced dashboard ACK preserves operation cause\n%!";
  with_env
  @@ fun ~base ~clock ->
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  let operation_id_text =
    Keeper_shutdown_types.Operation_id.to_string operation_id
  in
  ignore
    (Keeper_turn_admission.begin_shutdown ~base_path:base ~keeper_name
       ~operation_id
      : Keeper_turn_admission.begin_shutdown_result);
  (match
     Server_routes_http_keeper_stream.For_testing
     .defer_dashboard_payload_if_busy_evidence
       ~base_path:base ~clock ~thread_id
       (payload ~content:"keep this through shutdown" ())
   with
   | `Queued (json, ack) ->
     let open Yojson.Safe.Util in
     check "dashboard queued event carries shutdown operation id"
       (String.equal operation_id_text
          (json |> member "shutdown_operation_id" |> to_string));
     check "dashboard ACK names the shutdown operation"
       (Astring.String.is_infix
          ~affix:("stopping under operation " ^ operation_id_text)
          ack);
     check "dashboard ACK promises the next active lane"
       (Astring.String.is_infix ~affix:"for the next active lane" ack)
   | `Not_busy | `Queue_error _ ->
     check "shutdown-fenced dashboard message is durably queued" false);
  check "shutdown-fenced dashboard receipt stays Pending"
    (List.length (Keeper_chat_queue.snapshot ~keeper_name).pending = 1)
;;

let test_stream_surface_preserves_typed_shutdown_rejection () =
  Printf.printf
    "Test: streaming tool surface preserves typed shutdown rejection\n%!";
  with_env
  @@ fun ~base ~clock ->
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  ignore
    (Keeper_turn_admission.begin_shutdown ~base_path:base ~keeper_name
       ~operation_id
      : Keeper_turn_admission.begin_shutdown_result);
  Eio.Switch.run
  @@ fun sw ->
  let config = Workspace.default_config base in
  let ctx : _ Keeper_types_profile.context =
    { config
    ; agent_name = "dashboard-shutdown-test"
    ; sw
    ; clock
    ; proc_mgr = None
    ; net = None
    }
  in
  let observed = ref None in
  let result =
    Keeper_tool_surface_ops.handle_keeper_msg_stream
      ~on_admission_rejected:(fun rejection -> observed := Some rejection)
      ctx
      (`Assoc
         [ ("name", `String keeper_name)
         ; ("message", `String "must remain pending")
         ])
  in
  check "shutdown-fenced stream dispatch does not report success"
    (not (Tool_result.is_success result));
  match !observed with
  | Some { Keeper_turn_admission.shutdown_operation_id = Some observed_id; _ } ->
    check
      "stream surface callback preserves the shutdown operation id"
      (Keeper_shutdown_types.Operation_id.equal observed_id operation_id)
  | Some { shutdown_operation_id = None; _ } | None ->
    check "stream surface emits a typed shutdown rejection" false
;;

let () =
  test_busy_dashboard_enqueues ();
  test_free_dashboard_not_enqueued ();
  test_existing_backlog_defers_new_dashboard_message ();
  test_concurrent_busy_dashboard_enqueues_are_per_keeper ();
  test_busy_dashboard_persist_failure_is_explicit ();
  test_stream_headers_close_per_turn_response ();
  test_shutdown_fenced_dashboard_ack_preserves_cause ();
  test_stream_surface_preserves_typed_shutdown_rejection ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_busy_dashboard_deferred checks passed\n%!"
;;
