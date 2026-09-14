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
val render : keepers_dir:string -> keeper_name:string -> string option
(** Reads only the fixed-shape index. No source revalidation, queue traversal,
    snapshot serialization, or blob writes occur on the first-token path. *)
