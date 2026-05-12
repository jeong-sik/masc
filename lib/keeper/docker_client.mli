(** RFC-0070 Phase 3b-iv.1a — Docker daemon client (signature, concrete).

    Phase 3a stub kept the four payload types abstract; Phase 3b-iv.1a
    closes them to the concrete shared types now that
    {!Keeper_sandbox_oneshot_plan}, {!Keeper_container_name}, and
    {!Docker_response} are on main. With the signature concrete, the
    upcoming [Mock] and [Real] implementations are *interchangeable*
    at any call site that takes [(module Docker_client.S)].

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.2, §3.3

    Non-determinism contract: every function in {!S} is at the
    process boundary (docker daemon, network, host clock). All such
    calls return [result] with the typed {!sandbox_error}. No
    catch-all silent failure. *)

(** {1 Errors} *)

(** Closed sum — every docker daemon call returns one of these on
    failure. The reader is forced to handle each by exhaustive match.

    Phase 3b may refine arms with concrete payload fields (image
    digest, container name, exit code). Phase 3a kept the variant
    skeleton minimal; Phase 3b-iv.1a preserves that minimum until a
    caller surfaces an actual payload need. *)
type sandbox_error =
  | Daemon_unreachable
  | Image_pull_failed
  | Container_oom
  | Exec_timeout
  | Probe_format_drift
  | Cleanup_failed

(** {1 Client interface} *)

(** Sandbox executor client. [Real] (Phase 3b-iv.2) spawns docker via
    [Eio.Process]; [Mock] (Phase 3b-iv.1b) feeds injected responses
    for property-seeded replay tests. Both satisfy {!S} so callers
    parameterising on [(module S)] swap them without conditional
    branches. *)
module type S = sig
  val run
    :  Keeper_sandbox_oneshot_plan.t
    -> (Docker_response.exec_result, sandbox_error) result

  val exec
    :  ?user:int * int
    -> ?workdir:string
    -> container:Keeper_container_name.t
    -> cmd:string
    -> unit
    -> (Docker_response.exec_result, sandbox_error) result
  (** [exec ?user ?workdir ~container ~cmd ()] runs [cmd] inside an
      already-running [container] via [docker exec].

      - [?user] — [(uid, gid)], emitted as [--user uid:gid]. Omitted
        ⇒ docker uses the container image's [USER].
      - [?workdir] — emitted as [-w workdir]. Omitted ⇒ docker uses
        the container's [WORKDIR].

      The trailing [unit] is required so OCaml can erase the leading
      optionals (warning 16) — all parameters are otherwise labeled.

      A non-zero exit *inside the container* is the command's result
      ([Ok { exit_code = n; ... }]), not a daemon error; only
      daemon-level statuses become [Error Daemon_unreachable]. *)

  val ps_query
    :  labels:(string * string) list
    -> (Docker_response.ps_record list, sandbox_error) result

  val rm : Keeper_container_name.t -> (unit, sandbox_error) result

  val info_security_options : unit -> (string list, sandbox_error) result
  (** [info_security_options ()] = the docker daemon's [SecurityOptions]
      list (from [docker info --format '\{\{json .SecurityOptions\}\}']),
      lowercased so callers can match tokens like ["seccomp"] /
      ["apparmor"] / ["no-new-privileges"] case-insensitively.

      [Ok []] when the daemon reports none ([null] / empty array).
      A daemon-level failure (not running, permission denied, CLI
      missing) ⇒ [Error Daemon_unreachable]. A payload that is neither
      a JSON array nor [null], or that fails to parse — i.e. a docker
      output-format change — ⇒ [Error Probe_format_drift] rather than
      a silent [Ok []]. *)
end
