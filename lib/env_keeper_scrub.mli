(** Keeper subprocess env scrub / pass policy (RFC-0007 PR-1 / #9639 Cluster B).

    Default-deny (allowlist) model: only explicitly permitted env vars cross
    the keeper subprocess boundary. New secrets are blocked by default, and
    credentials enter only through [Keeper_secret_projection].

    Keeper GitHub execution must use the selected MASC credential bundle,
    never the operator's ambient GitHub token/config or SSH agent. *)

val is_keeper_process_allowed : string -> bool
(** Whether a key may enter a local Keeper command environment. Docker daemon
    connectivity and arbitrary runtime-prefix variables are excluded. *)

val is_control_plane_allowed : string -> bool
(** Whether a key may enter a Docker control-plane subprocess. This adds the
    explicit Docker daemon connection variables to the Keeper-safe set. *)

val filter_keeper_environment : string array -> string array
(** Filter an environment for a local Keeper command. *)

val filter_control_plane_environment : string array -> string array
(** Filter an environment for Docker control-plane commands. *)

val filter_control_plane_environment_c_messages : string array -> string array
(** Like {!filter_control_plane_environment}, but pins system messages to the C locale:
    drops any host [LC_ALL] / [LC_MESSAGES] and appends [LC_ALL=] (empty,
    treated by POSIX as unset) and [LC_MESSAGES=C]. Character encoding
    ([LC_CTYPE] / [LANG]) is left to the host. Use for subprocesses whose
    textual output MASC classifies — e.g. the EINTR retry marker in
    [Keeper_turn_sandbox_runtime] depends on [strerror] being English. *)
