(** Shared streaming decoder for exec-shim stderr control frames. Payload
    bytes retain their order; only the acceptance frame and final trailer are
    removed. The undecided trailer tail is bounded. *)
type t

val create :
  ?callback:(string -> unit) -> acceptance_frame:bool ->
  on_accepted:(unit -> unit) -> unit -> t
val stream_chunk : t -> string -> unit
val settle_head : t -> unit
val tail : t -> string
val flush_payload : t -> string -> unit
val split_final_trailer : string -> (string * string, string) result
