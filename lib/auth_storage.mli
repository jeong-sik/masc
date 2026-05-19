val generate_token : unit -> string
val sha256_hash : string -> string
val auth_dir : string -> string
val agents_dir : string -> string
val room_secret_file : string -> string
val auth_config_file : string -> string
val initial_admin_file : string -> string
val internal_keeper_token_hash_file : string -> string
val internal_keeper_token_env_key : string
val run_blocking_io : (unit -> 'a) -> 'a
val file_exists : string -> bool
val read_text_file : string -> string
val write_text_file : string -> string -> unit
val chmod : string -> int -> unit
val read_dir : string -> string array
val remove_file : string -> unit
val ensure_auth_dirs : string -> unit
val write_initial_admin : string -> string -> unit
val save_private_text_file : string -> string -> unit
val load_internal_keeper_token_hash : string -> string option
val save_internal_keeper_token_hash : string -> raw_token:string -> unit
val verify_internal_keeper_token : string -> token:string -> bool
val ensure_internal_keeper_token : string -> string
val read_initial_admin : string -> string option
