open Repo_manager_types

let ( let* ) = Result.bind

let repos_toml_path base_path =
  (* RFC-0121: layout SSOT via [Config_dir_resolver]. Byte-equal to the
     previous direct concat (test_rfc0121_repositories_toml). *)
  Config_dir_resolver.repositories_toml_path ~base_path

let now_unix_seconds () = Int64.of_float (Unix.time ())

let string_of_status = function
  | Active -> "Active"
  | Paused -> "Paused"
  | Cloning -> "Cloning"
  | Error _ -> "Error"

let repository_field_names =
  [
    "name";
    "url";
    "local_path";
    "aliases";
    "default_branch";
    "keepers";
    "status";
    "status_error";
    "auto_sync";
    "sync_interval";
    "created_at";
    "updated_at";
  ]

let repository_of_toml toml id =
  let path field = ["repository"; id; field] in
  let required field = function
    | Field_resolution.Present value -> Ok value
    | Missing ->
      Error
        (Printf.sprintf "repositories.toml: required field %s is absent"
           (String.concat "." (path field)))
    | Type_mismatch { path; expected; message } ->
      Error
        (Printf.sprintf "repositories.toml: field %s must be %s (%s)"
           (String.concat "." path) expected message)
  in
  let required_string field =
    required field (Field_resolution.resolve_string toml (path field))
  in
  let required_bool field =
    required field (Field_resolution.resolve_bool toml (path field))
  in
  let required_int field =
    required field (Field_resolution.resolve_int toml (path field))
  in
  let required_strings field =
    required field (Field_resolution.resolve_strings toml (path field))
  in
  let require_no_status_error () =
    match Field_resolution.resolve_string toml (path "status_error") with
    | Missing -> Ok ()
    | Present _ ->
      Error
        (Printf.sprintf
           "repositories.toml: field %s is only valid when status is Error"
           (String.concat "." (path "status_error")))
    | Type_mismatch { path; expected; message } ->
      Error
        (Printf.sprintf "repositories.toml: field %s must be %s (%s)"
           (String.concat "." path) expected message)
  in
  let* name = required_string "name" in
  let* url = required_string "url" in
  let* local_path = required_string "local_path" in
  let* aliases = required_strings "aliases" in
  let* default_branch = required_string "default_branch" in
  let* keepers = required_strings "keepers" in
  let* status_name = required_string "status" in
  let* status =
    match status_name with
    | "Active" ->
      let* () = require_no_status_error () in
      Ok Active
    | "Paused" ->
      let* () = require_no_status_error () in
      Ok Paused
    | "Cloning" ->
      let* () = require_no_status_error () in
      Ok Cloning
    | "Error" ->
      let* message = required_string "status_error" in
      Ok (Error message)
    | value ->
      Error (Printf.sprintf "Unknown repository status: %s" value)
  in
  let* auto_sync = required_bool "auto_sync" in
  let* sync_interval = required_int "sync_interval" in
  let* created_at = required_int "created_at" in
  let* updated_at = required_int "updated_at" in
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
      sync_interval;
      created_at = Int64.of_int created_at;
      updated_at = Int64.of_int updated_at;
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
    | Error msg -> ("status_error", Otoml.string msg) :: fields
    | Active | Paused | Cloning -> fields
  in
  Otoml.TomlTable fields

