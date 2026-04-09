(** Room Utilities - Shared helpers for Room module *)

(** Storage backend type - unified interface (Backend only) *)
type storage_backend =
  | Memory of Backend.Memory.t
  | FileSystem of Backend.FileSystem.t
  | PostgresNative of Backend.Postgres.t

(** Room configuration *)
type config = {
  base_path: string;
  workspace_path: string;
  lock_expiry_minutes: int;
  backend_config: Backend_types.config;
  backend: storage_backend;
}

let _domain_local_pg_backend_created = Atomic.make 0
let _domain_local_pg_backend_failed = Atomic.make 0
let _domain_local_pg_backend_last_error = Atomic.make ""

let domain_local_pg_backend_diagnostics_json () =
  `Assoc
    [
      ("creations", `Int (Atomic.get _domain_local_pg_backend_created));
      ("failures", `Int (Atomic.get _domain_local_pg_backend_failed));
      ( "last_error",
        match String.trim (Atomic.get _domain_local_pg_backend_last_error) with
        | "" -> `Null
        | value -> `String value );
    ]

(** Create a config with a domain-local PostgresNative backend.
    Use when running in a different Eio domain (e.g., Executor_pool)
    where the main domain's Caqti pool would crash due to Switch
    being domain-bound.  Skips schema init (already done by main pool).
    Constructs [Caqti_eio.stdenv] from [Eio_context] globals (net/clock
    are cross-domain safe, only Switch is domain-bound).
    Returns [None] on failure. *)
let with_domain_local_pg_backend ~sw ~net ~clock ~mono_clock config =
  match config.backend with
  | PostgresNative _ ->
    let env : Caqti_eio.stdenv =
      object
        method net = (net :> [`Generic] Eio.Net.ty Eio.Resource.t)
        method clock = clock
        method mono_clock = mono_clock
      end
    in
    let url = match config.backend_config.Backend_types.postgres_url with
      | Some u -> u
      | None -> ""
    in
    (match Backend.Postgres.create_readonly ~sw ~env ~url config.backend_config with
    | Ok t ->
      Atomic.fetch_and_add _domain_local_pg_backend_created 1 |> ignore;
      Some { config with backend = PostgresNative t }
    | Error err ->
      Atomic.fetch_and_add _domain_local_pg_backend_failed 1 |> ignore;
      Atomic.set _domain_local_pg_backend_last_error (Backend_types.show_error err);
      Log.Room.warn "Domain-local PG backend failed: %s"
        (Backend_types.show_error err);
      None)
  | Memory _ | FileSystem _ ->
    Some config

(* ============================================ *)
(* Git Root Detection (Worktree Support)        *)
(* ============================================ *)

(** Read .git file content (for worktrees) *)
let read_git_file path =
  match Safe_ops.read_file_safe path with
  | Ok content ->
    (match String.split_on_char '\n' content with
     | line :: _ -> Some (String.trim line)
     | [] -> None)
  | Error _ -> None

(** Parse gitdir from .git file
    Format: "gitdir: /path/to/main/.git/worktrees/branch-name"
    Returns: /path/to/main (the main repository root) *)
