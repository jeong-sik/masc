(* HIGH-RISK-UNREVIEWED: decides whether a request may run on a Runtime. A
   wrong answer here lets one account use another account's provider
   credential. Read it against design 6.2, one conjunct at a time. *)

open Authz_types
open Authz_records

type 'a lookup =
  | Found of 'a
  | Absent
  | Unreadable

module Chain = struct
  type t =
    { principals : Principal.t list
    ; grants : Grant_id.t list
    ; policy : Policy_id.t option
    ; runtime_id : Runtime_id.t
    ; provider_account : Provider_account_id.t
    }
end

type facts =
  { now : float
  ; principal : Principal.t -> Principal_status.t lookup
  ; auth_binding : Principal.t -> Auth_binding_status.t lookup
  ; membership : Principal.t -> Workspace_id.t -> Membership_status.t lookup
  ; delegate_policy :
      initiator:Principal.t -> executor:Principal.t -> Delegate_policy.t lookup
  ; runtime : Runtime_id.t -> Runtime_row.t lookup
  ; provider_account : Provider_account_id.t -> Resource_status.t lookup
  ; grant : Principal.t -> Runtime_id.t -> Runtime_grant.t lookup
  ; revocation : Subject.t -> Revocation_state.t lookup
  ; dependencies : Chain.t -> Dependency_state.t lookup
  }

type request =
  { context : Execution_context.t
  ; workspace_id : Workspace_id.t
  ; runtime_id : Runtime_id.t
  ; requested : Effect_request.t
  }

type party =
  | Initiator
  | Executor
  | Owner

type grant_defect =
  | No_grant
  | Grant_revoked
  | Grant_purged
  | Grant_expired
  | Grantee_not_owner

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
  | Invocation_not_allowed
  | Initiator_grant_not_current of grant_defect
  | Executor_grant_not_current of grant_defect
  | Runtime_unavailable of resource_defect
  | Provider_account_unavailable of resource_defect
  | Runtime_out_of_scope
  | Channel_out_of_scope
  | Effects_out_of_scope of Effect.Set.t
  | Revocation_pending of Subject.t
  | Dependencies_not_cleared

type allowance =
  { initiator_grant : Grant_id.t
  ; executor_grant : Grant_id.t
  ; policy : Policy_id.t option
  }

type decision =
  | Allow of allowance
  | Deny of deny_reason

let ( let* ) = Result.bind

(* [absent] is the reason when the store says the row does not exist. A row the
   store could not read is always [Authorization_uncertain]. *)
let require lookup ~absent =
  match lookup with
  | Found value -> Ok value
  | Absent -> Error absent
  | Unreadable -> Error Authorization_uncertain
;;

let for_each people check =
  List.fold_left
    (fun outcome (party, principal) ->
      let* () = outcome in
      check party principal)
    (Ok ())
    people
;;

(* active(principal). A deleted principal has no row. *)
let principal_active facts party principal =
  let* status = require (facts.principal principal) ~absent:(Principal_inactive party) in
  match status with
  | Principal_status.Active -> Ok ()
  | Principal_status.Disabled -> Error (Principal_inactive party)
;;

(* active(auth_binding), for the credential that authenticated the initiator. *)
let auth_binding_active facts initiator =
  let* status = require (facts.auth_binding initiator) ~absent:Auth_binding_inactive in
  match status with
  | Auth_binding_status.Active -> Ok ()
  | Auth_binding_status.Revoked -> Error Auth_binding_inactive
;;

(* current_membership(principal, workspace_id) *)
let membership_current facts workspace_id party principal =
  let* status =
    require (facts.membership principal workspace_id) ~absent:(Membership_inactive party)
  in
  match status with
  | Membership_status.Active -> Ok ()
  | Membership_status.Disabled -> Error (Membership_inactive party)
;;

