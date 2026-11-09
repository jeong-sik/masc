(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records

let ( let* ) = Result.bind

type error =
  | Id_not_drawn of Authz_id.error
  | Body_not_built of Authz_body.error
  | Refused of Authz_keeper_state.refusal
  | Commit_failed of Authz_zone.error

let author_of user_id = Author.Authenticated (Principal.Human user_id)

let error_to_string = function
  | Id_not_drawn error -> "a drawn policy id was refused: " ^ Authz_id.error_to_string error
  | Body_not_built error -> "the Keeper body was not built: " ^ Authz_body.error_to_string error
  | Refused refusal -> Authz_keeper_state.refusal_to_string refusal
  | Commit_failed error -> Authz_zone.error_to_string error
;;

(* What {!Authz_state} does with the record, on the state of the zone now, so
   a refusal comes back as a refusal of a Keeper. The commit decides again. *)
let check (state : Authz_state.t) ~user_id event =
  Authz_keeper_state.apply
    state.Authz_state.keepers
    ~author:(author_of user_id)
    ~is_active:(Authz_principal_state.is_active state.Authz_state.principals)
    ~runtime_owner:(Authz_runtime_state.owner state.Authz_state.runtimes)
    event
  |> Result.map (fun (_ : Authz_keeper_state.t) -> ())
;;

let write zone ~user_id event =
  match check (Authz_zone.snapshot zone).Authz_zone.state ~user_id event with
  | Error refusal -> Error (Refused refusal)
  | Ok () ->
    (match Authz_keeper_event.to_body event with
     | Error error -> Error (Body_not_built error)
     | Ok body ->
       let draft = { Authz_zone.author = author_of user_id; kind = Authz_record.Kind.Keeper; body } in
       (match Authz_zone.commit zone draft with
        | Ok (_ : Authz_zone.committed) -> Ok ()
        | Error error -> Error (Commit_failed error)))
;;

let make zone ~user_id ~keeper_id ~turn_scope ~draw =
  let* policy_id =
    Result.map_error (fun error -> Id_not_drawn error) (Policy_id.of_string (draw ()))
  in
  write zone ~user_id (Authz_keeper_event.Made { keeper_id; user_id; policy_id; turn_scope })
;;

let assign zone ~user_id ~keeper_id ~runtime_id =
  write zone ~user_id (Authz_keeper_event.Assigned { keeper_id; runtime_id })
;;

let owned (state : Authz_state.t) user_id =
  Authz_keeper_state.owned_by state.Authz_state.keepers user_id
;;