let load_all ~base_path =
  let path = repos_toml_path base_path in
  if not (Sys.file_exists path) then
    Ok []
  else
    match Otoml.Parser.from_file_result path with
    | Error msg -> Error msg
    | Ok toml -> (
        match Otoml.get_table toml with
        | exception Otoml.Type_error message ->
          Error
            (Printf.sprintf
               "repositories.toml: top level must be a table (%s)" message)
        | top_level_fields ->
          match
            List.find_opt
              (fun (field, _) -> not (String.equal field "repository"))
              top_level_fields
          with
          | Some (field, _) ->
            Error
              (Printf.sprintf
                 "repositories.toml: unknown top-level field %s" field)
          | None -> (
            match List.assoc_opt "repository" top_level_fields with
            | None ->
              Error "repositories.toml: required repository table is absent"
            | Some (Otoml.TomlTable fields | Otoml.TomlInlineTable fields) ->
            let rec loop acc = function
              | [] -> Ok (List.rev acc)
              | (id, value) :: rest ->
                  (match value with
                  | Otoml.TomlTable row_fields | Otoml.TomlInlineTable row_fields ->
                    (match
                       List.find_opt
                         (fun (field, _) ->
                           not (List.mem field repository_field_names))
                         row_fields
                     with
                    | Some (field, _) ->
                      Error
                        (Printf.sprintf
                           "repositories.toml: unknown field repository.%s.%s"
                           id field)
                    | None ->
                    let repo_toml =
                      Otoml.TomlTable
                        [("repository", Otoml.TomlTable [(id, value)])]
                    in
                    (match repository_of_toml repo_toml id with
                    | Ok repo -> loop (repo :: acc) rest
                    | Error msg -> Error msg))
                  | Otoml.TomlString _ | Otoml.TomlInteger _
                  | Otoml.TomlFloat _ | Otoml.TomlBoolean _
                  | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
                  | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
                  | Otoml.TomlArray _ | Otoml.TomlTableArray _ ->
                    Error (Printf.sprintf "repository.%s must be a table" id))
            in
            (* Two records naming the same upstream is not a preference the
               loader can resolve: they clone to different directory names, so
               a keeper reaching one by id and another by path basename ends up
               in different checkouts of the same repository. That is what
               produced the cwd_not_directory failures in #21837. Rejecting at
               load makes the operator collapse them; the [aliases] field is
               not the answer, since routing an alias would hide the duplicate
               instead of removing it. *)
            let reject_duplicate_upstream repos =
              let seen = Hashtbl.create 16 in
              let rec check = function
                | [] -> Ok repos
                | (repo : Repo_manager_types.repository) :: rest ->
                  (match Agent_observation.canonical_url_of_remote repo.url with
                   | None -> check rest
                   | Some canonical ->
                     (match Hashtbl.find_opt seen canonical with
                      | Some earlier ->
                        Error
                          (Printf.sprintf
                             "repositories.toml: repository.%s and repository.%s both \
                              point at %s. One upstream admits one record; merge them \
                              and reprovision the checkouts to a single directory name."
                             earlier
                             repo.id
                             canonical)
                      | None ->
                        Hashtbl.add seen canonical repo.id;
                        check rest))
              in
              check repos
            in
            Result.bind (loop [] fields) reject_duplicate_upstream
            | Some (Otoml.TomlString _ | Otoml.TomlInteger _
                   | Otoml.TomlFloat _ | Otoml.TomlBoolean _
                   | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
                   | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
                   | Otoml.TomlArray _ | Otoml.TomlTableArray _) ->
              Error "repositories.toml: repository must be a table"))

let write_all ~base_path (repos : repository list) =
  let path = repos_toml_path base_path in
  let config_dir = Filename.dirname path in
  Fs_compat.mkdir_p config_dir;
  let repo_entries =
    List.map (fun (repo : repository) -> (repo.id, toml_of_repository repo)) repos
  in
  let toml = Otoml.TomlTable [("repository", Otoml.TomlTable repo_entries)] in
  let content = Otoml.Printer.to_string toml in
  Fs_compat.save_file_atomic_strict path content

