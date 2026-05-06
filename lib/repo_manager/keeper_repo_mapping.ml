open Repo_manager_types

let ( let* ) = Result.bind

let logged_mapping_errors : (string, unit) Hashtbl.t = Hashtbl.create 4

let mappings_toml_path base_path =
  Filename.concat base_path ".masc/config/keeper_repo_mappings.toml"

let ensure_dir path =
  let rec loop dir =
    if dir = "" || dir = "." || Sys.file_exists dir then ()
    else begin
      loop (Filename.dirname dir);
      try Unix.mkdir dir 0o755
      with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  loop path

let mapping_of_toml toml keeper_id =
  let path field = ["mapping"; keeper_id; field] in
  let* repository_ids =
    Otoml.Helpers.find_strings_result toml (path "repositories")
  in
  let* github_credential_id =
    match Otoml.find_result toml Fun.id (path "credential_id") with
    | Error _ -> Ok None
    | Ok (Otoml.TomlString id) ->
        let id = String.trim id in
        Ok (if id = "" then None else Some id)
    | Ok _ ->
        Error
          (Printf.sprintf
             "mapping.%s.credential_id must be a string when present" keeper_id)
  in
  Ok { keeper_id; repository_ids; github_credential_id }

let credential_type_label = function
  | Github -> "GitHub"
  | Gitlab -> "GitLab"
  | Local -> "Local"

let toml_of_mapping mapping =
  let fields =
    [
      ( "repositories",
        Otoml.TomlArray
          (List.map (fun s -> Otoml.TomlString s) mapping.repository_ids) );
    ]
  in
  let fields =
    match mapping.github_credential_id with
    | Some id ->
        let id = String.trim id in
        if id = "" then fields
        else ("credential_id", Otoml.TomlString id) :: fields
    | None -> fields
  in
  Otoml.TomlTable fields

let load_all ~base_path =
  let path = mappings_toml_path base_path in
  if not (Sys.file_exists path) then Ok []
  else
    match Otoml.Parser.from_file_result path with
    | Error msg -> Error msg
    | Ok toml -> (
        match Otoml.find_result toml Fun.id ["mapping"] with
        | Error _ -> Ok []
        | Ok (Otoml.TomlTable fields | Otoml.TomlInlineTable fields) ->
            let rec loop acc = function
              | [] -> Ok (List.rev acc)
              | (keeper_id, value) :: rest -> (
                  match value with
                  | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
                      let mapping_toml =
                        Otoml.TomlTable [("mapping", Otoml.TomlTable [(keeper_id, value)])]
                      in
                      (match mapping_of_toml mapping_toml keeper_id with
                      | Ok mapping -> loop (mapping :: acc) rest
                      | Error msg -> Error msg)
                  | _ ->
                      Error
                        (Printf.sprintf "mapping.%s must be a table" keeper_id))
            in
            loop [] fields
        | Ok _ -> Ok [])

type mapping_lookup =
  | Mapping_found of keeper_repo_mapping
  | Mapping_missing of string
  | Mapping_load_error of string

let lookup_mapping ~base_path keeper_id =
  match load_all ~base_path with
  | Error msg -> Mapping_load_error msg
  | Ok mappings -> (
      match
        List.find_opt
          (fun (m : keeper_repo_mapping) -> String.equal m.keeper_id keeper_id)
          mappings
      with
      | Some mapping -> Mapping_found mapping
      | None -> Mapping_missing keeper_id)

let find_mapping ~base_path keeper_id =
  match lookup_mapping ~base_path keeper_id with
  | Mapping_found mapping -> Ok mapping
  | Mapping_missing keeper_id ->
      Error (Printf.sprintf "No mapping found for keeper: %s" keeper_id)
  | Mapping_load_error msg -> Error msg

let allowed_repositories ~keeper_id ~base_path =
  let* mapping = find_mapping ~base_path keeper_id in
  Ok mapping.repository_ids

(** Resolve the credentials currently mapped to [keeper_id], by looking
    through every repository the keeper is allowed to access and
    extracting each repository's [credential_id] into a unique list of
    [credential] records.

    Returns [Ok []] when the keeper has no mapping.  This is the
    backward-compatibility branch consumed by the credential provider
    bridge (RFC-0019 PR-A): a keeper without a mapping continues to use
    the legacy [Keeper_gh_env.keeper_binding] resolver.

    Repository IDs from the mapping are resolved against the loaded
    repositories; unknown repository IDs are ignored by this resolution path.

    Returns [Error _] on mapping load failures (including
    parse/validation failures) or when a credential referenced by a mapped
    repository cannot be found.  Absence of mapping is not an error. *)
