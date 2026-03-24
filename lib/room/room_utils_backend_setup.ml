(** Room Utilities - Shared helpers for Room module *)

(** Storage backend type - unified interface *)
type storage_backend =
  | Memory of Backend.MemoryBackend.t
  | FileSystem of Backend.FileSystemBackend.t
  | PostgresNative of Backend.PostgresNative.t

(** Room scope — determines which directory tree is active.
    Resolved once at config creation time, never re-read from filesystem. *)
type scope =
  | Default          (** Root .masc/ directory *)
  | Named of string  (** .masc/rooms/{id}/ directory *)

(** Room configuration *)
type config = {
  base_path: string;
  workspace_path: string;
  lock_expiry_minutes: int;
  backend_config: Backend.config;
  backend: storage_backend;
  scope: scope;
}

(** Create a config targeting a different scope. Cheap record copy. *)
let with_scope config scope = { config with scope }

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
    (match Backend.PostgresNative.create_eio_readonly ~sw ~env config.backend_config with
    | Ok t ->
      Atomic.fetch_and_add _domain_local_pg_backend_created 1 |> ignore;
      Some { config with backend = PostgresNative t }
    | Error err ->
      Atomic.fetch_and_add _domain_local_pg_backend_failed 1 |> ignore;
      Atomic.set _domain_local_pg_backend_last_error (Backend.show_error err);
      Log.Room.warn "Domain-local PG backend failed: %s"
        (Backend.show_error err);
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

(** Resolve base_path: if in worktree, use main repo's path for .masc/
    This ensures all worktrees share the same MASC coordination space *)
let resolve_masc_base_path path =
  match find_git_root path with
  | Some git_root ->
      Log.Room.info "MASC base resolved: %s → %s (git root)" path git_root;
      git_root
  | None ->
      Log.Room.info "MASC base: %s (no git root found)" path;
      path

(* ============================================ *)
(* Environment helpers                          *)
(* ============================================ *)

let env_opt name =
  match Sys.getenv_opt name with
  | Some value when String.trim value <> "" -> Some value
  | _ -> None

let normalize_postgres_url url =
  let uri = Uri.of_string url in
  match Uri.host uri, Uri.port uri with
  | Some host, Some 6543 when String.ends_with ~suffix:".pooler.supabase.com" host ->
      let normalized = Uri.to_string (Uri.with_port uri (Some 5432)) in
      Log.Backend.info
        "Supabase transaction pooler detected in PostgreSQL URL; using session pooler port 5432 for prepared-statement compatibility";
      normalized
  | _ -> url

let postgres_url_from_env () =
  let raw_url =
    match env_opt "MASC_POSTGRES_URL" with
  | Some _ as url -> url
  | None -> (
      match env_opt "DATABASE_URL" with
      | Some _ as url -> url
      | None -> (
          match env_opt "SUPABASE_DB_URL" with
          | Some _ as url -> url
          | None -> env_opt "SB_PG_URL"))
  in
  Option.map normalize_postgres_url raw_url

(** Auto-detect best backend based on environment variables
    Priority order:
    1. MASC_POSTGRES_URL / DATABASE_URL / SUPABASE_DB_URL / SB_PG_URL
       - if available, use PostgreSQL for distributed coordination
    2. FileSystem - zero-dependency default for personal/small use *)
let auto_detect_backend () =
  if postgres_url_from_env () <> None then begin
    Log.Backend.info "Auto-detect: PostgreSQL URL found → PostgresNative backend";
    "postgres"
  end else begin
    Log.Backend.info "Auto-detect: No distributed DB found → FileSystem backend (default)";
    "filesystem"
  end

(** Storage type from environment variable *)
let storage_type_from_env () =
  match env_opt "MASC_STORAGE_TYPE" with
  | Some value -> String.lowercase_ascii value
  | None -> auto_detect_backend ()  (* Smart default: PG if URL exists, else FileSystem *)

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
  let raw_storage_type = storage_type_from_env () in
  let storage_type =
    if raw_storage_type = "auto" then auto_detect_backend ()
    else raw_storage_type
  in
  let postgres_url = postgres_url_from_env () in
  let cluster_name =
    match env_opt "MASC_CLUSTER_NAME" with
    | Some name -> name
    | None -> "default"
  in
  let backend_type =
    match storage_type with
    | "postgres" | "postgresql" -> Backend.PostgresNative
    | "memory" -> Backend.Memory
    | _ -> Backend.FileSystem
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
    Backend.backend_type;
    Backend.postgres_url;
    Backend.base_path = backend_base_path;
    Backend.cluster_name;
    Backend.node_id = Backend.generate_node_id ();
    Backend.pubsub_max_messages = Backend.pubsub_max_messages_from_env ();
  }

