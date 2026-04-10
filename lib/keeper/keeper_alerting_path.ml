(** Keeper_alerting path safety and tool output helpers. *)

let project_root_of_config (config : Room.config) : string =
  let base = config.base_path in
  if Filename.basename base = ".masc" then Filename.dirname base else base

let starts_with ~(prefix : string) (s : string) : bool =
  let lp = String.length prefix in
  String.length s >= lp && String.sub s 0 lp = prefix

let strip_trailing_slashes = Env_config_core.strip_trailing_slashes

let normalize_path_for_check (path : string) : string =
  try Fs_compat.realpath path
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
        match (try Some (Fs_compat.realpath p) with Unix.Unix_error _ -> None) with
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

let split_relative_components (raw : string) : string list =
  raw
  |> String.split_on_char '/'
  |> List.filter (fun part -> part <> "" && part <> ".")

let has_parent_component (parts : string list) : bool =
  List.exists (fun part -> part = "..") parts

let join_path_components = function
  | [] -> "."
  | hd :: tl -> List.fold_left Filename.concat hd tl

let path_exists (path : string) : bool =
  Fs_compat.file_exists path

let parent_exists (path : string) : bool =
  let parent = Filename.dirname path in
  parent <> path && path_exists parent

let is_within_root_norm ~(root_norm : string) (path : string) : bool =
  let normalized = normalize_path_for_check path |> strip_trailing_slashes in
  normalized = root_norm
  || starts_with ~prefix:(root_norm ^ "/") normalized

let find_suffix_matches_under_root ~root ~anchor ~suffix_rel
    ?(max_dirs = 2000) ?(max_matches = 8) () : string list =
  let root_norm = normalize_path_for_check root |> strip_trailing_slashes in
  let visited : (string, unit) Hashtbl.t = Hashtbl.create 64 in
  let rec walk ~dirs_seen acc dir =
    if dirs_seen >= max_dirs || List.length acc >= max_matches then (dirs_seen, acc)
    else
      let dir_norm = normalize_path_for_check dir |> strip_trailing_slashes in
      if not (is_within_root_norm ~root_norm dir)
         || Hashtbl.mem visited dir_norm
      then (dirs_seen, acc)
      else begin
        Hashtbl.replace visited dir_norm ();
        let entries =
          try Sys.readdir dir |> Array.to_list |> List.sort String.compare
          with Sys_error _ -> []
        in
        List.fold_left
          (fun (dirs_seen, acc) entry ->
             if dirs_seen >= max_dirs || List.length acc >= max_matches then (dirs_seen, acc)
             else
               let path = Filename.concat dir entry in
               match (try Some (Sys.is_directory path) with Sys_error _ -> None) with
               | None -> (dirs_seen, acc)
               | Some is_dir ->
                   let acc =
                     if entry = anchor then
                       let candidate = Filename.concat path suffix_rel in
                       if path_exists candidate
                          && is_within_root_norm ~root_norm candidate
                       then candidate :: acc else acc
                     else acc
                   in
                   if is_dir && is_within_root_norm ~root_norm path
                   then walk ~dirs_seen:(dirs_seen + 1) acc path
                   else (dirs_seen, acc))
          (dirs_seen, acc) entries
      end
  in
  walk ~dirs_seen:0 [] root |> snd |> List.rev

let maybe_resolve_missing_relative_read_path ~(roots : string list) ~(raw_path : string) :
    (string option, string) result =
  let parts = split_relative_components raw_path in
  match parts with
  | [] | [_] -> Ok None
  | _ when has_parent_component parts -> Ok None
  | anchor :: rest ->
      let suffix_rel = join_path_components rest in
      let matches =
        roots
        |> List.concat_map (fun root ->
             find_suffix_matches_under_root ~root ~anchor ~suffix_rel ())
        |> List.sort_uniq String.compare
      in
      (match matches with
       | [] -> Ok None
       | [match_path] -> Ok (Some match_path)
       | many ->
           Error
             (Printf.sprintf
                "ambiguous_relative_read_path: %s (matches: [%s])"
                raw_path (String.concat ", " many)))

