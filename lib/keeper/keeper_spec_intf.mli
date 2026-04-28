(** First-class module type that mirrors a TLA+ state machine in OCaml.

    A spec module that satisfies [TLA_STATE_MACHINE] makes the link
    between a TLA+ module (e.g. [specs/keeper-state-machine/KeeperTurnFSM.tla])
    and an OCaml module enforceable by the type system rather than
    by convention.

    Cycle 10 / Tier I2 of the Kimi keeper FSM review plan. This is the
    interface-only landing — concrete instantiation
    (e.g. [Keeper_turn_fsm_spec : TLA_STATE_MACHINE]) is deferred so the
    interface lands additively first. Future cycles can wire existing
    keeper FSMs to the signature without touching its shape.

    Mapping convention:
    - {!type:state}     ↔ TLA+ state-set element (e.g. [TurnState]).
    - {!type:action}    ↔ TLA+ Next-action label (e.g. [Submit], [Resolve]).
    - {!type:variables} ↔ TLA+ tuple of [VARIABLES] (the full evaluation
                          context). Distinguished from [state] so that
                          actions which read auxiliary counters can be
                          modelled honestly.
    - {!val:initial}    ↔ TLA+ [Init] predicate, returned as a witness.
    - {!val:next}       ↔ TLA+ [Next] step. [None] models the case where
                          the action's enablement guard is not satisfied;
                          [Some v'] is the post-state. This makes the
                          action-enablement asymmetry explicit instead of
                          collapsing it into a permissive default.
    - {!val:invariant}  ↔ TLA+ [TypeOK] (or any state predicate intended
                          as an INVARIANT). Returns [bool] so callers can
                          assert it after every transition in tests.

    Bug-Model contract (CLAUDE.md software-development.md):
    A spec module that wires its TLA+ counterpart through this signature
    must, in its own .mli, state both the clean and the buggy cfg paths
    so [scripts/ci/check-tla-harness-coverage.sh] can verify that both
    are model-checked. *)

module type TLA_STATE_MACHINE = sig
  type state
  type action
  type variables

  val initial : variables
  (** TLA+ [Init] predicate as a constructive witness. *)

  val next : variables -> action -> variables option
  (** [next v a] returns [Some v'] iff the TLA+ action [a] is enabled
      in [v] and would step to [v']; [None] iff the enablement guard is
      not satisfied. The [option] is load-bearing: collapsing it into
      a permissive default (e.g. returning [v] unchanged) is the
      Unknown→Permissive anti-pattern documented in
      [memory/feedback_keeper_runtime_fail_closed_for_unknown_permissive_default.md]. *)

  val invariant : variables -> bool
  (** TLA+ [TypeOK] (or any chosen INVARIANT). Used by tests to assert
      that every reachable state through {!val:next} satisfies the
      predicate, mirroring the TLC invariant check. *)
end
