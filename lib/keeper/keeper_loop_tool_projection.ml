(* See keeper_loop_tool_projection.mli. *)

type t =
  { accum : Keeper_stream_tool_accum.t
  ; rejection : string option ref
        (* The first mapping the collector rejected in the current attempt.
           Later rejections are not more informative than the first and the
           rows are dropped either way, so only the first is kept. *)
  ; prepared_inputs :
      ((Ids.Turn_ref.t * Keeper_chat_delivery_identity.approval_input_binding list, string) result) option ref
        (* Frozen preparation association, independent of runtime attempts. *)
  }

let create () =
  { accum = Keeper_stream_tool_accum.create (); rejection = ref None; prepared_inputs = ref None }

let bind_prepared_inputs t ~turn_ref (model : Keeper_gate_replay.model_message) =
  let prepared = Result.bind model.approval_input_bindings (fun inputs ->
    Keeper_chat_delivery_identity.validate_approval_input_bindings inputs
    |> Result.map (fun () -> turn_ref, inputs)) in
  match !(t.prepared_inputs), prepared with
  | None, prepared -> t.prepared_inputs := Some prepared
  | Some (Error _), _ -> ()
  | Some (Ok _), Error detail -> t.prepared_inputs := Some (Error detail)
  | Some (Ok (owner, previous)), Ok (current_owner, current) ->
    if not (Ids.Turn_ref.equal owner current_owner
      && Keeper_chat_delivery_identity.approval_input_bindings_equal previous current)
    then t.prepared_inputs := Some (Error "prepared approval input association changed within a turn")
;;

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
     | Ok _ -> ()
     | Error detail -> record_rejection t detail)
  | Keeper_hooks_agent_core.Child_content_observed _
  | Keeper_hooks_agent_core.Provider_retry_observed _
  | Keeper_hooks_agent_core.Native_task_observed _
  | Keeper_hooks_agent_core.Native_tool_progress _
  | Keeper_hooks_agent_core.Native_tool_completion _ -> ()
  | Keeper_hooks_agent_core.Official_tool_result { block_index; tool_call_id; execution_id } ->
    (match Keeper_stream_tool_accum.record_official_execution_id t.accum
             ~block_index ~tool_call_id ~execution_id with
     | Ok _ -> ()
     | Error detail -> record_rejection t detail)
  | Keeper_hooks_agent_core.Turn_closed_without_sources { turn } ->
    (match Keeper_stream_tool_accum.close_turn_without_sources t.accum ~turn with
     | Ok () -> ()
     | Error detail -> record_rejection t detail)
;;

type drop_reason =
  | Mapping_rejected of string
  | Input_binding_unavailable of string
  | Append_failed of string

let drop_reason_to_string = function
  | Mapping_rejected detail -> "tool stream occurrence mapping rejected: " ^ detail
  | Input_binding_unavailable detail -> "prepared approval input binding unavailable: " ^ detail
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
  ; committed_ownerships : (Keeper_chat_delivery_identity.delivery_key * Keeper_chat_store.tool_ownership) list
  ; quarantined : protocol_error list
  }

let persist_continuation t ~base_dir ~keeper_name ~turn_ref ~turn_failed =
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
  let outcome, committed_ownerships =
    match !(t.rejection), tool_calls with
    | Some detail, _ -> Projection_dropped (Mapping_rejected detail), []
    | None, tool_calls ->
      (match !(t.prepared_inputs), tool_calls with
       | None, [] -> Nothing_to_project, []
       | None, _ :: _ ->
         Projection_dropped (Input_binding_unavailable "no actual prepared input observation"), []
       | Some (Error detail), _ -> Projection_dropped (Input_binding_unavailable detail), []
       | Some (Ok (owner, inputs)), _ ->
         if not (Ids.Turn_ref.equal owner turn_ref)
         then Projection_dropped (Input_binding_unavailable "prepared turn owner differs from projection owner"), []
         else
           let delivery_key = Keeper_chat_delivery_identity.Autonomous_turn owner in
           match Keeper_chat_store.append_autonomous_tool_calls_once
             ~base_dir ~keeper_name ~turn_ref:owner ~input_binding:inputs ~tool_calls () with
           | Ok ((Keeper_chat_store.Appended _ as result), ownerships) ->
             Projected result,
             List.map (fun ownership -> delivery_key, ownership)
               ownerships
           | Ok ((Keeper_chat_store.Already_present _ as result), _) -> Projected result, []
           | Error detail -> Projection_dropped (Append_failed detail), [])
  in
  { outcome; committed_ownerships; quarantined }
;;
