(** The identity and load errors of a checkpoint reference, their
    renderers, and the saved-history view of a load.

    [checkpoint_identity_error] says why a session id or a reference could
    not be built, and [checkpoint_ref_load_error] says why the checkpoint a
    reference names could not be loaded; each has a [*_to_string] renderer.
    [Saved_history] is the same load seen by a reader of the history: a
    canonical an earlier [checkpoint_version] wrote is the value
    [Saved_history.Superseded], not a failure. [saved_history] and
    [saved_history_of_ref] convert a load result into it, and
    [saved_history_error_to_string] and [saved_history_ref_error_to_string]
    render its errors.
    [Keeper_checkpoint_store] includes this module. *)

open Keeper_checkpoint_store_decode

type checkpoint_identity_error =
  | Session_id_invalid of string
  | Ref_create_failed of Keeper_checkpoint_ref.create_error

type checkpoint_ref_load_error =
  | Ref_not_found
  | Ref_read_failed of checkpoint_load_error
  | Ref_identity_invalid of checkpoint_identity_error
  | Ref_session_mismatch of
      { expected : Keeper_id.Trace_id.t
      ; actual : Keeper_id.Trace_id.t
      }
  | Ref_lock_failed of string

val checkpoint_ref_create_error_to_string :
  Keeper_checkpoint_ref.create_error -> string

val checkpoint_identity_error_to_string : checkpoint_identity_error -> string

val checkpoint_ref_load_error_to_string : checkpoint_ref_load_error -> string

module Saved_history :
  sig
    type 'a t = Read of 'a | Superseded of { expected : int; got : int; }
    type error =
        Not_found
      | Store_error of string
      | Parse_error of string
      | Newer_version of { expected : int; got : int; }
      | Io_error of string
      | Read_failed of {
          cause :
            checkpoint_read_failure;
          detail : string;
        }
      | Agent_core_error of string
      | Objects_invalid of Agent_core.Checkpoint_objects.load_error
    type ref_error =
        Ref_not_found
      | Ref_read_failed of error
      | Ref_identity_invalid of checkpoint_identity_error
      | Ref_session_mismatch of { expected : Keeper_id.Trace_id.t;
          actual : Keeper_id.Trace_id.t;
        }
      | Ref_lock_failed of string
  end

val saved_history :
  ('a, checkpoint_load_error) result ->
  ('a Saved_history.t, Saved_history.error) result

val saved_history_of_ref :
  ('a, checkpoint_ref_load_error) result ->
  ('a Saved_history.t, Saved_history.ref_error) result

val saved_history_error_to_string : Saved_history.error -> string

val saved_history_ref_error_to_string : Saved_history.ref_error -> string
