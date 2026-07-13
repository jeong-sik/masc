(** Supported schedule payload kinds — single source of truth.

    This neutral module is the contract surface between the schedule creation
    tool layer ({!Tool_schedule}) and the production consumer
    ({!Server_schedule_consumers}); see {!Schedule_supported_kinds} for the
    full design rationale. Neither layer reaches across the
    [lib/tool] <-> [lib/server] boundary. *)

val board_post : string
val keeper_wake : string

val supported : string list
(** Dispatchable payload kinds the production consumer can run.
    This is the consumer's dispatch set and the allow-list in
    {!unsupported_error}. Note: the creation validator does NOT grant
    acceptance from this list alone — each kind carries its own objective
    payload schema contract enforced by a per-kind branch in
    [Tool_schedule.validate_known_payload_request]. So adding a
    kind requires BOTH an entry here (consumer dispatch + reject message) AND a
    validator branch (creation acceptance); the list alone leaves it rejected at
    creation as an unsupported kind. *)

val supported_list_string : unit -> string

val unsupported_error : string -> string
(** Error message for a payload kind outside {!supported}. *)

type keeper_wake_urgency =
  | Keeper_wake_immediate
  | Keeper_wake_normal
  | Keeper_wake_low

val default_keeper_wake_urgency : keeper_wake_urgency
(** Schema-v1 default urgency for [masc.keeper_wake] when the optional
    [urgency] field is absent. *)

val keeper_wake_urgency_to_string : keeper_wake_urgency -> string

val keeper_wake_urgency_of_string : string -> (keeper_wake_urgency, string) result
(** Neutral wire enum for [masc.keeper_wake] urgency. Tool-side validation uses
    this schedule-owned contract; keeper-side consumers map it to
    [Keeper_event_queue.urgency] at the boundary. *)

val keeper_wake_target_name_pattern : string
(** Accepted name grammar for [masc.keeper_wake] body targets. *)

val valid_keeper_wake_target_name : string -> bool
(** [true] when a [masc.keeper_wake] body target name is valid. *)

val keeper_wake_target_name_error : field:string -> string
(** Canonical field-level validation message for target name failures. *)
