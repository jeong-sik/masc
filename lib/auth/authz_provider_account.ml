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

let link zone ~user_id ~provider_account_id =
  match
    Authz_provider_account_event.to_body
      (Authz_provider_account_event.Linked { provider_account_id; user_id })
  with
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

let owned (state : Authz_state.t) user_id =
  Authz_provider_account_state.owned_by state.Authz_state.provider_accounts user_id
;;
