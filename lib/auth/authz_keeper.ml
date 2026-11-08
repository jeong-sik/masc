(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records

type error =
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error

let error_to_string = function
  | Body_not_built error -> "the Keeper body was not built: " ^ Authz_body.error_to_string error
  | Commit_failed error -> Authz_zone.error_to_string error
;;

let write zone ~user_id event =
  match Authz_keeper_event.to_body event with
  | Error error -> Error (Body_not_built error)
  | Ok body ->
    let draft =
      { Authz_zone.author = Author.Authenticated (Principal.Human user_id)
      ; kind = Authz_record.Kind.Keeper
      ; body
      }
    in
    (match Authz_zone.commit zone draft with
     | Ok (_ : Authz_zone.committed) -> Ok ()
     | Error error -> Error (Commit_failed error))
;;

let make zone ~user_id ~keeper_id =
  write zone ~user_id (Authz_keeper_event.Made { keeper_id; user_id })
;;

let assign zone ~user_id ~keeper_id ~runtime_id =
  write zone ~user_id (Authz_keeper_event.Assigned { keeper_id; runtime_id })
;;

let owned (state : Authz_state.t) user_id =
  Authz_keeper_state.owned_by state.Authz_state.keepers user_id
;;
