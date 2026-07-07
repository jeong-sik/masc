open Repo_manager_types

let ( let* ) = Result.bind

module String_map = Map.Make (String)
module String_set = Set.Make (String)

(** Keep per-path/keeper auxiliary maps bounded. These maps are operational
    caches, not correctness state: on overflow we drop the old contents and
    keep the new entry so long-lived processes cannot grow without bound. *)
let max_load_all_cache_entries = 256
let max_logged_mapping_error_entries = 1024

let bounded_add key value map ~max_entries =
  let map =
    if String_map.mem key map || String_map.cardinal map < max_entries
    then map
    else String_map.empty
  in
  String_map.add key value map
;;

(** Fiber/domain-safe set of keepers for whom a mapping load error has already
    been logged. Using an immutable [Map] under [Atomic] avoids locking an
    Eio fiber while still deduplicating warnings. *)
let logged_mapping_errors : unit String_map.t Atomic.t =
  Atomic.make String_map.empty

let mappings_toml_basename = "keeper_repo_mappings.toml"

let mappings_toml_path base_path =
  (* RFC-0121: layout SSOT via [Config_dir_resolver]. *)
  Config_dir_resolver.keeper_repo_mappings_toml_path ~base_path

let mapping_of_toml toml keeper_id =
  let path field = ["mapping"; keeper_id; field] in
  let* repository_ids =
    Otoml.Helpers.find_strings_result toml (path "repositories")
  in
  Ok (make_keeper_repo_mapping ~keeper_id ~repository_ids)

let toml_of_mapping mapping =
  let fields =
    [
      ( "repositories",
        Otoml.TomlArray
          (List.map (fun s -> Otoml.TomlString s) mapping.repository_ids) );
    ]
  in
  Otoml.TomlTable fields

(** A [mapping_file_stamp] identifies one concrete version of the mapping file.
    It carries inode and a content digest in addition to mtime/size so that
    replacement edits that happen to preserve size and mtime still invalidate
    the cache. *)
type mapping_file_stamp =
  { mtime : float
  ; size : int
  ; inode : int64
  ; content_digest : string
  }

(** [file_snapshot] pairs the bytes read from disk with the metadata that was
    observed at read time. *)
type file_snapshot =
  { stamp : mapping_file_stamp
  ; content : string
  }

let log_mapping_file_warning path msg =
  Log.Misc.warn
    "[KeeperRepoMapping] mapping file %s unreadable — advisory mapping ignored (%s)"
    path msg
;;

let load_file_content path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

(** [read_mapping_file ~base_path] returns the current file snapshot, [None]
    when the file is absent, or [Error] when it exists but cannot be read.
    All [Unix.Unix_error] variants are caught so that a stat/read failure is
    never propagated as an exception to enforcement callers. *)
let read_mapping_file ~base_path : (file_snapshot option, string) result =
  Eio_guard.run_in_systhread (fun () ->
    let path = mappings_toml_path base_path in
    match Unix.stat path with
    | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> Ok None
    | exception Unix.Unix_error (e, _, _) ->
        let msg = Unix.error_message e in
        log_mapping_file_warning path msg;
        Error msg
    | exception Sys_error msg ->
        log_mapping_file_warning path msg;
        Error msg
    | stat -> (
        match load_file_content path with
        | exception Sys_error msg when not (Sys.file_exists path) ->
            (* The file disappeared between stat and read; treat as absent. *)
            Ok None
        | exception Sys_error msg ->
            log_mapping_file_warning path msg;
            Error msg
        | exception End_of_file ->
            let msg = "unexpected end of mapping file" in
            log_mapping_file_warning path msg;
            Error msg
        | content ->
            let stamp =
              { mtime = stat.Unix.st_mtime
              ; size = stat.Unix.st_size
              ; inode = Int64.of_int stat.Unix.st_ino
              ; content_digest = Digest.string content
              }
            in
            Ok (Some { stamp; content })))
;;

let toml_table_fields t =
  try Some (Otoml.get_table t) with
  | Otoml.Type_error _ -> None
;;

