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

   [Workspace.init] runs this at boot. Raising the counter loses nothing: the
   numbers between are simply never issued, and the store, not the counter,
   is what says which messages exist. A counter already at or above the store
   is left exactly as it is.

   It holds the state lock that [next_seq] takes, from reading the counter
   to writing it. Without it a message numbered in between could have its
   number written over by an older read, and the counter would step back.
   The store is read before the lock: a message numbered after that read
   only raises the counter, and a counter at or above the store is not
   written. *)
let reconcile_message_seq config path =
  let filed = resume_message_seq config in
  if filed > 0 then
    with_file_lock config path @@ fun () ->
    match read_json config path with
    (* Cancellation is not an unreadable file. Absorbing it here would let a
       shutdown look like state this function chose not to repair, which is the
       swallow this repo models in TLA+ as CancelledAbsorbed. *)
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
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

(* The backlog a workspace starts with. *)
let empty_backlog () = { tasks = []; task_creation_receipts = []; task_deletion_receipts = []; pending_completion_approvals = []; pending_completion_rejections = []; last_updated = now_iso (); version = 1 }

