(** Keeper_alerting path safety and tool output helpers. *)

let project_root_of_config (config : Coord.config) : string =
  let base = config.base_path in
  if Filename.basename base = Common.masc_dirname then Filename.dirname base else base

let starts_with ~(prefix : string) (s : string) : bool =
  String.starts_with ~prefix s

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

let normalize_path_for_check_stripped path =
  normalize_path_for_check path |> strip_trailing_slashes

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
  let module StringSet = Set.Make (String) in
  let rec walk visited ~dirs_seen acc dir =
    if dirs_seen >= max_dirs || List.length acc >= max_matches then
      (visited, dirs_seen, acc)
    else
      let dir_norm = normalize_path_for_check dir |> strip_trailing_slashes in
      if not (is_within_root_norm ~root_norm dir)
         || StringSet.mem dir_norm visited
      then
        (visited, dirs_seen, acc)
      else
        let visited = StringSet.add dir_norm visited in
        let entries =
          try Sys.readdir dir |> Array.to_list |> List.sort String.compare
          with Sys_error _ -> []
        in
        List.fold_left
          (fun (visited, dirs_seen, acc) entry ->
             if dirs_seen >= max_dirs || List.length acc >= max_matches then
               (visited, dirs_seen, acc)
             else
               let path = Filename.concat dir entry in
               match (try Some (Sys.is_directory path) with Sys_error _ -> None) with
               | None -> (visited, dirs_seen, acc)
               | Some is_dir ->
                   let acc =
                     if entry = anchor then
                       let candidate = Filename.concat path suffix_rel in
                       if path_exists candidate
                          && is_within_root_norm ~root_norm candidate
                       then candidate :: acc else acc
                     else acc
                   in
                   if is_dir && is_within_root_norm ~root_norm path then
                     walk visited ~dirs_seen:(dirs_seen + 1) acc path
                   else
                     (visited, dirs_seen, acc))
          (visited, dirs_seen, acc) entries
  in
  walk StringSet.empty ~dirs_seen:0 [] root
  |> fun (_, _, matches) -> List.rev matches

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
           (* Tier A3 / Cycle 6: do not echo the resolved match paths
              into the error string — that leaks the host filesystem
              layout to the caller (LLM) and dashboards. The match
              count alone is enough for the caller to course-correct. *)
           Error
             (Printf.sprintf
                "ambiguous_relative_read_path: %s (%d candidate matches; \
                 disambiguate the relative segment)"
                raw_path (List.length many)))

let allows_missing_leaf_read ~(raw : string) ~(candidate : string) : bool =
  let parts = split_relative_components raw in
  let trailing_slash =
    String.ends_with ~suffix:"/" raw
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

let absolute_allowed_paths ~(config : Coord.config) ~(allowed_paths : string list)
    : string list =
  let root = project_root_of_config config in
  allowed_paths |> List.filter_map (normalize_allowed_path_for_check ~root)

let absolute_allowed_paths_result ~(config : Coord.config)
    ~(allowed_paths : string list) : (string list, string) result =
  let normalized = absolute_allowed_paths ~config ~allowed_paths in
  if allowed_paths <> [] && normalized = [] then
    (* Tier A3 / Cycle 6: redact the raw [allowed_paths] list — those
       strings frequently include host-absolute prefixes that should
       not flow back to the LLM caller. The count is enough for the
       caller to know "you provided N entries, none were valid". *)
    Error
      (Printf.sprintf
         "allowed_paths_normalized_empty: %d entries provided, none \
          resolved to a valid path"
         (List.length allowed_paths))
  else
    Ok normalized

(** Build a sandbox boundary error message that teaches the LLM
    *why* the path was rejected — not just *that* it was. Bare "X not allowed"
    triggers retry loops; including the resolved candidate plus the
    sandbox boundary rule lets the keeper correct on the next call without
    re-trying the same broken interpretation. See
    [memory/feedback_tool-error-messages-teach-llm.md]. *)
(** Look for a playground-root allowed path (contains ".masc/playground/")
    and return the first match. Used to suggest a concrete rewrite when the
    raw path looks like a playground-subdir pattern that was not prepended. *)
let playground_root_of_allowed (allowed_norms : string list) : string option =
  List.find_opt
    (fun p ->
      let marker = "/" ^ Common.masc_dirname ^ "/playground/" in
      let mlen = String.length marker in
      let slen = String.length p in
      let rec find i =
        if i + mlen > slen then false
        else if String.sub p i mlen = marker then true
        else find (i + 1)
      in
      find 0)
    allowed_norms