let parse_mapping_content content : (keeper_repo_mapping list, string) result =
  match Otoml.Parser.from_string_result content with
  | Error msg -> Error msg
  | Ok toml -> (
      match Otoml.find_opt toml Fun.id ["mapping"] with
      | None -> Ok []
      | Some mapping -> (
          match toml_table_fields mapping with
          | Some fields ->
              let rec loop acc = function
                | [] -> Ok (List.rev acc)
                | (keeper_id, value) :: rest ->
                    if is_toml_table value then
                      let mapping_toml =
                        Otoml.TomlTable [("mapping", Otoml.TomlTable [(keeper_id, value)])]
                      in
                      (match mapping_of_toml mapping_toml keeper_id with
                       | Ok mapping -> loop (mapping :: acc) rest
                       | Error msg -> Error msg)
                    else
                      Error (Printf.sprintf "mapping.%s must be a table" keeper_id)
              in
              loop [] fields
          | None -> Error "mapping field must be a table"))

let load_all ~base_path : (keeper_repo_mapping list, string) result =
  let* snapshot = read_mapping_file ~base_path in
  match snapshot with
  | None -> Ok []
  | Some { content; _ } -> parse_mapping_content content

(** Cache for [load_all] results keyed by [base_path]. Each entry carries the
    mapping file stamp so out-of-process TOML edits invalidate the cache before
    repository-scope decisions reuse it. Writes through this module remove the
    entry explicitly. The immutable [Map] + [Atomic] design is fiber-safe
    without requiring an Eio mutex to be threaded through every caller. *)
type load_all_cache_entry =
  { stamp : mapping_file_stamp option
  ; result : (keeper_repo_mapping list, string) result
  }

let stamp_equal left right =
  Float.equal left.mtime right.mtime
  && Int.equal left.size right.size
  && Int64.equal left.inode right.inode
  && String.equal left.content_digest right.content_digest
;;

let load_all_cache : load_all_cache_entry String_map.t Atomic.t =
  Atomic.make String_map.empty
;;

let invalidate_load_all_cache ~base_path =
  let rec loop () =
    let current = Atomic.get load_all_cache in
    let next = String_map.remove base_path current in
    if Atomic.compare_and_set load_all_cache current next then () else loop ()
  in
  loop ()
;;

let update_load_all_cache ~base_path stamp result =
  let entry = { stamp; result } in
  let rec loop () =
    let current = Atomic.get load_all_cache in
    let next =
      bounded_add base_path entry current ~max_entries:max_load_all_cache_entries
    in
    if Atomic.compare_and_set load_all_cache current next then ()
    else loop ()
  in
  loop ()
;;

(** [load_all_cached_attempt ~base_path] returns the parsed mapping list, using
    a per-[base_path] stamp-keyed cache. The file is read once; it is parsed;
    then the file is read a second time to confirm the stamp has not changed
    before the result is cached or returned. This closes the TOCTOU window
    where a concurrent edit would serve stale repository-scope data. *)
let rec load_all_cached_attempt ~remaining_attempts ~base_path
  : (keeper_repo_mapping list, string) result
  =
  match read_mapping_file ~base_path with
  | Error msg -> Error msg
  | Ok None ->
      invalidate_load_all_cache ~base_path;
      Ok []
  | Ok Some snapshot -> (
      match String_map.find_opt base_path (Atomic.get load_all_cache) with
      | Some { stamp = Some cached_stamp; result }
        when stamp_equal cached_stamp snapshot.stamp ->
          result
      | _ ->
          let result = parse_mapping_content snapshot.content in
          (* Only cache the result if the on-disk version is still the one we
             parsed. A mismatch means the file changed mid-read; we return the
             result but leave the cache empty so the next call reads fresh. *)
          (match read_mapping_file ~base_path with
           | Error msg -> Error msg
           | Ok (Some post) when stamp_equal post.stamp snapshot.stamp ->
               update_load_all_cache ~base_path (Some snapshot.stamp) result;
               result
           | Ok _ ->
               invalidate_load_all_cache ~base_path;
               if remaining_attempts > 0
               then
                 load_all_cached_attempt ~remaining_attempts:(remaining_attempts - 1)
                   ~base_path
               else Error "mapping file changed while loading"))
;;

let load_all_cache_changed_file_retries = 1

let load_all_cached ~base_path =
  load_all_cached_attempt
    ~remaining_attempts:load_all_cache_changed_file_retries ~base_path
;;

type mapping_lookup =
  | Mapping_found of keeper_repo_mapping
  | Mapping_missing of string
  | Mapping_load_error of string

let lookup_mapping ~base_path ~keeper_id =
  match load_all_cached ~base_path with
  | Error msg -> Mapping_load_error msg
  | Ok mappings -> (
      match
        List.find_opt
          (fun (m : keeper_repo_mapping) -> String.equal m.keeper_id keeper_id)
          mappings
      with
      | Some mapping -> Mapping_found mapping
      | None -> Mapping_missing keeper_id)

