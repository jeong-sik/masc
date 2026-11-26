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
  | Agent_held_context
      (** An ACP agent counted the context its session holds after the turn
          ([usage_update.used]). The agent counts it from its own requests,
          so it is a count, not an estimate, but it is the context the next
          request starts from rather than one request already dispatched:
          its output is not part of any response. *)
[@@deriving enumerate]

val to_string : t -> string

val of_string : string -> t option
