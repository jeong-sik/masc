(* #39331 milestone B: reference-based sweep for the kept vision store root.

   The kept root has no size cap on purpose: handles that checkpoints, turn
   records and the durable record point at must not be evicted by a size
   rule. What can go is a kept file nothing references any more. This module
   sweeps exactly those, with the same two-pass candidate rule
   [Tool_blob_maintenance] uses for tool blobs:

   - one complete [Vision_artifact_reference.is_referenced] scan produces the
     candidate set (root entries that answer [Ok false]);
   - the candidate set is persisted next to the store;
   - only a handle in both the previous and the current candidate set is
     deleted.

   Any unknown -- a read failure, a symlink, a store that cannot be scanned
   completely -- aborts the sweep with an [Error] before anything is
   deleted: an unknown is where a live handle would hide. A missing previous
   snapshot is not an error; it only means this sweep records candidates and
   deletes nothing yet. *)

type error =
  | Reference_scan_failed of
      { handle : string
      ; detail : string
      }
  | Snapshot_read_failed of { detail : string }
  | Snapshot_write_failed of { detail : string }
  | Delete_failed of
      { handle : string
      ; detail : string
      }
(** Everything that can stop a sweep. No constructor means "delete this
    anyway": the sweep deletes only complete-knowledge candidates that were
    un-referenced in the previous complete scan too. *)

val error_to_string : error -> string

type report =
  { scanned : int
        (* canonical kept files observed at the root *)
  ; live : int
        (* handles the scan found still referenced *)
  ; candidates_recorded : int
        (* un-referenced handles recorded this sweep *)
  ; deleted : int
        (* handles deleted this sweep *)
  ; reclaimed_bytes : Int64.t
  ; remaining_count : int
  ; remaining_bytes : Int64.t
  }

val run : masc_dir:string -> dir:string -> (report, error) result
(** [run ~masc_dir ~dir] sweeps the kept vision store at [dir].
    [masc_dir] is the runtime root the reference scan reads the durable
    consumers from (the same value [Vision_artifact_reference.is_referenced]
    takes). Absent [dir] is an empty report, not an error: a Keeper with no
    vision store has nothing to sweep. *)
