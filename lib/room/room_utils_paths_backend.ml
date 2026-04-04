open Room_utils_backend_setup

let masc_root_dir config =
  let masc_root = Filename.concat config.base_path ".masc" in
  let cluster_name = config.backend_config.Backend_types.cluster_name in
  match cluster_name with
  | "" | "default" -> masc_root
  | other ->
      let seg = sanitize_namespace_segment other in
      Filename.concat (Filename.concat masc_root "clusters") seg

let rooms_root_dir config = Filename.concat (masc_root_dir config) "rooms"
let registry_root_path config = Filename.concat (masc_root_dir config) "rooms.json"
let current_room_root_path config = Filename.concat (masc_root_dir config) "current_room"

let warned_legacy_room_roots = Atomic.make []
let cached_legacy_room_roots = Atomic.make []

let rec mark_legacy_room_warning_emitted masc_root =
  let warned = Atomic.get warned_legacy_room_roots in
  if List.mem masc_root warned then
    false
  else if Atomic.compare_and_set warned_legacy_room_roots warned (masc_root :: warned) then
    true
  else
    mark_legacy_room_warning_emitted masc_root

let read_legacy_current_room config =
  let path = current_room_root_path config in
  if Sys.file_exists path then
    try
      let ic = open_in path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          match String.trim (input_line ic) with
          | "" -> None
          | room_id -> Some room_id)
    with _ -> None
  else
    None

let rec cache_legacy_room_root masc_root =
  let cached = Atomic.get cached_legacy_room_roots in
  if List.mem masc_root cached then
    ()
  else if Atomic.compare_and_set cached_legacy_room_roots cached (masc_root :: cached) then
    ()
  else
    cache_legacy_room_root masc_root

let legacy_room_dirs_exist_uncached config =
  let path = rooms_root_dir config in
  Sys.file_exists path
  &&
  try
    Sys.is_directory path && Array.length (Sys.readdir path) > 0
  with _ -> false

let legacy_room_dirs_exist config =
  let masc_root = masc_root_dir config in
  if List.mem masc_root (Atomic.get cached_legacy_room_roots) then
    true
  else
    let exists = legacy_room_dirs_exist_uncached config in
    if exists then cache_legacy_room_root masc_root;
    exists

(* Validation logic mirrors Room_utils_ops.validate_room_id but returns
   Option instead of Result.  Cannot call validate_room_id directly due to
   cyclic dependency (paths_backend <-> ops).  Keep in sync. *)
let room_id_re =
  Re.compile Re.(whole_string (rep1 (alt [rg 'A' 'Z'; rg 'a' 'z'; rg '0' '9'; char '.'; char '_'; char '-'])))

let normalize_current_room_label room_id =
  let room_id = String.trim room_id in
  if room_id = "" then None
  else if room_id = "." || room_id = ".." then None
  else if String.contains room_id '/' || String.contains room_id '\\' then None
  else if String_util.contains_substring room_id ".." then None
  else if not (Re.execp room_id_re room_id) then None
  else Some room_id

let warn_if_legacy_room_state_exists config =
  let legacy_current_room =
    match read_legacy_current_room config with
    | Some room_id when room_id <> "default" ->
        normalize_current_room_label room_id
    | Some _ -> None
    | None -> None
  in
  let has_legacy_rooms = legacy_room_dirs_exist config in
  match legacy_current_room, has_legacy_rooms with
  | None, false -> ()
  | _ ->
      let masc_root = masc_root_dir config in
      if mark_legacy_room_warning_emitted masc_root then
        let detail =
          match legacy_current_room, has_legacy_rooms with
          | Some room_id, true ->
              Printf.sprintf
                "legacy current_room=%S is ignored for the public default namespace pointer; explicit compatibility paths may still read room data under %S"
                room_id (rooms_root_dir config)
          | Some room_id, false ->
              Printf.sprintf
                "legacy current_room=%S is ignored for the public default namespace pointer"
                room_id
          | None, true ->
              Printf.sprintf
                "legacy room data under %S remains available only to explicit compatibility paths"
                (rooms_root_dir config)
          | None, false -> ""
        in
        Log.Room.warn
          "Legacy room-scoped state detected; startup now always resolves to the default scope and %s."
          detail

(** Read the compatibility current-room pointer.
    Room flattening keeps the file for backward compatibility, but the
    operational namespace is always the default root scope. *)
let read_current_room config =
  warn_if_legacy_room_state_exists config;
  Some "default"

let room_dir_for config room_id =
  if room_id = "default" then
    masc_root_dir config
  else
    Filename.concat (rooms_root_dir config) room_id

(** Resolve the initial scope from the current_room file.
    Named-room pointer resolution is deprecated; new configs always boot into
    the flat default namespace. *)
let resolve_initial_scope _config = Default

(** Scope-based directory resolution.
    Since #4638 scope is always [Default], so this always resolves to the
    root [.masc/] directory. *)
let masc_dir config =
  match config.scope with
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

(** Check if using PostgresNative backend (for HTTP state persistence) *)
let is_pg_backend config =
  match config.backend with
  | PostgresNative _ -> true
  | Memory _ | FileSystem _ -> false

(** Shared in-memory pubsub for FileSystem and Memory backends.
    PostgreSQL backend has its own pg_notify-based pubsub. *)
let _shared_pubsub = Backend_types.Pubsub_mem.create ()

(** Adapt Backend get (returns Ok string | Error NotFound) to
    the (string option, error) result shape used by all callers. *)
