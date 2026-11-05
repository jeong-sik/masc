module Objects = Agent_core.Checkpoint_objects
open Keeper_checkpoint_store_decode
open Keeper_checkpoint_store_session

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

let checkpoint_ref_create_error_to_string = function
  | Keeper_checkpoint_ref.Negative_turn_count value ->
    Printf.sprintf "negative turn count %d" value
  | Keeper_checkpoint_ref.Invalid_sha256 value ->
    Printf.sprintf "invalid checkpoint sha256 %S" value

let checkpoint_identity_error_to_string = function
  | Session_id_invalid detail -> "invalid session id: " ^ detail
  | Ref_create_failed error -> checkpoint_ref_create_error_to_string error

let checkpoint_ref_load_error_to_string = function
  | Ref_not_found -> "checkpoint not found"
  | Ref_read_failed error -> checkpoint_load_error_to_string error
  | Ref_identity_invalid error -> checkpoint_identity_error_to_string error
  | Ref_session_mismatch { expected; actual } ->
    Printf.sprintf
      "session mismatch expected=%s actual=%s"
      (Keeper_id.Trace_id.to_string expected)
      (Keeper_id.Trace_id.to_string actual)
  | Ref_lock_failed detail -> "checkpoint lock failed: " ^ detail

(* A canonical an earlier [checkpoint_version] wrote is the deliberate hard
   cut, not a failed read: the turn path starts fresh on it and the next save
   replaces it. A reader of the saved history takes the same answer, that
   there is no history this build reads, and settles on it. A keeper whose
   turns save no checkpoint (an official client) never replaces the file, so
   a reader that reported it as unreadable stopped on it at every pass for as
   long as the trace lasted (#44446). *)
module Saved_history = struct
  type 'a t =
    | Read of 'a
    | Superseded of { expected : int; got : int }

  (* The load failures without the cut, so a reader cannot be handed it as
     a failure. *)
  type error =
    | Not_found
    | Store_error of string
    | Parse_error of string
    | Newer_version of { expected : int; got : int }
    | Io_error of string
    | Read_failed of { cause : checkpoint_read_failure; detail : string }
    | Agent_core_error of string
    | Objects_invalid of Objects.load_error

  type ref_error =
    | Ref_not_found
    | Ref_read_failed of error
    | Ref_identity_invalid of checkpoint_identity_error
    | Ref_session_mismatch of
        { expected : Keeper_id.Trace_id.t
        ; actual : Keeper_id.Trace_id.t
        }
    | Ref_lock_failed of string
end

let saved_history = function
  | Ok value -> Ok (Saved_history.Read value)
  | Error (Superseded_version { expected; got }) ->
    Ok (Saved_history.Superseded { expected; got })
  | Error Not_found -> Error Saved_history.Not_found
  | Error (Store_error detail) -> Error (Saved_history.Store_error detail)
  | Error (Parse_error detail) -> Error (Saved_history.Parse_error detail)
  | Error (Newer_version { expected; got }) ->
    Error (Saved_history.Newer_version { expected; got })
  | Error (Io_error detail) -> Error (Saved_history.Io_error detail)
  | Error (Read_failed { cause; detail }) -> Error (Saved_history.Read_failed { cause; detail })
  | Error (Agent_core_error detail) -> Error (Saved_history.Agent_core_error detail)
  | Error (Objects_invalid error) -> Error (Saved_history.Objects_invalid error)

let saved_history_of_ref = function
  | Ok value -> Ok (Saved_history.Read value)
  | Error Ref_not_found -> Error Saved_history.Ref_not_found
  | Error (Ref_read_failed error) ->
    (match saved_history (Error error) with
     | Ok history -> Ok history
     | Error error -> Error (Saved_history.Ref_read_failed error))
  | Error (Ref_identity_invalid error) -> Error (Saved_history.Ref_identity_invalid error)
  | Error (Ref_session_mismatch { expected; actual }) ->
    Error (Saved_history.Ref_session_mismatch { expected; actual })
  | Error (Ref_lock_failed detail) -> Error (Saved_history.Ref_lock_failed detail)

let load_error_of_saved_history_error : Saved_history.error -> checkpoint_load_error = function
  | Saved_history.Not_found -> Not_found
  | Saved_history.Store_error detail -> Store_error detail
  | Saved_history.Parse_error detail -> Parse_error detail
  | Saved_history.Newer_version { expected; got } -> Newer_version { expected; got }
  | Saved_history.Io_error detail -> Io_error detail
  | Saved_history.Read_failed { cause; detail } -> Read_failed { cause; detail }
  | Saved_history.Agent_core_error detail -> Agent_core_error detail
  | Saved_history.Objects_invalid error -> Objects_invalid error

let saved_history_error_to_string error =
  checkpoint_load_error_to_string (load_error_of_saved_history_error error)

let saved_history_ref_error_to_string = function
  | Saved_history.Ref_not_found -> checkpoint_ref_load_error_to_string Ref_not_found
  | Saved_history.Ref_read_failed error -> saved_history_error_to_string error
  | Saved_history.Ref_identity_invalid error ->
    checkpoint_ref_load_error_to_string (Ref_identity_invalid error)
  | Saved_history.Ref_session_mismatch { expected; actual } ->
    checkpoint_ref_load_error_to_string (Ref_session_mismatch { expected; actual })
  | Saved_history.Ref_lock_failed detail ->
    checkpoint_ref_load_error_to_string (Ref_lock_failed detail)
