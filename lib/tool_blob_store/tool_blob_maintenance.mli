(** Single maintenance owner for the shared {!Tool_blob_store}.

    Live references are the union of exact {!Tool_output} markers in the
    closed durable-consumer registry: Keeper state/checkpoints, Gate replay,
    tool-call logs, traces, messages, Keeper chat, and bounded wire captures.
    A marker whose media type is {!Tool_output.artifact_manifest_mime} adds the
    manifest's strictly decoded normalized children transitively. No other
    blob content is parsed or treated as an ownership edge.
    Trajectory previews, repository mirrors, build products, operator config,
    and unrelated observational logs are not blob consumers and are never
    traversed. A new durable consumer must be added to this registry in the
    same change that persists a reference.

    Retention is an explicit two-state policy, not an age/count heuristic:
    [Observe_only] records every currently unreferenced blob as a durable
    candidate and deletes nothing. [Delete_previous_candidates] deletes only
    hashes that were candidates in the previous durable snapshot and remain
    unreferenced in the new complete scan. The offline deployment helper runs
    it only while holding the BasePath process lease, so two complete offline
    scans are required. A malformed reference, scan failure, candidate-store
    failure, or unlink failure aborts visibly. Because the blob store is shared across clusters
    while several consumers are cluster-aware, any non-empty
    [<base>/.masc/clusters] tree currently disables maintenance fail-closed
    until cross-cluster writer quiescence has one coordination owner. *)

type mode =
  | Observe_only
  | Delete_previous_candidates

type error =
  | Clustered_durable_roots_uncoordinated of
      { path : string
      ; entries : int
      }
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
  | Malformed_structured_artifact_reference of
      { path : string
      ; line : int
      ; detail : string
      }
  | Artifact_manifest_read_failed of
      { sha256 : string
      ; reason : string
      }
  | Artifact_manifest_invalid of
      { sha256 : string
      ; detail : string
      }
  | Candidate_snapshot_invalid of
      { path : string
      ; detail : string
      }
  | Candidate_snapshot_read_failed of
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
