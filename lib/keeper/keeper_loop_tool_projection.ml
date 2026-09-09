(* See keeper_loop_tool_projection.mli. *)

type t =
  { accum : Keeper_stream_tool_accum.t
  ; rejection : string option ref
        (* The first mapping the collector rejected in the current attempt.
           Later rejections are not more informative than the first and the
           rows are dropped either way, so only the first is kept. *)
  }

let create () = { accum = Keeper_stream_tool_accum.create (); rejection = ref None }

let record_rejection t detail =
  match !(t.rejection) with
  | Some _ -> ()
  | None -> t.rejection := Some detail
;;

let on_event t event = Keeper_stream_tool_accum.on_event t.accum event

let on_tool_stream_observation t
    (observation : Keeper_hooks_agent_core.tool_stream_observation) =
  match observation with
  | Keeper_hooks_agent_core.Runtime_attempt_started _ ->
    let (_ : Keeper_chat_events.runtime_attempt_scope_disposition) =
      Keeper_stream_tool_accum.start_runtime_attempt t.accum
    in
    (* The attempt this boundary abandons is quarantined by the collector, so
       a rejection recorded for it describes rows that are no longer
       persisted. *)
    t.rejection := None
  | Keeper_hooks_agent_core.Turn_collected { turn; tool_source_map } ->
    (match Keeper_stream_tool_accum.seal_turn t.accum ~turn ~tool_source_map with
     | Ok () -> ()
     | Error detail -> record_rejection t detail)
  | Keeper_hooks_agent_core.Turn_closed_without_sources { turn } ->
    (match Keeper_stream_tool_accum.close_turn_without_sources t.accum ~turn with
     | Ok () -> ()
     | Error detail -> record_rejection t detail)
;;

type drop_reason =
  | Mapping_rejected of string
  | Invalid_approval_id of string
  | Append_failed of string

let drop_reason_to_string = function
  | Mapping_rejected detail -> "tool stream occurrence mapping rejected: " ^ detail
  | Invalid_approval_id detail -> "approval id is not a delivery identity: " ^ detail
  | Append_failed detail -> "tool rows were not appended: " ^ detail
;;

type outcome =
  | Nothing_to_project
  | Projected of Keeper_chat_store.append_once_result
  | Projection_dropped of drop_reason

type protocol_error =
  Keeper_chat_events.stream_protocol_error_kind
  * Keeper_chat_events.tool_stream_occurrence
  * string

type persisted =
  { outcome : outcome
  ; quarantined : protocol_error list
  }

(* The store's once-append merges per transcript slot, and the slot of a
   delivery-only tool row is its ordinal within the append. A second turn
   continuing the same approval would have its first rows read as already
   present and only its surplus appended, interleaving two turns' rows under
   one identity with different turn refs. So the key is looked up before
   anything is appended: one approval projects the rows of one turn, and a
   later turn is reported as already present. *)
let tool_row_already_under ~base_dir ~keeper_name ~delivery_key =
  Keeper_chat_store.load_all ~base_dir ~keeper_name
  |> List.find_map (fun (row : Keeper_chat_store.chat_message) ->
       match row.delivery_provenance with
       | Some
           { Keeper_chat_delivery_identity.delivery_key = key
           ; transcript_slot = Keeper_chat_delivery_identity.Tool_delivery _
           }
         when Keeper_chat_delivery_identity.delivery_key_equal key delivery_key ->
         Some row.id
       | Some _ | None -> None)
;;

let persist_continuation t ~base_dir ~keeper_name ~approval_id ~turn_ref ~turn_failed =
  let tool_calls =
    if turn_failed
    then Keeper_stream_tool_accum.to_tool_calls_for_failure t.accum
    else Keeper_stream_tool_accum.to_tool_calls t.accum
  in
  (* The chat lane drains these because its live bridge reports the same
     conflicts to the operator as they happen. The loop lane has no bridge,
     so a quarantined row would otherwise leave the turn's projection short
     with nothing saying so; they travel with the outcome instead. *)
  let quarantined = Keeper_stream_tool_accum.take_protocol_errors t.accum in
  (* The rejection is read before the rows: a refused seal finalizes nothing,
     so an empty row list under a rejection is the drop, not an idle turn. *)
  let outcome =
    match !(t.rejection), tool_calls with
    | Some detail, _ -> Projection_dropped (Mapping_rejected detail)
    | None, [] -> Nothing_to_project
    | None, _ :: _ ->
      (match Keeper_chat_delivery_identity.Request_id.of_string approval_id with
       | Error detail -> Projection_dropped (Invalid_approval_id detail)
       | Ok request_id ->
         let delivery_key = Keeper_chat_delivery_identity.Approval_lifecycle request_id in
         (match tool_row_already_under ~base_dir ~keeper_name ~delivery_key with
          | Some row_id -> Projected (Keeper_chat_store.Already_present { row_id })
          | None ->
            (match
               Keeper_chat_store.append_tool_calls_once
                 ~base_dir
                 ~keeper_name
                 ~delivery_key
                 ~tool_calls
                 ~turn_ref
                 ()
             with
             | Ok result -> Projected result
             | Error detail -> Projection_dropped (Append_failed detail))))
  in
  { outcome; quarantined }
;;
