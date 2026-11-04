(* HIGH-RISK-UNREVIEWED: see the interface. *)

module K = Authz_record.Kind
module R = Authz_record

type t = { mode : Authz_mode_state.t }

let empty = { mode = Authz_mode_state.empty }

type refusal =
  | Before_bootstrap of K.t
  | Mode_event_unreadable of Authz_mode_event.error
  | Mode of Authz_mode_state.refusal
  | Kind_not_read of K.t

let refusal_to_string = function
  | Before_bootstrap kind ->
    Printf.sprintf "a %s record comes before the bootstrap of the log" (K.to_string kind)
  | Mode_event_unreadable error ->
    "the mode event cannot be read: " ^ Authz_mode_event.error_to_string error
  | Mode refusal -> Authz_mode_state.refusal_to_string refusal
  | Kind_not_read kind -> Printf.sprintf "no layer of this server reads %s records" (K.to_string kind)
;;

let mode_event state (record : R.t) =
  match Authz_mode_event.of_body record.R.body with
  | Error error -> Error (Mode_event_unreadable error)
  | Ok event ->
    (match Authz_mode_state.apply state.mode event with
     | Ok mode -> Ok { mode }
     | Error refusal -> Error (Mode refusal))
;;

(* A kind that no layer reads yet. *)
let not_read state kind =
  match state.mode with
  | Authz_mode_state.Not_bootstrapped -> Error (Before_bootstrap kind)
  | Authz_mode_state.Multi_account _ | Authz_mode_state.Off _ -> Error (Kind_not_read kind)
;;

let step state (record : R.t) =
  match record.R.kind with
  | K.Mode_event -> mode_event state record
  | ( K.Runtime_grant
    | K.Delegate_policy
    | K.Principal
    | K.Internal_service_credential
    | K.Permission_revocation
    | K.Trigger_evidence
    | K.Lease_terminal_evidence
    | K.Preauthorized_expiry
    | K.Migration_diagnostic
    | K.Local_recovery ) as kind -> not_read state kind
;;
