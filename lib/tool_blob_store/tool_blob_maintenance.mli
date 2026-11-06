(** Single maintenance owner for the shared {!Tool_blob_store}.

    Live references are the union of exact {!Tool_output} markers in the
    stores a {!scope} puts in scope.
    A marker whose media type is {!Tool_output.artifact_manifest_mime} adds the
    manifest's strictly decoded normalized children transitively. A JSON
    object that decodes as an agent history [Stored] media source
    ({!Agent_core_base.History.stored_source_of_json}) in the same registry is
    live as history media; it names a blob but is not a manifest, so it adds
    no children. No other blob content is parsed or treated as an ownership
    edge.
    The arbitrary input of a decoded History ToolUse, the JSON payload of
    decoded History/Keeper tool results, a tool-call receipt's input,
    execution_evidence, and route_evidence, and a complete official-client
    outbox receipt's arguments/response are opaque to history-media recognition,
    including inside nested lists. Outbox
    receipts require the shared strict codec, exact filename digest and the
    shared official-client storage path authority. Only a whole JSON document
    at that source qualifies; nested envelopes and JSONL rows cannot acquire
    this source authority.
    Their ordinary [type="stored"] data are not media ownership. Reserved artifact
    markers and [_blob] references remain authoritative in those payloads.
    These are field-ownership projections, not complete validation of each
    result or call-log row. Sibling [content] and [content_blocks] remain
    independently traversed; a recognized malformed media reference there
    still aborts. A call's execution or wire outcome does not change ownership
    of its arbitrary input.
    Unrecognized envelopes retain the generic reference scan. A reference that
    its existing codec recognizes as malformed still aborts before deletion;
    this is not complete validation of every durable-owner schema.
    Only the stores a {!scope} puts in scope are traversed. A new durable
    consumer must be added to the scope in the same change that persists a
    reference.

    Retention is an explicit two-state policy, not an age/count heuristic:
    [Observe_only] records every currently unreferenced blob as a durable
    candidate and deletes nothing. [Delete_previous_candidates] deletes only
    hashes that were candidates in the previous durable snapshot and remain
    unreferenced in the new complete scan. The offline deployment helper runs
    it only while holding the BasePath process lease, so two complete offline
    scans are required. Registered sources must decode as JSON documents,
    JSONL rows, or exact canonical marker rows; blank rows carry no references.
    A lock file below a store ({!Fs_compat.is_lock_name}) holds no record and
    is not read. Nor is a Finder file ({!finder_metadata_name}) below one.
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

val finder_metadata_name : string
(** [.DS_Store], the name the macOS Finder writes in any directory it opens.
    No MASC module writes it. A scope excludes it by this name
    ([Finder_metadata]), and a scan does not read a file of this name below a
    store. *)

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
  | Scope_place_unreadable of
      { path : string
      ; reason : string
      }

type report =
  { live_references : int
  ; blobs_observed : int
  ; candidates_recorded : int
  ; deleted : int
  }

val error_to_string : error -> string

(** {1 Scope}

    What a scan reads (RFC-0499 §5.3). Every direct entry of three places is
    classified: [<base>/.masc], the directories a {!Place} names below it,
    and the config [keepers/] directory. This library sits below the modules
    that make the names, so the value comes from the caller
    ([Server_tool_blob_scope.scope] in production). *)

(** Why a store holds no reference the scan must read. *)
type exclusion =
  | Blob_store  (** The blob store a sweep deletes from. *)
  | Sweep_record  (** This sweep's own records. *)
  | Truncated_copies
      (** Tool results cut to 500 bytes. A cut reference cannot be decoded,
          and no code reads one back. *)
  | Settled_archive  (** Archived request bodies no code reads back. *)
  | Finder_metadata  (** A [.DS_Store] the macOS Finder writes. *)
  | Other_media_store  (** A store its own maintenance command sweeps. *)
  | Operator_config  (** Configuration an operator edits. *)
  | Repository_mirror
      (** Source repository clones. A reference there is source text. *)
  | Unpublished_write  (** An atomic write's staging file. *)
  | Writes_no_reference
      (** A store whose producer writes no tool blob reference. *)
  | Repairable_pointer
      (** It names a blob that stores in scope own. When the blob is gone,
          its producer writes it again from another store. *)

type source =
  | Tree  (** Every regular file below the entry is read. *)
  | File  (** The entry is one file; absent, it holds nothing. *)

type classification =
  | In_scope of source
  | Excluded of exclusion

(** Reads one file with its producer's decoder and gives back the JSON the
    scan reads references from. An absent file, and bytes the producer itself
    discards, are [Ok None]. [Error] is a file the producer cannot read. *)
type keeper_file_decoder = string -> (Yojson.Safe.t option, string) result

type entry =
  | Store of
      { name : string
      ; classification : classification
      }  (** The entry with this exact name. *)
  | Keeper_files of
      { suffix : string
      ; reason : exclusion
      }  (** Config [keepers/] files named [<keeper><suffix>]. *)
  | Decoded_keeper_files of
      { suffix : string
      ; decode : keeper_file_decoder
      }
      (** Config [keepers/] files named [<keeper><suffix>], in scope. The scan
          reads each through [decode]; a file [decode] cannot read ends the
          scan with [Durable_source_read_failed]. *)
  | Names of
      { matches : string -> bool
      ; reason : exclusion
      }  (** Names a producer's own grammar recognizes. *)
  | Place of
      { name : string
      ; entries : entry list
      }  (** A directory whose direct entries are classified one by one. *)

(** A name made from another entry's name. It takes that entry's
    classification. *)
type derived_name =
  | Suffix of string  (** [<base><suffix>]. *)
  | Parsed of (string -> string option)
      (** A producer's grammar returns the base name. *)

type scope =
  { workspace : entry list  (** Direct entries of [<base>/.masc]. *)
  ; config_keepers_dir : base_path:string -> string
  ; config_keepers : entry list
  ; derived : derived_name list
  }

val dirname : string
(** The directory below [<base>/.masc] that holds this sweep's records. *)

type place =
  | Workspace of string list
      (** The directory these segments name below [<base>/.masc]. *)
  | Config_keepers

type unclassified_entry =
  { place : place
  ; name : string
  }

val unclassified_entry_to_string : unclassified_entry -> string

val unclassified_entries :
  base_path:string -> scope -> (unclassified_entry list, error) result
(** The direct entries of every place that no entry of [scope] classifies,
    sorted by name within a place. A name that matches two entries, directly
    or through two derived names, is unclassified. An absent place has no
    entries. *)

val consumer_paths : scope -> base_path:string -> string list
(** The path of every store [scope] puts in scope. *)

val candidate_snapshot_path : base_path:string -> string
val run :
  base_path:string ->
  scope:scope ->
  mode:mode ->
  (report, error) result

type live_references
(** What one complete scan of the durable-consumer registry holds live: tool
    artifact references, with the children of the manifests they name, and
    history [Stored] media sources, kept as two kinds. *)

val live_references :
  base_path:string ->
  scope:scope ->
  (live_references, error) result
(** The scan {!run} deletes against, with the same arguments and failures. *)

val fold_live_sha256 : live_references -> init:'a -> f:('a -> string -> 'a) -> 'a
(** Folds the digest of every live reference. A digest named both by a tool
    artifact reference and by a history source is folded once per reference.
    The in-server sweep ({!Tool_blob_sweep}) builds its live digest set from
    this. *)

val holds_history_media : live_references -> sha256:string -> bool
(** Whether a durable consumer holds a history [Stored] source with this
    digest. A tool artifact reference to the same bytes does not count. *)
