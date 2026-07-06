open Repo_manager_types

let ( let* ) = Result.bind

let repos_toml_path base_path =
  (* RFC-0121: layout SSOT via [Config_dir_resolver]. Byte-equal to the
     previous direct concat (test_rfc0121_repositories_toml). *)
  Config_dir_resolver.repositories_toml_path ~base_path

let repositories_toml_exists base_path =
  Sys.file_exists (repos_toml_path base_path)

(* NB: [default_local_path] returns a cwd-relative path because it is the
   default value for the [local_path] field in repositories.toml; the
   on-disk TOML representation is cwd/base-path-relative by design.
   Resolver routing for this default is deferred — see RFC-0121 §6. *)
let default_local_path id = Filename.concat ".masc/repos" id

let now_unix_seconds () = Int64.of_float (Unix.time ())

let string_of_status = function
  | Active -> "Active"
  | Paused -> "Paused"
  | Cloning -> "Cloning"
  | Error _ -> "Error"

let status_of_string = function
  | "Active" | "active" -> Ok Active
  | "Paused" | "paused" -> Ok Paused
  | "Cloning" | "cloning" -> Ok Cloning
  | "Error" | "error" -> Ok (Error "")
  | s -> Error (Printf.sprintf "Unknown repository status: %s" s)

let repository_of_toml toml id =
  let ( let* ) = Result.bind in
  let path field = ["repository"; id; field] in
  (* RFC-0141 PR-2: Type_mismatch is propagated as Error instead of being
     silenced into [Ok default]. Missing fields still fall back to default. *)
  let find_string_default field default =
    Field_resolution.resolve_string toml (path field)
    |> Field_resolution.or_default ~default
  in
  let find_bool_default field default =
    Field_resolution.resolve_bool toml (path field)
    |> Field_resolution.or_default ~default
  in
  let find_int64_default field default =
    match Field_resolution.resolve_int toml (path field) with
    | Present v -> Ok (Int64.of_int v)
    | Missing -> Ok default
    | Type_mismatch { path; expected; message } ->
      Error
        (Printf.sprintf "TOML field %s: expected %s (%s)"
           (String.concat "." path) expected message)
  in
  let find_string_list_default field default =
    Field_resolution.resolve_strings toml (path field)
    |> Field_resolution.or_default ~default
  in
  let* name = Otoml.find_result toml Otoml.get_string (path "name") in
  let* url = Otoml.find_result toml Otoml.get_string (path "url") in
  let* local_path = find_string_default "local_path" (default_local_path id) in
  let* aliases = find_string_list_default "aliases" [] in
  let* default_branch = find_string_default "default_branch" "main" in
  let* keepers = find_string_list_default "keepers" [] in
  let* status_str = find_string_default "status" "Active" in
  let* status = status_of_string status_str in
  let status =
    match status with
    | Error _ -> (
        match Otoml.find_result toml Otoml.get_string (path "status_error") with
        | Ok msg -> Error msg
        | Error _ -> Error "")
    | Active | Paused | Cloning -> status
  in
  let* auto_sync = find_bool_default "auto_sync" false in
  let* sync_interval = find_int64_default "sync_interval" (Int64.of_int 300) in
  let* created_at = find_int64_default "created_at" Int64.zero in
  let* updated_at = find_int64_default "updated_at" Int64.zero in
  Ok
    {
      id;
      name;
      url;
      local_path;
      aliases;
      default_branch;
      keepers;
      status;
      auto_sync;
      sync_interval = Int64.to_int sync_interval;
      created_at;
      updated_at;
    }

let toml_of_repository repo =
  let fields =
    [
      ("name", Otoml.string repo.name);
      ("url", Otoml.string repo.url);
      ("local_path", Otoml.string repo.local_path);
      ( "aliases",
        Otoml.TomlArray (List.map (fun s -> Otoml.TomlString s) repo.aliases)
      );
      ("default_branch", Otoml.string repo.default_branch);
      ( "keepers",
        Otoml.TomlArray (List.map (fun s -> Otoml.TomlString s) repo.keepers)
      );
      ("status", Otoml.string (string_of_status repo.status));
      ("auto_sync", Otoml.boolean repo.auto_sync);
      ("sync_interval", Otoml.integer repo.sync_interval);
      ("created_at", Otoml.integer (Int64.to_int repo.created_at));
      ("updated_at", Otoml.integer (Int64.to_int repo.updated_at));
    ]
  in
  let fields =
    match repo.status with
    | Error msg when String.trim msg <> "" ->
        ("status_error", Otoml.string msg) :: fields
    | Error _ | Active | Paused | Cloning -> fields
  in
  Otoml.TomlTable fields

