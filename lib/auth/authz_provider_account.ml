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

let link zone ~user_id ~provider_account_id ~integration_id =
  write
    zone
    ~user_id
    (Authz_provider_account_event.Linked { provider_account_id; user_id; integration_id })
;;

let link_key zone ~user_id ~provider_account_id ~integration_id =
  write
    zone
    ~user_id
    (Authz_provider_account_event.Key_linked { provider_account_id; user_id; integration_id })
;;

type replace_error =
  | Not_replaced of Authz_provider_account_state.refusal
  | Replace_failed of error

(* The generation is read on the state of the zone now, so a refusal comes
   back as a refusal of a replacement. The commit decides again. *)
let replace_key zone ~user_id ~provider_account_id =
  match
    Authz_state.key_to_replace (Authz_zone.snapshot zone).Authz_zone.state ~user_id provider_account_id
  with
  | Error refusal -> Error (Not_replaced refusal)
  | Ok held ->
    let generation = Key_generation.next held in
    (match
       write
         zone
         ~user_id
         (Authz_provider_account_event.Key_replaced { provider_account_id; user_id; generation })
     with
     | Ok () -> Ok generation
     | Error error -> Error (Replace_failed error))
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

type blocked =
  | Removal of removal
  | Replacement_start_given_up

type shown =
  { provider_account_id : Provider_account_id.t
  ; kind : Authz_provider_account_state.kind
  ; blocked : blocked option
  }

(* The log writes two reductions on a credential: the start of a purge and
   the replacement of a key. A removal that stopped is read first, so an
   account both stopped on shows its removal: it is removed next.

   A third reduction on a credential would block the account
   ([availability]) with no word for it here. Whoever writes one names it in
   [blocked]: until then the list hides the Runtimes of such an account
   ({!Auth_preview.provider_accounts} asks [availability]) and says no
   reason. *)
let shown (state : Authz_state.t) user_id =
  List.filter_map
    (fun provider_account_id ->
      Option.bind
        (Authz_provider_account_state.find state.Authz_state.provider_accounts provider_account_id)
        (fun { Authz_provider_account_state.owner = (_ : User_id.t); kind } ->
          let shown blocked = Some { provider_account_id; kind; blocked } in
          match Authz_state.account_removal state ~owner:user_id provider_account_id with
          | Authz_state.Removal_begun -> None
          | Authz_state.Removal_stayed failed_stage -> shown (Some (Removal (Stayed failed_stage)))
          | Authz_state.Removal_start_given_up -> shown (Some (Removal Start_given_up))
          | Authz_state.Removal_not_begun ->
            if Authz_state.key_replacement_given_up state provider_account_id
            then shown (Some Replacement_start_given_up)
            else shown None))
    (owned state user_id)
;;
