module Board_signal = Keeper_world_observation_board_signal
module Message_scope = Keeper_world_observation_message_scope

type t =
  | Targets of Keeper_identity.Keeper_id.t list
  | Broadcast
  | Thread_participants
  | Discoverable

type classification_error =
  | Invalid_board_target of string
  | Audience_not_recorded

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

let of_recorded = function
  | Some audience -> of_board_audience audience
  | None -> Error Audience_not_recorded
;;

let of_post (post : Board.post) = of_recorded post.audience
let of_comment (comment : Board.comment) = of_recorded comment.audience

let keeper_target_ids (meta : Keeper_meta_contract.keeper_meta) =
  Keeper_lane_mentions.effective_target_ids
    ~keeper_name:meta.name
    ~mention_targets:meta.mention_targets
;;

let reader_for_keeper (meta : Keeper_meta_contract.keeper_meta) =
  let target_ids = keeper_target_ids meta in
  Masc_board_handlers.Board_access.Named
    { name = meta.name
    ; addressed_by = (fun target ->
        match Keeper_identity.Keeper_id.of_string (Board.Agent_id.to_string target) with
        | Some target -> Keeper_lane_mentions.ids_match
            ~target_ids [target]
        | None -> false) }

let route_for_keeper ~audience ~(meta : Keeper_meta_contract.keeper_meta) ~signal =
  let self_ids = Message_scope.self_ids meta in
  if Message_scope.is_self_author ~self_ids signal.Board_dispatch.author
  then Board_signal.Available Ignore
  else
    match Board_dispatch.read_post_for_evidence_unchecked ~post_id:signal.post_id with
    | Error error ->
      Board_signal.Unavailable { operation = Board_signal.Get_post; post_id = signal.post_id; error }
    | Ok post ->
    if not (Masc_board_handlers.Board_access.can_read ~reader:(reader_for_keeper meta) post)
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
       | Board_signal.Available (Board_signal.Wake reason) ->
         Board_signal.Available (Deliver reason)
       | Board_signal.Available (Board_signal.Unaddressed_comment visibility) ->
         (* Public and internal threads can be discovered through comments
            (#27329). Unlisted and direct threads do not enter another lane's
            attention collector merely because someone replied. *)
         (match visibility with
          | Board.Public | Board.Internal when meta.board_interests <> [] ->
            Board_signal.Available Judge_discoverable
          | Board.Public | Board.Internal | Board.Unlisted | Board.Direct ->
            Board_signal.Available Ignore)
       | Board_signal.Available Board_signal.Not_addressed -> Board_signal.Available Ignore)
    | Discoverable ->
      if meta.board_interests = []
      then Board_signal.Available Ignore
      else Board_signal.Available Judge_discoverable
;;

let label = function
  | Targets _ -> "targets"
  | Broadcast -> "broadcast"
  | Thread_participants -> "thread_participants"
  | Discoverable -> "discoverable"
;;

let classification_error_to_string = function
  | Invalid_board_target target ->
    Printf.sprintf "Board audience target cannot identify a Keeper lane: %s" target
  | Audience_not_recorded -> "Board post or comment records no audience"
;;

let can_project_queued_stimulus ~meta (stimulus : Keeper_event_queue.stimulus) =
  let can_read ~attention =
    match Board_dispatch.read_post_for_evidence_unchecked ~post_id:stimulus.post_id with
    | Error _ -> false
    | Ok post ->
      Masc_board_handlers.Board_access.can_read ~reader:(reader_for_keeper meta) post
      && (match attention, post.visibility with
          | None, _ | Some _, (Board.Public | Board.Internal) -> true
          | Some _, Board.Direct -> false
          | Some Keeper_event_queue.Comment_added _, Board.Unlisted -> false
          | Some (Keeper_event_queue.Post_created | Post_updated _ | Reaction_changed _ | Vote_cast _),
              Board.Unlisted -> true)
  in
  match stimulus.payload with
  | Keeper_event_queue.Board_routing_pending _ -> false
  | Keeper_event_queue.Board_signal _ -> can_read ~attention:None
  | Keeper_event_queue.Board_attention attention -> can_read ~attention:(Some attention.signal.kind)
  | Keeper_event_queue.Bootstrap | Fusion_completed _ | Schedule_due _
  | Connector_attention _ | Hitl_resolved _ | Ask_answered _
  | Completion_authority_rejected _ | Task_outcome _ | Task_cancelled _
  | Workspace_message _ | Delegate_completed _ | Composition_completed _
  | Tool_result_ready _ | Owned_job_completed _ -> true
;;
