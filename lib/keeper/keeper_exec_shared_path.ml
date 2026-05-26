(** Keeper_exec_shared_path — keeper path resolution helpers extracted
    from [Keeper_exec_shared] (635 LoC).  JSON helpers, registry
    helpers, and tool list remain in the parent.
    @since Keeper 500-line decomposition *)

open Keeper_types
open Keeper_alerting


let keeper_effective_allowed_paths ~(meta : keeper_meta) =
  Keeper_alerting_path.effective_allowed_paths ~meta
;;

let keeper_effective_write_allowed_paths ~(meta : keeper_meta) =
  Keeper_alerting_path.effective_write_allowed_paths ~meta
;;

let keeper_playground_root ~(config : Coord.config) ~(meta : keeper_meta) =
  ignore (Keeper_alerting_path.ensure_sandbox_bundle ~config ~meta);
  Keeper_sandbox.host_root_abs_of_meta ~config meta
;;

let keeper_default_write_root ~(config : Coord.config) ~(meta : keeper_meta) =
  keeper_playground_root ~config ~meta
;;

let keeper_default_read_root ~(config : Coord.config) ~(meta : keeper_meta) =
  keeper_playground_root ~config ~meta
;;

let safe_file_exists path =
  try Fs_compat.file_exists path with
  | Sys_error _ -> false
;;

let safe_is_dir path =
  try Fs_compat.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false
;;

let keeper_sandbox_repo_names ~(config : Coord.config) ~(meta : keeper_meta) =
  let repos_dir = Filename.concat (keeper_playground_root ~config ~meta) "repos" in
  if not (safe_is_dir repos_dir)
  then []
  else
    Sys.readdir repos_dir
    |> Array.to_list
    |> List.sort String.compare
    |> List.filter (fun entry ->
      let candidate = Filename.concat repos_dir entry in
      safe_is_dir candidate && safe_file_exists (Filename.concat candidate ".git"))
;;

let keeper_playground_relative_root ~(meta : keeper_meta) =
  Keeper_sandbox.allowed_root_rel_of_meta ~meta
  |> Keeper_alerting_path.strip_trailing_slashes
;;

let keeper_playground_relative_path ~(meta : keeper_meta) rel =
  Filename.concat (keeper_playground_relative_root ~meta) rel
;;

let relative_path_targets_allowed_root ~(meta : keeper_meta) (raw : string) =
  let boundary prefix =
    let prefix = Keeper_alerting_path.strip_trailing_slashes prefix in
    prefix <> ""
    && (String.equal raw prefix || String.starts_with ~prefix:(prefix ^ "/") raw)
  in
  keeper_effective_allowed_paths ~meta
  |> List.filter Filename.is_relative
  |> List.exists boundary
;;

let is_playground_lane_relative_path (raw : string) =
  List.exists
    (fun prefix ->
       String.equal raw prefix || String.starts_with ~prefix:(prefix ^ "/") raw)
    [ "mind"; "repos" ]
;;

let strip_keeper_playground_prefix ~(meta : keeper_meta) (raw : string) =
  let try_strip ~prefix text =
    if
      Filename.is_relative text
      && String.length text >= String.length prefix
      && String.starts_with ~prefix text
    then (
      let rest =
        String.sub text (String.length prefix) (String.length text - String.length prefix)
      in
      Some (if rest = "" then "." else rest))
    else None
  in
  let sandbox_root = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
  let legacy_bundle_root = Playground_paths.bundle_root meta.name in
  let short_root =
    let rel = Keeper_alerting_path.strip_trailing_slashes sandbox_root in
    if String.starts_with ~prefix:(Common.masc_dirname ^ "/") rel
    then String.sub rel 6 (String.length rel - 6)
    else rel
  in
  let prefixes =
    [ sandbox_root
    ; Keeper_alerting_path.strip_trailing_slashes sandbox_root
    ; legacy_bundle_root
    ; Keeper_alerting_path.strip_trailing_slashes legacy_bundle_root
    ; short_root ^ "/"
    ; short_root
    ]
  in
  List.find_map (fun prefix -> try_strip ~prefix raw) prefixes
;;

let repo_relative_path_candidate ~(meta : keeper_meta) (raw : string) =
  let first_segment =
    match String.split_on_char '/' raw with
    | segment :: _ -> segment
    | [] -> raw
  in
  Filename.is_relative raw
  && raw <> ""
  && String.contains raw '/'
  && (not (is_playground_lane_relative_path raw))
  && (not (relative_path_targets_allowed_root ~meta raw))
  && not
       (List.mem
          first_segment
          [ Common.masc_dirname; "playground"; "workspace"; ".worktrees" ])
;;

let rewrite_single_repo_relative_path
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      (raw : string)
  =
  if not (repo_relative_path_candidate ~meta raw)
  then Ok None
  else (
    let first_segment =
      match String.split_on_char '/' raw with
      | segment :: _ -> segment
      | [] -> raw
    in
    match keeper_sandbox_repo_names ~config ~meta with
    | repo_names when List.mem first_segment repo_names ->
      let sandbox_relative = Filename.concat "repos" raw in
      let rewritten = keeper_playground_relative_path ~meta sandbox_relative in
      Log.Keeper.debug "playground_relative: explicit repo rewrite %S → %S" raw rewritten;
      Ok (Some rewritten)
    | [ repo_name ] ->
      let sandbox_relative = Filename.concat ("repos/" ^ repo_name) raw in
      let rewritten = keeper_playground_relative_path ~meta sandbox_relative in
      Log.Keeper.debug "playground_relative: single-repo rewrite %S → %S" raw rewritten;
      Ok (Some rewritten)
    | [] -> Ok None
    | repo_names ->
      Error
        (Printf.sprintf
           "ambiguous_repo_relative_path: %s (sandbox repos: [%s]). Use repos/<repo>/%s \
            or <repo>/%s explicitly."
           raw
           (String.concat ", " repo_names)
           raw
           raw))
