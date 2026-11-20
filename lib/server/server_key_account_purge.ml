(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
module Login = Server_setup_account_login
module Event = Authz_purge_event
module Purges = Authz_purge_state
module Accounts = Authz_provider_account_state
module Files = Runtime_key_account_files

type error =
  | Not_found
  | Not_a_key_account
  | Account_busy
  | Not_started of Authz_purge.error
  | Not_ended of Authz_purge.error
  | Files_not_removed of Event.account_failed_stage

let account_of (person : Login.person) provider_account_id : Event.account =
  { owner = person.user_id; provider_account_id }
;;

let target person id = Event.Provider_account (account_of person id)

let state_of (person : Login.person) = (Authz_zone.snapshot person.zone).Authz_zone.state

let status_of person id =
  Purges.find_account (state_of person).Authz_state.purges (account_of person id)
;;

let runtime_root_of (person : Login.person) ~base_path =
  Runtime_account_home_layout.person_runtime_root ~base_path ~namespace:person.namespace
;;

(* The details can name paths of the server (issue #50018), so they go to the
   log and not to the person. *)
let logged id what detail =
  Log.Server.warn "The removal of account %s: %s: %s" (Provider_account_id.to_string id) what detail
;;

let home_kind_of_integration config integration_id =
  match config with
  | Some config -> Login.key_account_home_kind config ~integration_id
  | None -> Files.Claude_home
;;

let home_kind_of_account person ~base_path id =
  match Accounts.find (state_of person).Authz_state.provider_accounts id with
  | Some { Accounts.kind = Accounts.Key { integration_id; generation = _ }; owner = _ } ->
    Login.key_account_home_kind_at ~base_path ~integration_id
  | Some { Accounts.kind = Accounts.Login { integration_id = _ }; owner = _ }
  | None -> Files.Claude_home
;;

(* The second and the third step: the files, and the record of the end. It
   takes the call of the account, inside which the files of an account
   change. *)
let finish ?home (_ : Runtime_account_call.t) (person : Login.person) ~base_path id =
  let account = account_of person id in
  let home =
    match home with
    | Some home -> home
    | None -> home_kind_of_account person ~base_path id
  in
  let ended written ~then_ =
    match written with
    | Ok () -> then_
    | Error error ->
      logged id "the end was not recorded" (Authz_purge.error_detail error);
      Error (Not_ended error)
  in
  match Files.remove ~home ~runtime_root:(runtime_root_of person ~base_path) ~account_id:id with
  | Ok () -> ended (Authz_purge.purged person.zone (Event.Account_purged { account })) ~then_:(Ok ())
  | Error stayed ->
    let failed_stage, detail =
      match stayed with
      | Files.Key_not_removed detail -> Event.Key_not_removed, detail
      | Files.Home_not_removed detail -> Event.Home_not_removed, detail
    in
    logged id "its files were not all removed" detail;
    ended
      (Authz_purge.failed person.zone (Event.Account_not_purged { account; failed_stage }))
      ~then_:(Error (Files_not_removed failed_stage))
;;

(* Whether [id] names a key account of the person. The files of a removal
   are those of a key account ([Files]), so no other account is removed
   here. *)
let key_account_of (person : Login.person) id =
  match Authz_provider_account_state.find (state_of person).Authz_state.provider_accounts id with
  | Some { Authz_provider_account_state.owner; kind } when User_id.equal owner person.user_id ->
    (match kind with
     | Authz_provider_account_state.Login { integration_id = _ } -> Error Not_a_key_account
     | Authz_provider_account_state.Key { integration_id = _; generation = _ } -> Ok ())
  | Some (_ : Authz_provider_account_state.account) | None -> Error Not_found
;;

let remove_in_call ?home in_call ~(person : Login.person) ~base_path id =
  let finish () = finish ?home in_call person ~base_path id in
  let start () =
    match Authz_purge.start person.zone ~user_id:person.user_id (target person id) with
    | Ok () -> finish ()
    | Error error ->
      (* The published state tells whether the record went into the log: a
         commit can answer an error after its record went in, as when the
         store did not take the end of the commit. *)
      (match status_of person id with
       | Some Purges.Account_pending ->
         logged id "its start was recorded, and the commit answered" (Authz_purge.error_detail error);
         finish ()
       | Some (Purges.Account_failed { failed_stage = _ } | Purges.Account_purged) | None ->
         logged id "it was not started" (Authz_purge.error_detail error);
         Error (Not_started error))
  in
  (* Read inside the call, whoever holds it: the records of that time say
     whose the account is and of which kind. *)
  match key_account_of person id with
  | Error refusal -> Error refusal
  | Ok () ->
    (match status_of person id with
     | None | Some (Purges.Account_failed { failed_stage = _ }) -> start ()
     | Some Purges.Account_pending -> finish ()
     | Some Purges.Account_purged -> Error Not_found)
;;

let remove ~(person : Login.person) ~base_path id =
  (* Asked before the call is taken, so whether a call of another person's
     account runs is not told. *)
  match key_account_of person id with
  | Error refusal -> Error refusal
  | Ok () ->
    Runtime_account_call.one_call_of id ~busy:Account_busy (fun in_call -> remove_in_call in_call ~person ~base_path id)
;;

(* A place that could not be looked at is left as it is: a removal that went
   through stays so. *)
let not_looked_at id detail =
  logged id "its files were not looked at, so a restore of them is not undone" detail
;;

(* The status is judged again inside the call of the account, where the
   removal of the owner runs too, so the two do not both end it. *)
let resume_one ~zone ~base_path ~owner ~namespace ~home id =
  let person = { Login.zone; user_id = owner; namespace } in
  let name = Provider_account_id.to_string id in
  let ended in_call = Result.map (fun () -> true) (finish ~home in_call person ~base_path id) in
  match
    Runtime_account_call.one_call_of id ~busy:Account_busy (fun in_call ->
      match status_of person id with
      | Some Purges.Account_pending -> ended in_call
      | Some Purges.Account_purged ->
        (match Files.present ~home ~runtime_root:(runtime_root_of person ~base_path) ~account_id:id with
         | Ok true -> ended in_call
         | Ok false -> Ok false
         | Error detail ->
           not_looked_at id detail;
           Ok false)
      | Some (Purges.Account_failed { failed_stage = _ }) | None -> Ok false)
  with
  | Ok true -> Log.Server.info "The removal of account %s ended at the start of the server" name
  | Ok false -> ()
  | Error Account_busy ->
    Log.Server.warn
      "The removal of account %s was not resumed: a call of the account runs. The next start of \
       the server ends it, and so does a removal by its owner while it is pending."
      name
  | Error (Files_not_removed (_ : Event.account_failed_stage) | Not_ended (_ : Authz_purge.error)) ->
    (* {!finish} logged the detail. *)
    ()
  | Error (Not_found | Not_a_key_account | Not_started (_ : Authz_purge.error)) ->
    (* Only a removal by its owner answers these. *)
    Log.Server.warn "The removal of account %s was not resumed" name
;;

(* An exception of one removal would end the switch of the server, and at
   each start again, since the record it came from is still there. It goes
   to the log, and the removal stays as it is, for the next start or its
   owner, as the removals of the other records go on. *)
let guarded id f =
  match f () with
  | () -> ()
  | exception ((Eio.Cancel.Cancelled _ | Out_of_memory | Stack_overflow | Sys.Break) as exn) ->
    Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | exception exn ->
    Log.Server.warn
      "The removal of account %s was not resumed: %s"
      (Provider_account_id.to_string id)
      (Printexc.to_string exn)
;;

let resume ~zone ~base_path =
  let state = (Authz_zone.snapshot zone).Authz_zone.state in
  let config = Result.to_option (Server_runtime_setup_actions.config ~base_path) in
  let home_of id =
    match Accounts.find state.Authz_state.provider_accounts id with
    | Some { Accounts.kind = Accounts.Key { integration_id; generation = _ }; owner = _ } ->
      home_kind_of_integration config integration_id
    | Some { Accounts.kind = Accounts.Login { integration_id = _ }; owner = _ }
    | None -> Files.Claude_home
  in
  (* An owner wrote [Purge_pending] while active, so with a membership. A
     deletion of the principal takes it out, and with it the one name of
     the folder of their files. *)
  let namespace_of owner =
    Option.map
      (fun membership -> membership.Authz_principal_state.account_home_namespace)
      (Authz_principal_state.find_membership state.Authz_state.principals owner)
  in
  List.iter
    (fun (({ owner; provider_account_id = id } : Event.account), (status : Purges.account_status)) ->
       guarded id @@ fun () ->
       let home = home_of id in
       match status, namespace_of owner with
       | Purges.Account_pending, Some namespace ->
         resume_one ~zone ~base_path ~owner ~namespace ~home id
       | Purges.Account_purged, Some namespace ->
         (* An account that went through and is not back takes no call. *)
         (match
            Files.present
              ~home
              ~runtime_root:(runtime_root_of { Login.zone; user_id = owner; namespace } ~base_path)
              ~account_id:id
          with
          | Ok true -> resume_one ~zone ~base_path ~owner ~namespace ~home id
          | Ok false -> ()
          | Error detail -> not_looked_at id detail)
       | Purges.Account_pending, None ->
         Log.Server.warn
           "The removal of account %s was not resumed: its owner has no membership, so nothing \
            names the folder of their files"
           (Provider_account_id.to_string id)
       | Purges.Account_purged, None -> ()
       | Purges.Account_failed { failed_stage = _ }, (Some _ | None) ->
         (* Its owner asks for the removal again. *)
         ())
    (Purges.accounts state.Authz_state.purges)
;;
