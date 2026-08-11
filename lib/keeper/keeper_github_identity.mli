(** Keeper-scoped GitHub CLI identity.

    GitHub CLI state is stored outside the generic Keeper secret projection.
    Token environment variables remain owned by [Keeper_secret_projection]. *)

type auth_result =
  { authenticated : bool
  ; login : string option
  ; error : string option
  }

type observation =
  { keeper : string
  ; hostname : string
  ; config_dir : string
  ; projected_token_env_names : string list
  ; stored : auth_result
  ; effective : auth_result
  ; checked_at_unix : float
  }

val config_dir : base_path:string -> keeper_name:string -> string
val container_config_dir : container_masc_dir:string -> keeper_name:string -> string
val ensure_config_dir : base_path:string -> keeper_name:string -> (string, string) result
val overlay_config_env : config_dir:string -> string array -> string array
val strip_github_token_env : string array -> string array
val projected_token_env_names : string array -> string list

val runtime_env :
  base_path:string -> keeper_name:string -> string array -> (string array, string) result

type tool_identity_state =
  | Unconfigured
  | Configured of string

(** Projects the deterministic Keeper path without provisioning it. Missing
    state is [Unconfigured]; malformed or unsafe state is a typed error rather
    than being collapsed into absence. *)
val runtime_env_for_tool :
  base_path:string ->
  keeper_name:string ->
  string array ->
  (string array * tool_identity_state, string) result

val docker_args :
  base_path:string ->
  keeper_name:string ->
  container_masc_dir:string ->
  (string list, string) result

(** Docker counterpart of [runtime_env_for_tool]. A safe existing identity is
    mounted read-only; an absent one projects only its deterministic container
    path. Malformed state remains a typed error. *)
val docker_args_for_tool :
  base_path:string ->
  keeper_name:string ->
  container_masc_dir:string ->
  (string list * tool_identity_state, string) result

val login_argv : hostname:string -> string list
val logout_argv : hostname:string -> string list
val login_env : base_path:string -> keeper_name:string -> (string array, string) result

val observe :
  base_path:string -> keeper_name:string -> hostname:string -> (observation, string) result

val auth_result_to_yojson : auth_result -> Yojson.Safe.t
val observation_to_yojson : observation -> Yojson.Safe.t
val secure_config_files :
  base_path:string -> keeper_name:string -> (unit, string) result

val stream_login :
  base_path:string ->
  keeper_name:string ->
  hostname:string ->
  env:string array ->
  is_closed:(unit -> bool) ->
  send_event:(string -> Yojson.Safe.t -> unit) ->
  (unit, string) result
(** Run interactive [gh auth login] with redacted streaming events. Closing
    the response cancels and reaps the child; a bounded timeout is also
    enforced. The caller must validate Keeper existence before invoking it. *)

val run_cli_login : base_path:string -> keeper_name:string -> hostname:string -> int
val run_cli_status : base_path:string -> keeper_name:string -> hostname:string -> int
val run_cli_logout : base_path:string -> keeper_name:string -> hostname:string -> int
