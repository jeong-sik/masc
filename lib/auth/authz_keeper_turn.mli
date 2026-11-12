(* HIGH-RISK-UNREVIEWED: decides whether a turn of a Keeper may run on the
   Runtime its owner gave it. A wrong answer runs a Keeper on another
   account's provider credential. Read it against design 6.2 and plan D2. *)

(** The decision of one turn of a Keeper in multi-account mode (plan D2-1).

    It builds the facts of {!Authz_decision.allowed} from the authorization
    log and asks that function. It adds no check of its own: every field of
    the facts reads a record of the log, and this interface says which.

    {b Who.} The owner of the Keeper is both the initiator and the executor of
    its turns (user decision 2026-11-09). A person whose Board post wakes the
    Keeper is an input of the turn, not a party to it.

    {b Facts.}
    - [principal] and [membership]: the principals of the log. A deleted
      principal has no membership. A service is no principal of the log.
    - [auth_binding]: the Keeper record. It binds the owner and no one else.
    - [delegate_policy]: the policy the Keeper record names, for the owner to
      the owner. A [Direct] turn needs none (design 6.2); every other channel
      is limited by its [turn_scope].
    - [runtime] and [grant]: the Runtime record and its Self grant, with the
      effects the record names. The grant is the owner's only.
    - Runtime and ProviderAccount status: the log of phase 1 has no record
      that disables, blocks, quarantines or purges either one, so a Runtime
      or an account the log has is [Active] (plan D2, D5 adds the records).
    - [revocation]: the reductions the state holds
      ({!Authz_state.revocation}).
    - [dependencies]: [Cleared]. Phase 1 has no restore window (F2 is phase 2)
      and a restored log is refused when the zone opens (plan A2).
    - [pat_scope]: the personal access token that authenticated the request
      the turn answers, if one did ([pat]). Its scope narrows the turn as
      every other source does (design 4.4): the Runtime, the channel and
      every effect of {!requested} must be inside it, and it must not have
      expired. A turn that a session started, and a turn the server starts
      itself, has none.
    - No durable work stores a scope in phase 1, so the stored scope puts no
      limit.

    {b One snapshot.} The facts and the gate read one snapshot, the one the
    caller took with {!Authz_zone.read}, so no record separates what they
    read, and a zone whose files stopped or disagree has no snapshot to
    decide on: its caller refuses the turn before this decision. *)

open Authz_types

(** The effects a turn asks for: it calls the model and uses tools. *)
val requested : Effect_request.t

type refusal =
  | Not_bootstrapped  (** The log was never bootstrapped: it has no workspace. *)
  | Keeper_not_made of Keeper_id.t
      (** The owner the turn names made no Keeper of this id. *)
  | No_authorized_runtime of Keeper_id.t
      (** The owner gave the Keeper no Runtime. It falls back to none (user
          decision 2026-11-08). *)
  | Denied of Authz_decision.deny_reason

val refusal_to_string : refusal -> string

(** An allowed turn. Only {!decide} makes one. *)
type turn = private
  { keeper_id : Keeper_id.t
  ; owner : User_id.t
  ; runtime_id : Runtime_id.t
  ; provider_account_id : Provider_account_id.t
  ; channel : Channel.t
  ; allowance : Authz_decision.allowance
  }

(** Decides one turn of the Keeper [keeper_id] of [owner] on [channel] at
    [now] (seconds since the epoch), in the state of one trusted snapshot. A
    Keeper is named by its owner and its id ({!Authz_keeper_state}), so the
    caller says whose Keeper it is: the person a request was authenticated
    as, never a name the request sent. [pat] is what authenticated
    the request the turn answers: [Not_pat] for a session and for a turn the
    server starts itself. *)
val decide
  :  Authz_zone.trusted
  -> owner:User_id.t
  -> keeper_id:Keeper_id.t
  -> channel:Channel.t
  -> pat:Pat_binding.t
  -> now:float
  -> (turn, refusal) result
