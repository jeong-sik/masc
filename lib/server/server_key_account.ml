(* HIGH-RISK-UNREVIEWED: see the interface. *)

module R = Login_routes
module Purge = Server_key_account_purge

let path = "/api/v1/setup/accounts/key"
let entry_prefix = path ^ "/"

let refused status ~code sentence = R.json status [ "error", `String sentence; "code", `String code ]

let unknown_account = refused R.Not_found_404 ~code:"unknown_account" "No key account of yours has this id."

(* The details of each failure are in the log ({!Purge.remove}). *)
let removal_error : Purge.error -> R.answer = function
  | Purge.Not_found -> unknown_account
  | Purge.Not_a_key_account ->
    refused
      R.Bad_request_400
      ~code:"not_a_key_account"
      "This account holds a login. Only an account that holds a key is removed here."
  | Purge.Account_busy ->
    refused
      R.Conflict_409
      ~code:"account_call_running"
      "A call of this account is running. Try again when it ends."
  | Purge.Not_started (Authz_purge.Refused (Authz_purge_state.User_not_active _)) ->
    refused R.Forbidden_403 ~code:"removal_refused" "Your account is not active, so it removes no account."
  | Purge.Not_started (Authz_purge.Commit_failed (_ : Authz_zone.error)) ->
    refused
      R.Service_unavailable_503
      ~code:"removal_not_recorded"
      "The removal could not be recorded, and nothing was removed. Ask again to remove it."
  | Purge.Not_started
      ( Authz_purge.Body_not_built (_ : Authz_body.error)
      | Authz_purge.Refused
          ( Authz_purge_state.Not_the_owner _
          | Authz_purge_state.Already_pending _
          | Authz_purge_state.Already_purged _
          | Authz_purge_state.Not_started _
          | Authz_purge_state.Not_a_human _
          | Authz_purge_state.Ended_by_a_principal _
          | Authz_purge_state.Started_by_the_maintenance _
          | Authz_purge_state.Not_a_purge_author _ ) ) ->
    (* The person starts the removal of an account of their own, as a person,
       after the status of the account was read inside its call, which keeps
       a second removal of it out. The body is two ids. *)
    refused
      R.Internal_error_500
      ~code:"internal_error"
      "The removal was refused for a reason this server does not expect."
  | Purge.Not_ended (_ : Authz_purge.error) ->
    refused
      R.Service_unavailable_503
      ~code:"removal_not_recorded"
      "The end of the removal could not be recorded. Ask again to finish it."
  | Purge.Files_not_removed Authz_purge_event.Key_not_removed ->
    refused
      R.Service_unavailable_503
      ~code:"key_not_removed"
      "The key of this account could not be removed from this server. Nothing uses the account. \
       Ask again to remove it."
  | Purge.Files_not_removed Authz_purge_event.Home_not_removed ->
    refused
      R.Service_unavailable_503
      ~code:"home_not_removed"
      "The key of this account was removed from this server, and its other files were not. Ask \
       again to remove them."
;;

let remove ~person ~base_path ~provider_account_id =
  match Authz_types.Provider_account_id.of_string provider_account_id with
  | Error (_ : Authz_id.error) -> unknown_account
  | Ok id ->
    (match Purge.remove ~person ~base_path id with
     | Ok () -> R.json R.Ok_200 [ "provider_account_id", `String provider_account_id; "removed", `Bool true ]
     | Error error -> removal_error error)
;;
