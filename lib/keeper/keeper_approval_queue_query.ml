open Keeper_approval_queue_rules
open Keeper_approval_queue_projection
open Keeper_approval_queue_result
open Keeper_approval_queue_codec
open Keeper_approval_queue_state
open Keeper_approval_queue_registry

let pending_entries_in_sequence_order () =
  SMap.fold (fun _id entry acc -> entry :: acc) (Atomic.get pending) []
  |> List.sort compare_pending_order
;;

type pending_entries_snapshot =
  { revision : int
  ; entries : pending_approval list
  ; read_errors : storage_error list
  }

let pending_entries_snapshot_unlocked ~base_path =
  let entries =
    pending_entries_in_sequence_order ()
    |> List.filter (fun (entry : pending_approval) ->
      String.equal entry.audit_base_path base_path)
  in
  let revision = store_revision_unlocked ~base_path in
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some _ when SMap.mem base_path (Atomic.get pending_read_errors) ->
    Ok
      { revision
      ; entries
      ; read_errors =
          Option.value
            (SMap.find_opt base_path (Atomic.get pending_read_errors))
            ~default:[]
      }
  | Some error -> Error error
  | None -> Ok { revision; entries; read_errors = [] }
;;

let pending_entries_snapshot_for_workspace ~base_path =
  with_pending_store_lock (fun () ->
    pending_entries_snapshot_unlocked ~base_path)
;;

let list_pending_entries_with_read_errors_for_workspace ~base_path =
  pending_entries_snapshot_for_workspace ~base_path
  |> Result.map (fun snapshot -> snapshot.entries, snapshot.read_errors)
;;

let list_pending_entries_for_workspace ~base_path =
  list_pending_entries_with_read_errors_for_workspace ~base_path
  |> Result.map fst
;;

let get_pending_entry_for_workspace ~base_path ~id =
  with_pending_store_lock (fun () ->
    match SMap.find_opt base_path (Atomic.get unavailable_stores) with
    | Some error -> Error error
    | None ->
      (match SMap.find_opt id (Atomic.get pending) with
       | Some entry when String.equal entry.audit_base_path base_path ->
         Ok (Some entry)
       | Some _ | None -> Ok None))
;;

let list_pending_dashboard_json_for_workspace ~base_path =
  list_pending_entries_for_workspace ~base_path
  |> Result.map (fun entries ->
    entries
    |> List.map (fun entry ->
      `Assoc (pending_entry_json_fields ~include_input:true entry)))
;;

let pending_count_for_keeper_in_workspace ~base_path ~keeper_name =
  list_pending_entries_for_workspace ~base_path
  |> Result.map (fun entries ->
    List.fold_left
      (fun count (entry : pending_approval) ->
        if String.equal entry.keeper_name keeper_name then count + 1 else count)
      0
      entries)
;;

type waiting_observation =
  { waiting_request : pending_approval; waiting_decision : decision option }
let observe_waiting_request ~base_path ~id =
  with_pending_store_lock (fun () ->
    match SMap.find_opt base_path (Atomic.get unavailable_stores) with
    | Some error -> Error error
    | None ->
      match SMap.find_opt id (Atomic.get deliveries), SMap.find_opt id (Atomic.get pending) with
      | Some delivery, _ when delivery.entry.audit_base_path = base_path ->
        Ok (Some {waiting_request=delivery.entry; waiting_decision=Some delivery.decision})
      | None, Some entry when entry.audit_base_path = base_path ->
        Ok (Some {waiting_request=entry; waiting_decision=None})
      | Some _, _ | None, Some _ | None, None -> Ok None)

let exact_matches_entry request (entry : pending_approval) =
  Keeper_approval_request_fingerprint.matches_entry request
    ~base_path:entry.audit_base_path ~keeper_name:entry.keeper_name
    ~operation:entry.tool_name ~input:entry.input ~input_hash:entry.input_hash
    ~origin:entry.origin ~task_id:entry.task_id ~goal_id:entry.goal_id
    ~continuation_channel:entry.continuation_channel
;;

let exact_delivery_observation (delivery : persisted_delivery) : exact_request_observation =
  let state = match delivery.decision with
    | Decision.Reject reason -> Exact_rejected reason
    | Decision.Approve ->
      if delivery.grant_consumed then Exact_approved_consumed delivery.replay_outcome
      else Exact_approved_unconsumed
  in
  { exact_approval_id = delivery.entry.id; exact_request = delivery.entry; exact_state = state }
;;

let exact_store_ready ~base_path =
  match Keeper_approval_queue_persist.next_sequence_lifecycle ~base_path with
  | Keeper_approval_queue_persist.Uninstalled ->
    Error { path = pending_store_path ~base_path;
      reason = "exact Gate lookup requires an installed workspace store" }
  | Keeper_approval_queue_persist.Unavailable error -> Error error
  | Keeper_approval_queue_persist.Ready _ ->
    (match SMap.find_opt base_path (Atomic.get pending_read_errors) with
     | Some (error :: _) -> Error error
     | Some [] | None ->
       match SMap.find_opt base_path (Atomic.get replay_projection_errors) with
       | Some error -> Error error
       | None -> Ok ())
;;

let observe_exact_request ?approval_id request =
  let base_path = Keeper_approval_request_fingerprint.base_path request in
  with_pending_store_lock (fun () ->
    match exact_store_ready ~base_path with
    | Error error -> Error error
    | Ok () ->
      let pending_map = Atomic.get pending in
      let delivery_map = Atomic.get deliveries in
      let matches =
        SMap.fold (fun _ (entry : pending_approval) found ->
          if exact_matches_entry request entry then
            { exact_approval_id = entry.id; exact_request = entry; exact_state = Exact_pending } :: found
          else found) pending_map []
        |> fun found -> SMap.fold (fun _ delivery found ->
          if exact_matches_entry request delivery.entry then
            exact_delivery_observation delivery :: found
          else found) delivery_map found
        |> List.sort (fun (a : exact_request_observation) b ->
          String.compare a.exact_approval_id b.exact_approval_id)
      in
      let matching_approval_ids =
        List.map (fun (row : exact_request_observation) -> row.exact_approval_id) matches
      in
      let classify_matches () = match matches with
        | [] -> Exact_absent
        | [row] -> Exact_found row
        | _ :: _ :: _ -> Exact_ambiguous matching_approval_ids
      in
      match approval_id with
        | None -> Ok (classify_matches ())
        | Some approval_id ->
          let known = match SMap.find_opt approval_id pending_map,
              SMap.find_opt approval_id delivery_map with
            | Some entry, None -> Ok (Some entry)
            | None, Some delivery -> Ok (Some delivery.entry)
            | None, None -> Ok None
            | Some _, Some _ -> Error
                { path = pending_store_path ~base_path;
                  reason = "known approval exists in both pending and resolved states" }
          in
          (match known with
           | Error error -> Error error
           | Ok None -> Ok (Known_approval_missing { approval_id; matching_approval_ids })
           | Ok (Some entry) ->
             if exact_matches_entry request entry then Ok (classify_matches ())
             else Ok (Known_approval_mismatch { approval_id; matching_approval_ids })))
;;
