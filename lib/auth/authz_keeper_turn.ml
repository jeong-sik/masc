(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module D = Authz_decision
module Ks = Authz_keeper_state
module Rs = Authz_runtime_state
module Ps = Authz_principal_state

let ( let* ) = Result.bind
let requested = Effect_request.make Effect.Invoke_model [ Effect.Use_tool ]
let attempts = 3

type refusal =
  | Not_bootstrapped
  | Keeper_not_made of Keeper_id.t
  | No_authorized_runtime of Keeper_id.t
  | Denied of D.deny_reason
  | Log_kept_moving

let refusal_to_string = function
  | Not_bootstrapped -> "the authorization log was never bootstrapped"
  | Keeper_not_made id -> Printf.sprintf "no record made the Keeper %s" (Keeper_id.to_string id)
  | No_authorized_runtime id ->
    Printf.sprintf "the owner gave the Keeper %s no Runtime" (Keeper_id.to_string id)
  | Denied reason -> "denied: " ^ D.deny_reason_to_string reason
  | Log_kept_moving ->
    Printf.sprintf "records were appended during each of %d decisions" attempts
;;

type turn =
  { keeper_id : Keeper_id.t
  ; owner : User_id.t
  ; runtime_id : Runtime_id.t
  ; provider_account_id : Provider_account_id.t
  ; channel : Channel.t
  ; allowance : D.allowance
  }

let found_or_absent = function
  | Some value -> D.Found value
  | None -> D.Absent
;;

let principal_status (state : Authz_state.t) = function
  | Principal.Human user_id ->
    Ps.find state.principals user_id
    |> Option.map (fun (principal : Ps.principal) ->
      match principal.Ps.status with
      | Ps.Active -> Principal_status.Active
      | Ps.Disabled -> Principal_status.Disabled)
    |> found_or_absent
  | Principal.Service (_ : Service_id.t) -> D.Absent
;;

let membership (state : Authz_state.t) principal workspace_id =
  match principal with
  | Principal.Human user_id ->
    (match Ps.find_membership state.principals user_id with
     | Some membership when Workspace_id.equal membership.Ps.workspace_id workspace_id ->
       D.Found Membership_status.Active
     | Some (_ : Ps.membership) | None -> D.Absent)
  | Principal.Service (_ : Service_id.t) -> D.Absent
;;

let runtime_row (state : Authz_state.t) runtime_id =
  Rs.find state.runtimes runtime_id
  |> Option.map (fun (runtime : Rs.runtime) ->
    { Runtime_row.id = runtime_id
    ; owner = Principal.Human runtime.Rs.owner
    ; provider_account = runtime.Rs.provider_account_id
    ; status = Resource_status.Active
    })
  |> found_or_absent
;;

let provider_account (state : Authz_state.t) account_id =
  Authz_provider_account_state.owner state.provider_accounts account_id
  |> Option.map (fun (_ : User_id.t) -> Resource_status.Active)
  |> found_or_absent
;;

(* The Self grant of the Runtime, for its owner and no one else. *)
let self_grant (state : Authz_state.t) principal runtime_id =
  match principal, Rs.find state.runtimes runtime_id with
  | Principal.Human user_id, Some runtime ->
    if User_id.equal user_id runtime.Rs.owner
    then
      D.Found
        { Runtime_grant.id = runtime.Rs.self_grant
        ; runtime_id
        ; grantee = principal
        ; allowed_effects = runtime.Rs.self_effects
        ; status = Grant_status.Active
        ; kind = Runtime_grant.Self
        }
    else D.Absent
  | Principal.Human (_ : User_id.t), None | Principal.Service (_ : Service_id.t), (None | Some _)
    -> D.Absent
;;

let revocation zone subject =
  match Authz_zone.revocation zone subject with
  | Authz_zone.Known state -> D.Found state
  | Authz_zone.Unknown_log_stopped _
  | Authz_zone.Unknown_store_stopped _
  | Authz_zone.Unknown_files_disagree _
  | Authz_zone.Unknown_store_holds_no_answer -> D.Unreadable
;;

let facts zone (state : Authz_state.t) ~(keeper : Ks.keeper) ~now =
  let owner = Principal.Human keeper.Ks.owner in
  { D.now
  ; principal = principal_status state
  ; auth_binding =
      (fun principal ->
        if Principal.equal principal owner then D.Found Auth_binding_status.Active else D.Absent)
  ; membership = membership state
  ; delegate_policy =
      (fun ~initiator ~executor ->
        if Principal.equal initiator owner && Principal.equal executor owner
        then
          D.Found
            { Delegate_policy.id = keeper.Ks.policy_id
            ; initiator
            ; executor
            ; scope = keeper.Ks.turn_scope
            }
        else D.Absent)
  ; runtime = runtime_row state
  ; provider_account = provider_account state
  ; grant = self_grant state
  ; revocation = revocation zone
  ; dependencies = (fun (_ : D.Chain.t) -> D.Found Dependency_state.Cleared)
  }
;;

(* One decision on one snapshot. *)
let decide_on zone (state : Authz_state.t) ~keeper_id ~channel ~now =
  let* workspace_id =
    Option.to_result ~none:Not_bootstrapped (Authz_mode_state.workspace state.mode)
  in
  let* keeper =
    Option.to_result ~none:(Keeper_not_made keeper_id) (Ks.find state.keepers keeper_id)
  in
  let* runtime_id =
    Option.to_result ~none:(No_authorized_runtime keeper_id) keeper.Ks.runtime
  in
  let owner = Principal.Human keeper.Ks.owner in
  let request =
    { D.context =
        { Execution_context.initiator = owner
        ; executor = owner
        ; channel
        ; stored_scope = Authorization_scope.all
        ; pat_scope = Pat_binding.Not_pat
        }
    ; workspace_id
    ; runtime_id
    ; requested
    }
  in
  match D.allowed (facts zone state ~keeper ~now) request with
  | D.Deny reason -> Error (Denied reason)
  | D.Allow allowance ->
    (match Rs.find state.runtimes runtime_id with
     | Some runtime ->
       Ok
         { keeper_id
         ; owner = keeper.Ks.owner
         ; runtime_id
         ; provider_account_id = runtime.Rs.provider_account_id
         ; channel
         ; allowance
         }
     | None ->
       (* [allowed] found the Runtime in this same state. *)
       Error (Denied D.Authorization_uncertain))
;;

let same_head a b =
  Int.equal (Authz_record.next_seq a) (Authz_record.next_seq b)
  && Authz_record.Hash.equal (Authz_record.head_hash a) (Authz_record.head_hash b)
;;

let decide zone ~keeper_id ~channel ~now =
  let rec go left =
    if left <= 0
    then Error Log_kept_moving
    else (
      let before = Authz_zone.snapshot zone in
      let decision = decide_on zone before.Authz_zone.state ~keeper_id ~channel ~now in
      let after = Authz_zone.snapshot zone in
      if same_head before.Authz_zone.head after.Authz_zone.head
      then decision
      else go (left - 1))
  in
  go attempts
;;
