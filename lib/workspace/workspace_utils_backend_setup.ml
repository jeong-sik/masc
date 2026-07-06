(** Workspace Utilities - Shared helpers for Workspace module *)

(** Storage backend type - unified interface (Backend only) *)
type storage_backend =
  | Memory of Backend.Memory.t
  | FileSystem of Backend.FileSystem.t

(** Workspace configuration *)
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

(** Read .git file content (for worktrees). *)
let read_git_file_result path =
  match Safe_ops.read_file_safe path with
  | Ok content ->
    (match String.split_on_char '\n' content with
     | line :: _ -> Ok (Some (String.trim line))
     | [] -> Ok None)
  | Error err -> Error err

(** Compatibility facade for callers that only know how to project
    unreadable worktree pointers to local git-root fallback. *)
let read_git_file path =
  match read_git_file_result path with
  | Ok value -> value
  | Error err ->
    Log.Workspace.warn "read_git_file failed for %s: %s" path err;
    None

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
  else if Filename.is_relative trimmed then
    Filename.concat (Config_dir_resolver.current_working_dir ()) trimmed
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
    match (Host_config.from_env ()).base_path with
    | Some current when String.equal current resolved_path -> ()
    | _ ->
        Unix.putenv Env_config_core.base_path_env_key resolved_path;
        Unix.putenv Env_config_core.base_path_input_env_key resolved_path;
        Unix.putenv "MASC_TEST_SYNCED_BASE_PATH" resolved_path;
        Log.Workspace.info "Synchronized MASC_BASE_PATH=%s for test executable %s"
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
    if fresh then Log.Workspace.info "%s" msg) fmt

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
let resolved_base_path_cache : string option ref = ref None

let cache_resolved_base_path path =
  resolved_base_path_cache := Some path

let resolve_masc_base_path path =
  match !resolved_base_path_cache with
  | Some cached -> cached
  | None ->
    let requested = resolve_requested_base_path path in
    match (Host_config.from_env ()).base_path with
    | Some explicit
      when running_under_test_executable ()
           && not (test_base_path_override_enabled ())
           && not (String.equal explicit requested) ->
        (* Test executable, override not opted in, and the inherited
           [MASC_BASE_PATH] diverges from the requested path: ignore it. A
           matching override ([explicit = requested]) is intentionally left to
           fall through to the [Some explicit] arm below, which keeps it — the
           docstring's "ignored unless it matches the requested path". The
           former broad arm (same body, no equality guard) shadowed this
           narrower one, leaving it unreachable; OCaml does not flag
           [when]-guard redundancy, so the dead arm compiled silently. *)
        log_once_info
          "Ignoring test MASC_BASE_PATH override=%s for requested path %s"
          explicit path;
        requested
    | Some explicit ->
        log_once_info "MASC base: %s (explicit MASC_BASE_PATH)" explicit;
        explicit
    | None when running_under_test_executable () -> requested
    | None ->
        Log.Backend.error
          "MASC_BASE_PATH is not set. Set MASC_BASE_PATH to the project root \
           containing the .masc/ directory.";
        exit 1

let resolve_server_default_base_path path = resolve_masc_base_path path

(* ============================================ *)
(* Environment helpers                          *)
(* ============================================ *)

let is_unresolved_template value =
  let v = String.trim value in
  (String.length v >= 2 && v.[0] = '{' && v.[1] = '{')
  || String.starts_with v ~prefix:"op://"

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
  let cluster_name =
    match env_opt "MASC_CLUSTER_NAME" with
    | Some name -> name
    | None -> "default"
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
    Backend_types.base_path = backend_base_path;
    Backend_types.cluster_name;
    Backend_types.node_id = Backend_types.generate_node_id ();
    Backend_types.pubsub_max_messages = Backend_types.pubsub_max_messages;
  }

let memory_backend_fallback (cfg : Backend_types.config) =
  Memory (Backend.Memory.get_or_create ~base_path:cfg.Backend_types.base_path)

let create_backend cfg =
  let filesystem_fallback reason =
    Log.Backend.warn "%s Falling back to Memory backend." reason;
    Ok (memory_backend_fallback cfg)
  in
  let fs_usable fs =
    try
      ignore (Eio.Path.kind ~follow:true fs);
      true
    with
    | Stdlib.Effect.Unhandled _ -> false
  in
  match Fs_compat.get_fs_opt () with
  | Some fs when fs_usable fs ->
      Ok (FileSystem (Backend.FileSystem.create ~fs cfg))
  | Some _fs ->
      (* Tests sometimes inherit a stale Fs_compat handle from a previous
         Eio_main.run. Using it outside an active Eio scheduler explodes
         with Effect.Unhandled, so prefer the shared Memory fallback. *)
      filesystem_fallback "Stale Eio fs context for FileSystem backend;"
  | None ->
      (* No Eio fs context available (e.g., test without Fs_compat.set_fs).
         Fall back to shared Memory backend for the same base path. *)
      filesystem_fallback "No Eio fs context for FileSystem backend;"

