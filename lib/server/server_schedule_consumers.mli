val supported_payload_kinds : string list

type keeper_wake_occurrence_status =
  | Keeper_wake_awaiting_settlement
  | Keeper_wake_already_settled

type dispatch_receipt =
  | Keeper_wake_enqueued of
      { keeper_name : string
      ; schedule_id : string
      ; urgency : string
      ; post_id : string
      ; queue : string
      ; stimulus : string
      ; stimulus_id : string
      ; occurrence_status : keeper_wake_occurrence_status
      }

val dispatch_receipt_of_detail :
  Yojson.Safe.t -> (dispatch_receipt, string) result

val dispatch_receipt_to_yojson : dispatch_receipt -> Yojson.Safe.t

val consumer : Schedule_runner.consumer
(** Production scheduled-automation consumer adapter.

    The schedule core remains opaque; this adapter is the MASC server layer that
    interprets explicitly supported payload envelopes. *)

module For_testing : sig
  val with_after_keeper_wake_reaction_read_hook :
    (unit -> unit) -> (unit -> 'a) -> 'a
  (** Install a scoped barrier after terminal evidence is read while the
      queue-owned settlement-projection lock remains held. *)
end
