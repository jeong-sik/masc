(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records

type error =
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error

let error_to_string = function
  | Body_not_built error ->
    "the provider account body was not built: " ^ Authz_body.error_to_string error
  | Commit_failed error -> Authz_zone.error_to_string error
;;

let write zone ~user_id event =
  match Authz_provider_account_event.to_body event with
  | Error error -> Error (Body_not_built error)
  | Ok body ->
    let draft =
      { Authz_zone.author = Author.Authenticated (Principal.Human user_id)
      ; kind = Authz_record.Kind.Provider_account
      ; body
      }
    in
    (match Authz_zone.commit zone draft with
     | Ok (_ : Authz_zone.committed) -> Ok ()
     | Error error -> Error (Commit_failed error))
;;

let link zone ~user_id ~provider_account_id =
  write zone ~user_id (Authz_provider_account_event.Linked { provider_account_id; user_id })
;;

let link_key zone ~user_id ~provider_account_id ~integration_id =
  write
    zone
    ~user_id
    (Authz_provider_account_event.Key_linked { provider_account_id; user_id; integration_id })
;;

let owned (state : Authz_state.t) user_id =
  Authz_provider_account_state.owned_by state.Authz_state.provider_accounts user_id
;;

type unavailable =
  | Linked_to_another
  | Defect of Authz_decision.resource_defect
  | Reduction_given_up

let unavailable_to_string = function
  | Linked_to_another -> "it is another person's"
  | Defect defect -> "it is " ^ Authz_decision.resource_defect_to_string defect
  | Reduction_given_up -> "a reduction of it was given up and blocks it"
;;

(* The owner is compared before anything of the account is read, so the answer
   to a person who names another's account does not change with that
   account. *)
let availability (state : Authz_state.t) ~user_id provider_account_id =
  match Authz_provider_account_state.find state.Authz_state.provider_accounts provider_account_id with
  | Some { Authz_provider_account_state.owner; kind = _ } when not (User_id.equal owner user_id) ->
    Error Linked_to_another
  | Some (_ : Authz_provider_account_state.account) | None ->
    (match
       Option.bind
         (Authz_state.provider_account_status state provider_account_id)
         Authz_decision.resource_defect
     with
     | Some defect -> Error (Defect defect)
     | None ->
       (match Authz_state.revocation state (Subject.Credential provider_account_id) with
        | Revocation_state.Pending -> Error Reduction_given_up
        | Revocation_state.Not_pending -> Ok ()))
;;

type removal =
  | Start_given_up
  | Stayed of Authz_purge_event.account_failed_stage

type shown =
  { provider_account_id : Provider_account_id.t
  ; kind : Authz_provider_account_state.kind
  ; removal : removal option
  }

let shown (state : Authz_state.t) user_id =
  List.filter_map
    (fun provider_account_id ->
      Option.bind
        (Authz_provider_account_state.find state.Authz_state.provider_accounts provider_account_id)
        (fun { Authz_provider_account_state.owner = (_ : User_id.t); kind } ->
          let shown removal = Some { provider_account_id; kind; removal } in
          match
            Authz_purge_state.find_account
              state.Authz_state.purges
              { Authz_purge_event.owner = user_id; provider_account_id }
          with
          | Some (Authz_purge_state.Account_pending | Authz_purge_state.Account_purged) -> None
          | Some (Authz_purge_state.Account_failed { failed_stage }) -> shown (Some (Stayed failed_stage))
          | None ->
            (match Authz_state.revocation state (Subject.Credential provider_account_id) with
             | Revocation_state.Pending -> shown (Some Start_given_up)
             | Revocation_state.Not_pending -> shown None)))
    (owned state user_id)
;;
