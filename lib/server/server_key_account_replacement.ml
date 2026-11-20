(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
module Login = Server_setup_account_login
module Files = Runtime_key_account_files
module Accounts = Authz_provider_account_state

let ( let* ) = Result.bind

type error =
  | Refused of Accounts.refusal
  | Account_busy
  | Files_not_reached
  | Not_recorded of Authz_provider_account.error
  | Key_not_stored

type replaced = { old_keys_removed : bool }

(* No line of this module is given the key. The details can name paths of
   the server (issue #50018), so they go to the log and not to the person. *)
let logged id what detail =
  Log.Server.warn
    "The replacement of the key of account %s: %s: %s"
    (Provider_account_id.to_string id)
    what
    detail
;;

let state_of (person : Login.person) = (Authz_zone.snapshot person.zone).Authz_zone.state

(* The first step: whose the account is, of which kind, and what a removal
   left on it, as the published state says, with the generation it holds. *)
let held (person : Login.person) id =
  Authz_state.key_to_replace (state_of person) ~user_id:person.user_id id
  |> Result.map_error (fun refusal -> Refused refusal)
;;

(* Before the record: the runtime root of the person, and under it the home
   of the account, made or looked at as the store of the key does first
   ({!Files.make_home}). [Login.person_runtime_root] takes a name that is
   there as the root: a link that leads nowhere is one. The home is made
   under the real path of the root, the path the store and the removal of
   the folder of the keys spell theirs from.

   Under a root or a home that is not reached the replacement is turned
   down while no record is written: the store would fail, and the record
   would take the key before out of use and put none in its place. Under
   such a root a store that failed could not clear the folder of the keys
   either. The file of the key stays. Under a home that is no private
   folder of this user every use of the account is refused as well, until
   the folder is mended. The folder of the keys is not looked at here: a
   store that fails there is recorded ([Key_not_stored]). A root that goes
   away between this and the store is not held. *)
let reached (person : Login.person) ~base_path id =
  match Login.person_runtime_root person ~base_path with
  | Error (_ : string) ->
    logged id "it was not recorded" "the runtime root of the person was not made";
    Error Files_not_reached
  | Ok runtime_root ->
    (match Files.make_home ~runtime_root ~account_id:id with
     | Ok () -> Ok runtime_root
     | Error detail ->
       logged id "it was not recorded" ("the home of the account was not reached: " ^ detail);
       Error Files_not_reached)
;;

(* The second step, and the generation the record names.

   A commit that answers [Ok] published the state with its record before it
   answered ({!Authz_zone.commit}). A commit can also answer an error after
   its record went in, as when the store did not take the end of the
   commit: the published state tells then. The generation was read inside
   the call of the account, where no other replacement of it runs, so the
   state holds the one after it only when this record went in. *)
let recorded (person : Login.person) id ~held:before =
  match
    Authz_provider_account.replace_key person.zone ~user_id:person.user_id ~provider_account_id:id
  with
  | Ok generation -> Ok generation
  | Error (Authz_provider_account.Not_replaced refusal) -> Error (Refused refusal)
  | Error (Authz_provider_account.Replace_failed error) ->
    let detail = Authz_provider_account.error_to_string error in
    (match held person id with
     | Ok generation when Key_generation.equal generation (Key_generation.next before) ->
       logged id "its record went in, and the commit answered" detail;
       Ok generation
     | Ok (_ : Key_generation.t) | Error (_ : error) ->
       logged id "it was not recorded" detail;
       Error (Not_recorded error))
;;

(* The third and the fourth step.

   A store that failed: from the record on the key of the generation before
   is not read, and the account is to read no key until the person sends
   one again (RFC 3.7). The folder is not known to hold none. A file of the
   new generation can have been there before the call, and is then what
   the account reads; the key that was sent can be in place with its folder
   not synced. So the folder of the keys goes, as it does first in a
   removal of the account, and the key before goes with it. The next
   replacement makes the folder again. *)
let stored ~runtime_root id ~generation key =
  match Files.replace ~runtime_root ~account_id:id ~generation key with
  | Ok Files.Other_keys_removed -> Ok { old_keys_removed = true }
  | Ok (Files.Other_keys_left detail) ->
    logged id "its new key is in place, and a file of the folder of its keys stays" detail;
    Ok { old_keys_removed = false }
  | Error error ->
    logged id "its record went in, and its key was not stored" (Files.make_error_detail error);
    (match Files.remove_keys ~runtime_root ~account_id:id with
     | Ok () -> ()
     | Error detail -> logged id "its key was not stored, and the folder of its keys stays" detail);
    Error Key_not_stored
;;

let replace ~(person : Login.person) ~base_path id key =
  (* Asked before the call is taken, so whether a call of another person's
     account runs is not told. *)
  let* (_ : Key_generation.t) = held person id in
  Runtime_account_call.one_call_of id ~busy:Account_busy (fun (_ : Runtime_account_call.t) ->
    (* Read again inside the call, whoever holds it: the records of that
       time say whose the account is and which generation it holds. *)
    let* before = held person id in
    let* runtime_root = reached person ~base_path id in
    let* generation = recorded person id ~held:before in
    stored ~runtime_root id ~generation key)
;;

(* ---- the start of the server ---- *)

(* Why the folder of the keys of an account was not looked at. *)
type not_looked_at =
  | Call_running
  | Zone_not_trusted of Authz_zone.uncertain
  | Owner_without_membership
  | Folder_not_read of string

let nothing_there = { Files.gone = 0; stayed = None }

(* Read inside the call of the account, where a replacement of its key runs
   too: the generation of that time names the one file that stays. The
   state is one the zone can be trusted for ([Authz_zone.read]): nothing
   commits here, so nothing else judges the zone.

   The runtime root is spelled and not made, so an account with no file
   gets none. An owner with no membership has no record that names the
   folder of their files: it is not looked at, and what it holds stays
   (issue #53111).

   The account of a removal that began or went through is looked at too.
   The removal takes every file of it, whichever of the two runs first. Of
   such an account whose owner has no membership nothing is said here: a
   removal that is pending says it in its resume, and one that went through
   took the files. Files that came back after it are those of issue
   #53111. *)
let remove_left_keys_of ~zone ~base_path id =
  Runtime_account_call.one_call_of id ~busy:Call_running (fun (_ : Runtime_account_call.t) ->
    match Authz_zone.read zone with
    | Error uncertain -> Error (Zone_not_trusted uncertain)
    | Ok trusted ->
      let state = (trusted :> Authz_zone.snapshot).Authz_zone.state in
      (match Accounts.find state.Authz_state.provider_accounts id with
       | None | Some { Accounts.owner = _; kind = Accounts.Login } -> Ok nothing_there
       | Some { Accounts.owner; kind = Accounts.Key { integration_id = _; generation } } ->
         (match Authz_principal_state.find_membership state.Authz_state.principals owner with
          | Some { Authz_principal_state.workspace_id = _; account_home_namespace = namespace } ->
            Files.remove_other_keys
              ~runtime_root:(Runtime_account_home_layout.person_runtime_root ~base_path ~namespace)
              ~account_id:id
              ~generation
            |> Result.map_error (fun detail -> Folder_not_read detail)
          | None ->
            (match Authz_state.account_removal state ~owner id with
             | Authz_state.Removal_begun -> Ok nothing_there
             | Authz_state.Removal_not_begun
             | Authz_state.Removal_stayed (_ : Authz_purge_event.account_failed_stage)
             | Authz_state.Removal_start_given_up -> Error Owner_without_membership))))
;;

(* The lines of a start say that it is one: no replacement was asked for.
   The same rule holds for them: no key, and a detail that can name a path
   goes to the log alone. *)
let logged_at_start id what detail =
  Log.Server.warn
    "The start of the server, the folder of the keys of account %s: %s: %s"
    (Provider_account_id.to_string id)
    what
    detail
;;

(* What a look at one account says of the accounts after it. *)
type rest =
  | Looked_at_next
  | Left_alone of Authz_zone.uncertain

(* An exception of one account would end the switch of the server, and at
   each start again. It goes to the log, and the accounts after it are
   looked at. *)
let guarded id f =
  match f () with
  | rest -> rest
  | exception ((Eio.Cancel.Cancelled _ | Out_of_memory | Stack_overflow | Sys.Break) as exn) ->
    Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | exception exn ->
    logged_at_start id "it was not looked at" (Printexc.to_string exn);
    Looked_at_next
;;

let remove_left_keys_of_and_say ~zone ~base_path id =
  match remove_left_keys_of ~zone ~base_path id with
  | Ok { Files.gone; stayed } ->
    (* A file that held a key went with no request of its owner, so the log
       of the server says it. *)
    if gone > 0
    then
      Log.Server.info
        "The start of the server removed %d of the files of the folder of the keys of account %s: \
         none of them is the key its records say"
        gone
        (Provider_account_id.to_string id);
    Option.iter (fun detail -> logged_at_start id "a file of it stays" detail) stayed;
    Looked_at_next
  | Error Call_running ->
    (* The call can be a replacement, which removes them itself, and whether
       a file was left is not known: it is no warning. It is said where a
       log of the default level shows it, since a key the owner replaced can
       stay on disk until the next start. *)
    Log.Server.info
      "The start of the server did not look at the folder of the keys of account %s: a call of \
       the account runs. The next start looks again, and so do a replacement of its key and its \
       removal."
      (Provider_account_id.to_string id);
    Looked_at_next
  | Error (Zone_not_trusted uncertain) -> Left_alone uncertain
  | Error Owner_without_membership ->
    Log.Server.warn
      "The start of the server did not look at the folder of the keys of account %s: its owner \
       has no membership, so nothing names the folder of their files"
      (Provider_account_id.to_string id);
    Looked_at_next
  | Error (Folder_not_read detail) ->
    logged_at_start id "it was not looked at" detail;
    Looked_at_next
;;

let remove_left_keys ~zone ~base_path =
  (* The list names the accounts to ask about and decides nothing: each is
     read again, where the zone can be trusted, inside its call.

     A zone that cannot be trusted stays so until a restart reads its files
     again ([Authz_zone.uncertain]). The first account that finds it so is
     the last one asked about, and the one cause is said once. *)
  let rec from = function
    | [] -> ()
    | id :: after ->
      (match guarded id (fun () -> remove_left_keys_of_and_say ~zone ~base_path id) with
       | Looked_at_next -> from after
       | Left_alone uncertain ->
         Log.Server.warn
           "The start of the server looked at no folder of keys from account %s on, %d of the \
            accounts: the authorization zone cannot be trusted now: %s"
           (Provider_account_id.to_string id)
           (List.length after + 1)
           (Authz_zone.uncertain_detail uncertain))
  in
  from (Accounts.key_accounts (Authz_zone.snapshot zone).Authz_zone.state.Authz_state.provider_accounts)
;;
