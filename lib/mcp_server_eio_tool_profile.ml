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
  "MASC remote operator profile exposes only four control-plane tools: \
masc_operator_snapshot, masc_operator_digest, masc_operator_action, and masc_operator_confirm. \
Read raw state with masc_operator_snapshot first when needed, and prefer masc_operator_digest for intervention-oriented supervision. \
Use masc_operator_action for guided actions only. \
When confirm_required=true, you must call masc_operator_confirm with the returned confirm_token before the action executes. \
Do not assume access to any other MASC tool from this endpoint."

let managed_agent_instructions =
  "MASC managed-agent profile exposes the internal agent control surface. \
Prefer canonical task-control tools such as masc_status, masc_tasks, masc_claim_next, masc_transition, and masc_plan_set_task. \
Managed aliases that remain listed on this endpoint are compatibility helpers, not the recommended control plane. \
Do not assume that the public /mcp surface and the managed-agent surface have the same inventory."

let managed_agent_passthrough_tool_names =
  Agent_tool_surfaces.spawned_agent_public_tool_names
  |> List.filter (fun name ->
         not
           (List.mem name
             [
                "masc_status";
                "masc_tasks";
                "masc_transition";
                "masc_a2a_delegate";
              ]))

module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

let dedupe_tool_schemas_by_name (schemas : Types.tool_schema list) =
  let _, result =
    List.fold_left
      (fun (seen, acc) (schema : Types.tool_schema) ->
        if StringSet.mem schema.name seen then (seen, acc)
        else (StringSet.add schema.name seen, schema :: acc))
      (StringSet.empty, []) schemas
  in
  List.rev result

let default_instructions =
  "MASC (Multi-Agent Streaming Coordination) enables AI agent collaboration. \
NAMESPACE: Agents sharing the same base path (.masc/ folder) coordinate together. \
CLUSTER: Set MASC_CLUSTER_NAME for multi-machine coordination (otherwise tool surfaces use the configured cluster/default label). \
READ: use resources/list + resources/read (status/tasks/agents/events/schema) for snapshots. \
WRITE: prefer masc_transition (claim/start/done/cancel/release) with expected_version for CAS. \
WORKFLOW: masc_status → masc_transition(claim) → masc_worktree_create (isolation) → work → masc_transition(done). \
Use masc_heartbeat periodically; use @agent mentions in masc_broadcast. \
Prefer worktrees for parallel work. \
Use masc_tool_help to inspect tool contracts and prefer the smallest useful surface."

let tool_schemas_for_profile ?(include_hidden = false) ?(include_deprecated = false)
    _state profile =
  let schemas =
    match profile with
    | Full ->
        let show_all = include_hidden || Tool_catalog.full_surface_override () in
        let all =
          Config.visible_tool_schemas
            ~include_hidden:show_all ~include_deprecated ()
        in
        let without_internal =
          List.filter
            (fun (schema : Types.tool_schema) ->
              not (Tool_catalog.is_on_surface Tool_catalog.Keeper_internal schema.name)
              && not (Tool_catalog.is_on_surface Tool_catalog.System_internal schema.name))
            all
        in
        if show_all then without_internal
        else
          List.filter
            (fun (schema : Types.tool_schema) ->
              Tool_catalog.is_public_mcp schema.name)
            without_internal
    | Managed_agent ->
        let passthrough =
          Config.visible_tool_schemas ~include_hidden:true ~include_deprecated:false ()
          |> List.filter (fun (schema : Types.tool_schema) ->
                 List.mem schema.name managed_agent_passthrough_tool_names
                 && Tool_catalog.is_visible ~include_hidden:true schema.name)
        in
        dedupe_tool_schemas_by_name
          (Sdk_tool_contract.sdk_tool_schemas @ passthrough)
    | Operator_remote -> Tool_operator.remote_schemas
  in
  schemas

let tool_allowed_in_profile state profile tool_name =
  match profile with
  | Full ->
      if Tool_catalog.is_on_surface Tool_catalog.Keeper_internal tool_name then
        false
      else
        let allowed_schema_names =
          Config.visible_tool_schemas ~include_hidden:true ~include_deprecated:true ()
          |> List.map (fun (schema : Types.tool_schema) -> schema.name)
        in
        List.mem tool_name allowed_schema_names
  | Managed_agent ->
      Option.is_some (Sdk_tool_contract.sdk_binding_by_name tool_name)
      || (tool_schemas_for_profile state Managed_agent
          |> List.exists (fun (schema : Types.tool_schema) ->
                 String.equal schema.name tool_name))
  | Operator_remote -> List.mem tool_name Tool_operator.remote_tool_names

