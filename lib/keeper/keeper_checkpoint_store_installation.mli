(** The result of installing a checkpoint when the file must still hold the
    source the candidate advances.

    [checkpoint_cas_error] says why a candidate was refused: the source
    could not be read or has changed, the candidate's identity, session,
    turn or content is wrong or cannot be encoded, or its objects or commit
    were not written. [checkpoint_installation] is [Not_installed] or
    [Installed]; both carry the [checkpoint_installation_auxiliary] failures
    that happened around the commit. [require_confirmed_installation] gives
    the installed reference when the commit is known to be durable and the
    installation itself otherwise; it re-raises a cancellation caught around
    the commit and logs the other auxiliary failures of a durable install.
    [not_installed] and [append_installation_auxiliary] build and extend an
    installation. [Keeper_checkpoint_store] includes this module. *)

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

val checkpoint_installation_auxiliary_to_string :
  checkpoint_installation_auxiliary -> string

val require_confirmed_installation :
  checkpoint_installation ->
  (Keeper_checkpoint_ref.t, checkpoint_installation) result

val not_installed : checkpoint_cas_error -> checkpoint_installation

val append_installation_auxiliary :
  checkpoint_installation ->
  checkpoint_installation_auxiliary -> checkpoint_installation
