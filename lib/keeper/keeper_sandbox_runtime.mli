(** Keeper sandbox runtime preflight.

    Shared between [Keeper_exec_shell] (bash sandbox) and
    [Keeper_docker_read] (read sandbox). Both surfaces need to verify
    the host docker runtime satisfies the configured hardening
    constraints (seccomp profile present, optional rootless / userns
    enforcement) before launching any containerised work.

    Pure leaf module — no upward dependencies on other [Keeper_*]
    modules. *)

type required_command_check =
  {
    command : string;
    available : bool;
  }

type docker_preflight =
  {
    ok : bool;
    image : string;
    docker_runtime_ok : bool;
    docker_runtime_error : string option;
    hardening_ok : bool;
    hardening_error : string option;
    image_present : bool;
    image_error : string option;
    required_commands : required_command_check list;
    missing_commands : string list;
    next_actions : string list;
  }

val docker_preflight :
  timeout_sec:float -> unit -> docker_preflight option
(** Global keeper sandbox preflight used by [doctor], keeper startup,
    and diagnostics. Returns [None] when
    [MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED=false]. *)

val docker_preflight_to_yojson :
  docker_preflight -> Yojson.Safe.t

val docker_preflight_failure_message :
  docker_preflight -> string

val ensure_keeper_startup_preflight :
  timeout_sec:float ->
  sandbox_profile:Keeper_types.sandbox_profile ->
  (unit, string) result
(** Fail-fast keeper-up preflight for [sandbox_profile=docker]. *)

val ensure_keeper_sandbox_runtime :
  timeout_sec:float -> (string list, string) result
(** Returns the [--security-opt seccomp=...] argv fragment when the
    runtime passes; [Error _] when something is missing.

    The fragment is empty when the env config has no seccomp profile
    set; the caller should still concat it into the docker argv. *)
