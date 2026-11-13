(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
module Login = Server_setup_account_login
module Conversation = Server_keeper_conversation
module Event = Authz_purge_event
module Purges = Authz_purge_state

(* A bound over a CLI that stays silent. A purge that does not end within it
   leaves the copy [may_remain]; no measurement of the CLI chose it. *)
let vendor_timeout_s = 60.0

type standing =
  | Kept
  | Deletion_failed
  | Deleted

type error =
  | Not_found
  | Account_busy
  | Record_unavailable of Conversation.error
  | Not_started of Authz_purge.error
  | Not_ended of Authz_purge.error
  | Directory_not_removed of Event.vendor_copy

let target (person : Login.person) conversation_id =
  Event.Keeper_conversation { owner = person.user_id; conversation_id }
;;

let status_of (person : Login.person) conversation_id =
  Purges.find
    (Authz_zone.snapshot person.zone).Authz_zone.state.Authz_state.purges
    (target person conversation_id)
;;

let standing person conversation_id =
  match status_of person conversation_id with
  | None -> Kept
  | Some (Purges.Failed { failed_stage = _; vendor_copy = _ }) -> Deletion_failed
  | Some (Purges.Pending { earlier_vendor_copy = _ } | Purges.Purged { vendor_copy = _ }) -> Deleted
;;

let deletion_began person conversation_id =
  match standing person conversation_id with
  | Kept -> false
  | Deletion_failed | Deleted -> true
;;

(* Where the step of the copy of the vendor starts from. *)
type since =
  | Fresh  (* This deletion wrote [Purge_pending]: nothing was removed before it. *)
  | After_stop
      (* A deletion stopped after its [Purge_pending], and may have removed a
         part of the directory. *)
  | After_failure of Event.vendor_copy
      (* A deletion before this one failed, and wrote this of the copy. No
         turn went on in the conversation after it. *)

let client_mgr clock =
  Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds:Process_eio.child_exit_grace_seconds
;;

(* The details can name paths of the server (issue #50018), so they go to the
   log and not to the person. *)
let logged (conversation : Conversation.conversation) what detail =
  Log.Server.warn
    "The deletion of conversation %s: %s: %s"
    (Conversation_id.to_string conversation.conversation_id)
    what
    detail
;;

(* The Runtime of the person on the account the conversation began on gives
   the CLI and the home its turns ran with. *)
let execution_of (person : Login.person) ~base_path provider_account_id =
  let state = (Authz_zone.snapshot person.zone).Authz_zone.state in
  match
    List.find_opt
      (fun ((_ : Runtime_id.t), (runtime : Authz_runtime_state.runtime)) ->
         Provider_account_id.equal runtime.provider_account_id provider_account_id)
      (Authz_runtime_state.owned_by state.Authz_state.runtimes person.user_id)
  with
  | None -> Error "the person has no Runtime on the account of the conversation"
  | Some (runtime_id, (_ : Authz_runtime_state.runtime)) ->
    (match
       Login.person_runtime
         person
         ~base_path
         ~provider_account_id
         ~binding:(Runtime_account_runtime.Runtime (Runtime_id.to_string runtime_id))
     with
     | Error ((`Bad_request | `Not_found | `Service_unavailable), sentence) -> Error sentence
     | Ok prepared ->
       (match prepared.Login.runtime.Runtime_instance.execution with
        | Runtime_execution.Claude_code execution -> Ok execution
        | Runtime_execution.Agent_core _
        | Runtime_execution.Codex_app_server _
        | Runtime_execution.Antigravity_cli _
        | Runtime_execution.Muse_serve _
        | Runtime_execution.Vibe_cli _ ->
          (* Only a turn of Claude Code records a conversation. *)
          Error "the Runtime of the account is not a Claude Code Runtime"))
;;

(* Claude Code purges the project the turns of the conversation started in,
   on the home of the account they ran on. Anything that keeps it from
   exiting 0 leaves the copy [may_remain]. *)
let purge_vendor_copy ~env (person : Login.person) ~base_path ~records conversation =
  let kept detail =
    logged conversation "the copy of the vendor may remain" detail;
    Event.May_remain
  in
  let provider_account_id = conversation.Conversation.provider_account_id in
  match execution_of person ~base_path provider_account_id with
  | Error detail -> kept detail
  | Ok (execution : Runtime_execution.claude_code) ->
    (match
       Runtime_account_access.authorize
         (Runtime_account_access.Own_account { user_id = person.user_id; provider_account_id })
         execution.account_home
     with
     | Error refusal -> kept (Runtime_account_access.refusal_to_string refusal)
     | Ok account ->
       (match Conversation.project_path records conversation with
        | Error error -> kept (Conversation.error_to_string error)
        | Ok project ->
          let clock = Eio.Stdenv.clock env in
          (match
             Runtime_claude_code.purge_project
               ~mgr:(client_mgr clock)
               ~clock
               ~cwd:Eio.Path.(Eio.Stdenv.fs env / Filename.get_temp_dir_name ())
               ~account
               ~cli_path:execution.cli_path
               ~timeout_s:vendor_timeout_s
               ~project
           with
           | Runtime_claude_code.Project_purged -> Event.Removed
           | Runtime_claude_code.Project_not_purged detail -> kept detail)))
;;

(* The third step. A turns file that was not read says nothing, so the CLI
   is asked as if a client had been reached. *)
let vendor_copy ~since ~reach ~purge =
  match since with
  | After_failure ((Event.Removed | Event.No_copy) as copy) -> copy
  | After_failure Event.May_remain -> purge ()
  | Fresh ->
    (match reach () with
     | Some Conversation.Reached | None -> purge ()
     | Some (Conversation.Not_reached | Conversation.No_record) -> Event.No_copy)
  | After_stop ->
    (* The deletion that stopped may have removed the turns file. *)
    (match reach () with
     | Some (Conversation.Reached | Conversation.No_record) | None -> purge ()
     | Some Conversation.Not_reached -> Event.No_copy)
;;

(* The third to the fifth step: the copy of the vendor, the directory, and
   the record of the end. *)
let finish ~env (person : Login.person) ~base_path ~records conversation ~since =
  let reach () =
    match Conversation.client_reach records conversation with
    | Ok reach -> Some reach
    | Error error ->
      logged conversation "its turns were not read" (Conversation.error_to_string error);
      None
  in
  let vendor_copy =
    vendor_copy ~since ~reach ~purge:(fun () ->
      purge_vendor_copy ~env person ~base_path ~records conversation)
  in
  let target = target person conversation.Conversation.conversation_id in
  let ended written ~then_ =
    match written with
    | Ok () -> then_
    | Error error ->
      logged conversation "the end was not recorded" (Authz_purge.error_detail error);
      Error (Not_ended error)
  in
  match Conversation.remove records conversation with
  | Ok () -> ended (Authz_purge.purged person.zone target ~vendor_copy) ~then_:(Ok vendor_copy)
  | Error detail ->
    logged conversation "its directory was not removed" detail;
    ended
      (Authz_purge.failed person.zone target ~failed_stage:Event.Folder_not_removed ~vendor_copy)
      ~then_:(Error (Directory_not_removed vendor_copy))
;;

let delete ~env ~(person : Login.person) ~base_path conversation_id =
  let records = Conversation.root ~base_path ~namespace:person.namespace in
  match Conversation.find records conversation_id with
  | Error error ->
    Log.Server.warn
      "The deletion of conversation %s: the conversations were not read: %s"
      (Conversation_id.to_string conversation_id)
      (Conversation.error_to_string error);
    Error (Record_unavailable error)
  | Ok None -> Error Not_found
  | Ok (Some conversation) ->
    Login.one_call_of conversation.Conversation.provider_account_id ~busy:Account_busy (fun () ->
      let finish since = finish ~env person ~base_path ~records conversation ~since in
      let start since =
        match Authz_purge.start person.zone ~user_id:person.user_id (target person conversation_id) with
        | Ok () -> finish since
        | Error error ->
          logged conversation "it was not started" (Authz_purge.error_detail error);
          Error (Not_started error)
      in
      match status_of person conversation_id with
      | None -> start Fresh
      | Some (Purges.Failed { vendor_copy; failed_stage = Event.Folder_not_removed }) ->
        start (After_failure vendor_copy)
      | Some (Purges.Pending { earlier_vendor_copy = None }) -> finish After_stop
      | Some (Purges.Pending { earlier_vendor_copy = Some copy }) -> finish (After_failure copy)
      | Some (Purges.Purged { vendor_copy = _ }) -> Error Not_found)
;;
