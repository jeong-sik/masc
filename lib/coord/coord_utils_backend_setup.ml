(** Coord Utilities - Shared helpers for Coord module *)

(** Storage backend type - unified interface (Backend only) *)
type storage_backend =
  | Memory of Backend.Memory.t
  | FileSystem of Backend.FileSystem.t

(** Coord configuration *)
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

let test_base_path_override_env = "MASC_TEST_ALLOW_BASE_PATH_OVERRIDE"

let test_base_path_override_enabled () =
  Env_config_core.get_bool ~default:false test_base_path_override_env

let sync_test_base_path_env resolved_path =
  if running_under_test_executable ()
     && not (test_base_path_override_enabled ())
  then
    match Env_config_core.base_path_opt () with
    | Some current when String.equal current resolved_path -> ()
    | _ ->
        Unix.putenv Env_config_core.base_path_env_key resolved_path;
        Unix.putenv "MASC_TEST_SYNCED_BASE_PATH" resolved_path;
        Log.Coord.info "Synchronized MASC_BASE_PATH=%s for test executable %s"
          resolved_path (Filename.basename Sys.executable_name)

(** Dedupe MASC-base-path log lines across back-to-back identical resolutions.

    [resolve_masc_base_path] is called on every HTTP request (see
    [server_mcp_transport_http_session.default_base_path]). cwd and
    [MASC_BASE_PATH] are invariant per server lifetime, so every call
    produces the same log lines — which used to spam the log every few
    seconds. The resolver still runs in full (so env changes in tests
    are honored); only log emission is suppressed when the exact message
    has been logged before.

    The set is unbounded because the number of distinct log lines the
    resolver can produce is small and fixed (~4 patterns × realistic
    input paths). [Stdlib.Mutex] is used instead of [Eio.Mutex] because
    this resolver is called from both test executables (no Eio context)
    and the server (with Eio); [Eio.Mutex] raises Unhandled on the
    former. See feedback: ocaml5-mutex-selection. *)
let logged_lines : (string, unit) Hashtbl.t = Hashtbl.create 8
let logged_lines_mutex = Mutex.create ()

let log_once_info fmt =
  Format.kasprintf (fun msg ->
    let fresh =
      Stdlib.Mutex.protect logged_lines_mutex (fun () ->
        if Hashtbl.mem logged_lines msg then false
        else begin Hashtbl.add logged_lines msg (); true end)
    in
    if fresh then Log.Coord.info "%s" msg) fmt

let resolve_requested_base_path path =
  let requested = normalize_base_path path in
  match find_git_root requested with
  | Some git_root ->
      log_once_info "MASC base resolved: %s → %s (git root)" requested git_root;
      git_root
  | None ->
      log_once_info "MASC base: %s (no git root found)" requested;
      requested

(** Resolve base_path with a single authority:
    - in normal executables, explicit [MASC_BASE_PATH] wins
    - in test executables, a shell-provided [MASC_BASE_PATH] override is
      ignored unless it matches the requested path or the test explicitly opts
      in via [MASC_TEST_ALLOW_BASE_PATH_OVERRIDE]
    - otherwise resolve the requested path to its git root *)
let resolve_masc_base_path path =
  let requested = resolve_requested_base_path path in
  match Env_config_core.base_path_opt () with
  | Some explicit
    when running_under_test_executable ()
         && not (test_base_path_override_enabled ()) ->
      log_once_info
        "Ignoring test MASC_BASE_PATH override=%s for requested path %s"
        explicit path;
      requested
  | Some explicit
    when running_under_test_executable ()
         && not (test_base_path_override_enabled ())
         && not (String.equal explicit requested) ->
      log_once_info
        "Ignoring test MASC_BASE_PATH override=%s for requested path %s"
        explicit path;
      requested
  | Some explicit ->
      log_once_info "MASC base: %s (explicit MASC_BASE_PATH)" explicit;
      explicit
  | None -> requested

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

(** Auto-detect best backend based on environment variables.
    MASC defaults to the local filesystem unless the caller explicitly
    selects another backend via MASC_STORAGE_TYPE. *)
let auto_detect_backend () =
  Log.Backend.info
    "Auto-detect disabled: defaulting to FileSystem backend \
     unless MASC_STORAGE_TYPE is set";
  "filesystem"

(** Storage type from environment variable.
    Defaults to filesystem when MASC_STORAGE_TYPE is not set.

    Unknown / typo'd values (e.g. "postgres", "redis", "memoryy") used to
    silently pass through and the downstream wildcard in [backend_config_for]
    collapsed them into [FileSystem] with no log trace. Now an unknown value
    is warned and explicitly normalised to "filesystem", so the operator sees
    the drift. See #8737 / #8605. *)
let storage_type_from_env () =
  match env_opt Env_config_core.storage_type_env_key with
  | Some raw ->
      let value = String.lowercase_ascii (String.trim raw) in
      (match value with
       | "filesystem" | "file" | "jsonl" | "auto" -> "filesystem"
       | "memory" -> "memory"
       | other ->
           Log.Backend.warn
             "MASC_STORAGE_TYPE=%S not recognised (known: filesystem|file|jsonl|auto|memory) -> using filesystem; see #8737"
             other;
           "filesystem")
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
  (* Exhaustive over the values that [storage_type_from_env] now produces
     ("memory" | "filesystem"). The wildcard branch is defensive; if it ever
     fires the upstream sanitiser regressed and we want to know. *)
  let backend_type =
    match storage_type with
    | "memory" -> Backend_types.Memory
    | "filesystem" -> Backend_types.FileSystem
    | other ->
        Log.Backend.warn
          "backend_config_for: storage_type=%S bypassed sanitiser -> defaulting to FileSystem; see #8737"
          other;
        Backend_types.FileSystem
  in
  let masc_root = Common.masc_dir_from_base_path ~base_path in
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
    to initialize dependent systems (e.g., Board) without Coord depending on them. *)
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
