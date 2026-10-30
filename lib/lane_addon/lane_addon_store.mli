(** Durable binding records, source captures and assertions. Slices are queries;
    no cached query result is authoritative. All paths are below [root]. *)
type t
val create : root:string -> t
(** Resolve a relative root against the working directory at creation. The
    resulting absolute ownership boundary is retained by the store. *)
val root : t -> string
val digest : string -> string
(** SHA-256 of every original byte, unchanged by internal feed boundaries.
    Bounded C feeds allow the runtime to service another systhread between
    chunks; they neither cap the input nor introduce an Eio suspension. The
    caller still owns CPU scheduling and cancellation of the complete work. *)
val blob_reference : string -> Lane_addon_types.evidence
(** Content-addressed reference without writing. It may be used to measure a
    complete acquisition envelope; publish it only after [write_blob] succeeds. *)
val write_blob : t -> string -> (Lane_addon_types.evidence, string) result
(** Publish every original byte durably; the returned address uses the digest
    already computed for the published leaf. *)
val write_sampling_blob : t -> string -> (Lane_addon_types.evidence, string) result
(** Publish a terminal sampling blob, using an independently writable recovery
    directory if the ordinary blob location fails. Both readers resolve the
    same immutable address. Success requires a durable write. Canonical and
    recovery publication use the same digest of this call's original bytes. *)
val read_blob : ?max_bytes:int -> t -> Lane_addon_types.evidence -> (string, string) result
(** [max_bytes] rejects a retained file before allocating its complete body. *)
type blob_slice = { content : string; snapshot : Fs_compat.owned_regular_file_snapshot }
val read_blob_slice : ?snapshot:Fs_compat.owned_regular_file_snapshot ->
  t -> Lane_addon_types.evidence -> offset:int -> max_bytes:int ->
  (blob_slice, string) result
(** Without [snapshot], hash the complete blob once and return its validated
    descriptor snapshot. With that witness, read only the bounded slice and
    reject any snapshot change. A consumer reconstructs the advertised full SHA
    after paging; a hash alone never supplies this witness. Zero bytes captures
    or verifies the witness without retaining body bytes. *)
val save_host_result : t -> instance_id:string -> request_id:string -> Yojson.Safe.t ->
  (unit, string) result
val load_host_result : t -> instance_id:string -> request_id:string ->
  (Yojson.Safe.t option, string) result
(** Durable host-result authority link, addressed by instance and original request,
    never by a package-supplied blob hash. Same verification as action receipts. *)
type read_budget
type bounded_read_error = Read_limit_exceeded | Read_failed of string
val read_budget : max_bytes:int -> read_budget
val read_blob_bounded : budget:read_budget -> t -> Lane_addon_types.evidence ->
  (string, bounded_read_error) result
(** One shared byte allowance, charged before reads including corrupt blobs.
    Use one budget for an entire projection, not one per reference. *)
val load_sampling_request_bounded : budget:read_budget -> t -> instance_id:string ->
  request_id:string -> (Yojson.Safe.t option, bounded_read_error) result
(** Prefer the independently retained terminal link; otherwise read the pending
    request index. Both use the caller's shared aggregate read allowance and
    verify the exact file and parent durability before accepting a receipt.
    Failed verification consumes the bytes read and never falls back to pending. *)
type jsonl_snapshot = { entry_count : int; reference : Lane_addon_types.evidence }
val retain_jsonl : t -> history:string -> entry_count:int -> newest_first:'a list ->
  encode:('a -> string) -> (jsonl_snapshot, string) result
(** Retains an immutable append-only history. The native owner guarantees that
    [history] changes on replacement/restore and the list is a captured prefix.
    Only new records are encoded; an older concurrent capture gets its old root.
    Call from a system thread: the store serializes its cursor updates. *)
val read_jsonl : t -> Lane_addon_types.evidence -> (string, string) result
(** Reads a complete retained sequence, oldest first, validating every node.
    Explicit full-history reads allocate the requested result; capture does not. *)
val bindings_directory : string
val actions_directory : string
val exact_requests_directory : string
val tool_request_owners_directory : string
val tool_request_bodies_directory : string
(** The directories below {!root} that hold binding, action receipt, Exact
    request and original tool request records, and the request bodies those
    records name by digest. *)
val binding_path : string -> string
(** One instance's binding record, relative to {!root}. *)
val observation_dir : string -> string
(** One instance's observation directory, relative to {!root}. *)
val action_path : instance_id:string -> request_id:string -> string
(** One action receipt, relative to {!root}. *)
val binding_sequence : Yojson.Safe.t -> (string * int * (string * Yojson.Safe.t) list, string) result
(** The instance id and observation sequence {!read_bindings} requires of
    every binding record before it reads the rest, with the record's fields. *)
type namespace_entry = Record_entry | Staged_entry | Unknown_entry
val tool_request_owner_entry : string -> namespace_entry
(** How {!tool_request_owner_inventory} treats one name in a scope directory:
    a record, an interrupted staged write it skips, or an entry that fails the
    whole inventory. *)
val save_binding : t -> instance_id:string -> Yojson.Safe.t -> (unit, string) result
type binding_write_error =
  | Binding_rejected of string
  | Binding_publication_failed of Fs_compat.atomic_replace_failure
val binding_write_error_to_string : binding_write_error -> string
val save_binding_staged : t -> instance_id:string -> Yojson.Safe.t -> (unit, binding_write_error) result
(** [save_binding] that keeps whether a publication failure preceded or
    followed the rename. [Binding_rejected] fails before any rename. The
    runtime commits a held observation by this write, so an [After_rename]
    failure names a visible binding and cancellation comes back as the
    failure's exception for the caller to re-raise after converging. *)
val remove_binding : t -> instance_id:string -> (unit, string) result
(** Removes one binding record and syncs the containing directory. A retry
    syncs even when the record was already unlinked by an uncertain attempt. *)
val save_action : t -> instance_id:string -> request_id:string -> Yojson.Safe.t -> (unit, string) result
(** Requires the configured root parent to exist as the workspace anchor.
    Publishes the root and action directories, syncing each parent even on
    retries after failed publication. Never opens ancestors above root.parent. *)
val load_action : t -> instance_id:string -> request_id:string -> (Yojson.Safe.t option, string) result
(** Missing receipts return [None]. Existing receipts are accepted only after
    strictly syncing the exact opened file and parent directory, verifying the
    bytes and both path identities again. A visible rename alone is not durable
    confirmation. Sync/read/identity failures return [Error] without replay or
    changing the result. Reads keep the existing full-receipt allocation policy. *)
val save_exact_request : t -> declaration_id:string -> request_id:string ->
  Yojson.Safe.t -> (unit, string) result
val load_exact_request : t -> declaration_id:string -> request_id:string ->
  (Yojson.Safe.t option, string) result
(** A package's exact-output request and its attempts, keyed by the
    declaration id so a restarted worker finds what the host retained. Same
    durability and read verification as action receipts, except one case.
    The owning run republishes the record at each transition, and an observer
    reads it without the run's claim. A read that ends on a file the path no
    longer names reads the newer record, instead of failing. *)
val save_tool_request_owner : t -> scope:string -> request_id:string -> Yojson.Safe.t -> (unit, string) result
(** Cooperative publication is serialized with known-ID reads and complete
    inventories of the same original scope, across Store objects and aliases
    of the existing physical parent. Uses the existing cross-context mutex
    table; no lock files or new registry. This short store transaction is not
    a multi-call Owner CAS or cross-process exclusion. Callers still hold the
    workspace lease and serialize semantic progress updates. *)
val load_tool_request_owner : t -> scope:string -> request_id:string -> (Yojson.Safe.t option, string) result
(** Strict known-ID read under the existing store parent anchor. Initial child
    absence is settled through owned ancestor descriptors; missing/replaced or
    unsafe parent authority is an error. Reads use the same no-follow file and
    parent descriptors for content, fsync and final verification. The same
    original-scope serializer as publication excludes cooperative replacements
    throughout these checks; external changes still refuse. Large records are
    reread in bounded chunks against the complete first observation, including
    the final partial chunk and EOF, without another file-sized allocation. *)
val tool_request_body_path : scope:string -> request_digest:string -> string
(** One original request body, relative to {!root}: beside the scope's
    records, not inside their directory, which holds only records. *)
val save_tool_request_body : t -> scope:string -> request_digest:string -> string -> (unit, string) result
(** Publish one original request body, named by the {!digest} of its bytes.
    Bytes that do not match [request_digest] are refused before writing.
    Writing the same body again publishes the same file. Same serializer and
    durability as record publication. *)
val load_tool_request_body : t -> scope:string -> request_digest:string -> (string option, string) result
(** Read one staged or published body under its scope serializer. Only a
    SHA-256 name is accepted; the consumer verifies canonical bytes against
    that digest. A body alone grants no ownership or execution authority. *)
val load_tool_request : t -> scope:string -> request_id:string ->
  name_body:(Yojson.Safe.t -> ('record * string, string) result) ->
  (('record * string option) option, string) result
(** One original: its record, decoded by [name_body] into the caller's value
    and the digest naming its body, and that body's bytes. Both are read under
    one hold of the scope serializer that publication and
    {!settle_tool_request} use, so an original is read whole or found gone.
    The same owned-descriptor checks as {!load_tool_request_owner} apply to
    both files. [None] means no record; a body that is not there is [None]
    beside the record, and the caller compares the bytes with its digest. *)
val tool_request_archive_directory : string
val tool_request_archive_record_path : scope:string -> date:string -> request_id:string -> string
val tool_request_archive_body_path : scope:string -> date:string -> request_digest:string -> string
(** Where a settled original's record and body live, relative to {!root}:
    [tool-request-owners-settled/<scope digest>/<date>/records|bodies/]. Startup
    cleanup inventories the records, only when a live body is not protected by a
    live record, and does not read archive body contents; no other pass lists or
    reads this namespace. *)
val with_tool_request_settlement_barrier : t -> (unit -> 'a) -> ('a, string) result
(** Serialize a read-only whole-store sweep with the record and body moves of
    cooperating settles in this process. [work] may re-enter individual scope
    readers, but must not invoke a settle. For Eio callers, admission can be
    cancelled, and admitted blocking work finishes on a system thread before
    the barrier is released. Cancellation after admission does not establish
    that a move did not happen. This is not a cross-process lock or an atomic
    inventory snapshot; cooperative writers hold the workspace process lease. *)
val settle_tool_request : t -> scope:string -> date:string -> request_id:string -> request_digest:string ->
  check_record:(Yojson.Safe.t option -> (bool, string) result) -> (bool, string) result
(** Move one original's record, then its body, from the scope into the settled
    archive under [date], syncing both directories after each rename. The
    record leaves first, the reverse of publication, so an interrupted settle
    leaves a body no record names, never a record without its body. A file
    already in the archive counts as moved, so settling again completes the
    move; a file in neither place is an error. Only single-link regular files
    this process owns are moved. Same scope serializer as publication. The
    [check_record] checks the current record under the same scope serializer
    as the move; [false] moves nothing. The caller checks that no other record
    names the body. The store barrier is acquired before the scope serializer. *)
val tool_request_settled : t -> scope:string -> date:string -> request_id:string -> (bool, string) result
(** Whether the archive holds the record of [request_id] under [date]. *)
val tool_request_owner_inventory : t -> scope:string -> ((string * Yojson.Safe.t) list, string) result
(** Complete sorted published [.json] records in one scope, with filenames for
    the consumer's exact key/schema validation. Missing descendants under an
    existing owned parent return an empty list; errors and a listed file that
    disappears never do. Every file is a regular single-link owned record.
    The whole blocking scope runs on one system thread in Eio, under the same
    original-scope serializer as publication and known-ID reads. This is not an
    atomic multi-record transaction; callers retain their process lease and
    serialization and revalidate the original record before effects. *)
val fold_tool_request_owner_inventory_all :
  t ->
  init:'a ->
  f:('a -> directory_name:string -> file_name:string -> Yojson.Safe.t -> ('a, string) result) ->
  ('a, string) result
(** Read-only observational fold across all published scopes, passing one
    scope-directory name, filename and parsed record JSON at a time to [f]
    under the same descriptor/no-follow/durability checks and per-scope
    publication serializer as {!tool_request_owner_inventory_all}. *)
val fold_startup_tool_request_owners :
  t -> init:'a ->
  f:('a -> directory_name:string -> file_name:string -> Yojson.Safe.t -> ('a, string) result) ->
  ('a, string) result
(** The same complete inventory while the caller holds the process lease and
    excludes all original writers. Avoids the per-scope serializer at this
    quiescent boundary. Staged entries must be owned regular single-link files,
    although their incomplete contents are not parsed. *)
val tool_request_owner_inventory_all : t -> ((string * string * Yojson.Safe.t) list, string) result
(** Read-only observational sweep of all published scopes. Each row retains its
    actual scope-directory name and filename for the Owner's strict key check.
    The same descriptor/no-follow/durability checks and per-scope publication
    serializer apply. Malformed names, vanished listed entries or any unreadable
    scope fail the whole sweep. Scope membership is checked again before return;
    individual scope reads are serialized, not one cross-scope atomic snapshot.
    No Keeper metadata/profile list is needed and no state is created. *)

val fold_archived_tool_request_owners :
  t -> init:'a ->
  f:('a -> directory_name:string -> file_name:string -> Yojson.Safe.t -> ('a, string) result) ->
  ('a, string) result
(** Complete, strictly owned inventory of settled record files across scope and
    day directories. The callback validates each record's schema and key.
    Missing archive descendants are settled as absence, but a listed entry
    that disappears or any malformed namespace rejects the entire fold. The
    archive bodies directory is checked, but its contents are not inputs to
    this record inventory. *)

type tool_request_body_entry = private {
  scope_directory : string;
  request_digest : string;
  snapshot : Unix.stats;
}
val tool_request_body_inventory_all : t -> (tool_request_body_entry list, string) result
(** Inspect all published live bodies, verifying owned single-link files and
    their content digests with bounded-memory streaming. Body contents are not
    parsed. Incomplete owned regular atomic staging entries are preserved.
    A malformed name, digest mismatch or unsafe or changing entry rejects the
    entire inventory. *)
val remove_inventoried_tool_request_body : t -> tool_request_body_entry -> (unit, string) result
(** Remove an unchanged inventory entry through a held parent and fsync it.
    The caller must exclude every original writer across the inventory and
    effect. An error can follow removal and does not prove the body remains. *)
val save_sampling_request : t -> instance_id:string -> request_id:string ->
  Yojson.Safe.t -> (unit, string) result
val save_sampling_outcome : t -> instance_id:string -> request_id:string ->
  Yojson.Safe.t -> (unit, string) result
(** Retain the terminal request/outcome link independently of the primary
    request index. [load_sampling_request_bounded] reads this link first. *)
val save_broadcast : t -> instance_id:string -> request_id:string -> Yojson.Safe.t -> (unit, string) result
val load_broadcast : t -> instance_id:string -> request_id:string -> (Yojson.Safe.t option, string) result
(** Retain the exact published evidence before sending its idempotent Broadcast.
    Repeated sends read that original artifact, not a changing live binding. *)
(** One binding file that could not be read as a retained binding. [contents]
    is the parsed JSON when the file was JSON, so the caller can still say whose
    record it is. *)
type unreadable_binding = { path : string; detail : string; contents : Yojson.Safe.t option }
type binding_reading = { readable : Yojson.Safe.t list; unreadable : unreadable_binding list }
val read_bindings : t -> (binding_reading, string) result
(** Reads every binding file on its own. A file that is not JSON, is not an
    object, or lacks an instance id or sequence is listed in [unreadable] and
    does not hide its siblings. The result is [Error] only when the directory
    cannot be listed or synced. Confirms containing-directory durability after
    capturing records/absence, including cold reads used to authorize
    reconciliation. A binding's sequence is its instance's committed
    observation; no observation directory is listed. Exact record reads still
    require their own durability and payload verification. *)
val read_binding : t -> instance_id:string -> (binding_reading, string) result
(** {!read_bindings} for one instance: opens only that instance's binding
    file and classifies it by the same rules, with the same directory
    confirmation. An absent file is an empty reading. A record for this
    instance stored under another file name is not seen. *)
val bindings : t -> (Yojson.Safe.t list, string) result
(** [read_bindings] for a caller that cannot use a partial reading: [Error]
    names the first unreadable file. *)
type binding_inventory = {
  records : (string * Yojson.Safe.t) list;
  issues : (string * string) list;
  complete : bool;
}
val binding_inventory : root:string -> binding_inventory
(** Read metadata without constructing a store, rewriting records or
    creating directories. A record whose read
    collides with this process's own rename/unlink publication retries once
    and accepts a confirmed absence, so a successful concurrent write does not
    read as a damaged store; only a failure that persists across the retry
    makes [complete] false. After capturing the records/absence, sync the
    containing directory (or its first existing ancestor) to reestablish
    publication durability after an uncertain rename or unlink by a previous
    process. Read/sync failures preserve readable siblings but make [complete]
    false. Issue details carry a bracketed failure-kind tag
    ([identity-changed] / [absent-unconfirmed] / [parse] / [non-regular …] /
    [unreadable]) so publication contention reads apart from real damage.
    Offload filesystem I/O. These observed bytes do not authorize
    mutations. *)
type observation_write_error =
  | Observation_rejected of string
  | Publication_failed of { failure : Fs_compat.atomic_replace_failure;
      verification_error : string option }
val observation_write_error_to_string : observation_write_error -> string
val append_observation : t -> instance_id:string -> seq:int ->
  sources:Yojson.Safe.t -> Lane_addon_types.output -> (unit, observation_write_error) result
(** The staged writer's [After_rename] knowledge is preserved even if exact
    visible-byte verification fails. [verification_error] records that failure;
    neither case establishes durability. The runtime must reserve the renamed
    sequence before propagating uncertainty; this never authorizes action replay. *)
val observations : t -> instance_id:string -> through:int ->
  ((Yojson.Safe.t * Lane_addon_types.output) list, string) result
(** The records from sequence 1 through [through], the binding's committed
    sequence, read by name. A missing or malformed record fails. *)
val read_observation : instance_id:string -> seq:int -> max_bytes:int -> t ->
  (Lane_addon_types.output, string) result
(** One immutable completed record. Missing, oversized and malformed records
    fail; callers must not advance a consumer cursor on those failures.
    The exact opened record and parent directory are strictly synced before
    accepting bytes, including when an earlier publication was unconfirmed.
    This does not rewrite or repair corrupted data. *)
val query_observations : t -> instance_id:string -> expected_seq:int -> max_bytes:int ->
  since:float option -> until:float option -> lane_id:string option ->
  (Lane_addon_types.output, string) result
(** Streams retained sequence files 1 through [expected_seq], the binding's
    committed sequence, with bounded response and per-record reads. A file
    above it is not committed and is not read. Matching rows have priority over source coverage. A second pass over the
    inspected prefix returns coverage for selected records first, then other
    source coverage, including observations without rows. Each coverage buffer
    is bounded by the space remaining after rows. The query receipt identifies
    the inspected prefix and explicitly reports omitted rows, omitted coverage,
    or unreadable observations; source coverage is not a chronological ledger. *)
val freeze : t -> instance_id:string -> binding:Yojson.Safe.t ->
  row_ids:string list -> (Yojson.Safe.t, string) result
(** Refuses a row whose sequence is above the [binding]'s [observation_seq]:
    only committed observations are evidence.
    The receipt includes [instance_id] and the exact validated [row_ids] from
    the frozen bundle, alongside its reference and row count. Publication keeps
    those selection coordinates; neither receipt implies delivery or reading. *)
val publish_for_keeper : base_path:string -> t -> Yojson.Safe.t ->
  (Yojson.Safe.t, string) result
(** Publishes a frozen bundle, its selected records and their retained source
    bodies byte-for-byte through the existing Tool artifact store. Only this
    store's verified content addresses are read; source bodies stay opaque. Host-owned [lane-sequence:] nodes alone are followed
    through their typed previous references, with every digest and count checked.
    The returned [message] is an exact retained artifact marker, and
    [keeper_artifact] names the manifest whose child references retain all
    published bytes for [keeper_artifact_read]. No message is sent here. *)

module For_testing : sig
  val tool_request_owner_inventory :
    after_listing:(string -> unit) -> sync_file:(Unix.file_descr -> unit) ->
    sync_parent:(Unix.file_descr -> unit) -> t -> scope:string ->
    ((string * Yojson.Safe.t) list, string) result
  val remove_binding : sync_parent:(string -> unit) -> t -> instance_id:string -> (unit, string) result
  val binding_inventory : sync_parent:(string -> unit) -> root:string -> binding_inventory
  val issue_detail : Fs_compat.owned_regular_file_read_error -> string
  val write : sync_parent:(string -> unit) -> t -> string -> string -> (unit, string) result
  val load_sampling_request_bounded :
    sync_file:(Unix.file_descr -> unit) -> sync_parent:(Unix.file_descr -> unit) ->
    budget:read_budget -> t -> instance_id:string -> request_id:string ->
    (Yojson.Safe.t option, bounded_read_error) result
  val save_action : sync_parent:(string -> unit) -> t -> instance_id:string ->
    request_id:string -> Yojson.Safe.t -> (unit, string) result
  val load_action : sync_file:(Unix.file_descr -> unit) -> sync_parent:(Unix.file_descr -> unit) ->
    t -> instance_id:string -> request_id:string -> (Yojson.Safe.t option, string) result
  val load_exact_request : sync_file:(Unix.file_descr -> unit) -> sync_parent:(Unix.file_descr -> unit) ->
    t -> declaration_id:string -> request_id:string -> (Yojson.Safe.t option, string) result
  val append_observation :
    replace_file:(string -> string -> (unit, Fs_compat.atomic_replace_failure) result) ->
    t -> instance_id:string -> seq:int -> sources:Yojson.Safe.t ->
    Lane_addon_types.output -> (unit, observation_write_error) result
  val save_binding_staged :
    replace_file:(string -> string -> (unit, Fs_compat.atomic_replace_failure) result) ->
    t -> instance_id:string -> Yojson.Safe.t -> (unit, binding_write_error) result
  val read_observation : sync_file:(Unix.file_descr -> unit) -> sync_parent:(Unix.file_descr -> unit) ->
    instance_id:string -> seq:int -> max_bytes:int -> t -> (Lane_addon_types.output, string) result

end
