open Workspace_utils_backend_setup

(** Pure helper: compute the masc_root directory from primitives.

    Use this when a caller has a [base_path] string (e.g. from
    [Env_config_core.base_path]) but no [Workspace.config] value. Semantics
    match [masc_root_dir] exactly: default cluster -> [<base>/.masc/],
    non-default -> [<base>/.masc/clusters/<sanitized>/]. *)
let masc_root_dir_from ~base_path ~cluster_name =
  let masc_root = Common.masc_dir_from_base_path ~base_path in
  match cluster_name with
  | "" | "default" -> masc_root
  | other ->
      let seg = sanitize_namespace_segment other in
      Filename.concat (Filename.concat masc_root "clusters") seg

let masc_root_dir config =
  masc_root_dir_from
    ~base_path:config.base_path
    ~cluster_name:config.backend_config.Backend_types.cluster_name

(** Default-cluster shortcut for callers that only have a [base_path]
    string and are in the default-cluster code path (no multi-cluster
    awareness). Equivalent to
    [masc_root_dir_from ~base_path ~cluster_name:"default"] and still
    compiles down to [<base>/.masc]. Exposed so non-workspace call sites
    stop re-inlining [Filename.concat base_path ".masc"]. Issue #8355. *)
let masc_dir_from_base_path ~base_path =
  masc_root_dir_from ~base_path ~cluster_name:"default"

(** Directory resolution. Always resolves to the root .masc/ directory. *)
let masc_dir config = masc_root_dir config

let agents_dir config = Filename.concat (masc_dir config) "agents"
let tasks_dir config = Filename.concat (masc_dir config) "tasks"
let messages_dir config = Filename.concat (masc_dir config) "messages"
let state_path config = Filename.concat (masc_dir config) "state.json"
let backlog_path config = Filename.concat (tasks_dir config) "backlog.json"
let archive_path config = Filename.concat (masc_dir config) "tasks-archive.json"

(* Cluster-aware keeper OUTPUT directory (server-written state + sidecars). The
   trailing segment is [Common.keepers_runtime_dirname] — the single literal,
   shared with [Common.keepers_runtime_dir_of_base] — so the input/output
   relocation flips one constant, not a call-site sweep. Callers holding only a
   base_path, and workspace-internal / accountability modules that cannot depend
   on Workspace without a cycle, use the Common variant instead. *)
let keepers_runtime_dir config =
  Filename.concat (masc_root_dir config) Common.keepers_runtime_dirname

(** Shared in-memory pubsub for FileSystem and Memory backends.
    All supported backends now share the same in-memory pubsub. *)
let shared_pubsub = Backend_types.Pubsub_mem.create ()

(** Adapt Backend get (returns Ok string | Error NotFound) to
    the (string option, error) result shape used by all callers. *)
let backend_get config ~key =
  let result = match config.backend with
    | Memory t -> Backend.Memory.get t key
    | FileSystem t -> Backend.FileSystem.get t key
  in
  (match result with
   | Ok v -> Ok (Some v)
   | Error (Backend_types.NotFound _) -> Ok None
   | Error (Backend_types.AlreadyExists _ | Backend_types.IOError _
           | Backend_types.InvalidKey _ | Backend_types.ConnectionFailed _
           | Backend_types.BackendNotSupported _) as err -> err)

let backend_set config ~key ~value =
  match config.backend with
  | Memory t -> Backend.Memory.set t key value
  | FileSystem t -> Backend.FileSystem.set t key value

(** Adapt Backend delete (returns Ok unit | Error NotFound) to
    the (bool, error) result shape. *)
let backend_delete config ~key =
  let result = match config.backend with
    | Memory t -> Backend.Memory.delete t key
    | FileSystem t -> Backend.FileSystem.delete t key
  in
  (match result with
   | Ok () -> Ok true
   | Error (Backend_types.NotFound _) -> Ok false
   | Error (Backend_types.AlreadyExists _ | Backend_types.IOError _
           | Backend_types.InvalidKey _ | Backend_types.ConnectionFailed _
           | Backend_types.BackendNotSupported _) as err -> err)

let backend_exists config ~key =
  match config.backend with
  | Memory t -> Backend.Memory.exists t key
  | FileSystem t -> Backend.FileSystem.exists t key

let backend_list_keys config ~prefix =
  match config.backend with
  | Memory t -> Backend.Memory.list_keys t ~prefix
  | FileSystem t -> Backend.FileSystem.list_keys t ~prefix

(** get_all: Memory uses native Hashtbl fold, FileSystem uses list_keys + get. *)
let backend_get_all config ~prefix =
  match config.backend with
  | Memory t -> Backend.Memory.get_all t ~prefix
  | FileSystem _ ->
      (match backend_list_keys config ~prefix with
       | Error e -> Error e
       | Ok keys ->
           let rec collect acc = function
             | [] -> Ok (List.rev acc)
             | key :: rest -> (
                 match backend_get config ~key with
                 | Ok (Some value) -> collect ((key, value) :: acc) rest
                 | Ok None -> Error (Backend_types.NotFound key)
                 | Error err -> Error err)
           in
           collect [] keys)

let backend_set_if_not_exists config ~key ~value =
  match config.backend with
  | Memory t -> Backend.Memory.set_if_not_exists t key value
  | FileSystem t -> Backend.FileSystem.set_if_not_exists t key value

let backend_acquire_lock config ~key ~ttl_seconds ~owner =
  match config.backend with
  | Memory _ -> Ok true  (* In-memory is single-process *)
  | FileSystem t -> Backend.FileSystem.acquire_lock t ~key ~owner ~ttl_seconds

let backend_release_lock config ~key ~owner =
  match config.backend with
  | Memory _ -> Ok true
  | FileSystem t -> Backend.FileSystem.release_lock t ~key ~owner

let backend_extend_lock config ~key ~ttl_seconds ~owner =
  match config.backend with
  | Memory _ -> Ok true
  | FileSystem t -> Backend.FileSystem.extend_lock t ~key ~owner ~ttl_seconds

let backend_health_check config =
  match config.backend with
  | Memory _ -> Ok { Backend_types.latency_ms = 0.0; is_healthy = true }
  | FileSystem t -> Backend.FileSystem.health_check t

let backend_publish config ~channel ~message =
  match config.backend with
  | Memory _ | FileSystem _ ->
      Backend_types.Pubsub_mem.publish (shared_pubsub) ~channel ~message

let backend_subscribe config ~channel ~callback =
  match config.backend with
  | Memory _ | FileSystem _ ->
      Backend_types.Pubsub_mem.subscribe (shared_pubsub) ~channel ~callback

let backend_name config =
  match config.backend with
  | Memory _ -> "memory"
  | FileSystem _ -> "filesystem"

let backend_supports_local_dir = function
  | FileSystem _ -> true
  | Memory _ -> false

let backend_cleanup_pubsub config ~days ~max_messages =
  let _ = config, days, max_messages in
  Ok 0

(* ============================================ *)
(* Key/path conversion                          *)
(* ============================================ *)

(** Generate a short hash prefix for project isolation.
    Uses first 8 chars of MD5 hash of base_path.
    This ensures different test directories get different keys. *)
let project_prefix config =
  let hash = Digest.string config.base_path |> Digest.to_hex in
  String.sub hash 0 8

(** Convert absolute path to backend key.
    For distributed backends: includes project hash prefix for isolation.
    Example: /tmp/test-abc/.masc/state.json -> "a1b2c3d4:state.json"
    For filesystem: returns relative path without prefix. *)
let key_of_path_from_root config ~root path =
  let prefix = root ^ "/" in
  if String.starts_with path ~prefix then
    let rel =
      String.sub path (String.length prefix) (String.length path - String.length prefix)
    in
    let key = String.map (fun c -> if c = '/' then ':' else c) rel in
    match config.backend with
    | Memory _ -> Some (project_prefix config ^ ":" ^ key)
    | FileSystem _ -> Some key
  else
    None

(* Key mapping is always relative to the .masc root so workspace paths
   are preserved in the backend key (e.g., workspace:state.json). *)
let key_of_path config path = key_of_path_from_root config ~root:(masc_root_dir config) path
let root_key_of_path config path = key_of_path_from_root config ~root:(masc_root_dir config) path

let strip_prefix prefix s =
  if String.length s >= String.length prefix then
    String.sub s (String.length prefix) (String.length s - String.length prefix)
  else
    s

let local_list_dir_result path =
  try Ok (Sys.readdir path |> Array.to_list)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Error
      (Printf.sprintf "failed to list local directory %s: %s"
         path
         (Printexc.to_string exn))

let list_dir_result config path =
  match key_of_path config path with
  | None ->
      if Sys.file_exists path && Sys.is_directory path then
        local_list_dir_result path
      else Ok []
  | Some _ when
      backend_supports_local_dir config.backend
      && Sys.file_exists path && Sys.is_directory path ->
      local_list_dir_result path
  | Some key_prefix ->
      let prefix = key_prefix ^ ":" in
      (match backend_list_keys config ~prefix with
       | Ok keys ->
           Ok
             (List.map
                (fun key ->
                   let rest = strip_prefix prefix key in
                   String.map (fun c -> if c = ':' then '/' else c) rest)
                keys)
       | Error err ->
         Error
           (Printf.sprintf
              "failed to list backend directory %s with prefix %s: %s"
              path
              prefix
              (Backend_types.show_error err)))

let list_dir config path =
  match list_dir_result config path with
  | Ok names -> names
  | Error msg ->
    Log.Workspace.warn "list_dir: %s" msg;
    []

(* ============================================ *)
(* Initialization check                         *)
(* ============================================ *)

let root_state_path config = Filename.concat (masc_root_dir config) "root-state.json"

(* Legacy root marker before root/workspace split lived at .masc/state.json. *)
let legacy_root_state_path config = Filename.concat (masc_root_dir config) "state.json"

(** Root initialization check - independent of current workspace.
    Used by workspace/cluster management features. *)
let root_is_initialized config =
  match config.backend with
  | Memory _ ->
      let exists_root path ~fallback_key =
        let key =
          match root_key_of_path config path with
          | Some k -> k
          | None -> fallback_key
        in
        backend_exists config ~key
      in
      exists_root (root_state_path config) ~fallback_key:"root-state.json" ||
      exists_root (legacy_root_state_path config) ~fallback_key:"state.json"
  | FileSystem _ ->
      Sys.file_exists (masc_root_dir config) &&
      Sys.is_directory (masc_root_dir config) &&
      (Sys.file_exists (root_state_path config) || Sys.file_exists (legacy_root_state_path config))

(* Server-level cache for is_initialized — avoids 3 syscalls per request.
   Cache key is (base_path, cluster_name) to handle multi-config scenarios. *)
type init_cache_entry = {
  cached_result : bool;
  cached_at : float;
}

let initialized_cache : init_cache_entry option Atomic.t = Atomic.make None
let initialized_cache_ttl = 1.0  (* seconds *)

(** Check if current workspace is initialized - backend-agnostic.
    Cached with 1-second TTL to avoid 3 filesystem syscalls per request. *)
let is_initialized config =
  let now = Time_compat.now () in
  match Atomic.get initialized_cache with
  | Some entry when now -. entry.cached_at < initialized_cache_ttl ->
      entry.cached_result
  | _ ->
      let result =
        match config.backend with
        | Memory _ ->
            let state_key =
              match key_of_path config (state_path config) with
              | Some k -> k
              | None -> "state.json"
            in
            backend_exists config ~key:state_key
        | FileSystem _ ->
            Sys.file_exists (masc_dir config) &&
            Sys.is_directory (masc_dir config) &&
            Sys.file_exists (state_path config)
      in
      Atomic.set initialized_cache (Some { cached_result = result; cached_at = now });
      result

(** Invalidate the is_initialized cache. Call this when workspace state
    changes (e.g., after init, reset, or cleanup operations). *)
let invalidate_initialized_cache () =
  Atomic.set initialized_cache None

(* ============================================ *)
(* Validation helpers                           *)
