(** Durable, product-neutral Fusion completion delivery state. *)

module Completion_address : sig
  type t [@@deriving yojson, show, eq]

  val of_opaque_string : string -> t
  val to_opaque_string : t -> string
  (** Fusion preserves this value exactly; only an upper adapter interprets it. *)
end

type completion_payload =
  { content : string
  ; evidence_ref : string option
  }
[@@deriving yojson, show, eq]

type completion =
  | Succeeded of completion_payload
  | Failed of completion_payload
[@@deriving yojson, show, eq]

type item =
  { operation_id : string
  ; address : Completion_address.t
  ; completion : completion
  }
[@@deriving show, eq]

type error =
  | Persistence_failed of { path : string; detail : string }
  | Unknown_address of string
  | Address_conflict of string
  | Completion_conflict of string
  | Unknown_completion of string

val error_to_string : error -> string

type register_receipt = Registered | Already_registered
type completion_receipt = Queued | Already_pending | Already_delivered
type acknowledgement_receipt = Acknowledged | Already_acknowledged

type t

val create : ?path:string -> unit -> t
val replay : string -> t
(** Hydrate exact addresses, pending completions, and acknowledgements. Invalid
    JSON or impossible event order is logged and never treated as success. *)

val register_address :
  t -> operation_id:string -> Completion_address.t -> (register_receipt, error) result

val complete :
  t -> operation_id:string -> completion -> (completion_receipt, error) result

val acknowledge :
  t -> operation_id:string -> (acknowledgement_receipt, error) result

val pending : t -> item list
val global : unit -> t
val set_global : t -> unit
