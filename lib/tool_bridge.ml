module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
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

(* This path is exercised both under Eio and from tests/module-init code, so a
   cross-context Atomic+Stdlib.Mutex memo is safer than Stdlib.Lazy.force. *)
let blob_store_cache : Tool_blob_store.t option option Atomic.t = Atomic.make None
let blob_store_cache_mu = Mutex.create ()

let resolve_blob_store () =
  match Atomic.get blob_store_cache with
  | Some store -> store
  | None ->
      Mutex.protect blob_store_cache_mu (fun () ->
        match Atomic.get blob_store_cache with
        | Some store -> store
        | None ->
            let store =
              match (Host_config.from_env ()).base_path with
              | None -> None
              | Some base_path -> Some (Tool_blob_store.create ~base_path)
            in
            Atomic.set blob_store_cache (Some store);
            store)

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
          | _ -> msg)

let success_result_preserves_full_content tr =
  match Tool_name.of_string (Tool_result.tool_name tr) with
  | Some
      (Tool_name.Masc
         (Tool_name.Masc.Domain
            (Tool_name.Domain_tool.Board Tool_name.Board_name.Board_post_get))) ->
    true
  | _ -> false

let success_content_for_oas tr =
  let msg = Tool_result.message tr in
  if success_result_preserves_full_content tr
  then msg
  else maybe_externalize msg

(** {1 Result Conversion} *)

let make_tool_error ?(recoverable = false) ?error_class message
  : Agent_sdk.Types.tool_result =
  Error { Agent_sdk.Types.message; recoverable; error_class }

let tool_error_class_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "" -> None
  | "transient" | "transient_mutex_contention" -> Some Agent_sdk.Types.Transient
  | "deterministic" | "validation_error" -> Some Agent_sdk.Types.Deterministic
  | "unknown" -> Some Agent_sdk.Types.Unknown
  | _ -> Some Agent_sdk.Types.Unknown

let tool_error_metadata_from_json_message msg =
  try
    match Yojson.Safe.from_string msg with
    | `Assoc fields ->
        let recoverable =
          match List.assoc_opt "recoverable" fields with
          | Some (`Bool true) -> true
          | _ -> false
        in
        let error_class =
          match List.assoc_opt "error_class" fields with
          | Some (`String s) -> tool_error_class_of_string s
          | _ -> None
        in
        (recoverable, error_class)
    | _ -> (false, None)
  with Yojson.Json_error _ -> (false, None)

let oas_error_class_of_tool_failure_class = function
  | Tool_result.Transient_error -> Some Agent_sdk.Types.Transient
  | Tool_result.Policy_rejection
  | Tool_result.Workflow_rejection ->
    Some Agent_sdk.Types.Deterministic
  | Tool_result.Runtime_failure -> Some Agent_sdk.Types.Unknown
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

let oas_permission_of_masc_tool name =
  let meta = Tool_catalog.metadata name in
  match meta.destructive, meta.readonly with
  | Some true, _ -> Some Agent_sdk.Tool.Destructive
  | _, Some true -> Some Agent_sdk.Tool.ReadOnly
  | _, Some false -> Some Agent_sdk.Tool.Write
  | _ when Tool_capability.has Tool_capability.Destructive name ->
    Some Agent_sdk.Tool.Destructive
  | _ when Tool_capability.has Tool_capability.Read_only name ->
    Some Agent_sdk.Tool.ReadOnly
  | _ -> None

(** Tools that perform real external network I/O (not local file reads) should
    never be marked [Parallel_read], even when read-only. Running multiple web
    searches or fetches concurrently would violate provider rate limits and
    abuse external services. Keep this list in sync with
    [Keeper_tool_descriptor.public_descriptors] web aliases and their internal
    names. *)
let is_external_network_tool name =
  List.mem name [ "masc_web_search"; "masc_web_fetch"; "WebSearch"; "WebFetch" ]
;;

let oas_descriptor_of_masc_tool name =
  let permission =
    match oas_permission_of_masc_tool name with
    | Some _ as p -> p
    | None ->
      (* Public aliases such as WebSearch/WebFetch do not appear in
         [Tool_catalog] metadata, but they still need a descriptor so the
         OAS runtime does not default them to Sequential_workspace and so
         they are never classified as Parallel_read. *)
      if is_external_network_tool name
      then Some Agent_sdk.Tool.ReadOnly
      else None
  in
  let descriptor_of_permission perm =
    let mutation_class, concurrency_class =
      match perm with
      | Agent_sdk.Tool.ReadOnly when is_external_network_tool name ->
        (* External read-only tools are not workspace-parallel: they hit
           rate-limited remote APIs. Use [Exclusive_external] so the OAS
           runtime runs them in isolation and flushes any parallel-read batch
           before and after. *)
        Some Agent_sdk.Tool.External_effect, Some Agent_sdk.Tool.Exclusive_external
      | Agent_sdk.Tool.ReadOnly ->
        Some Agent_sdk.Tool.Read_only, Some Agent_sdk.Tool.Parallel_read
      | Agent_sdk.Tool.Write ->
        Some Agent_sdk.Tool.Workspace_mutating, Some Agent_sdk.Tool.Sequential_workspace
      | Agent_sdk.Tool.Destructive ->
        Some Agent_sdk.Tool.External_effect, Some Agent_sdk.Tool.Exclusive_external
    in
    {
      Agent_sdk.Tool.kind = Some "masc";
      mutation_class;
      concurrency_class;
      permission = Some perm;
      evidence_role = None;
      shell = None;
      notes = [];
      examples = [];
    }
  in
  Option.map descriptor_of_permission permission

let to_oas_typed_result (tr : Tool_result.result) : Agent_sdk.Types.tool_result =
  if Tool_result.is_success tr
  then Ok { Agent_sdk.Types.content = success_content_for_oas tr; _meta = None }
  else (
    let msg = Tool_result.message tr in
    let json_recoverable, json_error_class =
      tool_error_metadata_from_json_message msg
    in
    let recoverable, error_class =
      match Tool_result.failure_class tr with
      | Some Tool_result.Runtime_failure
        when json_recoverable || Option.is_some json_error_class ->
        json_recoverable, json_error_class
      | Some cls ->
        (Tool_result.is_retryable cls, oas_error_class_of_tool_failure_class cls)
      | None -> json_recoverable, json_error_class
    in
    make_tool_error ~recoverable ?error_class (maybe_externalize msg))

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
  let descriptor =
    match descriptor with
    | Some _ -> descriptor
    | None -> oas_descriptor_of_masc_tool name
  in
  let oas_handler json_args =
    to_oas_typed_result (handler json_args)
  in
  Agent_sdk.Tool.create ?descriptor ~name ~description ~parameters oas_handler

let () =
  Runtime_agent.set_oas_tool_of_masc_hook (fun ~name ~description ~input_schema handler ->
    oas_tool_of_masc ~name ~description ~input_schema handler)
