open Alcotest

let make_message ?(content = "hello") ?(keeper_name = "luna")
    ?(channel_user_id = "user-1") ?(idempotency_key = "key-1") () =
  {
    Channel_gate.channel = "discord";
    channel_user_id;
    channel_user_name = "user";
    channel_workspace_id = "workspace-1";
    keeper_name;
    content;
    idempotency_key;
    metadata = [];
  }

let reset_dedup () =
  Channel_gate.dedup_cleanup
    ~now:(Unix.gettimeofday () +. Channel_gate.dedup_ttl_sec () +. 1.0)

let unique_key prefix =
  Printf.sprintf "%s-%d-%.0f" prefix (Unix.getpid ())
    (Unix.gettimeofday () *. 1_000_000.)

let test_validate_accepts_valid_message () =
  reset_dedup ();
  match Channel_gate.validate (make_message ~idempotency_key:(unique_key "ok") ()) with
  | Ok () -> ()
  | Error _ -> fail "expected valid message to pass validation"

let test_validate_rejects_empty_keeper_name () =
  reset_dedup ();
  match Channel_gate.validate (make_message ~keeper_name:"   " ~idempotency_key:"empty-keeper" ()) with
  | Error Channel_gate.Empty_keeper_name -> ()
  | Ok () -> fail "expected Empty_keeper_name"
  | Error _ -> fail "expected Empty_keeper_name"

let test_validate_rejects_empty_content () =
  reset_dedup ();
  match Channel_gate.validate (make_message ~content:"   " ~idempotency_key:"empty-content" ()) with
  | Error Channel_gate.Empty_content -> ()
  | Ok () -> fail "expected Empty_content"
  | Error _ -> fail "expected Empty_content"

let test_validate_rejects_duplicate_message () =
  reset_dedup ();
  let key = unique_key "dup" in
  let message = make_message ~idempotency_key:key () in
  (match Channel_gate.validate message with
  | Ok () -> ()
  | Error _ -> fail "first validate should accept fresh idempotency key");
  match Channel_gate.validate message with
  | Error (Channel_gate.Duplicate_message dup_key) ->
      check string "duplicate key" key dup_key
  | Ok () -> fail "expected duplicate validation failure"
  | Error _ -> fail "expected Duplicate_message"

let test_validate_allows_key_after_cleanup () =
  reset_dedup ();
  let key = unique_key "cleanup" in
  let message = make_message ~idempotency_key:key () in
  (match Channel_gate.validate message with
  | Ok () -> ()
  | Error _ -> fail "first validate should accept fresh idempotency key");
  reset_dedup ();
  match Channel_gate.validate message with
  | Ok () -> ()
  | Error _ -> fail "cleanup should evict expired idempotency key"

let test_dedup_ttl_covers_discord_resume_replays () =
  check bool "default ttl spans long gateway resume/replay windows" true
    (Channel_gate.dedup_ttl_sec () >= 3600.0)

let test_failed_validation_does_not_consume_idempotency_key () =
  reset_dedup ();
  let key = unique_key "retryable" in
  (match
     Channel_gate.validate
       (make_message ~content:"   " ~idempotency_key:key ())
   with
  | Error Channel_gate.Empty_content -> ()
  | Ok () -> fail "expected invalid message to fail"
  | Error _ -> fail "expected Empty_content");
  match Channel_gate.validate (make_message ~idempotency_key:key ()) with
  | Ok () -> ()
  | Error _ -> fail "failed validation should not consume idempotency key"

