module Async = Keeper_msg_async

type unavailable =
  | Canonical_unavailable of Async.canonical_terminal_error
  | Producer_mismatch
  | Terminal_mismatch
  | Logical_result_pending
  | Recovery_unavailable of Keeper_tool_execution_journal.error

type t =
  { completion : Keeper_event_queue.composition_completion
  ; result : (Async.entry, unavailable) result
  }

let read ~base_path ~keeper_name completion =
  let result =
    match Async.load_canonical_durable_terminal ~base_path ~caller:keeper_name completion.Keeper_event_queue.cc_request_id with
    | Error error -> Error (Canonical_unavailable error)
    | Ok proof ->
      let entry = Async.durable_terminal_entry proof in
      let producer = Option.bind entry.request_context (List.assoc_opt "composition_tool") in
      if not (String.equal entry.keeper_name keeper_name)
         || producer <> Some (`String completion.cc_tool) then Error Producer_mismatch
      else match Keeper_tool_execution_journal.completion_pending ~base_path entry with
        | Error error -> Error (Recovery_unavailable error)
        | Ok true -> Error Logical_result_pending
        | Ok false -> match Keeper_composition_completion_wake.terminal_of_status entry.status with
        | Some terminal when terminal = completion.cc_terminal -> Ok entry
        | Some _ | None -> Error Terminal_mismatch in
  { completion; result }
;;

let unavailable_to_json = function
  | Canonical_unavailable error ->
    `Assoc [ "kind", `String "canonical_result_unavailable"
           ; "detail", `String (Async.canonical_terminal_error_to_string error) ]
  | Producer_mismatch -> `Assoc [ "kind", `String "producer_mismatch" ]
  | Terminal_mismatch -> `Assoc [ "kind", `String "terminal_mismatch" ]
  | Logical_result_pending -> `Assoc ["kind",`String "logical_result_pending"]
  | Recovery_unavailable error -> `Assoc ["kind",`String "original_recovery_unavailable";
      "error",Keeper_tool_execution_journal.error_to_json error]
;;

let outcome = function
  | Keeper_event_queue.Composition_succeeded -> "succeeded"
  | Keeper_event_queue.Composition_failed _ -> "failed"
  | Keeper_event_queue.Composition_cancelled _ -> "cancelled"
;;

let source_fields (entry : Async.entry) =
  match entry.request_context with
  | None -> []
  | Some fields ->
    List.filter (fun (key, _) -> List.mem key
      [ "composition_run_id"; "parent_tool_use_id"; "source_turn"; "source_task_id"
      ; "skill_reference"; "draft_reference"; "run_artifact" ]) fields
;;

let selected_fields (entry : Async.entry) =
  match entry.status with
  | Async.Done { data = Some (`Assoc fields); _ } ->
    (match List.assoc_opt "exports" fields with
     | Some (`Assoc _) ->
       List.filter (fun (key, _) -> List.mem key
         [ "exports"; "nodes"; "cause"; "effect_disposition"; "execution_artifact" ]) fields
     | Some _ | None -> [])
  | Async.Done { data = Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _); _ }
  | Async.Done { data = None; _ }
  | Async.Lost _ | Async.Cancelled _ | Async.Persistence_failed _
  | Async.Waiting_for_dependencies _
  | Async.Queued | Async.Running | Async.Cancelling _ -> []
;;

let to_json { completion; result } =
  let reference = `Assoc
      [ "tool", `String "keeper_composition_status"
      ; "arguments", `Assoc [ "request_id", `String completion.Keeper_event_queue.cc_request_id ] ] in
  let base =
    [ "request_id", `String completion.cc_request_id
    ; "composition_tool", `String completion.cc_tool
    ; "outcome", `String (outcome completion.cc_terminal)
    ; "result_reference", reference ] in
  match result with
  | Error error ->
    `Assoc (base @ [ "result_available", `Bool false; "result_error", unavailable_to_json error ])
  | Ok entry ->
    let canonical = base @
      [ "result_available", `Bool true
      ; "request_status", `String (Async.status_to_string entry.status)
      ; "source", `Assoc (source_fields entry) ] in
    let detail = match completion.cc_terminal with
      | Keeper_event_queue.Composition_succeeded -> []
      | Keeper_event_queue.Composition_failed detail
      | Keeper_event_queue.Composition_cancelled detail -> [ "terminal_detail", `String detail ] in
    let selected = selected_fields entry in
    let candidate = `Assoc (canonical @ [ "result_inline", `Bool (selected <> []) ] @ detail @ selected) in
    if String.length (Yojson.Safe.to_string candidate) <= Common.max_agent_core_inline_result_bytes then
      candidate
    else
      (* Keep the exact source in the owned request record too. A referenced
         projection is complete as a lookup, rather than partial JSON. *)
      let reference_only = `Assoc (canonical @ [ "result_inline", `Bool false ]) in
      if String.length (Yojson.Safe.to_string reference_only) <= Common.max_agent_core_inline_result_bytes then
        reference_only
      else
        `Assoc (base @ [ "result_available", `Bool true; "request_status", `String (Async.status_to_string entry.status)
                      ; "result_inline", `Bool false; "source_inline", `Bool false ])
;;
