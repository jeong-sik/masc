module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** OAS boundary adapter for tool results, schemas, and tool definitions.

    MASC dispatch uses typed [Tool_result.result] internally.  This module is the
    boundary adapter that converts typed MASC results to/from
    [Agent_sdk.Types.tool_result = (tool_output, tool_error) Result.t].

    Central [Tool_dispatch.handler] implementations should return
    [Tool_result.result] directly rather than reintroducing tuple dispatch.

    @since 2.95.1 — result conversion
    @since 2.110.0 — schema conversion + OAS Tool.t creation
    @since 2.??? — externalize large outputs via [Tool_blob_store] *)

(** {1 Tool Output Externalization}

    Tool outputs above [default_externalize_threshold_bytes] are stored
    in the content-addressed blob store ([Tool_blob_store]) and the
    OAS [content] field carries a blob marker
    ([Tool_output.encode_for_oas (Stored {...})]). Smaller outputs flow
    through unchanged.

    The hydrator reducer (see [keeper_artifact_hydrator], PR 4) lazily
    re-inflates the most recent stored refs before LLM dispatch; older
    refs stay as markers in the message history.

    Disabled when [MASC_BASE_PATH] is unset (no store root resolvable),
    which keeps unit tests free from filesystem side effects unless they
    explicitly opt in. *)

let default_externalize_threshold_bytes = 2048

let externalize_threshold_bytes () =
  match Sys.getenv_opt "MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES" with
  | None -> default_externalize_threshold_bytes
  | Some s ->
      (match Stdlib.int_of_string_opt (String.trim s) with
       | Some n when n >= 0 -> n
       | _ -> default_externalize_threshold_bytes)

let externalization_disabled () =
  match Sys.getenv_opt "MASC_TOOL_EXTERNALIZE" with
  | Some ("0" | "false" | "no" | "off") -> true
  | _ -> false

let resolve_blob_store () =
  match (Host_config.from_env ()).base_path with
  | None -> None
  | Some base_path -> Some (Tool_blob_store.create ~base_path)

(** Externalize [msg] when it exceeds the threshold AND a blob store is
    available; otherwise pass through unchanged. Best-effort — any
    failure inside the store falls back to the original [msg] so the
    keeper never loses tool output bytes due to a storage hiccup. *)
let maybe_externalize ?(mime = "text/plain") (msg : string) : string =
  if externalization_disabled () then msg
  else
    let threshold = externalize_threshold_bytes () in
    if String.length msg <= threshold then msg
    else
      match resolve_blob_store () with
      | None -> msg
      | Some store ->
          (try
             let stored = Tool_blob_store.put store ~bytes:msg ~mime in
             Tool_output.encode_for_oas stored
           with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            Log.Misc.warn
              "tool_bridge: blob externalization failed; preserving inline output: %s"
              (Printexc.to_string exn);
            msg)

(** {1 Result Conversion} *)

let make_tool_error ?(recoverable = false) ?error_class message
  : Agent_sdk.Types.tool_result =
  Error { Agent_sdk.Types.message; recoverable; error_class }

let oas_error_class_of_tool_failure_class = function
  | Tool_result.Transient_error -> Agent_sdk.Types.Transient
  | Tool_result.Policy_rejection
  | Tool_result.Workflow_rejection ->
    Agent_sdk.Types.Deterministic
  | Tool_result.Runtime_failure -> Agent_sdk.Types.Unknown
;;

(** {1 Schema Conversion}

    Convert MASC JSON Schemas into the narrower OAS [tool_param list]
    representation. Keep this adapter tolerant: MASC schemas may contain
    JSON Schema unions such as ["object"; "string"; "array"], while the
    OAS param model has a single scalar [param_type]. *)

let param_type_of_string = Agent_sdk.Mcp.json_schema_type_to_param_type