let credentials_for_keeper ~base_path ~keeper_id =
  match lookup_mapping ~base_path keeper_id with
  | Mapping_missing _ -> Ok []
  | Mapping_load_error msg -> Error msg
  | Mapping_found mapping ->
      let resolve_credential id =
        match Credential_store.find ~base_path id with
        | Ok c -> Ok c
        | Error msg ->
            Error
              (Printf.sprintf
                 "credential %s referenced by mapping for keeper %s not found \
                  in credential store: %s"
                 id keeper_id msg)
      in
      (match mapping.github_credential_id with
      | Some id when String.trim id <> "" ->
          let id = String.trim id in
          let* credential = resolve_credential id in
          if credential.cred_type <> Github then
            Error
              (Printf.sprintf
                 "credential %s referenced by github_credential_id for keeper %s \
                  must be of type GitHub, got %s"
                 id keeper_id (credential_type_label credential.cred_type))
          else
            Ok [credential]
      | Some _ | None ->
      let* repos = Repo_store.load_all ~base_path in
      let mapped_repos =
        if List.exists (String.equal "*") mapping.repository_ids then
          repos
        else
          List.filter
            (fun (r : repository) ->
              List.exists (String.equal r.id) mapping.repository_ids)
            repos
      in
      (* Unique credential ids preserving first-seen order, so a keeper
         with several repos pointing at the same credential collapses to
         a single entry; the bridge can then dispatch deterministically. *)
      let cred_ids =
        List.fold_left
          (fun acc (r : repository) ->
            if List.mem r.credential_id acc then acc
            else r.credential_id :: acc)
          []
          mapped_repos
        |> List.rev
      in
      let rec resolve_creds acc = function
        | [] -> Ok (List.rev acc)
        | id :: rest -> (
            match resolve_credential id with
            | Ok c -> resolve_creds (c :: acc) rest
            | Error msg -> Error msg)
      in
      resolve_creds [] cred_ids)

let is_allowed ~keeper_id ~repository_id ~base_path =
  match lookup_mapping ~base_path keeper_id with
  | Mapping_missing _ -> true
  | Mapping_load_error msg ->
      if not (Hashtbl.mem logged_mapping_errors keeper_id) then begin
        Hashtbl.add logged_mapping_errors keeper_id ();
        Log.Misc.warn
          "[KeeperRepoMapping] is_allowed: mapping load error for keeper %s \
           — access control bypassed (error: %s)"
          keeper_id msg
      end;
      true
  | Mapping_found mapping ->
      List.exists
        (fun id -> String.equal id repository_id || String.equal id "*")
        mapping.repository_ids

let validate_access ~keeper_id ~repository_id ~base_path =
  if is_allowed ~keeper_id ~repository_id ~base_path then Ok ()
  else
    Error
      (Printf.sprintf "Keeper %s is not allowed to access repository %s"
         keeper_id repository_id)

let save_all ~base_path mappings =
  let path = mappings_toml_path base_path in
  let table =
    List.map
      (fun m -> (m.keeper_id, toml_of_mapping m))
      mappings
  in
  let toml = Otoml.TomlTable [("mapping", Otoml.TomlTable table)] in
  let dir = Filename.dirname path in
  ensure_dir dir;
  let content = Otoml.Printer.to_string toml in
  try
    let oc = open_out path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc content);
    Ok ()
  with Sys_error msg -> Error msg

let save_mapping ~base_path mapping =
  let* mappings = load_all ~base_path in
  let filtered =
    List.filter
      (fun (m : keeper_repo_mapping) ->
        not (String.equal m.keeper_id mapping.keeper_id))
      mappings
  in
  save_all ~base_path (mapping :: filtered)

let apply_mapping ~keeper_id ~base_path ~repositories =
  match lookup_mapping ~base_path keeper_id with
  | Mapping_missing _ -> repositories
  | Mapping_load_error msg ->
      Log.Misc.warn
        "[KeeperRepoMapping] apply_mapping: mapping load error for \
         keeper %s — returning unfiltered repositories (error: %s)"
        keeper_id msg;
      repositories
  | Mapping_found mapping ->
      if List.exists (String.equal "*") mapping.repository_ids then
        repositories
      else
        List.filter
          (fun (r : repository) ->
            List.exists (String.equal r.id) mapping.repository_ids)
          repositories

