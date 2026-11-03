(** What a runtime's [input_tokens] figure counted. Carried from the
    runtime observation into the durable turn record, because a compaction
    estimate and a dispatched request read identically as bare numbers and
    a reader must not present the estimate as a request. *)

type t =
  | Measured_request
      (** The runtime counted a request it actually dispatched. *)
  | Context_estimate
      (** The runtime estimated the size of the context it holds -- Codex
          after a compaction replaces the history and reports the whole new
          one. No request was dispatched at this size and no response
          exists for it. *)
[@@deriving enumerate]

val to_string : t -> string

val of_string : string -> t option
