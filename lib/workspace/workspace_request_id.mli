(** Producer-minted workspace broadcast identity. Shared by the broadcast
    ledger, its filenames and durable notification outboxes. *)
type t
val create : unit -> t
val of_string : string -> (t, string) result
val to_string : t -> string
