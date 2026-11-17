(** Actual full-original ordered publication and source settlement. This module
    supplies no Cut, lineage, dispatch, publication or ACK authority. *)
type retained = private {
  request_id : string;
  request_digest : string;
  owner : Keeper_librarian_durable_request.owner;
  source_basis_digest : string;
  first_step_id : string;
  first_step_digest : string;
  anchor : Keeper_memory_os_current.program_anchor_evidence;
  publication : Keeper_memory_os_program_types.publication;
  snapshot_revision : int;
  snapshot_sha256 : string;
  receipts : Keeper_memory_os_current_types.durable_range_receipt list;
  external_through : int;
  external_ack : Keeper_external_read_cursor.observation;
  atom_position : Keeper_librarian_progress.t option;
  official_position : Keeper_librarian_official_progress.t option;
}
val retained_to_json : retained -> Yojson.Safe.t
val retained_of_json : Yojson.Safe.t -> (retained, string) result
(** Strict data codec only. Decoding never creates a live settlement proof.
    The complete canonical program, original basis, receipts and actual ACK
    observation survive later step-body or rolling-receipt cleanup. The wire
    retains the full publication as [publication_bytes] JSON text so outer
    store canonicalization cannot change fact timestamps or opaque input/gate
    evidence. Decode that text with the strict publication decoder; an object
    publication field is not accepted. *)

type t
val observe : store:Lane_addon_store.t ->
  request:Keeper_librarian_durable_request.t ->
  record:Lane_addon_tool_request_owner.retained ->
  program:Keeper_memory_os_current.committed_program -> (t, string) result
(** Own the actual source-settlement locks; reobserve the exact retained
    original, schema-2 first question and complete basis/manifest/transaction,
    actual canonical Memory program and all original range receipts, and exact
    already-acknowledged read positions. This never turns a refusal into
    Finished. Caller retains the serialized Memory lane/purge exclusion,
    holds no source or Memory locks, and offloads this blocking scope. *)
val recheck : t -> (unit, string) result
(** Repeat the actual observation before retaining it in an intent. The first
    question and complete original bodies must still be retained. Once that
    intent is durable, its strict stored data does not repeat this live read. *)
val request : t -> Keeper_librarian_durable_request.t
val program : t -> Keeper_memory_os_current.committed_program
val retained : t -> retained
