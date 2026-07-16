(** Typed identity shared by direct Keeper chat requests, queued receipts,
    durable delivery journals, and transcript idempotency slots. *)

module Request_id : sig
  type t

  val generate : unit -> t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

module Receipt_id : sig
  type t

  val generate : unit -> t
  val of_request_id : Request_id.t -> t
  (** Preserve a producer-allocated exact request identity as the queue receipt.
      No derived hash or second namespace participates in duplicate convergence. *)
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

module Receipt_ids : sig
  type t
  type error = Empty

  val of_list : Receipt_id.t list -> (t, error) result
  val error_to_string : error -> string
  val to_list : t -> Receipt_id.t list
end

type delivery_key =
  | Direct_request of Request_id.t
  | Queue_receipts of Receipt_ids.t

type transcript_slot =
  | Accepted_user
  | Tool_call of
      { execution_id : Ids.Execution_id.t
      ; ordinal : int
      }
  | Terminal_assistant

val delivery_key_to_yojson : delivery_key -> Yojson.Safe.t
val delivery_key_of_yojson : Yojson.Safe.t -> (delivery_key, string) result
val delivery_key_equal : delivery_key -> delivery_key -> bool

(** Deterministic, filesystem-safe derivation used only as a record filename.
    The full typed identity remains inside every durable record. *)
val delivery_key_file_stem : delivery_key -> string

val transcript_slot_to_yojson : transcript_slot -> Yojson.Safe.t
val transcript_slot_of_yojson : Yojson.Safe.t -> (transcript_slot, string) result
val transcript_slot_equal : transcript_slot -> transcript_slot -> bool
