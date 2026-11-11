(** The JSON of what a Librarian commit consumed, and the durable range
    receipt file that holds it: the durable range id, the official range id,
    the explicit candidate id and the admission recall binding with their
    encoders and decoders, the candidate request and sequence sets with the
    uniqueness check on explicit candidates, the receipt and receipt list
    encoders and decoders with the record of a skipped receipt, and the read
    and the validation of the receipt file.

    [Keeper_memory_os_current] includes this module. *)

open Keeper_memory_os_types
open Keeper_memory_os_current_types

val durable_range_id_to_json : durable_range_id -> Yojson.Safe.t

val durable_range_id_of_json : Yojson.Safe.t -> (durable_range_id, wire_error) result

val official_range_id_to_json : official_range_id -> Yojson.Safe.t

val official_range_id_of_json : Yojson.Safe.t -> (official_range_id, wire_error) result

val explicit_candidate_id_to_json :
  explicit_candidate_id ->
  Yojson.Safe.t

val explicit_candidate_id_of_json :
  Yojson.Safe.t ->
  (explicit_candidate_id,
   wire_error)
  result

val admission_recall_binding_to_json :
  admission_recall_binding ->
  Yojson.Safe.t

val admission_recall_binding_of_json :
  Yojson.Safe.t ->
  (admission_recall_binding,
   wire_error)
  result

val consumed_candidate :
  consumed_range ->
  explicit_candidate_id option

val validate_unique_explicit_candidates :
  explicit_candidate_id list ->
  (unit, string) result

val durable_range_receipt_to_json :
  durable_range_receipt ->
  Yojson.Safe.t
val durable_range_receipt_of_json :
  Yojson.Safe.t -> (durable_range_receipt, wire_error) result

val durable_range_receipts_to_json :
  durable_range_receipt list ->
  Yojson.Safe.t

(* A receipt entry this binary cannot decode: legacy bytes from a schema it
   no longer writes. One such entry used to wedge the whole ledger: every
   pass failed the file and continuity never advanced, which is how a
   pre-#42020 [explicit_write_range_id] entry froze five keepers'
   snapshots and grew their carried ranges until fresh sessions failed
   (#42597). A receipt is evidence for skipping already-committed work, so
   an unverifiable receipt reads as no receipt, never as an honored one
   (#32461); the skipped bytes move aside with their reason instead of
   being silently dropped. *)
type skipped_range_receipt =
  { index : int
  ; reason : string
  ; entry : Yojson.Safe.t
  }

val durable_range_receipt_decodes : int Atomic.t

val read_durable_range_receipts :
  keepers_dir:string ->
  keeper_id:string ->
  (durable_range_receipt list *
   skipped_range_receipt list, string)
  result

val validate_durable_range_receipts :
  keepers_dir:string -> keeper_id:string -> (unit, string) result