let tool_annotations_for_profile _profile tool_name =
  let meta = Tool_catalog.metadata tool_name in
  let read_only =
    match meta.readonly with
    | Some v -> v
    | None -> Tool_dispatch.is_read_only tool_name
  in
  let destructive =
    match meta.destructive with
    | Some v -> v
    | None -> Tool_dispatch.is_destructive tool_name
  in
  let idempotent =
    match meta.idempotent with
    | Some v -> v
    | None -> Tool_dispatch.is_idempotent tool_name || read_only
  in
  let is_deprecated = meta.lifecycle = Tool_catalog.Deprecated in
  let fields =
    [ ("readOnlyHint", `Bool read_only) ]
    @ (if destructive then [ ("destructiveHint", `Bool true) ] else [])
    @ (if idempotent then [ ("idempotentHint", `Bool true) ] else [])
    @ (if is_deprecated then [ ("deprecated", `Bool true) ] else [])
    @ (match meta.replacement with
       | Some r when is_deprecated -> [ ("successor", `String r) ]
       | _ -> [])
    @ (match meta.reason with
       | Some r when is_deprecated -> [ ("deprecationReason", `String r) ]
       | _ -> [])
  in
  if fields = [] then None else Some (`Assoc fields)

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
  (* Room lifecycle *)
  ("masc_init", "Initialize Project Scope");
  ("masc_join", "Join Namespace");
  ("masc_leave", "Leave Namespace");
  ("masc_status", "Namespace Status");
  ("masc_reset", "Reset Namespace");
  ("masc_who", "List Online Agents");
  ("masc_check", "Check Preconditions");
  ("masc_workflow_guide", "Workflow Guide");
  (* Task management *)
  ("masc_tasks", "List Tasks");
  ("masc_add_task", "Add Task");
  ("masc_batch_add_tasks", "Batch Add Tasks");
  ("masc_transition", "Transition Task State");
  ("masc_claim_next", "Claim Next Task");
  ("masc_update_priority", "Update Task Priority");
  ("masc_task_history", "Task Event History");
  (* Communication *)
  ("masc_broadcast", "Broadcast Message");
  ("masc_messages", "Read Messages");
  ("masc_a2a_delegate", "Agent-to-Agent Delegate");
  ("masc_a2a_subscribe", "Subscribe to Agent Events");
  (* Planning *)
  ("masc_plan_init", "Initialize Plan");
  ("masc_plan_get", "Get Plan");
  ("masc_plan_update", "Update Plan");
  ("masc_plan_set_task", "Bind Current Task");
  ("masc_plan_get_task", "Get Current Task");
  ("masc_plan_clear_task", "Clear Current Task");
  ("masc_note_add", "Add Note");
  ("masc_deliver", "Deliver Result");
  ("masc_error_add", "Record Error");
  ("masc_error_resolve", "Resolve Error");
  (* Agents *)
  ("masc_agents", "List Agent Details");
  ("masc_agent_update", "Update Agent Profile");
  ("masc_register_capabilities", "Register Agent Capabilities");
  ("masc_find_by_capability", "Find Agent by Capability");
  (* Heartbeat *)
  ("masc_heartbeat", "Send Heartbeat");
  ("masc_heartbeat_start", "Start Auto-Heartbeat");
  ("masc_heartbeat_stop", "Stop Auto-Heartbeat");
  ("masc_heartbeat_list", "List Active Heartbeats");
  (* Operations *)
  ("masc_operator_snapshot", "Operator Snapshot");
  ("masc_operator_digest", "Operator Digest");
  ("masc_operator_action", "Operator Action");
  ("masc_operator_confirm", "Operator Confirm");
  (* Command plane *)
  ("masc_operation_start", "Start Operation");
  ("masc_operation_status", "Operation Status");
  ("masc_operation_stop", "Stop Operation");
  ("masc_operation_pause", "Pause Operation");
  ("masc_operation_resume", "Resume Operation");
  ("masc_operation_finalize", "Finalize Operation");
  ("masc_operation_checkpoint", "Operation Checkpoint");
  (* Worktree *)
  ("masc_worktree_create", "Create Worktree");
  ("masc_worktree_status", "Worktree Status");
  ("masc_worktree_remove", "Remove Worktree");
  (* Keeper *)
  ("masc_keeper_up", "Start Keeper");
  ("masc_keeper_msg", "Send Keeper Message");
  ("masc_keeper_repair", "Keeper Repair");
  ("masc_keeper_reconcile", "Keeper Reconcile");
  ("masc_keeper_status", "Keeper Status");
  ("masc_keeper_down", "Stop Keeper");
  ("masc_keeper_create_from_persona", "Create Keeper from Persona");
  (* SDK aliases *)
  ("masc_list_tasks", "List Tasks");
  ("masc_room_status", "Namespace Status");
  ("masc_claim_task", "Claim Task");
  ("masc_set_current_task", "Bind Current Task");
  ("masc_complete_task", "Complete Task");
  ("masc_release_task", "Release Task");
  ("masc_cancel_task", "Cancel Task");
  ("masc_claim_next", "Claim Next Task");
  (* Misc *)
  ("masc_poll_events", "Poll Events");
  ("masc_cleanup_zombies", "Clean Up Zombie Agents");
  ("masc_dispatch_plan", "Dispatch Plan");
  ("masc_dispatch_assign", "Dispatch Assign");
  ("masc_compact_context", "Compact Context");
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
      if String.length name > 5 && String.sub name 0 5 = "masc_" then
        String.sub name 5 (String.length name - 5)
      else
        name
    in
    String.concat " " (label_words_from_identifier trimmed)

let tool_icons_for_name name =
  let icon =
    if Tool_dispatch.is_read_only name then
      Mcp_server.themed_icon ~label:"RD" ~bg:"#0F766E" ~fg:"#F0FDFA"
    else
      Mcp_server.themed_icon ~label:"WR" ~bg:"#9A3412" ~fg:"#FFF7ED"
  in
  [ icon ]

let maybe_assoc_field name = function
  | Some value -> [ (name, value) ]
  | None -> []

let permissive_object_schema properties =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc properties);
      ("additionalProperties", `Bool true);
    ]

