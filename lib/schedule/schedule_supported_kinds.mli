(** Supported schedule payload kinds — single source of truth.

    This neutral module is the contract surface between the schedule creation
    tool layer ({!Tool_schedule}) and the production consumer
    ({!Server_schedule_consumers}); see {!Schedule_supported_kinds} for the
    full design rationale. Neither layer reaches across the
    [lib/tool] <-> [lib/server] boundary. *)

val keeper_wake : string

val lane_act : string
(** One action for a declared Lane Add-on installation's live worker. *)

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

(** How a due [masc.keeper_wake] reaches its Keeper. *)
type keeper_wake_delivery =
  | Keeper_wake_to_queue
      (** A new message in the Keeper's event queue. *)
  | Keeper_wake_to_receipt
      (** A tool-result receipt whose [call_id] is the schedule id. A turn that
          ended on [keeper_receipt_wait] for that id continues with it. No wake message is put in the event queue; the outbox delivers
          the receipt. *)

val default_keeper_wake_delivery : keeper_wake_delivery
(** [Keeper_wake_to_queue], for a body without the optional [delivery] field. *)

val keeper_wake_delivery_of_string : string -> (keeper_wake_delivery, string) result
(** Wire enum of the [delivery] field: [queue] or [receipt]. *)

val valid_keeper_wake_target_name : string -> bool
(** [true] when a [masc.keeper_wake] body target name is valid. *)

val keeper_wake_target_name_error : field:string -> string
(** Canonical field-level validation message for target name failures. *)
