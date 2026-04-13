(** Room Utilities - Shared helpers for Room module *)

(** Storage backend type - unified interface (Backend only) *)
type storage_backend =
  | Memory of Backend.Memory.t
  | FileSystem of Backend.FileSystem.t

(** Room configuration *)
type config = {
  base_path: string;
  workspace_path: string;
  lock_expiry_minutes: int;
  backend_config: Backend_types.config;
  backend: storage_backend;
}

let domain_local_pg_backend_diagnostics_json () =
  `Assoc
    [
      ("creations", `Int 0);
      ("failures", `Int 0);
      ("last_error", `Null);
    ]

let with_domain_local_pg_backend ~sw ~net ~clock ~mono_clock config =
  let _ = sw, net, clock, mono_clock in
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

let normalize_base_path path =
  let trimmed = Env_config_core.normalize_masc_base_path_input path in
  if trimmed = "" then ""
  else if Filename.is_relative trimmed then Filename.concat (Sys.getcwd ()) trimmed
  else trimmed

let running_under_test_executable () =
  let executable =
    Sys.executable_name |> Filename.basename |> String.lowercase_ascii
  in
  String.starts_with ~prefix:"test_" executable

let sync_test_base_path_env resolved_path =
  if running_under_test_executable ()
     && not (Env_config_core.get_bool ~default:false "MASC_TEST_ALLOW_INHERITED_BASE_PATH")
  then
    match Env_config_core.base_path_opt () with
    | Some current when String.equal current resolved_path -> ()
    | _ ->
        Unix.putenv "MASC_BASE_PATH" resolved_path;
        Unix.putenv "MASC_TEST_SYNCED_BASE_PATH" resolved_path;
        Log.Room.info "Synchronized MASC_BASE_PATH=%s for test executable %s"
          resolved_path (Filename.basename Sys.executable_name)

let resolve_requested_base_path path =
  let requested = normalize_base_path path in
  match find_git_root requested with
  | Some git_root ->
      Log.Room.info "MASC base resolved: %s → %s (git root)" requested git_root;
      git_root
  | None ->
      Log.Room.info "MASC base: %s (no git root found)" requested;
      requested

(** Resolve base_path with a single authority:
    - explicit [MASC_BASE_PATH] always wins
    - otherwise resolve the requested path to its git root *)
let resolve_masc_base_path path =
  match Env_config_core.base_path_opt () with
  | Some explicit
    when running_under_test_executable ()
         && not
              (Env_config_core.get_bool ~default:false
                 "MASC_TEST_ALLOW_INHERITED_BASE_PATH") ->
      Log.Room.info
        "Ignoring inherited MASC_BASE_PATH=%s for requested test path %s"
        explicit path;
      resolve_requested_base_path path
  | Some explicit ->
      Log.Room.info "MASC base: %s (explicit MASC_BASE_PATH)" explicit;
      explicit
  | None -> resolve_requested_base_path path

let resolve_server_default_base_path path = resolve_masc_base_path path

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

let postgres_url_from_env () = None

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
    PostgreSQL values are normalized to filesystem because PG storage
    is no longer part of the live runtime path. *)
let storage_type_from_env () =
  match env_opt "MASC_STORAGE_TYPE" with
  | Some raw ->
      let value = String.lowercase_ascii (String.trim raw) in
      (match value with
       | "postgres" | "postgresql" | "postgres-native"
       | "filesystem" | "file" | "jsonl" | "auto" -> "filesystem"
       | "memory" -> "memory"
       | other -> other)
  | None -> auto_detect_backend ()

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
  let cluster_name =
    match env_opt "MASC_CLUSTER_NAME" with
    | Some name -> name
    | None -> "default"
  in
  let backend_type =
    match storage_type with
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
    Backend_types.postgres_url = None;
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
(** Create backend with Eio context. *)
let create_backend_eio ~sw cfg =
  let _ = sw in
  create_backend cfg

let default_config base_path =
  (* Resolve to git root for worktree support - all worktrees share same .masc/ *)
  let resolved_path = resolve_masc_base_path base_path in
  sync_test_base_path_env resolved_path;
  let backend_config = backend_config_for resolved_path in
  Log.Backend.info "MASC Backend: type=%s"
    (Backend_types.show_backend_type backend_config.backend_type);
  let backend =
    match create_backend backend_config with
    | Ok backend ->
        Log.Backend.info "Backend initialized: %s"
          (match backend with
           | Memory _ -> "Memory"
           | FileSystem _ -> "FileSystem");
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
  }

(** Create config with Eio context.
    [on_backend_ready] is called after backend creation, allowing callers
    to initialize dependent systems (e.g., Board) without Room depending on them. *)
let default_config_eio ~sw ?(on_backend_ready = fun _backend -> ()) base_path =
  let resolved_path = resolve_masc_base_path base_path in
  sync_test_base_path_env resolved_path;
  let backend_config = backend_config_for resolved_path in
  Log.Backend.info "MASC Backend: type=%s"
    (Backend_types.show_backend_type backend_config.backend_type);
  let backend =
    match create_backend_eio ~sw backend_config with
    | Ok backend ->
        Log.Backend.info "Backend initialized: %s"
          (match backend with
           | Memory _ -> "Memory"
           | FileSystem _ -> "FileSystem");
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
  }

(* ============================================ *)
(* Path utilities                               *)
