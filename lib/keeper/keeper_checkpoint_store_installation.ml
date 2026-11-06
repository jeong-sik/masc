open Keeper_checkpoint_store_ref_errors

type checkpoint_cas_error =
  | Source_unavailable of checkpoint_ref_load_error
  | Source_changed of Keeper_checkpoint_ref.t
  | Candidate_identity_invalid of checkpoint_identity_error
  | Candidate_session_mismatch of
      { expected : Keeper_id.Trace_id.t
      ; candidate : Keeper_id.Trace_id.t
      }
   | Candidate_turn_regressed of
       { source_turn : int
       ; candidate_turn : int
       }
   | Candidate_unencodable of Agent_core.Error.t
   | Candidate_content_mismatch of
       { reference : Keeper_checkpoint_ref.t
       ; content : string
       }
   | Objects_not_installed of Keeper_checkpoint_object_store.write_error
   | Commit_not_installed of Keeper_fs.durable_write_error

type checkpoint_installation_auxiliary =
  | Commit_durability_unknown of Keeper_fs.durable_write_error
  | Commit_observer_failed of Eio.Exn.with_bt
  | Release_process_lock_failed of File_lock_eio.durable_lock_error
  | Post_commit_unwind_interrupted of Eio.Exn.with_bt

type not_installed_checkpoint =
  { cause : checkpoint_cas_error
  ; auxiliary : checkpoint_installation_auxiliary list
  }

type installed_checkpoint =
  { installed_ref : Keeper_checkpoint_ref.t
  ; auxiliary : checkpoint_installation_auxiliary list
  }

type checkpoint_installation =
  | Not_installed of not_installed_checkpoint
  | Installed of installed_checkpoint

let checkpoint_installation_auxiliary_to_string = function
  | Commit_durability_unknown error ->
    "commit durability unknown: " ^ Keeper_fs.durable_write_error_to_string error
  | Commit_observer_failed (exn, _backtrace) ->
    "commit observer failed: " ^ Printexc.to_string exn
  | Release_process_lock_failed error ->
    "checkpoint lock release failed: " ^ File_lock_eio.durable_lock_error_to_string error
  | Post_commit_unwind_interrupted (exn, _backtrace) ->
    "post-commit unwind interrupted: " ^ Printexc.to_string exn
;;

(* Whether the head's bytes are known to be on disk. Only a writer error after
   the rename leaves that open; the observer, the lock release and the unwind
   all run after Keeper_fs reports the commit durable. *)
let leaves_commit_durability_open = function
  | Commit_durability_unknown _ -> true
  | Commit_observer_failed _ | Release_process_lock_failed _
  | Post_commit_unwind_interrupted _ -> false
;;

let require_confirmed_installation installation =
  let auxiliary = match installation with
    | Installed installed -> installed.auxiliary
    | Not_installed refused -> refused.auxiliary in
  List.iter (function
    | Commit_observer_failed ((Eio.Cancel.Cancelled _ as cause), backtrace)
    | Post_commit_unwind_interrupted ((Eio.Cancel.Cancelled _ as cause), backtrace) ->
      Printexc.raise_with_backtrace cause backtrace
    | Commit_observer_failed _ | Post_commit_unwind_interrupted _
    | Commit_durability_unknown _ | Release_process_lock_failed _ -> ()) auxiliary;
  match installation with
  | Not_installed _ -> Error installation
  | Installed installed ->
    if List.exists leaves_commit_durability_open installed.auxiliary
    then Error installation
    else (
      (* The turn goes on with a durable head, so this is where a failure that
         happened after the commit is still written down. *)
      List.iter
        (fun fact ->
          Log.Keeper.warn "checkpoint %s installed durably; %s"
            installed.installed_ref.Keeper_checkpoint_ref.sha256
            (checkpoint_installation_auxiliary_to_string fact))
        installed.auxiliary;
      Ok installed.installed_ref)

let not_installed cause = Not_installed { cause; auxiliary = [] }

let append_installation_auxiliary installation auxiliary =
  match installation with
  | Not_installed outcome ->
    Not_installed
      { outcome with
        auxiliary = outcome.auxiliary @ [ auxiliary ]
      }
  | Installed outcome ->
    Installed
      { outcome with
        auxiliary = outcome.auxiliary @ [ auxiliary ]
      }
;;