let load_all ~base_path =
  let path = repos_toml_path base_path in
  if not (Sys.file_exists path) then
    (* backward compatibility: treat base_path as a single default repository *)
    let now = now_unix_seconds () in
    Ok
      [
        {
          id = "default";
          name = Filename.basename base_path;
          url = "";
          local_path = base_path;
          aliases = [];
          default_branch = "main";
          keepers = [];
          status = Active;
          auto_sync = false;
          sync_interval = 0;
          created_at = now;
          updated_at = now;
        };
      ]
  else
    match Otoml.Parser.from_file_result path with
    | Error msg -> Error msg
    | Ok toml -> (
        match Otoml.find_result toml Fun.id ["repository"] with
        | Error _ -> Ok []
        | Ok (Otoml.TomlTable fields | Otoml.TomlInlineTable fields) ->
            let rec loop acc = function
              | [] -> Ok (List.rev acc)
              | (id, value) :: rest ->
                  if is_toml_table value then
                    let repo_toml =
                      Otoml.TomlTable
                        [("repository", Otoml.TomlTable [(id, value)])]
                    in
                    (match repository_of_toml repo_toml id with
                    | Ok repo -> loop (repo :: acc) rest
                    | Error msg -> Error msg)
                  else
                    Error (Printf.sprintf "repository.%s must be a table" id)
            in
            loop [] fields
        | Ok (Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
             | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
             | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
             | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _) ->
            Ok [])

let save_all ~base_path (repos : repository list) =
  let path = repos_toml_path base_path in
  let config_dir = Filename.dirname path in
  Fs_compat.mkdir_p config_dir;
  let repo_entries =
    List.map (fun (repo : repository) -> (repo.id, toml_of_repository repo)) repos
  in
  let toml = Otoml.TomlTable [("repository", Otoml.TomlTable repo_entries)] in
  let content = Otoml.Printer.to_string toml in
  try
    let oc = open_out path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc content);
    Ok ()
  with
  | Sys_error msg -> Error msg
  | Unix.Unix_error (err, _, _) -> Error (Unix.error_message err)
  | Failure msg -> Error msg

let find ~base_path id =
  let* repos = load_all ~base_path in
  match List.find_opt (fun (r : repository) -> String.equal r.id id) repos with
  | Some repo -> Ok repo
  | None -> Error (Printf.sprintf "Repository not found: %s" id)

let add ~base_path (repo : repository) =
  let* repos = load_all ~base_path in
  if List.exists (fun (r : repository) -> String.equal r.id repo.id) repos then
    Error (Printf.sprintf "Repository already exists: %s" repo.id)
  else
    let now = now_unix_seconds () in
    let repo =
      {
        repo with
        local_path =
          (if String.trim repo.local_path = "" then default_local_path repo.id
           else repo.local_path);
        created_at = (if Int64.equal repo.created_at Int64.zero then now else repo.created_at);
        updated_at = (if Int64.equal repo.updated_at Int64.zero then now else repo.updated_at);
      }
    in
    let* () = save_all ~base_path (repo :: repos) in
    Ok repo

let remove ~base_path id =
  let* repos = load_all ~base_path in
  let filtered =
    List.filter (fun (r : repository) -> not (String.equal r.id id)) repos
  in
  if List.length filtered = List.length repos then
    Error (Printf.sprintf "Repository not found: %s" id)
  else
    save_all ~base_path filtered

let update_status ~base_path id status =
  let* repos = load_all ~base_path in
  let found = ref false in
  let now = now_unix_seconds () in
  let updated =
    List.map
      (fun (r : repository) ->
        if String.equal r.id id then (
          found := true;
          { r with status; updated_at = now })
        else r)
      repos
  in
  if not !found then Error (Printf.sprintf "Repository not found: %s" id)
  else save_all ~base_path updated

let update ~base_path id (repo : repository) =
  let* repos = load_all ~base_path in
  let now = now_unix_seconds () in
  let result : (repository, string) Stdlib.result ref =
    ref (Stdlib.Error (Printf.sprintf "Repository not found: %s" id))
  in
  let updated =
    List.map
      (fun (r : repository) ->
        if String.equal r.id id then
          let normalised =
            {
              repo with
              id;
              local_path =
                (if String.trim repo.local_path = "" then default_local_path id
                 else repo.local_path);
              created_at = r.created_at;
              updated_at = now;
            }
          in
          result := Stdlib.Ok normalised;
          normalised
        else r)
      repos
  in
  match !result with
  | Stdlib.Error _ as e -> e
  | Stdlib.Ok _ ->
      let* () = save_all ~base_path updated in
      !result

