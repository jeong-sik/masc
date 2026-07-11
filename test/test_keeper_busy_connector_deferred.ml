(* test_keeper_busy_connector_deferred.ml — RFC-connector-deferred-reply-via-chat-queue §4.

   Production-path proof (not a pure-helper test): a Discord connector message
   that arrives while the keeper already holds an in-flight turn is routed
   through [Gate_keeper_backend.dispatch] onto [Keeper_chat_queue] (where the
   serial consumer can drain it and deliver the reply via the Discord outbound
   adapter), NOT the outbound-less async [Keeper_msg_async] poll store — the
   RFC root-cause fix. It also pins the recording-ownership invariant: the gate
   inbound boundary records the connector user line exactly once, with no paired
   assistant row yet (the message is still pending, waiting to be drained).

   The Discord busy branch enqueues and returns a queued ACK without running a
   keeper turn, so this needs no provider: [proc_mgr]/[net] are [None] and the
   admission slot is held by a sibling fiber for the whole assertion window. *)

open Masc

let failures = ref 0

let check name cond =
  if cond then Printf.printf "  \xe2\x9c\x93 %s\n%!" name
  else (
    incr failures;
    Printf.printf "  \xe2\x9c\x97 %s\n%!" name)

let contains ~affix text = Astring.String.is_infix ~affix text

let keeper_name = "busy-connector-keeper"

(* Hold the keeper's admission slot busy in a forked fiber (the proven pattern
   from test_keeper_turn_admission): the body resolves [started] then blocks on
   [release], so the slot stays occupied across [f]. *)
let with_busy_slot ~base ~sw f =
  let started, set_started = Eio.Promise.create () in
  let release, set_release = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    ignore
      (Keeper_turn_admission.run_serialized ~base_path:base ~keeper_name
         (fun () ->
           Eio.Promise.resolve set_started ();
           Eio.Promise.await release)));
  Eio.Promise.await started;
  let result = f () in
  Eio.Promise.resolve set_release ();
  result

let with_unpublished_busy_slot ~base ~sw f =
  let started, set_started = Eio.Promise.create () in
  let release, set_release = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Keeper_turn_admission.For_testing.with_unpublished_turn_lock
      ~base_path:base ~keeper_name (fun () ->
        Eio.Promise.resolve set_started ();
        Eio.Promise.await release));
  Eio.Promise.await started;
  let result = f () in
  Eio.Promise.resolve set_release ();
  result

let count_user_lines ~base =
  (* The gate inbound boundary records the connector user line as a pending
     (assistant-less) row. Count those rows for the keeper to assert exactly-once
     recording. *)
  List.length
    (List.filter
       (fun (m : Keeper_chat_store.chat_message) ->
          match m.role with Keeper_chat_store.Role.User -> true | _ -> false)
       (Keeper_chat_store.load ~base_dir:base ~keeper_name))

let configure_queue ~base =
  Keeper_chat_queue.For_testing.reset ();
  let report = Keeper_chat_queue.configure_persistence ~base_path:base in
  check "chat queue persistence configured without load errors"
    (report.load_errors = [])

