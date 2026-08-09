(** Typed immutable identity shared by Keeper operations, Fusion runs,
    durable delivery journals, and transcript idempotency slots. *)

module Request_id : sig
  type t

  val generate : unit -> t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

type delivery_key =
  | Operation of Request_id.t
  | Fusion_run of Request_id.t

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