let local_path ~base_path repo =
  if Filename.is_relative repo.local_path then
    Filename.concat base_path repo.local_path
  else
    repo.local_path

let list_branches ~base_path id : (string list, string) result =
  let* repo = find ~base_path id in
  let path = local_path ~base_path repo in
  let* branches = Repo_git.get_branches ~repository:{ repo with local_path = path } in
  let normalize b =
    if String.starts_with ~prefix:"origin/" b then
      String.sub b 7 (String.length b - 7)
    else
      b
  in
  Ok (List.filter (fun b -> b <> "HEAD") (List.map normalize branches))

let slugify_id s =
  String.map
    (fun c ->
      match c with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> c
      | _ -> '-')
    s

let is_directory path = try Sys.is_directory path with Sys_error _ -> false

let is_symlink path =
  try (Unix.lstat path).st_kind = Unix.S_LNK
  with Unix.Unix_error _ | Sys_error _ -> false

let is_real_directory path = is_directory path && not (is_symlink path)
let is_hidden_name name = String.length name > 0 && Char.equal name.[0] '.'

let discover_git_dirs ~base_path =
  let max_git_depth = 4 in
  let rec scan_dir ~depth dir acc =
    let git_dir = Filename.concat dir ".git" in
    let acc =
      if depth + 1 <= max_git_depth && is_real_directory git_dir then git_dir :: acc
      else acc
    in
    if depth >= max_git_depth - 1 then acc
    else
      let entries =
        try Sys.readdir dir with Sys_error _ | Unix.Unix_error _ -> [||]
      in
      Array.fold_left
        (fun acc name ->
          if String.equal name "." || String.equal name ".." || is_hidden_name name
          then
            acc
          else
            let child = Filename.concat dir name in
            if is_real_directory child then scan_dir ~depth:(depth + 1) child acc
            else acc)
        acc
        entries
  in
  if is_real_directory base_path then List.rev (scan_dir ~depth:0 base_path [])
  else []

(* Pure path normalization fallback for environments where the path does
   not exist on disk yet (Unix.realpath would raise) or Unix is
   unavailable.  Drops empty segments and "."; folds ".." against the
   accumulator. *)
let normalize_path raw =
  if String.length raw = 0 then raw
  else
    let absolute = Char.equal raw.[0] '/' in
    let parts = String.split_on_char '/' raw in
    let acc = ref [] in
    List.iter
      (fun p ->
        match p with
        | "" | "." -> ()
        | ".." -> (match !acc with _ :: rest -> acc := rest | [] -> ())
        | _ -> acc := p :: !acc)
      parts;
    let body = String.concat "/" (List.rev !acc) in
    if absolute then "/" ^ body
    else if String.equal body "" then "."
    else body

let canonical_path raw =
  try Unix.realpath raw
  with Unix.Unix_error _ | Sys_error _ -> normalize_path raw

type discovery_error =
  | Discovery_origin_read_failed of
      { local_path : string
      ; error : string
      }

let discovery_error_to_string = function
  | Discovery_origin_read_failed { local_path; error } ->
    Printf.sprintf "repository %s origin read failed: %s" local_path error

