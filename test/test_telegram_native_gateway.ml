open Alcotest
open Masc
module Api=Telegram_rest_client
module Gateway=Server_telegram_in_process_gateway.For_testing
module Route=Keeper_continuation_channel
let ok = function Ok value -> value | Error detail -> fail detail
let parsed body = Api.parse_updates_response ~status:200 ~body |> function Ok [u] -> u | Ok _ -> fail "one update expected" | Error e -> fail(Format.asprintf "%a" Api.pp_error e)
let inbound = {|{"ok":true,"result":[{"update_id":90,"message":{"message_id":8,"chat":{"id":-1001234567890},"message_thread_id":7,"from":{"id":1234567890123,"is_bot":false,"first_name":"Ada"},"text":"hello"}}]}|}
let test_route_roundtrip_and_topics () =
  let route=Route.telegram ~bot_user_id:777L ~chat_id:(-1001234567890L) ~message_thread_id:(Some 7)
    ~direct_messages_topic_id:None ~reply_to_message_id:(Some 8) ~user_id:1234567890123L |> ok in
  check bool "lossless strict persistence" true (Route.same_route route (Route.of_yojson(Route.to_yojson route) |> ok));
  let other=Route.telegram ~bot_user_id:777L ~chat_id:(-1001234567890L) ~message_thread_id:(Some 8)
    ~direct_messages_topic_id:None ~reply_to_message_id:(Some 8) ~user_id:1234567890123L |> ok in
  check bool "topics do not batch as one conversation" false (Route.same_conversation route other);
  let other_bot=Route.telegram ~bot_user_id:778L ~chat_id:(-1001234567890L) ~message_thread_id:(Some 7)
    ~direct_messages_topic_id:None ~reply_to_message_id:(Some 8) ~user_id:1234567890123L |> ok in
  check bool "different bot route never aliases" false (Route.same_conversation route other_bot);
  let json=match Route.to_yojson route with `Assoc fields -> `Assoc(("chat_id",`Int 3)::fields) | _ -> fail "object" in
  check bool "duplicate route coordinate rejected" true (Result.is_error(Route.of_yojson json))
let with_claim_root run =
  Eio_main.run (fun env ->
    if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
    let root=Filename.temp_file "telegram-claim" "" in
    Sys.remove root;
    Fun.protect ~finally:(fun()->if Sys.file_exists root then Fs_compat.remove_tree root) (fun()->run root))
let test_producer_exact_route_and_receipt () = with_claim_root (fun claim_root ->
  let observed=ref None in
  let dispatch_for_delivery (delivery:Gate_keeper_backend.connector_delivery)
      ~channel ~channel_user_id ~channel_user_name:_ ~channel_workspace_id ~keeper_name ~idempotency_key ~metadata:_ ~content =
    observed:=Some(delivery,channel_user_id,channel_workspace_id,content);
    Gate_protocol.Reply{content="queued";structured=None;stats=None;message_request=Some {
      request_id=idempotency_key;destination_type="keeper";destination_id=keeper_name;channel;actor_id=Some channel_user_id;
      status=Queued;modalities=["text"];transport=Some channel;metadata=[]}} in
  let result=Gateway.accept_update ~claim_root ~resolve:(fun ~channel_id -> check string "binding uses signed chat id" "-1001234567890" channel_id;Ok(Some "k"))
    ~dispatch_for_delivery ~bot_user_id:777L ~operation_id:"telegram-exact-update90" (parsed inbound) |> ok in
  (match result with Telegram_poll_custody.Accepted {message_request=Some receipt;_} -> check string "receipt conserved" "telegram-exact-update90" receipt.request_id
   | Accepted _ | Intentionally_ignored _ -> fail "missing original receipt");
  match !observed with
  | None -> fail "dispatch missing"
  | Some(delivery,user,workspace,content) ->
    check string "original caller" "1234567890123" user;
    check string "Telegram has no workspace" "" workspace;
    check string "unaltered human content" "hello" content;
    (match delivery.continuation_channel with
     | Route.Telegram {bot_user_id=777L;chat_id= -1001234567890L;message_thread_id=Some 7;reply_to_message_id=Some 8;user_id=1234567890123L;direct_messages_topic_id=None} -> ()
     | _ -> fail "route lost native coordinates");
    let make surface=Keeper_chat_operation_payload.source_to_json ~submitted_by:"test" ~thread_id:"keeper:k"
      ~continuation_channel:delivery.continuation_channel ~surface ~channel:"telegram" ~channel_user_id:user
      ~channel_user_name:"Ada" ~channel_workspace_id:"" ~conversation_id:delivery.conversation_id
      ~external_message_id:delivery.external_message_id ~workspace_id:None ~extra_mentions:[] ~sender_keeper:None
      ~user_row_origin:Keeper_chat_store.Needs_append in
    let source = make delivery.surface |> ok in
    let canonical = Keeper_chat_operation.canonical_json_string source |> ok |> Yojson.Safe.from_string in
    ignore(Keeper_chat_operation_payload.source_of_json canonical |> ok);
    let actual=Surface_ref.of_json(Surface_ref.to_json delivery.surface) |> ok in
    check bool "terminal consumer accepts persisted coordinates" true
      (Keeper_telegram_coordinates.matches_surface ~bot_user_id:777L ~chat_id:(-1001234567890L)
        ~message_thread_id:(Some 7) ~direct_messages_topic_id:None ~reply_to_message_id:(Some 8) actual);
    (match delivery.surface with
     | Surface_ref.Gate {label;address} ->
       ignore(make(Surface_ref.Gate{label;address=List.rev address}) |> ok);
       List.iter (fun bad -> check bool "exact address rejects duplicate missing and unknown fields" true (Result.is_error(make(Surface_ref.Gate{label;address=bad}))))
         ([(("chat_id","-1001234567890")::address);List.tl address;("unexpected","value")::address])
     | _ -> fail "Telegram surface must be Gate");
    check bool "tampered generic surface cannot replace typed topic" true
      (Result.is_error(make(Keeper_telegram_coordinates.surface ~bot_user_id:777L ~chat_id:(-1001234567890L)
        ~message_thread_id:(Some 8) ~direct_messages_topic_id:None ~reply_to_message_id:(Some 8)))))
let test_unreadable_binding_is_not_ignored () = with_claim_root (fun claim_root ->
  let called=ref false in
  let dispatch_for_delivery _ ~channel:_ ~channel_user_id:_ ~channel_user_name:_ ~channel_workspace_id:_ ~keeper_name:_ ~idempotency_key:_ ~metadata:_ ~content:_ =
    called:=true;Gate_protocol.Unavailable_result in
  check bool "binding failure refuses acceptance" true
    (Result.is_error(Gateway.accept_update ~claim_root ~resolve:(fun ~channel_id:_ -> Error "binding unreadable") ~dispatch_for_delivery
      ~bot_user_id:777L ~operation_id:"op" (parsed inbound)));
  check bool "no dispatch on unknown binding" false !called)
let with_token f =
  let previous=Sys.getenv_opt "TELEGRAM_BOT_TOKEN" in
  Fun.protect ~finally:(fun()->match previous with None -> Unix.unsetenv "TELEGRAM_BOT_TOKEN" | Some value -> Unix.putenv "TELEGRAM_BOT_TOKEN" value)
    (fun()->Unix.putenv "TELEGRAM_BOT_TOKEN" "fixture-token";Eio_main.run(fun env->f(Eio.Stdenv.clock env)))
let test_sender_identity_topics_partial_failure () = with_token(fun clock ->
  let sends=ref [] in
  let post ~url ~body =
    match Filename.basename(Uri.path(Uri.of_string url)) with
    | "getMe" -> Ok(200,{|{"ok":true,"result":{"id":777,"is_bot":true,"first_name":"Bot"}}|})
    | "sendMessage" ->
      sends:=Yojson.Safe.from_string body::!sends;
      if List.length !sends=2 then Error () else Ok(200,{|{"ok":true,"result":{"message_id":99,"chat":{"id":-1001234567890},"message_thread_id":7}}|})
    | _ -> fail "unexpected method" in
  (match Channel_gate_telegram_state.send_message ~post ~clock ~bot_user_id:778L ~chat_id:(-1001234567890L)
    ~message_thread_id:(Some 7) ~direct_messages_topic_id:None ~reply_to_message_id:(Some 8) ~html:false ~messages:["hello"] () with
   | Error(Api_failure _) -> () | _ -> fail "wrong bot sent a reply");
  check int "wrong bot performs no sends" 0 (List.length !sends);
  (match Channel_gate_telegram_state.send_message ~post ~clock ~bot_user_id:777L ~chat_id:(-1001234567890L)
    ~message_thread_id:(Some 7) ~direct_messages_topic_id:None ~reply_to_message_id:(Some 8) ~html:false ~messages:[String.make 4096 'a';String.make 904 'a'] () with
   | Error(Partial_delivery {sent_messages=[chat,99];cause=Api.Transport_failed}) -> check int64 "partial receipt conserved" (-1001234567890L) chat
   | _ -> fail "partial delivery falsely completed");
  check int "uncertain transport not retried" 2 (List.length !sends);
  List.iter(fun body -> check bool "topic conserved" true (Yojson.Safe.Util.member "message_thread_id" body=`Int 7);
    check bool "native reply coordinate conserved" true (Yojson.Safe.Util.member "reply_parameters" body=`Assoc["message_id",`Int 8])) !sends)
