(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
module Login = Server_setup_account_login
module Purge = Server_key_account_purge
module Files = Runtime_key_account_files
module Accounts = Authz_provider_account_state

let ( let* ) = Result.bind

type error =
  | Id_not_usable
  | Not_recorded of Authz_provider_account.error
  | Files_not_made
  | Account_stays of
      { provider_account_id : Provider_account_id.t
      ; removal : Purge.error
      }

(* No line of this module is given the key. The details can name paths of
   the server (issue #50018), so they go to the log and not to the person. *)
let logged id what detail =
  Log.Server.warn
    "The registration of key account %s: %s: %s"
    (Provider_account_id.to_string id)
    what
    detail
;;

(* The generation the records give the account, when the published state
   holds it as a key account of the person. *)
let generation_of (person : Login.person) id =
  let state = (Authz_zone.snapshot person.zone).Authz_zone.state in
  match Accounts.find state.Authz_state.provider_accounts id with
  | Some { Accounts.owner; kind = Accounts.Key { integration_id = _; generation } }
    when User_id.equal owner person.user_id -> Some generation
  | Some
      { Accounts.owner = _
      ; kind =
          Accounts.Key { integration_id = _; generation = _ } | Accounts.Login { integration_id = _ }
      }
  | None -> None
;;

(* The second step, and the generation of the key the record names.

   A commit that answers [Ok] published the state with its record before it
   answered ({!Authz_zone.commit}), and a [key_linked] record gives its
   account the first generation ({!Authz_types.Key_generation}). A commit
   can also answer an error after its record went in, as when the store did
   not take the end of the commit: the published state tells then. *)
let recorded (person : Login.person) id ~integration_id =
  match
    Authz_provider_account.link_key
      person.zone
      ~user_id:person.user_id
      ~provider_account_id:id
      ~integration_id
  with
  | Ok () -> Ok Key_generation.first
  | Error error ->
    (match generation_of person id with
     | Some generation ->
       logged
         id
         "its record went in, and the commit answered"
         (Authz_provider_account.error_to_string error);
       Ok generation
     | None ->
       logged id "it was not recorded" (Authz_provider_account.error_to_string error);
       Error (Not_recorded error))
;;

(* The third step: the runtime root of the person, the home of the account
   (when the provider carries a CLI home), and then its key file. *)
let made ~home (person : Login.person) ~base_path id ~generation key =
  match Login.person_runtime_root person ~base_path with
  | Error (_ : string) -> Error "the runtime root of the person was not made"
  | Ok runtime_root ->
    Files.make_for ~home ~runtime_root ~account_id:id ~generation key |> Result.map_error Files.make_error_detail
;;

let register ?(home = Files.Claude_home) ~(person : Login.person) ~base_path ~integration_id key =
  match Provider_account_id.of_string (Auth.generate_token ()) with
  | Error (_ : Authz_id.error) -> Error Id_not_usable
  | Ok id ->
    (* No call runs under an id that was just drawn. The call is held for
       what comes after the record: from then on the list of the person
       names the account, and a verification, a turn or a removal of it
       answers that a call runs until the files are there. *)
    Runtime_account_call.one_call_of id ~busy:Id_not_usable (fun in_call ->
      let* generation = recorded person id ~integration_id in
      match made ~home person ~base_path id ~generation key with
      | Ok () -> Ok id
      | Error detail ->
        logged id "its files were not all made, and its removal starts" detail;
        (match Purge.remove_in_call ~home in_call ~person ~base_path id with
         | Ok () -> Error Files_not_made
         | Error removal -> Error (Account_stays { provider_account_id = id; removal })))
;;