let test_busy_discord_enqueues () =
  Printf.printf
    "Test: busy Discord dispatch enqueues onto Keeper_chat_queue (not async poll)\n%!";
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-busy-conn-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote base))))
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock = Eio.Stdenv.clock env in
      let config = Workspace.default_config base in
      ignore (Workspace.init config ~agent_name:(Some keeper_name));
      Keeper_turn_admission.For_testing.reset ();
      configure_queue ~base;
      Eio.Switch.run (fun sw ->
        Eio.Switch.on_release sw Keeper_chat_queue.For_testing.reset;
        let reply =
          with_busy_slot ~base ~sw (fun () ->
            Gate_keeper_backend.dispatch
              ~connector_kind:Gate_keeper_backend.Discord
              ~sw ~clock ~proc_mgr:None ~net:None ~config
              ~channel:"discord" ~channel_user_id:"user-42"
              ~channel_user_name:"Tester" ~channel_workspace_id:"chan-777"
              ~keeper_name ~idempotency_key:"discord-msg-777"
              ~metadata:[] ~content:"are you there?")
        in
        (* The connector receives a busy ACK now; the deferred reply arrives
           later via the consumer. The existing message-request envelope carries
           the durable queue receipt instead of an async-poll request id. *)
        let ack_receipt_id = ref None in
        (match reply with
         | Gate_protocol.Reply
             { message_request = Some request; content; _ } ->
             ack_receipt_id := Some request.request_id;
             check "busy connector ACK is queued"
               (request.status = Gate_protocol.Queued);
             check "busy connector ACK carries queue status source"
               (List.assoc_opt "status_source" request.metadata
                = Some "keeper_chat_queue");
             check "busy connector ACK carries queue revision"
               (List.assoc_opt "queue_revision" request.metadata <> None);
             check "busy ACK text is non-empty" (String.length content > 0)
         | Gate_protocol.Reply { message_request = None; _ } ->
             check "busy connector ACK carries durable receipt" false
         | Gate_protocol.Keeper_error_result _
         | Gate_protocol.Unavailable_result ->
             check "busy Discord dispatch returns a Reply (not error/unavailable)"
               false);
        (* The message lands on the chat queue with the typed Discord source so
           the serial consumer can drain it and route the reply to the channel. *)
        let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
        check "exactly one durable receipt is pending"
          (List.length snapshot.pending = 1);
        check "no durable receipt is inflight yet"
          (snapshot.inflight = []);
        check "queue snapshot has no load errors" (snapshot.load_errors = []);
        (match snapshot.pending with
         | [ { Keeper_chat_queue.receipt_id; message =
                 { Keeper_chat_queue.source =
                     Keeper_chat_queue.Discord { channel_id; user_id }
                 ; content
                 ; _
                 }
             ; _
             } ] ->
             check "ACK and pending receipt ids match"
               (Some (Keeper_chat_queue.Receipt_id.to_string receipt_id)
                = !ack_receipt_id);
             check "queued source is the Discord channel_id"
               (channel_id = "chan-777");
             check "queued source carries the user_id" (user_id = "user-42");
             check "queued content is the user's message"
               (content = "are you there?")
         | _ -> check "queue holds one Discord receipt" false);
        (match Keeper_chat_queue.lease_batch ~keeper_name with
         | `Leased lease ->
             check "lease carries the pending receipt"
               (List.length lease.items = 1);
             (match
                Keeper_chat_queue.finalize ~keeper_name
                  ~lease_id:lease.lease_id
                  ~outcome:
                    (Keeper_chat_queue.Mark_delivered
                       { completed_at = Time_compat.now (); outcome_ref = None })
              with
              | `Finalized receipt_ids ->
                  check "finalize records the delivered receipt"
                    (List.length receipt_ids = 1)
              | `Unknown_lease | `Error _ ->
                  check "leased receipt finalizes" false)
         | `Empty | `Already_leased _ | `Error _ ->
             check "pending receipt leases" false);
        (* Ownership invariant (RFC §3.4): the gate inbound boundary recorded the
           user line exactly once; no paired assistant row exists yet because the
           turn has not been drained. *)
        check "gate inbound recorded the connector user line exactly once"
          (count_user_lines ~base = 1)))

let test_unpublished_busy_slot_queues_without_resolved_meta () =
  Printf.printf
    "Test: unresolved-meta Gate queues during the lock-before-in-flight window\n%!";
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-unpublished-conn-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote base))))
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock = Eio.Stdenv.clock env in
      let config = Workspace.default_config base in
      ignore (Workspace.init config ~agent_name:(Some keeper_name));
      Keeper_turn_admission.For_testing.reset ();
      configure_queue ~base;
      Eio.Switch.run (fun sw ->
        Eio.Switch.on_release sw Keeper_chat_queue.For_testing.reset;
        let reply =
          with_unpublished_busy_slot ~base ~sw (fun () ->
            check "raw lock has no published in-flight metadata"
              (Keeper_turn_admission.in_flight ~base_path:base ~keeper_name = None);
            Gate_keeper_backend.dispatch
              ~connector_kind:Gate_keeper_backend.Discord
              ~sw ~clock ~proc_mgr:None ~net:None ~config
              ~channel:"discord" ~channel_user_id:"user-unpublished"
              ~channel_user_name:"Tester" ~channel_workspace_id:"chan-unpublished"
              ~keeper_name ~idempotency_key:"discord-msg-unpublished"
              ~metadata:[] ~content:"queue me during admission")
        in
        (match reply with
         | Gate_protocol.Reply { message_request = Some request; _ } ->
           check "unpublished busy slot returns a queued ACK"
             (request.status = Gate_protocol.Queued)
         | Gate_protocol.Reply { message_request = None; _ }
         | Gate_protocol.Keeper_error_result _
         | Gate_protocol.Unavailable_result ->
           check "unpublished busy slot returns a queued ACK" false);
        let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
        check "unpublished busy slot durably preserves the connector message"
          (List.length snapshot.pending = 1 && snapshot.inflight = [])))

let test_busy_discord_persist_failure_is_explicit () =
  Printf.printf
    "Test: busy Discord dispatch fails closed when durable enqueue fails\n%!";
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-busy-conn-fail-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote base))))
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock = Eio.Stdenv.clock env in
      let config = Workspace.default_config base in
      ignore (Workspace.init config ~agent_name:(Some keeper_name));
      Keeper_turn_admission.For_testing.reset ();
      configure_queue ~base;
      Eio.Switch.run (fun sw ->
        Eio.Switch.on_release sw Keeper_chat_queue.For_testing.reset;
        let reply =
          with_busy_slot ~base ~sw (fun () ->
            Keeper_chat_queue.For_testing.fail_next_persist ();
            Gate_keeper_backend.dispatch
              ~connector_kind:Gate_keeper_backend.Discord
              ~sw ~clock ~proc_mgr:None ~net:None ~config
              ~channel:"discord" ~channel_user_id:"user-42"
              ~channel_user_name:"Tester" ~channel_workspace_id:"chan-777"
              ~keeper_name ~idempotency_key:"discord-msg-persist-fail"
              ~metadata:[] ~content:"do not lose me")
        in
        (match reply with
         | Gate_protocol.Keeper_error_result message ->
             check "persistence failure is returned explicitly"
               (String.length message > 0)
         | Gate_protocol.Reply _ | Gate_protocol.Unavailable_result ->
             check "persistence failure never claims queued" false);
        let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
        check "failed enqueue leaves no pending receipt"
          (snapshot.pending = []);
        check "failed enqueue does not advance queue revision"
          (snapshot.revision = 0L)))

let test_pending_receipt_prevents_direct_overtake () =
  Printf.printf "Test: active receipt queues a later connector turn without a live slot\n%!";
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-pending-conn-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote base))))
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock = Eio.Stdenv.clock env in
      let config = Workspace.default_config base in
      ignore (Workspace.init config ~agent_name:(Some keeper_name));
      Keeper_turn_admission.For_testing.reset ();
      configure_queue ~base;
      ignore
        (Keeper_chat_queue.enqueue ~keeper_name
           { content = "first"
           ; user_blocks = []
           ; attachments = []
           ; timestamp = Eio.Time.now clock
           ; source =
               Keeper_chat_queue.Discord
                 { channel_id = "chan-777"; user_id = "user-42" }
           });
      Eio.Switch.run @@ fun sw ->
      let reply =
        Gate_keeper_backend.dispatch
          ~connector_kind:Gate_keeper_backend.Discord
          ~sw ~clock ~proc_mgr:None ~net:None ~config
          ~channel:"discord" ~channel_user_id:"user-42"
          ~channel_user_name:"Tester" ~channel_workspace_id:"chan-777"
          ~keeper_name ~idempotency_key:"discord-msg-778"
          ~metadata:[] ~content:"second"
      in
      (match reply with
       | Gate_protocol.Reply { message_request = Some request; _ } ->
         check "later connector input is queued" (request.status = Gate_protocol.Queued)
       | _ -> check "later connector input is queued" false);
      let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
      check "FIFO keeps both accepted receipts pending"
        (List.map (fun item -> item.Keeper_chat_queue.message.content) snapshot.pending
         = [ "first"; "second" ]))

let test_busy_slack_preserves_thread_context () =
  Printf.printf "Test: busy Slack dispatch preserves reply-thread identity\n%!";
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-busy-slack-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote base))))
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock = Eio.Stdenv.clock env in
      let config = Workspace.default_config base in
      ignore (Workspace.init config ~agent_name:(Some keeper_name));
      Keeper_turn_admission.For_testing.reset ();
      configure_queue ~base;
      Eio.Switch.run @@ fun sw ->
      let reply =
        with_busy_slot ~base ~sw (fun () ->
          Gate_keeper_backend.dispatch
            ~connector_kind:Gate_keeper_backend.Slack
            ~sw ~clock ~proc_mgr:None ~net:None ~config
            ~channel:"slack" ~channel_user_id:"U-42"
            ~channel_user_name:"Slack User" ~channel_workspace_id:"C-777"
            ~keeper_name ~idempotency_key:"slack-msg-171.001"
            ~metadata:
              [ "slack.message_ts", "171.001"
              ; "slack.team_id", "T-777"
              ]
            ~content:"threaded question")
      in
      (match reply with
       | Gate_protocol.Reply { message_request = Some request; _ } ->
         check "Slack busy input is queued" (request.status = Gate_protocol.Queued)
       | _ -> check "Slack busy input is queued" false);
      match (Keeper_chat_queue.snapshot ~keeper_name).pending with
      | [ { message =
              { source =
                  Keeper_chat_queue.Slack
                    { channel_id; user_id; user_name; team_id; thread_ts }
              ; _
              }
          ; _
          } ] ->
        check "Slack channel retained" (channel_id = "C-777");
        check "Slack user retained" (user_id = "U-42" && user_name = "Slack User");
        check "Slack team retained" (team_id = Some "T-777");
        check "top-level message roots deferred reply thread"
          (thread_ts = Some "171.001")
      | _ -> check "one typed Slack receipt is pending" false)

let test_shutdown_fenced_connector_ack
    ~label ~connector_kind ~channel ~channel_user_id ~channel_user_name
    ~channel_workspace_id ~metadata ~content ~source_matches =
  Printf.printf
    "Test: shutdown-fenced %s ACK carries typed operation cause\n%!"
    label;
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-shutdown-conn-%s-%d-%d"
         (String.lowercase_ascii label)
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote base))))
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock = Eio.Stdenv.clock env in
      let config = Workspace.default_config base in
      ignore (Workspace.init config ~agent_name:(Some keeper_name));
      Keeper_turn_admission.For_testing.reset ();
      configure_queue ~base;
      let operation_id = Keeper_shutdown_types.Operation_id.generate () in
      let operation_id_text =
        Keeper_shutdown_types.Operation_id.to_string operation_id
      in
      (match
         Keeper_turn_admission.begin_shutdown
           ~base_path:base ~keeper_name ~operation_id
       with
       | Keeper_turn_admission.Shutdown_reserved _ -> ()
       | Keeper_turn_admission.Shutdown_already_reserved _ ->
         check (label ^ " shutdown fence is newly reserved") false);
      Eio.Switch.run (fun sw ->
        Eio.Switch.on_release sw Keeper_chat_queue.For_testing.reset;
        let reply =
          Gate_keeper_backend.dispatch
            ~connector_kind ~sw ~clock ~proc_mgr:None ~net:None ~config
            ~channel ~channel_user_id ~channel_user_name ~channel_workspace_id
            ~keeper_name
            ~idempotency_key:("shutdown-fenced-" ^ String.lowercase_ascii label)
            ~metadata ~content
        in
        (match reply with
         | Gate_protocol.Reply
             { message_request = Some request; content = ack_text; _ } ->
           check (label ^ " shutdown-fenced input is durably queued")
             (request.status = Gate_protocol.Queued);
           check (label ^ " ACK metadata carries shutdown operation id")
             (List.assoc_opt "shutdown_operation_id" request.metadata
              = Some operation_id_text);
           check (label ^ " ACK names the stopping operation")
             (contains
                ~affix:
                  (Printf.sprintf "is stopping under shutdown operation %s"
                     operation_id_text)
                ack_text);
           check (label ^ " ACK promises the next active lane")
             (contains
                ~affix:"durably queued and will wait for the next active lane"
                ack_text);
           check (label ^ " ACK does not claim the current turn will finish")
             (not (contains ~affix:"current turn finishes" ack_text))
         | Gate_protocol.Reply { message_request = None; _ }
         | Gate_protocol.Keeper_error_result _
         | Gate_protocol.Unavailable_result ->
           check (label ^ " shutdown-fenced input returns a queued ACK") false);
        (match (Keeper_chat_queue.snapshot ~keeper_name).pending with
         | [ { Keeper_chat_queue.message = { source; _ }; _ } ] ->
           check (label ^ " shutdown-fenced receipt retains connector source")
             (source_matches source)
         | _ ->
           check (label ^ " shutdown-fenced receipt is pending exactly once") false));
      match
        Keeper_turn_admission.rollback_shutdown
          ~base_path:base ~keeper_name ~operation_id
      with
      | Keeper_turn_admission.Shutdown_rolled_back -> ()
      | Keeper_turn_admission.Shutdown_not_reserved
      | Keeper_turn_admission.Shutdown_reserved_by_other _ ->
        check (label ^ " shutdown fence rolls back") false)

let test_shutdown_fenced_discord_ack () =
  test_shutdown_fenced_connector_ack
    ~label:"Discord" ~connector_kind:Gate_keeper_backend.Discord
    ~channel:"discord" ~channel_user_id:"discord-user"
    ~channel_user_name:"Discord User" ~channel_workspace_id:"discord-channel"
    ~metadata:[] ~content:"keep this until restart"
    ~source_matches:(function
      | Keeper_chat_queue.Discord { channel_id; user_id } ->
        channel_id = "discord-channel" && user_id = "discord-user"
      | Keeper_chat_queue.Dashboard | Keeper_chat_queue.Slack _ -> false)

let test_shutdown_fenced_slack_ack () =
  test_shutdown_fenced_connector_ack
    ~label:"Slack" ~connector_kind:Gate_keeper_backend.Slack
    ~channel:"slack" ~channel_user_id:"U-SHUTDOWN"
    ~channel_user_name:"Slack User" ~channel_workspace_id:"C-SHUTDOWN"
    ~metadata:
      [ "slack.message_ts", "171.999"
      ; "slack.team_id", "T-SHUTDOWN"
      ]
    ~content:"keep this until restart"
    ~source_matches:(function
      | Keeper_chat_queue.Slack
          { channel_id; user_id; team_id; thread_ts; _ } ->
        channel_id = "C-SHUTDOWN"
        && user_id = "U-SHUTDOWN"
        && team_id = Some "T-SHUTDOWN"
        && thread_ts = Some "171.999"
      | Keeper_chat_queue.Dashboard | Keeper_chat_queue.Discord _ -> false)

let () =
  test_busy_discord_enqueues ();
  test_unpublished_busy_slot_queues_without_resolved_meta ();
  test_busy_discord_persist_failure_is_explicit ();
  test_pending_receipt_prevents_direct_overtake ();
  test_busy_slack_preserves_thread_context ();
  test_shutdown_fenced_discord_ack ();
  test_shutdown_fenced_slack_ack ();
  if !failures > 0 then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_busy_connector_deferred checks passed\n%!"
