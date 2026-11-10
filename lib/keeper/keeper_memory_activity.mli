(** Read-only, bounded memory change history. These observations grant no
    restoration, deletion or publication authority. *)

type kind = Created | Reobserved | Revised | Absorbed | Retracted | Removed | Invalidated
type fact = { memory_id : string; claim : string }
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
  identity:string -> absorbed:Keeper_memory_absorbed.record list ->
  Yojson.Safe.t -> (event list, string) result
(** Validate the entire persisted journal row before projecting it. Unchanged,
    failed and quarantine observations produce no change events. A legacy row
    without a transition marker is unavailable, never a repeated old change.
    Ordered publications retain intermediate stages. Legacy absorption requires
    an archive row matching the committed trace, clock, removed identity and
    added successor; an archive append alone is never commit evidence. *)

val read : keepers_dir:string -> keeper_id:string -> limit:int -> t
(** Read the last [limit] journal lines off the scheduler domain. Oldest first;
    offsets supply stable event identities. Errors remain [notes], distinct
    from an empty history. The absorbed archive is read only on this explicit
    activity request, not on the ordinary journal/chat path. No recovery/write. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Shared HTTP codec. Unknown kinds, malformed references and invalid clocks
    reject rather than becoming successful empty activity. *)
