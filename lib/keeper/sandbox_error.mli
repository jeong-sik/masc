(** Typed errors for Docker sandbox daemon operations.

    Implements RFC-0070 §2 G2:
    "every docker daemon call returns [(_, sandbox_error) result] where
     [sandbox_error] is a closed sum
     ([Daemon_unreachable | Image_pull_failed | Container_oom |
       Exec_timeout | Probe_format_drift | Cleanup_failed |
       Image_not_found]). No catch-all."

    The previous implementation collapsed all of these into
    [Tool_result.Runtime_failure] via substring classification on the
    dispatch error string. That allowed [Exec_timeout],
    [Daemon_unreachable], and OCI mount failures to be miscounted as
    [sandbox_image_missing] when their messages happened to share
    tokens — exactly the [classify_from_dispatch_failure] substring
    match collapse documented in the Phase 4.1 prep audit
    (2026-05-12, iter 34 of cron 7493fe21).

    This module defines the closed sum so downstream callers
    ([keeper_docker_read], [keeper_sandbox_runtime],
    [keeper_turn_sandbox_runtime]) can be migrated incrementally to
    [(_, sandbox_error) result] without re-parsing strings. Producer-
    and consumer-side migration is tracked under RFC-0070 Phase 4.1
    and is intentionally out of scope for this introduction PR.

    Each constructor carries the smallest payload that preserves the
    diagnostic signal callers used to recover from the dispatch error
    string. [Image_not_found] is the [docker image inspect] "no such
    image" case (Phase 3e), distinct from [Image_pull_failed] which is
    a pull that was attempted and failed. *)

type t =
  | Daemon_unreachable of { message : string }
      (** Docker daemon connection failure, socket unavailable, or
          [docker version] probe timed out at the dispatch boundary. *)
  | Image_pull_failed of { image : string; message : string }
      (** [docker pull <image>] was attempted and returned a non-zero
          exit / network error / registry rejection. *)
  | Container_oom of { container_id : string }
      (** Container terminated by the kernel OOM-killer. Captured
          from the [State.OOMKilled = true] probe field; the dispatch
          error string is not load-bearing here. *)
  | Exec_timeout of { container_id : string; budget_sec : float }
      (** [docker exec] (or per-OAS-call ceiling) exceeded its budget.
          Distinct from [Daemon_unreachable] — the daemon answered
          promptly, the workload itself ran past the budget. *)
  | Probe_format_drift of { command : string; raw : string }
      (** [docker ps --format ...] / [docker image inspect] produced
          output that does not match the typed yojson schema. Signals
          a Docker version mismatch or upstream format change. *)
  | Cleanup_failed of { container_id : string; message : string }
      (** [docker rm] / [docker stop] returned an error during the
          [Sandbox_cleanup.cleanup_tick] pass. Feeds the
          [cleanup_outcome] state machine (RFC-0070 §2 G4), not the
          dispatch error string. *)
  | Image_not_found of { image : string }
      (** [docker image inspect <image>] returned "no such image".
          Phase 3e addition (2026-05-12 v2.3 amendment) — distinct
          from [Image_pull_failed] so the dashboard can stop counting
          inspect-timeouts as image-missing. *)

val to_string : t -> string
(** Canonical lowercase tag — used by dashboards / log emitters when
    the typed value crosses a string boundary. Constructors are
    enumerated explicitly so adding a new case fails to compile here
    until handled. *)
