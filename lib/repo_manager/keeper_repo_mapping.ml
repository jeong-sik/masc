open Repo_manager_types

let ( let* ) = Result.bind

let mappings_toml_path base_path =
  Filename.concat base_path ".masc/config/keeper_repo_mappings.toml"

let mapping_of_toml toml keeper_id =
  let path field = ["mapping"; keeper_id; field] in
  let* repository_ids =
    Otoml.Helpers.find_strings_result toml (path "repositories")
  in
  Ok { keeper_id; repository_ids }

let toml_of_mapping mapping =
  Otoml.TomlTable
    [
      ( "repositories",
        Otoml.TomlArray
          (List.map (fun s -> Otoml.TomlString s) mapping.repository_ids) );
    ]

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

let find_mapping ~base_path keeper_id =
  let* mappings = load_all ~base_path in
  match
    List.find_opt
      (fun (m : keeper_repo_mapping) -> String.equal m.keeper_id keeper_id)
      mappings
  with
  | Some mapping -> Ok mapping
  | None -> Error (Printf.sprintf "No mapping found for keeper: %s" keeper_id)

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

    Returns [Error _] only on infrastructure failure (mapping store
    unreadable, repository not found, credential not found).  Absence of
    mapping is not an error. *)
let credentials_for_keeper ~base_path ~keeper_id =
  match find_mapping ~base_path keeper_id with
  | Error _ -> Ok []
  | Ok mapping ->
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
            match Credential_store.find ~base_path id with
            | Ok c -> resolve_creds (c :: acc) rest
            | Error msg ->
                Error
                  (Printf.sprintf
                     "credential %s referenced by mapping for keeper %s \
                      not found in credential store: %s"
                     id keeper_id msg))
      in
      resolve_creds [] cred_ids

let is_allowed ~keeper_id ~repository_id ~base_path =
  match find_mapping ~base_path keeper_id with
  | Error _ -> true
  | Ok mapping ->
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
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let content = Otoml.Printer.to_string toml in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content);
  Ok ()

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
  match find_mapping ~base_path keeper_id with
  | Error _ -> repositories
  | Ok mapping ->
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
  if String.length p > 0 && p.[String.length p - 1] = '/' then
    String.sub p 0 (String.length p - 1)
  else p

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
  match Repo_store.load_all ~base_path with
  | Error _ -> None
  | Ok repos -> (
      match
        List.find_opt (fun repo -> path_under_repo ~base_path repo path) repos
      with
      | Some repo -> Some repo.id
      | None -> None)

(** [validate_path_access ~keeper_id ~base_path ~path] checks whether
    [keeper_id] is allowed to access the repository that contains [path].
    If [path] is not under any registered repository, access is allowed.
    This is the integration point for keeper execution paths that operate
    on filesystem paths rather than explicit repository IDs. *)
let validate_path_access ~keeper_id ~base_path ~path =
  match repository_id_of_path ~base_path ~path with
  | None -> Ok ()
  | Some repo_id -> validate_access ~keeper_id ~repository_id:repo_id ~base_path