(* Path normalization for prefix comparison. *)
let normalize_path_for_prefix_check path =
  let p = String.trim path in
  if String.ends_with ~suffix:"/" p then
    String.sub p 0 (String.length p - 1)
  else p

let relative_under ~root path =
  let root_norm = normalize_path_for_prefix_check root in
  let path_norm = normalize_path_for_prefix_check path in
  if String.equal path_norm root_norm then Some ""
  else
    let prefix = root_norm ^ "/" in
    if String.starts_with ~prefix path_norm then
      Some
        (String.sub path_norm (String.length prefix)
           (String.length path_norm - String.length prefix))
    else None

let path_segments rel =
  String.split_on_char '/' rel
  |> List.filter (fun segment -> not (String.equal segment ""))

type playground_path =
  | Playground_internal
  | Playground_repos_root
  | Playground_repo of string

let playground_path_of_path ~base_path ~path =
  let playground_root =
    Filename.concat (Filename.concat base_path ".masc") "playground"
  in
  match relative_under ~root:playground_root path with
  | None -> None
  | Some rel -> (
      match path_segments rel with
      | "docker" :: _keeper :: "repos" :: repo_id :: _
      | _keeper :: "repos" :: repo_id :: _ ->
          Some (Playground_repo repo_id)
      | "docker" :: _keeper :: ["repos"]
      | _keeper :: ["repos"] ->
          Some Playground_repos_root
      | _ -> Some Playground_internal)

let basename_of_path path =
  normalize_path_for_prefix_check path |> Filename.basename

let repository_url_basename url =
  let stripped = normalize_path_for_prefix_check url in
  if stripped = "" then ""
  else
    let base = Filename.basename stripped in
    if Filename.check_suffix base ".git" then
      String.sub base 0 (String.length base - 4)
    else base

let resolve_repository_id_segment ~base_path segment =
  match Repo_store.load_all ~base_path with
  | Error msg ->
      Log.Misc.warn
        "[KeeperRepoMapping] resolve_repository_id_segment: repo store load \
         failed for segment %s (error: %s)"
        segment msg;
      segment
  | Ok repos -> (
      match
        List.find_opt
          (fun (repo : repository) ->
            String.equal repo.id segment
            || String.equal repo.name segment
            || String.equal (repository_url_basename repo.url) segment
            || String.equal
                 (basename_of_path (Repo_store.local_path ~base_path repo))
                 segment)
          repos
      with
      | Some repo -> repo.id
      | None -> segment)

(** [path_under_repo ~base_path repo path] returns [true] when [path]
    is equal to or strictly under [repo]'s resolved local_path. *)
let path_under_repo ~base_path repo path =
  let repo_path = Repo_store.local_path ~base_path repo in
  let repo_norm = normalize_path_for_prefix_check repo_path in
  let path_norm = normalize_path_for_prefix_check path in
  String.equal path_norm repo_norm
  || String.starts_with ~prefix:(repo_norm ^ "/") path_norm

(** [repository_id_of_path ~base_path ~path] returns the ID of the
    registered repository whose [local_path] contains [path], or [None]
    if the path is not under any registered repository. *)
let repository_id_of_path ~base_path ~path =
  match playground_path_of_path ~base_path ~path with
  | Some Playground_internal | Some Playground_repos_root -> None
  | Some (Playground_repo repo_id) ->
      Some (resolve_repository_id_segment ~base_path repo_id)
  | None -> (
  match Repo_store.load_all ~base_path with
  | Error msg ->
      Log.Misc.warn
        "[KeeperRepoMapping] repository_id_of_path: repo store load failed \
         for path %s (error: %s)"
        path msg;
      None
  | Ok repos -> (
      match
        List.find_opt (fun repo -> path_under_repo ~base_path repo path) repos
      with
      | Some repo -> Some repo.id
      | None -> None))

(** [validate_path_access ~keeper_id ~base_path ~path] checks whether
    [keeper_id] is allowed to access the repository that contains [path].
    If [path] is not under any registered repository, access is allowed.
    This is the integration point for keeper execution paths that operate
    on filesystem paths rather than explicit repository IDs. *)
let validate_path_access ~keeper_id ~base_path ~path =
  match repository_id_of_path ~base_path ~path with
  | None -> Ok ()
  | Some repo_id -> validate_access ~keeper_id ~repository_id:repo_id ~base_path