let type_string_of_schema_property prop =
  match Json_util.assoc_member_opt "type" prop with
  | Some (`String value) -> Some value
  | Some (`List values) ->
      List.find_map
        (function
          | `String value when not (String.equal value "null") -> Some value
          | _ -> None)
        values
  | _ -> None

let params_of_json_schema schema =
  let __t0 = Mtime_clock.now () in
  (* [required] is conceptually a set (membership semantics, no ordering
     or duplicates) — materialise as Hashtbl so the per-property check
     below is O(1) instead of O(R) per property.  Per-call savings scale
     with property × required-field count; this helper fires from
     [oas_tool_of_masc] per OAS conversion. *)
  let required_set =
    match Json_util.get_array schema "required" with
    | Some (`List items) ->
        (* Constant initial size 16: avoid the extra [List.length items]
           pass (which itself is O(R)) before [List.iter].  Hashtbl
           auto-resizes — sizing exactly to the input only saves a
           handful of resizes per call, which is cheaper than re-walking
           the list. *)
        let tbl = Hashtbl.create 16 in
        List.iter
          (function
            | `String value -> Hashtbl.replace tbl value ()
            | _ -> ())
          items;
        tbl
    | _ -> Hashtbl.create 0
  in
  let result =
    match Json_util.get_object schema "properties" with
    | Some (`Assoc pairs) ->
        List.map
          (fun (name, prop) ->
            let param_type =
              prop
              |> type_string_of_schema_property
              |> Option.value ~default:"string"
              |> param_type_of_string
            in
            let description =
              Json_util.get_string prop "description"
              |> Option.value ~default:""
            in
            let required = Hashtbl.mem required_set name in
            { Agent_sdk.Types.name = name; description; param_type; required })
          pairs
    | _ -> []
  in
  Otel_metric_hotpath.observe
    ~metric:Otel_metric_hotpath.metric_oas_params_of_schema_sec
    ~start:__t0;
  result

(** {1 OAS Tool.t Creation}

    Create OAS [Tool.t] from MASC schema definition + dispatch handler.
    This allows incremental migration: each tool can be converted independently. *)

let to_oas_typed_result (tr : Tool_result.result) : Agent_sdk.Types.tool_result =
  match tr with
  | Tool_result.Completed output ->
    Ok
      { Agent_sdk.Types.content = maybe_externalize (Tool_result.message tr)
      ; _meta = output.metadata
      }
  | Tool_result.Deferred output ->
    let disposition_field =
      "masc.tool_disposition", `String (Tool_result.string_of_disposition tr)
    in
    let metadata =
      match output.metadata with
      | None -> `Assoc [ disposition_field ]
      | Some metadata ->
        `Assoc [ disposition_field; "masc.payload", metadata ]
    in
    Ok
      { Agent_sdk.Types.content = maybe_externalize (Tool_result.message tr)
      ; _meta = Some metadata
      }
  | Tool_result.Failed { class_; message; _ } ->
    make_tool_error
      ~recoverable:(Tool_result.is_retryable class_)
      ~error_class:(oas_error_class_of_tool_failure_class class_)
      (maybe_externalize message)

(** Create an OAS [Tool.t] from a MASC tool schema and a typed handler.

    [handler] receives raw JSON args and returns a {!Tool_result.result}.
    The bridge converts the result to OAS [tool_result] automatically.

    {[
      let oas_tool = oas_tool_of_masc
        ~name:"masc_board_post"
        ~description:"Post to the board..."
        ~input_schema:schema_json
        (fun args -> handle_board_post ctx args)
    ]} *)
let oas_tool_of_masc ?descriptor ~name ~description ~input_schema
    handler : Agent_sdk.Tool.t =
  let parameters = params_of_json_schema input_schema in
  let oas_handler json_args =
    to_oas_typed_result (handler json_args)
  in
  Agent_sdk.Tool.create ?descriptor ~name ~description ~parameters oas_handler

let () =
  Runtime_agent.set_oas_tool_of_masc_hook (fun ~name ~description ~input_schema handler ->
    oas_tool_of_masc ~name ~description ~input_schema handler)
