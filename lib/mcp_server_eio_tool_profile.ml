(** Mcp_server_eio_tool_profile — Tool profile, schema, annotations, and pagination

    Extracted from mcp_server_eio.ml.
    Handles tool listing, profile filtering, annotations, pagination cursors,
    and tool JSON serialization for the MCP protocol.
*)

type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote

let operator_remote_instructions =
  "MASC remote operator profile exposes five operator tools: \
masc_operator_snapshot, masc_operator_digest, masc_operator_action, masc_operator_chat_recovery_resolve, and masc_operator_confirm. \
Read raw state with masc_operator_snapshot first when needed, and prefer masc_operator_digest for intervention-oriented supervision. \
Use masc_operator_action for guided actions only. \
Use masc_operator_chat_recovery_resolve only with the exact receipt_id, revision, and lease_id observed from queue state; it never auto-redelivers. \
When confirm_required=true, you must call masc_operator_confirm with the returned confirm_token before the action executes. \
Do not assume access to any other MASC tool from this endpoint."

let managed_agent_instructions =
  "MASC managed-agent profile exposes the internal agent control surface. \
Prefer canonical task-control tools such as masc_status, masc_tasks, keeper_task_claim, masc_transition, and masc_plan_set_task. \
Do not assume that the public /mcp surface and the managed-agent surface have the same inventory."

let managed_agent_passthrough_tool_names =
  Keeper_tool_surfaces.spawned_agent_public_tool_names

(* O(1) membership view of [managed_agent_passthrough_tool_names].
   Used by [tool_schemas_for_profile Managed_agent] to filter
   ~150 visible schemas per request — replaces a per-schema
   [List.mem] scan over ~20 passthrough names. *)
let managed_agent_passthrough_tool_set : (string, unit) Hashtbl.t =
  let tbl =
    Hashtbl.create (List.length managed_agent_passthrough_tool_names)
  in
  List.iter
    (fun name -> Hashtbl.replace tbl name ())
    managed_agent_passthrough_tool_names;
  tbl

module StringSet = Set_util.StringSet
module StringMap = Set_util.StringMap

let dedupe_tool_schemas_by_name (schemas : Masc_domain.tool_schema list) =
  let _, result =
    List.fold_left
      (fun (seen, acc) (schema : Masc_domain.tool_schema) ->
        if StringSet.mem schema.name seen then (seen, acc)
        else (StringSet.add schema.name seen, schema :: acc))
      (StringSet.empty, []) schemas
  in
  List.rev result

let default_instructions () =
  Printf.sprintf
    "MASC (Multi-Agent Streaming Workspace) enables AI agent collaboration. \
PROJECT: Agents sharing the same base path (.masc/ folder) align together. \
CLUSTER: Set MASC_CLUSTER_NAME for multi-machine workspace (otherwise tool surfaces use the configured cluster/default label). \
READ: use resources/list + resources/read (status/tasks/agents/events/schema) for snapshots. \
WRITE: prefer masc_transition (claim/start/done/cancel/release) with expected_version for CAS. \
WORKFLOW: %s. \
Use masc_heartbeat periodically; use @agent mentions in masc_broadcast. \
Prefer worktrees for parallel work. \
Use masc_tool_help to inspect tool contracts and prefer the smallest useful surface."
    (Tool_contract_guidance.task_lifecycle_workflow ())

