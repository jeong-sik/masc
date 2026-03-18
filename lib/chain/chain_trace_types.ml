(** Chain Trace Types - Execution Tracing Types

    Pure type definitions for chain execution tracing.
    No dependencies on exec_context or other runtime types.
*)

(** Trace event types for execution logging *)
type trace_event =
  | NodeStart of { node_type : string; attempt : int }
  | NodeComplete of { duration_ms : int; success : bool; node_type : string; attempt : int }
  | NodeError of { message : string; error_class : string option; node_type : string; attempt : int }
  | ChainStart of { chain_id : string; mermaid_dsl : string option }
  | ChainComplete of { chain_id : string; success : bool }

(** Internal trace entry for execution *)
type internal_trace = {
  timestamp : float;
  node_id : string;
  event : trace_event;
}

(** Execution phase for node status tracking *)
type exec_phase =
  | Planned
  | Running
  | Completed
  | Failed
  | Skipped

(** {1 Trace Conversion Functions} *)

(** Convert internal_trace to Chain_types.trace_entry *)
let trace_to_entry (t : internal_trace) (node_type_name : string) : Chain_types.trace_entry =
  let node_type_from_event = match t.event with
    | NodeStart { node_type; _ }
    | NodeComplete { node_type; _ }
    | NodeError { node_type; _ } -> Some node_type
    | _ -> None
  in
  let node_type_name = match node_type_from_event with
    | Some nt -> nt
    | None -> node_type_name
  in
  let status, error = match t.event with
    | NodeStart _ -> (`Success, None)  (* Will be updated by NodeComplete *)
    | NodeComplete { success; _ } ->
        if success then (`Success, None) else (`Failure, None)
    | NodeError { message; _ } -> (`Failure, Some message)
    | ChainStart _ | ChainComplete _ -> (`Success, None)
  in
  {
    Chain_types.node_id = t.node_id;
    node_type_name;
    start_time = t.timestamp;
    end_time = t.timestamp;  (* Will be updated by pairing with NodeComplete *)
    status;
    output_preview = None;
    error;
  }

(** Convert internal traces to trace_entry list, pairing start/complete events *)
let traces_to_entries (traces : internal_trace list) : Chain_types.trace_entry list =
  (* Group traces by node_id and build proper entries *)
  let node_traces = Hashtbl.create 16 in
  List.iter (fun (t : internal_trace) ->
    let existing = try Hashtbl.find node_traces t.node_id with Not_found -> [] in
    Hashtbl.replace node_traces t.node_id (t :: existing)
  ) traces;

  Hashtbl.fold (fun node_id events acc ->
    let node_type_name =
      List.find_map (fun t ->
        match t.event with
        | NodeStart { node_type; _ }
        | NodeComplete { node_type; _ }
        | NodeError { node_type; _ } -> Some node_type
        | _ -> None
      ) events
      |> Option.value ~default:"unknown"
    in
    (* Find start and complete events *)
    let start_time = List.fold_left (fun acc t ->
      match t.event with NodeStart _ -> min acc t.timestamp | _ -> acc
    ) max_float events in
    let end_time, status, error = List.fold_left (fun (et, st, err) t ->
      match t.event with
      | NodeComplete { duration_ms = _; success; _ } ->
          (t.timestamp, (if success then `Success else `Failure), err)
      | NodeError { message; _ } -> (et, `Failure, Some message)
      | _ -> (et, st, err)
    ) (start_time, `Success, None) events in

    let entry : Chain_types.trace_entry = {
      node_id;
      node_type_name;
      start_time;
      end_time;
      status;
      output_preview = None;
      error;
    } in
    entry :: acc
  ) node_traces []
