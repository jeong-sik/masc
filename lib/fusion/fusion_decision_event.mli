(** Pure, lossless Fusion decision events. Storage owns source authority,
    locks, journal traversal, JSON-line syntax, hashing, clocks and append. *)

type disposition = Adopted | Rejected | Modified

type proposal = private
  { run_id : string
  ; task_id : string
  ; disposition : disposition
  ; choice : string
  ; reason : string
  }

val parse : Yojson.Safe.t -> (proposal, string) result
(** Validate caller arguments in their existing field/error order. Accepted
    strings retain their original whitespace. *)

type payload
type t

val prepare :
  decision_id:string -> post_id:string -> evidence_sha256:string ->
  goal_ids:string list -> agent:string -> turn_ref:Ids.Turn_ref.t ->
  proposal -> payload
(** Bind already admitted source/Task/Goal/identity facts without performing
    authority checks or reading time. Goal order is retained. *)

val select_for_run : run_id:string -> Yojson.Safe.t -> (t option, string) result
(** [Ok None] skips an already parsed unrelated row before shape validation.
    Selected rows use the existing strict key multiset and validation order.
    One arbitrary [notes] value is accepted; strings and Goal order are kept.
    The original parsed object and turn-reference wire spelling are retained. *)

val decision_id : t -> string
val agent : t -> string
val timestamp : t -> string
(** Original nonblank timestamp, for the store's existing lexical sort. *)

val matches_payload : t -> payload -> bool
(** Compare every payload field while ignoring timestamp, notes and object
    field order. Typed turn identity AND its original wire value must match;
    decoding a different numeric spelling does not authorize a retry. *)

val to_yojson : t -> Yojson.Safe.t
(** Return the original parsed object unchanged, including notes and order. *)

val encode : payload -> timestamp:string -> Yojson.Safe.t
(** Construct a fresh event in the existing field order. The caller reads
    the timestamp only after it has decided to append. *)