let parse_gitdir_to_main_root gitdir_line =
  match String.split_on_char ':' gitdir_line with
  | [prefix; path] when String.trim prefix = "gitdir" ->
      let gitdir = String.trim path in
      (* gitdir: /main/.git/worktrees/branch → /main *)
      if String.length gitdir > 0 then begin
        (* Check if it's a worktree path: .git/worktrees/xxx *)
        let parts = String.split_on_char '/' gitdir in
        let rec find_git_parent = function
          | [] -> None
          | ".git" :: "worktrees" :: _ :: _ ->
              (* Found worktree pattern, reconstruct main repo path *)
              let rec take_until_git acc = function
                | [] -> None
                | ".git" :: _ -> Some (String.concat "/" (List.rev acc))
                | h :: t -> take_until_git (h :: acc) t
              in
              take_until_git [] parts
          | _ :: t -> find_git_parent t
        in
        find_git_parent parts
      end else None
  | _ -> None

(** Find git root from a path, handling worktrees
    - If .git is a directory → this is the main repo
    - If .git is a file → this is a worktree, find main repo
    - If no .git found → search parent directories *)
let rec find_git_root path =
  let git_path = Filename.concat path ".git" in
  if Sys.file_exists git_path then begin
    if Sys.is_directory git_path then
      Some path  (* Main repository *)
    else begin
      (* Worktree: .git is a file pointing to main repo *)
      match read_git_file git_path with
      | Some content ->
          (match parse_gitdir_to_main_root content with
           | Some main_root -> Some main_root
           | None -> Some path)  (* Fallback to current if parse fails *)
      | None -> Some path
    end
  end else begin
    let parent = Filename.dirname path in
    if parent = path then None  (* Reached filesystem root *)
    else find_git_root parent
  end

let bool_env name = Env_config_core.get_bool ~default:false name

let normalize_base_path path =
  let trimmed = String.trim path in
  if trimmed = "" then ""
  else if Filename.is_relative trimmed then Filename.concat (Sys.getcwd ()) trimmed
  else trimmed

let canonical_base_path path =
  let normalized = normalize_base_path path in
  match find_git_root normalized with
  | Some git_root -> git_root
  | None -> normalized
  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
  | exception _ -> normalized

let path_has_masc_dir path =
  let masc_dir = Filename.concat path ".masc" in
  Sys.file_exists masc_dir && Sys.is_directory masc_dir

let running_under_test_executable () =
  let executable =
    Sys.executable_name |> Filename.basename |> String.lowercase_ascii
  in
  String.starts_with ~prefix:"test_" executable

let realpath p =
  try Unix.realpath p with Unix.Unix_error _ -> p

let is_ancestor_path ~ancestor ~descendant =
  let a = realpath ancestor in
  let d = realpath descendant in
  let a = if String.ends_with ~suffix:"/" a then a else a ^ "/" in
  String.starts_with ~prefix:a d

let should_ignore_inherited_base_path ~requested_path ~explicit_path =
  not (bool_env "MASC_ALLOW_INHERITED_BASE_PATH")
  && String.trim requested_path <> ""
  && not (String.equal requested_path ".")
  &&
  let requested = canonical_base_path requested_path in
  let explicit = canonical_base_path explicit_path in
  requested <> ""
  && explicit <> ""
  && not (String.equal requested explicit)
  && not (is_ancestor_path ~ancestor:explicit ~descendant:requested)
  && path_has_masc_dir requested
  && path_has_masc_dir explicit

let should_ignore_inherited_test_base_path ~requested_path ~explicit_path =
  running_under_test_executable ()
  && not (bool_env "MASC_ALLOW_INHERITED_BASE_PATH")
  && not (bool_env "MASC_TEST_ALLOW_INHERITED_BASE_PATH")
  && String.trim requested_path <> ""
  && not (String.equal requested_path ".")
  && not (String.equal explicit_path requested_path)
  && not (is_ancestor_path ~ancestor:(canonical_base_path explicit_path)
            ~descendant:(canonical_base_path requested_path))

let sync_test_base_path_env resolved_path =
  if running_under_test_executable ()
     && not (bool_env "MASC_TEST_ALLOW_INHERITED_BASE_PATH")
  then
    match Env_config_core.base_path_opt () with
    | Some current when String.equal current resolved_path -> ()
    | _ ->
        Unix.putenv "MASC_BASE_PATH" resolved_path;
        Log.Room.info "Synchronized MASC_BASE_PATH=%s for test executable %s"
          resolved_path (Filename.basename Sys.executable_name)

let resolve_requested_base_path path =
  match find_git_root path with
  | Some git_root ->
      Log.Room.info "MASC base resolved: %s → %s (git root)" path git_root;
      git_root
  | None ->
      Log.Room.info "MASC base: %s (no git root found)" path;
      path

(** Resolve base_path: when MASC_BASE_PATH is explicitly set, use it
    directly unless a test executable intentionally ignores an inherited
    override. Git root detection applies for worktree auto-resolution when
    no explicit path is configured, or when that inherited test override is
    ignored. When the explicit path is an ancestor of the requested path
    (e.g. ~/me contains ~/me/workspace/.../masc-mcp), the ancestor wins
    because the sub-repo is part of the parent project. Only unrelated
    sibling paths with dual .masc/ dirs trigger the ignore guard. *)
let resolve_masc_base_path path =
  match Env_config_core.base_path_opt () with
  | Some explicit
    when should_ignore_inherited_base_path ~requested_path:path
           ~explicit_path:explicit ->
      let resolved = resolve_requested_base_path path in
      Log.Room.info
        "Ignoring inherited MASC_BASE_PATH=%s because both %s and %s have .masc; using requested base path %s. Set MASC_ALLOW_INHERITED_BASE_PATH=1 to preserve the inherited root."
        explicit (canonical_base_path path) (canonical_base_path explicit) resolved;
      resolved
  | Some explicit
    when should_ignore_inherited_test_base_path ~requested_path:path
           ~explicit_path:explicit ->
      Log.Room.warn
        "Ignoring inherited MASC_BASE_PATH=%s for test executable %s; using requested base path %s"
        explicit (Filename.basename Sys.executable_name) path;
      resolve_requested_base_path path
  | Some explicit ->
      Log.Room.info "MASC base: %s (explicit MASC_BASE_PATH)" explicit;
      explicit
  | None -> resolve_requested_base_path path

(* ============================================ *)
(* Environment helpers                          *)
(* ============================================ *)

let is_unresolved_template value =
  let v = String.trim value in
  (String.length v >= 2 && v.[0] = '{' && v.[1] = '{')
  || (String.length v >= 5 && String.sub v 0 5 = "op://")

let env_opt name =
  match Sys.getenv_opt name with
  | Some value when String.trim value <> "" ->
      if Backend_pg_url.is_unresolved_template value then begin
        Log.Backend.warn
          "%s contains unresolved 1Password template; skipping" name;
        None
      end else
        Some value
  | _ -> None

let legacy_pg_env_var_names =
  [| "DATABASE_URL"; "SUPABASE_DB_URL"; "SB_PG_URL" |]

let configured_legacy_pg_envs () =
  legacy_pg_env_var_names
  |> Array.to_list
  |> List.filter (fun name -> env_opt name <> None)

let legacy_pg_warning_signature : string option ref = ref None

let warn_ignored_legacy_pg_envs storage_type =
  if storage_type <> "postgres" then
    let configured = configured_legacy_pg_envs () in
    if configured <> [] then begin
      let signature = String.concat "," configured in
      if !legacy_pg_warning_signature <> Some signature then begin
        legacy_pg_warning_signature := Some signature;
        Log.Backend.warn
          "Ignoring legacy PG envs for MASC backend selection: %s. \
           Use MASC_STORAGE_TYPE=postgres with MASC_POSTGRES_URL for explicit PG mode."
          (String.concat ", " configured)
      end
    end

let postgres_url_from_env () =
  match env_opt "MASC_POSTGRES_URL" with
  | None -> None
  | Some _ ->
      let candidates : string option list =
        [
          env_opt "MASC_POSTGRES_URL";
          env_opt "DATABASE_URL";
          env_opt "SUPABASE_DB_URL";
          env_opt "SB_PG_URL";
        ]
      in
      (match Backend_pg_url.choose_preferred_url candidates with
       | Some
           {
             url;
             preferred_supabase_transaction_companion = true;
             preferred_host = Some host;
           } ->
           Log.Backend.info "Supabase Session Pooler configured on %s:5432; preferring available Transaction Pooler companion on %s:6543" host host;
           Some url
       | Some { url; _ } -> Some url
       | None -> None)

(** Auto-detect best backend based on environment variables.
    Stage-1 SSOT policy: no implicit PG auto-detect.
    MASC defaults to the local filesystem unless the caller explicitly
    selects another backend via MASC_STORAGE_TYPE. *)
let auto_detect_backend () =
  Log.Backend.info
    "Auto-detect disabled: defaulting to FileSystem backend \
     unless MASC_STORAGE_TYPE is set";
  "filesystem"

(** Storage type from environment variable.
    Defaults to filesystem when MASC_STORAGE_TYPE is not set.
    Requires explicit MASC_STORAGE_TYPE=postgres for PG mode. *)
let storage_type_from_env () =
  let storage_type =
    match env_opt "MASC_STORAGE_TYPE" with
    | Some raw ->
        let value = String.lowercase_ascii (String.trim raw) in
        (match value with
         | "postgres" | "postgresql" | "postgres-native" -> "postgres"
         | "filesystem" | "file" | "jsonl" | "auto" -> "filesystem"
         | "memory" -> "memory"
         | other -> other)
    | None -> auto_detect_backend ()
  in
  warn_ignored_legacy_pg_envs storage_type;
  storage_type

(* ============================================ *)
(* Backend creation                             *)
(* ============================================ *)

(* Sanitize namespace/cluster name for filesystem path segments.
   Keep alnum, '-', '_' and replace others with '-'. *)
let sanitize_namespace_segment name =
  let buf = Buffer.create (String.length name) in
  String.iter (fun c ->
    let is_safe =
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c = '-' || c = '_'
    in
    Buffer.add_char buf (if is_safe then c else '-')
  ) name;
  let sanitized = String.trim (Buffer.contents buf) in
  if sanitized = "" then "default" else sanitized

let backend_config_for base_path =
  let storage_type = storage_type_from_env () in
  let postgres_url = postgres_url_from_env () in
  if storage_type = "postgres" && postgres_url = None then
    invalid_arg
      (match configured_legacy_pg_envs () with
       | [] -> "MASC_STORAGE_TYPE=postgres requires MASC_POSTGRES_URL"
       | configured ->
           Printf.sprintf
             "MASC_STORAGE_TYPE=postgres requires MASC_POSTGRES_URL; \
              ignored legacy envs: %s"
             (String.concat ", " configured));
  let cluster_name =
    match env_opt "MASC_CLUSTER_NAME" with
    | Some name -> name
    | None -> "default"
  in
  let backend_type =
    match storage_type with
    | "postgres" | "postgresql" -> Backend_types.PostgresNative
    | "memory" -> Backend_types.Memory
    | _ -> Backend_types.FileSystem
  in
  let masc_root = Filename.concat base_path ".masc" in
  let cluster_segment =
    match cluster_name with
    | "" | "default" -> None
    | other -> Some (sanitize_namespace_segment other)
  in
  let backend_base_path =
    match cluster_segment with
    | None -> masc_root
    | Some seg -> Filename.concat (Filename.concat masc_root "clusters") seg
  in
  {
    Backend_types.backend_type;
    Backend_types.postgres_url;
    Backend_types.base_path = backend_base_path;
    Backend_types.cluster_name;
    Backend_types.node_id = Backend_types.generate_node_id ();
    Backend_types.pubsub_max_messages = Backend_types.pubsub_max_messages_from_env ();
  }

let create_backend cfg =
  let filesystem_fallback reason =
    Log.Backend.warn "%s Falling back to Memory backend." reason;
    Ok (Memory (Backend.Memory.get_or_create ~base_path:cfg.Backend_types.cluster_name))
  in
  let fs_usable fs =
    try
      ignore (Eio.Path.kind ~follow:true fs);
      true
    with
    | Stdlib.Effect.Unhandled _ -> false
  in
  match cfg.Backend_types.backend_type with
  | Backend_types.Memory ->
      (* Backend.Memory now has Effect.Unhandled/Poisoned fallback
         built in, so it works in both Eio and non-Eio contexts.
         get_or_create shares state across configs for the same path. *)
      Ok (Memory (Backend.Memory.get_or_create ~base_path:cfg.cluster_name))
  | Backend_types.FileSystem ->
      (match Fs_compat.get_fs_opt () with
       | Some fs when fs_usable fs ->
           Ok (FileSystem (Backend.FileSystem.create ~fs cfg))
       | Some _fs ->
           (* Tests sometimes inherit a stale Fs_compat handle from a previous
              Eio_main.run. Using it outside an active Eio scheduler explodes
              with Effect.Unhandled, so prefer the shared Memory fallback. *)
           filesystem_fallback
             "Stale Eio fs context for FileSystem backend;"
       | None ->
           (* No Eio fs context available (e.g., test without Fs_compat.set_fs).
              Fall back to shared Memory backend for the same base path. *)
           filesystem_fallback
             "No Eio fs context for FileSystem backend;")
  | Backend_types.PostgresNative ->
      (* PostgresNative requires Eio context - use create_backend_eio instead *)
      Error (Backend_types.BackendNotSupported "PostgresNative requires Eio context (use create_backend_eio)")

(** Create backend with Eio context - required for PostgresNative *)
let create_backend_eio ~sw ~env cfg =
  match cfg.Backend_types.backend_type with
  | Backend_types.PostgresNative ->
      let url = match cfg.Backend_types.postgres_url with
        | Some u -> u
        | None -> ""
      in
      (match Backend.Postgres.create ~sw ~env ~url cfg with
       | Ok backend -> Ok (PostgresNative backend)
       | Error e -> Error e)
  | _ ->
      (* Non-Eio backends can use the regular create_backend *)
      create_backend cfg

let default_config base_path =
  (* Resolve to git root for worktree support - all worktrees share same .masc/ *)
  let resolved_path = resolve_masc_base_path base_path in
  sync_test_base_path_env resolved_path;
  let backend_config = backend_config_for resolved_path in
  Log.Backend.info "MASC Backend: type=%s, postgres_url=%s"
    (Backend_types.show_backend_type backend_config.backend_type)
    (match backend_config.postgres_url with Some _ -> "<configured>" | None -> "none");
  let backend =
    match create_backend backend_config with
    | Ok backend ->
        Log.Backend.info "Backend initialized: %s"
          (match backend with
           | Memory _ -> "Memory"
           | FileSystem _ -> "FileSystem"
           | PostgresNative _ -> "PostgresNative");
        backend
    | Error e ->
        (match backend_config.Backend_types.backend_type with
         | Backend_types.PostgresNative ->
             invalid_arg
               (Printf.sprintf
                  "MASC_STORAGE_TYPE=postgres failed to initialize backend: %s"
                  (Backend_types.show_error e))
         | Backend_types.Memory | Backend_types.FileSystem ->
             Log.Backend.warn "Backend init failed (%s). Falling back to filesystem."
               (Backend_types.show_error e);
             let fallback_cfg =
               { backend_config with Backend_types.backend_type = Backend_types.FileSystem }
             in
             (match create_backend fallback_cfg with
              | Ok fb -> fb
              | Error _ ->
                  (* Final fallback: shared in-memory to keep server alive *)
                  Memory (Backend.Memory.get_or_create ~base_path:backend_config.cluster_name)))
  in
  {
    base_path = resolved_path;  (* Use resolved path (git root for worktrees) *)
    workspace_path = base_path;
    lock_expiry_minutes = 2;
    backend_config;
    backend;
  }

(** Create config with Eio context - required for PostgresNative backend.
    [on_backend_ready] is called after backend creation, allowing callers
    to initialize dependent systems (e.g., Board) without Room depending on them. *)
let default_config_eio ~sw ~env ?(on_backend_ready = fun _backend -> ()) base_path =
  let resolved_path = resolve_masc_base_path base_path in
  sync_test_base_path_env resolved_path;
  let backend_config = backend_config_for resolved_path in
  Log.Backend.info "MASC Backend: type=%s, postgres_url=%s"
    (Backend_types.show_backend_type backend_config.backend_type)
    (match backend_config.postgres_url with Some _ -> "<configured>" | None -> "none");
  let backend =
    match create_backend_eio ~sw ~env backend_config with
    | Ok backend ->
        Log.Backend.info "Backend initialized: %s"
          (match backend with
           | Memory _ -> "Memory"
           | FileSystem _ -> "FileSystem"
           | PostgresNative _ -> "PostgresNative");
        on_backend_ready backend;
        backend
    | Error e ->
        (match backend_config.Backend_types.backend_type with
         | Backend_types.PostgresNative ->
             invalid_arg
               (Printf.sprintf
                  "MASC_STORAGE_TYPE=postgres failed to initialize backend: %s"
                  (Backend_types.show_error e))
         | Backend_types.Memory | Backend_types.FileSystem ->
             Log.Backend.warn "Backend init failed (%s). Falling back to filesystem."
               (Backend_types.show_error e);
             let fallback_cfg =
               { backend_config with Backend_types.backend_type = Backend_types.FileSystem }
             in
             (match create_backend fallback_cfg with
              | Ok fb -> fb
              | Error _ ->
                  (* Final fallback: shared in-memory to keep server alive *)
                  Memory (Backend.Memory.get_or_create ~base_path:backend_config.cluster_name)))
  in
  {
    base_path = resolved_path;
    workspace_path = base_path;
    lock_expiry_minutes = 2;
    backend_config;
    backend;
  }

(* ============================================ *)
(* Path utilities                               *)
