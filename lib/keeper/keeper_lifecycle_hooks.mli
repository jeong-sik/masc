(** Keeper Lifecycle Cleanup Hooks (RFC-0036 Phase A.1).

    Foundation for the lifecycle_cleanup_hook plumbing described in
    [docs/rfc/RFC-0036-multi-keeper-docker-orchestration.md].

    Purely additive — this module has no consumers in [Keeper_supervisor]
    yet. Phase A.2/A.3 wires call sites; Phase B/C uses the same
    registration API to attach the [Docker_runtime] bridge.

    Contract:
    - Hooks are best-effort, synchronous, and exception-safe. The runner
      logs and swallows exceptions so a single misbehaving hook cannot
      block supervisor work or other hooks.
    - Hook registration is process-global. Order of execution is the
      order of registration. There is no unregister API by design — once
      a subsystem opts in, it stays in for the process lifetime.
    - Hook list is backed by [Atomic.t] for lock-free read on the
      supervisor hot path.

    Future extensions (Phase A.2+): structured event payload
    (subprocess pid set, owner keeper config) once call sites are wired. *)

(** Lifecycle event the hook is invoked with. *)
type event =
  | Phase_transition of {
      from_phase : Keeper_state_machine.phase;
      to_phase   : Keeper_state_machine.phase;
    }
      (** Fired by [Keeper_supervisor.transition_to] before the
          registry write commits. Hooks observe the intent of the
          transition; they cannot veto. *)
  | Tombstone_reaped
      (** Fired by [Keeper_supervisor.cleanup_dead_tombstone] after the
          registry unregister completes. The keeper is fully gone from
          in-process state at this point. *)

(** Hook callback. *)
type hook = keeper_id:string -> event -> unit

(** Register a cleanup hook. Idempotency is the caller's responsibility
    — calling twice with the same closure registers it twice. *)
val register : hook -> unit

(** Run every registered hook with the given event. Exceptions raised
    from a hook are caught and logged via [Log.Server.warn]; the runner
    always returns normally. *)
val run : keeper_id:string -> event -> unit

(** Number of currently registered hooks. Useful for tests. *)
val registered_count : unit -> int

(** Clear all registered hooks. Test-only escape hatch. Production
    code should never call this. *)
val reset_for_testing : unit -> unit
