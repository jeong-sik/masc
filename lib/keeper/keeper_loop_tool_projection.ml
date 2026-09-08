(* See keeper_loop_tool_projection.mli. *)

type t =
  { accum : Keeper_stream_tool_accum.t
  ; first_failure : string option ref
        (* The first mapping or join the collector rejected. Later failures
           are not more informative than the first and the rows are dropped
           either way, so only the first is kept. *)
  }

let create () =
  { accum = Keeper_stream_tool_accum.create (); first_failure = ref None }
;;

let record_failure t detail =
  match !(t.first_failure) with
  | Some _ -> ()
  | None -> t.first_failure := Some detail
;;

let on_event t event = Keeper_stream_tool_accum.on_event t.accum event

let on_tool_stream_observation t
    (observation : Keeper_hooks_agent_core.tool_stream_observation) =
  match observation with
  | Keeper_hooks_agent_core.Runtime_attempt_started _ ->
    let (_ : Keeper_chat_events.runtime_attempt_scope_disposition) =
      Keeper_stream_tool_accum.start_runtime_attempt t.accum
    in
    ()
  | Keeper_hooks_agent_core.Turn_collected { turn; tool_source_map } ->
    (match Keeper_stream_tool_accum.seal_turn t.accum ~turn ~tool_source_map with
     | Ok () -> ()
     | Error detail -> record_failure t ("tool stream occurrence mapping rejected: " ^ detail))
  | Keeper_hooks_agent_core.Turn_closed_without_sources { turn } ->
    (match Keeper_stream_tool_accum.close_turn_without_sources t.accum ~turn with
     | Ok () -> ()
     | Error detail -> record_failure t ("sourceless turn close rejected: " ^ detail))
;;

let on_tool_result_ready t ~tool_call_id ~turn ~planned_index ~execution_id =
  match
    Keeper_stream_tool_accum.record_execution_id
      t.accum
      ~tool_call_id
      ~turn
      ~planned_index
      ~execution_id
  with
  | Ok (_ : Keeper_chat_events.tool_stream_occurrence) -> ()
  | Error detail -> record_failure t ("tool execution identity join rejected: " ^ detail)
;;

type outcome =
  | Nothing_to_project
  | Projected of Keeper_chat_store.append_once_result
  | Projection_dropped of string

let persist t ~base_dir ~keeper_name ~delivery_key ~turn_ref ~turn_failed =
  let tool_calls =
    if turn_failed
    then Keeper_stream_tool_accum.to_tool_calls_for_failure t.accum
    else Keeper_stream_tool_accum.to_tool_calls t.accum
  in
  match !(t.first_failure), tool_calls with
  | Some detail, _ -> Projection_dropped detail
  | None, [] -> Nothing_to_project
  | None, _ :: _ ->
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
     | Error detail -> Projection_dropped ("tool rows were not appended: " ^ detail))
;;
