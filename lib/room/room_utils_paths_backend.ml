open Room_utils_backend_setup

let masc_root_dir config =
  let masc_root = Filename.concat config.base_path ".masc" in
  let cluster_name = config.backend_config.Backend.cluster_name in
  match cluster_name with
  | "" | "default" -> masc_root
  | other ->
      let seg = sanitize_namespace_segment other in
      Filename.concat (Filename.concat masc_root "clusters") seg

let rooms_root_dir config = Filename.concat (masc_root_dir config) "rooms"
let registry_root_path config = Filename.concat (masc_root_dir config) "rooms.json"
let current_room_root_path config = Filename.concat (masc_root_dir config) "current_room"

(** Read current room ID from .masc/current_room. *)
let read_current_room config =
  let read_from path =
    match Safe_ops.read_file_safe path with
    | Ok content ->
      let trimmed = String.trim content in
      if trimmed = "" then None
      else
        (match String.split_on_char '\n' trimmed with
         | line :: _ -> Some (String.trim line)
         | [] -> None)
    | Error _ -> None
  in
  match read_from (current_room_root_path config) with
  | Some room_id -> Some room_id
  | None -> Some "default"

let room_dir_for config room_id =
  if room_id = "default" then
    masc_root_dir config
  else
    Filename.concat (rooms_root_dir config) room_id

(** Resolve the initial scope from the current_room file.
    Called once at config creation time; the result is stored in config.scope
    so that all subsequent path lookups are pure and deterministic. *)
let resolve_initial_scope config =
  match read_current_room config with
  | Some "default" | None -> Default
  | Some room_id -> Named room_id

(** Scope-based directory resolution.
    Both branches are pure — no filesystem reads.
    Default scope resolves to the root .masc/ directory.
    Named scope resolves to .masc/rooms/{id}/.
    Callers that need the current_room file must call
    [config_with_resolved_scope] at config creation time. *)
let masc_dir config =
  match config.scope with
  | Named id -> room_dir_for config id
  | Default -> masc_root_dir config

let agents_dir config = Filename.concat (masc_dir config) "agents"
let tasks_dir config = Filename.concat (masc_dir config) "tasks"
let messages_dir config = Filename.concat (masc_dir config) "messages"
let state_path config = Filename.concat (masc_dir config) "state.json"
let backlog_path config = Filename.concat (tasks_dir config) "backlog.json"
let archive_path config = Filename.concat (masc_dir config) "tasks-archive.json"

(* ============================================ *)
(* Backend dispatch functions                   *)
(* ============================================ *)

(** Convert Backend_eio error to Backend_core error for dispatch compatibility *)
let eio_to_backend_error = function
  | Backend_eio.NotFound key -> Backend.KeyNotFound key
  | Backend_eio.AlreadyExists key -> Backend.OperationFailed ("already exists: " ^ key)
  | Backend_eio.IOError msg -> Backend.OperationFailed msg
  | Backend_eio.InvalidKey msg -> Backend.InvalidKey msg

(** Check if using PostgresNative backend (for HTTP state persistence) *)
let is_pg_backend config =
  match config.backend with
  | PostgresNative _ -> true
  | Memory _ | FileSystem _ -> false

let backend_fs_get t ~key =
  match t with
  | Eio t ->
      (match Backend_eio.FileSystem.get t key with
       | Ok v -> Ok (Some v)
       | Error (Backend_eio.NotFound _) -> Ok None
       | Error e -> Error (eio_to_backend_error e))
  | Compat t -> Backend.FileSystemBackend.get t ~key

let backend_fs_set t ~key ~value =
  match t with
  | Eio t ->
      Backend_eio.FileSystem.set t key value |> Result.map_error eio_to_backend_error
  | Compat t -> Backend.FileSystemBackend.set t ~key ~value

let backend_fs_delete t ~key =
  match t with
  | Eio t ->
      (match Backend_eio.FileSystem.delete t key with
       | Ok () -> Ok true
       | Error (Backend_eio.NotFound _) -> Ok false
       | Error e -> Error (eio_to_backend_error e))
  | Compat t -> Backend.FileSystemBackend.delete t ~key

let backend_fs_exists t ~key =
  match t with
  | Eio t -> Backend_eio.FileSystem.exists t key
  | Compat t -> Backend.FileSystemBackend.exists t ~key

let backend_fs_list_keys t ~prefix =
  match t with
  | Eio t ->
      Backend_eio.FileSystem.list_keys t ~prefix |> Result.map_error eio_to_backend_error
  | Compat t -> Backend.FileSystemBackend.list_keys t ~prefix

