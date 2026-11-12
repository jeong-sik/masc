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
      (** A tool-result receipt whose [call_id] is the schedule's {!receipt_key}.
          A turn that ended on [keeper_receipt_wait] for the schedule continues
          with it. No wake message is put in the event queue; the outbox
          delivers the receipt. *)

val default_keeper_wake_delivery : keeper_wake_delivery
(** [Keeper_wake_to_queue], for a body without the optional [delivery] field. *)

val keeper_wake_delivery_of_string : string -> (keeper_wake_delivery, string) result
(** Wire enum of the [delivery] field: [queue] or [receipt]. *)

type receipt_key = private string
(** The name of one receipt-delivering schedule, held in the row's body as
    [receipt_key]. It is the receipt's [call_id], and a wait for the schedule is
    recorded under it. The schedule id cannot play that part: a Keeper may pick
    it, so it can equal an Execute request id, or name a second schedule created
    after the first was pruned while the first one's receipt is still in the
    outbox. *)

val receipt_key_prefix : string
(** Every key starts with it. It holds a character a request id cannot, which is
    how the receipt wait sweep tells a key from a request id. *)

val receipt_key_of_string : string -> (receipt_key, string) result
(** [Error] for a string that does not start with {!receipt_key_prefix}, or that
    holds nothing after it. *)

val receipt_key_to_string : receipt_key -> string

val fresh_receipt_key : unit -> receipt_key
(** A key no other schedule holds. *)

val valid_keeper_wake_target_name : string -> bool
(** [true] when a [masc.keeper_wake] body target name is valid. *)

val keeper_wake_target_name_error : field:string -> string
(** Canonical field-level validation message for target name failures. *)
