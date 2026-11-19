(** Background publication of organized context for bounded prompt recall.
    The index contains counts and one content-addressed reference, never queue
    bodies or a growing directory of pockets. Artifact pages use the existing
    in-process [keeper_artifact_read] surface in every sandbox/runtime. *)
val filename_suffix : string
(** [<keeper_name><filename_suffix>] is the index file in the config
    [keepers/] directory. *)
val path : keepers_dir:string -> keeper_name:string -> string
val publish : base_path:string -> keepers_dir:string -> keeper_name:string ->
  Keeper_librarian_context.snapshot -> (unit, string) result
(** Publish after a successful context commit, on the Librarian IO worker.
    The artifact is historical context: sources and execution progress must be
    revalidated before acting. Failure never changes original input authority.
    The artifact and the counts in the index hold the pockets the Keeper may
    read now ({!Keeper_librarian_context_readership.shown}); a pocket that
    names a Board source the Keeper cannot read, or an event source that no
    longer decodes, is left out. When pockets are stored and none is readable
    this is [Error] and the previous index stays. *)
val render : ?artifact_reader_available:bool -> base_path:string -> keepers_dir:string -> keeper_name:string -> unit -> (string option, string) result
(** Reads the fixed-shape index and injects its artifact only when its exact
    generation and revision still match a nonempty authoritative snapshot.
    The artifact holds the pockets {!publish} would publish now. Readership
    can change while the revision stays, so the index is current only while
    it points at the bytes those pockets render to; otherwise it is rebuilt.
    When pockets are stored and none is readable, the unavailable notice is
    emitted.
    An absent or empty authoritative snapshot emits a stable empty-state
    notice. A missing, corrupt or stale derived index is rebuilt from the
    current authoritative snapshot. An unavailable authority or failed repair
    emits a distinct stable unavailable notice. Both retire earlier artifact references
    as current context without granting authority or blocking original intake.
    Confirmed absent or empty context also retires the exact current retention
    pin observed before the authoritative read. Unavailable context preserves
    that pin, and a later publication cannot be retired by an older read.
    On success the option is always [Some], including status notices, so persistent client
    sessions observe disappearance and can deduplicate an unchanged status.
    [artifact_reader_available] defaults to true; callers pass the observed
    availability of [keeper_artifact_read]. When false, no store is read and
    the unavailable notice retires previous pointers until capability returns.
    Apart from that readership check, no source revalidation or queue
    traversal occurs here. The IO worker validates
    the blob and retains its structured reference before returning recall. Missing or
    damaged bytes are republished from the matching authoritative snapshot;
    failed repair emits unavailable. Historical pins use dated Keeper retention.
    Missing or invalid managed guidance is an explicit [Error], distinct from
    an empty snapshot or unavailable context storage. *)

module For_testing : sig
  val render : before_retain:(unit -> unit) -> ?before_retire:(unit -> unit) ->
    ?after_repair_publish:(unit -> unit) ->
    ?artifact_reader_available:bool ->
    base_path:string -> keepers_dir:string -> keeper_name:string -> unit -> (string option, string) result
  (** Interleave a publication before retention, after confirming empty
      authority and before retiring the previously observed pin, or between a
      repair's publication and its read-back of the index. *)
end
