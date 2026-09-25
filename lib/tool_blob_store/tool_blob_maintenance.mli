(** Single maintenance owner for the shared {!Tool_blob_store}.

    Live references are the union of exact {!Tool_output} markers in the
    closed durable-consumer registry: Keeper state/checkpoints, Gate replay,
    tool-call logs, traces, messages, Keeper chat, Board posts, and bounded wire captures.
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
    failure, or unlink failure aborts visibly.

    The blob store is one per BasePath while the consumers are per cluster:
    each writes under its cluster's workspace root, [<base>/.masc] for the
    default cluster and [<base>/.masc/clusters/<name>] for the others. The
    scan therefore reads the same consumer registry in every workspace, and a
    hash is live when any workspace references it (#38919). A symlink or a
    special file under [clusters] rejects the pass ([Cluster_workspace_rejected])
    instead of being skipped, because a symlink can point at a real workspace;
    so does a cluster set that changes while the scan runs. A regular file there
    (Finder's [.DS_Store]) cannot be a workspace, holds no references, and is
    skipped and reported in [skipped_cluster_files].
    Both leave the candidate snapshot untouched and delete nothing. *)

type mode =
  | Observe_only
  | Delete_previous_candidates

type error =
  | Cluster_workspace_rejected of
      { path : string
      ; reason : string
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
  ; skipped_cluster_files : string list
        (** Regular files found directly under [<base>/.masc/clusters] (for
            example [.DS_Store]). They cannot be workspace roots, so they
            hold no references; the pass skips them and names them here so
            the caller can log each one. *)
  }

val error_to_string : error -> string
val candidate_snapshot_path : base_path:string -> string
val run :
  base_path:string ->
  board_posts_file:(workspace_masc_dir:string -> string) ->
  mode:mode ->
  (report, error) result
(** [board_posts_file ~workspace_masc_dir] names the Board posts file of one
    workspace. Production passes [Board_paths.file_path ~workspace_masc_dir
    Posts] ([Masc_board_handlers.Board_paths.posts_file]); this library sits
    below Board, so it takes the name instead of repeating it. *)

module For_testing : sig
  val run :
    after_scan:(unit -> unit) ->
    base_path:string ->
    board_posts_file:(workspace_masc_dir:string -> string) ->
    mode:mode ->
    (report, error) result
  (** {!run} with a fault-injection boundary after every workspace has been
      scanned and before the cluster set is confirmed unchanged. A test
      creates a cluster there to stand in for one that appears while a real
      pass is reading. *)
end