let string_schema = `Assoc [ ("type", `String "string") ]
let int_schema = `Assoc [ ("type", `String "integer") ]
let bool_schema = `Assoc [ ("type", `String "boolean") ]
let array_schema = `Assoc [ ("type", `String "array") ]
let object_schema = `Assoc [ ("type", `String "object") ]

let tool_output_schema_field = function
  | "masc_status" ->
      Some
        (permissive_object_schema
           [
             ("cluster", string_schema);
             ("project", string_schema);
             ("room", string_schema);
             ("path", string_schema);
             ("agents", array_schema);
             ("tasks", array_schema);
             ("active_task_count", int_schema);
             ("done_count", int_schema);
             ("cancelled_count", int_schema);
             ("total_task_count", int_schema);
             ("message_count", int_schema);
           ])
  | "masc_tasks" | "masc_list_tasks" ->
      Some
        (permissive_object_schema
           [
             ("tasks", `Assoc [
               ("type", `String "array");
               ("items", permissive_object_schema [
                 ("id", string_schema);
                 ("title", string_schema);
                 ("status", string_schema);
                 ("assignee", string_schema);
                 ("priority", int_schema);
               ]);
             ]);
             ("total", int_schema);
           ])
  | "masc_agents" ->
      Some
        (permissive_object_schema
           [
             ("agents", `Assoc [
               ("type", `String "array");
               ("items", permissive_object_schema [
                 ("name", string_schema);
                 ("status", string_schema);
                 ("last_heartbeat", string_schema);
               ]);
             ]);
           ])
  | "masc_heartbeat" ->
      Some
        (permissive_object_schema
           [
             ("agent_name", string_schema);
             ("timestamp", string_schema);
             ("success", bool_schema);
           ])
  | "masc_heartbeat_list" ->
      Some
        (permissive_object_schema
           [
             ("heartbeats", `Assoc [
               ("type", `String "array");
               ("items", permissive_object_schema [
                 ("id", string_schema);
                 ("agent_name", string_schema);
                 ("interval", int_schema);
                 ("message", string_schema);
                 ("uptime_s", int_schema);
               ]);
             ]);
           ])
  | "masc_plan_get" ->
      Some
        (permissive_object_schema
           [
             ("task_id", string_schema);
             ("plan", string_schema);
             ("notes", string_schema);
             ("deliverable", string_schema);
           ])
  | "masc_plan_get_task" ->
      Some
        (permissive_object_schema
           [
             ("task_id", string_schema);
           ])
  | "masc_who" | "masc_room_status" ->
      Some
        (permissive_object_schema
           [
             ("agents", array_schema);
             ("count", int_schema);
           ])
  | "masc_operator_digest" ->
      Some
        (permissive_object_schema
           [
             ("target_type", string_schema);
             ("target_id", string_schema);
             ("health", string_schema);
             ("attention_items", array_schema);
             ("recommended_actions", array_schema);
           ])
  | "masc_operator_snapshot" ->
      Some
        (permissive_object_schema
           [
             ("room", object_schema);
             ("agents", array_schema);
             ("tasks", array_schema);
             ("operations", array_schema);
           ])
  | "masc_operation_status" ->
      Some
        (permissive_object_schema
           [
             ("operation_id", string_schema);
             ("status", string_schema);
             ("progress", object_schema);
           ])
  | "masc_check" ->
      Some
        (permissive_object_schema
           [
             ("assertions", `Assoc [
               ("type", `String "array");
               ("items", permissive_object_schema [
                 ("name", string_schema);
                 ("passed", bool_schema);
                 ("hint", string_schema);
               ]);
             ]);
             ("all_passed", bool_schema);
           ])
  | "masc_keeper_status" ->
      Some
        (permissive_object_schema
           [
             ("keeper_id", string_schema);
             ("status", string_schema);
             ("uptime_s", int_schema);
           ])
  | "masc_task_history" ->
      Some
        (permissive_object_schema
           [
             ("task_id", string_schema);
             ("events", array_schema);
           ])
  | _ -> None

