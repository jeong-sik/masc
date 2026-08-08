(** Dune-private immutable storage for a provider-built request and the exact
    output-token decision used to build it.  Public backends expose only their
    own abstract artifact types and read-only projections. *)

type 'payload t

val create
  :  payload:'payload
  -> output_token_receipt:Types.output_token_receipt
  -> 'payload t

val payload : 'payload t -> 'payload
val output_token_receipt : 'payload t -> Types.output_token_receipt