let backend_get config ~key =
  let result = match config.backend with
    | Memory t -> Backend.Memory.get t key
    | FileSystem t -> Backend.FileSystem.get t key
    | PostgresNative t -> Backend.Postgres.get t key
  in
  (match result with
   | Ok v -> Ok (Some v)
   | Error (Backend_types.NotFound _) -> Ok None
   | Error e -> Error e)

let backend_set config ~key ~value =
  match config.backend with
  | Memory t -> Backend.Memory.set t key value
  | FileSystem t -> Backend.FileSystem.set t key value
  | PostgresNative t -> Backend.Postgres.set t key value

(** Adapt Backend delete (returns Ok unit | Error NotFound) to
    the (bool, error) result shape. *)
let backend_delete config ~key =
  let result = match config.backend with
    | Memory t -> Backend.Memory.delete t key
    | FileSystem t -> Backend.FileSystem.delete t key
    | PostgresNative t -> Backend.Postgres.delete t key
  in
  (match result with
   | Ok () -> Ok true
   | Error (Backend_types.NotFound _) -> Ok false
   | Error e -> Error e)

let backend_exists config ~key =
  match config.backend with
  | Memory t -> Backend.Memory.exists t key
  | FileSystem t -> Backend.FileSystem.exists t key
  | PostgresNative t -> Backend.Postgres.exists t key

let backend_list_keys config ~prefix =
  match config.backend with
  | Memory t -> Backend.Memory.list_keys t ~prefix
  | FileSystem t -> Backend.FileSystem.list_keys t ~prefix
  | PostgresNative t -> Backend.Postgres.list_keys t ~prefix

(** get_all: Memory uses native Hashtbl fold, FileSystem uses list_keys + get.
    PostgreSQL has a native get_all. *)
let backend_get_all config ~prefix =
  match config.backend with
  | PostgresNative t -> Backend.Postgres.get_all t ~prefix
  | Memory t -> Backend.Memory.get_all t ~prefix
  | FileSystem _ ->
      (match backend_list_keys config ~prefix with
       | Error e -> Error e
       | Ok keys ->
           let pairs = List.filter_map (fun k ->
             match backend_get config ~key:k with
             | Ok (Some v) -> Some (k, v)
             | _ -> None
           ) keys in
           Ok pairs)

let backend_set_if_not_exists config ~key ~value =
  match config.backend with
  | Memory t -> Backend.Memory.set_if_not_exists t key value
  | FileSystem t -> Backend.FileSystem.set_if_not_exists t key value
  | PostgresNative t -> Backend.Postgres.set_if_not_exists t key value

let backend_acquire_lock config ~key ~ttl_seconds ~owner =
  match config.backend with
  | Memory _ -> Ok true  (* In-memory is single-process *)
  | FileSystem t -> Backend.FileSystem.acquire_lock t ~key ~owner ~ttl_seconds
  | PostgresNative t -> Backend.Postgres.acquire_lock t ~key ~owner ~ttl_seconds

let backend_release_lock config ~key ~owner =
  match config.backend with
  | Memory _ -> Ok true
  | FileSystem t -> Backend.FileSystem.release_lock t ~key ~owner
  | PostgresNative t -> Backend.Postgres.release_lock t ~key ~owner

let backend_extend_lock config ~key ~ttl_seconds ~owner =
  match config.backend with
  | Memory _ -> Ok true
  | FileSystem t -> Backend.FileSystem.extend_lock t ~key ~owner ~ttl_seconds
  | PostgresNative t -> Backend.Postgres.extend_lock t ~key ~owner ~ttl_seconds

let backend_health_check config =
  match config.backend with
  | Memory _ -> Ok { Backend_types.latency_ms = 0.0; is_healthy = true }
  | FileSystem t -> Backend.FileSystem.health_check t
  | PostgresNative t -> Backend.Postgres.health_check t

(** Publish: PostgreSQL uses pg_notify, FileSystem/Memory use shared in-mem pubsub. *)
let backend_publish config ~channel ~message =
  match config.backend with
  | PostgresNative t -> Backend.Postgres.publish t ~channel ~message
  | Memory _ | FileSystem _ ->
      Backend_types.Pubsub_mem.publish (_shared_pubsub) ~channel ~message

(** Subscribe: PostgreSQL uses table polling, FileSystem/Memory use shared in-mem pubsub. *)
let backend_subscribe config ~channel ~callback =
  match config.backend with
  | PostgresNative t -> Backend.Postgres.subscribe t ~channel ~callback
  | Memory _ | FileSystem _ ->
      Backend_types.Pubsub_mem.subscribe (_shared_pubsub) ~channel ~callback

let backend_name config =
  match config.backend with
  | Memory _ -> "memory"
  | FileSystem _ -> "filesystem"
  | PostgresNative _ -> "postgres-native"

let backend_supports_local_dir = function
  | FileSystem _ -> true
  | Memory _ | PostgresNative _ -> false

(** Cleanup pubsub messages - only effective for PostgreSQL backend.
    Other backends use FS cleanup in gc or are ephemeral.
    Returns the number of deleted messages. *)
let backend_cleanup_pubsub config ~days ~max_messages =
  match config.backend with
  | PostgresNative t -> Backend.Postgres.cleanup_pubsub t ~days ~max_messages
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
  | Some _ when
      backend_supports_local_dir config.backend
      && Sys.file_exists path && Sys.is_directory path ->
      Sys.readdir path |> Array.to_list
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
