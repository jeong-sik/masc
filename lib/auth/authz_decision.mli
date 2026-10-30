(* HIGH-RISK-UNREVIEWED: decides whether a request may run on a Runtime. A
   wrong answer here lets one account use another account's provider
   credential. Read it against design 6.2, one conjunct at a time. *)

(** The decision formula of design 6.2, as a pure function.

    {!allowed} reads facts only through {!facts}, so the caller owns the store,
    the clock, and the epoch checks. A fact that the store could not answer is
    {!Unreadable} and denies as [Authorization_uncertain] (design 6.1). A fact
    that is missing, inactive, or expired denies with its own reason. There is
    no default that allows.

    The reason returned is the first check that fails, in this order:
    + the initiator and the executor are active principals;
    + the credential binding of the initiator is active;
    + the initiator and the executor have a current membership;
    + the PAT deadline has not passed;
    + a PAT that asks for a management effect names the channel and the
      effects; its runtimes may remain [All] (design 4.4);
    + a policy covers the pair and the channel;
    + the Runtime exists, and the initiator and the executor each hold a
      current grant on it;
    + the Runtime and its ProviderAccount are active;
    + the Runtime's owner is an active principal with a current membership;
    + the Runtime, the channel, and every requested effect are inside the
      intersection of all limits;
    + no revocation is pending on a principal, grant, Runtime, or credential
      the decision stands on;
    + the chain the decision stands on is cleared.

    Design 6.2 does not list the PAT deadline, the PAT naming rule, the
    resource status, or the owner as conjuncts. It reaches them through
    [active(auth_binding)], the explicit-scope rule of 4.4, and [current_grant]
    (resource epoch, current owner, membership). They are checked here because
    this function does not see epochs.

    Grants are checked before resource status on purpose. A requester without
    a grant gets the same answer for a Runtime that does not exist and for one
    that exists, and learns nothing about the state of someone else's Runtime
    (design 4.2).

    Not here: creating a PAT or an Admin assignment, creating durable work,
    epochs and high-water marks, and [Purge_pending] targets. *)

open Authz_types
open Authz_records

(** What the store said about one row. [Absent] means it answered that the row
    does not exist. [Unreadable] means it could not answer. *)
type 'a lookup =
  | Found of 'a
  | Absent
  | Unreadable

(** The records one decision stands on (design 10.1). A transition clears
    chains one by one, so a chain that is not cleared stops only the requests
    that stand on it (design 3-9). *)
module Chain : sig
  type t =
    { principals : Principal.t list  (** Initiator, executor, and Runtime owner, once each. *)
    ; grants : Grant_id.t list  (** Initiator's grant and executor's grant, once each. *)
    ; policy : Policy_id.t option
    ; runtime_id : Runtime_id.t
    ; provider_account : Provider_account_id.t
    }
end

(** The facts one decision reads. This record is the trust boundary of the
    module: only the store adapter builds it, from the store and nothing else.
    A record whose functions answer [Found] with [Active] for everything allows
    everything, and nothing here can tell.

    Every function must answer from one consistent snapshot, return only rows
    that are current under the epoch and high-water checks of design 8.1 and
    8.2, and never raise: a read that fails answers {!Unreadable}. {!allowed}
    does not catch exceptions, so cancellation still propagates. *)
type facts =
  { now : float  (** Seconds since the epoch. *)
  ; principal : Principal.t -> Principal_status.t lookup
        (** [Absent] is a deleted or unknown principal. *)
  ; auth_binding : Principal.t -> Auth_binding_status.t lookup
        (** The credential binding that authenticated this request as the given
            principal. [Absent] when the request's credential belongs to
            someone else. Only the initiator's binding is asked for, because
            the request is authenticated as the initiator. A revocation that
            is pending on the executor shows up through [revocation]. *)
  ; membership : Principal.t -> Workspace_id.t -> Membership_status.t lookup
  ; delegate_policy :
      initiator:Principal.t -> executor:Principal.t -> Delegate_policy.t lookup
  ; runtime : Runtime_id.t -> Runtime_row.t lookup
  ; provider_account : Provider_account_id.t -> Resource_status.t lookup
  ; grant : Principal.t -> Runtime_id.t -> Runtime_grant.t lookup
  ; revocation : Subject.t -> Revocation_state.t lookup
        (** [Absent] is not an answer and denies as uncertain. *)
  ; dependencies : Chain.t -> Dependency_state.t lookup
        (** Design 6.2 [dependencies_cleared(current_transition_epoch)]:
            [Found Cleared] only when every record in the chain is cleared at
            the current transition epoch. [Absent] is not an answer and denies
            as uncertain. *)
  }

type request =
  { context : Execution_context.t
  ; workspace_id : Workspace_id.t
        (** The workspace of the resource the caller is handling. The caller
            takes it from that resource and never from a value the requester
            sent: the membership checks of the initiator, the executor, and the
            Runtime's owner read it. *)
  ; runtime_id : Runtime_id.t
  ; requested : Effect_request.t
  }

type party =
  | Initiator
  | Executor
  | Owner  (** The Runtime's owner. *)

type grant_defect =
  | No_grant
  | Grant_revoked
  | Grant_purged
  | Grant_expired
  | Grantee_not_owner

(** Why a Runtime or ProviderAccount cannot run. Only states that block. *)
type resource_defect =
  | Resource_disabled
  | Resource_blocked
  | Resource_quarantined
  | Resource_purged

type deny_reason =
  | Authorization_uncertain
  | Principal_inactive of party
  | Auth_binding_inactive
  | Membership_inactive of party
  | Pat_expired
  | Pat_scope_not_explicit
      (** A management effect was requested with a PAT whose channels or
          effects are [All]. *)
  | Invocation_not_allowed
      (** No stored policy covers this initiator and executor pair. Only an
          initiator running its own [Direct] request needs none. *)
  | Initiator_grant_not_current of grant_defect
      (** Also the answer for a Runtime that does not exist. *)
  | Executor_grant_not_current of grant_defect
  | Runtime_unavailable of resource_defect
  | Provider_account_unavailable of resource_defect
  | Runtime_out_of_scope
  | Channel_out_of_scope
  | Effects_out_of_scope of Effect.Set.t
      (** The requested effects that no filter in the intersection allows. *)
  | Revocation_pending of Subject.t
  | Dependencies_not_cleared

(** What an allowed request stands on. The grant ids are equal when the
    initiator is the executor. [policy] is [None] for the neutral [Direct]
    filter. *)
type allowance =
  { initiator_grant : Grant_id.t
  ; executor_grant : Grant_id.t
  ; policy : Policy_id.t option
  }

(** Only {!allowed} makes an [Allow]. Callers read it by pattern matching. *)
type decision = private
  | Allow of allowance
  | Deny of deny_reason

val allowed : facts -> request -> decision

(** A label for logs and test output. It is not parsed back. *)
val deny_reason_to_string : deny_reason -> string
