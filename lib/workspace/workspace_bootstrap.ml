(** Workspace Bootstrap - Directory initialization and default state.

    Extracted from workspace_state.ml to isolate the "init or not"
    responsibility from runtime state I/O. *)

open Masc_domain
open Workspace_utils

(* Where the message counter starts when there is no state to read it from.

   The counter is not the authority on what has been said -- the message files
   are -- so a lost counter is recovered from them rather than restarted. Left
   at zero beside a store that already holds messages, every new message takes
   a number below the old ones, and a reader that pages in sequence order
   never reaches it however far back it asks.

   That is not hypothetical. On 2026-08-25 the workspace state was rebuilt at
   04:38:42Z while the store held 2,604 messages. Eight and a half hours of
   broadcasts landed at sequences 1 through 75 and stayed invisible to
   [masc_messages]: keepers asking each other for help, and the answers nobody
   could see they were owed. Seven sequence numbers were issued twice. *)
let resume_message_seq config =
  let dir = messages_dir config in
  match Sys.readdir dir with
  | exception Sys_error _ -> 0
  | names ->
    Array.fold_left
      (fun highest name -> max highest (message_seq_of_filename name))
      0
      names
;;

let default_workspace_state config = {
  protocol_version = "0.1.0";
  project = Filename.basename config.base_path;
  started_at = now_iso ();
  message_seq = resume_message_seq config;
  active_agents = [];
  paused = false;
  pause_reason = None;
  paused_by = None;
  paused_at = None;
  search_strategy_default = Some "best_first_v1";
  speculation_enabled = false;
  speculation_budget = None;
}

(* Pull a counter that fell behind the store back up to it.

   [default_workspace_state] resumes the counter, but only where there is no
   state to read. A workspace that already reset does not pass that way again
   and so never recovers on its own: on 2026-08-25 the live counter sat at 84
   beside 2,604 filed messages for eight and a half hours, and every broadcast
   in that window was filed below everything already there and unreachable to
   a reader paging in sequence order. It took someone editing state.json by
   hand.

   Boot is where that is noticed, because it is the one moment the store and
   the counter are both at rest. Raising the counter loses nothing: the
   numbers between are simply never issued, and the store, not the counter,
   is what says which messages exist. A counter already at or above the store
   is left exactly as it is. *)
let reconcile_message_seq config path =
  let filed = resume_message_seq config in
  if filed > 0 then
    match read_json config path with
    | exception _ ->
      (* Unreadable state is [read_state]'s to repair; it has the typed
         recovery and this does not. *)
      ()
    | `Assoc fields as json ->
      let recorded = Safe_ops.json_int ~default:0 "message_seq" json in
      if recorded < filed then begin
        Log.Misc.warn
          "workspace message counter behind the store (recorded=%d filed=%d): \
           resuming above it"
          recorded
          filed;
        write_json
          config
          path
          (`Assoc
            (List.remove_assoc "message_seq" fields
             @ [ "message_seq", `Int filed ]))
      end
    | _ -> ()
;;

let ensure_workspace_bootstrap config =
  let root_dir = masc_root_dir config in
  let root_agents_dir = Filename.concat root_dir "agents" in
  let root_keepers_dir = Filename.concat root_dir Common.keepers_runtime_dirname in
  let root_traces_dir = Filename.concat root_dir "traces" in
  let root_tasks_dir = Filename.concat root_dir "tasks" in
  let root_messages_dir = Filename.concat root_dir "messages" in
  let root_backlog_path = Filename.concat root_tasks_dir "backlog.json" in
  List.iter mkdir_p
    [
      root_agents_dir;
      root_keepers_dir;
      root_traces_dir;
      root_tasks_dir;
      root_messages_dir;
    ];
  if not (path_exists_root config (root_state_path config)) then
    write_json_root config (root_state_path config)
      (workspace_state_to_yojson (default_workspace_state config));
  if not (path_exists_root config root_backlog_path) then
    write_json_root config root_backlog_path
      (backlog_to_yojson { tasks = []; last_updated = now_iso (); version = 1 });

  let scoped_agents = agents_dir config in
  let scoped_tasks = tasks_dir config in
  let scoped_messages = messages_dir config in
  let scoped_state = state_path config in
  let scoped_backlog = backlog_path config in
  List.iter mkdir_p [ masc_dir config; scoped_agents; scoped_tasks; scoped_messages ];
  if not (path_exists config scoped_state) then
    write_json config scoped_state (workspace_state_to_yojson (default_workspace_state config))
  else reconcile_message_seq config scoped_state;
  if not (path_exists config scoped_backlog) then
    write_json config scoped_backlog
      (backlog_to_yojson { tasks = []; last_updated = now_iso (); version = 1 })
