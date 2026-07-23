(** Issue #8575: SSOT for the [event] string emitted by
    {!Keeper_event_publisher.publish_keeper_lifecycle}.

    The supervisor, keepalive, and durable dashboard cleanup boundary emit
    thirteen distinct event names through that function. The docstring on
    [Keeper_event_publisher.publish_keeper_lifecycle] previously listed only five
    of them, so operators reading the doc subscribed to the
    phase-derived events ([started] / [stopped] / [crashed] /
    [restarted] / [dead]) and silently missed the cleanup /
    recovery events ([reconciled] / [dead_cleaned] /
    [admission_denied]) — exactly
    the events that signal supervisor recovery actions where
    observability matters most.

    This module pins the vocabulary in one place. The custom-event
    Variant covers verbs that do not map 1:1 to a phase; the
    phase-derived event names come from
    {!Keeper_state_machine.phase_to_string} on the four lifecycle
    phases that fire a wire event ([Stopped] / [Crashed] / [Dead] /
    [Running]).

    NOTE (#22071): a previously-cited emit-site coverage test
    ([test/test_types.ml :: lifecycle_events_ssot]) does not exist —
    keep this vocabulary aligned with the supervisor/keepalive call
    sites by hand. The [to_string]/[event_of_string] round-trip is
    pinned by [test/test_dashboard_http_core.ml ::
    lifecycle_event_of_string_roundtrip]. *)

(** Custom (non-phase-derived) keeper lifecycle events. Each verb
    captures an action distinct from a phase noun:

    - [Started]            : keeper began executing (Running phase as side-effect)
    - [Reconciled]         : durable keeper re-picked up after restart
    - [Restarted]          : supervisor relaunched a crashed lane
    - [Dead_cleaned]       : explicit durable tombstone cleanup
    - [Purged]             : dashboard purge completed all durable artifacts
    - [Admission_denied]   : spawn/admission guard refused to launch a keeper *)
type t =
  | Started
  | Reconciled
  | Restarted
  | Dead_cleaned
  | Purged
  | Admission_denied

let to_string = function
  | Started -> "started"
  | Reconciled -> "reconciled"
  | Restarted -> "restarted"
  | Dead_cleaned -> "dead_cleaned"
  | Purged -> "purged"
  | Admission_denied -> "admission_denied"

(* Inverse of [to_string] over the closed custom-event sum. Strings outside the
   vocabulary (phase-derived names, legacy/operator strings, garbage) map to
   [None] so callers parse-then-exhaustive-match instead of reverse-classifying
   the variant by raw string literals. The round-trip is pinned by
   [test/test_dashboard_http_core.ml :: lifecycle_event_of_string_roundtrip]. *)
let event_of_string = function
  | "started" -> Some Started
  | "reconciled" -> Some Reconciled
  | "restarted" -> Some Restarted
  | "dead_cleaned" -> Some Dead_cleaned
  | "purged" -> Some Purged
  | "admission_denied" -> Some Admission_denied
  | _ -> None

let all_custom_events : t list =
  [ Started; Reconciled; Restarted; Dead_cleaned; Purged; Admission_denied ]

let valid_custom_event_strings : string list =
  List.map to_string all_custom_events

(** Phase-derived event names. These mirror the wire format of
    {!Keeper_state_machine.phase_to_string} for the four lifecycle
    phases that publish a lifecycle event. The list is hand-rolled
    rather than generated to keep this module dependency-free
    (Keeper_state_machine pulls in the full FSM module). Keep aligned
    with [Keeper_state_machine.phase_to_string] by hand — the formerly
    cited sync test ([test/test_types.ml]) does not exist (#22071). *)
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
    landed on the bus as a garbage event name. (A runtime SSOT test in
    [test_types.ml :: lifecycle_events_ssot] was cited here but does
    not exist — #22071.)

    This sum type unifies the two pre-existing typed vocabularies
    ([t] for the custom verbs, [Keeper_state_machine.phase] for the
    4 phase-derived names) so the wire string is computed inside
    [Keeper_event_publisher.publish_keeper_lifecycle] from a fully-typed argument.
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
