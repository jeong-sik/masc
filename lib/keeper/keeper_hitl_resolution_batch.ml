module Approval_ids = Set.Make (String)

type reply_partition =
  | No_reply_route
  | Exact_reply_route of Keeper_continuation_channel.t

type t =
  | Empty
  | Single of Keeper_event_queue.hitl_resolution
  | Cohort of
      { base_path : string
      ; keeper_name : string
      ; partition : reply_partition
      ; reversed : Keeper_event_queue.hitl_resolution list
      ; approval_ids : Approval_ids.t
      }

type singleton_reason =
  | Rejected_resolution
  | Model_issued_operation of string
  | Terminal_operation of string
  | Recovery_resolution
  | Different_keeper of string
  | Grant_unavailable of Keeper_approval_queue_result.grant_error

type join_error =
  | Duplicate_resolution of string
  | Different_reply_partitions
  | Different_scope
  | Invalid_workspace of Config_dir_resolver.canonical_base_path_error
  | Single_only of { approval_id : string; reason : singleton_reason }

let join_error_to_string = function
  | Duplicate_resolution id -> "duplicate HITL resolution: " ^ id
  | Different_reply_partitions -> "HITL resolutions have different reply partitions"
  | Different_scope -> "HITL cohort belongs to another workspace or Keeper"
  | Invalid_workspace error -> Config_dir_resolver.canonical_base_path_error_to_string error
  | Single_only { approval_id; reason } ->
    let detail = match reason with
      | Rejected_resolution -> "rejection continues individually"
      | Model_issued_operation operation -> "model-issued operation: " ^ operation
      | Terminal_operation operation -> "terminal operation: " ^ operation
      | Recovery_resolution -> "consumed or recorded resolution requires recovery"
      | Different_keeper name -> "approval belongs to Keeper " ^ name
      | Grant_unavailable error -> Keeper_approval_queue_result.grant_error_to_string error
    in
    "HITL resolution " ^ approval_id ^ " continues individually: " ^ detail

let empty = Empty
let singleton resolution = Single resolution

let resolutions = function
  | Empty -> []
  | Single resolution -> [ resolution ]
  | Cohort { reversed; _ } -> List.rev reversed

let singleton_resolution = function
  | Single resolution -> Some resolution
  | Empty | Cohort _ -> None

let canonical_workspace base_path =
  Config_dir_resolver.canonical_base_path base_path
  |> Result.map_error (fun error -> Invalid_workspace error)

let validate_scope ~base_path ~keeper_name = function
  | Empty | Single _ -> Ok ()
  | Cohort current ->
    Result.bind (canonical_workspace base_path) (fun base_path ->
      if String.equal current.base_path base_path && String.equal current.keeper_name keeper_name
      then Ok () else Error Different_scope)

let partition channel =
  if Keeper_continuation_channel.is_routable channel
  then Exact_reply_route channel
  else No_reply_route

let same_partition left right =
  match left, right with
  | No_reply_route, No_reply_route -> true
  | Exact_reply_route left, Exact_reply_route right ->
    Keeper_continuation_channel.same_route left right
  | No_reply_route, Exact_reply_route _ | Exact_reply_route _, No_reply_route -> false

let eligible_partition ~base_path ~keeper_name
    (resolution : Keeper_event_queue.hitl_resolution) =
  let single reason = Error (Single_only { approval_id = resolution.approval_id; reason }) in
  match resolution.decision with
  | Keeper_event_queue.Hitl_rejected _ -> single Rejected_resolution
  | Keeper_event_queue.Hitl_approved ->
    match Keeper_approval_queue.approved_resolution_delivery
      ~base_path ~id:resolution.approval_id with
    | Error error -> single (Grant_unavailable error)
    | Ok delivery ->
      if not (String.equal delivery.request.keeper_name keeper_name)
      then single (Different_keeper delivery.request.keeper_name)
      else
        match delivery.state, delivery.replay_outcome with
        | Keeper_approval_queue_result.Resolution_consumed, _
        | Resolution_unconsumed, Some _ -> single Recovery_resolution
        | Resolution_unconsumed, None ->
          match Keeper_gate.replayable_operation delivery.request.tool_name with
          | None -> single (Model_issued_operation delivery.request.tool_name)
          | Some Keeper_gate.Replay_connector_post ->
            single (Terminal_operation delivery.request.tool_name)
          | Some (Keeper_gate.Replay_write | Replay_execute | Replay_network_read
                 | Replay_identity | Replay_voice_speak) ->
            Ok (partition resolution.channel)

let try_append ~base_path ~keeper_name batch
    (resolution : Keeper_event_queue.hitl_resolution) =
  let ( let* ) = Result.bind in
  match batch with
  | Empty -> Ok (Single resolution)
  | Single first ->
    if String.equal first.approval_id resolution.approval_id
    then Error (Duplicate_resolution resolution.approval_id)
    else
      let* base_path = canonical_workspace base_path in
      let* first_partition = eligible_partition ~base_path ~keeper_name first in
      let* next_partition = eligible_partition ~base_path ~keeper_name resolution in
      if not (same_partition first_partition next_partition)
      then Error Different_reply_partitions
      else Ok (Cohort
        { base_path; keeper_name; partition = first_partition
        ; reversed = [ resolution; first ]
        ; approval_ids = Approval_ids.of_list [ first.approval_id; resolution.approval_id ]
        })
  | Cohort current ->
    let* base_path = canonical_workspace base_path in
    if not (String.equal current.base_path base_path
            && String.equal current.keeper_name keeper_name)
    then Error Different_scope
    else if Approval_ids.mem resolution.approval_id current.approval_ids
    then Error (Duplicate_resolution resolution.approval_id)
    else
      let* next_partition = eligible_partition ~base_path ~keeper_name resolution in
      if not (same_partition current.partition next_partition)
      then Error Different_reply_partitions
      else Ok (Cohort { current with
        reversed = resolution :: current.reversed
      ; approval_ids = Approval_ids.add resolution.approval_id current.approval_ids })

let of_resolutions ~base_path ~keeper_name resolutions =
  List.fold_left
    (fun result resolution ->
      Result.bind result (fun batch -> try_append ~base_path ~keeper_name batch resolution))
    (Ok empty) resolutions