let raw_looks_like_playground_subdir (raw : string) : bool =
  starts_with ~prefix:"repos/" raw
  || starts_with ~prefix:"mind/" raw
  || raw = "repos"
  || raw = "mind"

let format_path_rejection ~(raw : string) ~(resolved : string)
    ~(allowed_norms : string list) : string =
  let resolved_hint =
    if Filename.is_relative raw && resolved <> raw then
      "; relative paths are checked against your sandbox boundary"
    else
      ""
  in
  let playground_hint =
    if raw_looks_like_playground_subdir raw then
      match playground_root_of_allowed allowed_norms with
      | Some _ ->
        Printf.sprintf
          ". Your raw path already looks sandbox-relative. Use it as-is \
           (for example path=%S); call keeper_context_status and use \
           sandbox_repos / sandbox_mind if unsure."
          raw
      | None -> ""
    else ""
  in
  Printf.sprintf "path_outside_sandbox: %s%s%s" raw resolved_hint
    playground_hint

let resolve_keeper_target_path ~(config : Coord.config)
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
      (* Tier A3 / Cycle 6: do not echo the resolved [target_norm] or
         [root_norm] absolute paths — both reveal the host sandbox
         layout to the caller (LLM). Echo only the caller's [raw]
         input. The "outside_project_root" label is enough for the
         caller to course-correct without enumerating the host. *)
      Error
        (Printf.sprintf "path_outside_project_root: %s" raw)
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
          (format_path_rejection ~raw ~resolved:target_norm ~allowed_norms)

(* Playground path SSOT lives in [Playground_paths] (masc_config). These
   names preserve the historical keeper-facing API. Do not re-implement
   the literal ".masc/playground" layout here — edit [Playground_paths]
   if it ever changes. *)
let sanitize_keeper_name = Playground_paths.sanitize_keeper_name
let playground_path_of_keeper = Playground_paths.bundle_root
let playground_mind_path = Playground_paths.mind_path
let playground_repos_path = Playground_paths.repos_path
let playground_bundle_paths = Playground_paths.bundle_paths
let sandbox_path_of_keeper name = Keeper_sandbox.allowed_root_rel ~name
let sandbox_path_of_meta ~(meta : Keeper_types.keeper_meta) =
  Keeper_sandbox.allowed_root_rel_of_meta ~meta

let sandbox_bundle_paths_of_meta ~(meta : Keeper_types.keeper_meta) =
  let root = sandbox_path_of_meta ~meta |> strip_trailing_slashes in
  [ root ^ "/"; root ^ "/mind/"; root ^ "/repos/" ]

let ensure_playground_bundle ~(config : Coord.config) ~(name : string) : string list =
  let root = project_root_of_config config in
  playground_bundle_paths name
  |> List.map (Filename.concat root)
  |> List.map Keeper_fs.ensure_dir

let ensure_sandbox_bundle ~(config : Coord.config) ~(meta : Keeper_types.keeper_meta)
    : string list =
  let root = project_root_of_config config in
  sandbox_bundle_paths_of_meta ~meta
  |> List.map (Filename.concat root)
  |> List.map Keeper_fs.ensure_dir

let ensure_sandbox_bundle_for_profile ~(config : Coord.config)
    ~(name : string) ~(sandbox_profile : Keeper_types.sandbox_profile) : string list =
  let root = project_root_of_config config in
  let sandbox_root =
    Keeper_sandbox.host_root_rel_of_profile sandbox_profile name
    |> strip_trailing_slashes
  in
  [ sandbox_root ^ "/"; sandbox_root ^ "/mind/"; sandbox_root ^ "/repos/" ]
  |> List.map (Filename.concat root)
  |> List.map Keeper_fs.ensure_dir

(** Compute effective read allowed_paths from keeper meta.
    Returns the single sandbox root plus any explicit [allowed_paths]
    entries. Every additional path must be listed explicitly in
    [allowed_paths]. *)
let effective_allowed_paths ~(meta : Keeper_types.keeper_meta) : string list =
  let sandbox_paths = Keeper_sandbox.allowed_path_roots_of_meta ~meta in
  sandbox_paths @ meta.allowed_paths

(** Compute effective write allowed_paths from keeper meta.
    Returns the single sandbox root plus any explicit [allowed_paths]
    entries. Every additional path must be listed explicitly in
    [allowed_paths]. *)
let effective_write_allowed_paths ~(meta : Keeper_types.keeper_meta) : string list =
  let sandbox_paths = Keeper_sandbox.allowed_path_roots_of_meta ~meta in
  sandbox_paths @ meta.allowed_paths

