(* RFC-0084 §2.1 Tool dispatch telemetry 4-tuple emission SSOT.
   See tool_telemetry.mli for the contract. *)

type trace_id = string

(* Precedence: the board surface, then the MCP surface, then the catalog, then
   the name chain.

   The first two are surface labels and keep their existing meaning. The
   catalog is the only place a tool declares what it *does*
   ([Tool_catalog.metadata] carries [readonly : bool option]), so where that is
   set it decides read-vs-write instead of the name.

   Only four tools seen in live traffic declare it today, but one of them
   (keeper_tasks_list) is 28% of all calls, so consulting the catalog moves the
   "other" bucket from 57.0% to 27.6% of 94,784 recorded calls.

   The name chain stays as the last resort for tools the catalog has not
   classified — including Read / Write / Edit / Grep / Execute, whose names
   happen to be the verb and which it labels correctly today. Dropping it in
   favour of the catalog alone would push those 21,192 calls into "other" and
   make the dimension worse. The way out is to declare [readonly] for the
   remaining tools, not to grow the prefix list. *)
let tool_type_of_name name =
  let trimmed = String.trim name in
  let name = String.lowercase_ascii trimmed in
  match Tool_name.Board_name.of_string name with
  | Some _ -> "board"
  | None ->
    if String.starts_with ~prefix:"masc_" name
    then "mcp"
    else (
      match (Tool_catalog.metadata trimmed).readonly with
      | Some true -> "read"
      | Some false -> "write"
      | None ->
      if name = "grep"
      then "read"
      else if String.starts_with ~prefix:"read" name
      then "read"
      else if String.starts_with ~prefix:"write" name
      then "write"
      else if String.starts_with ~prefix:"edit" name
      then "write"
      else if String.starts_with ~prefix:"execute" name
      then "execute"
      else "other")
;;

let counter_name = "tool_dispatch_total"
let counter_registered = Atomic.make false
let counter_registration_mu = Stdlib.Mutex.create ()

let register_metrics () =
  if not (Atomic.get counter_registered)
  then
    Stdlib.Mutex.protect counter_registration_mu (fun () ->
      if not (Atomic.get counter_registered)
      then begin
        Otel_metric_store.register_counter
          ~name:counter_name
          ~help:
            "Total tool dispatches by tool name, outcome, surface, and tool_type \
             (RFC-0084 §2.1 4-tuple emission invariant)."
          ~labels:[ "tool", ""; "outcome", ""; "surface", ""; "tool_type", "" ]
          ();
        Atomic.set counter_registered true
      end)
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
