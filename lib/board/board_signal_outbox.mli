(** Durable Board routing-event outbox.

    A Board mutation is bracketed by [prepare] and [commit]. Once prepared, a
    command is never discarded from recovery based on current projected state. A
    committed routing event remains pending until [mark_delivered] durably
    settles it.  The ledger is strict: malformed rows and illegal transitions
    fail the whole read instead of being skipped. *)

type recipient = private
  | Keeper_lane of string
  | Target_identity of {
      identity : string;
      keeper_name : string option;
    }

val keeper_lane : string -> (recipient, string) result
val target_identity : string -> (recipient, string) result

type phase =
  | Prepared of Board_signal_command.t
  | Committed of {
      mutation : Board_signal_command.t;
      recipients : recipient list option;
      settled_recipients : recipient list;
    }
  | Delivered of {
      mutation : Board_signal_command.t;
      recipients : recipient list;
      at : float;
    }

type entry = {
  event_id : string;
  order : int;
  phase : phase;
}

val prepare : event_id:string -> command:Board_signal_command.t -> (unit, string) result
val commit : event_id:string -> (unit, string) result

type recipient_progress =
  | Recipients_unplanned
  | Recipients_pending of recipient list
  | Recipients_settled

val plan_recipients :
  event_id:string -> recipients:recipient list -> (unit, string) result
(** Freeze the typed delivery units for this committed event. Keeper lanes are
    exact names. Target identities start unresolved and must be durably bound
    with {!resolve_target} before delivery. Repeating the same plan is
    idempotent; a different plan is a conflict. *)

val recipient_progress :
  event_id:string -> (recipient_progress, string) result

val resolve_target :
  event_id:string ->
  identity:string ->
  keeper_name:string ->
  (recipient, string) result
(** Durably freeze one target identity to its uniquely resolved Keeper lane
    before delivery. Repeating the same binding is idempotent; rebinding is a
    conflict. *)

val reject_target : event_id:string -> identity:string -> (unit, string) result
(** Explicitly terminalize a target that has no unique Keeper lane in the
    authoritative registry. The unresolved typed recipient is retained as the
    durable rejection proof; it is never reinterpreted as a successful
    delivery. *)

val settle_recipient :
  event_id:string -> recipient:recipient -> (unit, string) result
(** Durably settle one planned recipient.  Exact repeats are idempotent. *)

val mark_delivered : event_id:string -> at:float -> (unit, string) result

val entries : unit -> (entry list, string) result
(** Current latest state for every event in durable prepare order. *)

val compact_terminal : unit -> (unit, string) result
(** Deterministic compaction. Removes the terminal prefix before the oldest
    pending event. Terminal successors are retained because replay of an older
    prepared mutation must reapply every later mutation in durable order. *)
