(* HIGH-RISK-UNREVIEWED: see the interface. *)

module R = Login_routes
module S = Authz_state
module Accounts = Authz_provider_account_state
module Client = Runtime_setup_login_client
module Login = Server_setup_account_login
module Purge = Server_key_account_purge
module Registration = Server_key_account_registration
module Replacement = Server_key_account_replacement

let path = "/api/v1/setup/accounts/key"
let entry_prefix = path ^ "/"

let refused status ~code sentence = R.json status [ "error", `String sentence; "code", `String code ]

let unknown_account = refused R.Not_found_404 ~code:"unknown_account" "No key account of yours has this id."

(* A record the zone did not take, and what is answered for it.

   Whether asking again can go through is the zone's to say
   ({!Authz_zone.read}). A zone that can be trusted has not stopped: a
   request asked again is read and its record is tried, and goes in after a
   moment in which another process held a file and wrote nothing.
   [asked_again] says what the request left and to ask again. A zone that
   cannot be trusted takes no record until the server starts again, and
   answers every request of a person from then on as {!R.zone_uncertain}
   does, before the request is read. This request found it so, and is
   answered the same: asked again, it gets that answer. *)
let not_taken (person : Login.person) ~asked_again =
  match Authz_zone.read person.zone with
  | Ok (_ : Authz_zone.trusted) -> asked_again
  | Error uncertain -> R.zone_uncertain uncertain
;;

(* The details of each failure are in the log ({!Purge.remove}). *)
let removal_error person : Purge.error -> R.answer = function
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
    not_taken
      person
      ~asked_again:
        (refused
           R.Service_unavailable_503
           ~code:"removal_not_recorded"
           "The removal could not be recorded, and nothing was removed. Ask again to remove it.")
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
    not_taken
      person
      ~asked_again:
        (refused
           R.Service_unavailable_503
           ~code:"removal_not_recorded"
           "The end of the removal could not be recorded. Ask again to finish it.")
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
     | Error error -> removal_error person error)
;;

(* ---- registration ---- *)

type request =
  { integration_id : Authz_types.Integration_id.t
  ; key : Runtime_api_key_file.key
  }

let invalid_request =
  refused
    R.Bad_request_400
    ~code:"invalid_request"
    {|The body is {"integration_id": ..., "key": ...}: these two members, each a string, and integration_id an id.|}
;;

let not_a_key =
  refused
    R.Bad_request_400
    ~code:"not_a_key"
    "The key is one value: not empty, with no control character in it, and no JSON document."
;;

(* The body holds the key. It is read here and nowhere else, and nothing of
   it goes into an answer or a line of the log: the answers of a refused
   body are fixed sentences. *)
