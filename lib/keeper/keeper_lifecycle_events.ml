(** Issue #8575: SSOT for the [event] string emitted by
    {!Cascade_events.publish_keeper_lifecycle}.

    The supervisor and keepalive together emit eleven distinct event
    names through that function. The docstring on
    [Cascade_events.publish_keeper_lifecycle] previously listed only five
    of them, so operators reading the doc subscribed to the
    phase-derived events ([started] / [stopped] / [crashed] /
    [restarted] / [dead]) and silently missed the cleanup /
    self-healing events ([reconciled] / [dead_cleaned] /
    [self_preservation] / [paused_pruned] / [auto_resumed]) — exactly
    the events that signal supervisor recovery actions where
    observability matters most.

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
    - [Paused_pruned]      : paused keeper removed from registry after timeout
    - [Auto_resumed]       : supervisor auto-resumed a keeper after circuit-breaker back-off *)
type t =
  | Started
  | Reconciled
  | Restarted
  | Dead_cleaned
  | Self_preservation
  | Paused_pruned
  | Auto_resumed

let to_string = function
  | Started -> "started"
  | Reconciled -> "reconciled"
  | Restarted -> "restarted"
  | Dead_cleaned -> "dead_cleaned"
  | Self_preservation -> "self_preservation"
  | Paused_pruned -> "paused_pruned"
  | Auto_resumed -> "auto_resumed"

let all_custom_events : t list =
  [ Started; Reconciled; Restarted; Dead_cleaned;
    Self_preservation; Paused_pruned; Auto_resumed ]

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

(** {1 Unified lifecycle event sum type (#8856 / #8605 family)}

    [publish_keeper_lifecycle] previously took [event:string ?phase] --
    a typo at any of the supervisor/keepalive call sites silently
    landed on the bus as a garbage event name. The runtime SSOT test
    in [test_types.ml :: lifecycle_events_ssot] caught drift at CI
    time but not at compile time.

    This sum type unifies the two pre-existing typed vocabularies
    ([t] for the 6 custom verbs, [Keeper_state_machine.phase] for the
    4 phase-derived names) so the wire string is computed inside
    [Cascade_events.publish_keeper_lifecycle] from a fully-typed argument.
    A typo at the call site is now a build error.

    Note: importing [Keeper_state_machine] here breaks the
    "dependency-free" claim in the module-level docstring above. The
    trade-off is intentional -- the type-level coupling is essentially
    free (no runtime FSM behaviour pulled in) and gives compile-time
    typo elimination for the entire wire vocabulary. *)
(* The legacy [?phase:_ ~event:_] surface allowed a Custom verb to
   carry a phase context (e.g. ~event:"started" ~phase:Running emits
   event="started" phase="running" on the wire). The [Custom_event]
   constructor preserves this; [Phase_event] is the case where the
   wire event name IS the phase. The two cases produce different JSON
   payloads (Phase_event emits the phase string in BOTH "event" and
   "phase" fields; Custom_event emits the verb in "event" and the
   optional phase in "phase"). *)
type lifecycle_event =
  | Custom_event of { verb : t; phase : Keeper_state_machine.phase option }
  | Phase_event of Keeper_state_machine.phase

let lifecycle_event_to_string = function
  | Custom_event { verb; _ } -> to_string verb
  | Phase_event p -> Keeper_state_machine.phase_to_string p

let lifecycle_event_phase = function
  | Custom_event { phase; _ } -> phase
  | Phase_event p -> Some p
