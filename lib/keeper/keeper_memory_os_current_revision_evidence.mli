(** The reads of committed receipts and recall evidence: the receipt read
    mode and the receipt status wrappers, the revision evidence read, the
    committed ranges, explicit candidates, coverage and unread messages, the
    admission recall bindings and reads with the JSON of their unresolved
    reasons, and the recall transitions and the successor recall read.

    [Keeper_memory_os_current] includes this module. *)

open Keeper_memory_os_current_types

type committed_program = private {
  keepers_dir : string;
  keeper_id : string;
  publication : Keeper_memory_os_program_types.publication;
  snapshot_revision : int;
  snapshot_sha256 : string;
  receipts : durable_range_receipt list;
}
val read_committed_program : keepers_dir:string -> keeper_id:string ->
  transaction_id:string -> (committed_program option, string) result
(** Confirm/recover a real canonical program transaction and its complete
    committed boundary receipts under Memory serialization. Bind the actual
    marked journal transition, current incarnation and consistent target
    revision/hash. A pending, missing component or contradictory proof is an
    error; None is no matching journal program, never permission to replay.
    May perform standard publication recovery. No source ACK is performed. *)
val confirm_committed_program : committed_program -> (unit, string) result
(** Re-observe the same exact program, target and receipt set. This is Memory
    evidence, not source ownership or Cut/ACK authority. Caller retains source
    serialization and must not already hold Memory locks. *)

val read_with_revision_evidence_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> after_revision:int ->
  ((t option * revision_evidence list), string) result

val committed_explicit_candidates :
  keepers_dir:string -> keeper_id:string -> queue_generation:string ->
  (explicit_candidate_id list, string) result

val read_with_admission_recall_status_for_keepers_dir :
  keepers_dir:string -> keeper_id:string ->
  ((t option * (admission_recall_binding list, string) result), string) result

val read_with_admission_recall_for_keepers_dir :
  keepers_dir:string -> keeper_id:string ->
  ((t option * admission_recall_binding list), string) result

val revision_evidence_to_json : revision_evidence -> Yojson.Safe.t

val recall_unresolved_reason_to_string : recall_unresolved_reason -> string

val recall_unresolved_reason_to_json : recall_unresolved_reason -> Yojson.Safe.t

val read_successor_recall_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> (successor_recall, string) result

val committed_durable_coverage :
  keepers_dir:string ->
  keeper_id:string ->
  receipt_scope:string ->
  (durable_range_id option, string) result

val committed_official_coverage :
  keepers_dir:string ->
  keeper_id:string ->
  receipt_scope:string ->
  (official_range_id option, string) result

val committed_durable_range :
  keepers_dir:string ->
  keeper_id:string ->
  receipt_scope:string ->
  (durable_range_id option, string) result

val committed_official_range :
  keepers_dir:string ->
  keeper_id:string ->
  receipt_scope:string ->
  (official_range_id option, string) result

val read_unread_messages : keepers_dir:string -> keeper_id:string ->
  (Keeper_librarian_unread.t list, string) result

val committed_unread_messages : keepers_dir:string -> keeper_id:string ->
  (Keeper_librarian_unread.t list, string) result
