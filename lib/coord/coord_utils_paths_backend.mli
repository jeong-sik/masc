(** Coord paths + backend dispatch.

    Resolves the canonical [.masc/] directory layout (per-cluster +
    legacy room paths), and dispatches CRUD/lock/pubsub calls to
    the active [Backend] implementation (Memory / FileSystem). *)

open Coord_utils_backend_setup

(** Compute the masc_root directory from primitives.
    [cluster_name = "" | "default"] resolves to [<base>/.masc/];
    other names produce [<base>/.masc/clusters/<sanitized>/]. *)
val masc_root_dir_from :
  base_path:string -> cluster_name:string -> string

val masc_root_dir : config -> string

(** Default-cluster shortcut for callers holding only [base_path]
    (#8355: stops re-inlining [<base>/.masc] across non-coord
    callsites). *)
val masc_dir_from_base_path : base_path:string -> string

val current_room_root_path : config -> string
val room_dir_for : config -> string -> string

(** Always [Some "default"] — the operational namespace is
    single-room. *)
val read_current_room : config -> string option

val masc_dir : config -> string
val agents_dir : config -> string
val tasks_dir : config -> string
val messages_dir : config -> string
val state_path : config -> string
val backlog_path : config -> string
val archive_path : config -> string

(** {1 Backend dispatch} *)

(** Always [false] — postgres backend was removed. *)
val is_pg_backend : config -> bool

val backend_get :
  config -> key:string -> (string option, Backend_types.error) result

val backend_set :
  config -> key:string -> value:string -> (unit, Backend_types.error) result

(** Returns [Ok true] if a key was deleted, [Ok false] if absent. *)
val backend_delete :
  config -> key:string -> (bool, Backend_types.error) result

(** [backend_exists config ~key] returns whether [key] is present in
    the configured backend. The implementation delegates to
    [Backend.{Memory,FileSystem}.exists], both of which return [bool]
    (validation errors are mapped to [false]); no [Result] wrapper is
    propagated. *)
val backend_exists :
  config -> key:string -> bool

val backend_list_keys :
  config -> prefix:string -> (string list, Backend_types.error) result

val backend_get_all :
  config -> prefix:string -> ((string * string) list, Backend_types.error) result

val backend_set_if_not_exists :
  config -> key:string -> value:string -> (bool, Backend_types.error) result

val backend_acquire_lock :
  config -> key:string -> ttl_seconds:int -> owner:string ->
  (bool, Backend_types.error) result

val backend_release_lock :
  config -> key:string -> owner:string ->
  (bool, Backend_types.error) result

val backend_extend_lock :
  config -> key:string -> ttl_seconds:int -> owner:string ->
  (bool, Backend_types.error) result

val backend_health_check :
  config -> (Backend_types.health_result, Backend_types.error) result

val backend_publish :
  config -> channel:string -> message:string ->
  (unit, Backend_types.error) result

val backend_subscribe :
  config -> channel:string -> callback:(string -> unit) ->
  (unit, Backend_types.error) result

val backend_name : config -> string

(** [true] iff the backend mirrors keys to local-filesystem
    directories (FileSystem backend). *)
val backend_supports_local_dir : storage_backend -> bool

val backend_cleanup_pubsub :
  config -> days:int -> max_messages:int ->
  (int, Backend_types.error) result

(** {1 Path / key conversion} *)

(** Convert an absolute filesystem path to a backend key.
    Returns [None] when the path is not rooted under
    [masc_root_dir]. *)
val key_of_path : config -> string -> string option

(** Same as [key_of_path] — kept as a separate alias to make
    cluster-root-rooted lookups explicit at the call site. *)
val root_key_of_path : config -> string -> string option

(** List directory entries either via [Sys.readdir] (when the
    backend supports a local dir mirror) or via [backend_list_keys]
    over the synthesized prefix. *)
val list_dir : config -> string -> string list

(** {1 Initialization check} *)

(** Path to the canonical cluster-root state file
    ([<masc_root>/root-state.json]). Callers (coord_init,
    coord_bootstrap) need this to gate one-time initialization. *)
val root_state_path : config -> string

(** Backend-key prefix for the current room's broadcast/lock namespace.
    Used by coord_broadcast and Memory-backend-aware key composition. *)
val project_prefix : config -> string

(** [true] iff the cluster-root state file exists (independent of
    the current room). Used by room/cluster management features. *)
val root_is_initialized : config -> bool

(** [true] iff the current room is initialized (state.json
    present). Backend-agnostic check. *)
val is_initialized : config -> bool