let pat_unexpired facts = function
  | Pat_binding.Not_pat -> Ok ()
  | Pat_binding.Pat { Pat_scope.expires_at = None; scope = _ } -> Ok ()
  | Pat_binding.Pat { Pat_scope.expires_at = Some deadline; scope = _ } ->
    if facts.now < deadline then Ok () else Error Pat_expired
;;

(* A PAT that asks for a management effect must name the channel and the
   effects (design 4.4). [All] in either is the wildcard a stolen PAT would
   most want, so it does not count as naming. *)
let pat_names_management ~pat_scope ~requested =
  match pat_scope with
  | Pat_binding.Not_pat -> Ok ()
  | Pat_binding.Pat
      { Pat_scope.scope = { Authorization_scope.channels; allowed_effects; runtimes = _ }
      ; expires_at = _
      } ->
    if not (Effect.Set.exists Effect.is_management (Effect_request.to_set requested))
    then Ok ()
    else (
      match channels, allowed_effects with
      | Channel_scope.All, (Effect_scope.Empty | Effect_scope.All | Effect_scope.Only _)
      | (Channel_scope.Empty | Channel_scope.Only _), Effect_scope.All ->
        Error Pat_scope_not_explicit
      | ( (Channel_scope.Empty | Channel_scope.Only _)
        , (Effect_scope.Empty | Effect_scope.Only _) ) -> Ok ())
;;

(* invocation_allowed(initiator, executor, channel) and current_delegate_policy.
   Only the initiator running its own [Direct] request needs no stored policy.
   Every other pair and channel needs the policy stored for exactly that pair. *)
let invocation_policy facts ~initiator ~executor ~channel =
  if Principal.equal initiator executor && Channel.equal channel Channel.Direct
  then Ok (Delegate_policy.neutral_direct, None)
  else (
    let* policy =
      require (facts.delegate_policy ~initiator ~executor) ~absent:Invocation_not_allowed
    in
    (* The store answered with a policy for another pair. *)
    if Principal.equal policy.Delegate_policy.initiator initiator
       && Principal.equal policy.executor executor
    then Ok (policy.scope, Some policy.id)
    else Error Authorization_uncertain)
;;

(* A Runtime that does not exist is reported as the initiator holding no grant,
   so the answer does not tell a requester which Runtime ids exist. *)
let runtime_row facts runtime_id =
  let* row = require (facts.runtime runtime_id) ~absent:(Initiator_grant_not_current No_grant) in
  (* The store answered with another Runtime. *)
  if Runtime_id.equal row.Runtime_row.id runtime_id then Ok row else Error Authorization_uncertain
;;

let resource_defect = function
  | Resource_status.Active -> None
  | Resource_status.Disabled -> Some Resource_disabled
  | Resource_status.Blocked -> Some Resource_blocked
  | Resource_status.Quarantined -> Some Resource_quarantined
  | Resource_status.Purged -> Some Resource_purged
;;

let runtime_active (runtime : Runtime_row.t) =
  match resource_defect runtime.status with
  | None -> Ok ()
  | Some defect -> Error (Runtime_unavailable defect)
;;

(* A Runtime points at its ProviderAccount. If the store does not know the
   account, its own records disagree and nobody can fix that by asking again. *)
let provider_account_active facts account_id =
  let* status =
    require (facts.provider_account account_id) ~absent:Authorization_uncertain
  in
  match resource_defect status with
  | None -> Ok ()
  | Some defect -> Error (Provider_account_unavailable defect)
;;

