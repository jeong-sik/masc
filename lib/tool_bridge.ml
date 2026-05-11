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

    MASC tools use [(bool * string)] internally (success flag + message).
    OAS uses [Agent_sdk.Types.tool_result = (tool_output, tool_error) Result.t].

    This module converts at the OAS boundary only — internal MASC
    tool handlers keep their existing convention unchanged.

    @since 2.95.1 — result conversion
    @since 2.110.0 — schema conversion + OAS Tool.t creation
    @since 2.??? — externalize large outputs via [Tool_blob_store] *)

(** {1 Tool Output Externalization}

    Tool outputs above [default_externalize_threshold_bytes] are stored
    in the content-addressed blob store ([Tool_blob_store]) and the
    OAS [content] field carries a sentinel marker
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
              match Env_config_core.base_path_opt () with
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

let recoverable_from_json_message msg =
  fst (tool_error_metadata_from_json_message msg)

let to_oas_tool_result ?(recoverable = false) (success, msg)
  : Agent_sdk.Types.tool_result =
  if success then Ok { Agent_sdk.Types.content = maybe_externalize msg }
  else
    let json_recoverable, error_class =
      tool_error_metadata_from_json_message msg
    in
    let recoverable = recoverable || json_recoverable in
    make_tool_error ~recoverable ?error_class (maybe_externalize msg)

let of_oas_tool_result : Agent_sdk.Types.tool_result -> bool * string = function
  | Ok { content } -> (true, content)
  | Error { message; _ } -> (false, message)

(** {1 Schema Conversion}

    Convert MASC JSON Schemas into the narrower OAS [tool_param list]
    representation. Keep this adapter tolerant: MASC schemas may contain
    JSON Schema unions such as ["object"; "string"; "array"], while the
    OAS param model has a single scalar [param_type]. *)

let param_type_of_string = Agent_sdk.Mcp.json_schema_type_to_param_type

let string_of_json_member key json =
  match Yojson.Safe.Util.member key json with
  | `String value -> Some value
  | _ -> None

let type_string_of_schema_property prop =
  match Yojson.Safe.Util.member "type" prop with
  | `String value -> Some value
  | `List values ->
      List.find_map
        (function
          | `String value when not (String.equal value "null") -> Some value
          | _ -> None)
        values
  | _ -> None

let params_of_json_schema schema =
  let open Yojson.Safe.Util in
  (* [required] is conceptually a set (membership semantics, no ordering
     or duplicates) — materialise as Hashtbl so the per-property check
     below is O(1) instead of O(R) per property.  Per-call savings scale
     with property × required-field count; this helper fires from
     [oas_tool_of_masc] per OAS conversion. *)
  let required_set =
    match schema |> member "required" with
    | `List items ->
        let tbl = Hashtbl.create (List.length items) in
        List.iter
          (function
            | `String value -> Hashtbl.replace tbl value ()
            | _ -> ())
          items;
        tbl
    | _ -> Hashtbl.create 0
  in
  match schema |> member "properties" with
  | `Assoc pairs ->
      List.map
        (fun (name, prop) ->
          let param_type =
            prop
            |> type_string_of_schema_property
            |> Option.value ~default:"string"
            |> param_type_of_string
          in
          let description =
            string_of_json_member "description" prop
            |> Option.value ~default:""
          in
          let required = Hashtbl.mem required_set name in
          { Agent_sdk.Types.name = name; description; param_type; required })
        pairs
  | _ -> []

(** {1 OAS Tool.t Creation}

    Create OAS [Tool.t] from MASC schema definition + dispatch handler.
    This allows incremental migration: each tool can be converted independently. *)

let oas_permission_of_masc_tool name =
  let meta = Tool_catalog.metadata name in
  match meta.destructive, meta.readonly with
  | Some true, _ -> Some Agent_sdk.Tool.Destructive
  | _, Some true -> Some Agent_sdk.Tool.ReadOnly
  | _, Some false -> Some Agent_sdk.Tool.Write
  | _ when Tool_dispatch.is_destructive name -> Some Agent_sdk.Tool.Destructive
  | _ when Tool_dispatch.is_read_only name -> Some Agent_sdk.Tool.ReadOnly
  | _ -> None

let oas_descriptor_of_masc_tool name =
  let descriptor_of_permission permission =
    let mutation_class, concurrency_class =
      match permission with
      | Agent_sdk.Tool.ReadOnly ->
          Some "read_only", Some Agent_sdk.Tool.Parallel_read
      | Agent_sdk.Tool.Write ->
          Some "workspace_mutating", Some Agent_sdk.Tool.Sequential_workspace
      | Agent_sdk.Tool.Destructive ->
          Some "external_effect", Some Agent_sdk.Tool.Exclusive_external
    in
    {
      Agent_sdk.Tool.kind = Some "masc";
      mutation_class;
      concurrency_class;
      permission = Some permission;
      shell = None;
      notes = [];
      examples = [];
    }
  in
  Option.map descriptor_of_permission (oas_permission_of_masc_tool name)

let to_oas_typed_result (tr : Tool_result.t) : Agent_sdk.Types.tool_result =
  to_oas_tool_result (tr.success, Tool_result.message tr)

(** Create an OAS [Tool.t] from a MASC tool schema and a typed handler.

    [handler] receives raw JSON args and returns a {!Tool_result.t}.
    The bridge converts the result to OAS [tool_result] automatically.

    {[
      let oas_tool = oas_tool_of_masc
        ~name:"masc_board_post"
        ~description:"Post to the board..."
        ~input_schema:schema_json
        (fun args -> handle_board_post ctx args)
    ]} *)
let oas_tool_of_masc ~name ~description ~input_schema
    handler : Agent_sdk.Tool.t =
  let parameters = params_of_json_schema input_schema in
  let descriptor = oas_descriptor_of_masc_tool name in
  let oas_handler json_args =
    to_oas_typed_result (handler json_args)
  in
  Agent_sdk.Tool.create ?descriptor ~name ~description ~parameters oas_handler
