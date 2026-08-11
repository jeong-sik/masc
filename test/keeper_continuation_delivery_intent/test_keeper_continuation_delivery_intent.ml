open Keeper_continuation_delivery_intent

let expect_ok = function
  | Ok value -> value
  | Error error -> failwith (error_to_string error)
;;

let dashboard thread_id =
  Keeper_continuation_channel.dashboard ~thread_id |> Result.get_ok
;;

let discord channel_id =
  Keeper_continuation_channel.discord
    ~guild_id:(Some "guild-1")
    ~channel_id
    ~parent_channel_id:None
    ~thread_id:None
    ~user_id:"user-1"
  |> Result.get_ok
;;

let fusion_intent ?(channel = dashboard "thread-1") ?(response = "final answer") () =
  let origin = fusion_origin ~run_id:"run-1" channel |> expect_ok in
  create
    ~keeper_name:"keeper-one"
    ~keeper_turn_id:7
    ~origin
    ~response_text:response
  |> expect_ok
;;

let assert_roundtrip intent =
  match of_yojson (to_yojson intent) with
  | Error error -> failwith (error_to_string error)
  | Ok decoded ->
    assert (Yojson.Safe.equal (to_yojson intent) (to_yojson decoded))
;;

let test_roundtrip_all_states () =
  let pending = fusion_intent () in
  let attempting = start_attempt ~started_at:10.5 pending |> expect_ok in
  let delivered =
    mark_delivered
      ~completed_at:11.0
      ~connector_message_id:"connector-message-1"
      attempting
    |> expect_ok
  in
  let failed =
    mark_failed
      ~completed_at:11.0
      ~kind:Retry_exhausted
      ~detail:"connector stayed unavailable"
      pending
    |> expect_ok
  in
  let ambiguous =
    mark_ambiguous
      ~detected_at:11.0
      ~detail:"send returned before receipt persistence"
      attempting
    |> expect_ok
  in
  List.iter assert_roundtrip [ pending; attempting; delivered; failed; ambiguous ];
  match attempting.state with
  | Attempting { idempotency_key; _ } ->
    assert (String.equal idempotency_key (Intent_id.to_string attempting.intent_id))
  | Pending | Delivered _ | Failed _ | Ambiguous _ ->
    failwith "start_attempt did not produce Attempting"
;;

let test_identity_and_collision_contract () =
  let original = fusion_intent () in
  let replay = fusion_intent () in
  let changed_response = fusion_intent ~response:"different answer" () in
  let changed_route = fusion_intent ~channel:(dashboard "thread-2") () in
  assert (classify_replay ~existing:original ~incoming:replay = Exact_replay);
  assert
    (classify_replay ~existing:original ~incoming:changed_response
     = Identity_conflict);
  assert
    (classify_replay ~existing:original ~incoming:changed_route
     = Identity_conflict);
  assert (Intent_id.equal original.intent_id changed_response.intent_id);
  assert (Intent_id.equal original.intent_id changed_route.intent_id);
  let hitl =
    hitl_origin ~approval_id:"run-1" (dashboard "thread-1")
    |> expect_ok
    |> fun origin ->
    create
      ~keeper_name:"keeper-one"
      ~keeper_turn_id:7
      ~origin
      ~response_text:"final answer"
    |> expect_ok
  in
  let connector =
    connector_attention_origin ~event_id:"run-1" (dashboard "thread-1")
    |> expect_ok
    |> fun origin ->
    create
      ~keeper_name:"keeper-one"
      ~keeper_turn_id:7
      ~origin
      ~response_text:"final answer"
    |> expect_ok
  in
  assert (classify_replay ~existing:original ~incoming:hitl = Distinct_identity);
  assert (classify_replay ~existing:original ~incoming:connector = Distinct_identity);
  assert (classify_replay ~existing:hitl ~incoming:connector = Distinct_identity)
;;

let test_unrouted_fails_closed () =
  let unrouted = Keeper_continuation_channel.unrouted "source had no reply route" in
  assert (Result.is_error (fusion_origin ~run_id:"run-1" unrouted));
  let payload : Keeper_event_queue.stimulus_payload =
    Fusion_completed
      { run_id = "run-1"
      ; terminal = Fusion_succeeded "answer"
      ; board_post_id = "post-1"
      ; channel = unrouted
      }
  in
  assert (origin_of_payload payload = None);
  let routable_payload : Keeper_event_queue.stimulus_payload =
    Connector_attention
      { event_id = "event-1"; channel = discord "channel-1" }
  in
  assert (Option.is_some (origin_of_payload routable_payload))
;;

let replace_field name replacement = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (field_name, value) ->
            if String.equal field_name name
            then field_name, replacement
            else field_name, value)
         fields)
  | json -> json
;;

let test_strict_codec_rejects_drift () =
  let json = to_yojson (fusion_intent ()) in
  let unknown =
    match json with
    | `Assoc fields -> `Assoc (("future_field", `Bool true) :: fields)
    | other -> other
  in
  assert (Result.is_error (of_yojson unknown));
  let different_valid_id = "kdelivery-" ^ String.make 64 '0' in
  assert
    (Result.is_error
       (of_yojson (replace_field "intent_id" (`String different_valid_id) json)));
  let bad_response =
    match json with
    | `Assoc fields ->
      let fields =
        List.map
          (fun (name, value) ->
             if String.equal name "response"
             then
               ( name
               , replace_field "sha256" (`String (String.make 64 '0')) value )
             else name, value)
          fields
      in
      `Assoc fields
    | other -> other
  in
  assert (Result.is_error (of_yojson bad_response))
;;

let test_transition_guards () =
  let pending = fusion_intent () in
  assert (Result.is_error (mark_delivered ~completed_at:1.0 pending));
  assert
    (Result.is_error
       (mark_ambiguous ~detected_at:1.0 ~detail:"unknown" pending));
  assert (Result.is_error (start_attempt ~started_at:Float.nan pending));
  let attempting = start_attempt ~started_at:1.0 pending |> expect_ok in
  let delivered = mark_delivered ~completed_at:2.0 attempting |> expect_ok in
  assert
    (Result.is_error
       (mark_failed
          ~completed_at:3.0
          ~kind:Adapter_rejected
          ~detail:"late failure"
          delivered))
;;

let () =
  test_roundtrip_all_states ();
  test_identity_and_collision_contract ();
  test_unrouted_fails_closed ();
  test_strict_codec_rejects_drift ();
  test_transition_guards ();
  print_endline "keeper_continuation_delivery_intent: ok"
