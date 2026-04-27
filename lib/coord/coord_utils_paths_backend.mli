val masc_root_dir_from : base_path:string -> cluster_name:string -> string
val masc_root_dir : Coord_utils_backend_setup.config -> string
val masc_dir_from_base_path : base_path:string -> string
val current_room_root_path : Coord_utils_backend_setup.config -> string
val room_dir_for : Coord_utils_backend_setup.config -> string -> string
val read_current_room : Coord_utils_backend_setup.config -> string option
val masc_dir : Coord_utils_backend_setup.config -> string
val agents_dir : Coord_utils_backend_setup.config -> string
val tasks_dir : Coord_utils_backend_setup.config -> string
val messages_dir : Coord_utils_backend_setup.config -> string
val state_path : Coord_utils_backend_setup.config -> string
val backlog_path : Coord_utils_backend_setup.config -> string
val archive_path : Coord_utils_backend_setup.config -> string
val is_pg_backend : Coord_utils_backend_setup.config -> bool
val backend_get : Coord_utils_backend_setup.config -> key:string -> (string option, Backend_types.error) result
val backend_set : Coord_utils_backend_setup.config -> key:string -> value:string -> (unit, Backend_types.error) result
val backend_delete : Coord_utils_backend_setup.config -> key:string -> (bool, Backend_types.error) result
val backend_exists : Coord_utils_backend_setup.config -> key:string -> bool
val backend_list_keys : Coord_utils_backend_setup.config -> prefix:string -> (string list, Backend_types.error) result
val backend_get_all : Coord_utils_backend_setup.config -> prefix:string -> ((string * string) list, Backend_types.error) result
val backend_set_if_not_exists : Coord_utils_backend_setup.config -> key:string -> value:string -> (bool, Backend_types.error) result
val backend_acquire_lock : Coord_utils_backend_setup.config -> key:string -> ttl_seconds:int -> owner:string -> (bool, Backend_types.error) result
val backend_release_lock : Coord_utils_backend_setup.config -> key:string -> owner:string -> (bool, Backend_types.error) result
val backend_extend_lock : Coord_utils_backend_setup.config -> key:string -> ttl_seconds:int -> owner:string -> (bool, Backend_types.error) result
val backend_health_check : Coord_utils_backend_setup.config -> (Backend_types.health_status, Backend_types.error) result
val backend_publish : Coord_utils_backend_setup.config -> channel:string -> message:string -> (unit, Backend_types.error) result
val backend_subscribe : Coord_utils_backend_setup.config -> channel:string -> callback:(string -> unit) -> (unit, Backend_types.error) result
val backend_name : Coord_utils_backend_setup.config -> string
val backend_supports_local_dir : Coord_utils_backend_setup.storage_backend -> bool
val backend_cleanup_pubsub : Coord_utils_backend_setup.config -> days:int -> max_messages:int -> (int, Backend_types.error) result
val project_prefix : Coord_utils_backend_setup.config -> string
val key_of_path_from_root : Coord_utils_backend_setup.config -> root:string -> string -> string option
val key_of_path : Coord_utils_backend_setup.config -> string -> string option
val root_key_of_path : Coord_utils_backend_setup.config -> string -> string option
val strip_prefix : string -> string -> string
val list_dir : Coord_utils_backend_setup.config -> string -> string list
val root_state_path : Coord_utils_backend_setup.config -> string
val legacy_root_state_path : Coord_utils_backend_setup.config -> string
val root_is_initialized : Coord_utils_backend_setup.config -> bool
val is_initialized : Coord_utils_backend_setup.config -> bool