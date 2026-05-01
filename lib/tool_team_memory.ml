open Base
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

module Sg = Oas.Tool_schema_gen

let room_field =
  Sg.string_field "room" ~required:true
    ~desc:"Flattened shared-memory namespace placeholder. Must be 'default'." ()

let key_field =
  Sg.string_field "key" ~required:true
    ~desc:"Relative memory key/path under the room memory root" ()

let content_field =
  Sg.string_field "content" ~required:true
    ~desc:"UTF-8 text content to store in team memory" ()

let query_field =
  Sg.string_field "query" ~required:true
    ~desc:"Case-insensitive search query for team memory" ()

let read_schema = Sg.two room_field key_field
let write_schema = Sg.three room_field key_field content_field
let search_schema = Sg.two room_field query_field

let parse schema ~tool_name json =
  match Sg.parse schema json with
  | Ok value -> Ok value
  | Error errs ->
      Error
        (Oas.Tool_input_validation.format_errors ~tool_name errs)

let schema_to_tool_schema ~name ~description schema : Types.tool_schema =
  {
    Types.name = name;
    description;
    input_schema = Sg.to_json_schema schema;
  }

let schemas =
  [
    schema_to_tool_schema
      ~name:"masc_team_memory_read"
      ~description:
        "Read shared team memory by key from the flattened default namespace. Uses a typed lane instead of exposing a shared writable shell directory."
      read_schema;
    schema_to_tool_schema
      ~name:"masc_team_memory_write"
      ~description:
        "Write shared team memory by key in the flattened default namespace. Traversal, symlink escape, and secret-like payloads are blocked."
      write_schema;
    schema_to_tool_schema
      ~name:"masc_team_memory_search"
      ~description:
        "Search shared team memory in the flattened default namespace by filename or content substring."
      search_schema;
  ]

let default_namespace = "default"

let validate_team_memory_room room =
  let trimmed = String.trim room in
  if String.equal trimmed "" then
    Error "room is required"
  else if String.equal (String.lowercase_ascii trimmed) default_namespace then
    Ok default_namespace
  else
    Error
      (Printf.sprintf
         "team memory uses the flattened default namespace; room must be '%s'"
         default_namespace)

let validate_authorized_room_id room =
  match Coord.validate_room_id room with
  | Ok room_id -> Ok room_id
  | Error err -> Error ("invalid team memory room id: " ^ err)

let resolve_keeper_access ~(config : Coord.config) ~(agent_name : string) =
  let trimmed = String.trim agent_name in
  if String.equal trimmed "" then
    Error "team memory tools require keeper agent context"
  else
    match Keeper_types.keeper_name_from_agent_name trimmed with
    | None ->
        Error
          (Printf.sprintf
             "team memory tools are keeper-only; agent '%s' is not a keeper agent"
             trimmed)
    | Some keeper_name -> (
        match Keeper_types.read_meta_resolved config keeper_name with
        | Error err -> Error err
        | Ok None ->
            Error
              (Printf.sprintf
                 "keeper context not found for team memory agent '%s'"
                 trimmed)
        | Ok (Some (_resolved_name, meta)) ->
            Ok (keeper_name, meta))

let authorize_team_memory ~(operation: string) ~(config : Coord.config) ~(agent_name : string)
    ~room =
  match resolve_keeper_access ~config ~agent_name with
  | Error err -> Error err
  | Ok (keeper_name, meta) -> (
      match meta.shared_memory_scope with
      | Keeper_types.Shared_memory_disabled ->
          Error
            (Printf.sprintf
               "team memory is disabled for keeper '%s'; set shared_memory_scope=room to enable the flattened default namespace"
               keeper_name)
      | Keeper_types.Shared_memory_room ->
          validate_team_memory_room room
      | Keeper_types.Shared_memory_keeper_only ->
          let private_room = Playground_paths.sanitize_keeper_name keeper_name in
          (match validate_team_memory_room room with
          | Ok _ -> Ok private_room
          | Error _ ->
              Error
                "when using keeper_only memory, room must be 'default' in tool call")
      | Keeper_types.Shared_memory_room_readonly ->
          if String.equal operation "write" then
            Error (Printf.sprintf "team memory is readonly for keeper '%s'" keeper_name)
          else
            validate_team_memory_room room)

let team_memory_root ~(config : Coord.config) room =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path:config.base_path)
    (Printf.sprintf "shared/rooms/%s/memory" room)

let is_safe_subpath ~parent ~child =
  if String.equal child parent then
    true
  else
    let prefix = parent ^ "/" in
    String.length child >= String.length prefix
    && String.equal (Stdlib.String.sub child 0 (String.length prefix)) prefix

let rec nearest_existing_path path =
  if Sys.file_exists path then
    path
  else
    let parent = Filename.dirname path in
    if String.equal parent path then
      path
    else
      nearest_existing_path parent

