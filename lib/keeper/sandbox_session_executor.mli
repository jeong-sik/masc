(** RFC-0070 Phase 3e (f) — Sandbox_session_executor.

    Functor on {!Docker_client.S}, sibling of {!Sandbox_executor}.
    Where {!Sandbox_executor} runs one {!Keeper_sandbox_oneshot_plan.t}
    through [D.run], this orchestrates *one container's lifetime* from a
    {!Keeper_sandbox_session_plan.t}: [start] (→ [D.run_detached]) →
    [exec] (→ [D.exec], any number of times) → [cleanup] (→ [D.rm]).
    Covers [keeper_turn_sandbox_runtime]'s persistent-session container
    (the Phase 4.1 cutover target).

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.2.3

    This functor stays a *thin* orchestrator — all I/O and
    non-determinism live in [D] ({!Docker_client.S}, the edge): the
    {!Keeper_sandbox_session_plan} is the pure spec, [D.run_detached]
    materialises it (writing the plan's [identity_files], the seccomp
    daemon probe, the [owner_pid] / [started_at] labels, the
    [docker_command_argv ()] prefix, the spawn), and this functor only
    wires [start] → [exec]* → [cleanup]. Both {!Docker_client_mock} and
    [Docker_client_real] satisfy [S], so [Make(Mock)] and [Make(Real)]
    are interchangeable at the call site.

    Determinism contract: same {!Keeper_sandbox_session_plan.t} ⇒ same
    spawn argv (modulo the two spawn-time labels and the resolved
    seccomp path the edge adds) ⇒ same {!Keeper_container_name.t}. The
    session handle {!t} is opaque — it carries runtime / started-at
    state callers must not branch on; only {!container_name} is
    observable. *)

module Make : functor (D : Docker_client.S) -> sig
  (** Opaque session handle. Wraps the {!Keeper_container_name.t} the
      container was started under plus the originating
      {!Keeper_sandbox_session_plan.t} (so {!exec} can thread the
      plan's [user] / [workdir] without the caller re-supplying them).
      Constructed only by {!start}. *)
  type t

  (** [start plan] spawns the session container via [D.run_detached
      plan] and wraps the returned name into a session handle. The
      [Real] [run_detached] performs the edge work the pure
      {!Keeper_sandbox_session_plan} factored out (see the module doc).
      The [Mock] returns [Ok plan.container_name] with no daemon
      (deterministic). A start failure surfaces as the typed
      {!Docker_client.sandbox_error} that [D.run_detached] returned —
      never an exception, never a silent [None]. *)
  val start
    :  Keeper_sandbox_session_plan.t
    -> (t, Docker_client.sandbox_error) result

  (** [exec t ~cmd] runs [cmd] inside the started container via
      [D.exec], threading the originating plan's [user] / [workdir]
      through as [D.exec]'s [?user] / [?workdir] (Phase 3e (b),
      #14947) so the command runs as the same uid:gid / cwd the
      container was created with. A non-zero exit *inside the
      container* is the command's result ([Ok { exit_code = n; ... }])
      — not an error of this layer; only a daemon-level failure becomes
      [Error Docker_client.Daemon_unreachable]. *)
  val exec
    :  t
    -> cmd:string
    -> (Docker_response.exec_result, Docker_client.sandbox_error) result

  (** [cleanup t] removes the container via [D.rm]. Calling it on an
      already-removed container is the daemon's concern, surfaced as
      whatever {!Docker_client.sandbox_error} [D.rm] maps that to
      (typically [Cleanup_failed]); this layer keeps no idempotence
      bookkeeping of its own. *)
  val cleanup : t -> (unit, Docker_client.sandbox_error) result

  (** [container_name t] is the {!Keeper_container_name.t} the
      container was started under — observable for probe / inspect from
      the caller's POV. Equals
      [Keeper_sandbox_session_plan.container_name] of the plan passed
      to {!start} (the [run_detached] contract: the name is the plan's,
      no [docker inspect] round-trip); exposing it here saves the
      caller from retaining the plan. *)
  val container_name : t -> Keeper_container_name.t
end