let backend_name_of_storage = function
  | Memory _ -> "Memory"
  | FileSystem _ -> "FileSystem"

(* #10919: per-call Backend init was producing 1745 inits / 2 days
   (~83 inits per server lifetime against an expected 1) plus 3490
   INFO log lines.  Hot callers — [Workspace.default_config] from every
   MCP tool dispatch and [keeper_rollover] per rollover
   [keeper_rollover] per rollover — were paying both filesystem
   resolution and a fresh Backend handshake per invocation.

   The returned [config] is an immutable record and the underlying
   storage is already deduplicated upstream:

   - [Backend.Memory.shared_instances] keys by base_path (line 685),
     so two Memory backends for the same path were already pointing
     at identical hashtable state — the wrapper [config] was the
     duplicate.
   - FileSystem backends are pointers to on-disk state; multiple
     handles for the same directory share the underlying files.

   Caching [config] keyed by the input [base_path] therefore avoids
   1744 redundant inits without changing observable semantics.  Tests
   that need a fresh config (e.g. resetting filesystem state between
   cases) call [reset_default_config_cache] from outside this module
   when needed. *)
let default_config_cache : (string, config) Hashtbl.t = Hashtbl.create 4
let default_config_cache_mutex = Mutex.create ()

let with_default_config_cache_mutex f =
  Mutex.lock default_config_cache_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock default_config_cache_mutex) f

(** Drop the cached configs.  Intended for tests that need to force a
    re-init (e.g. after relocating the on-disk state).  Production
    code should never call this. *)
let reset_default_config_cache () =
  with_default_config_cache_mutex (fun () ->
    Hashtbl.clear default_config_cache)

let build_default_config base_path =
  (* Resolve to git root for worktree support - all worktrees share same .masc/ *)
  let resolved_path = resolve_masc_base_path base_path in
  sync_test_base_path_env resolved_path;
  let backend_config = backend_config_for resolved_path in
  (* #10919: this factory is invoked per-tool-dispatch (8 call sites:
     mcp_server_eio_call_tool, mcp_tool_runtime_workspace,
     keeper_rollover, ...) — 1745 inits / 2 days = 3490 INFO events
     for what is conceptually a static config.  Demote the success
     path to DEBUG; the failure / fallback paths below stay at
     WARN so operators still see degraded backend selection.  A
     per-base_path memoization patch (root fix for the per-call
     factory pattern itself) is left for a follow-up since it needs
     concurrency-safe state and broader test coverage. *)
  Log.Backend.debug "MASC Backend: filesystem";
  let backend =
    match create_backend backend_config with
    | Ok backend ->
        Log.Backend.debug "Backend initialized: %s" (backend_name_of_storage backend);
        backend
    | Error e ->
        Log.Backend.warn "Backend init failed (%s). Falling back to Memory."
          (Backend_types.show_error e);
        memory_backend_fallback backend_config
  in
  {
    base_path = resolved_path;  (* Use resolved path (git root for worktrees) *)
    workspace_path = base_path;
    lock_expiry_minutes = 2;
    backend_config;
    backend;
  }

let default_config base_path =
  with_default_config_cache_mutex (fun () ->
    match Hashtbl.find_opt default_config_cache base_path with
    | Some cfg -> cfg
    | None ->
        let cfg = build_default_config base_path in
        Hashtbl.replace default_config_cache base_path cfg;
        cfg)

(** Create config with Eio context.
    [on_backend_ready] is called after backend creation, allowing callers
    to initialize dependent systems (e.g., Board) without Workspace depending on them. *)
let default_config_eio ~sw ?(on_backend_ready = fun _backend -> ()) base_path =
  let _ = sw in
  let resolved_path = resolve_masc_base_path base_path in
  sync_test_base_path_env resolved_path;
  let backend_config = backend_config_for resolved_path in
  (* #10919: same noise pattern as [default_config]; demote success
     path to DEBUG.  Failure / fallback paths below stay at WARN. *)
  Log.Backend.debug "MASC Backend: filesystem";
  let backend =
    match create_backend backend_config with
    | Ok backend ->
        Log.Backend.debug "Backend initialized: %s" (backend_name_of_storage backend);
        on_backend_ready backend;
        backend
    | Error e ->
        Log.Backend.warn "Backend init failed (%s). Falling back to Memory."
          (Backend_types.show_error e);
        memory_backend_fallback backend_config
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
