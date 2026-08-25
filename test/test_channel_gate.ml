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

let unique_key prefix =
  Printf.sprintf "%s-%d-%.0f" prefix (Unix.getpid ())
    (Unix.gettimeofday () *. 1_000_000.)

let test_validate_accepts_valid_message () =
  match Channel_gate.validate (make_message ~idempotency_key:(unique_key "ok") ()) with
  | Ok () -> ()
  | Error _ -> fail "expected valid message to pass validation"

let test_validate_rejects_empty_keeper_name () =
  match Channel_gate.validate (make_message ~keeper_name:"   " ~idempotency_key:"empty-keeper" ()) with
  | Error Channel_gate.Empty_keeper_name -> ()
  | Ok () -> fail "expected Empty_keeper_name"
  | Error _ -> fail "expected Empty_keeper_name"

let test_validate_rejects_empty_content () =
  match Channel_gate.validate (make_message ~content:"   " ~idempotency_key:"empty-content" ()) with
  | Error Channel_gate.Empty_content -> ()
  | Ok () -> fail "expected Empty_content"
  | Error _ -> fail "expected Empty_content"

let test_failed_validation_does_not_poison_retry () =
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

let test_validation_error_to_string () =
  check string "empty content" "content is required"
    (Channel_gate.validation_error_to_string Channel_gate.Empty_content);
  check string "empty keeper name" "destination_id is required"
    (Channel_gate.validation_error_to_string Channel_gate.Empty_keeper_name)

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

let mock_dispatch_unavailable ~channel:_ ~channel_user_id:_ ~channel_user_name:_
    ~channel_workspace_id:_ ~keeper_name:_ ~idempotency_key:_ ~metadata:_ ~content:_ =
  Gate_protocol.Unavailable_result

let queued_request : Gate_protocol.message_request =
  {
    request_id = "kmsg-queued";
    destination_type = "keeper";
    destination_id = "luna";
    channel = "discord";
    actor_id = Some "user-1";
    status = Gate_protocol.Queued;
    modalities = [ "text" ];
    transport = Some "discord";
    metadata =
      [ ("status_source", "keeper_chat_operation")
      ; ("operation_id", "kmsg-queued")
      ];
  }

let mock_dispatch_queued ~channel:_ ~channel_user_id:_ ~channel_user_name:_
    ~channel_workspace_id:_ ~keeper_name:_ ~idempotency_key:_ ~metadata:_ ~content:_ =
  Gate_protocol.Reply
    { content = "luna accepted operation kmsg-queued (queued)."
    ; structured = None
    ; stats = None
    ; message_request = Some queued_request
    }

let test_handle_inbound_success () =
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
  let msg = make_message ~idempotency_key:(unique_key "dispatch-queued") () in
  match Channel_gate.handle_inbound ~dispatch:mock_dispatch_queued msg with
  | Ok out -> (
      check string "reply content"
        "luna accepted operation kmsg-queued (queued)."
        out.content;
      match out.message_request with
      | Some request ->
          check string "operation id" "kmsg-queued" request.request_id;
          check string "status" "queued"
            (Gate_protocol.message_request_status_to_string request.status)
      | None -> fail "expected message_request")
  | Error e -> fail (Channel_gate.gate_error_to_string e)

let test_handle_inbound_keeper_error () =
  let msg = make_message ~idempotency_key:(unique_key "dispatch-err") () in
  match Channel_gate.handle_inbound ~dispatch:mock_dispatch_error msg with
  | Error (Channel_gate.Keeper_error err) ->
      check string "error message" "mock keeper error" err
  | Error _ -> fail "expected Keeper_error"
  | Ok _ -> fail "expected error"

let test_handle_inbound_unavailable () =
  let msg = make_message ~idempotency_key:(unique_key "dispatch-unavail") () in
  match Channel_gate.handle_inbound ~dispatch:mock_dispatch_unavailable msg with
  | Error Channel_gate.Dispatch_unavailable -> ()
  | Error _ -> fail "expected Dispatch_unavailable"
  | Ok _ -> fail "expected error"

let test_handle_inbound_validation_blocks_dispatch () =
  let msg = make_message ~content:"   " ~idempotency_key:(unique_key "val-block") () in
  match Channel_gate.handle_inbound ~dispatch:mock_dispatch_ok msg with
  | Error (Channel_gate.Validation Channel_gate.Empty_content) -> ()
  | Error _ -> fail "expected Validation(Empty_content)"
  | Ok _ -> fail "expected validation to block dispatch"

let test_handle_inbound_passes_channel_context_to_dispatch () =
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
          test_case "failed validation does not poison retry" `Quick
            test_failed_validation_does_not_poison_retry;
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
          test_case "returns keeper error" `Quick
            test_handle_inbound_keeper_error;
          test_case "returns unavailable" `Quick
            test_handle_inbound_unavailable;
          test_case "validation blocks dispatch" `Quick
            test_handle_inbound_validation_blocks_dispatch;
        ] );
    ]
