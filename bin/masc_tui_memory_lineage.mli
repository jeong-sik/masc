(** A captured, read-only neighbourhood within one Keeper's retained history.
    Edges come only from persisted event endpoints, never claim similarity. *)
type t = private {
  selected : Masc.Keeper_memory_activity.event;
  events : Masc.Keeper_memory_activity.event list;
  facts : Masc.Keeper_memory_activity.fact list;
  journal_lines : int;
  limit : int;
  notes : string list;
}

val select : event_id:string -> Masc.Keeper_memory_activity.t -> t option
(** [None] when the selected event is absent. Retains exactly the connected
    component of observed memory identities, in original event order. *)

val kind_label : ko:bool -> Masc.Keeper_memory_activity.kind -> string
(** Shared change word and icon for the table and chart. *)

val transition_svg : ko:bool -> palette:Masc_tui_terminal_palette.t -> t -> string
(** Focus on the selected recorded transition: every prior fact, the change,
    and every successor. Wrapped excerpts retain their original text; the
    complete claims remain on Enter. Unknown relations stay explicit. The
    observed terminal palette owns the canvas and text colours. *)

val mermaid : ko:bool -> t -> string
(** Summarized labels, rounded fact nodes and explicit transition nodes for
    the existing offline Pele preview. Unknown relations use dotted edges.
    The retained window and partial/stale notes remain part of the chart.
    Full claims stay in the existing captured text reading. *)

val transition_mermaid : ko:bool -> t -> string
(** Palette-independent fallback with the same selected-transition scope as
    [transition_svg]. Never expands the default view to connected history. *)
