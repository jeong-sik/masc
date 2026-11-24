(** Direct, occurrence-scoped fact transitions. A successor carries the source
    of its displayed body independently from the ID established by the removal. *)
type range = Time of float * float | Revisions of int * int
type position =
  { seq : int option
  ; revision : int option
  ; at : float
  ; source : Keeper_memory_os_current_types.source option
  }

type relation = Revision | Program_revision | Program_absorption
type body_source = Same_commit | Held_before | Current_snapshot | Archived_fact
type event =
  | Added of Keeper_memory_os_types.fact
  | Updated of { before : Keeper_memory_os_types.fact; after : Keeper_memory_os_types.fact;
                 relation : relation; body_source : body_source }
  | Successor_unavailable of { before : Keeper_memory_os_types.fact; successor_id : string; relation : relation }
  | Removed of { fact : Keeper_memory_os_types.fact; reason : string option; missing : string list option }

type gap = { first_seq : int; last_seq : int }
type t =
  { events : (position * event) list
  ; ticks : Librarian_memory_change.t list
  ; gaps : gap list
  ; unsequenced_in_range : int
  ; snapshot_ahead : bool
  ; snapshot_behind : bool
  }

val project : range:range -> current:Keeper_memory_os_types.fact list -> revision:int -> Librarian_archive.history -> t
