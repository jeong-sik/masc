(** Reading the canonical checkpoint file strictly, what a save knows about
    it, and removing one that no turn can decode.

    [load_canonical_bytes_strict] reads the canonical file together with the
    identity of what it read, and refuses bytes that changed while they were
    read. [known_canonical] gives a save the session id, turn count, head and
    object state of the canonical on disk: from the summary while it
    describes the file, otherwise from a parse of the head.
    [absent_objects] lists the objects the canonical names that the session
    does not hold. [judge_canonical] reads and decodes in separate steps and
    says which step stopped. [remove_undecodable_canonical] deletes the
    canonical only when that judgement is [Judged_undecodable].
    [Keeper_checkpoint_store] includes this module. *)

open Keeper_checkpoint_store_decode
open Keeper_checkpoint_store_summary

val load_canonical_bytes_strict :
  string ->
  ((canonical_identity * string) option,
   checkpoint_load_error)
  result

(* What a save needs from the canonical: the head alone, no message object.
   From the summary while it describes the file, otherwise from a parse of
   the head, which publishes the summary. *)
type known_canonical =
  { known_session_id : string
  ; known_turn_count : int
  ; known_head : Agent_core.Checkpoint_objects.head
  ; known_objects : head_objects
  }

val parsed_canonical :
  canonical_path:string ->
  ((canonical_identity * Agent_core.Checkpoint_objects.head)
   option, checkpoint_load_error)
  result

val known_canonical :
  canonical_path:string ->
  (known_canonical option,
   checkpoint_load_error)
  result

val absent_objects :
  session_dir:string -> known_canonical -> Agent_core.Checkpoint_objects.digest list

type canonical_judgement =
  | Judged_absent
  | Judged_decoded of Agent_core.Checkpoint.t
  | Judged_superseded of { expected : int; got : int }
  | Judged_newer of { expected : int; got : int }
  | Judged_undecodable of checkpoint_load_error
  | Judged_inconclusive of checkpoint_load_error

val judge_canonical :
  session_dir:string -> session_id:string -> canonical_judgement

type undecodable_removal_outcome =
  | Removed of { undecodable : checkpoint_load_error }
  | Canonical_absent
  | Canonical_loadable

type undecodable_removal_error =
  | Removal_refused of checkpoint_load_error
  | Removal_failed of string
  | Removal_durability_unknown of string

val undecodable_removal_error_to_string : undecodable_removal_error -> string

val remove_undecodable_canonical :
  session_dir:string ->
  session_id:string ->
  (undecodable_removal_outcome, undecodable_removal_error) result
