(** Strict current snapshot and receipt wire codec. No storage effects. *)
open Keeper_event_queue_state_core

val projected_source_kind_to_string : projected_source_kind -> string

val durable_disposition_to_yojson : durable_disposition -> Yojson.Safe.t

val durable_disposition_of_yojson : Yojson.Safe.t -> (durable_disposition, string) result
(** The existing compact witness wire shape, also used by the exact-id
    receipt when a consumed scheduled occurrence leaves the queue snapshot. *)

val transition_receipt_to_yojson : transition_receipt -> Yojson.Safe.t

val transition_receipt_of_yojson : Yojson.Safe.t -> (transition_receipt, string) result

val outbox_entry_to_yojson : outbox_entry -> Yojson.Safe.t

val outbox_entry_of_yojson : Yojson.Safe.t -> (outbox_entry, string) result

val to_yojson : t -> Yojson.Safe.t

val of_yojson : Yojson.Safe.t -> (t, string) result

val schema : string
(** ["keeper.event_queue.state.v17"] is the only accepted schema. *)
