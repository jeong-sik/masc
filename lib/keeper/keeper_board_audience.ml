module Board_signal = Keeper_world_observation_board_signal
module Message_scope = Keeper_world_observation_message_scope

type t =
  | Targets of Keeper_identity.Keeper_id.t list
  | Broadcast
  | Thread_participants
  | Discoverable

type classification_error =
  | Invalid_board_audience of Board.board_error
  | Invalid_board_target of string

type route =
  | Deliver of Board_signal.wake_reason
  | Judge_discoverable
  | Ignore

let keeper_targets_of_board targets =
  List.fold_left
    (fun result target ->
      match result with
      | Error _ as error -> error
      | Ok targets ->
        let raw = Board.Agent_id.to_string target in
        (match Keeper_identity.Keeper_id.of_string raw with
         | Some target -> Ok (target :: targets)
         | None -> Error (Invalid_board_target raw)))
    (Ok [])
    targets
  |> Result.map (List.sort_uniq Keeper_identity.Keeper_id.compare)
;;

let of_board_audience = function
  | Board.Targets targets ->
    keeper_targets_of_board targets |> Result.map (fun targets -> Targets targets)
  | Board.Broadcast -> Ok Broadcast
  | Board.Thread_participants -> Ok Thread_participants
  | Board.Discoverable -> Ok Discoverable
;;

let classify ~visibility signal =
  let board_audience =
    match signal.Board_dispatch.kind with
    | Board_dispatch.Board_post_created ->
      Board.audience_for_post
        ~visibility
        ~title:signal.title
        ~content:signal.content
    | Board_dispatch.Board_comment_added ->
      Board.audience_for_comment ~content:signal.content
    | Board_dispatch.Board_reaction_changed _ ->
      Ok Board.audience_for_reaction
  in
  match board_audience with
  | Error error -> Error (Invalid_board_audience error)
  | Ok audience -> of_board_audience audience
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
  | Invalid_board_audience error -> Board.show_board_error error
  | Invalid_board_target target ->
    Printf.sprintf "Board audience target cannot identify a Keeper lane: %s" target
;;
