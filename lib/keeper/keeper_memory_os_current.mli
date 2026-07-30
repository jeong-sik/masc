(** Keeper-owned current Memory OS snapshot.

    This is the only production persistence authority for Memory OS content.
    A missing file means fresh empty state. Historical facts/event JSONL files,
    episode directories, and alternate store layouts are never read.

    Librarian updates replace the complete current fact set. The same atomic
    write records the exact added/removed delta that the dashboard projects.
    Recall reads [facts] from this snapshot directly; it does not rank, trim, or
    select records. *)

type source_kind =
  | Librarian
  | Explicit_write

type source =
  { kind : source_kind
  ; trace_id : string
  ; generation : int
  }

type change =
  { added : Keeper_memory_os_types.fact list
  ; removed : Keeper_memory_os_types.fact list
  ; retained : int
  }

type t =
  { revision : int
  ; updated_at : float
  ; source : source
  ; summary : string
  ; facts : Keeper_memory_os_types.fact list
  ; open_items : string list
  ; constraints : string list
  ; preserved_tool_refs : string list
  ; change : change
  }

val schema : string

val path : keeper_id:string -> string
val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

val list_keeper_ids : unit -> string list
val list_keeper_ids_for_keepers_dir : keepers_dir:string -> string list

val read : keeper_id:string -> (t option, string) result
val read_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> (t option, string) result

val replace
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> keeper_id:string
  -> now:float
  -> source:source
  -> summary:string
  -> facts:Keeper_memory_os_types.fact list
  -> open_items:string list
  -> constraints:string list
  -> preserved_tool_refs:string list
  -> unit
  -> (t, string) result
(** Atomically replace the complete current snapshot. Duplicate fact identities
    reject before writing. Existing state must parse as the exact current
    schema; malformed or non-current state fails closed and is not overwritten. *)

val upsert_fact
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> keeper_id:string
  -> now:float
  -> source:source
  -> Keeper_memory_os_types.fact
  -> (t, string) result
(** Atomically insert or replace one explicit keeper-authored fact while
    preserving the rest of the current snapshot. A matching identity is
    replaced by the explicit incoming fact; no local importance, recency, or
    echo heuristic participates. *)

val to_json : t -> Yojson.Safe.t

module For_testing : sig
  val with_keepers_dir : string -> (unit -> 'a) -> 'a
end
