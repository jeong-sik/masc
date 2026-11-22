(** Channel 3 Bounded Muted Historical Incident Ledger.

    Records transient HTTP failures, decode warnings, stream gaps, and resolved
    past faults in a bounded 200-entry ledger. By construction, this module
    never mutates Channel 2 live operational health. *)

open Masc_tui_core

val max_entries : int
(** Hard ledger bound: [200]. *)

type t = {
  entries : Health.incident list;
  next_id : int;
  selected_index : int;
  scroll_offset : int;
  filter_query : string;
  show_dismissed : bool;
  unread_count : int;
}

val empty : t

val push :
  occurred_at_unix:float ->
  source:Health.incident_source ->
  summary:Say.t ->
  detail:string ->
  status:Health.incident_status ->
  t ->
  t * Health.incident
(** Append a new incident at the head of the ledger, evicting entries past
    {!max_entries}. *)

val dismiss : id:int -> t -> t
val dismiss_selected : t -> t
val clear_all : t -> t
val mark_all_read : t -> t

val visible_entries : t -> Health.incident list
val selected_entry : t -> Health.incident option
val find_by_id : int -> t -> Health.incident option

val move_selection : delta:int -> t -> t
val set_filter : string -> t -> t
val toggle_show_dismissed : t -> t

val count : t -> int
val active_count : t -> int
(** Count of entries whose status is not {!Health.Dismissed}. *)