let test_validate_serializes_duplicate_race_under_eio () =
  reset_dedup ();
  let key = unique_key "concurrent" in
  let with_eio f =
    Eio_main.run @@ fun _env ->
    Eio_guard.enable ();
    Fun.protect ~finally:Eio_guard.disable f
  in
  with_eio (fun () ->
    let results = Array.make 16 (Error Channel_gate.Empty_content) in
    Eio.Fiber.all
      (List.init 16 (fun i -> fun () ->
         results.(i) <- Channel_gate.validate (make_message ~idempotency_key:key ())
      ));
    let ok_count, duplicate_count =
      Array.fold_left
        (fun (oks, dups) -> function
          | Ok () -> (oks + 1, dups)
          | Error (Channel_gate.Duplicate_message dup_key) ->
              check string "duplicate key is preserved" key dup_key;
              (oks, dups + 1)
          | Error err ->
              fail
                (Printf.sprintf "unexpected validation result: %s"
                   (Channel_gate.validation_error_to_string err)))
        (0, 0) results
    in
    check int "exactly one fresh message wins" 1 ok_count;
    check int "all other fibers see duplicate" 15 duplicate_count)

let test_validation_error_to_string () =
  check string "empty content" "content is required"
    (Channel_gate.validation_error_to_string Channel_gate.Empty_content);
  check string "empty keeper name" "keeper_name is required"
    (Channel_gate.validation_error_to_string Channel_gate.Empty_keeper_name);
  check string "duplicate message"
    "duplicate message (idempotency_key=dup)"
    (Channel_gate.validation_error_to_string
       (Channel_gate.Duplicate_message "dup"))

let test_inbound_of_json_normalizes_channel_label () =
  let json =
    `Assoc [
      ("channel", `String "  DisCord  ");
      ("channel_user_id", `String "user-1");
      ("channel_user_name", `String "user");
      ("channel_workspace_id", `String "workspace-1");
      ("keeper_name", `String "luna");
      ("content", `String "hello");
      ("idempotency_key", `String (unique_key "json"));
    ]
  in
  match Channel_gate.inbound_of_json json with
  | Ok msg ->
      check string "channel normalized" "discord" msg.channel
  | Error err -> fail ("expected inbound json to parse: " ^ err)

(* ── Mock dispatch for handle_inbound tests ──────────────────── *)

let mock_dispatch_ok ~channel:_ ~channel_user_id:_ ~channel_user_name:_
    ~channel_workspace_id:_ ~keeper_name:_ ~idempotency_key:_ ~metadata:_ ~content:_ =
  Gate_protocol.Reply {
    content = "mock reply";
    structured = None;
    stats = Some { Gate_protocol.model_used = "test-model"; duration_ms = 42; tokens_used = 10 };
    message_request = None;
  }

let mock_dispatch_error ~channel:_ ~channel_user_id:_ ~channel_user_name:_
    ~channel_workspace_id:_ ~keeper_name:_ ~idempotency_key:_ ~metadata:_ ~content:_ =
  Gate_protocol.Keeper_error_result "mock keeper error"

let mock_dispatch_accepted_error ~channel:_ ~channel_user_id:_
    ~channel_user_name:_ ~channel_workspace_id:_ ~keeper_name:_
    ~idempotency_key ~metadata:_ ~content:_ =
  Gate_protocol.Accepted_keeper_error_result
    { detail = "mock accepted keeper error"
    ; message_id = idempotency_key
    ; receipt_id = Some "chatq_00000000-0000-4000-8000-000000000777"
    }

let mock_dispatch_raises ~channel:_ ~channel_user_id:_ ~channel_user_name:_
    ~channel_workspace_id:_ ~keeper_name:_ ~idempotency_key:_ ~metadata:_
    ~content:_ =
  failwith "unexpected dispatch exception"

let mock_dispatch_unavailable ~channel:_ ~channel_user_id:_ ~channel_user_name:_
    ~channel_workspace_id:_ ~keeper_name:_ ~idempotency_key:_ ~metadata:_ ~content:_ =
  Gate_protocol.Unavailable_result

let queued_request : Gate_protocol.message_request =
  {
    request_id = "req-queued";
    destination_type = "keeper";
    destination_id = "luna";
    channel = "discord";
    actor_id = Some "user-1";
    status = Gate_protocol.Queued;
    modalities = [ "text" ];
    transport = Some "discord";
    metadata = [ ("status_source", "keeper_msg_async") ];
  }

