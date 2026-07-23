module Board_signal = Keeper_world_observation_board_signal
module Message_scope = Keeper_world_observation_message_scope

type t =
  | Targets of Keeper_identity.Keeper_id.t list
  | Broadcast
  | Thread_participants
  | Discoverable

type classification_error =
  | Unsupported_broadcast of string list
  | Direct_without_targets of string

type route =
  | Deliver of Board_signal.wake_reason
  | Judge_discoverable
  | Ignore

let classify ~visibility signal =
  match
    Keeper_lane_mentions.explicit_address_of_content
      (Board_signal.address_text signal)
  with
  | Keeper_lane_mentions.Broadcast_all -> Ok Broadcast
  | Keeper_lane_mentions.Targets targets -> Ok (Targets targets)
  | Keeper_lane_mentions.Unsupported_broadcast selectors ->
    Error (Unsupported_broadcast selectors)
  | Keeper_lane_mentions.No_explicit_address ->
    (match signal.Board_dispatch.kind, visibility with
     | Board_dispatch.Board_post_created, Board.Direct ->
       Error (Direct_without_targets signal.post_id)
     | Board_dispatch.Board_post_created,
       (Board.Public | Board.Unlisted | Board.Internal) -> Ok Discoverable
     | ( Board_dispatch.Board_comment_added
       | Board_dispatch.Board_reaction_changed _ ),
       (Board.Public | Board.Unlisted | Board.Internal | Board.Direct) ->
       Ok Thread_participants)
;;

let keeper_target_ids (meta : Keeper_meta_contract.keeper_meta) =
  let targets =
    if meta.mention_targets = [] then [ meta.name ] else meta.mention_targets
  in
  Keeper_lane_mentions.target_ids_of targets
;;

let route_for_keeper ~audience ~(meta : Keeper_meta_contract.keeper_meta) ~signal =
  let self_ids = Message_scope.self_ids meta in
  if Message_scope.is_self_author ~self_ids signal.Board_dispatch.author
  then Board_signal.Available Ignore
  else
    match audience with
    | Targets targets ->
      if Keeper_lane_mentions.ids_match ~target_ids:(keeper_target_ids meta) targets
      then Board_signal.Available (Deliver Board_signal.Explicit_mention)
      else Board_signal.Available Ignore
    | Broadcast -> Board_signal.Available (Deliver Board_signal.Broadcast)
    | Thread_participants ->
      (match Board_signal.wake_reason ~meta ~signal with
       | Board_signal.Unavailable _ as unavailable -> unavailable
       | Board_signal.Available (Some reason) -> Board_signal.Available (Deliver reason)
       | Board_signal.Available None -> Board_signal.Available Ignore)
    | Discoverable -> Board_signal.Available Judge_discoverable
;;

let label = function
  | Targets _ -> "targets"
  | Broadcast -> "broadcast"
  | Thread_participants -> "thread_participants"
  | Discoverable -> "discoverable"
;;

let classification_error_to_string = function
  | Unsupported_broadcast selectors ->
    Printf.sprintf
      "unsupported Keeper Board broadcast selector(s): %s"
      (String.concat ", " (List.map (Printf.sprintf "@@%s") selectors))
  | Direct_without_targets post_id ->
    Printf.sprintf "Direct Board post %s has no explicit Keeper targets" post_id
;;