let backend_fs_get_all t ~prefix =
  match t with
  | Eio t ->
      Backend_eio.FileSystem.get_all t ~prefix |> Result.map_error eio_to_backend_error
  | Compat t -> Backend.FileSystemBackend.get_all t ~prefix

let backend_fs_set_if_not_exists t ~key ~value =
  match t with
  | Eio t ->
      Backend_eio.FileSystem.set_if_not_exists t key value
      |> Result.map_error eio_to_backend_error
  | Compat t -> Backend.FileSystemBackend.set_if_not_exists t ~key ~value

let backend_fs_acquire_lock t ~key ~ttl_seconds ~owner =
  match t with
  | Eio t ->
      Backend_eio.FileSystem.acquire_lock t ~key ~owner ~ttl_seconds
      |> Result.map_error eio_to_backend_error
  | Compat t -> Backend.FileSystemBackend.acquire_lock t ~key ~ttl_seconds ~owner

let backend_fs_release_lock t ~key ~owner =
  match t with
  | Eio t ->
      Backend_eio.FileSystem.release_lock t ~key ~owner
      |> Result.map_error eio_to_backend_error
  | Compat t -> Backend.FileSystemBackend.release_lock t ~key ~owner

let backend_fs_extend_lock t ~key ~ttl_seconds ~owner =
  match t with
  | Eio t ->
      Backend_eio.FileSystem.extend_lock t ~key ~owner ~ttl_seconds
      |> Result.map_error eio_to_backend_error
  | Compat t -> Backend.FileSystemBackend.extend_lock t ~key ~ttl_seconds ~owner

let backend_fs_health_check t =
  match t with
  | Eio t ->
      (match Backend_eio.FileSystem.health_check t with
       | Ok status -> Ok status.Backend_eio.is_healthy
       | Error e -> Error (eio_to_backend_error e))
  | Compat t -> Backend.FileSystemBackend.health_check t

let backend_fs_publish t ~channel ~message =
  match t with
  | Eio t -> Backend_eio.FileSystem.publish t ~channel ~message
  | Compat t -> Backend.FileSystemBackend.publish t ~channel ~message

let backend_fs_subscribe t ~channel ~callback =
  match t with
  | Eio t -> Backend_eio.FileSystem.subscribe t ~channel ~callback
  | Compat t -> Backend.FileSystemBackend.subscribe t ~channel ~callback

let backend_get config ~key =
  match config.backend with
  | Memory t -> Backend.MemoryBackend.get t ~key
  | FileSystem t -> backend_fs_get t ~key
  | PostgresNative t -> Backend.PostgresNative.get t ~key

let backend_set config ~key ~value =
  match config.backend with
  | Memory t -> Backend.MemoryBackend.set t ~key ~value
  | FileSystem t -> backend_fs_set t ~key ~value
  | PostgresNative t -> Backend.PostgresNative.set t ~key ~value

let backend_delete config ~key =
  match config.backend with
  | Memory t -> Backend.MemoryBackend.delete t ~key
  | FileSystem t -> backend_fs_delete t ~key
  | PostgresNative t -> Backend.PostgresNative.delete t ~key

let backend_exists config ~key =
  match config.backend with
  | Memory t -> Backend.MemoryBackend.exists t ~key
  | FileSystem t -> backend_fs_exists t ~key
  | PostgresNative t -> Backend.PostgresNative.exists t ~key

let backend_list_keys config ~prefix =
  match config.backend with
  | Memory t -> Backend.MemoryBackend.list_keys t ~prefix
  | FileSystem t -> backend_fs_list_keys t ~prefix
  | PostgresNative t -> Backend.PostgresNative.list_keys t ~prefix

let backend_get_all config ~prefix =
  match config.backend with
  | Memory t -> Backend.MemoryBackend.get_all t ~prefix
  | FileSystem t -> backend_fs_get_all t ~prefix
  | PostgresNative t -> Backend.PostgresNative.get_all t ~prefix

let backend_set_if_not_exists config ~key ~value =
  match config.backend with
  | Memory t -> Backend.MemoryBackend.set_if_not_exists t ~key ~value
  | FileSystem t -> backend_fs_set_if_not_exists t ~key ~value
  | PostgresNative t -> Backend.PostgresNative.set_if_not_exists t ~key ~value

let backend_acquire_lock config ~key ~ttl_seconds ~owner =
  match config.backend with
  | Memory t -> Backend.MemoryBackend.acquire_lock t ~key ~ttl_seconds ~owner
  | FileSystem t -> backend_fs_acquire_lock t ~key ~ttl_seconds ~owner
  | PostgresNative t -> Backend.PostgresNative.acquire_lock t ~key ~ttl_seconds ~owner