let find_mapping ~base_path ~keeper_id =
  match lookup_mapping ~base_path ~keeper_id with
  | Mapping_found mapping -> Ok mapping
  | Mapping_missing keeper_id ->
      Error (Printf.sprintf "No mapping found for keeper: %s" keeper_id)
  | Mapping_load_error msg -> Error msg

let allowed_repositories ~keeper_id ~base_path =
  match lookup_mapping ~base_path ~keeper_id with
  | Mapping_found mapping -> Ok mapping.repository_ids
  | Mapping_missing _ -> Ok ["*"]
  | Mapping_load_error _ -> Ok ["*"]

type repository_scope = Repo_manager_types.repository_scope =
  | All_repositories
  | Selected_repositories of repository_id list

let repository_scope_of_mapping (mapping : keeper_repo_mapping) =
  mapping.repository_scope

let mapping_allows_repository (mapping : keeper_repo_mapping) ~repository_id =
  match repository_scope_of_mapping mapping with
  | All_repositories -> true
  | Selected_repositories repository_ids ->
      List.exists (String.equal repository_id) repository_ids

(* Filter [repos] down to those whose id appears in the parsed mapping scope.
   Wildcard scope bypasses filtering, and selected scopes use an immutable set
   so display/policy paths do not allocate mutable membership tables. *)
let filter_repos_by_mapping (mapping : keeper_repo_mapping)
    (repos : repository list) : repository list =
  match repository_scope_of_mapping mapping with
  | All_repositories -> repos
  | Selected_repositories repository_ids ->
    let mapping_id_set =
      List.fold_left
        (fun set id -> String_set.add id set)
        String_set.empty repository_ids
    in
    List.filter
      (fun (r : repository) -> String_set.mem r.id mapping_id_set)
      repos

let repository_registered ~base_path ~repository_id : (bool, string) result =
  match Repo_store.load_all ~base_path with
  | Stdlib.Error msg ->
    Log.Misc.warn
      "[KeeperRepoMapping] repository_registered: repo store load failed for \
       repository %s — access denied fail-closed (error: %s)"
      repository_id msg;
    Stdlib.Error msg
  | Stdlib.Ok repos ->
    Stdlib.Ok
      (List.exists
         (fun (repo : repository) -> String.equal repo.id repository_id)
         repos)

let log_mapping_load_error_if_new ~keeper_id msg =
  let rec mark () =
    let current = Atomic.get logged_mapping_errors in
    if String_map.mem keeper_id current then ()
    else
      let next =
        bounded_add keeper_id () current ~max_entries:max_logged_mapping_error_entries
      in
      if Atomic.compare_and_set logged_mapping_errors current next then
        Log.Misc.warn
          "[KeeperRepoMapping] mapping load error for keeper %s \
           — advisory mapping ignored (error: %s)"
          keeper_id msg
      else mark ()
  in
  mark ()
;;

type access_denial =
  | Access_denied_unregistered_repository of repository_id
  | Access_denied_load_error of string
  | Access_denied_repository_store_error of
      { repository_id : repository_id
      ; detail : string
      }

type access_decision =
  | Access_allowed
  | Access_denied of access_denial

type policy_decision =
  | Policy_decision_default_scope_allowed
  | Policy_decision_unregistered_repository
  | Policy_decision_load_error
  | Policy_decision_repository_identity_mismatch
  | Policy_decision_repository_store_error

let record_policy_decision ~keeper_id ?repository_id decision =
  let metric, extra_labels =
    match decision with
    | Policy_decision_default_scope_allowed ->
      ( Keeper_metrics.KeeperRepoMappingDefaultScopeAllowed
      , match repository_id with
        | None -> []
        | Some r -> [("repository_id", r)] )
    | Policy_decision_unregistered_repository ->
      ( Keeper_metrics.KeeperRepoMappingDeniedUnregistered
      , match repository_id with
        | None -> []
        | Some r -> [("repository_id", r)] )
    | Policy_decision_load_error ->
      (Keeper_metrics.KeeperRepoMappingLoadError, [])
    | Policy_decision_repository_identity_mismatch ->
      ( Keeper_metrics.KeeperRepoMappingRepositoryIdentityMismatch
      , match repository_id with
        | None -> []
        | Some r -> [("repository_id", r)] )
    | Policy_decision_repository_store_error ->
      ( Keeper_metrics.KeeperRepoMappingRepositoryStoreError
      , match repository_id with
        | None -> []
        | Some r -> [("repository_id", r)] )
  in
  Otel_metric_store_core.inc_counter
    ~labels:(("keeper_id", keeper_id) :: extra_labels)
    Keeper_metrics.(to_string metric)
    ()
