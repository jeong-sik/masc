(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records

let ( let* ) = Result.bind

type registered =
  { registration_id : Registration_id.t
  ; previously_deleted : bool
  }

type error =
  | Id_not_drawn of Authz_id.error
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error

let error_to_string = function
  | Id_not_drawn error -> "a drawn id was refused: " ^ Authz_id.error_to_string error
  | Body_not_built error -> "the registration body was not built: " ^ Authz_body.error_to_string error
  | Commit_failed error -> Authz_zone.error_to_string error
;;

let attempts = 3

let commit zone ~admin event =
  let* body =
    Result.map_error (fun error -> Body_not_built error) (Authz_registration_event.to_body event)
  in
  let draft =
    { Authz_zone.author = Author.Authenticated (Principal.Human admin)
    ; kind = Authz_record.Kind.Registration
    ; body
    }
  in
  Result.map_error (fun error -> Commit_failed error) (Authz_zone.commit zone draft)
;;

(* An id that the snapshot already names is drawn again. On the last attempt
   it goes to the zone all the same, which refuses it as taken. *)
let register zone ~admin ~draw identity =
  let rec go left =
    let* registration_id =
      Result.map_error (fun error -> Id_not_drawn error) (Registration_id.of_string (draw ()))
    in
    let registrations = (Authz_zone.snapshot zone).state.registrations in
    match Authz_registration_state.find registrations registration_id with
    | Some (_ : Authz_registration_state.registration) when left > 1 -> go (left - 1)
    | Some (_ : Authz_registration_state.registration) | None ->
      let* (committed : Authz_zone.committed) =
        commit zone ~admin (Authz_registration_event.Registered { registration_id; identity })
      in
      Ok
        { registration_id
        ; previously_deleted =
            Authz_principal_state.was_deleted committed.snapshot.state.principals identity
        }
  in
  go attempts
;;

let remove zone ~admin registration_id =
  Result.map
    (fun (_ : Authz_zone.committed) -> ())
    (commit zone ~admin (Authz_registration_event.Removed { registration_id }))
;;