let test_direct_topic_and_chunk_bytes () =
  let u=parsed {|{"ok":true,"result":[{"update_id":1,"message":{"message_id":1,"chat":{"id":-1005},"direct_messages_topic":{"topic_id":9007199254740991},"from":{"id":123,"is_bot":false,"first_name":"A"},"text":"hello"}}]}|} in
  (match u.kind with Api.Message m -> check (option int64) "large direct topic" (Some 9007199254740991L) m.direct_messages_topic_id | _ -> fail "message");
  let text=String.concat "" (List.init 5000(fun _ -> "🙂")) in
  let chunks=match Channel_gate_telegram_state.chunks text with Ok v -> v | Error _ -> fail "valid UTF-8 refused" in
  check string "every authored byte preserved across chunks" text (String.concat "" chunks);
  check bool "invalid UTF-8 cannot silently mutate a reply" true (Result.is_error(Channel_gate_telegram_state.chunks "\255"))
let terminal outcome text=Keeper_chat_events.Reply_details{reply=text;turn_outcome=outcome;
  turn_ref=Ids.Turn_ref.make ~trace_id:"telegram-fixture" ~absolute_turn:1;terminal_stream_scope=None}
let test_adapter_requires_terminal_and_actual_send () = Eio_main.run(fun _ ->
  let bus=Keeper_chat_events.create () in
  Keeper_chat_events.publish bus (Keeper_chat_events.Text_delta{text="uncommitted";response=Unobserved_scope None});
  Keeper_chat_events.publish bus (terminal Keeper_turn_outcome.Visible_reply "canonical terminal");
  Keeper_chat_events.publish bus (Run_finished{run_id="r"});
  let sent=ref [] in
  let result=Keeper_chat_telegram.deliver ~events:bus ~load_blocks:(fun _ -> Ok None) ~send:(fun text -> sent:=text @ !sent;Error "send refused") in
  check (list string) "only canonical terminal sent" ["canonical terminal"] !sent;
  check bool "failed send stays failed" true (Result.is_error result);
  let bus=Keeper_chat_events.create () in Keeper_chat_events.publish bus (Run_finished{run_id="r"});
  check bool "missing terminal details not completed" true
    (Result.is_error(Keeper_chat_telegram.deliver ~events:bus ~load_blocks:(fun _ -> Ok None) ~send:(fun _ -> fail "uncommitted send"))))
