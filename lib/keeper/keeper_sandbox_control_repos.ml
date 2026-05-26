(** Keeper_sandbox_control_repos — playground repo filesystem/git
    operations and cleanup extracted from [Keeper_sandbox_control] (589 LoC).
    @since Keeper 500-line decomposition *)

let normalize_path path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

let cleanup_stale ~(config : Coord.config) ~(timeout_sec : float) () =
  Keeper_sandbox_runtime.cleanup_stale_containers
    ~base_path:config.base_path
    ~timeout_sec
    ()

let safe_file_exists path =
  try Fs_compat.file_exists path with
  | Sys_error _ -> false

let safe_is_dir path =
  try Fs_compat.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false

let repo_name_of_json = function
  | `Assoc fields -> (
      match List.assoc_opt "name" fields with
      | Some (`String raw_name) ->
          let name = String.trim raw_name in
          if
            name <> ""
            && name <> "."
            && name <> ".."
            && not (String.contains name '/')
            && not (String.contains name '\\')
            && String.equal (Filename.basename name) name
          then Some name
          else None
      | _ -> None)
  | _ -> None

let upsert_assoc key value fields =
  (key, value) :: List.remove_assoc key fields

let git_metadata_timeout_sec = 2.0
let max_live_git_enrichment_repos = 20

let git_string_opt repo_path args =
  (* RFC-0106 P1: Cancelled re-raise centralised via Cancel_safe.protect.
     The [_ -> None] silent default is pre-existing behaviour (git
     metadata is treated as optional by callers) and is preserved
     verbatim. Promoting it to a logged/counted failure is a separate
     visibility concern outside this PR's migration scope. *)
  Cancel_safe.protect
    ~on_exn:(fun _ -> None)
    (fun () ->
      let argv = "git" :: "-C" :: repo_path :: args in
      let status, out =
        Masc_exec.Exec_gate.run_argv_with_status ~actor:`Coord_git
          ~raw_source:(String.concat " " argv)
          ~summary:"keeper sandbox git metadata"
          ~timeout_sec:git_metadata_timeout_sec
          argv
      in
      match status with
      | Unix.WEXITED 0 ->
          let trimmed = String.trim out in
          if String.equal trimmed "" then None else Some trimmed
      | _ -> None)

let enrich_playground_repo_from_git
      ~(source : string) ~(repo_name : string) ~(repo_path : string)
      (repo_json : Yojson.Safe.t) =
  let observed_at_unix = Time_compat.now () in
  let fields =
    match repo_json with
    | `Assoc fields -> fields
    | _ -> [ ("name", `String repo_name) ]
  in
  let fields =
    fields
    |> upsert_assoc "name" (`String repo_name)
    |> upsert_assoc "path" (`String (Filename.concat "repos" repo_name))
    |> upsert_assoc "source" (`String source)
    |> upsert_assoc "observed_at"
         (`String (Masc_domain.iso8601_of_unix_seconds observed_at_unix))
    |> upsert_assoc "observed_at_unix" (`Float observed_at_unix)
  in
  let fields =
    match git_string_opt repo_path [ "rev-parse"; "--abbrev-ref"; "HEAD" ] with
    | Some branch -> upsert_assoc "branch" (`String branch) fields
    | None -> fields
  in
  let fields =
    match git_string_opt repo_path [ "log"; "--oneline"; "-1" ] with
    | Some commit -> upsert_assoc "latest_commit" (`String commit) fields
    | None -> fields
  in
  let fields =
    match git_string_opt repo_path [ "rev-parse"; "--is-shallow-repository" ] with
    | Some raw ->
        upsert_assoc "shallow"
          (`Bool (String.equal (String.lowercase_ascii raw) "true"))
          fields
    | None -> fields
  in
  `Assoc fields

let playground_repo_entry_json ~(source : string) ~(repo_name : string)
    (repo_json : Yojson.Safe.t) =
  let observed_at_unix = Time_compat.now () in
  let fields =
    match repo_json with
    | `Assoc fields -> fields
    | _ -> [ ("name", `String repo_name) ]
  in
  fields
  |> upsert_assoc "name" (`String repo_name)
  |> upsert_assoc "path" (`String (Filename.concat "repos" repo_name))
  |> upsert_assoc "source" (`String source)
  |> upsert_assoc "observed_at"
       (`String (Masc_domain.iso8601_of_unix_seconds observed_at_unix))
  |> upsert_assoc "observed_at_unix" (`Float observed_at_unix)
  |> fun fields -> `Assoc fields

let cached_playground_repo_entries playground_abs =
  let cache_path = Filename.concat playground_abs ".playground_state.json" in
  try
    match Yojson.Safe.from_file cache_path with
    | `Assoc _ as json -> (
        match Yojson.Safe.Util.member "repos" json with
        | `List repos -> repos
        | _ -> [])
    | _ -> []
  with
  | Sys_error _ | Yojson.Json_error _ -> []

let filesystem_playground_repo_names playground_abs =
  let repos_dir = Filename.concat playground_abs "repos" in
  if not (safe_is_dir repos_dir) then []
  else
    try
      Sys.readdir repos_dir
      |> Array.to_list
      |> List.filter (fun name ->
        let repo_path = Filename.concat repos_dir name in
        safe_is_dir repo_path
        && safe_file_exists (Filename.concat repo_path ".git"))
      |> List.sort String.compare
    with
    | Sys_error _ -> []

let playground_repos_json ~(config : Coord.config) ~(meta : Keeper_types.keeper_meta) =
  let playground_abs =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> normalize_path
  in
  let repos_dir = Filename.concat playground_abs "repos" in
  let live_enriched_count = ref 0 in
  let cached =
    cached_playground_repo_entries playground_abs
    |> List.map (fun repo ->
      match repo_name_of_json repo with
      | Some name ->
          let repo_path = Filename.concat repos_dir name in
          if safe_is_dir repo_path
             && safe_file_exists (Filename.concat repo_path ".git")
             && !live_enriched_count < max_live_git_enrichment_repos
          then
            (incr live_enriched_count;
            enrich_playground_repo_from_git ~source:"git" ~repo_name:name
              ~repo_path repo)
          else playground_repo_entry_json ~source:"cache" ~repo_name:name repo
      | None -> repo)
  in
  let cached_names = List.filter_map repo_name_of_json cached in
  let fs_entries =
    filesystem_playground_repo_names playground_abs
    |> List.filter (fun name -> not (List.mem name cached_names))
    |> List.map (fun name ->
      playground_repo_entry_json ~source:"filesystem" ~repo_name:name
        (`Assoc []))
  in
  `List (cached @ fs_entries)