let request_of_body body =
  let members =
    match Yojson.Safe.from_string body with
    | `Assoc [ ("integration_id", `String integration_id); ("key", `String key) ]
    | `Assoc [ ("key", `String key); ("integration_id", `String integration_id) ] ->
      Some (integration_id, key)
    | (_ : Yojson.Safe.t) -> None
    | exception Yojson.Json_error (_ : string) -> None
  in
  match members with
  | None -> Error invalid_request
  | Some (integration_id, key) ->
    (match Authz_types.Integration_id.of_string integration_id, Runtime_api_key_file.key_of_string key with
     | Error (_ : Authz_id.error), (Some (_ : Runtime_api_key_file.key) | None) -> Error invalid_request
     | Ok (_ : Authz_types.Integration_id.t), None -> Error not_a_key
     | Ok integration_id, Some key -> Ok { integration_id; key })
;;

let takes_no_key =
  refused
    R.Bad_request_400
    ~code:"integration_takes_no_key"
    "This integration takes no API key."
;;

let takes_key : Client.client -> bool = function
  | Client.Claude -> true
  | Client.Codex | Client.Muse | Client.Antigravity -> false
;;

let http_takes_key = Runtime_account_runtime.http_provider_takes_key

(* Whether a person registers a key for the integration: a provider that
   runtime.toml declares, either an HTTP provider whose API key this stage
   takes (returning [No_home], RFC §3.9) or an official client whose key
   uses a Claude Code home. It is the target a verification of the account
   resolves again ({!Login.person_runtime}), so a key is taken only where it
   is used. *)
let key_target config ~integration_id =
  let id = Authz_types.Integration_id.to_string integration_id in
  match Runtime_schema.provider_of_id config id with
  | None ->
    Error
      (refused
         R.Bad_request_400
         ~code:"unknown_integration"
         "This workspace declares no provider of this id.")
  | Some provider when http_takes_key provider -> Ok Runtime_key_account_files.No_home
  | Some (_ : Runtime_schema.provider) ->
    (match Login.person_target config ~integration_id:id with
     | Error
         ( Login.Invalid_integration
         | Login.Not_declared
         | Login.No_login (_ : Server_runtime_setup_actions.error)
         | Login.Copy_without_owner ) ->
       Error takes_no_key
     | Ok { Server_runtime_setup_actions.client; cli_path = _; spawn_path = _ } ->
       if takes_key client then Ok Runtime_key_account_files.Claude_home else Error takes_no_key)
;;

let not_recorded =
  refused
    R.Service_unavailable_503
    ~code:"registration_not_recorded"
    "The registration could not be recorded, and nothing of the key was stored. Send the key again."
;;

let registration_refused =
  refused
    R.Forbidden_403
    ~code:"registration_refused"
    "Your account is not active, or an action that restricts it has not finished, so it registers no key."
;;

let unexpected =
  refused
    R.Internal_error_500
    ~code:"internal_error"
    "The registration was refused for a reason this server does not expect. Nothing of the key was \
     stored."
;;

(* What the state says of a record of a provider account that a person
   wrote for themselves. Only the author, the mode and the account itself
   refuse one; the other refusals are of other kinds of record, or of a
   record that closes a reduction it does not hold. *)
type state_refusal =
  | Person_not_writing
  | Log_not_writing
  | Of_account of Accounts.refusal
  | No_request_leads_here

let state_refusal : S.refusal -> state_refusal = function
  | S.Author_inactive (_ : Authz_types.User_id.t) | S.Revocation_pending (_ : Authz_records.Subject.t) ->
    Person_not_writing
  | S.Before_bootstrap (_ : Authz_record.Kind.t) | S.Accounts_off (_ : Authz_record.Kind.t) -> Log_not_writing
  | S.Provider_account refusal -> Of_account refusal
  | S.Provider_account_unreadable _
  | S.Pat_unreadable _
  | S.Pat _
  | S.Registration_unreadable _
  | S.Registration _
  | S.Mode_event_unreadable _
  | S.Mode _
  | S.Invite_unreadable _
  | S.Invite _
  | S.Admission_unreadable _
  | S.Admission _
  | S.Admin_assignment_unreadable _
  | S.Admin_assignment _
  | S.Principal_unreadable _
  | S.Principal_event _
  | S.Kind_not_read _
  | S.Admission_behind_log _
  | S.Closes_without_reduction
  | S.Closes_not_held _
  | S.Cancel_unreadable _
  | S.Canceller_is_not_an_admin _
  | S.Cancel_not_held _
  | S.Cancel_subject_differs _
  | S.Canceller_owns_the_subject _
  | S.Cancel_owner_unknown _
  | S.Session_unreadable _
  | S.Session _
  | S.Service_credential_unreadable _
  | S.Service_credential _
  | S.Runtime_unreadable _
  | S.Runtime _
  | S.Keeper_unreadable _
  | S.Keeper _
  | S.Purge_unreadable _
  | S.Purge _ -> No_request_leads_here
;;

(* Why a record of a provider account did not go into the log. *)
type not_recorded =
  | Refused_by_state of S.refusal
  | Not_built
  | Store_did_not_take

let not_recorded_of : Authz_provider_account.error -> not_recorded = function
  | Authz_provider_account.Commit_failed (Authz_zone.Refused refusal) -> Refused_by_state refusal
  | Authz_provider_account.Body_not_built (_ : Authz_body.error)
  | Authz_provider_account.Commit_failed (Authz_zone.Record_not_built _ | Authz_zone.Log_holds_records _) ->
    Not_built
  | Authz_provider_account.Commit_failed
      ( Authz_zone.Store_stopped _
      | Authz_zone.Log_stopped _
      | Authz_zone.Uncertain _
      | Authz_zone.Store_holds_no_answer
      | Authz_zone.Store_entry_refused _
      | Authz_zone.Abort_not_confirmed _
      | Authz_zone.Settlement_not_written _
      | Authz_zone.Intent_not_written _
      | Authz_zone.Record_not_appended _
      | Authz_zone.Answer_not_written _ ) -> Store_did_not_take
;;

(* A [key_linked] record that a person wrote for themselves, with an id the
   server drew: of the account, only an inactive owner refuses it. The other
   refusals of an account are of an id that was linked before, which a drawn
   id is not, or of a replacement. *)
let registration_refusal refusal =
  match state_refusal refusal with
  | Person_not_writing | Of_account (Accounts.User_not_active (_ : Authz_types.User_id.t)) ->
    registration_refused
  | Log_not_writing -> not_recorded
  | Of_account
      ( Accounts.Already_linked (_ : Authz_types.Provider_account_id.t)
      | Accounts.Linked_for_another { author = _; user_id = _ }
      | Accounts.Not_a_human (_ : Authz_types.Principal.t)
      | Accounts.Not_an_account_author (_ : Authz_records.Author.t)
      | Accounts.Replaced_for_another { author = _; user_id = _ }
      | Accounts.Not_linked (_ : Authz_types.Provider_account_id.t)
      | Accounts.Not_the_owner (_ : Authz_types.Provider_account_id.t)
      | Accounts.Not_a_key_account (_ : Authz_types.Provider_account_id.t)
      | Accounts.Account_removed (_ : Authz_types.Provider_account_id.t)
      | Accounts.Removal_stopped (_ : Authz_types.Provider_account_id.t)
      | Accounts.Generation_not_next { held = _; given = _ } )
  | No_request_leads_here -> unexpected
;;

(* The details of each failure are in the log ({!Registration.register}). *)
let registration_error person : Registration.error -> R.answer = function
  | Registration.Id_not_usable -> not_recorded
  | Registration.Not_recorded error ->
    (match not_recorded_of error with
     | Refused_by_state refusal -> registration_refusal refusal
     | Not_built -> unexpected
     | Store_did_not_take -> not_taken person ~asked_again:not_recorded)
  | Registration.Files_not_made ->
    refused
      R.Service_unavailable_503
      ~code:"key_not_stored"
      "The key could not be stored on this server, and nothing of it stays here. Send the key again."
  | Registration.Account_stays { provider_account_id; removal = (_ : Purge.error) } ->
    (* The person removes the account by its id, so the answer gives it. *)
    R.json
      R.Service_unavailable_503
      [ ( "error"
        , `String
            "The key could not be stored on this server, and the account that was recorded for it \
             could not be removed. Remove this account, and send the key again." )
      ; "code", `String "account_not_removed"
      ; "provider_account_id", `String (Authz_types.Provider_account_id.to_string provider_account_id)
      ]
;;

let register ~person ~base_path ~body =
  match request_of_body body with
  | Error answer -> answer
  | Ok { integration_id; key } ->
    (match Server_runtime_setup_actions.config ~base_path with
     | Error (_ : Server_runtime_setup_actions.error) ->
       refused
         R.Service_unavailable_503
         ~code:"configuration_unavailable"
         "The providers of this workspace could not be read, so no key was taken."
     | Ok config ->
       (match key_target config ~integration_id with
        | Error answer -> answer
        | Ok home ->
          (match Registration.register ~home ~person ~base_path ~integration_id key with
           | Ok id ->
             R.json
               R.Ok_200
               [ "provider_account_id", `String (Authz_types.Provider_account_id.to_string id)
               ; "kind", `String "key"
               ]
           | Error error -> registration_error person error)))
;;

(* ---- replacement ---- *)

let replacement_invalid_request =
  refused R.Bad_request_400 ~code:"invalid_request" {|The body is {"key": ...}: this one member, a string.|}
;;

(* The body holds the key, as that of a registration does: it is read here
   and nowhere else, and the answers of a refused body are fixed sentences. *)
let replacement_key_of_body body =
  match Yojson.Safe.from_string body with
  | `Assoc [ ("key", `String key) ] ->
    (match Runtime_api_key_file.key_of_string key with
     | Some key -> Ok key
     | None -> Error not_a_key)
  | (_ : Yojson.Safe.t) -> Error replacement_invalid_request
  | exception Yojson.Json_error (_ : string) -> Error replacement_invalid_request
;;

let replacement_refused =
  refused
    R.Forbidden_403
    ~code:"replacement_refused"
    "Your account is not active, or an action that restricts it has not finished, so it replaces no key."
;;

let replacement_not_recorded =
  refused
    R.Service_unavailable_503
    ~code:"replacement_not_recorded"
    "The replacement could not be recorded, and the key of the account was not changed. Send the key \
     again."
;;

(* A folder that is not there for this server, or is not a private folder
   of its user, is the server's to mend: the same request gets the same
   answer until then. An error that passes is answered so too, so the
   sentence leaves the next request to the person. *)
let files_not_reached =
  refused
    R.Service_unavailable_503
    ~code:"files_not_reached"
    "This server could not use the folder of this account. Nothing was recorded, and the key of the \
     account was not changed. If the answer stays the same, tell the person who runs this server."
;;

let replacement_unexpected =
  refused
    R.Internal_error_500
    ~code:"internal_error"
    "The replacement was refused for a reason this server does not expect. The key of the account was \
     not changed."
;;

(* What the records of the account say of a replacement its owner asks for.
   An account of another person answers as one that is not there. *)
let replacement_refusal : Accounts.refusal -> R.answer = function
  | Accounts.Not_linked (_ : Authz_types.Provider_account_id.t)
  | Accounts.Not_the_owner (_ : Authz_types.Provider_account_id.t)
  | Accounts.Account_removed (_ : Authz_types.Provider_account_id.t) -> unknown_account
  | Accounts.Not_a_key_account (_ : Authz_types.Provider_account_id.t) ->
    refused
      R.Bad_request_400
      ~code:"not_a_key_account"
      "This account holds a login. Only the key of an account that holds a key is replaced here."
  | Accounts.Removal_stopped (_ : Authz_types.Provider_account_id.t) ->
    refused
      R.Conflict_409
      ~code:"removal_left"
      "A removal of this account did not go through, so its key is not replaced. Remove the account."
  | Accounts.User_not_active (_ : Authz_types.User_id.t) -> replacement_refused
  | Accounts.Already_linked (_ : Authz_types.Provider_account_id.t)
  | Accounts.Linked_for_another { author = _; user_id = _ }
  | Accounts.Not_a_human (_ : Authz_types.Principal.t)
  | Accounts.Not_an_account_author (_ : Authz_records.Author.t)
  | Accounts.Replaced_for_another { author = _; user_id = _ }
  | Accounts.Generation_not_next { held = _; given = _ } ->
    (* The person replaces a key of their own, as a person, for the
       generation after the one read inside the call of the account. *)
    replacement_unexpected
;;

(* The details of each failure are in the log ({!Replacement.replace}). *)
let replacement_error person : Replacement.error -> R.answer = function
  | Replacement.Refused refusal -> replacement_refusal refusal
  | Replacement.Account_busy ->
    refused
      R.Conflict_409
      ~code:"account_call_running"
      "A call of this account is running. Try again when it ends."
  | Replacement.Files_not_reached -> files_not_reached
  | Replacement.Not_recorded error ->
    (match not_recorded_of error with
     | Refused_by_state refusal ->
       (match state_refusal refusal with
        | Person_not_writing -> replacement_refused
        | Log_not_writing -> replacement_not_recorded
        | Of_account refusal -> replacement_refusal refusal
        | No_request_leads_here -> replacement_unexpected)
     | Not_built -> replacement_unexpected
     | Store_did_not_take -> not_taken person ~asked_again:replacement_not_recorded)
  | Replacement.Key_not_stored ->
    refused
      R.Service_unavailable_503
      ~code:"key_not_stored"
      "The replacement was recorded, and the new key could not be stored on this server. The key the \
       account had is not used any more. Send the key again."
;;

let replace ~person ~base_path ~provider_account_id ~body =
  match Authz_types.Provider_account_id.of_string provider_account_id with
  | Error (_ : Authz_id.error) -> unknown_account
  | Ok id ->
    (match replacement_key_of_body body with
     | Error answer -> answer
     | Ok key ->
       (match Replacement.replace ~person ~base_path id key with
        | Ok { Replacement.old_keys_removed } ->
          R.json
            R.Ok_200
            [ "provider_account_id", `String provider_account_id; "old_keys_removed", `Bool old_keys_removed ]
        | Error error -> replacement_error person error))
;;