let safe_realpath path =
  try Ok (Unix.realpath path) with
  | Unix.Unix_error (code, _, _) ->
      Error
        (Printf.sprintf "realpath failed for %s: %s"
           path (Unix.error_message code))

let encoded_traversal_markers =
  [ "%2e"; "%2f"; "%5c" ]

let contains_encoded_traversal key =
  let lowered = String.lowercase_ascii key in
  List.exists (String_util.contains_substring lowered) encoded_traversal_markers

let validate_team_memory_key key =
  let trimmed = String.trim key in
  if String.equal trimmed "" then
    Error "key is required"
  else if String.contains trimmed '\x00' then
    Error "key must not contain NUL"
  else if String.contains trimmed '\\' then
    Error "key must not contain backslashes"
  else if String.contains trimmed '%' && contains_encoded_traversal trimmed then
    Error "key must not contain encoded traversal"
  else
    Validation.Safe_path.validate_relative trimmed

let resolve_key_path ~(config : Coord.config) ~room ~key =
  match validate_authorized_room_id room with
  | Error err -> Error err
  | Ok room_id -> (
      match validate_team_memory_key key with
      | Error err -> Error err
      | Ok rel_key ->
          let root = team_memory_root ~config room_id in
          let abs = Filename.concat root rel_key in
          let parent = Filename.dirname abs in
          let root_real =
            if Sys.file_exists root then
              safe_realpath root
            else
              safe_realpath (nearest_existing_path root)
          in
          match root_real, safe_realpath (nearest_existing_path parent) with
          | Error err, _ | _, Error err -> Error err
          | Ok real_root, Ok real_parent ->
              if is_safe_subpath ~parent:real_root ~child:real_parent then
                Ok (room_id, rel_key, root, abs, real_root)
              else
                Error
                  (Printf.sprintf
                     "team memory key escapes room root via symlink: %s" rel_key))

let is_secret_token_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
  | _ -> false

let contains_secret_token_prefix ~prefix ~min_suffix_len text =
  let lowered = String.lowercase_ascii text in
  let prefix_len = String.length prefix in
  let text_len = String.length lowered in
  let rec count_suffix idx count =
    if idx + count >= text_len then
      count
    else if is_secret_token_char lowered.[idx + count] then
      count_suffix idx (count + 1)
    else
      count
  in
  let rec loop idx =
    if idx + prefix_len > text_len then
      false
    else if String.equal (Stdlib.String.sub lowered idx prefix_len) prefix then
      let boundary_ok = idx = 0 || not (is_secret_token_char lowered.[idx - 1]) in
      let suffix_len = count_suffix (idx + prefix_len) 0 in
      if boundary_ok && suffix_len >= min_suffix_len then true else loop (idx + 1)
    else
      loop (idx + 1)
  in
  loop 0

let content_looks_secret_like content =
  let lowered = String.lowercase_ascii content in
  let markers =
    [
      "-----begin ";
      "authorization:";
      "bearer ";
      "x-api-key:";
      "api_key=";
      "token=";
      "password=";
      "secret=";
      "ssh-rsa ";
    ]
  in
  let secret_prefixes =
    [
      ("ghp_", 8);
      ("github_pat_", 8);
      ("sk-", 10);
    ]
  in
  List.exists (String_util.contains_substring lowered) markers
  || List.exists
       (fun (prefix, min_suffix_len) ->
         contains_secret_token_prefix ~prefix ~min_suffix_len content)
       secret_prefixes

let preview_snippet ?(max_chars = 180) text =
  let normalized = String.trim text in
  if String.length normalized <= max_chars then normalized
  else String.sub normalized 0 max_chars ^ "..."

let read_json ~config (room, key) =
  match resolve_key_path ~config ~room ~key with
  | Error err -> (false, err)
  | Ok (room_id, rel_key, _root, abs, real_root) ->
      if not (Sys.file_exists abs) then
        (false, Printf.sprintf "team memory key not found: %s" rel_key)
      else if Sys.is_directory abs then
        (false, Printf.sprintf "team memory key is a directory: %s" rel_key)
      else
        match safe_realpath abs with
        | Error err -> (false, err)
        | Ok real_path ->
            if not (is_safe_subpath ~parent:real_root ~child:real_path) then
              (false,
               Printf.sprintf
                 "team memory key escapes room root via symlink: %s" rel_key)
            else
              let content = Fs_compat.load_file real_path in
              ( true,
                Yojson.Safe.to_string
                  (`Assoc
                     [
                       ("room", `String room_id);
                       ("key", `String rel_key);
                       ("content", `String content);
                     ]) )