;;

let access_denial_to_string = function
  | Access_denied_unregistered_repository repository_id ->
    Printf.sprintf
      "Repository %s is not registered; access not allowed"
      repository_id
  | Access_denied_load_error detail -> detail
  | Access_denied_repository_store_error { repository_id; detail } ->
    Printf.sprintf
      "Repository store load failed while validating repository %s: %s"
      repository_id
      detail
;;

let access_decision ~keeper_id ~repository_id ~base_path =
  match repository_registered ~base_path ~repository_id with
  | Stdlib.Error detail ->
    record_policy_decision ~keeper_id ~repository_id
      Policy_decision_repository_store_error;
    Access_denied
      (Access_denied_repository_store_error { repository_id; detail })
  | Stdlib.Ok false ->
    record_policy_decision ~keeper_id ~repository_id
      Policy_decision_unregistered_repository;
    Access_denied (Access_denied_unregistered_repository repository_id)
  | Stdlib.Ok true -> (
    match lookup_mapping ~base_path ~keeper_id with
    | Mapping_missing _ ->
      record_policy_decision ~keeper_id ~repository_id
        Policy_decision_default_scope_allowed;
      Access_allowed
    | Mapping_load_error msg ->
      log_mapping_load_error_if_new ~keeper_id msg;
      record_policy_decision ~keeper_id Policy_decision_load_error;
      Access_allowed
    | Mapping_found _mapping ->
      Access_allowed)
;;

let is_allowed ~keeper_id ~repository_id ~base_path =
  match access_decision ~keeper_id ~repository_id ~base_path with
  | Access_allowed -> true
  | Access_denied _ -> false

let validate_access ~keeper_id ~repository_id ~base_path =
  match access_decision ~keeper_id ~repository_id ~base_path with
  | Access_allowed -> Ok ()
  | Access_denied denial -> Error (access_denial_to_string denial)

let save_all ~base_path mappings =
  let path = mappings_toml_path base_path in
  let table =
    List.map
      (fun m -> (m.keeper_id, toml_of_mapping m))
      mappings
  in
  let toml = Otoml.TomlTable [("mapping", Otoml.TomlTable table)] in
  let dir = Filename.dirname path in
  Fs_compat.mkdir_p dir;
  let content = Otoml.Printer.to_string toml in
  match Fs_compat.save_file_atomic path content with
  | Ok () ->
      invalidate_load_all_cache ~base_path;
      Ok ()
  | Error msg -> Error msg

let save_mapping ~base_path mapping =
  let mapping =
    make_keeper_repo_mapping ~keeper_id:mapping.keeper_id
      ~repository_ids:mapping.repository_ids
  in
  let path = mappings_toml_path base_path in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    File_lock_eio.with_lock path (fun () ->
      let* mappings = load_all ~base_path in
      let filtered =
        List.filter
          (fun (m : keeper_repo_mapping) ->
            not (String.equal m.keeper_id mapping.keeper_id))
          mappings
      in
      save_all ~base_path (mapping :: filtered))
  with
  | File_lock_eio.Flock_timeout { path; attempts; _ } ->
      Error
        (Printf.sprintf
           "timed out acquiring keeper repo mapping lock %s after %d attempts"
           path attempts)
  | Sys_error msg -> Error msg

let apply_mapping ~keeper_id ~base_path ~repositories =
  match lookup_mapping ~base_path ~keeper_id with
  | Mapping_missing _ -> repositories
  | Mapping_load_error msg ->
      log_mapping_load_error_if_new ~keeper_id msg;
      record_policy_decision ~keeper_id Policy_decision_load_error;
      repositories
  | Mapping_found mapping ->
      filter_repos_by_mapping mapping repositories

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
  | Playground_repo of { segment : string; repo_root : string }

