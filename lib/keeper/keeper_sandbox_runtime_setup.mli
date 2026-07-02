val docker_command : unit -> string
val docker_command_argv : unit -> string list
val docker_run_pull_never_args : unit -> string list
val docker_image_missing_next_action : string
val run_docker_argv_with_status :
  summary:string ->
  timeout_sec:float -> string list -> Unix.process_status * string
type classified_error = { message : string; failure_class : string; }
val process_status_is_timeout : Unix.process_status -> bool
val lower_contains : string -> string -> bool
val output_looks_docker_daemon_unavailable : string -> bool
val output_looks_image_missing : string -> bool
val output_looks_timeout : string -> bool
val docker_output_looks_oci_mount_failure : string -> bool
val classify_docker_runtime_failure :
  status:Unix.process_status -> output:string -> string
val classify_image_inspect_failure :
  status:Unix.process_status -> output:string -> string
val classify_image_inventory_failure :
  status:Unix.process_status -> output:string -> string
val docker_run_looks_daemon_pressure :
  status:Unix.process_status -> output:string -> bool
val docker_info_security_options_with_class :
  timeout_sec:float -> (string list, classified_error) result
val docker_info_security_options :
  timeout_sec:float -> (string list, string) result
type required_command_check = { command : string; available : bool; }
type docker_preflight = {
  ok : bool;
  image : string;
  docker_runtime_ok : bool;
  docker_runtime_error : string option;
  hardening_ok : bool;
  hardening_error : string option;
  image_present : bool;
  image_error : string option;
  failure_classes : string list;
  required_commands : required_command_check list;
  missing_commands : string list;
  next_actions : string list;
}
val docker_preflight_min_sec : float
val docker_preflight_max_sec : float
val docker_preflight_timeout : timeout_sec:float -> float
val required_commands : string list
type cleanup_result = { scanned : int; removed : int; errors : string list; }
val sandbox_component_label_key : string
val sandbox_component_label_value : string
val sandbox_base_path_hash_label_key : string
val sandbox_keeper_label_key : string
val sandbox_kind_label_key : string
val sandbox_owner_pid_label_key : string
val sandbox_started_at_label_key : string
val sandbox_network_label_key : string
val sandbox_ttl_sec_label_key : string
val sandbox_turn_id_label_key : string
val strip_trailing_slashes : string -> string
val normalize_base_path_for_hash : string -> string
val base_path_hash : string -> string
val sanitize_label_value : string -> string
val find_char_from : string -> Char.t -> int -> int option
val max_docker_mount_path_log_len : int
val docker_mount_failure_looks_daemon_originated : string -> bool
val extract_quoted_value_after : string -> string -> string option
val docker_mount_failure_path : string -> string option
val docker_output_mentions_mount_failure : string -> bool
val docker_failure_output_for_log : string -> string
val optional_context_field : string -> string option -> string list
val docker_mount_failure_context_suffix :
  ?base_path_hash:string ->
  ?keeper_name:string ->
  ?image:string ->
  ?status_label:string ->
  ?container_kind:string -> ?network_label:string -> string -> string
val optional_json_string_field :
  'a -> string option -> ('a * [> `String of string ]) list
val docker_mount_failure_details :
  ?image:string ->
  ?status_label:string ->
  ?container_kind:string ->
  ?network_label:string ->
  base_path_hash:string ->
  keeper_name:string ->
  output:string ->
  unit -> [> `Assoc of (string * [> `String of string ]) list ] option
val docker_label_args :
  ?ttl_sec:float ->
  ?turn_id:int ->
  base_path:string ->
  keeper_name:string ->
  container_kind:string -> network_label:string -> unit -> string list
val docker_network_args :
  Keeper_types_profile_sandbox.network_mode -> string list * string
val docker_nofile_args : unit -> string list
val container_masc_runtime_base : container_root:'a -> string
val container_masc_dir : container_root:'a -> string
val container_masc_config_dir : container_root:'a -> string
val host_masc_config_dir : base_path:string -> string
val docker_masc_config_mount_spec :
  base_path:string -> container_root:'a -> string
val docker_masc_config_mount_args :
  base_path:string -> container_root:'a -> string list
val docker_masc_runtime_env_pairs :
  container_root:'a -> (string * string) list
val docker_masc_runtime_env_args : container_root:'a -> string list
val docker_user_env_args : unit -> string list
val trim_env_opt : string -> string option
val docker_config_host_root : base_path:string -> string
val docker_config_container_root : container_root:'a -> string
val docker_config_available : string -> bool
val docker_config_mount_args :
  base_path:string -> container_root:'a -> string list
val host_gitconfig_path : unit -> string
val container_gitconfig_path : unit -> string
val docker_gitconfig_mount_args : unit -> string list
type workspace_state_mount_kind = Workspace_state_file | Workspace_state_dir
val docker_workspace_state_mounts : (workspace_state_mount_kind * string) list
val workspace_state_path_available : workspace_state_mount_kind -> string -> bool
val unique_preserving_order : 'a list -> 'a list
val docker_workspace_state_mount_specs :
  base_path:string -> container_root:'a -> string list
val docker_workspace_state_mount_args :
  base_path:string -> container_root:'a -> string list
val docker_config_env_args :
  base_path:string -> container_root:'a -> string list
val docker_sandbox_env_args :
  base_path:string -> container_root:'a -> string list
val docker_identity_dir : host_root:string -> string
val docker_user_identity_mount_args :
  host_root:string -> uid:int -> gid:int -> (string list, string) result
val is_path_boundary_after : string -> int -> bool
val rewrite_host_root_to_container_root :
  host_root:string -> container_root:string -> string -> string
