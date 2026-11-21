(* HIGH-RISK-UNREVIEWED: this is what the grant records of the authorization
   log add up to. The effects this module keeps for a grant are the only ones a
   delegated call on that Runtime may spend. *)

(** The grants that the Runtime grant records of [authz.jsonl] add up to
    (design 4.3, plan D1). {!Authz_state} keeps one of these as its field and
    hands it every Runtime grant record of a bootstrapped log.

    {b Projection only.} This module reads a {!Authz_records.Runtime_grant.t}
    that the layer above decoded and decides nothing beyond what that record
    type already says. It does not say who may write a grant record, which
    effects a grantee may exercise, or whether a deadline has passed:
    {!Authz_decision} holds those rules and {!Authz_state} decides who may
    write. The event module that carries [Delegated_granted],
    [Grant_revoked] and [Grant_purged] for this kind (design 4.2-1, plan D1-1)
    writes the record this projection reads; the [Authz_state] handler that
    passes it the records is D1's wiring change, after the N3 [C1-1] landing
    that touches the same file.

    {b One id.} A grant id names one grant for good (design 4.3): no record
    makes a grant again under an id the log already used, and a Runtime keeps
    the Self grant it was made with. *)

type t

val empty : t

(** The grant, if it was made. *)
val find : t -> Authz_types.Grant_id.t -> Authz_records.Runtime_grant.t option

(** Whether the log named this grant id already. *)
val mem : t -> Authz_types.Grant_id.t -> bool

(** The grants of one Runtime, in the order the log named them. An id is an
    arbitrary safe string, so that order is not the order of the ids and not a
    time order either: it is the only order the log itself has. *)
val of_runtime
  :  t
  -> Authz_types.Runtime_id.t
  -> (Authz_types.Grant_id.t * Authz_records.Runtime_grant.t) list

(** The grants one principal holds, in the order of their ids. *)
val of_grantee
  :  t
  -> Authz_types.Principal.t
  -> (Authz_types.Grant_id.t * Authz_records.Runtime_grant.t) list

(** The grant one principal holds on one Runtime — the design's
    [(Principal.t * Runtime_id.t)] lookup (design 4.2-1). The state keeps the
    grants of a Runtime under that Runtime, so this answers without a scan over
    the log.

    {b Which one.} A log may name the pair more than once (a revoke and a
    fresh grant). Ids do not sort by time, so the state keeps the log's own
    order and answers the live grant: the last [Active] one. When no
    grant of the pair is active, it answers the last one, so a caller that must
    explain a refusal sees the record that closed the pair. Deciding whether
    more than one may live at a time is admission's ([Authz_state]), not this
    projection's.
*)
val find_for
  :  t
  -> grantee:Authz_types.Principal.t
  -> runtime_id:Authz_types.Runtime_id.t
  -> Authz_records.Runtime_grant.t option

type refusal = Already_named of Authz_types.Grant_id.t
  (** The id was named before: a grant id names one grant for good. *)

val refusal_to_string : refusal -> string

(** Adds the grant a record names. The grant is taken as the record says it,
    and this layer changes no field of it. *)
val add : t -> Authz_records.Runtime_grant.t -> (t, refusal) result