let playground_path_of_path ~base_path ~path =
  let playground_root =
    Filename.concat (Config_dir_resolver.masc_root ~base_path) "playground"
  in
  match relative_under ~root:playground_root path with
  | None -> None
  | Some rel -> (
      match path_segments rel with
      | "docker" :: keeper :: "repos" :: repo_id :: _ ->
          let repo_root =
            Filename.concat playground_root
              (Filename.concat "docker"
                 (Filename.concat keeper (Filename.concat "repos" repo_id)))
          in
          Some (Playground_repo { segment = repo_id; repo_root })
      | keeper :: "repos" :: repo_id :: _ ->
          let repo_root =
            Filename.concat playground_root
              (Filename.concat keeper (Filename.concat "repos" repo_id))
          in
          Some (Playground_repo { segment = repo_id; repo_root })
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

let repository_identity_tokens (repo : repository) =
  repo.id :: repo.name :: repo.aliases
  |> List.map String.trim
  |> List.filter (fun token -> not (String.equal token ""))

(** [token_matches_url_basename ~basename token] is a case-insensitive
    comparison between a repository identity token and the basename extracted
    from a URL. Identity drift in the wild (e.g. [masc] vs [Masc]) should not
    cause a fail-closed rejection. *)
let token_matches_url_basename ~basename token =
  String.equal (String.lowercase_ascii basename) (String.lowercase_ascii token)

(** [repository_url_basename_matches_identity repo] returns [true] when the
    repository's URL basename can be matched against one of the repository's
    declared identity tokens. An empty basename (missing/empty URL or
    unparseable URL) is treated as [false]: fail-closed, not "matches by
    default". *)
let repository_url_basename_matches_identity repo =
  let basename = repository_url_basename repo.url in
  (not (String.equal basename ""))
  && List.exists (token_matches_url_basename ~basename) (repository_identity_tokens repo)

type repository_identity_mismatch = {
  repository_id : string;
  repository_name : string;
  repository_url : string;
  url_basename : string;
  segment : string;
  repo_root : string option;
}

let repository_identity_mismatch ?repo_root ~segment repo =
  let url_basename = repository_url_basename repo.url in
  if String.equal url_basename "" then
    (* Empty URL basename means a missing or unparseable repository URL. Treat
       it as an identity mismatch so the fail-closed path denies access rather
       than silently authorizing an unvalidated repository. *)
    Some
      {
        repository_id = repo.id;
        repository_name = repo.name;
        repository_url = repo.url;
        url_basename;
        segment;
        repo_root;
      }
  else if
    List.exists (token_matches_url_basename ~basename:url_basename) (repository_identity_tokens repo)
  then None
  else
    Some
      {
        repository_id = repo.id;
        repository_name = repo.name;
        repository_url = repo.url;
        url_basename;
        segment;
        repo_root;
      }

let repository_identity_mismatch_message
    { repository_id; repository_name; repository_url; url_basename; segment; repo_root } =
  let repo_root =
    match repo_root with
    | Some repo_root -> repo_root
    | None -> "unknown"
  in
  Printf.sprintf
    "Repository identity mismatch for repos/%s: repository id=%S name=%S \
     url_basename=%S url=%S repo_root=%S. Add the URL basename as an explicit \
     alias, or fix repositories.toml before keeper repository access."
    segment repository_id repository_name url_basename repository_url repo_root

let repository_matches_token ~base_path token (repo : repository) =
  String.equal repo.id token
  || String.equal repo.name token
  || List.exists (String.equal token) repo.aliases
  || (repository_url_basename_matches_identity repo
      && token_matches_url_basename ~basename:(repository_url_basename repo.url) token)
  || String.equal
       (basename_of_path (Repo_store.local_path ~base_path repo))
       token

type repository_resolution =
  | No_repository
  | Repository of repository_match
  | Repository_identity_mismatch of repository_identity_mismatch
  | Repository_store_error of string

and repository_match =
  { repository_id : repository_id
  ; repo_root : string option
  }

let repository_match ?repo_root repository_id = { repository_id; repo_root }

let repository_resolution_of_repo ?repo_root ~segment repo =
  match repository_identity_mismatch ?repo_root ~segment repo with
  | Some mismatch -> Repository_identity_mismatch mismatch
  | None -> Repository (repository_match ?repo_root repo.id)

let repository_identity_mismatch_for_url_basename_token ?repo_root ~segment
    token repos =
  if String.equal token "" then None
  else
    List.find_map
      (fun repo ->
        let url_basename = repository_url_basename repo.url in
        if
          String.equal url_basename ""
          || not (token_matches_url_basename ~basename:url_basename token)
        then None
        else repository_identity_mismatch ?repo_root ~segment repo)
      repos

let unresolved_repository_segment_resolution ?repo_root ~segment repos =
  match
    repository_identity_mismatch_for_url_basename_token ?repo_root ~segment
      segment repos
  with
  | Some mismatch -> Repository_identity_mismatch mismatch
  | None -> No_repository

let resolve_repository_id_segment_from_catalog ~base_path ?repo_root segment repos =
  match List.find_opt (repository_matches_token ~base_path segment) repos with
  | Some repo -> repository_resolution_of_repo ?repo_root ~segment repo
  | None -> unresolved_repository_segment_resolution ?repo_root ~segment repos
;;

let resolve_repository_id_segment ~base_path ?repo_root segment =
  match Repo_store.load_all ~base_path with
  | Error msg ->
    Log.Misc.warn
      "[KeeperRepoMapping] resolve_repository_id_segment: repo store load \
       failed for segment %s — access denied fail-closed (error: %s)"
      segment msg;
    Repository_store_error msg
  | Ok repos ->
    resolve_repository_id_segment_from_catalog ~base_path ?repo_root segment repos

(** [path_under_repo ~base_path repo path] returns [true] when [path]
    is equal to or strictly under [repo]'s resolved local_path. *)
let path_under_repo ~base_path repo path =
  let repo_path = Repo_store.local_path ~base_path repo in
  let repo_norm = normalize_path_for_prefix_check repo_path in
  let path_norm = normalize_path_for_prefix_check path in
  String.equal path_norm repo_norm
  || String.starts_with ~prefix:(repo_norm ^ "/") path_norm

(** [repository_resolution_of_path ~base_path ~path] returns the registered
    repository for [path], or an identity mismatch when the path points at a
    declared repository whose URL basename contradicts its declared identity.
    Playground clone paths that do not resolve to a registered repository are
    treated like other sandbox-local paths after the identity-mismatch check;
    the repository catalog is not an authorization cap for a keeper's own
    playground. Repository store load failures remain explicit so access
    callers can deny instead of treating an unknown repository catalog as "not
    a repository". *)
let repository_resolution_of_path_from_catalog ~base_path ~path repos =
  match playground_path_of_path ~base_path ~path with
  | Some Playground_internal | Some Playground_repos_root -> No_repository
  | Some (Playground_repo { segment; repo_root }) ->
    resolve_repository_id_segment_from_catalog ~base_path ~repo_root segment repos
  | None -> (
    match List.find_opt (fun repo -> path_under_repo ~base_path repo path) repos with
    | Some repo -> repository_resolution_of_repo ~segment:repo.id repo
    | None -> No_repository)
;;

let repository_resolution_of_path ~base_path ~path =
  match playground_path_of_path ~base_path ~path with
  | Some Playground_internal | Some Playground_repos_root -> No_repository
  | Some (Playground_repo { segment; repo_root }) ->
    resolve_repository_id_segment ~base_path ~repo_root segment
  | None -> (
    match Repo_store.load_all ~base_path with
    | Error msg ->
      Log.Misc.warn
        "[KeeperRepoMapping] repository_resolution_of_path: repo store load \
         failed for path %s — access denied fail-closed (error: %s)"
        path msg;
      Repository_store_error msg
    | Ok repos -> repository_resolution_of_path_from_catalog ~base_path ~path repos)

(** [repository_id_of_path ~base_path ~path] returns the ID of the
    registered repository whose [local_path] contains [path], or [None]
    if the path is not under any registered repository. *)
let repository_id_of_path ~base_path ~path =
  match repository_resolution_of_path ~base_path ~path with
  | Repository { repository_id; _ } -> Some repository_id
  | No_repository | Repository_identity_mismatch _ | Repository_store_error _ -> None

(** [validate_path_access ~keeper_id ~base_path ~path] checks that [path]
    either is outside registered repositories or resolves to a valid
    registered repository. A sandbox-local playground clone that is absent from
    the repository catalog is outside registered repositories, not a policy
    denial. Per-keeper mappings are advisory/default-scope metadata and do not
    cap access. This is the integration point for keeper execution paths that
    operate on filesystem paths rather than explicit repository IDs. *)
let validate_path_access ~keeper_id ~base_path ~path =
  match repository_resolution_of_path ~base_path ~path with
  | No_repository -> Ok ()
  | Repository { repository_id; _ } ->
      validate_access ~keeper_id ~repository_id ~base_path
  | Repository_identity_mismatch mismatch ->
      Error (repository_identity_mismatch_message mismatch)
  | Repository_store_error msg ->
      Error
        (Printf.sprintf
           "Repository store load failed while validating keeper %s path %s: %s"
           keeper_id path msg)
