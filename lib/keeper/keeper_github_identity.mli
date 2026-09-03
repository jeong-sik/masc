(** Keeper-scoped GitHub CLI identity.

    GitHub CLI state is stored outside the generic Keeper secret projection.
    Token environment variables remain owned by [Keeper_secret_projection]. *)

type auth_result =
  { authenticated : bool
  ; login : string option
  ; error : string option
  }

type effective_probe_scope =
  [ `Host_process_credential_only
  | `Endpoint_process_only
  ]
(** Which machine's [gh] answered the [effective] probe.

    [`Host_process_credential_only]: the server ran the probe as its own
    process, with the Keeper's projected token environment. It reports this
    host and says nothing about what a container image or a guest holds.

    [`Endpoint_process_only]: the probe ran on the Keeper's remote endpoint
    through the exec lane. It reports that endpoint's [gh] and says nothing
    about this host. No token environment is projected onto an endpoint, so
    an observation carrying this scope has [stored] and [effective] equal and
    [projected_token_env_names] empty. *)

type observation =
  { keeper : string
  ; hostname : string
  ; config_dir : string
  ; projected_token_env_names : string list
  ; stored : auth_result
  ; effective : auth_result
  ; effective_probe_scope : effective_probe_scope
  ; checked_at_unix : float
  }

type login_lane =
  { run_login :
      on_stdout_chunk:(string -> unit)
      -> on_stderr_chunk:(string -> unit)
      -> Unix.process_status * string * string
  ; secure_after_login : unit -> (unit, string) result
  ; observe_after_login : unit -> (observation, string) result
  }
(** Where one device-flow login runs, and where its result is then read.

    {!stream_login} owns the parts that do not vary — event framing, secret
    redaction, cancellation when the response closes, the timeout — and calls
    these three in order: [run_login], then on exit 0 [secure_after_login],
    then [observe_after_login]. [run_login] writes each output chunk as it
    arrives, which is what carries the one-time code to the operator before
    the process ends. A lane whose three functions reached different machines
    would report one machine's login as another's, so each lane keeps all
    three on the machine the login was written to. *)

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

val login_timeout_sec : float
(** Wall-clock ceiling for one device-flow login, in seconds. The browser half
    of the flow is a person's, so this bounds a person rather than a program. *)

val login_argv : hostname:string -> string list
(** The [gh auth login] argv every lane runs. It names no config directory:
    the lane places [GH_CONFIG_DIR] in the environment its own machine sees.
    It allocates no terminal and asks for none, so [gh] writes the one-time
    code and the verification URL as plain lines on its own output instead of
    rendering an interactive prompt. *)

val auth_probe_argv : hostname:string -> string list
(** The argv whose stdout is the login name the identity resolves to on
    [hostname], and whose non-zero exit is the absence of one. *)

val auth_result_of_probe
  :  base_path:string
  -> keeper_name:string
  -> Unix.process_status * string * string
  -> auth_result
(** Read one {!auth_probe_argv} run as an [auth_result], redacting the
    Keeper's known secrets out of the failure detail first. Exposed so a lane
    that runs the probe somewhere other than this host reads its outcome by
    the same rule rather than by a second one. *)

val local_lane
  :  config:Workspace.config
  -> keeper_name:string
  -> hostname:string
  -> (login_lane, string) result
(** The lane for a Keeper whose GitHub directory is this host's: the login
    runs here against [<base>/.masc/keepers/<name>/github-cli], and both the
    permission fix-up and the observation read that same directory. Docker and
    Micro_vm mount that directory, so their logins belong here too. *)

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
  lane:login_lane ->
  is_closed:(unit -> bool) ->
  send_event:(string -> Yojson.Safe.t -> unit) ->
  (unit, string) result
(** Run one device-flow login on [lane] and report it as redacted streaming
    events: an [output] event per chunk, then either [complete] carrying the
    lane's observation or [error] carrying the failure. Closing the response
    cancels and reaps the process; a bounded timeout is also enforced. The
    caller must validate Keeper existence, and must pick the lane, before
    invoking it. *)

val run_cli_login : lane:login_lane -> int
(** Run one login on [lane], writing each output chunk to this process's
    stdout as it arrives, then print the lane's observation as JSON. Answers
    0 only when the login exited 0 and the observation could be read. *)
val run_cli_status : config:Workspace.config -> keeper_name:string -> hostname:string -> int
val run_cli_logout : config:Workspace.config -> keeper_name:string -> hostname:string -> int
