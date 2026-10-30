(** Completion result and the request provenance actually available.

    This is separate from the provider response: errors after serialization
    retain the same fact as successes. The constructors do not invoke an observer.
    Serialization is not evidence of dispatch or provider acceptance. *)
type serialized_request = private
  { output_token_receipt : Types.output_token_receipt
  ; body_bytes : int
  ; body_sha256 : string
  }

type request_provenance =
  | Not_serialized
  | Serialized of serialized_request
  | Cache_reused of serialized_request
  | External_unobserved
  | Interrupted_unobserved

type 'a t = private
  { result : 'a
  ; request_provenance : request_provenance
  }

(** No native generation serialization evidence was produced or supplied for
    this call. *)
val before_serialization : 'a -> 'a t

(** Seal the final body digest and the exact backend-owned receipt from the
    same private artifact. No raw body or credentials are exposed. *)
val after_serialization
  :  request:Complete_common.serialized_http_request
  -> 'a
  -> 'a t

(** Preserve request provenance while transforming only the returned value. *)
val map_result : ('a -> 'b) -> 'a t -> 'b t

(** An injected callback did not return authoritative native wire evidence. *)
val external_unobserved : 'a -> 'a t

(** The caller interrupted work before receiving its native outcome. No
    serialization or non-serialization fact is inferred from cancellation. *)
val interrupted_unobserved : 'a -> 'a t

(** A response cache supplied this result. The sealed body and receipt belong
    to this lookup request, not to a new dispatch or the cached response's
    original provider call. *)
val cache_reused
  :  request:Complete_common.serialized_http_request
  -> 'a
  -> 'a t

(** Durable read projection of request facts. Decoding validates the receipt,
    body length and digest, but cannot establish dispatch or reconstruct the
    private live request artifact. No constructor for a live outcome is exposed. *)
val request_provenance_to_yojson : request_provenance -> Yojson.Safe.t
val request_provenance_of_yojson : Yojson.Safe.t -> (request_provenance, string) result
val equal_request_provenance : request_provenance -> request_provenance -> bool
val pp_request_provenance : Format.formatter -> request_provenance -> unit