let test_committed_blocks_and_html () = Eio_main.run(fun _ ->
  let bus=Keeper_chat_events.create () in
  Keeper_chat_events.publish bus (Keeper_chat_events.Image_block{url="https://abandoned.example/image";caption=None});
  Keeper_chat_events.publish bus (terminal Keeper_turn_outcome.Visible_reply "");
  Keeper_chat_events.publish bus (Run_finished{run_id="r"});
  let sent=ref [] in
  let blocks=[Keeper_chat_blocks.Image{src="https://example.com/image?a=1&b=2";cap=Some "<photo>"};
    Heading{html="A &amp; B"};Thinking{content="private reasoning";redacted=false}] in
  let result=Keeper_chat_telegram.deliver ~events:bus ~load_blocks:(fun _ -> Ok(Some blocks))
    ~send:(fun messages -> sent:=messages;Ok ()) in
  check bool "media-only committed reply delivered" true (Result.is_ok result);
  check (list string) "only committed public blocks rendered safely"
    ["Image: ";"<a href=\"https://example.com/image?a=1&amp;b=2\">&lt;photo&gt;</a>";"<b>A &amp; B</b>"] !sent;
  check bool "private-only content is not delivered" true
    (Result.is_error(Keeper_telegram_render.render ~reply:"" ~blocks:(Some [Thinking{content="secret";redacted=false}])));
  check bool "private media reference remains owed" true
    (Result.is_error(Keeper_telegram_render.render ~reply:"" ~blocks:(Some [Image{src="/api/keeper-media/private";cap=None}]))));
  let raw=String.make 5000 '<' in
  let messages=Keeper_telegram_render.render ~reply:"" ~blocks:(Some [Keeper_chat_blocks.Code{cap=None;html="";source=Some raw}]) |> ok in
  let restored=messages |> List.concat_map Markup_document.parse_html |> List.map Markup_document.text_content |> String.concat "" in
  check string "formatted long chunks preserve complete source" raw restored
