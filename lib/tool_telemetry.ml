(* RFC-0084 §2.1 Tool dispatch telemetry 4-tuple emission SSOT.
   See tool_telemetry.mli for the contract. *)

type trace_id = string

(* Precedence: the board surface, then the MCP surface, then what the tool
   declares about itself — in its descriptor first, else in the catalog.

   The first two are surface labels and keep their existing meaning. A
   descriptor is the tool's own declaration, in closed fields:
   [policy.readonly_hint] for read-vs-write, and [executor = Shell_ir] without
   a read-only declaration for a tool whose call is a process — the "execute"
   label. It comes before the catalog so that Execute reads the same under
   its public name and its internal one ([tool_execute], whose catalog row is
   the generic [mutating_tool]). The catalog ([Tool_catalog.metadata.readonly])
   is where a tool without a descriptor says whether it reads or writes;
   keeper_tasks_list alone is 28% of recorded calls, so that declaration
   decides for it.

   There is no name chain. A name that merely looks like a verb (an attached
   service's read_file, a typo, a tool nobody declared) is "other", the honest
   unknown; until #49742 this arm read [read]/[write]/[edit]/[execute]
   prefixes and the "grep" literal off the name, which is the kind of
   substring dispatch the constitution ([string_matching]) forbids. The way
   to move a tool out of "other" is to declare it. *)
let declared_kind (descriptor : Keeper_tool_descriptor.t) =
  let open Keeper_tool_descriptor in
  match descriptor.policy.readonly_hint, descriptor.executor with
  | Some true, (Shell_ir | Filesystem | In_process) -> Some "read"
  | Some false, (Shell_ir | Filesystem | In_process) -> Some "write"
  | None, Shell_ir -> Some "execute"
  | None, (Filesystem | In_process) -> None
;;

(* The model-visible name is the public one ([Read]); the MCP surface and the
   runtime dispatcher carry the internal one ([tool_read_file]). *)
let descriptor_of_name name =
  match Keeper_tool_descriptor.find_public name with
  | Some descriptor -> Some descriptor
  | None ->
    (match Keeper_tool_descriptor.descriptors_for_internal name with
     | descriptor :: _ -> Some descriptor
     | [] -> None)
;;

let tool_type_of_name name =
  let trimmed = String.trim name in
  let lower = String.lowercase_ascii trimmed in
  match Tool_name.Board_name.of_string lower with
  | Some _ -> "board"
  | None ->
    if String.starts_with ~prefix:"masc_" lower
    then "mcp"
    else (
      match Option.bind (descriptor_of_name trimmed) declared_kind with
      | Some kind -> kind
      | None ->
        (match (Tool_catalog.metadata trimmed).readonly with
         | Some true -> "read"
         | Some false -> "write"
         | None -> "other"))
;;

let counter_name = "tool_dispatch_total"

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
