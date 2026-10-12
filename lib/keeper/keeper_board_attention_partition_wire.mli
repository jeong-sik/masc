(** Pure current-schema partition JSON and ledger framing. No disk read,
    cursor mutation, clock acquisition or worker-epoch generation. *)
open Keeper_board_attention_partition_types

type ready_confirmation =
  { partition_id : string
  ; generation : Generation.t
  ; confirmed_at : float
  ; runtime_instance_id : string
  }

val state_to_string : state -> string
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
val confirmed_ready_to_yojson : t -> ready_confirmation -> Yojson.Safe.t
val parse : string -> (t list * ready_confirmation list, string) result
val serialize : t list -> string
val serialize_confirmations : ready_confirmation list -> string