let backend_release_lock config ~key ~owner =
  match config.backend with
  | Memory t -> Backend.MemoryBackend.release_lock t ~key ~owner
  | FileSystem t -> backend_fs_release_lock t ~key ~owner
  | PostgresNative t -> Backend.PostgresNative.release_lock t ~key ~owner

let backend_extend_lock config ~key ~ttl_seconds ~owner =
  match config.backend with
  | Memory t -> Backend.MemoryBackend.extend_lock t ~key ~ttl_seconds ~owner
  | FileSystem t -> backend_fs_extend_lock t ~key ~ttl_seconds ~owner
  | PostgresNative t -> Backend.PostgresNative.extend_lock t ~key ~ttl_seconds ~owner

let backend_health_check config =
  match config.backend with
  | Memory t -> Backend.MemoryBackend.health_check t
  | FileSystem t -> backend_fs_health_check t
  | PostgresNative t -> Backend.PostgresNative.health_check t

let backend_publish config ~channel ~message =
  match config.backend with
  | Memory t -> Backend.MemoryBackend.publish t ~channel ~message
  | FileSystem t -> backend_fs_publish t ~channel ~message
  | PostgresNative t -> Backend.PostgresNative.publish t ~channel ~message

let backend_subscribe config ~channel ~callback =
  match config.backend with
  | Memory t -> Backend.MemoryBackend.subscribe t ~channel ~callback
  | FileSystem t -> backend_fs_subscribe t ~channel ~callback
  | PostgresNative t -> Backend.PostgresNative.subscribe t ~channel ~callback

let backend_name config =
  match config.backend with
  | Memory _ -> "memory"
  | FileSystem _ -> "filesystem"
  | PostgresNative _ -> "postgres-native"

(** Cleanup pubsub messages - only effective for PostgreSQL backend.
    Other backends use FS cleanup in gc or are ephemeral.
    Returns the number of deleted messages. *)
let backend_cleanup_pubsub config ~days ~max_messages =
  match config.backend with
  | PostgresNative t -> Backend.PostgresNative.cleanup_pubsub t ~days ~max_messages
  | Memory _ | FileSystem _ ->
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
  if String.length path >= String.length prefix &&
     String.sub path 0 (String.length prefix) = prefix then
    let rel =
      String.sub path (String.length prefix) (String.length path - String.length prefix)
    in
    let key = String.map (fun c -> if c = '/' then ':' else c) rel in
    match config.backend with
    | Memory _ | PostgresNative _ -> Some (project_prefix config ^ ":" ^ key)
    | FileSystem _ -> Some key
  else
    None

(* Key mapping is always relative to the .masc root so room paths
   are preserved in the backend key (e.g., rooms:my-room:state.json). *)
let key_of_path config path = key_of_path_from_root config ~root:(masc_root_dir config) path
let root_key_of_path config path = key_of_path_from_root config ~root:(masc_root_dir config) path

let strip_prefix prefix s =
  if String.length s >= String.length prefix then
    String.sub s (String.length prefix) (String.length s - String.length prefix)
  else
    s

let list_dir config path =
  match key_of_path config path with
  | None ->
      if Sys.file_exists path && Sys.is_directory path then
        Sys.readdir path |> Array.to_list
      else
        []
  | Some key_prefix ->
      let prefix = key_prefix ^ ":" in
      (match backend_list_keys config ~prefix with
       | Ok keys ->
           List.map (fun key ->
             let rest = strip_prefix prefix key in
             String.map (fun c -> if c = ':' then '/' else c) rest
           ) keys
       | Error _ -> [])

(* ============================================ *)
(* Initialization check                         *)
(* ============================================ *)

let root_state_path config = Filename.concat (masc_root_dir config) "root-state.json"

(* Legacy root marker before root/room split lived at .masc/state.json. *)
let legacy_root_state_path config = Filename.concat (masc_root_dir config) "state.json"

(** Root initialization check - independent of current room.
    Used by room/cluster management features. *)
let root_is_initialized config =
  match config.backend with
  | Memory _ | PostgresNative _ ->
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

(** Check if current room is initialized - backend-agnostic *)
let is_initialized config =
  match config.backend with
  | Memory _ | PostgresNative _ ->
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

(** Create a config with scope resolved from the current_room file.
    Wraps default_config / default_config_eio output so that masc_dir
    never needs to read the filesystem again. *)
let config_with_resolved_scope config =
  { config with scope = resolve_initial_scope config }

(* ============================================ *)
(* Validation helpers                           *)
