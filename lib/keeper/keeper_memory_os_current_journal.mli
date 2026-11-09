(** The reading of a snapshot file and the appending to its journal: the
    source kind, JSON and digest of a snapshot, the parse of snapshot text,
    the guard that refuses a read while publication recovery is pending, the
    classified read, the projection and cache of recall revisions read from
    the journal with the commit observer, and the strict and plain appends of
    a journal line and entry with the Librarian failure and the snapshot
    quarantine records.

    [Keeper_memory_os_current] includes this module. *)

open Keeper_memory_os_types
open Keeper_memory_os_current_types
open Keeper_memory_os_support_core

val source_kind_to_string : source_kind -> string

val to_json : t -> Yojson.Safe.t

val snapshot_sha256 : t -> string

val parse :
  string -> string -> (t, string) result

val publication_read_guard :
  keepers_dir:string -> keeper_id:string -> (unit, string) result

type read_classified =
  | No_snapshot
  | Readable of t
  | Undecodable of { rejection : string }
  | Io_unreadable of { detail : string }

val read_classified :
  keepers_dir:string -> keeper_id:string -> read_classified

val librarian_failure_kind_to_string : librarian_failure_kind -> string

module Recall_revision_set :
  sig
    type elt = int
    type t = Set.Make(Int).t
    val empty : t
    val add : elt -> t -> t
    val singleton : elt -> t
    val remove : elt -> t -> t
    val union : t -> t -> t
    val inter : t -> t -> t
    val disjoint : t -> t -> bool
    val diff : t -> t -> t
    val cardinal : t -> elt
    val elements : t -> elt list
    val min_elt : t -> elt
    val min_elt_opt : t -> elt option
    val max_elt : t -> elt
    val max_elt_opt : t -> elt option
    val choose : t -> elt
    val choose_opt : t -> elt option
    val find : elt -> t -> elt
    val find_opt : elt -> t -> elt option
    val find_first : (elt -> bool) -> t -> elt
    val find_first_opt : (elt -> bool) -> t -> elt option
    val find_last : (elt -> bool) -> t -> elt
    val find_last_opt : (elt -> bool) -> t -> elt option
    val iter : (elt -> unit) -> t -> unit
    val fold : (elt -> 'acc -> 'acc) -> t -> 'acc -> 'acc
    val map : (elt -> elt) -> t -> t
    val filter : (elt -> bool) -> t -> t
    val filter_map : (elt -> elt option) -> t -> t
    val partition : (elt -> bool) -> t -> t * t
    val split : elt -> t -> t * bool * t
    val is_empty : t -> bool
    val is_singleton : t -> bool
    val mem : elt -> t -> bool
    val equal : t -> t -> bool
    val compare : t -> t -> elt
    val subset : t -> t -> bool
    val for_all : (elt -> bool) -> t -> bool
    val exists : (elt -> bool) -> t -> bool
    val to_list : t -> elt list
    val of_list : elt list -> t
    val to_seq_from : elt -> t -> elt Seq.t
    val to_seq : t -> elt Seq.t
    val to_rev_seq : t -> elt Seq.t
    val add_seq : elt Seq.t -> t -> t
    val of_seq : elt Seq.t -> t
  end

type recall_journal_projection =
  { revisions : Recall_revision_set.t
  ; retired : int Identity_map.t
  ; highest : int
  ; rewrites_rev : Keeper_memory_os_successor_recall.transition list
  ; invalid : string option
  }

type recall_journal_cache =
  { oldest : int
  ; identity : Unix.stats
  ; projection : recall_journal_projection
  }

val recall_journal_cache :
  recall_journal_cache Identity_map.t Atomic.t

val empty_recall_projection : recall_journal_projection

val publish_recall_cache : string -> recall_journal_cache option -> unit

val retired_identities : change -> string list

val project_recall_entry :
  oldest:int ->
  recall_journal_projection ->
  Dated_jsonl.recent_entry -> recall_journal_projection

val install_commit_observer :
  (keepers_dir:string -> keeper_id:string -> unit) -> (unit -> unit)

val append_journal_line_strict :
  keepers_dir:string ->
  keeper_id:string -> Yojson.Safe.t -> (unit, string) result

val append_journal_entry :
  keepers_dir:string ->
  keeper_id:string ->
  commit_effect:commit_effect ->
  revision_links:revision list ->
  dropped_statements:dropped_statement list option ->
  t -> unit

val dropped_by_commit :
  previous:t option ->
  next:t ->
  dropped_statement list ->
  dropped_statement list

val append_librarian_failure :
  keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> trace_id:string
  -> kind:librarian_failure_kind
  -> detail:string
  -> snapshot_present:bool
  -> unit

val append_snapshot_quarantine :
  keepers_dir:string ->
  keeper_id:string ->
  now:float -> rejection:string -> rejected_path:string -> unit