;;

let host_path_of_own_container_path
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      (raw : string)
  =
  if Filename.is_relative raw || meta.sandbox_profile <> Keeper_types.Docker
  then None
  else (
    let strip = Keeper_alerting_path.strip_trailing_slashes in
    let normalize path = Keeper_alerting_path.normalize_path_for_check_stripped path in
    let container_root = Keeper_sandbox.container_root meta.name |> normalize in
    let raw_norm = normalize raw in
    let host_root = keeper_playground_root ~config ~meta |> strip in
    if String.equal raw_norm container_root
    then Some host_root
    else if String.starts_with ~prefix:(container_root ^ "/") raw_norm
    then (
      let suffix =
        String.sub
          raw_norm
          (String.length container_root + 1)
          (String.length raw_norm - String.length container_root - 1)
      in
      Some (Filename.concat host_root suffix))
    else None)
;;

let project_relative_host_path ~(config : Coord.config) (path : string) =
  let root =
    Keeper_alerting_path.project_root_of_config config
    |> Keeper_alerting_path.normalize_path_for_check_stripped
  in
  let path_norm = Keeper_alerting_path.normalize_path_for_check_stripped path in
  if String.equal path_norm root then Some "."
  else if String.starts_with ~prefix:(root ^ "/") path_norm then
    Some
      (String.sub path_norm (String.length root + 1)
         (String.length path_norm - String.length root - 1))
  else None
;;

(* Bare filenames and canonical sandbox lanes default to the keeper sandbox,
   but rooted-looking relative paths (for example
   "workspace/..." or "lib/...") keep project-root/boundary semantics.

   Additionally, strip the keeper's legacy playground prefix when the path
   already includes it.  Keeper LLMs sometimes construct paths like
   ".masc/playground/<name>/repos" (relative) or
   "<base>/.masc/playground/<name>/.masc/playground/<name>/repos" (absolute,
   doubled).  Stripping early
   prevents the downstream resolver from doubling the prefix again. *)
let playground_relative_unless_allowed_root
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      (raw : string)
  : (string, string) result
  =
  let trimmed = String.trim raw in
  let mapped_from_container, trimmed =
    match host_path_of_own_container_path ~config ~meta trimmed with
    | Some host_path ->
      Log.Keeper.debug
        "playground_relative: mapped container path %S → %S"
        trimmed
        host_path;
      true, host_path
    | None -> false, trimmed
  in
  let trimmed =
    if mapped_from_container
    then Option.value ~default:trimmed (project_relative_host_path ~config trimmed)
    else trimmed
  in
  let trimmed =
    match strip_keeper_playground_prefix ~meta trimmed with
    | Some stripped ->
      Log.Keeper.debug "playground_relative: stripped prefix %S → %S" trimmed stripped;
      stripped
    | None -> trimmed
  in
  (* 2. Fix doubled playground prefix in absolute paths.
     E.g. "/base/.masc/playground/X/.masc/playground/X/repos" →
          "/base/.masc/playground/X/repos" *)
  let trimmed =
    if not (Filename.is_relative trimmed)
    then (
      let pg_root =
        keeper_playground_root ~config ~meta
        |> Keeper_alerting_path.strip_trailing_slashes
      in
      let pg_bundle = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
      let doubled_prefix = pg_root ^ "/" ^ pg_bundle in
      if String.starts_with ~prefix:doubled_prefix trimmed
      then (
        let rest =
          String.sub
            trimmed
            (String.length doubled_prefix)
            (String.length trimmed - String.length doubled_prefix)
        in
        let fixed = Filename.concat pg_root rest in
        Log.Keeper.debug "playground_relative: fixed doubled abs %S → %S" trimmed fixed;
        (match project_relative_host_path ~config fixed with
         | Some rel -> rel
         | None ->
           (* NDT-OK: [fixed] is produced by deterministic prefix removal from an
              absolute keeper playground path. If it is not under the project root,
              keep the absolute value so the downstream resolver enforces the
              containment boundary. *)
           fixed))
      else trimmed)
    else trimmed
  in
  match rewrite_single_repo_relative_path ~config ~meta trimmed with
  | Error _ as err -> err
  | Ok (Some rewritten) -> Ok rewritten
  | Ok None ->
    if
      trimmed = ""
      || (not (Filename.is_relative trimmed))
      || (String.contains trimmed '/' && not (is_playground_lane_relative_path trimmed))
      || relative_path_targets_allowed_root ~meta trimmed
    then Ok trimmed
    else (
      Ok (keeper_playground_relative_path ~meta trimmed))
;;

let resolve_keeper_path
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(raw_path : string)
  =
  match playground_relative_unless_allowed_root ~config ~meta raw_path with
  | Error e -> Error e
  | Ok normalized ->
    match Keeper_alerting_path.resolve_keeper_target_path
      ~config
      ~allowed_paths:(keeper_effective_write_allowed_paths ~meta)
      ~raw_path:normalized
    with
    | Error rej -> Error (Keeper_alerting_path.rejection_to_user_message rej)
    | Ok p -> Ok p
;;

let resolve_keeper_read_path
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(raw_path : string)
  =
  match playground_relative_unless_allowed_root ~config ~meta raw_path with
  | Error e -> Error e
  | Ok normalized ->
    match Keeper_alerting_path.resolve_keeper_read_path
      ~config
      ~allowed_paths:(keeper_effective_allowed_paths ~meta)
      ~raw_path:normalized
    with
    | Error rej -> Error (Keeper_alerting_path.rejection_to_user_message rej)
    | Ok p -> Ok p
;;