let tool_schemas_for_profile ?(include_hidden = false)
    ?(include_agent_internal = false) _state
    profile =
  let schemas =
    match profile with
    | Full ->
        let show_all = include_hidden in
        (* The Agent_internal surface was empty (agent_internal_surface_tools =
           []), so no schema was ever agent-internal.  Surface deleted in the
           surface-cut refactor; [include_agent_internal] no longer adds any
           schema and the per-schema agent-internal branch is unreachable. *)
        let all =
          Config.visible_tool_schemas
            ~include_hidden:(show_all || include_agent_internal)
            ()
          |> dedupe_tool_schemas_by_name
        in
        let full_profile_tools =
          List.filter
            (fun (schema : Masc_domain.tool_schema) ->
              show_all || Tool_catalog.is_public_mcp schema.name)
            all
        in
        full_profile_tools
    | Managed_agent ->
        let passthrough =
          Config.visible_tool_schemas ~include_hidden:true ()
          |> List.filter (fun (schema : Masc_domain.tool_schema) ->
                 Hashtbl.mem managed_agent_passthrough_tool_set schema.name
                 && Tool_catalog.is_visible ~include_hidden:true schema.name)
        in
        dedupe_tool_schemas_by_name
          (Sdk_tool_contract.sdk_tool_schemas @ passthrough)
    | Operator_remote -> Tool_operator.remote_schemas ()
  in
  schemas

let tool_allowed_in_profile ?(internal_keeper_runtime = false) state profile
    tool_name =
  match profile with
  | Full ->
      (* The Agent_internal surface was empty, so no tool was ever
         agent-internal; [internal_keeper_runtime] no longer gates anything.
         Surface deleted in the surface-cut refactor.
         Equivalent to [List.mem tool_name (names from
         visible_tool_schemas ~include_hidden:true)]: that helper
         composes raw schemas → dedupe → canonicalize → filter
         is_visible.  Dedupe and
         canonicalize do not change the name set, so the name set is
         exactly { n | n ∈ raw_all_tool_schemas.names ∧ is_visible n }.
         Two O(1) checks replace ~150 schema canonicalizations + a
         List.mem per dispatch. *)
      ignore (internal_keeper_runtime : bool);
      Config.is_raw_tool_name tool_name
      && Tool_catalog.is_visible ~include_hidden:true tool_name
  | Managed_agent ->
      Option.is_some (Sdk_tool_contract.sdk_binding_by_name tool_name)
      || (tool_schemas_for_profile state Managed_agent
          |> List.exists (fun (schema : Masc_domain.tool_schema) ->
                 String.equal schema.name tool_name))
  | Operator_remote -> List.mem tool_name (Tool_operator.remote_tool_names ())

