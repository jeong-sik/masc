(** Workspace paths + backend dispatch.

    Resolves the canonical [.masc/] directory layout (per-cluster),
    and dispatches CRUD/lock/pubsub calls to
    the active [Backend] implementation (Memory / FileSystem). *)

open Workspace_utils_backend_setup

(** Compute the masc_root directory from primitives.
    [cluster_name = "" | "default"] resolves to [<base>/.masc/];
    other names produce [<base>/.masc/clusters/<sanitized>/]. *)
val masc_root_dir_from :
  base_path:string -> cluster_name:string -> string

val masc_root_dir : config -> string

(** Default-cluster shortcut for callers holding only [base_path]
    (#8355: stops re-inlining [<base>/.masc] across non-workspace
    callsites). *)
val masc_dir_from_base_path : base_path:string -> string

val masc_dir : config -> string
val agents_dir : config -> string
val tasks_dir : config -> string
val messages_dir : config -> string
val state_path : config -> string
val backlog_path : config -> string
val archive_path : config -> string

(** Cluster-aware keeper OUTPUT directory (server-written state + sidecars). The
    trailing segment is [Common.keepers_runtime_dirname]; relocating the OUTPUT
    root flips that one constant. base_path-only and cycle-bound callers use
    [Common.keepers_runtime_dir_of_base] instead. *)
val keepers_runtime_dir : config -> string

(** Cluster-root state.json path. Used by bootstrap/init to gate
    one-time root setup. *)
val root_state_path : config -> string

(** Pre-rename cluster-root state path (legacy [.masc/state.json]).
    Kept exposed for fallback existence checks during migration. *)
val legacy_root_state_path : config -> string

(** Project-scoped key prefix for backend keys (e.g.
    ["proj:default"]). Used by broadcast/pubsub channel naming. *)
val project_prefix : config -> string

(** {1 Backend dispatch} *)

val backend_get :
  config -> key:string -> (string option, Backend_types.error) result

val backend_set :
  config -> key:string -> value:string -> (unit, Backend_types.error) result

(** Returns [Ok true] if a key was deleted, [Ok false] if absent. *)
val backend_delete :
  config -> key:string -> (bool, Backend_types.error) result

(** Plain [bool] (not [result]); the underlying backend implementations
    do not return errors here, and call sites compose with [||]. *)
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

(** Returns [Ok n] where [n] is the number of subscribers notified
    (forwarded from [Pubsub_mem.publish]). *)
val backend_publish :
  config -> channel:string -> message:string ->
  (int, Backend_types.error) result

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

val strip_prefix : string -> string -> string
(** [strip_prefix prefix s] removes the first [String.length prefix]
    characters from [s] without verifying that they actually equal
    [prefix] (callers must check separately). Returns [s] unchanged
    when it is shorter than [prefix]. *)

(** List directory entries either via [Sys.readdir] (when the
    backend supports a local dir mirror) or via [backend_list_keys]
    over the synthesized prefix. *)
val list_dir_result : config -> string -> (string list, string) result

val list_dir : config -> string -> string list

(** {1 Initialization check} *)

(** [true] iff the cluster-root state file exists (independent of
    the current workspace). Used by workspace/cluster management features. *)
val root_is_initialized : config -> bool

(** [true] iff the current workspace is initialized (state.json
    present). Backend-agnostic check. Cached with 1-second TTL. *)
val is_initialized : config -> bool

(** Invalidate the is_initialized cache. Call when workspace state
    changes (init, reset, cleanup). *)
val invalidate_initialized_cache : unit -> unit
