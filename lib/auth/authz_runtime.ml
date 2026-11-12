(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records

let ( let* ) = Result.bind

type error =
  | Id_not_drawn of Authz_id.error
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error

let error_detail = function
  | Id_not_drawn error -> "a drawn grant id was refused: " ^ Authz_id.error_to_string error
  | Body_not_built error -> "the Runtime body was not built: " ^ Authz_body.error_to_string error
  | Commit_failed error -> Authz_zone.error_detail error
;;

let make zone ~user_id ~provider_account_id ~runtime_id ~self_effects ~draw =
  let* grant_id =
    Result.map_error (fun error -> Id_not_drawn error) (Grant_id.of_string (draw ()))
  in
  let* body =
    Result.map_error
      (fun error -> Body_not_built error)
      (Authz_runtime_event.to_body
         (Authz_runtime_event.Made
            { runtime_id; provider_account_id; user_id; grant_id; self_effects }))
  in
  let draft =
    { Authz_zone.author = Author.Authenticated (Principal.Human user_id)
    ; kind = Authz_record.Kind.Runtime
    ; body
    }
  in
  match Authz_zone.commit zone draft with
  | Ok (_ : Authz_zone.committed) -> Ok grant_id
  | Error error -> Error (Commit_failed error)
;;

let owned (state : Authz_state.t) user_id =
  Authz_runtime_state.owned_by state.Authz_state.runtimes user_id
;;