let mock_dispatch_queued ~channel:_ ~channel_user_id:_ ~channel_user_name:_
    ~channel_workspace_id:_ ~keeper_name:_ ~idempotency_key:_ ~metadata:_ ~content:_ =
  Gate_protocol.Reply
    { content = "luna is busy; your message is queued (request_id=req-queued)."
    ; structured = None
    ; stats = None
    ; message_request = Some queued_request
    }

let test_handle_inbound_success () =
  reset_dedup ();
  let msg = make_message ~idempotency_key:(unique_key "dispatch-ok") () in
  match Channel_gate.handle_inbound ~dispatch:mock_dispatch_ok msg with
  | Ok out ->
      check string "reply content" "mock reply" out.content;
      check string "keeper name" "luna" out.keeper_name;
      (match out.turn_stats with
       | Some s -> check string "model" "test-model" s.model_used
       | None -> fail "expected turn_stats")
  | Error e -> fail (Channel_gate.gate_error_to_string e)

let test_handle_inbound_surfaces_message_request () =
  reset_dedup ();
  let msg = make_message ~idempotency_key:(unique_key "dispatch-queued") () in
  match Channel_gate.handle_inbound ~dispatch:mock_dispatch_queued msg with
  | Ok out -> (
      check string "reply content"
        "luna is busy; your message is queued (request_id=req-queued)."
        out.content;
      match out.message_request with
      | Some request ->
          check string "request id" "req-queued" request.request_id;
          check string "status" "queued"
            (Gate_protocol.message_request_status_to_string request.status)
      | None -> fail "expected message_request")
  | Error e -> fail (Channel_gate.gate_error_to_string e)

let test_handle_inbound_keeper_error () =
  reset_dedup ();
  let msg = make_message ~idempotency_key:(unique_key "dispatch-err") () in
  match Channel_gate.handle_inbound ~dispatch:mock_dispatch_error msg with
  | Error (Channel_gate.Keeper_error err) ->
      check string "error message" "mock keeper error" err
  | Error _ -> fail "expected Keeper_error"
  | Ok _ -> fail "expected error"

let test_handle_inbound_keeper_error_releases_idempotency_key () =
  reset_dedup ();
  let msg =
    make_message ~idempotency_key:(unique_key "dispatch-err-retry") ()
  in
  (match Channel_gate.handle_inbound ~dispatch:mock_dispatch_error msg with
   | Error (Channel_gate.Keeper_error _) -> ()
   | Error _ | Ok _ -> fail "expected first keeper error");
  match Channel_gate.handle_inbound ~dispatch:mock_dispatch_ok msg with
  | Ok _ -> ()
  | Error (Channel_gate.Validation (Channel_gate.Duplicate_message _)) ->
    fail "keeper-side rejection must release the connector idempotency key"
  | Error error -> fail (Channel_gate.gate_error_to_string error)

let test_accepted_keeper_error_retains_idempotency_key () =
  reset_dedup ();
  let msg =
    make_message ~idempotency_key:(unique_key "accepted-dispatch-err") ()
  in
  (match
     Channel_gate.handle_inbound ~dispatch:mock_dispatch_accepted_error msg
   with
   | Error (Channel_gate.Accepted_keeper_error _) -> ()
   | Error _ | Ok _ -> fail "expected accepted keeper error");
  match Channel_gate.handle_inbound ~dispatch:mock_dispatch_ok msg with
  | Error (Channel_gate.Validation (Channel_gate.Duplicate_message _)) -> ()
  | Error error -> fail (Channel_gate.gate_error_to_string error)
  | Ok _ -> fail "accepted inbound message must retain its idempotency key"

