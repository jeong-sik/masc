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
    (* Walk up the directory tree until we find an ancestor that exists and
       can be resolved via realpath, then reconstruct the suffix.
       This handles symlinks (e.g., /tmp -> /private/tmp on macOS) even when
       intermediate directories do not exist on disk.
       Tail-recursive to avoid stack overflow on deep untrusted paths. *)
    let rec collect_suffix p acc =
      let parent = Filename.dirname p in
      if parent = p then
        (* Reached filesystem root without a successful realpath. *)
        (p, acc)
      else
        match (try Some (Unix.realpath p) with Unix.Unix_error _ -> None) with
        | Some resolved -> (resolved, acc)
        | None -> collect_suffix parent (Filename.basename p :: acc)
    in
    let (resolved_base, suffix_parts) = collect_suffix path [] in
    List.fold_left Filename.concat resolved_base suffix_parts

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
    the workspace default dirs:
    - `.masc/keepers/<name>/`
    - `.masc/traces/`
    (project root `.` is no longer included by default; set
     [`allowed_paths`] explicitly if needed.)
    - [`*`] → [] (full access, explicit opt-in bypasses path checks)
    - other  → playground :: workspace_defaults @ explicit *)
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
        ".masc/traces/" ]
    | _ -> []
  in
  match meta.allowed_paths with
  | ["*"] -> []
  | explicit -> playground :: workspace_defaults @ explicit

(** Resolve a path for read-only access: allow any path within the
    project root, regardless of allowed_paths.  Write operations must
    use {!resolve_keeper_target_path} which enforces allowed_paths. *)
let resolve_keeper_read_path ~(config : Room.config) ~(raw_path : string)
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
    else if not (Sys.file_exists candidate) then
      (* Early rejection: the path is within root but does not exist on disk.
         Without this check the underlying tool (rg, find, cat) runs and fails
         with a system-level error that gives the LLM no actionable hint. *)
      let parent = Filename.dirname candidate in
      let nearby =
        if Sys.file_exists parent && Sys.is_directory parent then
          match Safe_ops.list_dir_safe parent with
          | Ok entries ->
            let limited = List.filteri (fun i _ -> i < 10) entries in
            Printf.sprintf " Available in %s: [%s]."
              parent (String.concat ", " limited)
          | Error _ -> ""
        else ""
      in
      Error
        (Printf.sprintf
           "path_not_found: '%s' does not exist.%s \
            Hint: clone repos into your playground \
            (.masc/playground/<your_name>/) using op=git_clone, \
            then read from there."
           raw nearby)
    else Ok candidate

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
