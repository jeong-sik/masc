(* RFC-0084 §2.1 Tool dispatch telemetry 4-tuple emission SSOT.
   See tool_telemetry.mli for the contract. *)

type trace_id = string

let tool_type_of_name name =
  let name = String.lowercase_ascii (String.trim name) in
  match Tool_name.Board_name.of_string name with
  | Some _ -> "board"
  | None ->
    (* Five arms used to sit here and none of them could match. Run over the
       99 names [Keeper_tool_policy.keeper_model_tool_names] returns and the
       counts are: masc_ 67, Board_name 21, grep/read/write/edit/execute 1
       each, and mcp__masc__ / board_ / memory_ / library_ / surface_ zero.

       The last three were aimed at tools that exist under different names.
       keeper_memory_search, keeper_memory_write, keeper_library_search,
       keeper_library_read, keeper_surface_read and keeper_surface_post all
       carry a keeper_ prefix now, so they fall through to "other" alongside
       WebSearch and the voice tools. Fixing the prefixes would change the
       tool_type dimension for six tools, which is a metric contract call and
       not made here — the arms that cannot fire are removed, the mislabelling
       is left visible. *)
    if String.starts_with ~prefix:"masc_" name
    then "mcp"
    else if name = "grep"
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