let test_dispatch_exception_releases_preaccept_reservation () =
  reset_dedup ();
  let msg = make_message ~idempotency_key:(unique_key "dispatch-raise") () in
  (match Channel_gate.handle_inbound ~dispatch:mock_dispatch_raises msg with
   | Error (Channel_gate.Internal _) -> ()
   | Error _ | Ok _ -> fail "expected typed internal dispatch failure");
  match Channel_gate.handle_inbound ~dispatch:mock_dispatch_ok msg with
  | Ok _ -> ()
  | Error (Channel_gate.Validation (Channel_gate.Duplicate_message _)) ->
    fail "preaccept exception must release the reservation"
  | Error error -> fail (Channel_gate.gate_error_to_string error)

let test_inbound_error_notice_policy () =
  check bool "keeper error requires retry notice" true
    (match
       Channel_gate.inbound_error_notice (Channel_gate.Keeper_error "private")
     with
     | Channel_gate.Retry_notice -> true
     | Channel_gate.Offline_notice | Channel_gate.Accepted_failure_notice
     | Channel_gate.No_notice -> false);
  check bool "accepted keeper error requires a non-retry notice" true
    (match
       Channel_gate.inbound_error_notice
         (Channel_gate.Accepted_keeper_error
            { detail = "private"
            ; message_id = "message-1"
            ; receipt_id = None
            })
     with
     | Channel_gate.Accepted_failure_notice -> true
     | Channel_gate.Offline_notice | Channel_gate.Retry_notice
     | Channel_gate.No_notice -> false);
  check bool "offline requires offline notice" true
    (match
       Channel_gate.inbound_error_notice Channel_gate.Dispatch_unavailable
     with
     | Channel_gate.Offline_notice -> true
     | Channel_gate.Retry_notice | Channel_gate.Accepted_failure_notice
     | Channel_gate.No_notice -> false);
  check bool "validation does not expose a connector notice" true
    (match
       Channel_gate.inbound_error_notice
         (Channel_gate.Validation Channel_gate.Empty_content)
     with
     | Channel_gate.No_notice -> true
     | Channel_gate.Offline_notice | Channel_gate.Retry_notice
     | Channel_gate.Accepted_failure_notice -> false)

let test_accepted_replay_has_no_connector_notice () =
  match
    Channel_gate.inbound_error_notice
      (Channel_gate.Accepted_replay
         { message_id = "message-1"; receipt_id = None })
  with
  | Channel_gate.No_notice -> ()
  | Channel_gate.Offline_notice | Channel_gate.Retry_notice
  | Channel_gate.Accepted_failure_notice ->
    fail "accepted replay must not produce another connector message"

let test_gate_error_json_distinguishes_accepted_failure () =
  let json =
    Channel_gate.gate_error_json
      (Channel_gate.Accepted_keeper_error
         { detail = "/private/storage/path"
         ; message_id = "message-accepted-1"
         ; receipt_id = Some "chatq_00000000-0000-4000-8000-000000000778"
         })
  in
  let open Yojson.Safe.Util in
  check bool "accepted is explicit" true (json |> member "accepted" |> to_bool);
  check bool "accepted failure is not retryable" false
    (json |> member "retryable" |> to_bool);
  check string "message identity is present" "message-accepted-1"
    (json |> member "message_id" |> to_string);
  check bool "private operator detail is absent" false
    (Astring.String.is_infix ~affix:"/private/storage/path"
       (Yojson.Safe.to_string json))

let test_handle_inbound_unavailable () =
  reset_dedup ();
  let msg = make_message ~idempotency_key:(unique_key "dispatch-unavail") () in
  match Channel_gate.handle_inbound ~dispatch:mock_dispatch_unavailable msg with
  | Error Channel_gate.Dispatch_unavailable -> ()
  | Error _ -> fail "expected Dispatch_unavailable"
  | Ok _ -> fail "expected error"

let test_handle_inbound_validation_blocks_dispatch () =
  reset_dedup ();
  let msg = make_message ~content:"   " ~idempotency_key:(unique_key "val-block") () in
  match Channel_gate.handle_inbound ~dispatch:mock_dispatch_ok msg with
  | Error (Channel_gate.Validation Channel_gate.Empty_content) -> ()
  | Error _ -> fail "expected Validation(Empty_content)"
  | Ok _ -> fail "expected validation to block dispatch"

