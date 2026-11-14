(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records

type error =
  | Body_not_built of Authz_body.error
  | Refused of Authz_purge_state.refusal
  | Commit_failed of Authz_zone.error

let error_detail = function
  | Body_not_built error -> "the purge body was not built: " ^ Authz_body.error_to_string error
  | Refused refusal -> Authz_purge_state.refusal_to_string refusal
  | Commit_failed error -> Authz_zone.error_detail error
;;

(* What {!Authz_state} does with the record, on the state of the zone now, so
   a refusal comes back as a refusal of a purge. The commit decides again. *)
let check (state : Authz_state.t) ~author event =
  Authz_purge_state.apply
    state.Authz_state.purges
    ~author
    ~is_active:(Authz_principal_state.is_active state.Authz_state.principals)
    event
  |> Result.map (fun (_ : Authz_purge_state.t) -> ())
;;

let write zone ~author event =
  match check (Authz_zone.snapshot zone).Authz_zone.state ~author event with
  | Error refusal -> Error (Refused refusal)
  | Ok () ->
    (match Authz_purge_event.to_body event with
     | Error error -> Error (Body_not_built error)
     | Ok body ->
       (match Authz_zone.commit zone { Authz_zone.author; kind = Authz_record.Kind.Purge; body } with
        | Ok (_ : Authz_zone.committed) -> Ok ()
        | Error error -> Error (Commit_failed error)))
;;

let start zone ~user_id target =
  write
    zone
    ~author:(Author.Authenticated (Principal.Human user_id))
    (Authz_purge_event.Purge_pending { target })
;;

let purged zone target ~vendor_copy =
  write zone ~author:Author.System_maintenance (Authz_purge_event.Purged { target; vendor_copy })
;;

let failed zone target ~failed_stage ~vendor_copy =
  write
    zone
    ~author:Author.System_maintenance
    (Authz_purge_event.Purge_failed { target; failed_stage; vendor_copy })
;;