let tool_annotations_for_profile _profile tool_name =
  let read_only =
    Keeper_tool_descriptor_resolution.capability_has Tool_capability.Read_only tool_name
  in
  let idempotent =
    Keeper_tool_descriptor_resolution.capability_has Tool_capability.Idempotent tool_name
  in
  let fields =
    [ ("readOnlyHint", `Bool read_only) ]
    @ (if idempotent then [ ("idempotentHint", `Bool true) ] else [])
  in
  if fields = [] then None else Some (`Assoc fields)

let metadata_key_present key fields =
  List.exists (fun (existing, _) -> String.equal existing key) fields
;;

let add_metadata_field_if_absent key value fields =
  if metadata_key_present key fields then fields else fields @ [ key, value ]
;;

let descriptor_metadata_fields tool_name fields =
  match Keeper_tool_descriptor_resolution.descriptor_for_tool_name tool_name with
  | None -> fields
  | Some descriptor ->
    fields
    |> add_metadata_field_if_absent "descriptorId" (`String descriptor.id)
    |> add_metadata_field_if_absent "descriptorPublicName" (`String descriptor.public_name)
    |> add_metadata_field_if_absent
         "descriptorCanonicalName"
         (`String descriptor.internal_name)
    |> add_metadata_field_if_absent
         "descriptorExecutor"
         (`String (Keeper_tool_descriptor.executor_to_string descriptor.executor))
    |> add_metadata_field_if_absent
         "descriptorBackend"
         (`String (Keeper_tool_descriptor.backend_to_string descriptor.backend))
    |> add_metadata_field_if_absent
         "descriptorSandbox"
         (`String (Keeper_tool_descriptor.sandbox_to_string descriptor.sandbox))
;;

let label_words_from_identifier ident =
  ident
  |> String.split_on_char '_'
  |> List.filter (fun chunk -> chunk <> "")
  |> List.map (fun word ->
         if String.length word = 0 then word
         else
           String.uppercase_ascii (String.sub word 0 1)
           ^ String.lowercase_ascii
               (String.sub word 1 (String.length word - 1)))

(** Custom human-readable titles for key tools.
    Falls back to auto-generated Title Case when absent. *)
let custom_tool_titles : (string * string) list = [
  (* Workspace lifecycle *)
  ("masc_status", "Project Status");
  ("masc_reset", "Reset Project");
  ("masc_check", "Check Preconditions");
  (* Task management *)
  ("masc_tasks", "List Tasks");
  ("masc_add_task", "Add Task");
  ("masc_batch_add_tasks", "Batch Add Tasks");
  ("masc_transition", "Transition Task State");
  ("masc_update_priority", "Update Task Priority");
  ("masc_task_history", "Task Event History");
  (* Communication *)
  ("masc_broadcast", "Broadcast Message");
  ("masc_messages", "Read Messages");
  (* Planning *)
  ("masc_plan_init", "Initialize Plan");
  ("masc_plan_get", "Get Plan");
  ("masc_plan_update", "Update Plan");
  ("masc_plan_set_task", "Bind Current Task");
  ("masc_plan_get_task", "Get Current Task");
  ("masc_plan_clear_task", "Clear Current Task");
  ("masc_note_add", "Add Note");
  ("masc_deliver", "Deliver Result");
  (* Heartbeat *)
  ("masc_heartbeat", "Send Heartbeat");
  (* Operations *)
  ("masc_operator_snapshot", "Operator Snapshot");
  ("masc_operator_digest", "Operator Digest");
  ("masc_operator_action", "Operator Action");
  ("masc_operator_chat_recovery_resolve", "Resolve Chat Recovery");
  ("masc_operator_confirm", "Operator Confirm");
  (* SDK projections *)
]

let custom_title_table : string StringMap.t =
  List.fold_left
    (fun acc (name, title) -> StringMap.add name title acc)
    StringMap.empty custom_tool_titles

let tool_title_of_name name =
  match StringMap.find_opt name custom_title_table with
  | Some title -> title
  | None ->
    let trimmed =
      if String.length name > 5 && String.starts_with ~prefix:"masc_" name then
        String.sub name 5 (String.length name - 5)
      else
        name
    in
    String.concat " " (label_words_from_identifier trimmed)

let tool_icons_for_name name =
  let icon =
    if Keeper_tool_descriptor_resolution.capability_has Tool_capability.Read_only name then
      Mcp_server.themed_icon ~label:"RD" ~bg:"#0F766E" ~fg:"#F0FDFA"
    else
      Mcp_server.themed_icon ~label:"WR" ~bg:"#9A3412" ~fg:"#FFF7ED"
  in
  [ icon ]

let maybe_assoc_field name = function
  | Some value -> [ (name, value) ]
  | None -> []

let tool_output_schema_field _ =
  (* Public MCP tools still return text-first envelopes and only some handlers
     opportunistically emit structuredContent. Advertising outputSchema before
     structuredContent is guaranteed breaks strict clients such as Anthropic/FastMCP,
     which reject the tool result as malformed. Keep outputSchema disabled until
     the call path can produce typed payloads from the handler itself. *)
  None

let tool_json_for_profile ?usage_summary profile (schema : Masc_domain.tool_schema) =
  let metadata_fields =
    Tool_catalog.metadata_to_fields schema.name
    |> descriptor_metadata_fields schema.name
  in
  let base =
    [
      ("name", `String schema.name);
      ("title", `String (tool_title_of_name schema.name));
      ("description", `String schema.description);
      ( "icons",
        `List
          (List.map Mcp_server.icon_to_json (tool_icons_for_name schema.name)) );
      ("inputSchema", schema.input_schema);
    ]
    @ metadata_fields
    @ maybe_assoc_field "outputSchema" (tool_output_schema_field schema.name)
    @ maybe_assoc_field "annotations" (tool_annotations_for_profile profile schema.name)
    @
    (match usage_summary with
    | Some summary -> Telemetry_eio.tool_usage_fields summary schema.name
    | None -> [])
  in
  `Assoc base

(** {1 Pagination} *)

type cursor_params = { cursor : string option }

type tools_list_params = {
  names : string list option;
  include_hidden : bool;
  include_usage : bool;
  cursor : string option;
}

open Result.Syntax

let strict_assoc_params params =
  match params with
  | None -> Ok []
  | Some (`Assoc fields) -> Ok fields
  | Some other ->
      Error
        (Printf.sprintf "Invalid params: expected object (received %s)"
           (Json_util.kind_name other))

let cursor_param payload =
  match Json_util.assoc_member_opt "cursor" payload with
  | None -> Ok None
  | Some (`String value) ->
      let trimmed = String.trim value in
      if trimmed = "" then
        Error "Invalid params: cursor must not be empty"
      else
        Ok (Some trimmed)
  | Some other ->
      Error
        (Printf.sprintf "Invalid params: cursor must be a string (received %s)"
           (Json_util.kind_name other))

let bool_param payload key =
  match Json_util.assoc_member_opt key payload with
  | None -> Ok false
  | Some (`Bool value) -> Ok value
  | Some other ->
      Error
        (Printf.sprintf "Invalid params: %s must be a boolean (received %s)"
           key (Json_util.kind_name other))

let decode_cursor_offset = function
  | None -> Ok 0
  | Some raw -> (
      match int_of_string_opt raw with
      | Some offset when offset >= 0 -> Ok offset
      | Some offset ->
          Error
            (Printf.sprintf
               "Invalid params: cursor offset must be non-negative \
                (parsed %d from %S)"
               offset raw)
      | None ->
          Error
            (Printf.sprintf
               "Invalid params: cursor must be a non-negative integer \
                string (could not parse %S as an integer)"
               raw))

let rec drop_list n = function
  | xs when n <= 0 -> xs
  | [] -> []
  | _ :: rest -> drop_list (n - 1) rest

let rec take_list n xs =
  if n <= 0 then
    []
  else
    match xs with
    | [] -> []
    | x :: rest -> x :: take_list (n - 1) rest

let paginate_json_items ?(page_size = 128) ~field_name items cursor =
  match decode_cursor_offset cursor with
  | Error msg -> Error msg
  | Ok offset ->
      let total = List.length items in
      let page = items |> drop_list offset |> take_list page_size in
      let next_offset = offset + List.length page in
      let fields =
        [ (field_name, `List page) ]
        @
        if next_offset < total then
          [ ("nextCursor", `String (string_of_int next_offset)) ]
        else
          []
      in
      Ok (`Assoc fields)

let cursor_only_params params =
  match params with
  | None -> Ok None
  | Some (`Assoc _ as payload) -> cursor_param payload
  | Some other ->
      Error
        (Printf.sprintf "Invalid params: expected object (received %s)"
           (Json_util.kind_name other))

let validate_optional_meta payload =
  match Json_util.assoc_member_opt "_meta" payload with
  | None
  | Some (`Assoc _) -> Ok ()
  | Some other ->
      Error
        (Printf.sprintf "Invalid params: _meta must be an object (received %s)"
           (Json_util.kind_name other))

let requested_tool_list_params params =
  let* fields = strict_assoc_params params in
  let allowed =
    [ "_meta"; "names"; "include_hidden"; "include_usage"; "cursor" ]
  in
  let unknown =
    fields
    |> List.filter_map (fun (key, _value) ->
           if List.mem key allowed then None else Some key)
  in
  if unknown <> [] then
    Error
      (Printf.sprintf "Invalid params: unsupported field(s): %s"
         (String.concat ", " unknown))
  else
    let payload = `Assoc fields in
    let* () = validate_optional_meta payload in
    let* names =
      match Json_util.assoc_member_opt "names" payload with
      | None -> Ok None
      | Some (`List items) ->
          items
          |> List.fold_left
               (fun acc item ->
                 match (acc, item) with
                 | Error _ as err, _ -> err
                 | Ok names, `String value -> Ok (value :: names)
                 | Ok _, bad ->
                     Error
                       (Printf.sprintf
                          "Invalid params: names must be an array of strings \
                           (received %s element)"
                          (Json_util.kind_name bad)))
               (Ok [])
          |> Result.map (fun names -> Some (List.rev names))
      | Some other ->
          Error
            (Printf.sprintf
               "Invalid params: names must be an array of strings (received %s)"
               (Json_util.kind_name other))
    in
    let* cursor = cursor_param payload in
    let* include_hidden = bool_param payload "include_hidden" in
    let* include_usage = bool_param payload "include_usage" in
    Ok
      {
        names;
        include_hidden;
        include_usage;
        cursor;
      }

let parse_cursor_only_params params =
  let* fields = strict_assoc_params params in
  let allowed = [ "_meta"; "cursor" ] in
  let unknown =
    fields
    |> List.filter_map (fun (key, _value) ->
           if List.mem key allowed then None else Some key)
  in
  if unknown <> [] then
    Error
      (Printf.sprintf "Invalid params: unsupported field(s): %s"
         (String.concat ", " unknown))
  else
    let payload = `Assoc fields in
    let* () = validate_optional_meta payload in
    match Json_util.assoc_member_opt "cursor" payload with
    | None -> Ok { cursor = None }
    | Some (`String cursor) -> Ok { cursor = Some cursor }
    | Some other ->
        Error
          (Printf.sprintf
             "Invalid params: cursor must be a string (received %s)"
             (Json_util.kind_name other))

let list_page_size () = Env_config.Tools.list_page_size ()

let encode_cursor ~kind offset =
  Base64.encode_string (Printf.sprintf "%s:%d" kind offset)

let decode_cursor ~kind cursor =
  match Base64.decode cursor with
  | Ok decoded ->
      let prefix = kind ^ ":" in
      let prefix_len = String.length prefix in
      if String.starts_with decoded ~prefix
      then
        int_of_string_opt
          (String.sub decoded prefix_len (String.length decoded - prefix_len))
      else
        None
  | Error _ -> None

let page_items_with_cursor ~kind items cursor =
  let page_size = list_page_size () in
  let offset =
    match cursor with
    | None -> Ok 0
    | Some encoded -> (
        match decode_cursor ~kind encoded with
        | Some value when value >= 0 -> Ok value
        | Some value ->
            Error
              (Printf.sprintf
                 "Invalid params: cursor decoded to negative offset %d \
                  (kind=%S, encoded=%S)"
                 value kind encoded)
        | None ->
            (* [decode_cursor] returns [None] for three different
               failure modes (base64 decode failed / kind-prefix
               mismatch / int_of_string_opt failed).  Promoting it to
               [(int, string) result] is a separate change because it
               is the second [decode_cursor] in the tree (the other
               lives in [graphql_api]) and the [int option] contract
               is exercised by both. *)
            Error
              (Printf.sprintf
                 "Invalid params: cursor %S could not be decoded \
                  (expected base64-encoded \"%s:<non-negative int>\")"
                 encoded kind))
  in
  let rec drop n xs =
    match (n, xs) with
    | 0, rest -> rest
    | _, [] -> []
    | n, _ :: rest -> drop (n - 1) rest
  in
  let rec take n xs =
    match (n, xs) with
    | 0, _ | _, [] -> []
    | n, x :: rest -> x :: take (n - 1) rest
  in
  let count = List.length items in
  let* offset = offset in
  let offset = min offset count in
  let page = items |> drop offset |> take page_size in
  let next_offset = offset + List.length page in
  let next_cursor =
    if next_offset < count then Some (encode_cursor ~kind next_offset) else None
  in
  Ok (page, next_cursor)
