(** The session directory a save writes to, the lock around it, and the
    outcomes and errors of a save.

    [canonical_session_location] resolves the parent of a session directory
    and refuses a leaf that is not a real path segment or is a symbolic link.
    [with_session_lock_typed] runs a function under the durable lock kept
    beside that location, and [with_session_lock] does the same with the error
    as text. [save_agent_core_outcome] says whether a save installed a
    checkpoint ([Saved], with its [save_relation] to the turn count already on
    disk) or found a later turn there and wrote nothing ([Stale_noop]).
    [save_agent_core_error] names why a save failed;
    [save_agent_core_error_to_string] and [checkpoint_load_error_to_string]
    render the errors. [archive_agent_core_history_best_effort] saves a
    history snapshot and turns a failure into a log line and a counter.
    [Keeper_checkpoint_store] includes this module. *)

open Keeper_checkpoint_store_history_files
open Keeper_checkpoint_store_decode

type save_agent_core_relation = [ `Cold | `Forward | `Equal ]

type save_agent_core_outcome =
  | Saved of
      { relation : save_agent_core_relation
      ; turn_count : int
      ; canonical_bytes : int
      ; checkpoint : Agent_core.Checkpoint.t
      }
  | Stale_noop of { incoming_turn_count : int; known_turn_count : int }

val save_relation :
  known:'a option -> incoming:'a -> [> `Cold | `Equal | `Forward ]

type unix_failure =
  { error : Unix.error
  ; operation : string
  ; argument : string
  }

type directory_failure =
  | Directory_unix_failure of unix_failure
  | Directory_other_failure of string
  | Directory_leaf_invalid of
      { session_dir : string
      ; leaf : string
      }

type save_agent_core_error =
  | Invalid_session_id of string
  | Session_directory_unavailable of directory_failure
  | Existing_checkpoint_unreadable of checkpoint_load_error
  | Checkpoint_unencodable of Agent_core.Error.t
      (** The checkpoint codec refused the messages or the fields around them,
          and dropping unencodable json did not give a copy it accepts. *)
  | Objects_write_failed of Keeper_checkpoint_object_store.write_error
  | Canonical_write_failed of Keeper_fs.durable_write_error
  | Transaction_lock_failed of File_lock_eio.durable_lock_error
  | Structurally_invalid of Keeper_transcript_unit.structural_error
      (** The messages do not satisfy the tool-protocol contract a reload has
          to replay. One of the three writers ran this check before calling
          here; the mid-run sink and finalize assembled their checkpoint
          directly and did not, so a broken history was admitted by the two
          hottest paths (#25561). The check belongs at the write boundary
          every writer passes through. *)

val checkpoint_load_error_to_string :
  checkpoint_load_error -> string

val save_agent_core_error_to_string : save_agent_core_error -> string

val canonical_session_location :
  string -> (string, save_agent_core_error) result

val with_session_lock_typed :
  session_dir:string ->
  (string -> ('a, save_agent_core_error) result) ->
  ('a, save_agent_core_error) result

val with_session_lock :
  session_dir:string -> (string -> 'a) -> ('a, string) result

val archive_agent_core_history_best_effort :
  payload_writer:Checkpoint_payload_writer.t ->
  session_dir:string ->
  retained:int -> head_bytes:string -> Agent_core.Checkpoint.t -> unit
