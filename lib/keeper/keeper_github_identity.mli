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
  ; effective_probe_scope : [ `Host_process_credential_only ]
  ; checked_at_unix : float
  }

val config_dir : config:Workspace.config -> keeper_name:string -> string
val container_config_dir : container_masc_dir:string -> keeper_name:string -> string

val secret_files_of_base_path : base_path:string -> keeper_name:string -> string list

val stored_token
  :  base_path:string
  -> keeper_name:string
  -> hostname:string
  -> (string, string) result
(** The token this Keeper's gh CLI holds for [hostname], read from its
    hosts.yml at the moment of asking.

    masc keeps no second copy: gh rewrites that file on login and logout, so
    a copy would answer with a credential the Keeper no longer has. Callers
    that need a bearer for a GitHub-backed provider come here rather than to
    the secret projection. An absent or logged-out identity is an error
    naming what to do, not an empty string. *)
(** Paths of the GitHub CLI files that can hold credentials ([hosts.yml])
    for callers that hold only [base_path] (default cluster). Intended as
    [additional_secret_files] input for
    {!Keeper_secret_redaction.snapshot_with_additional_secret_files};
    missing files are ignored there, so the paths are safe to pass
    unconditionally. *)
val ensure_config_dir : config:Workspace.config -> keeper_name:string -> (string, string) result
val overlay_config_env : config_dir:string -> string array -> string array
val projected_config_dir : string array -> string option
(** Read the exact [GH_CONFIG_DIR] installed by {!overlay_config_env}. *)
val strip_github_token_env : string array -> string array
val projected_token_env_names : string array -> string list

type tool_identity_state =
  | Unconfigured
  | Configured of string

type docker_tool_projection =
  { args : string list
  ; identity_state : tool_identity_state
  ; host_snapshot_dir : string
  ; revision : string
  ; cleanup : unit -> unit
  }

val current_tool_identity_revision :
  config:Workspace.config -> keeper_name:string -> (string, string) result
(** SHA-256 identity of the exact files a new tool snapshot would receive.
    The digest is comparison authority only and never exposes token bytes. *)

(** Projects the deterministic Keeper path without provisioning it. Missing
    state and a safe directory without a stored token in [hosts.yml] are
    [Unconfigured]; malformed or unsafe state is a typed error rather than
    being collapsed into absence. *)
val runtime_env_for_tool :
  config:Workspace.config ->
  keeper_name:string ->
  string array ->
  (string array * tool_identity_state * (unit -> unit), string) result
(** Local tools receive a per-dispatch copy-on-write snapshot and an explicit
    cleanup capability. They never receive the operator-owned identity path. *)

val docker_args :
  config:Workspace.config ->
  keeper_name:string ->
  container_masc_dir:string ->
  (string list, string) result

(** Stable-directory variant for keeper-lifetime containers: the mount is the
    live config directory (read-only), not a per-turn snapshot, so identity
    changes made on the host reach a running container through the bind
    mount. Includes the git credential wiring env; call
    [refresh_git_credential_config] on adoption to keep the derived gitconfig
    in step with hosts.yml. *)
val docker_args_persistent :
  config:Workspace.config ->
  keeper_name:string ->
  container_masc_dir:string ->
  (string list, string) result

(** Rewrites the derived gitconfig inside the stable config directory from
    the hosts it currently holds. Pure function of hosts.yml; a no-op when
    the keeper is unconfigured. *)
val refresh_git_credential_config :
  config:Workspace.config -> keeper_name:string -> (bool, string) result

(** The stable config directory, when the keeper has one at all. Readers that
    only need "where would hosts.yml live" use this instead of provisioning
    with [ensure_config_dir]. *)
val existing_config_dir :
  config:Workspace.config -> keeper_name:string -> (string option, string) result

(** Docker counterpart of [runtime_env_for_tool]. Each dispatch receives an
    immutable read-only snapshot, including when the Keeper is unconfigured,
    plus an explicit cleanup capability. A host login that happens while a
    tool is running cannot change that tool's credential authority. Malformed
    state remains a typed error. *)
val docker_args_for_tool :
  config:Workspace.config ->
  keeper_name:string ->
  container_masc_dir:string ->
  (docker_tool_projection, string) result

val login_env : config:Workspace.config -> keeper_name:string -> (string array, string) result

val run_inherited : timeout_sec:float -> env:string array -> string list -> Unix.process_status
(** Run a subprocess with inherited stdio, bounded by [timeout_sec]. On
    timeout the child is SIGKILLed and reaped, and [Unix.WEXITED 124] is
    returned (matching the [with_unix_capture] convention). *)

val observe :
  config:Workspace.config -> keeper_name:string -> hostname:string -> (observation, string) result
(** [effective] verifies projected credentials with the host process only.
    [effective_probe_scope] prevents callers from presenting it as proof that a
    Docker image contains a usable CLI/network stack. *)

val observation_to_yojson : observation -> Yojson.Safe.t
val stream_login :
  config:Workspace.config ->
  keeper_name:string ->
  hostname:string ->
  env:string array ->
  is_closed:(unit -> bool) ->
  send_event:(string -> Yojson.Safe.t -> unit) ->
  (unit, string) result
(** Run interactive [gh auth login] with redacted streaming events. Closing
    the response cancels and reaps the child; a bounded timeout is also
    enforced. The caller must validate Keeper existence before invoking it. *)

val run_cli_login : config:Workspace.config -> keeper_name:string -> hostname:string -> int
val run_cli_status : config:Workspace.config -> keeper_name:string -> hostname:string -> int
val run_cli_logout : config:Workspace.config -> keeper_name:string -> hostname:string -> int
