(** Supported schedule payload kinds — single source of truth.

    This neutral module is the contract surface between the schedule creation
    tool layer ({!Tool_schedule}) and the production consumer
    ({!Server_schedule_consumers}); see {!Schedule_supported_kinds} for the
    full design rationale. Neither layer reaches across the
    [lib/tool] <-> [lib/server] boundary. *)

val keeper_wake : string

val unsupported_error : string -> string
(** Error message for a payload kind outside [supported]. *)

type keeper_wake_urgency =
  | Keeper_wake_immediate
  | Keeper_wake_normal
  | Keeper_wake_low

val default_keeper_wake_urgency : keeper_wake_urgency
(** Schema-v1 default urgency for [masc.keeper_wake] when the optional
    [urgency] field is absent. *)

val keeper_wake_urgency_of_string : string -> (keeper_wake_urgency, string) result
(** Neutral wire enum for [masc.keeper_wake] urgency. Tool-side validation uses
    this schedule-owned contract; keeper-side consumers map it to
    [Keeper_event_queue.urgency] at the boundary. *)

val valid_keeper_wake_target_name : string -> bool
(** [true] when a [masc.keeper_wake] body target name is valid. *)

val keeper_wake_target_name_error : field:string -> string
(** Canonical field-level validation message for target name failures. *)
