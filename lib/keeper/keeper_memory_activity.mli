(** Read-only, bounded memory change history. These observations grant no
    restoration, deletion or publication authority. *)

type kind = Created | Reobserved | Revised | Absorbed | Retracted | Removed | Invalidated | Relation_unavailable
type fact = { memory_id : string; claim : string option }
(** [None] is an unresolved successor identity, never a confirmed claim. *)
type event =
  { identity : string
  ; recorded_at : float
  ; revision : int
  ; kind : kind
  ; before : fact list
  ; after : fact list
  ; reason : string option
  }
type t = { limit : int; journal_lines : int; events : event list; notes : string list }

val project :
  ?snapshot:Keeper_memory_os_current.t -> ?archive_error:string ->
  identity:string -> absorbed:Keeper_memory_absorbed.record list ->
  Yojson.Safe.t -> (event list, string) result
(** Validate the entire persisted journal row before projecting it. Unchanged,
    failed and quarantine observations produce no change events. A legacy row
    without a transition marker is unavailable, never a repeated old change.
    Ordered publications retain intermediate stages. Legacy absorption requires
    an archive row matching the committed trace, clock, removed identity and
    added successor; an archive append alone is never commit evidence.
    A guarded [snapshot] may resolve retained successors only when its full
    revision, clock, source and change match the journal row. Otherwise the
    candidate relation stays explicitly unavailable. [archive_error] also
    preserves unknown lineage, rather than inventing an empty archive. *)

val read : keepers_dir:string -> keeper_id:string -> limit:int -> t
(** Read the last [limit] journal lines off the scheduler domain. Oldest first;
    offsets supply stable event identities. The tail is fixed before reading
    any absorption archive, respecting archive-before-commit write order.
    Errors remain [notes], distinct
    from an empty history. The absorbed archive is read only on this explicit
    activity request, not on the ordinary journal/chat path. No recovery/write. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Shared HTTP codec. Unknown kinds, malformed references and invalid clocks
    reject rather than becoming successful empty activity. *)
