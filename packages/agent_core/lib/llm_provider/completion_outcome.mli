(** Native completion result and the serialization fact it actually owns.

    This is separate from the provider response: errors after serialization
    retain the same fact as successes. Neither constructor invokes an observer.
    Serialization is not evidence of dispatch or provider acceptance. *)
type serialized_request = private
  { output_token_receipt : Types.output_token_receipt
  ; body_bytes : int
  ; body_sha256 : string
  }

type request_provenance =
  | Not_serialized
  | Serialized of serialized_request

type 'a t = private
  { result : 'a
  ; request_provenance : request_provenance
  }

(** No generation body was serialized by this native call. *)
val before_serialization : 'a -> 'a t

(** Seal the final body digest and the exact backend-owned receipt from the
    same private artifact. No raw body or credentials are exposed. *)
val after_serialization
  :  request:Complete_common.serialized_http_request
  -> 'a
  -> 'a t
