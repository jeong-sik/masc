(** Room Utilities - Shared helpers for Room module *)

(** Storage backend type - unified interface (Backend only) *)
type storage_backend =
  | Memory of Backend.Memory.t
  | FileSystem of Backend.FileSystem.t
  | PostgresNative of Backend.Postgres.t

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
  backend_config: Backend_types.config;
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

let is_unresolved_template value =
  let v = String.trim value in
  (String.length v >= 2 && v.[0] = '{' && v.[1] = '{')
  || (String.length v >= 5 && String.sub v 0 5 = "op://")

let env_opt name =
  match Sys.getenv_opt name with
  | Some value when String.trim value <> "" ->
      if is_unresolved_template value then begin
        Log.Backend.warn
          "%s contains unresolved 1Password template; skipping" name;
        None
      end else
        Some value
  | _ -> None

let normalize_postgres_url url =
  let uri = Uri.of_string url in
  match Uri.host uri, Uri.port uri with
  | Some host, Some 6543 when String.ends_with ~suffix:".pooler.supabase.com" host ->
      Log.Backend.info
        "Supabase Transaction Pooler detected (port 6543 on %s); rewriting to Session Pooler port 5432"
        host;
      Uri.with_port uri (Some 5432) |> Uri.to_string
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
  match cfg.Backend_types.backend_type with
  | Backend_types.Memory ->
      (* Backend.Memory now has Effect.Unhandled/Poisoned fallback
         built in, so it works in both Eio and non-Eio contexts.
         get_or_create shares state across configs for the same path. *)
      Ok (Memory (Backend.Memory.get_or_create ~base_path:cfg.cluster_name))
  | Backend_types.FileSystem ->
      if Fs_compat.has_fs () then
        match Fs_compat.get_fs_opt () with
        | Some fs -> Ok (FileSystem (Backend.FileSystem.create ~fs cfg))
        | None ->
            Log.Backend.warn
              "FileSystem backend expected an active Eio fs but none was present; falling back to Memory";
            Ok (Memory (Backend.Memory.get_or_create ~base_path:cfg.cluster_name))
      else
        (* No active Eio fs context available (e.g., tests running outside
           Eio_main.run, or a prior Eio test left a stale fs handle behind).
           Fall back to shared Memory backend for the same base path. *)
        (Log.Backend.warn "No active Eio fs context for FileSystem backend, falling back to Memory";
         Ok (Memory (Backend.Memory.get_or_create ~base_path:cfg.cluster_name)))
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

let backend_kind = function
  | Memory _ -> "Memory"
  | FileSystem _ -> "FileSystem"
  | PostgresNative _ -> "PostgresNative"

let auto_storage_requested () =
  match env_opt "MASC_STORAGE_TYPE" with
  | None -> true
  | Some value -> String.lowercase_ascii value = "auto"

let auto_local_backend ~reason cfg =
  match Fs_compat.get_fs_opt () with
  | Some fs when Fs_compat.has_fs () ->
      let fs_cfg =
        { cfg with Backend_types.backend_type = Backend_types.FileSystem }
      in
      let backend = FileSystem (Backend.FileSystem.create ~fs fs_cfg) in
      Log.Backend.info "Auto-detect: %s → FileSystem backend" reason;
      Log.Backend.info "Backend initialized: %s" (backend_kind backend);
      backend
  | _ ->
      let backend = Memory (Backend.Memory.get_or_create ~base_path:cfg.cluster_name) in
      Log.Backend.info "Auto-detect: %s → Memory backend" reason;
      Log.Backend.info "Backend initialized: %s" (backend_kind backend);
      backend

let default_config base_path =
  (* Resolve to git root for worktree support - all worktrees share same .masc/ *)
  let resolved_path = resolve_masc_base_path base_path in
  let backend_config = backend_config_for resolved_path in
  Log.Backend.info "MASC Backend: type=%s, postgres_url=%s"
    (Backend_types.show_backend_type backend_config.backend_type)
    (match backend_config.postgres_url with Some _ -> "<configured>" | None -> "none");
  let backend =
    if auto_storage_requested ()
       && Option.is_none (Eio_context.get_net_opt ())
    then
      match backend_config.Backend_types.backend_type with
      | Backend_types.PostgresNative ->
          auto_local_backend
            ~reason:"PostgreSQL URL found but no active Eio net"
            backend_config
      | Backend_types.FileSystem when not (Fs_compat.has_fs ()) ->
          auto_local_backend
            ~reason:"No active Eio fs context"
            backend_config
      | _ ->
          match create_backend backend_config with
          | Ok backend ->
              Log.Backend.info "Backend initialized: %s"
                (backend_kind backend);
              backend
          | Error e ->
              Log.Backend.warn "Backend init failed (%s). Falling back to filesystem."
                (Backend_types.show_error e);
              let fallback_cfg =
                { backend_config with Backend_types.backend_type = Backend_types.FileSystem }
              in
              (match create_backend fallback_cfg with
               | Ok fb -> fb
               | Error _ ->
                   (* Final fallback: shared in-memory to keep server alive *)
                   Memory (Backend.Memory.get_or_create ~base_path:backend_config.cluster_name))
    else
      match create_backend backend_config with
      | Ok backend ->
          Log.Backend.info "Backend initialized: %s"
            (backend_kind backend);
          backend
      | Error e ->
          Log.Backend.warn "Backend init failed (%s). Falling back to filesystem."
            (Backend_types.show_error e);
          let fallback_cfg =
            { backend_config with Backend_types.backend_type = Backend_types.FileSystem }
          in
          (match create_backend fallback_cfg with
           | Ok fb -> fb
           | Error _ ->
               (* Final fallback: shared in-memory to keep server alive *)
               Memory (Backend.Memory.get_or_create ~base_path:backend_config.cluster_name))
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
        Log.Backend.warn "Backend init failed (%s). Falling back to filesystem."
          (Backend_types.show_error e);
        let fallback_cfg =
          { backend_config with Backend_types.backend_type = Backend_types.FileSystem }
        in
        (match create_backend fallback_cfg with
         | Ok fb -> fb
         | Error _ ->
             (* Final fallback: shared in-memory to keep server alive *)
             Memory (Backend.Memory.get_or_create ~base_path:backend_config.cluster_name))
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
