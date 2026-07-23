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
  A.pending_for_keeper ~base_path ~keeper_name ~limit:10 ()

let record ~base_path ?(team_id = Some "T1") ?(thread_ts = None) ~ts ~route
    ~urgency () =
  G.For_testing.record_external_attention ~base_dir:base_path
    ~keeper_name:"sangsu" ~team_id ~channel_id:"C1" ~thread_ts ~ts
    ~user_id:"U1" ~user_name:(Some "user-one") ~content:"hello keeper"
    ~mentions_bot:(urgency = A.Mention) ~route ~urgency

let test_triggered_record_is_pending_with_slack_surface () =
  with_temp_base "slack-attention-triggered" @@ fun base_path ->
  match record ~base_path ~ts:"1700000000.000100" ~route:"triggered"
          ~urgency:A.Mention () with
  | None -> fail "record returned None"
  | Some event_id -> (
    match pending ~base_path ~keeper_name:"sangsu" with
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

let test_ambient_record_uses_ambient_urgency () =
  with_temp_base "slack-attention-ambient" @@ fun base_path ->
  match record ~base_path ~ts:"1700000000.000200" ~route:"ambient"
          ~urgency:A.Ambient () with
  | None -> fail "record returned None"
  | Some _ -> (
    match pending ~base_path ~keeper_name:"sangsu" with
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
  check int "one pending" 1 (List.length (pending ~base_path ~keeper_name:"sangsu"))

let test_sent_reply_retires_attention () =
  with_temp_base "slack-attention-resolve" @@ fun base_path ->
  match record ~base_path ~ts:"1700000000.000400" ~route:"triggered"
          ~urgency:A.Mention () with
  | None -> fail "record returned None"
  | Some event_id ->
    check int "pending before reply" 1
      (List.length (pending ~base_path ~keeper_name:"sangsu"));
    G.For_testing.mark_attention_resolved ~base_dir:base_path
      ~keeper_name:"sangsu" ~event_id ~reason:"slack_reply_sent";
    check int "pending after reply" 0
      (List.length (pending ~base_path ~keeper_name:"sangsu"))

let () =
  run "Server_slack_gateway_attention"
    [ "attention"
      , [ test_case "triggered record pending with slack surface" `Quick
            test_triggered_record_is_pending_with_slack_surface
        ; test_case "ambient record uses ambient urgency" `Quick
            test_ambient_record_uses_ambient_urgency
        ; test_case "duplicate wire delivery keeps one pending" `Quick
            test_duplicate_wire_delivery_keeps_one_pending
        ; test_case "sent reply retires attention" `Quick
            test_sent_reply_retires_attention
        ]
    ]
