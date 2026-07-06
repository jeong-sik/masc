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

let payload ?(name = keeper_name) ?(content = "are you there?") ()
    : Server_routes_http_keeper_stream.keeper_chat_stream_request =
  { name
  ; message = content
  ; user_blocks = []
  ; timeout_sec = None
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
      body ~base ~clock)
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
       (payload ())
   with
   | `Queued len -> check "queue length is reported" (len = 1)
   | `Not_busy -> check "busy keeper was deferred" false);
  check "exactly one dashboard message enqueued" (Keeper_chat_queue.length ~keeper_name = 1);
  (match Keeper_chat_queue.dequeue ~keeper_name with
   | Some { Keeper_chat_queue.content; source = Dashboard; _ } ->
     check "queued content is the user's message" (String.equal content "are you there?")
   | Some _ -> check "queued source is dashboard" false
   | None -> check "queue holds the dashboard message" false)
;;

let test_free_dashboard_not_enqueued () =
  Printf.printf "Test: free dashboard dispatch is not deferred\n%!";
  with_env
  @@ fun ~base ~clock ->
  (match
     Server_routes_http_keeper_stream.For_testing.defer_dashboard_payload_if_busy
       ~base_path:base
       ~clock
       (payload ~content:"run now" ())
   with
   | `Not_busy -> check "free keeper stays on direct stream path" true
   | `Queued _ -> check "free keeper must not enqueue" false);
  check "queue remains empty" (Keeper_chat_queue.length ~keeper_name = 0)
;;

let test_existing_backlog_defers_new_dashboard_message () =
  Printf.printf "Test: existing dashboard backlog keeps newer messages queued\n%!";
  with_env
  @@ fun ~base ~clock ->
  Keeper_chat_queue.enqueue ~keeper_name
    { Keeper_chat_queue.content = "older queued message"
    ; user_blocks = []
    ; attachments = []
    ; timestamp = Eio.Time.now clock
    ; source = Dashboard
    };
  (match
     Server_routes_http_keeper_stream.For_testing.defer_dashboard_payload_if_busy
       ~base_path:base
       ~clock
       (payload ~content:"newer dashboard message" ())
   with
   | `Queued len -> check "newer message joins existing backlog" (len = 2)
   | `Not_busy -> check "existing backlog should force queue path" false);
  (match Keeper_chat_queue.dequeue ~keeper_name with
   | Some { Keeper_chat_queue.content; _ } ->
     check "older queued message stays first" (String.equal content "older queued message")
   | None -> check "older queued message is present" false);
  (match Keeper_chat_queue.dequeue ~keeper_name with
   | Some { Keeper_chat_queue.content; _ } ->
     check "newer dashboard message stays second" (String.equal content "newer dashboard message")
   | None -> check "newer queued message is present" false)
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
        (Keeper_chat_queue.length ~keeper_name = 1)
    | Some (`Queued n) ->
      check
        (Printf.sprintf "keeper %s queued exactly one message (got %d)" keeper_name n)
        false
    | Some `Not_busy ->
      check
        (Printf.sprintf "keeper %s was busy and should defer" keeper_name)
        false
    | None ->
      check
        (Printf.sprintf "keeper %s defer fiber completed" keeper_name)
        false);
  let total_queued =
    keeper_names
    |> List.fold_left
         (fun acc keeper_name -> acc + Keeper_chat_queue.length ~keeper_name)
         0
  in
  check "all busy dashboard messages are preserved" (total_queued = 8)
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

let () =
  test_busy_dashboard_enqueues ();
  test_free_dashboard_not_enqueued ();
  test_existing_backlog_defers_new_dashboard_message ();
  test_concurrent_busy_dashboard_enqueues_are_per_keeper ();
  test_stream_headers_close_per_turn_response ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_busy_dashboard_deferred checks passed\n%!"
;;
