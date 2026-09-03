(* Slack gateway external-attention round trips.

   Pins the durable producer the Slack gateway's triggered and ambient lanes
   share ({!Server_slack_in_process_gateway.For_testing.record_external_attention})
   and the reply-time resolution ({!mark_attention_resolved}): a recorded
   Slack event is pending with its typed surface/urgency, a duplicate wire
   delivery dedups to the same event identity, and a sent reply retires the
   event from the pending projection. *)

open Alcotest
module G = Server_slack_in_process_gateway
module A = Masc.Keeper_external_attention

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let temp_base_path prefix =
  Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let with_temp_base name f =
  let base_path = temp_base_path name in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_path with _ -> ())
    (fun () -> f base_path)

let pending ~base_path ~keeper_name =
  A.load_events ~base_path ~keeper_name
  |> List.filter_map (function A.Recorded item -> Some item)

let record ~base_path ?(team_id = Some "T1") ?(thread_ts = None)
    ?(user_name = Some "user-one") ?(channel_name = None) ~ts ~route ~urgency ()
  =
  G.For_testing.record_external_attention ~base_dir:base_path
    ~keeper_name:"alpha" ~team_id ~channel_id:"C1" ~channel_name ~thread_ts ~ts
    ~user_id:"U1" ~user_name ~content:"hello keeper"
    ~mentions_bot:(urgency = A.Mention) ~route ~urgency

let test_triggered_record_is_pending_with_slack_surface () =
  with_temp_base "slack-attention-triggered" @@ fun base_path ->
  match record ~base_path ~ts:"1700000000.000100" ~route:"triggered"
          ~urgency:A.Mention () with
  | None -> fail "record returned None"
  | Some event_id -> (
    match pending ~base_path ~keeper_name:"alpha" with
    | [ item ] ->
      check string "event id" event_id item.A.event_id;
      check string "urgency" "mention" (A.urgency_to_string item.A.urgency);
      check string "conversation" "slack:channel:C1"
        item.A.conversation.A.conversation_id;
      (match item.A.conversation.A.surface with
       | A.Slack { team_id; channel_id; thread_ts } ->
         check (option string) "team" (Some "T1") team_id;
         check string "channel" "C1" channel_id;
         check (option string) "thread" None thread_ts
       | _ -> fail "expected Slack surface")
    | items ->
      failf "expected exactly one pending item, got %d" (List.length items))

(* Slack sometimes sends a message with no [user_name]. The gateway used to
   put [user_id] in its place and wrap that back into [Some], so the stored row
   said the person is called [U09L0RHPW7P] and the chat pane drew an id where a
   name goes. One person's 24 messages arrived named half the time.

   [display_name] is [string option]: absence already has a place to live. *)
let test_a_missing_author_name_stays_missing () =
  with_temp_base "slack-attention-unnamed" @@ fun base_path ->
  match
    record ~base_path ~user_name:None ~ts:"1700000000.000700"
      ~route:"triggered" ~urgency:A.Mention ()
  with
  | None -> fail "record returned None"
  | Some _ -> (
    match pending ~base_path ~keeper_name:"alpha" with
    | [] -> fail "no pending item"
    | item :: _ ->
      check (option string) "the id is not offered as a name" None
        item.A.actor.A.display_name;
      (* The id is still carried: an author nobody named is still a particular
         author, and two of them in a channel are two people. *)
      check (option string) "and the author is still identified" (Some "U1")
        item.A.actor.A.actor_id)

let test_ambient_record_uses_ambient_urgency () =
  with_temp_base "slack-attention-ambient" @@ fun base_path ->
  match record ~base_path ~ts:"1700000000.000200" ~route:"ambient"
          ~urgency:A.Ambient () with
  | None -> fail "record returned None"
  | Some _ -> (
    match pending ~base_path ~keeper_name:"alpha" with
    | [ item ] ->
      check string "urgency" "ambient" (A.urgency_to_string item.A.urgency)
    | items ->
      failf "expected exactly one pending item, got %d" (List.length items))

let test_duplicate_wire_delivery_keeps_one_pending () =
  with_temp_base "slack-attention-dedupe" @@ fun base_path ->
  let first =
    record ~base_path ~ts:"1700000000.000300" ~route:"triggered"
      ~urgency:A.Mention ()
  in
  let second =
    record ~base_path ~ts:"1700000000.000300" ~route:"triggered"
      ~urgency:A.Mention ()
  in
  check (option string) "same event id" first second;
  check int "one pending" 1 (List.length (pending ~base_path ~keeper_name:"alpha"))

(* Inbound identity rendering (issue #28376): the lane-shared mapping
   resolves the author label and rewrites mention escapes, and never touches
   [user_id] or [ts] (identity keys). *)
let test_resolve_event_identity_maps_names_and_mentions () =
  let directory =
    Slack_user_directory.create
      ~fetch:(fun ~user_id ->
        if String.equal user_id "U09L0RHPW7P" then
          Ok
            { Slack_rest_client.user_id
            ; name = Some "vincent"
            ; real_name = None
            ; display_name = Some "Vincent"
            }
        else Error (Slack_rest_client.Slack_api { error = "user_not_found" }))
      ~now:(fun () -> 0.0)
      ()
  in
  let event =
    Slack_gateway_state.Message_create
      { channel_id = "C1"
      ; thread_ts = None
      ; user_id = "U09L0RHPW7P"
      ; user_name = None
      ; text = "<@U09L0RHPW7P> 확인"
      ; ts = "1786524720.554309"
      ; mentions_bot = true
      ; bot_id = None
      ; files = []
      }
  in
  (match G.For_testing.resolve_event_identity ~user_directory:directory event with
   | Slack_gateway_state.Message_create { user_id; user_name; text; ts; _ } ->
     check string "identity key untouched" "U09L0RHPW7P" user_id;
     check string "dedup key untouched" "1786524720.554309" ts;
     check (option string) "author label resolved" (Some "Vincent") user_name;
     check string "mention rewritten" "@Vincent 확인" text
   | _ -> fail "message event mapped to another variant");
  match G.For_testing.resolve_event_identity event with
  | Slack_gateway_state.Message_create { user_name; text; _ } ->
    check (option string) "no directory keeps the raw absence" None user_name;
    check string "no directory keeps the wire text" "<@U09L0RHPW7P> 확인" text
  | _ -> fail "message event mapped to another variant"

let () =
  run "Server_slack_gateway_attention"
    [ "attention"
      , [ test_case "triggered record pending with slack surface" `Quick
            test_triggered_record_is_pending_with_slack_surface
        ; test_case "ambient record uses ambient urgency" `Quick
            test_ambient_record_uses_ambient_urgency
        ; test_case "a missing author name stays missing" `Quick
            test_a_missing_author_name_stays_missing
        ; test_case "duplicate wire delivery keeps one pending" `Quick
            test_duplicate_wire_delivery_keeps_one_pending
        ; test_case "inbound identity mapping" `Quick
            test_resolve_event_identity_maps_names_and_mentions
        ]
    ]
