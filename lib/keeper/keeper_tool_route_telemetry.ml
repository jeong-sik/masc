(** Bounded telemetry projection for descriptor-owned tool routes. *)

let add_internal_names table (descriptor : Keeper_tool_descriptor.t) =
  List.iter
    (fun internal_name -> Hashtbl.replace table internal_name ())
    (Keeper_tool_descriptor.internal_names descriptor)
;;

let known_public_names : (string, unit) Hashtbl.t =
  let table = Hashtbl.create 16 in
  List.iter
    (fun descriptor ->
      List.iter
        (fun public_name -> Hashtbl.replace table public_name ())
        (Keeper_tool_descriptor.public_names_of_descriptor descriptor))
    Keeper_tool_descriptor.public_descriptors;
  table
;;

let known_runtime_names : (string, unit) Hashtbl.t =
  let table = Hashtbl.create 128 in
  List.iter
    (add_internal_names table)
    (Keeper_tool_descriptor.all_descriptors ());
  List.iter
    (fun (schema : Masc_domain.tool_schema) ->
      Hashtbl.replace table schema.name ())
    Tool_schemas_misc.mcp_runtime_schemas;
  table
;;

let safe_tool_label name =
  if Hashtbl.mem known_public_names name || Hashtbl.mem known_runtime_names name
  then name
  else "unknown"
;;

let safe_routed_to_label name =
  if String.equal name "none" || Hashtbl.mem known_runtime_names name
  then name
  else "unknown"
;;

let record_route_outcome ~tool ~routed_to ~result =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ToolCallTotal)
    ~labels:
      [ "tool", safe_tool_label tool
      ; "routed_to", safe_routed_to_label routed_to
      ; "result", result
      ; "tool_type", Tool_telemetry.tool_type_of_name tool
      ]
    ();
  Otel_metric_store.inc_counter
    (Keeper_metrics.to_string ToolCallParamCompleteness)
    ~labels:
      [ "tool", safe_tool_label tool
      ; "status", if String.equal result "ok" then "complete" else "incomplete"
      ]
    ()
;;