let create_backend cfg =
  match cfg.Backend.backend_type with
  | Backend.Memory ->
      (match Backend.MemoryBackend.create cfg with
       | Ok backend -> Ok (Memory backend)
       | Error e -> Error e)
  | Backend.FileSystem ->
      (match Backend.FileSystemBackend.create cfg with
       | Ok backend -> Ok (FileSystem backend)
       | Error e -> Error e)
  | Backend.PostgresNative ->
      (* PostgresNative requires Eio context - use create_backend_eio instead *)
      (match Backend.PostgresNative.create cfg with
       | Ok backend -> Ok (PostgresNative backend)
       | Error e -> Error e)

(** Create backend with Eio context - required for PostgresNative *)
let create_backend_eio ~sw ~env cfg =
  match cfg.Backend.backend_type with
  | Backend.PostgresNative ->
      (match Backend.PostgresNative.create_eio ~sw ~env cfg with
       | Ok backend -> Ok (PostgresNative backend)
       | Error e -> Error e)
  | _ ->
      (* Non-Eio backends can use the regular create_backend *)
      create_backend cfg

let default_config base_path =
  (* Resolve to git root for worktree support - all worktrees share same .masc/ *)
  let resolved_path = resolve_masc_base_path base_path in
  let backend_config = backend_config_for resolved_path in
  Log.Backend.info "MASC Backend: type=%s, postgres_url=%s"
    (Backend.show_backend_type backend_config.backend_type)
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
        Log.Backend.warn "Backend init failed (%s). Falling back to filesystem."
          (Backend.show_error e);
        let fallback_cfg =
          { backend_config with Backend.backend_type = Backend.FileSystem }
        in
        (match Backend.FileSystemBackend.create fallback_cfg with
         | Ok fs -> FileSystem fs
         | Error _ ->
             (* Final fallback: in-memory to keep server alive *)
             (match Backend.MemoryBackend.create fallback_cfg with
              | Ok mem -> Memory mem
              | Error e -> invalid_arg (Printf.sprintf "Failed to initialize any MASC backend: %s" (Backend.show_error e))))
  in
  {
    base_path = resolved_path;  (* Use resolved path (git root for worktrees) *)
    workspace_path = base_path;
    lock_expiry_minutes = 2;
    backend_config;
    backend;
    scope = Default;
  }

(** Create config with Eio context - required for PostgresNative backend.
    [on_backend_ready] is called after backend creation, allowing callers
    to initialize dependent systems (e.g., Board) without Room depending on them. *)
let default_config_eio ~sw ~env ?(on_backend_ready = fun _backend -> ()) base_path =
  let resolved_path = resolve_masc_base_path base_path in
  let backend_config = backend_config_for resolved_path in
  Log.Backend.info "MASC Backend: type=%s, postgres_url=%s"
    (Backend.show_backend_type backend_config.backend_type)
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
        Log.Backend.warn "Backend init failed (%s). Falling back to filesystem."
          (Backend.show_error e);
        let fallback_cfg =
          { backend_config with Backend.backend_type = Backend.FileSystem }
        in
        (match Backend.FileSystemBackend.create fallback_cfg with
         | Ok fs -> FileSystem fs
         | Error _ ->
             (match Backend.MemoryBackend.create fallback_cfg with
              | Ok mem -> Memory mem
              | Error e -> invalid_arg (Printf.sprintf "Failed to initialize any MASC backend: %s" (Backend.show_error e))))
  in
  {
    base_path = resolved_path;
    workspace_path = base_path;
    lock_expiry_minutes = 2;
    backend_config;
    backend;
    scope = Default;
  }

(* ============================================ *)
(* Path utilities                               *)
