val docker_command : unit -> string
val refuse_real_daemon_under_test : what:string -> unit
(** Raise when a test executable is about to reach the host docker daemon
    without a fake configured.

    A container a test starts is named for its temp base_path. Nothing
    reclaims it: a persistent container outliving its owner pid is the normal
    state between server restarts, so the sweep leaves it, and no teardown
    owns a workspace nobody will open again. Ten of them were found on the
    daemon on 2026-08-29.

    [what] names the operation for the message ("start a container"). Set
    MASC_TEST_ALLOW_REAL_DOCKER=1 to opt a test into the real daemon
    deliberately. *)

val docker_command_argv : unit -> string list
val docker_run_pull_never_args : unit -> string list
(** Argv removing [container] together with the anonymous volumes it owns.

    The sandbox image declares VOLUME ["/tmp/keeper-creds"], so every container
    started from it carries a fresh anonymous volume. [-v] is inside this argv
    so a removal site cannot orphan that volume by leaving the flag out. *)
val docker_remove_argv : string -> string list

val docker_image_inspect_next_action : string
val run_docker_argv_with_status :
  ?timeout_sec:float -> string list -> Unix.process_status * string
type classified_error = {
  message : string;
  failure_class : Keeper_sandbox_runtime_classify.docker_failure_class;
}
val process_status_is_timeout : Unix.process_status -> bool
val classify_docker_info_failure :
  status:Unix.process_status -> Keeper_sandbox_runtime_classify.docker_failure_class
val classify_image_inspect_failure :
  status:Unix.process_status -> Keeper_sandbox_runtime_classify.docker_failure_class
val docker_info_security_options_with_class :
  timeout_sec:float -> (string list, classified_error) result
val docker_info_security_options_optional :
  ?timeout_sec:float -> unit -> (string list, string) result
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
  next_actions : string list;
}
type cleanup_result =
  { scanned : int
  ; removed : int
  ; already_absent : int
  ; errors : string list
  }
val sandbox_component_label_key : string
val sandbox_component_label_value : string
val sandbox_base_path_hash_label_key : string
val sandbox_keeper_label_key : string
val sandbox_kind_label_key : string
val sandbox_owner_pid_label_key : string
val sandbox_started_at_label_key : string
val sandbox_network_label_key : string
val sandbox_ttl_sec_label_key : string

val turn_container_kind : string
(** Value of the [masc.mcp.kind] label on a one-turn container. *)

val persistent_container_kind : string
(** Value of the [masc.mcp.kind] label on a keeper-lifetime container:
    adopted across turns and server restarts, removed only when the keeper
    is. *)

val current_owner_pid : unit -> int
(** The pid written as [masc.mcp.owner_pid] and the one a filter must supply to
    select those containers again. Kept as one reader so a filter cannot be
    built from a different pid than the label carries. *)
(** Value of the [masc.mcp.kind] label on a container that lives for one turn. *)

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
  base_path:string ->
  keeper_name:string ->
  container_kind:string -> network_label:string -> unit -> string list
val docker_network_args :
  Keeper_types_profile_sandbox.network_mode -> (string list * string, string) result
(** [Network_policy] is refused here: the Docker egress boundary has not been
    measured, and a mode that is policy on one backend and advice on another
    is worse than one that says no (RFC-0415). *)
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
val docker_config_mount_args :
  base_path:string -> container_root:'a -> string list
type workspace_state_mount_kind = Workspace_state_file | Workspace_state_dir

(** Why a path is allowed inside a keeper container: the store it belongs to.

    Provenance rather than inspection. A secret-shaped content scan cannot do
    this job -- a Slack bot token and a task id have the same shape -- so what
    is asserted instead is that MASC writes the file itself, in a schema MASC
    owns. A path that fits no variant is a path nobody has justified; adding one
    is a visible decision, where one more entry in a list of paths is not. *)
type mount_warrant =
  | Board_store
  | Task_store
  | Goal_store

val mount_warrant_to_string : mount_warrant -> string

val docker_workspace_state_mounts
  : (mount_warrant * workspace_state_mount_kind * string) list
val unique_preserving_order : 'a list -> 'a list
val docker_workspace_state_mount_specs :
  base_path:string -> container_root:'a -> string list
val docker_workspace_state_mount_args :
  base_path:string -> container_root:'a -> string list
val config_env_names : string list
val docker_config_env :
  base_path:string -> container_root:'a -> (string * string) list
val docker_config_env_args :
  base_path:string -> container_root:'a -> string list
val docker_sandbox_env_args :
  base_path:string -> container_root:'a -> string list
val docker_user_identity_mount_args :
  host_root:string -> uid:int -> gid:int -> (string list, string) result
val rewrite_host_root_to_container_root :
  host_root:string -> container_root:string -> string -> string
