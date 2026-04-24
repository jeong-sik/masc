(** OAS boundary adapter for tool results, schemas, and tool definitions.

    MASC tools use [(bool * string)] internally (success flag + message).
    OAS uses [Oas.Types.tool_result = (tool_output, tool_error) result].

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
      (match int_of_string_opt (String.trim s) with
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

let make_tool_error ?(recoverable = false) message : Oas.Types.tool_result =
  Error { Oas.Types.message; recoverable; error_class = None }

let to_oas_tool_result ?(recoverable = false) (success, msg)
  : Oas.Types.tool_result =
  if success then Ok { Oas.Types.content = maybe_externalize msg }
  else make_tool_error ~recoverable (maybe_externalize msg)

let of_oas_tool_result : Oas.Types.tool_result -> bool * string = function
  | Ok { content } -> (true, content)
  | Error { message; _ } -> (false, message)

(** {1 Schema Conversion}

    Delegates to [Oas.Mcp.json_schema_to_params] — the canonical
    JSON Schema to OAS [tool_param list] conversion.

    @since 2.221.0 — delegates to OAS Mcp module (removes 40-line duplicate) *)

let param_type_of_string = Oas.Mcp.json_schema_type_to_param_type

let params_of_json_schema = Oas.Mcp.json_schema_to_params

(** {1 OAS Tool.t Creation}

    Create OAS [Tool.t] from MASC schema definition + dispatch handler.
    This allows incremental migration: each tool can be converted independently. *)

let oas_permission_of_masc_tool name =
  let meta = Tool_catalog.metadata name in
  match meta.destructive, meta.readonly with
  | Some true, _ -> Some Oas.Tool.Destructive
  | _, Some true -> Some Oas.Tool.ReadOnly
  | _, Some false -> Some Oas.Tool.Write
  | _ when Tool_dispatch.is_destructive name -> Some Oas.Tool.Destructive
  | _ when Tool_dispatch.is_read_only name -> Some Oas.Tool.ReadOnly
  | _ -> None

let oas_descriptor_of_masc_tool name =
  let descriptor_of_permission permission =
    let mutation_class, concurrency_class =
      match permission with
      | Oas.Tool.ReadOnly ->
          Some "read_only", Some Oas.Tool.Parallel_read
      | Oas.Tool.Write ->
          Some "workspace_mutating", Some Oas.Tool.Sequential_workspace
      | Oas.Tool.Destructive ->
          Some "external_effect", Some Oas.Tool.Exclusive_external
    in
    {
      Oas.Tool.kind = Some "masc";
      mutation_class;
      concurrency_class;
      permission = Some permission;
      shell = None;
      notes = [];
      examples = [];
    }
  in
  Option.map descriptor_of_permission (oas_permission_of_masc_tool name)

(** Create an OAS [Tool.t] from a MASC tool schema and a handler function.

    [handler] receives raw JSON args and returns MASC [(bool * string)].
    The bridge converts the result to OAS [tool_result] automatically.

    {[
      let oas_tool = oas_tool_of_masc
        ~name:"masc_board_post"
        ~description:"Post to the board..."
        ~input_schema:schema_json
        (fun args -> handle_board_post ctx args)
    ]} *)
let oas_tool_of_masc ~name ~description ~input_schema
    handler : Oas.Tool.t =
  let parameters = params_of_json_schema input_schema in
  let descriptor = oas_descriptor_of_masc_tool name in
  let oas_handler json_args =
    let success, msg = handler json_args in
    to_oas_tool_result (success, msg)
  in
  Oas.Tool.create ?descriptor ~name ~description ~parameters oas_handler
