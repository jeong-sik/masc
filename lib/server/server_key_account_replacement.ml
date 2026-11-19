(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
module Login = Server_setup_account_login
module Files = Runtime_key_account_files
module Accounts = Authz_provider_account_state

let ( let* ) = Result.bind

type error =
  | Refused of Accounts.refusal
  | Account_busy
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

(* The third and the fourth step. From the record on, the key of the
   generation before is not read, so an error here leaves the account with
   no key until the person sends one again. *)
let stored (person : Login.person) ~base_path id ~generation key =
  match Login.person_runtime_root person ~base_path with
  | Error (_ : string) ->
    logged id "its record went in, and its key was not stored" "the runtime root of the person was not made";
    Error Key_not_stored
  | Ok runtime_root ->
    (match Files.replace ~runtime_root ~account_id:id ~generation key with
     | Ok Files.Other_keys_removed -> Ok { old_keys_removed = true }
     | Ok (Files.Other_keys_left detail) ->
       logged id "its new key is in place, and a file of the folder of its keys stays" detail;
       Ok { old_keys_removed = false }
     | Error error ->
       logged id "its record went in, and its key was not stored" (Files.make_error_detail error);
       Error Key_not_stored)
;;

let replace ~(person : Login.person) ~base_path id key =
  (* Asked before the call is taken, so whether a call of another person's
     account runs is not told. *)
  let* (_ : Key_generation.t) = held person id in
  Login.one_call_of id ~busy:Account_busy (fun (_ : Login.in_call) ->
    (* Read again inside the call, whoever holds it: the records of that
       time say whose the account is and which generation it holds. *)
    let* before = held person id in
    let* generation = recorded person id ~held:before in
    stored person ~base_path id ~generation key)
;;

(* ---- the start of the server ---- *)

type left =
  | Call_running
  | Stayed of string

(* Read inside the call of the account, where a replacement of its key runs
   too: the generation of that time names the one file that stays. The
   runtime root is spelled and not made, so an account with no file gets
   none. An owner with no membership has no name for the folder of their
   files: there is nothing of theirs to look at.

   The account of a removal that began or went through is looked at too.
   The removal takes every file of it, whichever of the two runs first. *)
let remove_left_keys_of ~zone ~base_path id =
  Login.one_call_of id ~busy:Call_running (fun (_ : Login.in_call) ->
    let state = (Authz_zone.snapshot zone).Authz_zone.state in
    match Accounts.find state.Authz_state.provider_accounts id with
    | None | Some { Accounts.owner = _; kind = Accounts.Login } -> Ok 0
    | Some { Accounts.owner; kind = Accounts.Key { integration_id = _; generation } } ->
      (match Authz_principal_state.find_membership state.Authz_state.principals owner with
       | None -> Ok 0
       | Some { Authz_principal_state.workspace_id = _; account_home_namespace = namespace } ->
         Files.remove_other_keys
           ~runtime_root:(Runtime_account_home_layout.person_runtime_root ~base_path ~namespace)
           ~account_id:id
           ~generation
         |> Result.map_error (fun detail -> Stayed detail)))
;;

(* An exception of one account would end the switch of the server, and at
   each start again. It goes to the log, and the accounts after it are
   looked at. *)
let guarded id f =
  match f () with
  | () -> ()
  | exception ((Eio.Cancel.Cancelled _ | Out_of_memory | Stack_overflow | Sys.Break) as exn) ->
    Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | exception exn -> logged id "the files of its keys were not looked at" (Printexc.to_string exn)
;;

let remove_left_keys ~zone ~base_path =
  List.iter
    (fun id ->
      guarded id
      @@ fun () ->
      match remove_left_keys_of ~zone ~base_path id with
      | Ok 0 -> ()
      | Ok gone ->
        (* A file that held a key went with no request of its owner, so the
           log of the server says it. *)
        Log.Server.info
          "The start of the server removed %d of the files of the folder of the keys of account %s: \
           none of them is the key its records say"
          gone
          (Provider_account_id.to_string id)
      | Error Call_running ->
        (* The call can be a replacement, which removes them itself. The
           next start looks again. *)
        Log.Server.debug
          "The files of the keys of account %s were not looked at: a call of the account runs"
          (Provider_account_id.to_string id)
      | Error (Stayed detail) -> logged id "a file of the folder of its keys stays" detail)
    (Accounts.key_accounts (Authz_zone.snapshot zone).Authz_zone.state.Authz_state.provider_accounts)
;;
