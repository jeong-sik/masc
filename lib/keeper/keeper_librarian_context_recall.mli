(** Background publication of organized context for bounded prompt recall.
    The index contains counts and one content-addressed reference, never queue
    bodies or a growing directory of pockets. Artifact pages use the existing
    in-process [keeper_artifact_read] surface in every sandbox/runtime. *)
val path : keepers_dir:string -> keeper_name:string -> string
val publish : base_path:string -> keepers_dir:string -> keeper_name:string ->
  Keeper_librarian_context.snapshot -> (unit, string) result
(** Publish after a successful context commit, on the Librarian IO worker.
    The artifact is historical context: sources and execution progress must be
    revalidated before acting. Failure never changes original input authority. *)
val render : ?artifact_reader_available:bool -> base_path:string -> keepers_dir:string -> keeper_name:string -> unit -> string option
(** Reads the fixed-shape index and injects its artifact only when its exact
    generation and revision still match a nonempty authoritative snapshot.
    An absent or empty authoritative snapshot emits a stable empty-state
    notice. A missing, corrupt or stale derived index is rebuilt from the
    current authoritative snapshot. An unavailable authority or failed repair
    emits a distinct stable unavailable notice. Both retire earlier artifact references
    as current context without granting authority or blocking original intake.
    The option is always [Some], including status notices, so persistent client
    sessions observe disappearance and can deduplicate an unchanged status.
    [artifact_reader_available] defaults to true; callers pass the observed
    availability of [keeper_artifact_read]. When false, no store is read and
    the unavailable notice retires previous pointers until capability returns. No
    source revalidation or queue traversal occurs here. The IO worker validates
    the blob and retains its structured reference before returning recall. Missing or
    damaged bytes are republished from the matching authoritative snapshot;
    failed repair emits unavailable. Historical pins use dated Keeper retention. *)

module For_testing : sig
  val render : before_retain:(unit -> unit) -> ?artifact_reader_available:bool ->
    base_path:string -> keepers_dir:string -> keeper_name:string -> unit -> string option
  (** Interleave an owner commit after observing the index and before retention. *)
end