let with_store_lock ~base_path (f : unit -> ('value, string) result) :
    ('value, string) result =
  let path = repos_toml_path base_path in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    File_lock_eio.with_lock path f
  with
  | File_lock_eio.Flock_timeout { path; attempts; _ } ->
    Stdlib.Error
      (Printf.sprintf
         "timed out acquiring repository catalog lock %s after %d attempts"
         path attempts)
  | Sys_error message -> Stdlib.Error message

let save_all ~base_path repos =
  with_store_lock ~base_path (fun () -> write_all ~base_path repos)

let find ~base_path id =
  let* repos = load_all ~base_path in
  match List.find_opt (fun (r : repository) -> String.equal r.id id) repos with
  | Some repo -> Ok repo
  | None -> Error (Printf.sprintf "Repository not found: %s" id)

let add ~base_path (repo : repository) =
  if String.trim repo.local_path = "" then
    Stdlib.Error "Repository local_path must be non-empty"
  else
    with_store_lock ~base_path (fun () ->
      let* repos = load_all ~base_path in
      if List.exists (fun (r : repository) -> String.equal r.id repo.id) repos then
        Error (Printf.sprintf "Repository already exists: %s" repo.id)
      else
        let now = now_unix_seconds () in
        let repo =
          {
            repo with
            created_at = now;
            updated_at = now;
          }
        in
        let* () = write_all ~base_path (repo :: repos) in
        Ok repo)

let remove ~base_path id =
  with_store_lock ~base_path (fun () ->
      let* repos = load_all ~base_path in
      let filtered =
        List.filter (fun (r : repository) -> not (String.equal r.id id)) repos
      in
      if List.length filtered = List.length repos then
        Error (Printf.sprintf "Repository not found: %s" id)
      else
        write_all ~base_path filtered)

let update_status ~base_path id status =
  with_store_lock ~base_path (fun () ->
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
      else write_all ~base_path updated)

let update ~base_path id (repo : repository) =
  if String.trim repo.local_path = "" then
    Stdlib.Error "Repository local_path must be non-empty"
  else
    with_store_lock ~base_path (fun () ->
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
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok persisted ->
        let* () = write_all ~base_path updated in
        Ok persisted)

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

let discovery_skip_log_line ~abs_repo_dir ~detail =
  Printf.sprintf
    "repo discovery skipped %S: origin unavailable (%S)"
    abs_repo_dir
    detail
;;

let discover_repositories_with_budget_impl
    ~before_origin_inspection
    ~origin_budget_sec
    ~base_path
  =
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
  let* repositories = load_all ~base_path in
  let existing_paths =
    List.map
      (fun (repo : repository) ->
        canonical_path (local_path ~base_path:abs_base_path repo))
      repositories
  in
  let git_dirs = discover_git_dirs ~base_path:abs_base_path in
  before_origin_inspection ();
  let budget = Repo_git.Inspection_budget.create ~timeout_sec:origin_budget_sec () in
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
  let rec collect_candidates inspected acc = function
    | [] -> Ok (List.rev acc)
    | git_dir :: rest ->
        (* Canonicalize again here in case find traversed a symlink the
           caller did not anticipate; the existing-repo membership check
           below relies on identical normalized representations. *)
        let abs_repo_dir = canonical_path (Filename.dirname git_dir) in
        if has_hidden_segment_under_base abs_repo_dir
        then collect_candidates inspected acc rest
        else if List.exists (String.equal abs_repo_dir) existing_paths
        then collect_candidates inspected acc rest
        else
          (match Repo_git.Inspection_budget.remaining_timeout budget with
           | Error _ ->
             Error
               (Printf.sprintf
                  "repository origin inspection budget exhausted after %d candidates"
                  inspected)
           | Ok timeout_sec ->
             (match
                Repo_git.get_origin_url ~timeout_sec ~local_path:abs_repo_dir ()
              with
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
              collect_candidates (inspected + 1) (candidate :: acc) rest
              (* Typed origin failures let a real timeout fail the incomplete
                 scan while a missing remote remains a normal skip. The
                 rendered fields use OCaml string escaping so repository
                 names and Git stderr cannot inject terminal controls or forge
                 a second log line. *)
              | Error detail ->
                let detail_text = Repo_git.origin_lookup_error_to_string detail in
                Log.Misc.warn "%s"
                  (discovery_skip_log_line ~abs_repo_dir ~detail:detail_text);
                (match detail with
                 | Repo_git.Origin_lookup_timed_out _ ->
                   Error
                     (Printf.sprintf
                        "repository origin inspection budget exhausted after %d candidates"
                        (inspected + 1))
                 | Repo_git.Origin_missing
                 | Repo_git.Origin_lookup_failed _ ->
                   collect_candidates (inspected + 1) acc rest)))
  in
  collect_candidates 0 [] git_dirs
;;

let discover_repositories_with_budget ~origin_budget_sec ~base_path =
  discover_repositories_with_budget_impl
    ~before_origin_inspection:(fun () -> ())
    ~origin_budget_sec
    ~base_path
;;

let discover_repositories ~base_path =
  discover_repositories_with_budget
    ~origin_budget_sec:Repo_git.inspection_timeout_sec
    ~base_path
;;

module For_testing = struct
  let discover_repositories_with_budget = discover_repositories_with_budget
  let discover_repositories_with_budget_after_scan
      ~before_origin_inspection
      ~origin_budget_sec
      ~base_path
    =
    discover_repositories_with_budget_impl
      ~before_origin_inspection
      ~origin_budget_sec
      ~base_path
  ;;

  let discovery_skip_log_line = discovery_skip_log_line
end

let register_discovered ~base_path =
  let* candidates = discover_repositories ~base_path in
  with_store_lock ~base_path (fun () ->
      let* existing = load_all ~base_path in
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
        let* () = write_all ~base_path (existing @ registered) in
        Ok registered)

let strip_trailing_slash path =
  let length = String.length path in
  if length > 0 && Char.equal path.[length - 1] '/' then
    String.sub path 0 (length - 1)
  else path

let is_path_prefix ~prefix path =
  let prefix = strip_trailing_slash prefix in
  let prefix_length = String.length prefix in
  if prefix_length = 0 then false
  else if String.length path = prefix_length && String.equal path prefix then true
  else
    String.length path > prefix_length
    && String.equal (String.sub path 0 prefix_length) prefix
    && Char.equal path.[prefix_length] '/'

let rel_under_path ~prefix path =
  let prefix = strip_trailing_slash prefix in
  let prefix_length = String.length prefix in
  if String.length path = prefix_length then ""
  else
    String.sub path (prefix_length + 1)
      (String.length path - prefix_length - 1)

let find_url_by_id ~base_path id =
  let* repositories = load_all ~base_path in
  Ok
    (match
       List.find_opt
         (fun (repository : repository) -> String.equal repository.id id)
         repositories
     with
     | Some repository when not (String.equal repository.url "") ->
       Some repository.url
     | Some _ | None -> None)

let find_repo_by_path_prefix ~base_path path =
  let* repositories = load_all ~base_path in
  let candidates =
    List.filter_map
      (fun (repository : repository) ->
        let repository_path = local_path ~base_path repository in
        if is_path_prefix ~prefix:repository_path path then
          Some
            ( repository,
              repository_path,
              rel_under_path ~prefix:repository_path path )
        else None)
      repositories
  in
  let longest =
    match candidates with
    | [] -> None
    | first :: rest ->
      Some
        (List.fold_left
           (fun ((_, best_path, _) as best)
                ((_, candidate_path, _) as candidate) ->
             if String.length candidate_path > String.length best_path then
               candidate
             else best)
           first rest)
  in
  Ok (Option.map (fun (repository, _, rel) -> (repository, rel)) longest)
