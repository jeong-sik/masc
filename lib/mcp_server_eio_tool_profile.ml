(** Mcp_server_eio_tool_profile — Tool profile, schema, annotations, and pagination

    Extracted from mcp_server_eio.ml.
    Handles tool listing, profile filtering, annotations, pagination cursors,
    and tool JSON serialization for the MCP protocol.
*)

type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote
  | Role_filtered of Mode.mode

let operator_remote_instructions =
  "MASC remote operator profile exposes only four control-plane tools: \
masc_operator_snapshot, masc_operator_digest, masc_operator_action, and masc_operator_confirm. \
Read raw state with masc_operator_snapshot first when needed, and prefer masc_operator_digest for intervention-oriented supervision. \
Use masc_operator_action for guided actions only. \
When confirm_required=true, you must call masc_operator_confirm with the returned confirm_token before the action executes. \
Do not assume access to any other MASC tool from this endpoint."

let managed_agent_instructions =
  "MASC managed-agent profile exposes the internal agent control surface. \
Prefer SDK-style task and room aliases such as masc_room_status, masc_list_tasks, masc_claim_task, masc_set_current_task, masc_complete_task, masc_release_task, masc_cancel_task, masc_send_direct, masc_add_task, masc_batch_add_tasks, masc_broadcast, and masc_heartbeat. \
Use canonical passthrough tools only when no managed alias exists on this endpoint. \
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

let dedupe_tool_schemas_by_name (schemas : Types.tool_schema list) =
  let seen = Hashtbl.create (List.length schemas) in
  List.filter
    (fun (schema : Types.tool_schema) ->
      if Hashtbl.mem seen schema.name then
        false
      else (
        Hashtbl.add seen schema.name ();
        true))
    schemas

let default_instructions =
  "MASC (Multi-Agent Streaming Coordination) enables AI agent collaboration. \
ROOM: Agents sharing the same base path (.masc/ folder) or PostgreSQL cluster coordinate together. \
CLUSTER: Set MASC_CLUSTER_NAME for multi-machine coordination (defaults to basename of ME_ROOT). \
READ: use resources/list + resources/read (status/tasks/agents/events/schema) for snapshots. \
WRITE: prefer masc_transition (claim/start/done/cancel/release) with expected_version for CAS. \
WORKFLOW: masc_status → masc_transition(claim) → masc_worktree_create (isolation) → work → masc_transition(done). \
Use masc_heartbeat periodically; use @agent mentions in masc_broadcast. \
Prefer worktrees for parallel work."

let apply_budget_filter ?budget_tokens schemas =
  match budget_tokens with
  | None -> (
      match Tool_budget.default_budget () with
      | None -> schemas
      | Some budget ->
          let usage_counts name =
            match Tool_metrics.stats_for name with
            | Some s -> s.Tool_metrics.call_count
            | None -> 0
          in
          Tool_budget.filter_by_budget ~budget_tokens:budget ~usage_counts
            ~tool_schemas:schemas)
  | Some budget ->
      let usage_counts name =
        match Tool_metrics.stats_for name with
        | Some s -> s.Tool_metrics.call_count
        | None -> 0
      in
      Tool_budget.filter_by_budget ~budget_tokens:budget ~usage_counts
        ~tool_schemas:schemas

let tool_schemas_for_profile ?(include_hidden = false) ?(include_deprecated = false)
    ?mode_override ?budget_tokens state profile =
  let schemas =
    match profile with
    | Full ->
        let categories =
          match mode_override with
          | Some mode_str ->
              (match Mode.mode_of_string (String.lowercase_ascii mode_str) with
               | Some mode -> Mode.categories_for_mode mode
               | None ->
                   let room_path = Room.masc_dir state.Mcp_server.room_config in
                   let config = Config.load room_path in
                   config.Config.enabled_categories)
          | None ->
              let room_path = Room.masc_dir state.Mcp_server.room_config in
              let config = Config.load room_path in
              config.Config.enabled_categories
        in
        Config.enabled_tool_schemas ~include_hidden ~include_deprecated categories
    | Managed_agent ->
        let passthrough =
          Config.visible_tool_schemas ~include_hidden:false ~include_deprecated:false ()
          |> List.filter (fun (schema : Types.tool_schema) ->
                 List.mem schema.name managed_agent_passthrough_tool_names
                 && Tool_catalog.is_visible schema.name)
        in
        dedupe_tool_schemas_by_name
          (Sdk_tool_contract.sdk_tool_schemas @ passthrough)
    | Operator_remote -> Tool_operator.remote_schemas
    | Role_filtered mode ->
        let categories = Mode.categories_for_mode mode in
        Config.enabled_tool_schemas ~include_hidden ~include_deprecated categories
  in
  apply_budget_filter ?budget_tokens schemas

let tool_allowed_in_profile state profile tool_name =
  match profile with
  | Full ->
      tool_schemas_for_profile ~include_deprecated:true state Full
      |> List.exists (fun (schema : Types.tool_schema) ->
             String.equal schema.name tool_name)
  | Managed_agent ->
      tool_schemas_for_profile state Managed_agent
      |> List.exists (fun (schema : Types.tool_schema) ->
             String.equal schema.name tool_name)
  | Operator_remote -> List.mem tool_name Tool_operator.remote_tool_names
  | Role_filtered mode ->
      Mode.is_tool_enabled (Mode.categories_for_mode mode) tool_name