let write_json ~config (room, key, content) =
  match resolve_key_path ~config ~room ~key with
  | Error err -> (false, err)
  | Ok (room_id, rel_key, root, abs, _real_root) ->
      if content_looks_secret_like content then
        (false,
         "team memory write blocked: content looks like it may contain secrets")
      else (
        Fs_compat.mkdir_p root;
        Fs_compat.mkdir_p (Filename.dirname abs);
        match Fs_compat.save_file_atomic abs content with
        | Error err -> (false, err)
        | Ok () ->
            ( true,
              Yojson.Safe.to_string
                (`Assoc
                   [
                     ("room", `String room_id);
                     ("key", `String rel_key);
                     ("bytes", `Int (String.length content));
                   ]) ))

let rec collect_files acc dir =
  let entries =
    try Sys.readdir dir |> Array.to_list with
    | Sys_error _ -> []
  in
  List.fold_left
    (fun acc entry ->
      let path = Filename.concat dir entry in
      try
        match (Unix.lstat path).Unix.st_kind with
        | Unix.S_REG -> path :: acc
        | Unix.S_DIR -> collect_files acc path
        | Unix.S_LNK -> acc
        | _ -> acc
      with
      | Unix.Unix_error _ -> acc)
    acc entries

let search_json ~config (room, query) =
  match validate_authorized_room_id room with
  | Error err -> (false, err)
  | Ok room_id ->
      let normalized_query = String.trim query in
      if String.equal normalized_query "" then
        (false, "query is required")
      else
        let root = team_memory_root ~config room_id in
        if not (Sys.file_exists root && Sys.is_directory root) then
          (true,
           Yojson.Safe.to_string
             (`Assoc [ ("room", `String room_id); ("matches", `List []) ]))
        else
          let lowered_query = String.lowercase_ascii normalized_query in
          let root_prefix =
            root
            |> Keeper_alerting_path.normalize_path_for_check
            |> Keeper_alerting_path.strip_trailing_slashes
          in
          let to_key path =
            let normalized =
              path
              |> Keeper_alerting_path.normalize_path_for_check
              |> Keeper_alerting_path.strip_trailing_slashes
            in
            let prefix = root_prefix ^ "/" in
            if String.starts_with ~prefix normalized then
              String.sub normalized (String.length prefix)
                (String.length normalized - String.length prefix)
            else
              Filename.basename normalized
          in
          let matches =
            collect_files [] root
            |> List.rev
            |> List.filter_map (fun path ->
                   let key = to_key path in
                   let content =
                     try Fs_compat.load_file path with
                     | Sys_error _ -> ""
                   in
                   let lowered_key = String.lowercase_ascii key in
                   let lowered_content = String.lowercase_ascii content in
                   if String_util.contains_substring lowered_key lowered_query
                      || String_util.contains_substring lowered_content lowered_query
                   then
                     Some
                       (`Assoc
                          [
                            ("key", `String key);
                            ("preview", `String (preview_snippet content));
                          ])
                   else
                     None)
            |> fun xs ->
            if List.length xs > 20 then List.filteri (fun idx _ -> idx < 20) xs
            else xs
          in
          ( true,
            Yojson.Safe.to_string
              (`Assoc
                 [
                   ("room", `String room_id);
                   ("query", `String normalized_query);
                   ("matches", `List matches);
                 ]))

let dispatch ~(config : Coord.config) ~(agent_name : string) ~name ~args
    : Keeper_types.tool_result option =
  match name with
  | "masc_team_memory_read" -> (
      match parse read_schema ~tool_name:name args with
      | Ok ((room, _key) as parsed) -> (
          match authorize_team_memory ~operation:"read" ~config ~agent_name ~room with
          | Error err -> Some (false, err)
          | Ok room_id -> Some (read_json ~config (room_id, snd parsed)))
      | Error err -> Some (false, err))
  | "masc_team_memory_write" -> (
      match parse write_schema ~tool_name:name args with
      | Ok ((room, key, content)) -> (
          match authorize_team_memory ~operation:"write" ~config ~agent_name ~room with
          | Error err -> Some (false, err)
          | Ok room_id -> Some (write_json ~config (room_id, key, content)))
      | Error err -> Some (false, err))
  | "masc_team_memory_search" -> (
      match parse search_schema ~tool_name:name args with
      | Ok ((room, _query) as parsed) -> (
          match authorize_team_memory ~operation:"read" ~config ~agent_name ~room with
          | Error err -> Some (false, err)
          | Ok room_id -> Some (search_json ~config (room_id, snd parsed)))
      | Error err -> Some (false, err))
  | _ -> None

let read_only_tools = [ "masc_team_memory_read"; "masc_team_memory_search" ]

let tool_required_permission = function
  | "masc_team_memory_read" | "masc_team_memory_search" ->
      Some Types.CanReadState
  | "masc_team_memory_write" ->
      Some Types.CanBroadcast
  | _ -> None

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      let is_ro = List.mem s.name read_only_tools in
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_misc
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:is_ro
           ~is_idempotent:is_ro
           ~requires_join:true
           ?required_permission:(tool_required_permission s.name)
           ()))
    schemas
