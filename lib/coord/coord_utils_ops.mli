val contains_substring : string -> string -> bool
val validate_agent_name : string -> (string, string) result
val validate_task_id : string -> (string, string) result
val validate_room_id : string -> (string, string) result
val validate_file_path : string -> (string, string) result
val sanitize_html : string -> string
val sanitize_agent_name : string -> string
val sanitize_message : string -> string
val safe_filename : string -> string
val validate_agent_name_r : string -> (string, Types.masc_error) result
val validate_task_id_r : string -> (string, Types.masc_error) result
val validate_file_path_r : string -> (string, Types.masc_error) result
val ensure_initialized : Coord_utils_backend_setup.config -> unit
val ensure_initialized_r : Coord_utils_backend_setup.config -> (unit, Types.masc_error) result
val mkdir_p : string -> unit
val read_json_local : string -> Yojson.Safe.t
val read_json_local_result : string -> (Yojson.Safe.t, string) result
val write_json_local : string -> Yojson.Safe.t -> (unit, string) result
val read_json_root : Coord_utils_backend_setup.config -> string -> Yojson.Safe.t
val write_json_root : Coord_utils_backend_setup.config -> string -> Yojson.Safe.t -> unit
val delete_path_root : Coord_utils_backend_setup.config -> string -> unit
val path_exists_root : Coord_utils_backend_setup.config -> string -> bool
val read_json : Coord_utils_backend_setup.config -> string -> Yojson.Safe.t
val read_json_result : Coord_utils_backend_setup.config -> string -> (Yojson.Safe.t, string) result
val read_text : Coord_utils_backend_setup.config -> string -> string
val should_dual_write_local : Coord_utils_backend_setup.config -> bool
val write_json : Coord_utils_backend_setup.config -> string -> Yojson.Safe.t -> unit
val write_text_local : string -> string -> (unit, string) result
val write_text : Coord_utils_backend_setup.config -> string -> string -> unit
val delete_path : Coord_utils_backend_setup.config -> string -> unit
val path_exists : Coord_utils_backend_setup.config -> string -> bool
val append_text : Coord_utils_backend_setup.config -> string -> string -> unit
val read_json_opt : Coord_utils_backend_setup.config -> string -> Yojson.Safe.t option
val agent_json_needs_repair : Yojson.Safe.t -> bool
val read_agent_with_repair : Coord_utils_backend_setup.config -> string -> (Types.agent, string) result
val sleep_lock_retry : ?clock:Eio.Time.clock -> float -> unit
val backoff_rng_key : Random.State.t Domain.DLS.key
val backoff_with_jitter : float -> float
val with_distributed_lock : ?clock:Eio.Time.clock -> Coord_utils_backend_setup.config -> string -> string -> (unit -> 'a) -> 'a
val with_distributed_lock_r : ?clock:Eio.Time.clock -> Coord_utils_backend_setup.config -> string -> string -> (unit -> 'a) -> ('a, Types.masc_error) result
val with_file_lock_impl : ?clock:Eio.Time.clock -> Coord_utils_backend_setup.config -> string -> (unit -> 'a) -> 'a
val with_file_lock_eio : clock:Eio.Time.clock -> Coord_utils_backend_setup.config -> string -> (unit -> 'a) -> 'a
val with_file_lock : Coord_utils_backend_setup.config -> string -> (unit -> 'a) -> 'a
val with_file_lock_r_impl : ?clock:Eio.Time.clock -> Coord_utils_backend_setup.config -> string -> (unit -> 'a) -> ('a, Types.masc_error) result
val with_file_lock_r_eio : clock:Eio.Time.clock -> Coord_utils_backend_setup.config -> string -> (unit -> 'a) -> ('a, Types.masc_error) result
val with_file_lock_r : Coord_utils_backend_setup.config -> string -> (unit -> 'a) -> ('a, Types.masc_error) result
val log_event : Coord_utils_backend_setup.config -> string -> unit