let is_destructive_tool_name name =
  let lowered = String.lowercase_ascii name in
  List.exists
    (fun fragment ->
      let len = String.length fragment in
      let lowered_len = String.length lowered in
      let rec loop idx =
        if idx + len > lowered_len then false
        else if String.sub lowered idx len = fragment then true
        else loop (idx + 1)
      in
      loop 0)
    [ "delete"; "remove"; "reset"; "revoke"; "disable"; "kill_switch"; "retire" ]

let is_idempotent_tool_name name =
  let lowered = String.lowercase_ascii name in
  List.exists
    (fun prefix ->
      let prefix_len = String.length prefix in
      String.length lowered >= prefix_len
      && String.sub lowered 0 prefix_len = prefix)
    [ "masc_status"; "masc_get_"; "masc_list"; "masc_tool_"; "masc_keeper_tool_catalog" ]

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
    | None -> is_destructive_tool_name tool_name
  in
  let idempotent =
    match meta.idempotent with
    | Some v -> v
    | None -> is_idempotent_tool_name tool_name || read_only
  in
  let fields =
    [ ("readOnlyHint", `Bool read_only) ]
    @ (if destructive then [ ("destructiveHint", `Bool true) ] else [])
    @ (if idempotent then [ ("idempotentHint", `Bool true) ] else [])
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

let tool_title_of_name name =
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

let tool_output_schema_field = function
  | "masc_team_session_status" ->
      Some
        (permissive_object_schema
           [
             ("status", `Assoc [ ("type", `String "string") ]);
             ("result", `Assoc [ ("type", `String "object") ]);
           ])
  | "masc_operator_digest" ->
      Some
        (permissive_object_schema
           [
             ("target_type", `Assoc [ ("type", `String "string") ]);
             ("target_id", `Assoc [ ("type", `String "string") ]);
             ("health", `Assoc [ ("type", `String "string") ]);
             ("attention_items", `Assoc [ ("type", `String "array") ]);
             ("recommended_actions", `Assoc [ ("type", `String "array") ]);
           ])
  | _ -> None

let tool_json_for_profile ?usage_summary profile (schema : Types.tool_schema) =
  let category_str = Mode.category_to_string (Mode.tool_category schema.name) in
  let tier_str = Tool_catalog.tier_to_string (Tool_catalog.tool_tier schema.name) in
  let base =
    [
      ("name", `String schema.name);
      ("title", `String (tool_title_of_name schema.name));
      ("description", `String schema.description);
      ( "icons",
        `List
          (List.map Mcp_server.icon_to_json (tool_icons_for_name schema.name)) );
      ("inputSchema", schema.input_schema);
      ("x-category", `String category_str);
      ("x-tier", `String tier_str);
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
  mode : string option;
  tier : string option;
  cursor : string option;
}

let ( let* ) = Result.bind

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

let requested_tool_list_params params =
  let open Yojson.Safe.Util in
  match params with
  | None ->
      Ok {
        names = None;
        include_hidden = false;
        include_deprecated = false;
        include_usage = false;
        mode = None;
        tier = None;
        cursor = None;
      }
  | Some (`Assoc _ as payload) -> (
      let names_result =
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
      let mode_result =
        match payload |> member "mode" with
        | `Null -> Ok None
        | `String s -> Ok (Some s)
        | _ -> Error "Invalid params: mode must be a string"
      in
      let tier_result =
        match payload |> member "tier" with
        | `Null -> Ok None
        | `String s -> (
            match Tool_catalog.tier_of_string (String.lowercase_ascii s) with
            | Some _ -> Ok (Some s)
            | None -> Error "Invalid params: tier must be one of: essential, standard, full")
        | _ -> Error "Invalid params: tier must be a string"
      in
      match names_result with
      | Error _ as err -> err
      | Ok names -> (
          match cursor_param payload with
          | Error _ as err -> err
          | Ok cursor -> (
          match mode_result with
          | Error _ as err -> err
          | Ok mode -> (
          match tier_result with
          | Error _ as err -> err
          | Ok tier -> (
          match bool_param payload "include_hidden" with
          | Error _ as err -> err
          | Ok include_hidden -> (
              match bool_param payload "include_deprecated" with
              | Error _ as err -> err
              | Ok include_deprecated -> (
                  match bool_param payload "include_usage" with
                  | Error _ as err -> err
                  | Ok include_usage ->
                      Ok {
                        names;
                        include_hidden;
                        include_deprecated;
                        include_usage;
                        mode;
                        tier;
                        cursor;
                      })))))))
  | Some _ -> Error "Invalid params: expected object"

let validate_optional_meta payload =
  match Yojson.Safe.Util.member "_meta" payload with
  | `Null
  | `Assoc _ -> Ok ()
  | _ -> Error "Invalid params: _meta must be an object"

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

let list_page_size () =
  match Sys.getenv_opt "MASC_LIST_PAGE_SIZE" with
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some v when v >= 10 && v <= 1024 -> v
      | _ -> 512)
  | None -> 512

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