let with_env settings f =
  let previous=List.map(fun (key,_) -> key,Sys.getenv_opt key) settings in
  Fun.protect ~finally:(fun () -> List.iter(fun (key,value) -> match value with
    | None -> Unix.unsetenv key | Some value -> Unix.putenv key value) previous)
    (fun () -> List.iter(fun (key,value)->Unix.putenv key value) settings;f ())
let test_binding_path_authority () =
  let path=Filename.temp_file "telegram-bindings" ".json" in
  let audit=path^".audit" in
  Fun.protect ~finally:(fun () -> List.iter(fun p -> if Sys.file_exists p then Sys.remove p) [path;audit])
    (fun () ->
      let out=open_out path in output_string out {|{"-1005":"keeper-custom"}|};close_out out;
      with_env ["TELEGRAM_BINDING_STORE_PATH",path;"MASC_TELEGRAM_BINDING_STORE_PATH",path^".other";
        "TELEGRAM_BINDING_AUDIT_PATH",audit;"MASC_TELEGRAM_BINDING_AUDIT_PATH",audit^".other"] (fun () ->
        let resolved=Channel_gate_telegram_state.resolve_keeper_for_channel_result ~channel_id:"-1005" in
        check bool "existing custom binding remains visible" true (resolved=Ok(Some "keeper-custom"));
        let native = Route.telegram ~bot_user_id:777L ~chat_id:(-1005L)
          ~message_thread_id:None ~direct_messages_topic_id:None ~reply_to_message_id:None
          ~user_id:123L |> ok |> Keeper_native_origin_reply.of_continuation |> ok in
        check bool "current owner may reply" true
          (Result.is_ok (Keeper_native_origin_reply.check_binding ~keeper_name:"keeper-custom" native));
        check bool "foreign Keeper cannot borrow origin" true
          (Result.is_error (Keeper_native_origin_reply.check_binding ~keeper_name:"foreign" native));
        check bool "mutation uses same authority" true
          (Result.is_ok(Channel_gate_telegram_state.bind ~channel_id:"-1006" ~keeper_name:"second" ~actor_name:"fixture"));
        check bool "audit override used" true (Sys.file_exists audit);
        check bool "write is read back from same store" true
          (Channel_gate_telegram_state.resolve_keeper_for_channel_result ~channel_id:"-1006"=Ok(Some "second"));
        Unix.putenv "TELEGRAM_BINDING_STORE_PATH" "";
        Unix.putenv "MASC_TELEGRAM_BINDING_STORE_PATH" path;
        check string "existing alias used when primary blank" path (Env_config_telegram.binding_store_path ())))
