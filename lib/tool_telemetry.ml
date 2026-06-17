(* RFC-0084 §2.1 Tool dispatch telemetry 4-tuple emission SSOT.
   See tool_telemetry.mli for the contract. *)

type trace_id = string

let tool_type_of_name name =
  let name = String.lowercase_ascii (String.trim name) in
  if String.starts_with ~prefix:"masc_" name
  then "mcp"
  else if String.starts_with ~prefix:"mcp__masc__" name
  then "mcp"
  else if String.starts_with ~prefix:"keeper_board_" name
       || String.starts_with ~prefix:"board_" name
  then "board"
  else if String.starts_with ~prefix:"memory_" name
  then "memory"
  else if String.starts_with ~prefix:"library_" name
       || String.starts_with ~prefix:"surface_" name
  then "read"
  else if name = "grep"
       || name = "search"
       || name = "search_files"
       || String.starts_with ~prefix:"search_files" name
  then "read"
  else if String.starts_with ~prefix:"read" name
  then "read"
  else if String.starts_with ~prefix:"write" name
  then "write"
  else if String.starts_with ~prefix:"edit" name
  then "write"
  else if String.starts_with ~prefix:"execute" name
  then "execute"
  else "other"
;;

let counter_name = "tool_dispatch_total"
let counter_registered = ref false

let register_metrics () =
  if not !counter_registered
  then begin
    Otel_metric_store.register_counter
      ~name:counter_name
      ~help:
        "Total tool dispatches by tool name, outcome, surface, and tool_type \
         (RFC-0084 §2.1 4-tuple emission invariant)."
      ~labels:[ "tool", ""; "outcome", ""; "surface", ""; "tool_type", "" ]
      ();
    counter_registered := true
  end
;;

let with_span ?(force_new_trace_id = false) ?(surface = "unknown") ~tool_name f =
  let span_name = "tool_dispatch." ^ tool_name in
  Otel_spans.with_span ~name:span_name ~force_new_trace_id (fun trace_id_thunk ->
    let result, outcome = f trace_id_thunk in
    Otel_metric_store.inc_counter
      counter_name
      ~labels:
        [ "tool", tool_name
        ; "outcome", outcome
        ; "surface", surface
        ; "tool_type", tool_type_of_name tool_name
        ]
      ();
    result, outcome)
;;