let test_handle_inbound_passes_channel_context_to_dispatch () =
  reset_dedup ();
  let seen = ref None in
  let dispatch ~channel ~channel_user_id ~channel_user_name ~channel_workspace_id
      ~keeper_name:_ ~idempotency_key ~metadata ~content:_ =
    seen :=
      Some
        (channel, channel_user_id, channel_user_name, channel_workspace_id,
         idempotency_key, metadata);
    Gate_protocol.Reply {
      content = "ok";
      structured = None;
      stats = None;
      message_request = None;
    }
  in
  let msg =
    {
      (make_message ~idempotency_key:(unique_key "dispatch-context") ()) with
      channel_user_name = "Alice";
      channel_workspace_id = "thread-7";
      metadata = [ ("discord.guild_id", "guild-1") ];
    }
  in
  match Channel_gate.handle_inbound ~dispatch msg with
  | Ok _ -> (
      match !seen with
      | Some (channel, user_id, user_name, workspace_id, idempotency_key, metadata) ->
          check string "channel" "discord" channel;
          check string "user id" "user-1" user_id;
          check string "user name" "Alice" user_name;
          check string "workspace id" "thread-7" workspace_id;
          check string "idempotency key" msg.idempotency_key idempotency_key;
          check string "metadata" "guild-1"
            (List.assoc "discord.guild_id" metadata)
      | None -> fail "dispatch should receive connector context" )
  | Error e -> fail (Channel_gate.gate_error_to_string e)

let test_handle_inbound_passes_metadata_to_dispatch () =
  reset_dedup ();
  let seen = ref None in
  let dispatch ~channel:_ ~channel_user_id:_ ~channel_user_name:_
      ~channel_workspace_id:_ ~keeper_name:_ ~idempotency_key:_ ~metadata ~content:_ =
    seen := Some metadata;
    Gate_protocol.Reply
      { content = "ok"
      ; structured = None
      ; stats = None
      ; message_request = None
      }
  in
  let msg =
    {
      (make_message ~idempotency_key:(unique_key "dispatch-metadata") ()) with
      metadata =
        [
          ("conversation_id", "discord:guild-1:channel:thread-7");
          ("external_message_id", "msg-7");
        ];
    }
  in
  match Channel_gate.handle_inbound ~dispatch msg with
  | Ok _ -> (
      match !seen with
      | Some metadata ->
          check string "conversation id" "discord:guild-1:channel:thread-7"
            (List.assoc "conversation_id" metadata);
          check string "external message id" "msg-7"
            (List.assoc "external_message_id" metadata)
      | None -> fail "dispatch should receive metadata")
  | Error e -> fail (Channel_gate.gate_error_to_string e)

let test_handle_inbound_streaming_forwards_snapshot_callback () =
  reset_dedup ();
  let snapshots = ref [] in
  let dispatch ~on_text_snapshot ~channel:_ ~channel_user_id:_
      ~channel_user_name:_ ~channel_workspace_id:_ ~keeper_name:_
      ~idempotency_key:_ ~metadata:_ ~content:_ =
    on_text_snapshot "partial";
    Gate_protocol.Reply
      { content = "ok"
      ; structured = None
      ; stats = None
      ; message_request = None
      }
  in
  let msg =
    make_message ~idempotency_key:(unique_key "dispatch-stream") ()
  in
  match
    Channel_gate.handle_inbound_streaming ~dispatch
      ~on_text_snapshot:(fun text -> snapshots := text :: !snapshots)
      msg
  with
  | Ok out ->
      check string "reply content" "ok" out.content;
      check (list string) "snapshots" [ "partial" ] (List.rev !snapshots)
  | Error e -> fail (Channel_gate.gate_error_to_string e)