let test_prepared_claim_conflicts_and_uncertain_write () = with_claim_root (fun claim_root ->
  let module Claim = Keeper_telegram_ingress_claim in
  let delivered=ref [] in
  let recipient=ref (Some "A") in
  let dispatch_for_delivery _ ~channel ~channel_user_id ~channel_user_name:_ ~channel_workspace_id:_
      ~keeper_name ~idempotency_key ~metadata:_ ~content:_ =
    delivered:=keeper_name::!delivered;
    Gate_protocol.Reply {content="queued";structured=None;stats=None;message_request=Some {
      request_id=idempotency_key;destination_type="keeper";destination_id=keeper_name;channel;
      actor_id=Some channel_user_id;status=Queued;modalities=["text"];transport=Some channel;metadata=[]}} in
  let accept update=Gateway.accept_update ~claim_root ~resolve:(fun ~channel_id:_ -> Ok !recipient)
    ~dispatch_for_delivery ~bot_user_id:777L ~operation_id:"telegram-bot-777-generation-0-update-90" update in
  let update=parsed inbound in
  ignore(accept update |> ok);
  recipient:=Some "B";
  check bool "changed Keeper refuses original update" true (Result.is_error(accept update));
  recipient:=None;
  check bool "claimed update cannot become an unbound ignore" true (Result.is_error(accept update));
  recipient:=Some "A";
  let changed=match update.kind with
    | Api.Message message -> {update with kind=Api.Message {message with text=Some "changed"}}
    | Edited_message _ | Unsupported -> fail "message" in
  check bool "same identity cannot change model input" true (Result.is_error(accept changed));
  check (list string) "only original recipient dispatched" ["A"] !delivered;
  ignore(accept update |> ok);
  check (list string) "exact retry returns to original Keeper" ["A";"A"] !delivered;
  let identity=`Assoc["recipient",`String "A";"content",`String "original"] in
  let writes=ref 0 and written_path=ref None in
  let write path body=incr writes;written_path:=Some path;
    match Fs_compat.save_file_atomic_strict path body with
    | Error _ as error -> error | Ok () -> Error "injected uncertain parent sync" in
  let ensure ~sync identity=Claim.For_testing.ensure_with_io ~write ~sync ~root:claim_root
    ~operation_id:"telegram-bot-777-generation-0-update-91" ~identity in
  check bool "visible uncertain claim cannot authorize dispatch" true
    (Result.is_error(ensure ~sync:Fs_compat.sync_file_and_parent_strict identity));
  check bool "unproven resync still refuses" true
    (Result.is_error(ensure ~sync:(fun _->Error "injected sync refusal") identity));
  check bool "different request cannot replace uncertain claim" true
    (Result.is_error(ensure ~sync:Fs_compat.sync_file_and_parent_strict (`Assoc["recipient",`String "B"])));
  check bool "same exact claim is usable after actual resync" true
    (Result.is_ok(ensure ~sync:Fs_compat.sync_file_and_parent_strict identity));
  check int "existing claim is never overwritten" 1 !writes;
  Fs_compat.save_file_atomic_strict (Option.get !written_path)
    {|{"schema_version":1,"schema_version":1,"operation_id":"changed","identity":{}}|} |> ok;
  check bool "corrupt claim cannot be replaced by current recipient" true
    (match ensure ~sync:Fs_compat.sync_file_and_parent_strict identity with
     | Error Claim.Invalid_claim->true
     | Error (Claim.Conflicting_claim | Claim.Storage_failed _) | Ok ()->false);
  let unicode_identity=`Assoc["recipient",`String "A";"content",`String "�"] in
  let unicode_path=ref None in
  Claim.For_testing.ensure_with_io ~root:claim_root ~operation_id:"telegram-bot-777-generation-0-update-92"
    ~identity:unicode_identity ~sync:Fs_compat.sync_file_and_parent_strict
    ~write:(fun path body->unicode_path:=Some path;Fs_compat.save_file_atomic_strict path body)
    |> (function Ok ()->() | Error _->fail "valid Unicode claim");
  let malformed=Printf.sprintf
    {|{"schema_version":1,"operation_id":"telegram-bot-777-generation-0-update-92","identity":{"recipient":"A","content":"%s"}}|} "\255" in
  Fs_compat.save_file_atomic_strict (Option.get !unicode_path) malformed |> ok;
  check bool "invalid durable UTF-8 cannot normalize into an admitted identity" true
    (match Claim.ensure ~root:claim_root ~operation_id:"telegram-bot-777-generation-0-update-92"
      ~identity:unicode_identity with Error Claim.Invalid_claim->true
     | Error (Claim.Conflicting_claim | Claim.Storage_failed _) | Ok ()->false);
  let output=open_out(Filename.concat claim_root "not-a-directory") in close_out output;
  let blocked=Gateway.accept_update ~claim_root:(Filename.concat claim_root "not-a-directory")
    ~resolve:(fun ~channel_id:_ -> Ok(Some "B")) ~dispatch_for_delivery ~bot_user_id:777L ~operation_id:"blocked" update in
  check bool "claim storage failure prevents Gate" true (Result.is_error blocked);
  check (list string) "failed persistence did not dispatch another Keeper" ["A";"A"] !delivered)

let test_autonomous_wake_native_reply () = with_token (fun clock ->
  let module Native = Keeper_native_origin_reply in
  let module Queue = Keeper_event_queue in
  let route = Route.telegram ~bot_user_id:777L ~chat_id:(-1001234567890L)
    ~message_thread_id:(Some 7) ~direct_messages_topic_id:None
    ~reply_to_message_id:(Some 8) ~user_id:123L |> ok in
  let wake : Queue.stimulus = {post_id="keeper-ask:answer";urgency=Queue.Normal;
    arrived_at=1.;payload=Queue.Ask_answered {ask_id="answer";channel=route}} in
  (* Actual queue wire round trip and production wake projection; no fabricated
     result receipt substitutes for a transport callback. *)
  let restored = Queue.stimulus_to_yojson wake |> Yojson.Safe.to_string
    |> Yojson.Safe.from_string |> Queue.stimulus_of_yojson |> ok in
  let channel = Keeper_unified_turn.continuation_channel_of_wake
    (Keeper_registry.Woken [restored.payload]) |> Option.get in
  let native = Native.of_continuation channel |> ok in
  let target = Keeper_surface_post.resolve_target ~surface:"telegram" ~channel_id:None
    ~continuation_channel:channel ~native_reply:native () |> ok in
  check bool "wake reply addresses original route" true
    (Keeper_surface_post.matches_continuation_route target channel);
  check bool "cannot retarget the native continuation" true
    (Result.is_error (Keeper_surface_post.resolve_target ~surface:"telegram"
      ~channel_id:(Some "-2000") ~continuation_channel:channel ~native_reply:native ()));
  let input = `Assoc ["connector",`String "telegram";"channel_id",`String (Native.channel_id native);
    "native_route",Native.to_yojson native;"content",`String "answer";"mention_user_ids",`List []] in
  let replay = Keeper_tool_in_process_runtime.connector_post_replay_of_gate_input
    (Yojson.Safe.from_string (Yojson.Safe.to_string input)) |> ok in
  let replay_target = Keeper_tool_in_process_runtime.connector_post_replay_target replay in
  check bool "Gate replay retains native route" true
    (Keeper_surface_post.matches_continuation_route replay_target channel);
  let receipt = Keeper_surface_post.delivery_target_of_post_target replay_target in
  let receipt_json = Keeper_surface_post.delivery_target_to_yojson receipt in
  check bool "completed effect metadata survives its wire" true
    (Keeper_surface_post.delivery_target_of_yojson
       (Yojson.Safe.from_string (Yojson.Safe.to_string receipt_json)) = Ok receipt);
  let sends = ref [] in
  let post ~url ~body = match Filename.basename (Uri.path (Uri.of_string url)) with
    | "getMe" -> Ok (200,{|{"ok":true,"result":{"id":777,"is_bot":true,"first_name":"Bot"}}|})
    | "sendMessage" -> sends := Yojson.Safe.from_string body :: !sends;
      Ok (200,{|{"ok":true,"result":{"message_id":99,"chat":{"id":-1001234567890},"message_thread_id":7}}|})
    | _ -> fail "unexpected method" in
  Native.send ~telegram_post:post ~clock native ~content:"answer" |> ok;
  check int "one actual injected send" 1 (List.length !sends);
  let body = List.hd !sends in
  check bool "wake forum coordinates retained" true
    (Yojson.Safe.Util.member "message_thread_id" body = `Int 7
      && Yojson.Safe.Util.member "reply_parameters" body = `Assoc ["message_id",`Int 8]);
  let imessage = Route.imessage ~chat_identifier:"source" ~chat_guid:(Some "source-guid") ~user_id:"person" |> ok in
  let native = Native.of_continuation ~imessage_destination:"self-guid" imessage |> ok in
  let sent = ref None in
  Native.send ~clock ~imessage_send:(fun ~chat_guid ~content -> sent:=Some(chat_guid,content);Ok ())
    native ~content:"answer" |> ok;
  check (option (pair string string)) "configured iMessage destination used" (Some ("self-guid","answer")) !sent;
  check bool "self-chat receipt cannot claim original group was answered" false
    (Native.matches_continuation native imessage);
  let native_input = `Assoc ["connector",`String "imessage";"channel_id",`String "source";
    "native_route",Native.to_yojson native;"content",`String "answer";"mention_user_ids",`List []] in
  let replay = Keeper_tool_in_process_runtime.connector_post_replay_of_gate_input native_input |> ok in
  check (option string) "approval names the actual configured destination" (Some "imessage self-guid: answer")
    (Keeper_tool_in_process_runtime.connector_post_call_summary replay);
  let json = Keeper_surface_post.delivery_target_to_yojson
    (Keeper_surface_post.Delivered_to_native native) in
  check bool "duplicate receipt field is refused" true
    (match json with `Assoc fields -> Result.is_error (Keeper_surface_post.delivery_target_of_yojson
       (`Assoc (("channel_id",`String "source")::fields))) | _ -> fail "receipt object");
  check bool "unknown native route cannot be replayed" true
    (Result.is_error (Native.of_yojson (`Assoc ["kind",`String "dashboard";"thread_id",`String "foreign"]))))

let ()=run "Telegram native gateway" ["continuity",[
  test_case "prepared claims survive retry and uncertain write" `Quick test_prepared_claim_conflicts_and_uncertain_write;
  test_case "autonomous persisted wake and native effect route" `Quick test_autonomous_wake_native_reply;
  test_case "strict route and topic separation" `Quick test_route_roundtrip_and_topics;
  test_case "producer exact source and original receipt" `Quick test_producer_exact_route_and_receipt;
  test_case "unreadable binding stays owed" `Quick test_unreadable_binding_is_not_ignored;
  test_case "sender identity topics and partial receipt" `Quick test_sender_identity_topics_partial_failure;
  test_case "direct topic and UTF-8 preservation" `Quick test_direct_topic_and_chunk_bytes;
  test_case "terminal and delivery evidence" `Quick test_adapter_requires_terminal_and_actual_send;
  test_case "committed rich blocks and HTML boundaries" `Quick test_committed_blocks_and_html;
  test_case "configured binding read write and audit authority" `Quick test_binding_path_authority]]
