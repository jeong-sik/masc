(** Issue #8575: SSOT for the [event] string emitted by
    {!Oas_events.publish_keeper_lifecycle}.

    The supervisor and keepalive together emit ten distinct event
    names through that function. The docstring on
    [Oas_events.publish_keeper_lifecycle] previously listed only five
    of them, so operators reading the doc subscribed to the
    phase-derived events ([started] / [stopped] / [crashed] /
    [restarted] / [dead]) and silently missed the cleanup /
    self-healing events ([reconciled] / [dead_cleaned] /
    [self_preservation] / [paused_pruned]) — exactly the events that
    signal supervisor recovery actions where observability matters
    most.

    This module pins the vocabulary in one place. The custom-event
    Variant covers verbs that do not map 1:1 to a phase; the
    phase-derived event names come from
    {!Keeper_state_machine.phase_to_string} on the four lifecycle
    phases that fire a wire event ([Stopped] / [Crashed] / [Dead] /
    [Running]).

    The sync test in [test/test_types.ml :: lifecycle_events_ssot]
    asserts every literal event name still emitted by the supervisor
    and keepalive lives in [all_event_names], so adding a new event
    site without updating the SSOT fails CI. *)

(** Custom (non-phase-derived) keeper lifecycle events. Each verb
    captures an action distinct from a phase noun:

    - [Started]            : keeper began executing (Running phase as side-effect)
    - [Reconciled]         : durable keeper re-picked up after restart
    - [Restarted]          : supervisor relaunched after crash within budget
    - [Dead_cleaned]       : tombstone cleanup after restart budget exhaustion
    - [Self_preservation]  : supervisor refused a cascade-wide action to protect itself
    - [Paused_pruned]      : paused keeper removed from registry after timeout *)
type t =
  | Started
  | Reconciled
  | Restarted
  | Dead_cleaned
  | Self_preservation
  | Paused_pruned

let to_string = function
  | Started -> "started"
  | Reconciled -> "reconciled"
  | Restarted -> "restarted"
  | Dead_cleaned -> "dead_cleaned"
  | Self_preservation -> "self_preservation"
  | Paused_pruned -> "paused_pruned"

let all_custom_events : t list =
  [ Started; Reconciled; Restarted; Dead_cleaned;
    Self_preservation; Paused_pruned ]

let valid_custom_event_strings : string list =
  List.map to_string all_custom_events

(** Phase-derived event names. These mirror the wire format of
    {!Keeper_state_machine.phase_to_string} for the four lifecycle
    phases that publish a lifecycle event. The list is hand-rolled
    rather than generated to keep this module dependency-free
    (Keeper_state_machine pulls in the full FSM module); the sync
    test in [test/test_types.ml] asserts the strings stay aligned
    with [Keeper_state_machine.phase_to_string]. *)
let phase_derived_event_strings : string list =
  [ "stopped"; "crashed"; "dead"; "running" ]

(** Combined vocabulary — every event name [publish_keeper_lifecycle]
    can carry. Subscribe to all of these to avoid silently missing
    half the lifecycle stream. *)
let all_event_names : string list =
  valid_custom_event_strings @ phase_derived_event_strings
