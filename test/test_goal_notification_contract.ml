open Alcotest
open Masc
module Chat = Masc.Keeper_chat_store
module Projection = Server_bootstrap_loops.For_testing

let rec remove_tree path =
  if Sys.is_directory path then (
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path)
  else Sys.remove path

(* The server enables the guard before any delivery runs. With the guard off,
   [Eio_guard.with_mutex] runs its body without a lock, so a store call made
   from a system thread passes here and raises [Non_eio_mutex_context] there. *)
let with_workspace run = Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  let base_dir = Filename.temp_file "goal-notification-contract-" "" in
  Sys.remove base_dir; Unix.mkdir base_dir 0o700;
  Fun.protect ~finally:(fun () -> Eio_guard.disable (); remove_tree base_dir) (fun () ->
    let config = Workspace_utils.default_config_uncached base_dir in
    Fs_compat.mkdir_p (Workspace_utils.masc_dir config);
    run config)

let accepted = function Ok value -> value | Error detail -> fail detail
let delivery content : Workspace_broadcast.broadcast_delivery =
  { request_id = "wmsg-0123456789abcdef0123456789abcdef"; seq=1
  ; rendered=content; from_agent="verifier"; content; mention=None
  ; msg_type="broadcast"; mention_delivery=Passive
  ; fanout_state=Fanout_durable_admitted; audience=Fleet_conversation }

let rows config = Chat.load_all_result ~base_dir:config.Workspace_utils.base_path
  ~keeper_name:"beta" |> accepted
let project config sender_authority message =
  Projection.append_workspace_message_to_recipient ~base_path:config.Workspace_utils.base_path
    ~sender_authority message ~keeper_name:"beta" |> accepted

let test_passive sender_authority () = with_workspace @@ fun config ->
  let content = "Goal title: @beta\nEvidence quotes @beta without requesting work." in
  let message = delivery content in
  project config sender_authority message;
  project config sender_authority message;
  let messages = rows config in
  check int "one transcript row across retry" 1 (List.length messages);
  let row = List.hd messages in
  check string "literal evidence is preserved" content row.Chat.content;
  check int "passive projection cannot create mention metadata" 0 (List.length row.mentions);
  check bool "broadcast context keeps its typed surface" true (row.surface=Some Surface_ref.Broadcast);
  let raw = Fs_compat.load_file (Chat.chat_path ~base_dir:config.base_path ~keeper_name:"beta") in
  let json = Yojson.Safe.from_string (String.trim raw) in
  check bool "empty mentions are explicitly durable" true
    (Yojson.Safe.Util.member "mentions" json = `List [])

let test_active_mention_survives_projection () = with_workspace @@ fun config ->
  let message = delivery "@beta please review this Goal" in
  let request = Keeper_chat_delivery_identity.Request_id.of_string message.request_id |> accepted in
  let speaker : Chat.speaker =
    {speaker_id=Some "verifier";speaker_name=Some "verifier";speaker_authority=External} in
  ignore (Chat.append_user_message_once ~base_dir:config.base_path ~keeper_name:"beta"
    ~delivery_key:(Keeper_chat_delivery_identity.Workspace_message request)
    ~content:message.content ~surface:Surface_ref.Broadcast ~speaker () |> accepted);
  let before = rows config in
  check bool "ordinary inbound mentions are still parsed" true
    ((List.hd before).Chat.mentions <> []);
  project config Lane_addon_broadcast_delivery.External_sender message;
  check bool "existing mention authority survives the passive fleet pass" true (rows config=before)

let create_goal config =
  match Goal_store.upsert_goal config ~title:"Notification identity"
    ~metric:"durable notifications" ~target_value:"1" () with
  | Ok (goal, _) -> goal
  | Error error -> fail (Goal_store.write_error_to_string error)

let test_notification_id request_id should_accept () = with_workspace @@ fun config ->
  let goal = create_goal config in
  let state = match Goal_store.load_source config with
    | Goal_store.Available state -> state | _ -> fail "fixture store is unavailable" in
  let notice : Goal_store.pending_notification =
    {notification_id=request_id;goal_id=goal.id;sender="verifier";content="proof recorded";
     delivery=Awaiting_recipients} in
  Goal_store.write_state config {state with pending_notifications=[notice]};
  let path = Goal_store.goals_path config in
  let before = Fs_compat.load_file path in
  match Goal_store.load_source config with
  | Goal_store.Available _ -> check bool "only canonical identities are authoritative" true should_accept
  | Goal_store.Uninitialized -> fail "initialized Goal store disappeared"
  | Goal_store.Unavailable failure ->
      check bool "malformed identity refuses the source" false should_accept;
      (match failure.reason with
       | Goal_store.Schema_rejected {field="pending_notifications";_} -> ()
       | _ -> fail (Goal_store.unavailable_to_string failure));
      (match Goal_store.upsert_goal config ~id:goal.id ~title:"must not commit" () with
       | Error (Goal_store.Store_unavailable _) -> ()
       | _ -> fail "a corrupt notification outbox authorized a Goal mutation");
      check string "failed mutation preserves the primary" before (Fs_compat.load_file path)

let () = run "Goal notification contract"
  ["transcript", [
    test_case "external notification is passive" `Quick
      (test_passive Lane_addon_broadcast_delivery.External_sender);
    test_case "Keeper fleet context is passive" `Quick
      (test_passive Lane_addon_broadcast_delivery.Keeper_sender);
    test_case "active mention survives passive projection" `Quick test_active_mention_survives_projection];
   "identity", List.map (fun (name,id,valid) -> test_case name `Quick (test_notification_id id valid))
      ["canonical", "wmsg-0123456789abcdef0123456789abcdef", true;
       "untyped", "notification", false;
       "short", "wmsg-0123", false;
       "uppercase", "wmsg-0123456789ABCDEF0123456789ABCDEF", false;
       "nonhex", ("wmsg-" ^ String.make 31 '0' ^ "g"), false;
       "path", ("wmsg-" ^ String.make 31 '0' ^ "/"), false]]
