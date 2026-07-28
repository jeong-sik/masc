(** Single maintenance owner for the shared {!Tool_blob_store}.

    Live references are the union of exact {!Tool_output} markers in every
    regular durable file below the workspace runtime root, including Gate
    replay sidecars and shared [Tool_bridge] consumers. Blob payloads and this
    module's own candidate snapshot are excluded.

    Retention is an explicit two-state policy, not an age/count heuristic:
    [Observe_only] records every currently unreferenced blob as a durable
    candidate and deletes nothing. [Delete_previous_candidates] deletes only
    hashes that were candidates in the previous durable snapshot and remain
    unreferenced in the new complete scan. The caller owns the quiescent
    maintenance window. A malformed reference, scan failure, candidate-store
    failure, or unlink failure aborts visibly. *)

type mode =
  | Observe_only
  | Delete_previous_candidates

type error =
  | Durable_source_stat_failed of
      { path : string
      ; reason : string
      }
  | Durable_source_read_failed of
      { path : string
      ; reason : string
      }
  | Malformed_artifact_reference of
      { path : string
      ; line : int
      ; offset : int
      ; detail : string
      }
  | Candidate_snapshot_invalid of
      { path : string
      ; detail : string
      }
  | Candidate_snapshot_write_failed of
      { path : string
      ; detail : string
      }
  | Blob_listing_failed of Tool_blob_store.list_error
  | Blob_delete_failed of Tool_blob_store.delete_error

type report =
  { live_references : int
  ; blobs_observed : int
  ; candidates_recorded : int
  ; deleted : int
  }

val error_to_string : error -> string
val candidate_snapshot_path : base_path:string -> string
val run : base_path:string -> mode:mode -> (report, error) result
