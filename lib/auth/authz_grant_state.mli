(* HIGH-RISK-UNREVIEWED: this is what the grant records of the authorization
   log add up to. The effects this module keeps for a grant are the only ones a
   delegated call on that Runtime may spend. *)

(** The grants that the Runtime grant records of [authz.jsonl] add up to
    (design 4.3, plan D1). {!Authz_state} keeps one of these as its field and
    hands it every Runtime grant record of a bootstrapped log.

    {b Projection only, for now.} The record body of this kind is not defined
    yet: [Authz_runtime_event] carries the Self grant of a Runtime as an id and
    a set of effects, and no module writes a grant's own grantee, status, kind
    and deadline. Design 4.3 is outside the repository (plan D1), so this
    module reads a {!Authz_records.Runtime_grant.t} that the layer above
    decoded and decides nothing beyond what that record type already says. It
    does not say who may write a grant record, which effects a grantee may
    exercise, or whether a deadline has passed: {!Authz_decision} holds those
    rules, and {!Authz_state} answers [Kind_not_read] for the kind until the
    body is defined. The wiring and those answers follow in one change with the
    record body, so no caller reads a grant from here while a log record that
    makes it cannot be written.

    {b One id.} A grant id names one grant for good (design 4.3): no record
    makes a grant again under an id the log already used, and a Runtime keeps
    the Self grant it was made with. *)

type t

val empty : t

(** The grant, if it was made. *)
val find : t -> Authz_types.Grant_id.t -> Authz_records.Runtime_grant.t option

(** Whether the log named this grant id already. *)
val mem : t -> Authz_types.Grant_id.t -> bool

(** The grants of one Runtime, in the order of their ids. *)
val of_runtime
  :  t
  -> Authz_types.Runtime_id.t
  -> (Authz_types.Grant_id.t * Authz_records.Runtime_grant.t) list

(** The grants one principal holds, in the order of their ids. *)
val of_grantee
  :  t
  -> Authz_types.Principal.t
  -> (Authz_types.Grant_id.t * Authz_records.Runtime_grant.t) list

type refusal = Already_named of Authz_types.Grant_id.t
  (** The id was named before: a grant id names one grant for good. *)

val refusal_to_string : refusal -> string

(** Adds the grant a record names. The grant is taken as the record says it,
    and this layer changes no field of it. *)
val add : t -> Authz_records.Runtime_grant.t -> (t, refusal) result
