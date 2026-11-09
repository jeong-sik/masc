(** AGENT_CORE boundary adapter for tool results, schemas, and tool definitions.

    MASC dispatch uses typed [Tool_result.result] internally.  This module is the
    boundary adapter that converts typed MASC results to/from
    [Agent_core.Types.tool_result = (tool_output, tool_error) Result.t].

    Central [Tool_dispatch.handler] implementations should return
    [Tool_result.result] directly rather than reintroducing tuple dispatch.

    The result-projection surface (externalization, artifact manifests,
    failure-class sentences, [to_agent_core_typed_result]) lives in
    [Tool_projection], a leaf library mid-level libraries such as
    [Masc_task_handlers] can depend on; this module re-exports it unchanged
    and keeps the schema conversion and AGENT_CORE [Tool.t] creation.

    @since 2.95.1 — result conversion
    @since 2.110.0 — schema conversion + AGENT_CORE Tool.t creation
    @since 2.??? — externalize large outputs via [Tool_blob_store] *)

(* Re-exports of [Tool_projection]. The constructors and record fields are
   re-exported with the types so existing references such as
   [Tool_bridge.Inline_budget_exceeded] and [Tool_bridge.kind] keep
   resolving. *)
type projection_error_kind = Tool_projection.projection_error_kind =
  | Artifact_storage_failure
  | Inline_budget_exceeded

type externalization_error = Tool_projection.externalization_error =
  { kind : projection_error_kind
  ; message : string
  }

let default_externalize_threshold_bytes = Tool_projection.default_externalize_threshold_bytes
let attach_artifact_manifest = Tool_projection.attach_artifact_manifest
let artifact_manifest_reference = Tool_projection.artifact_manifest_reference
let artifact_result_envelope = Tool_projection.artifact_result_envelope
let maybe_externalize = Tool_projection.maybe_externalize
let failure_next_move = Tool_projection.failure_next_move
let to_agent_core_typed_result = Tool_projection.to_agent_core_typed_result

(** {1 Schema Conversion}

    AGENT_CORE owns the JSON Schema to [tool_param] contract. Invalid, missing, or
    ambiguous property types fail at this boundary instead of being guessed
    as strings or reduced to the first union member. *)

(* A property that names its accepted shapes with [oneOf]/[anyOf] and no
   [type] has no single typed parameter, by design: the wire schema carries the
   alternatives verbatim and the tool parses the value itself (BrowserAct
   [keepPages] is "all" or a list of Page labels). It is therefore absent from
   the derived parameter view on purpose. A [type] array that merely lists
   several types is still refused, because that is the ambiguity #25272
   guards: no alternatives are declared, so nothing says how to read it. *)
let declares_disjoint_alternatives = function
  | `Assoc fields ->
    (not (List.mem_assoc "type" fields))
    && List.exists
         (fun key ->
            match List.assoc_opt key fields with
            | Some (`List (_ :: _)) -> true
            | None | Some _ -> false)
         [ "oneOf"; "anyOf" ]
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false
;;

type schema_error =
  | Schema_conversion_error of string
  | Unprojected_property of string
  | Invalid_tool_schema of { name : string; detail : string }

let schema_error_to_string = function
  | Schema_conversion_error detail -> detail
  | Unprojected_property name ->
    Printf.sprintf "property %S cannot be represented by the typed tool parameter surface" name
  | Invalid_tool_schema { name; detail } ->
    Printf.sprintf "tool %S schema invalid: %s" name detail

let params_of_json_schema schema =
  match Agent_core.Mcp.json_schema_to_params_result schema with
  | Error detail -> Error (Schema_conversion_error detail)
  | Ok params ->
  let unprojected_property =
    match schema with
    | `Assoc fields ->
      (match List.assoc_opt "properties" fields with
       | Some (`Assoc properties) ->
         List.find_opt
           (fun (name, property) ->
              (not (declares_disjoint_alternatives property))
              && not
                   (List.exists
                      (fun (param : Agent_core.Types.tool_param) ->
                         String.equal param.name name)
                      params))
           properties
       | None | Some `Null | Some _ -> None)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      None
  in
  match unprojected_property with
  | None -> Ok params
  | Some (name, _) -> Error (Unprojected_property name)
;;

(** {1 AGENT_CORE Tool.t Creation}

    Create AGENT_CORE [Tool.t] from MASC schema definition + dispatch handler.
    This allows incremental migration: each tool can be converted independently. *)

(** Create an AGENT_CORE [Tool.t] from a MASC tool schema and a typed handler.

    [handler] receives raw JSON args and returns a {!Tool_result.result}.
    The bridge converts the result to AGENT_CORE [tool_result] automatically.

    {[
      let agent_core_tool = agent_core_tool_of_masc
        ~name:"masc_board_post"
        ~description:"Post to the board..."
        ~input_schema:schema_json
        (fun args -> handle_board_post ctx args)
    ]} *)
let agent_core_tool_of_masc
    ?descriptor
    ?base_path
    ?model_projection
    ?on_externalization_error
    ~name
    ~description
    ~input_schema
    handler : (Agent_core.Tool.t, schema_error) result =
  let agent_core_handler json_args =
    Tool_projection.to_agent_core_typed_result
      ?base_path
      ?model_projection
      ?on_externalization_error
      (handler json_args)
  in
  match Agent_core.Base.Schema_observation.constructor
          ~site:Bridge_plain_constructor
          (fun () -> Agent_core.Types.tool_schema_of_input_schema ~name ~description ~input_schema ()) with
  | Ok schema ->
    Ok (Agent_core.Tool.of_schema ?descriptor schema
      (Agent_core.Tool.ignoring_execution_env agent_core_handler))
  | Error detail -> Error (Invalid_tool_schema { name; detail })

let agent_core_tool_of_schema_with_execution_env
    ?descriptor
    ?base_path
    ?answer_reader
    ?model_projection
    ?on_externalization_error
    ~schema
  handler
  : Agent_core.Tool.t
  =
  (* Resolved per call, not per tool. One bundle is built before the turn
     picks a runtime, and a heterogeneous lane fallback can change the answer
     between attempts, so a value captured here would describe the wrong lane. *)
  let agent_core_handler execution_env json_args =
    Tool_projection.to_agent_core_typed_result
      ?base_path
      ?answer_reader
      ?model_projection:(Option.map (fun decide -> decide ()) model_projection)
      ?on_externalization_error
      (handler execution_env json_args)
  in
  Agent_core.Base.Tool.of_schema ?descriptor schema agent_core_handler

let agent_core_tool_of_masc_with_execution_env
    ?descriptor
    ?base_path
    ?answer_reader
    ?model_projection
    ?on_externalization_error
    ~name
    ~description
    ~input_schema
    handler
  : (Agent_core.Tool.t, schema_error) result
  =
  match Agent_core.Base.Schema_observation.constructor
          ~site:Bridge_execution_env_constructor
          (fun () -> Agent_core.Types.tool_schema_of_input_schema ~name ~description ~input_schema ()) with
  | Ok schema ->
    Ok (agent_core_tool_of_schema_with_execution_env
      ?descriptor ?base_path ?answer_reader ?model_projection
      ?on_externalization_error ~schema handler)
  | Error detail -> Error (Invalid_tool_schema { name; detail })
