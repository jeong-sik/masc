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

let persist_continuation t ~base_dir ~keeper_name ~approval_id ~turn_ref ~turn_failed =
  let tool_calls =
    if turn_failed
    then Keeper_stream_tool_accum.to_tool_calls_for_failure t.accum
    else Keeper_stream_tool_accum.to_tool_calls t.accum
  in
  match tool_calls, !(t.rejection) with
  | [], _ -> Nothing_to_project
  | _ :: _, Some detail -> Projection_dropped (Mapping_rejected detail)
  | _ :: _, None ->
    (match Keeper_chat_delivery_identity.Request_id.of_string approval_id with
     | Error detail -> Projection_dropped (Invalid_approval_id detail)
     | Ok request_id ->
       (match
          Keeper_chat_store.append_tool_calls_once
            ~base_dir
            ~keeper_name
            ~delivery_key:(Keeper_chat_delivery_identity.Approval_lifecycle request_id)
            ~tool_calls
            ~turn_ref
            ()
        with
        | Ok result -> Projected result
        | Error detail -> Projection_dropped (Append_failed detail)))
;;
