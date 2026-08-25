(** Private construction of immutable exact-output response provenance. *)

type t

type raw_response =
  { body : string
  ; body_sha256 : string
  }

val of_evidence
  :  ?response:Types.api_response
  -> Exact_output_execution.one_dispatch_receipt
  -> Exact_output_execution.raw_response_evidence
  -> t

val fingerprint : t -> string
val equal : t -> t -> bool
val raw_response : Exact_output_execution.raw_response_evidence -> raw_response
val record_once : t option Atomic.t -> t -> unit
