(** Durable original-invocation to job binding, committed before workspace
    preparation or backend effects. This is ownership evidence, not permission
    to replay a job whose launch is unconfirmed. *)

type invocation
val invocation_of_source :
  Keeper_owned_job_store.source -> (invocation option, string) result
(** [None] means the original trace, turn reference or tool-use identity is
    unavailable. Contradictory identities are rejected instead of repaired. *)

type replay
val replay_of_source : Keeper_owned_job_store.source -> (replay, string) result
val replay_source : replay -> Keeper_owned_job_store.source
(** Exact original source for an interrupted launch. This carries identity,
    not permission to create a new invocation or replay a backend effect. *)

type reservation = private
  { job_id : Keeper_owned_job_store.Job_id.t
  ; base_path : string
  ; keeper_name : string
  ; source : Keeper_owned_job_store.source
  ; request_sha256 : string
  }

type binding = Fresh of reservation | Existing of reservation
type error =
  { job_id : Keeper_owned_job_store.Job_id.t option
  ; cause : Keeper_owned_job_store.error
  }

val reserve :
  base_path:string -> keeper_name:string -> invocation:invocation ->
  source:Keeper_owned_job_store.source -> argv:string list ->
  inputs:Keeper_owned_job_store.input list -> (binding, error) result
(** Cross-process first-writer binding. Repeated exact calls find the original
    job. A changed source or request is rejected with that existing job ID.
    An unconfirmed commit never authorizes workspace preparation or launch. *)

val reserve_existing :
  base_path:string -> keeper_name:string -> replay -> argv:string list ->
  inputs:Keeper_owned_job_store.input list -> (reservation, error) result
(** Under the same canonical invocation transaction as [reserve], require an
    existing exact source and request. Missing, unreadable or different bytes
    never create a binding, workspace or job. *)

val lookup :
  base_path:string -> keeper_name:string -> invocation ->
  (reservation option, error) result
(** Read-only exact source lookup, including a reservation whose job journal
    is not available yet. Absence never authorizes replay of an existing
    execution attempt. No backend command or job inventory is consulted. *)
