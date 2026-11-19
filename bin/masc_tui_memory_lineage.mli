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

val transition_svg : ko:bool -> now:float -> palette:Masc_tui_terminal_palette.t -> t -> string
(** Focus on the selected recorded transition: every prior fact, the change,
    and every successor, rendered with full wrapped claims, fact identifiers,
    optional transition reason, and deduplicated observation notes. Unknown
    relations stay explicit. The observed terminal palette owns the canvas and
    text colours. *)

val lineage_graph :
  ko:bool ->
  now:float ->
  ?palette:Masc_tui_terminal_palette.t ->
  keeper_name:string ->
  t ->
  string
(** Structured JSON scene for Pele [Graph] mode covering the connected lineage
    component with full wrapped claims, fact retention statuses, transition
    reasons, and deduplicated observation notes. *)

val mermaid : ko:bool -> now:float -> t -> string
(** Styled Mermaid fallback covering the connected lineage neighbourhood with
    full wrapped claims, deduplicated notes, and unknown-relation dashes. *)

val transition_mermaid : ko:bool -> now:float -> t -> string
(** Palette-independent fallback with the same selected-transition scope as
    [transition_svg]. Never expands the default view to connected history. *)
