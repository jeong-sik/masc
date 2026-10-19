(** Owner-locked quarantine journal. Strict-sync before moving either entry.
    The caller holds the queue owner lock and owns the directory; this does not
    exclude unrelated processes bypassing that ownership. *)
type slot = Snapshot | Transition_wal
type t
type moved =
  { path : string
  ; rejected_path : string
  ; moved_with : (string * string) option
  }
val filename : string
val path : snapshot:string -> string
val guard : snapshot:string -> (unit, string) result
(** Refuse every present journal entry, including malformed or indirect entries.
    Only physical absence permits access. *)
val read : snapshot:string -> wal:string -> (t option, string) result
val start :
  snapshot:string -> wal:string -> rejected:slot ->
  rejected_path_of:(string -> string) -> (t, string) result
(** Capture both entries, including originally absent partners, and strict-sync
    the journal. Destinations must be unused rejected siblings of their source.
    A failed publication never authorizes a move. *)
val finish :
  sync_intent:(string -> (unit, string) result) ->
  rename:(string -> string -> unit) -> before_clear:(unit -> unit) ->
  snapshot:string -> wal:string -> t -> (moved, string) result
(** Forward only, WAL first. Reuse recorded destinations and verify no-follow
    identity and regular bytes or link target on every retry. Sync the moved
    directory before removing the journal and sync it again. No rollback or
    cleanup-on-failure. Cancellation propagates. *)