let tool_json_for_profile ?usage_summary profile (schema : Types.tool_schema) =
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
    @ Tool_catalog.metadata_to_fields schema.name
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
  include_deprecated : bool;
  include_usage : bool;
  cursor : string option;
}

open Result_syntax

let strict_assoc_params params =
  match params with
  | None -> Ok []
  | Some (`Assoc fields) -> Ok fields
  | Some _ -> Error "Invalid params: expected object"

let cursor_param payload =
  let open Yojson.Safe.Util in
  match payload |> member "cursor" with
  | `Null -> Ok None
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then
        Error "Invalid params: cursor must not be empty"
      else
        Ok (Some trimmed)
  | _ -> Error "Invalid params: cursor must be a string"

let bool_param payload key =
  let open Yojson.Safe.Util in
  match payload |> member key with
  | `Null -> Ok false
  | `Bool value -> Ok value
  | _ -> Error (Printf.sprintf "Invalid params: %s must be a boolean" key)

let decode_cursor_offset = function
  | None -> Ok 0
  | Some raw -> (
      match int_of_string_opt raw with
      | Some offset when offset >= 0 -> Ok offset
      | _ -> Error "Invalid params: cursor must be a non-negative integer string")

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
  | Some _ -> Error "Invalid params: expected object"

let validate_optional_meta payload =
  match Yojson.Safe.Util.member "_meta" payload with
  | `Null
  | `Assoc _ -> Ok ()
  | _ -> Error "Invalid params: _meta must be an object"

let requested_tool_list_params params =
  let open Yojson.Safe.Util in
  let* fields = strict_assoc_params params in
  let allowed =
    [ "_meta"; "names"; "include_hidden"; "include_deprecated"; "include_usage";
      "cursor" ]
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
      match payload |> member "names" with
      | `Null -> Ok None
      | `List items ->
          items
          |> List.fold_left
               (fun acc item ->
                 match (acc, item) with
                 | Error _ as err, _ -> err
                 | Ok names, `String value -> Ok (value :: names)
                 | Ok _, _ ->
                     Error "Invalid params: names must be an array of strings")
               (Ok [])
          |> Result.map (fun names -> Some (List.rev names))
      | _ -> Error "Invalid params: names must be an array of strings"
    in
    let* cursor = cursor_param payload in
    let* include_hidden = bool_param payload "include_hidden" in
    let* include_deprecated = bool_param payload "include_deprecated" in
    let* include_usage = bool_param payload "include_usage" in
    Ok
      {
        names;
        include_hidden;
        include_deprecated;
        include_usage;
        cursor;
      }

let parse_cursor_only_params params =
  let open Yojson.Safe.Util in
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
    match payload |> member "cursor" with
    | `Null -> Ok { cursor = None }
    | `String cursor -> Ok { cursor = Some cursor }
    | _ -> Error "Invalid params: cursor must be a string"

let list_page_size () = Env_config.Tools.list_page_size ()

let encode_cursor ~kind offset =
  Base64.encode_string (Printf.sprintf "%s:%d" kind offset)

let decode_cursor ~kind cursor =
  match Base64.decode cursor with
  | Ok decoded ->
      let prefix = kind ^ ":" in
      let prefix_len = String.length prefix in
      if String.length decoded >= prefix_len
         && String.sub decoded 0 prefix_len = prefix
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
        | _ -> Error "Invalid params: cursor is invalid")
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