let test_handle_inbound_streaming_validation_blocks_callback () =
  reset_dedup ();
  let dispatch_called = ref false in
  let snapshot_called = ref false in
  let dispatch ~on_text_snapshot:_ ~channel:_ ~channel_user_id:_
      ~channel_user_name:_ ~channel_workspace_id:_ ~keeper_name:_
      ~idempotency_key:_ ~metadata:_ ~content:_ =
    dispatch_called := true;
    Gate_protocol.Reply
      { content = "ok"
      ; structured = None
      ; stats = None
      ; message_request = None
      }
  in
  let msg =
    make_message ~content:"   "
      ~idempotency_key:(unique_key "dispatch-stream-invalid") ()
  in
  match
    Channel_gate.handle_inbound_streaming ~dispatch
      ~on_text_snapshot:(fun _ -> snapshot_called := true)
      msg
  with
  | Error (Channel_gate.Validation Channel_gate.Empty_content) ->
      check bool "dispatch not called" false !dispatch_called;
      check bool "snapshot not called" false !snapshot_called
  | Error _ -> fail "expected Validation(Empty_content)"
  | Ok _ -> fail "expected validation to block dispatch"

let () =
  Alcotest.run "Channel_gate"
    [
      ( "validate",
        [
          test_case "accepts valid message" `Quick
            test_validate_accepts_valid_message;
          test_case "rejects empty content" `Quick
            test_validate_rejects_empty_content;
          test_case "rejects empty keeper name" `Quick
            test_validate_rejects_empty_keeper_name;
          test_case "rejects duplicate message" `Quick
            test_validate_rejects_duplicate_message;
          test_case "allows key after cleanup" `Quick
            test_validate_allows_key_after_cleanup;
          test_case "dedup ttl covers discord resume replays" `Quick
            test_dedup_ttl_covers_discord_resume_replays;
          test_case "failed validation does not consume key" `Quick
            test_failed_validation_does_not_consume_idempotency_key;
          test_case "serializes duplicate race under eio" `Quick
            test_validate_serializes_duplicate_race_under_eio;
          test_case "stringifies validation errors" `Quick
            test_validation_error_to_string;
          test_case "normalizes inbound channel labels" `Quick
            test_inbound_of_json_normalizes_channel_label;
        ] );
      ( "handle_inbound",
        [
          test_case "dispatches and returns reply" `Quick
            test_handle_inbound_success;
          test_case "surfaces message_request" `Quick
            test_handle_inbound_surfaces_message_request;
          test_case "passes channel context to dispatch" `Quick
            test_handle_inbound_passes_channel_context_to_dispatch;
          test_case "passes metadata to dispatch" `Quick
            test_handle_inbound_passes_metadata_to_dispatch;
          test_case "streaming forwards snapshot callback" `Quick
            test_handle_inbound_streaming_forwards_snapshot_callback;
          test_case "streaming validation blocks callback" `Quick
            test_handle_inbound_streaming_validation_blocks_callback;
          test_case "returns keeper error" `Quick
            test_handle_inbound_keeper_error;
          test_case "keeper error releases idempotency key" `Quick
            test_handle_inbound_keeper_error_releases_idempotency_key;
          test_case "accepted keeper error retains idempotency key" `Quick
            test_accepted_keeper_error_retains_idempotency_key;
          test_case "dispatch exception releases preaccept reservation" `Quick
            test_dispatch_exception_releases_preaccept_reservation;
          test_case "maps gate errors to connector notices" `Quick
            test_inbound_error_notice_policy;
          test_case "accepted replay has no connector notice" `Quick
            test_accepted_replay_has_no_connector_notice;
          test_case "typed accepted failure envelope" `Quick
            test_gate_error_json_distinguishes_accepted_failure;
          test_case "returns unavailable" `Quick
            test_handle_inbound_unavailable;
          test_case "validation blocks dispatch" `Quick
            test_handle_inbound_validation_blocks_dispatch;
        ] );
    ]