let discover_repositories ~base_path =
  let toml_exists = repositories_toml_exists base_path in
  (* Issue #13188 + #13217 review: [find <base_path>] echoes the
     search-path prefix in every result, and a relative base_path
     (e.g. ["workspace"]) used to duplicate via [Filename.concat
     base_path repo_dir].  Beyond simple absolute conversion we also
     have to canonicalize because [Filename.concat (Sys.getcwd ())
     "."] yields ["/cwd/."] — find would then emit ["/cwd/./repo"],
     which [String.equal] does not match against existing repos
     stored as ["/cwd/repo"] and silently rediscovers them.  Resolve
     [base_path] to its canonical absolute form (symlinks + ".."
     + redundant "." collapsed) before invoking [find] so every
     downstream comparison sees a single normalized representation. *)
  let abs_base_path = canonical_path base_path in
  let existing_paths =
    match load_all ~base_path with
    | Ok repos ->
      repos
      |> List.filter (fun (r : repository) ->
            (* Reviewer #13217: legacy-default detection used to compare
               [local_path r] against [base_path] textually.  When
               [base_path = "."] and [repo.local_path = "."],
               [local_path] concatenates to ["./."] which does not
               equal [base_path] — the default repo then leaks into
               [existing_paths], causing the real repo at base_path to
               be classified as "already known" and skipped.  Compare
               raw [r.local_path] against [base_path] directly so the
               relative-default case is detected without going through
               [Filename.concat]. *)
            not
              ((not toml_exists)
               && String.equal r.id "default"
               && String.equal r.local_path base_path))
      |> List.map (fun (r : repository) ->
            canonical_path (local_path ~base_path:abs_base_path r))
      |> fun paths -> Ok paths
    | Error msg ->
      Error
        (Printf.sprintf
           "repository store read failed during discovery for base_path=%S: %s"
           base_path
           msg)
  in
  let* existing_paths = existing_paths in
  let git_dirs = discover_git_dirs ~base_path:abs_base_path in
  let has_hidden_segment_under_base path =
    if String.equal path abs_base_path then false
    else
      let base_prefix =
        if String.length abs_base_path > 0
           && Char.equal abs_base_path.[String.length abs_base_path - 1] '/'
        then abs_base_path
        else abs_base_path ^ "/"
      in
      let prefix_len = String.length base_prefix in
      if
        String.length path < prefix_len
        || not (String.equal (String.sub path 0 prefix_len) base_prefix)
      then false
      else
        let rel =
          String.sub path prefix_len (String.length path - prefix_len)
        in
        rel
        |> String.split_on_char '/'
        |> List.exists (fun segment ->
               String.length segment > 0
               && (not (String.equal segment "." || String.equal segment ".."))
               && Char.equal segment.[0] '.')
  in
  let rec collect_candidates candidates errors = function
    | [] ->
      (match errors with
       | [] -> Ok (List.rev candidates)
       | _ ->
         Error
           (String.concat
              "; "
              (List.rev_map discovery_error_to_string errors)))
    | git_dir :: rest ->
        (* Canonicalize again here in case find traversed a symlink the
           caller did not anticipate; the existing-repo membership check
           below relies on identical normalized representations. *)
        let abs_repo_dir = canonical_path (Filename.dirname git_dir) in
        if has_hidden_segment_under_base abs_repo_dir
        then collect_candidates candidates errors rest
        else if List.exists (String.equal abs_repo_dir) existing_paths
        then collect_candidates candidates errors rest
        else
          match Repo_git.get_origin_url ~local_path:abs_repo_dir with
          | Ok url ->
            let name = Filename.basename abs_repo_dir in
            let id = slugify_id name in
            let candidate =
              { id
              ; name
              ; url
              ; local_path = abs_repo_dir
              ; aliases = []
              ; default_branch = "main"
              ; keepers = []
              ; status = Active
              ; auto_sync = false
              ; sync_interval = 0
              ; created_at = Int64.zero
              ; updated_at = Int64.zero
              }
            in
            collect_candidates (candidate :: candidates) errors rest
          | Error error ->
            let error = Discovery_origin_read_failed { local_path = abs_repo_dir; error } in
            collect_candidates candidates (error :: errors) rest
  in
  collect_candidates [] [] git_dirs

let register_discovered ~base_path =
  let* candidates = discover_repositories ~base_path in
  let* existing =
    if repositories_toml_exists base_path then load_all ~base_path else Ok []
  in
  let existing_ids = List.map (fun (r : repository) -> r.id) existing in
  let timestamp = now_unix_seconds () in
  let rec collect seen_ids acc = function
    | [] -> List.rev acc
    | (candidate : repository) :: rest ->
        if List.exists (String.equal candidate.id) seen_ids then
          collect seen_ids acc rest
        else
          let registered =
            { candidate with created_at = timestamp; updated_at = timestamp }
          in
          collect (candidate.id :: seen_ids) (registered :: acc) rest
  in
  match collect existing_ids [] candidates with
  | [] -> Ok []
  | registered ->
      let* () = save_all ~base_path (existing @ registered) in
      Ok registered

module Lookup = Repo_store_lookup.Make (struct
  let load_all = load_all
  let local_path = local_path
end)

let find_url_by_id_result = Lookup.find_url_by_id_result
let find_url_by_id = Lookup.find_url_by_id
let find_repo_by_path_prefix_result = Lookup.find_repo_by_path_prefix_result
let find_repo_by_path_prefix = Lookup.find_repo_by_path_prefix