(** Resolve a path for read-only access within the keeper's effective
    allowlist. The allowlist is usually the keeper sandbox root
    plus any explicit custom paths. *)
let resolve_keeper_read_path ~(config : Coord.config)
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
      (* Tier A3 / Cycle 6: do not echo the resolved [target_norm] or
         [root_norm] absolute paths — both reveal the host sandbox
         layout to the caller (LLM). Echo only the caller's [raw]
         input. The "outside_project_root" label is enough for the
         caller to course-correct without enumerating the host. *)
      Error
        (Printf.sprintf "path_outside_project_root: %s" raw)
    else
      let allowed_norms =
        if allowed_paths = [] then []
        else
          allowed_paths
          |> List.filter_map (normalize_allowed_path_for_check ~root:root_norm)
      in
      if allowed_paths <> [] && allowed_norms = [] then
        (* Tier A3 / Cycle 6: redact the raw [allowed_paths] list. *)
        Error
          (Printf.sprintf
             "allowed_paths_normalized_empty: %d entries provided, none \
              resolved to a valid path"
             (List.length allowed_paths))
      else
      let within_allowed =
        allowed_norms = [] || is_within_allowed_norms ~target_norm allowed_norms
      in
      let search_roots =
        if allowed_norms = [] then [root_norm] else allowed_norms
      in
      let reject_outside_sandbox () =
        Prometheus.inc_counter Prometheus.metric_keeper_path_rejection
          ~labels:[ ("kind", "out_of_roots") ] ();
        Error
          (format_path_rejection ~raw ~resolved:target_norm ~allowed_norms)
      in
      if not within_allowed then
        if Filename.is_relative raw then
          (match maybe_resolve_missing_relative_read_path ~roots:search_roots ~raw_path:raw with
           | Ok (Some resolved) -> Ok resolved
           | Ok None -> reject_outside_sandbox ()
           | Error e -> Error e)
        else reject_outside_sandbox ()
      else if path_exists candidate || allows_missing_leaf_read ~raw ~candidate then
        Ok candidate
      else if Filename.is_relative raw then
        (match maybe_resolve_missing_relative_read_path ~roots:search_roots ~raw_path:raw with
         | Ok (Some resolved) -> Ok resolved
         | Ok None ->
             (* #10349: keep the rejection signal in the
                Prometheus counter; do NOT echo the resolved
                roots back to the LLM.  When keeper identity
                drifts (turn 433 evidence), the roots can
                belong to a sibling sandbox, leaking its
                directory layout to the wrong keeper. *)
             Prometheus.inc_counter Prometheus.metric_keeper_path_rejection
               ~labels:[ ("kind", "not_found_relative") ] ();
             Error
               (Printf.sprintf "path_not_found_under_allowed_roots: %s" raw)
         | Error e -> Error e)
      else begin
        Prometheus.inc_counter Prometheus.metric_keeper_path_rejection
          ~labels:[ ("kind", "out_of_roots") ] ();
        Error
          (Printf.sprintf "path_not_found_under_allowed_roots: %s"
             raw)
      end

let process_status_to_json (st : Unix.process_status) : Yojson.Safe.t =
  let sem = Masc_exec.Exit_code.of_process_status st in
  let base = match st with
    | Unix.WEXITED 124 ->
        (* Process_eio returns exit code 124 on Eio.Time.Timeout *)
        [("kind", `String "timeout")]
    | Unix.WEXITED _code ->
        [("kind", `String "exit"); ("code", `Int sem.code)]
    | Unix.WSIGNALED sig_num when sig_num = Sys.sigterm ->
        [("kind", `String "timeout")]
    | Unix.WSIGNALED sig_num ->
        [("kind", `String "signaled"); ("signal", `Int sig_num)]
    | Unix.WSTOPPED sig_num ->
        [("kind", `String "stopped"); ("signal", `Int sig_num)]
  in
  let with_label = ("label", `String sem.label) :: base in
  if sem.hint = "" then `Assoc with_label
  else `Assoc (("hint", `String sem.hint) :: with_label)

let extract_user_messages (ctx_work : Keeper_types.working_context) : string list =
  Keeper_exec_context.messages_of_context ctx_work
  |> List.filter_map (fun (m : Agent_sdk.Types.message) ->
       if m.role = Agent_sdk.Types.User then
         let c = String.trim (Agent_sdk.Types.text_of_message m) in
         if c = "" then None else Some c
       else
         None)