let allows_missing_leaf_read ~(raw : string) ~(candidate : string) : bool =
  let parts = split_relative_components raw in
  let trailing_slash =
    String.length raw > 0 && raw.[String.length raw - 1] = '/'
  in
  parent_exists candidate
  && List.length parts > 1
  && not trailing_slash

let is_within_allowed_norms ~(target_norm : string) (allowed_norms : string list) : bool =
  List.exists
    (fun allowed_norm ->
       target_norm = allowed_norm
       || starts_with ~prefix:(allowed_norm ^ "/") target_norm)
    allowed_norms

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

let playground_mind_path (name : string) : string =
  let safe_name = sanitize_keeper_name name in
  Printf.sprintf ".masc/playground/%s/mind/" safe_name

let playground_repos_path (name : string) : string =
  let safe_name = sanitize_keeper_name name in
  Printf.sprintf ".masc/playground/%s/repos/" safe_name

let playground_bundle_paths (name : string) : string list =
  [
    playground_path_of_keeper name;
    playground_mind_path name;
    playground_repos_path name;
  ]

let ensure_playground_bundle ~(config : Room.config) ~(name : string) : string list =
  let root = project_root_of_config config in
  playground_bundle_paths name
  |> List.map (Filename.concat root)
  |> List.map Keeper_fs.ensure_dir

let effective_allowed_paths ~(meta : Keeper_types.keeper_meta) : string list =
  let playground_paths = playground_bundle_paths meta.name in
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
  | explicit -> playground_paths @ workspace_defaults @ explicit

(** Resolve a path for read-only access within the keeper's effective
    allowlist. The allowlist is usually the keeper playground bundle
    plus any explicit custom paths; explicit ["*"] still means full
    project-root access. *)
let resolve_keeper_read_path ~(config : Room.config)
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
    else
      let allowed_norms =
        if allowed_paths = [] then []
        else
          allowed_paths
          |> List.filter_map (normalize_allowed_path_for_check ~root:root_norm)
      in
      if allowed_paths <> [] && allowed_norms = [] then
        Error
          (Printf.sprintf
             "allowed_paths_normalized_empty: [%s]"
             (String.concat ", " allowed_paths))
      else
      let within_allowed =
        allowed_norms = [] || is_within_allowed_norms ~target_norm allowed_norms
      in
      let search_roots =
        if allowed_norms = [] then [root_norm] else allowed_norms
      in
      if not within_allowed then
        if Filename.is_relative raw then
          (match maybe_resolve_missing_relative_read_path ~roots:search_roots ~raw_path:raw with
           | Ok (Some resolved) -> Ok resolved
           | Ok None ->
               Error
                 (Printf.sprintf
                    "path_not_in_allowed_paths: %s (allowed: [%s])"
                    raw (String.concat ", " allowed_norms))
           | Error e -> Error e)
        else
          Error
            (Printf.sprintf
               "path_not_in_allowed_paths: %s (allowed: [%s])"
               raw (String.concat ", " allowed_norms))
      else if path_exists candidate || allows_missing_leaf_read ~raw ~candidate then
        Ok candidate
      else if Filename.is_relative raw then
        (match maybe_resolve_missing_relative_read_path ~roots:search_roots ~raw_path:raw with
         | Ok (Some resolved) -> Ok resolved
         | Ok None ->
             Error
               (Printf.sprintf
                  "path_not_found_under_allowed_roots: %s (roots=[%s])"
                  raw (String.concat ", " search_roots))
         | Error e -> Error e)
      else
        Error
          (Printf.sprintf
             "path_not_found_under_allowed_roots: %s (roots=[%s])"
             target_norm
             (String.concat ", "
                (if allowed_norms = [] then [root_norm] else allowed_norms)))

let process_status_to_json (st : Unix.process_status) : Yojson.Safe.t =
  match st with
  | Unix.WEXITED code ->
      `Assoc [("kind", `String "exit"); ("code", `Int code)]
  | Unix.WSIGNALED sig_num when sig_num = Sys.sigterm ->
      `Assoc [("kind", `String "timeout")]
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
