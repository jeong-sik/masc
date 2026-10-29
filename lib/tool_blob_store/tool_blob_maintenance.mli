(** Single maintenance owner for the shared {!Tool_blob_store}.

    Live references are the union of exact {!Tool_output} markers in the
    closed durable-consumer registry: Keeper state/checkpoints, Gate replay,
    tool-call logs, traces, messages, Keeper chat, Board posts, bounded wire captures,
    Skill composition evidence, and durable asynchronous Keeper requests.
    A marker whose media type is {!Tool_output.artifact_manifest_mime} adds the
    manifest's strictly decoded normalized children transitively. A JSON
    object that decodes as an agent history [Stored] media source
    ({!Agent_core_base.History.stored_source_of_json}) in the same registry is
    live as history media; it names a blob but is not a manifest, so it adds
    no children. No other blob content is parsed or treated as an ownership
    edge.
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
    scans are required. Registered sources must decode as JSON documents,
    JSONL rows, or exact canonical marker rows; blank rows carry no references.
    An undecodable row, malformed reference, scan failure, or candidate-store
    failure aborts visibly before deletion. Parse failure leaves the previous
    candidate snapshot intact. An unlink failure is reported during deletion;
    earlier candidate deletions may already have succeeded.

    The blob store is one per BasePath and the consumers write under the same
    BasePath's [<base>/.masc]; a hash is live when any consumer there
    references it. *)

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
  | Durable_source_parse_failed of
      { path : string
      ; line : int
      ; detail : string
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
val run :
  base_path:string ->
  board_posts_file:(workspace_masc_dir:string -> string) ->
  mode:mode ->
  (report, error) result
(** [board_posts_file ~workspace_masc_dir] names the Board posts file of one
    workspace. Production passes [Board_paths.file_path ~workspace_masc_dir
    Posts] ([Masc_board_handlers.Board_paths.posts_file]); this library sits
    below Board, so it takes the name instead of repeating it. *)

type live_references
(** What one complete scan of the durable-consumer registry holds live: tool
    artifact references, with the children of the manifests they name, and
    history [Stored] media sources, kept as two kinds. *)

val live_references :
  base_path:string ->
  board_posts_file:(workspace_masc_dir:string -> string) ->
  (live_references, error) result
(** The scan {!run} deletes against, with the same arguments and failures. *)

val holds_history_media : live_references -> sha256:string -> bool
(** Whether a durable consumer holds a history [Stored] source with this
    digest. A tool artifact reference to the same bytes does not count. *)
