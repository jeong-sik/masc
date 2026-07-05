val supported_payload_kinds : string list

type dispatch_receipt =
  | Board_post_created of
      { post_id : string
      ; author : string
      ; hearth : string option
      }
  | Keeper_wake_enqueued of
      { keeper_name : string
      ; schedule_id : string
      ; urgency : string
      ; post_id : string
      ; queue : string
      ; stimulus : string
      }

val dispatch_receipt_of_detail :
  Yojson.Safe.t -> (dispatch_receipt, string) result

val dispatch_receipt_to_yojson : dispatch_receipt -> Yojson.Safe.t

val consumer : Schedule_runner.consumer
(** Production scheduled-automation consumer adapter.

    The schedule core remains opaque; this adapter is the MASC server layer that
    interprets explicitly supported payload envelopes. *)
