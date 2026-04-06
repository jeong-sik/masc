(** Keeper_alerting path safety and tool output helpers. *)

let project_root_of_config (config : Room.config) : string =
  let base = config.base_path in
  if Filename.basename base = ".masc" then Filename.dirname base else base

let starts_with ~(prefix : string) (s : string) : bool =
  let lp = String.length prefix in
  String.length s >= lp && String.sub s 0 lp = prefix

let strip_trailing_slashes = Env_config_core.strip_trailing_slashes

let normalize_path_for_check (path : string) : string =
  try Unix.realpath path
  with Unix.Unix_error _ ->
    let parent = Filename.dirname path in
    let parent_norm =
      try Unix.realpath parent
      with Unix.Unix_error _ -> parent
    in
    Filename.concat parent_norm (Filename.basename path)

let normalize_allowed_path_for_check ~(root : string) (path : string) : string option =
  let raw = String.trim path in
  if raw = "" then None
  else
    let candidate =
      if Filename.is_relative raw then Filename.concat root raw else raw
    in
    let normalized = normalize_path_for_check candidate |> strip_trailing_slashes in
    if normalized = "" then None else Some normalized

let absolute_allowed_paths ~(config : Room.config) ~(allowed_paths : string list)
    : string list =
  let root = project_root_of_config config in
  allowed_paths |> List.filter_map (normalize_allowed_path_for_check ~root)

let absolute_allowed_paths_result ~(config : Room.config)
    ~(allowed_paths : string list) : (string list, string) result =
  let normalized = absolute_allowed_paths ~config ~allowed_paths in
  if allowed_paths <> [] && normalized = [] then
    Error
      (Printf.sprintf
         "allowed_paths_normalized_empty: [%s]"
         (String.concat ", " allowed_paths))
  else
    Ok normalized

let resolve_keeper_target_path ~(config : Room.config)
    ~(allowed_paths : string list) ~(raw_path : string)
    : (string, string) result =
  let raw = String.trim raw_path in
  if raw = "" then Error "path_required"
  else
    let root = project_root_of_config config in
    let candidate =
      if Filename.is_relative raw then Filename.concat root raw else raw
    in
    let root_norm = normalize_path_for_check root in
    let target_norm = normalize_path_for_check candidate in
    let within_root =
      target_norm = root_norm
      || starts_with ~prefix:(root_norm ^ "/") target_norm
    in
    if not within_root then
      Error
        (Printf.sprintf "path_outside_project_root: %s (root=%s)"
           target_norm root_norm)
    else if allowed_paths = [] then
      Ok candidate
    else
      let allowed_norms =
        allowed_paths
        |> List.filter_map (normalize_allowed_path_for_check ~root:root_norm)
      in
      let matches_any =
        List.exists
          (fun allowed_norm ->
             target_norm = allowed_norm
             || starts_with ~prefix:(allowed_norm ^ "/") target_norm)
          allowed_norms
      in
      if matches_any then Ok candidate
      else
        Error
          (Printf.sprintf
             "path_not_in_allowed_paths: %s (allowed: [%s])"
             raw (String.concat ", " allowed_norms))

(** Compute effective allowed_paths from keeper meta.
    Always prepends the keeper's playground path and, for workspace scope,
    the workspace default dirs (.masc/keepers/<name>/, .masc/traces/, ".").
    - ["*"]          → [] (full access, explicit opt-in bypasses path checks)
    - other          → playground :: workspace_defaults @ explicit *)
let sanitize_keeper_name (name : string) : string =
  String.map (fun c ->
    if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
       || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '.'
    then c else '_') name

let playground_path_of_keeper (name : string) : string =
  let safe_name = sanitize_keeper_name name in
  Printf.sprintf ".masc/playground/%s/" safe_name

let effective_allowed_paths ~(meta : Keeper_types.keeper_meta) : string list =
  let playground = playground_path_of_keeper meta.name in
  let workspace_defaults =
    match String.lowercase_ascii meta.execution_scope with
    | "workspace" ->
      let safe_name = sanitize_keeper_name meta.name in
      [ Printf.sprintf ".masc/keepers/%s/" safe_name;
        ".masc/traces/";
        "." ]
    | _ -> []
  in
  match meta.allowed_paths with
  | ["*"] -> []
  | explicit -> playground :: workspace_defaults @ explicit

let truncate_tool_output ?(max_len = 12000) (s : string) : string =
  if String.length s <= max_len then s
  else String.sub s 0 max_len ^ "\n...[truncated]"

let process_status_to_json (st : Unix.process_status) : Yojson.Safe.t =
  match st with
  | Unix.WEXITED code ->
      `Assoc [("kind", `String "exit"); ("code", `Int code)]
  | Unix.WSIGNALED sig_num ->
      `Assoc [("kind", `String "signaled"); ("signal", `Int sig_num)]
  | Unix.WSTOPPED sig_num ->
      `Assoc [("kind", `String "stopped"); ("signal", `Int sig_num)]

let extract_user_messages (ctx_work : Keeper_types.working_context) : string list =
  ctx_work.messages
  |> List.filter_map (fun (m : Agent_sdk.Types.message) ->
       if m.role = Agent_sdk.Types.User then
         let c = String.trim (Agent_sdk.Types.text_of_message m) in
         if c = "" then None else Some c
       else
         None)
