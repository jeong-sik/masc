(** RFC-0070 Phase 3b-iv.2.3 — Real {!Docker_client.S}
    ([rm] + [exec] + [run] wired).

    Phase 3a's stub kept [Docker_client.S] as a *signature only*. Phase
    3b-iv.1b added [Docker_client_mock] for tests. Phase 3b-iv.2.0
    added the *production* skeleton. Phase 3b-iv.2.1 (#14844) wired
    [rm]; 3b-iv.2.2 (#14854) wired [exec]; 3b-iv.2.3 (this) wires
    [run]. Only [ps_query] remains a placeholder pending 3b-iv.2.4.

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.2

    Implementation status per function:
    - [rm] — wired: spawns [docker rm -f <name>] via
      [Process_eio.run_argv_with_status]. Exit-status mapping:
      {ul
        {- [WEXITED 0] → [Ok ()]}
        {- [WEXITED 127] (spawn failure: docker CLI missing or exec
           error) → [Error Daemon_unreachable]}
        {- any other [WEXITED n] → [Error Cleanup_failed]}
        {- [WSIGNALED _] / [WSTOPPED _] → [Error Daemon_unreachable]}}
      No [Unix.Unix_error] leak (Process_eio internalises spawn errors
      to [WEXITED 127]). [Eio.Cancel.Cancelled] still propagates to the
      caller by design — RFC-0070 requires cancellation to remain
      observable rather than being absorbed into a typed error.
    - [exec] — wired: spawns
      [docker exec <name> sh -lc <cmd>] via
      [Process_eio.run_argv_with_status_split]. The semantic
      distinction vs [rm] matters: a non-zero exit *inside the
      container* is the *command's* result, returned as
      [Ok exec_result { exit_code = n; stdout; stderr }] — not a
      daemon error. Only daemon-level statuses become
      [Error Daemon_unreachable]:
      {ul
        {- [WEXITED 125] (daemon error)}
        {- [WEXITED 127] (docker CLI missing / spawn failure)}
        {- [WSIGNALED _] / [WSTOPPED _]}}
      All other [WEXITED n] values surface as
      [Ok { exit_code = n; stdout; stderr }].
    - [run] — wired: spawns
      [docker run --rm --name <name> <image> sh -lc <cmd>] via
      [Process_eio.run_argv_with_status_split], passing
      [Keeper_sandbox_oneshot_plan.timeout_budget_sec] as the
      [?timeout_sec] parameter. Status mapping is the same as [exec]
      ({!Docker_response.exec_result} on container-command exit;
      [Error Daemon_unreachable] on daemon-level status). [--rm]
      flag removes the container after exit (RFC §3.1's interim
      default cleanup; a typed cleanup-policy field on
      {!Keeper_sandbox_oneshot_plan.t} is deferred to a follow-up RFC).
    - [ps_query] — still [Error Cleanup_failed] placeholder pending
      3b-iv.2.4 (JSON parser for
      [docker ps --format '\{\{json .\}\}']).

    **Why a placeholder skeleton and not [failwith]**: returning
    [Error Cleanup_failed] keeps the signature in {!result}; a caller
    that wires Real before Phase 3b-iv.2.{1,2,3,4} land will receive a
    typed failure they can pattern-match on, not an exception that
    surfaces as a crash. RFC-0070's "no silent failure, no exception
    leak" contract is preserved. *)

include Docker_client.S

(** [exec_argv ?user ?workdir ?stdin ~container ~cmd ()] is the pure
    [docker exec] argv builder used by {!exec}. Exposed for unit-testing
    the argv shape (option presence, [--user] before [-w] before [-i]
    ordering) without spawning a daemon.

    [?stdin] is a [bool], not the content — the *content* is never part
    of the argv (it is piped on stdin at spawn time by {!exec}); the
    pure builder only needs to know whether to emit [-i]. Defaults to
    [false]. Trailing [unit] for the same optional-erasure reason as
    {!exec}. *)
val exec_argv
  :  ?user:int * int
  -> ?workdir:string
  -> ?stdin:bool
  -> container:Keeper_container_name.t
  -> cmd:string
  -> unit
  -> string list

(** [parse_security_options raw] is the pure parser behind
    {!info_security_options}: it interprets the stdout of
    [docker info --format '\{\{json .SecurityOptions\}\}'] — a JSON
    array of strings (or [null] / [] for none), lowercased; non-string
    elements dropped; anything else ⇒ [Probe_format_drift]. Exposed
    so the parse is unit-testable without a daemon. *)
val parse_security_options
  :  string
  -> (string list, Docker_client.sandbox_error) result

(** [run_detached_argv plan ~seccomp_args ~owner_pid ~started_at] is
    the pure [docker run -d ...] argv builder behind {!run_detached}:
    it assembles the argv from [plan] plus the spawn-time bits the plan
    omits (resolved seccomp args, owner PID, started-at clock). Exposed
    so the argv shape is unit-testable without writing files / probing
    a daemon / reading the clock. *)
val run_detached_argv
  :  Keeper_sandbox_session_plan.t
  -> seccomp_args:string list
  -> owner_pid:int
  -> started_at:float
  -> string list

(** [is_eintr_127 status out] is the EINTR-retry predicate behind the
    gated-spawn helpers (RFC-0070 Phase 4.1-g): a spawn that exited
    [WEXITED 127] *and* whose combined stdout/stderr mentions
    "interrupted system call" (case-insensitive) is a transient EINTR
    on [fork]/[exec], not a missing docker CLI — so it is retried (up
    to 8×) instead of being mapped straight to [Daemon_unreachable].
    Any other status, or [WEXITED 127] without that marker, is [false].
    Pure; exposed for unit-testing the predicate without a daemon.
    Mirrors [keeper_turn_sandbox_runtime]'s long-standing EINTR loop
    (the Phase 4.1 cutover deletes that copy in favour of this one). *)
val is_eintr_127 : Unix.process_status -> string -> bool

(** [is_exec_gate_blocked status out] detects the Exec_gate deny/ask
    sentinel. The real Docker client maps that host-side gate result to
    [Daemon_unreachable] rather than treating exit 126 as an
    in-container command result. *)
val is_exec_gate_blocked : Unix.process_status -> string -> bool

(** Timeout used by short Docker daemon probes such as [rm],
    [image_present], and [info_security_options]. *)
val docker_probe_timeout_sec : unit -> float

(** Timeout used by [exec] session commands. Preserves the 60s shell
    command budget instead of the short sandbox-preflight budget. *)
val session_exec_timeout_sec : unit -> float

(** Timeout used by the actual [docker run -d] session start. *)
val session_start_timeout_sec : unit -> float

(** Timeout used by the short seccomp/runtime preflight before detached
    session start. *)
val session_preflight_timeout_sec : unit -> float
