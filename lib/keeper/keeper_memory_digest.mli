(** Frozen-per-memory-epoch Per-Keeper Memory Digest.

    Compiles a Keeper's current Memory OS snapshot into a deterministic,
    cache-stable Tier-1 digest block keyed by [(keeper_id, revision, sha256)].
    Across turns [N..N+K] while the Librarian revision has not advanced, the
    rendered digest bytes are strictly identical so prompt prefix caches remain
    100% warm — eliminating the legacy ["bodies omitted"] recall notice without
    breaking prompt cache stability.

    Disk reads and writes of the epoch cache file
    ([<keeper_id>.memory-digest.json]) run off the main Eio domain via
    {!Domain_pool_ref.submit_io_or_inline}. *)

type digest =
  { keeper_id : string
  ; revision : int
  ; digest_sha256 : string
  ; fact_count : int
  ; derived_count : int
  ; rendered : string
  }

val suffix : string
val default_max_rendered_bytes : int
(** Deterministic structural byte ceiling for inline Tier-1 digest rendering
    (8 KiB). Facts beyond this budget are summarized with a deterministic
    overflow pointer to [keeper_memory_search] so Tier-1 prompt injection stays
    strictly bounded while remaining 100% cache-stable within an epoch. *)

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

(** Pure deterministic compilation of a Memory OS snapshot into a frozen-epoch
    digest bounded by {!default_max_rendered_bytes}. Derived facts are
    prioritized first, followed by canonical category and [memory_id] order. *)
val compile
  :  keeper_id:string
  -> revision:int
  -> facts:Keeper_memory_os_types.fact list
  -> digest

(** Like {!compile} with an explicit inline byte ceiling [max_bytes]. *)
val compile_bounded
  :  max_bytes:int
  -> keeper_id:string
  -> revision:int
  -> facts:Keeper_memory_os_types.fact list
  -> digest

(** Load the cached digest for [(keepers_dir, keeper_id)] if it matches
    [(revision, digest_sha256)]; otherwise compile and atomically
    persist the new epoch digest off-domain via {!Domain_pool_ref}. *)
val load_or_compile
  :  keepers_dir:string
  -> keeper_id:string
  -> revision:int
  -> facts:Keeper_memory_os_types.fact list
  -> digest

(** Convenience wrapper returning the frozen Tier-1 rendered digest string for
    injection into {!Keeper_memory_os_recall}. Never returns ["bodies omitted"]. *)
val render_for_snapshot
  :  keepers_dir:string
  -> keeper_id:string
  -> revision:int
  -> facts:Keeper_memory_os_types.fact list
  -> string
