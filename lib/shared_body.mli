(** A response body that outlives its request (RFC-0518 D5).

    The bytes are kept by whoever built the value, a cache for instance, and
    every response of them reads the same string: OCaml strings cannot be
    changed. A response therefore adds no copy of the body to the process,
    and {!Http_reqd.respond_with_shared} reserves nothing for it in the
    HTTP/2 response ledger. A body made for one request does not belong
    here: wrapping it would only hide its bytes from the ledger. *)

type t

val of_string : string -> t
val to_string : t -> string
val length : t -> int