(* Why a stored grant is not current, or [None] when it is. A [Self] grant is
   valid only for the Runtime's current owner. *)
let grant_fault facts ~(runtime : Runtime_row.t) (grant : Runtime_grant.t) =
  match grant.status with
  | Grant_status.Revoked -> Some Grant_revoked
  | Grant_status.Purged -> Some Grant_purged
  | Grant_status.Active ->
    (match grant.kind with
     | Runtime_grant.Self ->
       if Principal.equal grant.grantee runtime.owner then None else Some Grantee_not_owner
     | Runtime_grant.Delegated { expires_at = None } -> None
     | Runtime_grant.Delegated { expires_at = Some deadline } ->
       if facts.now < deadline then None else Some Grant_expired)
;;

(* current_grant(principal, runtime). [not_current] says whose grant it was. *)
let current_grant facts ~runtime ~runtime_id ~not_current principal =
  let* grant = require (facts.grant principal runtime_id) ~absent:(not_current No_grant) in
  (* The store answered with a grant for another Runtime or grantee. *)
  if not
       (Runtime_id.equal grant.Runtime_grant.runtime_id runtime_id
        && Principal.equal grant.grantee principal)
  then Error Authorization_uncertain
  else (
    match grant_fault facts ~runtime grant with
    | Some defect -> Error (not_current defect)
    | None -> Ok grant)
;;

(* scope_ok, channel_ok, effects_ok. Every source only narrows. [All] is the
   identity of the intersection and never reaches past the grants. *)
let within_limits ~(request : request) ~policy_scope ~initiator_grant ~executor_grant =
  let { Execution_context.initiator = _
      ; executor = _
      ; channel
      ; stored_scope
      ; pat_scope
      }
    =
    request.context
  in
  let { Authorization_scope.runtimes; channels; allowed_effects } =
    Authorization_scope.inter
      stored_scope
      (Authorization_scope.inter policy_scope (Pat_binding.scope pat_scope))
  in
  if not (Runtime_scope.mem request.runtime_id runtimes)
  then Error Runtime_out_of_scope
  else if not (Channel_scope.mem channel channels)
  then Error Channel_out_of_scope
  else (
    let grant_effects (grant : Runtime_grant.t) = Effect_scope.only grant.allowed_effects in
    let permitted =
      Effect_scope.inter
        allowed_effects
        (Effect_scope.inter (grant_effects initiator_grant) (grant_effects executor_grant))
    in
    let uncovered =
      Effect_scope.uncovered permitted (Effect_request.to_set request.requested)
    in
    if Effect.Set.is_empty uncovered
    then Ok ()
    else Error (Effects_out_of_scope uncovered))
;;

(* not revocation_pending(subject), for every subject the request stands on. *)
let revocation_clear facts subjects =
  List.fold_left
    (fun outcome subject ->
      let* () = outcome in
      let* state = require (facts.revocation subject) ~absent:Authorization_uncertain in
      match state with
      | Revocation_state.Not_pending -> Ok ()
      | Revocation_state.Pending -> Error (Revocation_pending subject))
    (Ok ())
    subjects
;;

(* dependencies_cleared(current_transition_epoch) for the chain of this
   decision, not for the whole store. *)
let dependencies_cleared facts chain =
  let* state = require (facts.dependencies chain) ~absent:Authorization_uncertain in
  match state with
  | Dependency_state.Cleared -> Ok ()
  | Dependency_state.Not_cleared -> Error Dependencies_not_cleared
;;

let add_distinct equal item items =
  if List.exists (equal item) items then items else items @ [ item ]
;;

let evaluate facts (request : request) =
  let { Execution_context.initiator; executor; channel; stored_scope = _; pat_scope } =
    request.context
  in
  let same_principal = Principal.equal initiator executor in
  let people =
    (Initiator, initiator) :: (if same_principal then [] else [ Executor, executor ])
  in
  let* () = for_each people (principal_active facts) in
  let* () = auth_binding_active facts initiator in
  let* () = for_each people (membership_current facts request.workspace_id) in
  let* () = pat_unexpired facts pat_scope in
  let* () = pat_names_management ~pat_scope ~requested:request.requested in
  let* policy_scope, policy_id = invocation_policy facts ~initiator ~executor ~channel in
  let* runtime = runtime_row facts request.runtime_id in
  let runtime_id = request.runtime_id in
  let* initiator_grant =
    current_grant
      facts
      ~runtime
      ~runtime_id
      ~not_current:(fun defect -> Initiator_grant_not_current defect)
      initiator
  in
  let* executor_grant =
    if same_principal
    then Ok initiator_grant
    else
      current_grant
        facts
        ~runtime
        ~runtime_id
        ~not_current:(fun defect -> Executor_grant_not_current defect)
        executor
  in
  let* () = runtime_active runtime in
  let provider_account = runtime.Runtime_row.provider_account in
  let* () = provider_account_active facts provider_account in
  (* The owner stands behind every grant on the Runtime. It is checked here
     unless it is the initiator or the executor, who were checked above. *)
  let owner = runtime.Runtime_row.owner in
  let owners =
    if List.exists (fun (_, principal) -> Principal.equal principal owner) people
    then []
    else [ Owner, owner ]
  in
  let* () = for_each owners (principal_active facts) in
  let* () = for_each owners (membership_current facts request.workspace_id) in
  let* () = within_limits ~request ~policy_scope ~initiator_grant ~executor_grant in
  let initiator_grant_id = initiator_grant.Runtime_grant.id in
  let executor_grant_id = executor_grant.Runtime_grant.id in
  let* () =
    revocation_clear
      facts
      [ Subject.Principal initiator
      ; Subject.Principal executor
      ; Subject.Principal owner
      ; Subject.Grant initiator_grant_id
      ; Subject.Grant executor_grant_id
      ; Subject.Runtime runtime_id
      ; Subject.Credential provider_account
      ]
  in
  let chain =
    { Chain.principals =
        add_distinct Principal.equal owner (add_distinct Principal.equal executor [ initiator ])
    ; grants = add_distinct Grant_id.equal executor_grant_id [ initiator_grant_id ]
    ; policy = policy_id
    ; runtime_id
    ; provider_account
    }
  in
  let* () = dependencies_cleared facts chain in
  Ok { initiator_grant = initiator_grant_id; executor_grant = executor_grant_id; policy = policy_id }
;;

let allowed facts request =
  match evaluate facts request with
  | Ok allowance -> Allow allowance
  | Error reason -> Deny reason
;;

let party_to_string = function
  | Initiator -> "initiator"
  | Executor -> "executor"
  | Owner -> "owner"
;;

let grant_defect_to_string = function
  | No_grant -> "no_grant"
  | Grant_revoked -> "grant_revoked"
  | Grant_purged -> "grant_purged"
  | Grant_expired -> "grant_expired"
  | Grantee_not_owner -> "grantee_not_owner"
;;

let resource_defect_to_string = function
  | Resource_disabled -> "disabled"
  | Resource_blocked -> "blocked"
  | Resource_quarantined -> "quarantined"
  | Resource_purged -> "purged"
;;

let deny_reason_to_string = function
  | Authorization_uncertain -> "authorization_uncertain"
  | Principal_inactive party -> "principal_inactive:" ^ party_to_string party
  | Auth_binding_inactive -> "auth_binding_inactive"
  | Membership_inactive party -> "membership_inactive:" ^ party_to_string party
  | Pat_expired -> "pat_expired"
  | Pat_scope_not_explicit -> "pat_scope_not_explicit"
  | Invocation_not_allowed -> "invocation_not_allowed"
  | Initiator_grant_not_current defect ->
    "grant_not_current:initiator:" ^ grant_defect_to_string defect
  | Executor_grant_not_current defect ->
    "grant_not_current:executor:" ^ grant_defect_to_string defect
  | Runtime_unavailable defect -> "runtime_unavailable:" ^ resource_defect_to_string defect
  | Provider_account_unavailable defect ->
    "provider_account_unavailable:" ^ resource_defect_to_string defect
  | Runtime_out_of_scope -> "runtime_out_of_scope"
  | Channel_out_of_scope -> "channel_out_of_scope"
  | Effects_out_of_scope effects ->
    "effects_out_of_scope:"
    ^ String.concat "," (List.map Effect.to_string (Effect.Set.elements effects))
  | Revocation_pending subject -> "revocation_pending:" ^ Subject.to_string subject
  | Dependencies_not_cleared -> "dependencies_not_cleared"
;;
