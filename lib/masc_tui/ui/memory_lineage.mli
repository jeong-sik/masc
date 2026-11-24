(** Pure memory transition & connected-lineage chart builder.

    Captures a read-only neighbourhood within one Keeper's retained memory
    history. Edges come exclusively from persisted event endpoints, never claim
    similarity. Unconfirmed relations ([Relation_unavailable]) remain explicit
    and are never upgraded even when an observed body exists for the same
    memory identity.

    Pure module: zero terminal, filesystem, or [Unix] I/O. *)

type fact = {
  memory_id : string;
  claim : string option;
}

type event_kind =
  | Created
  | Reobserved
  | Revised
  | Absorbed
  | Retracted
  | Removed
  | Invalidated
  | Relation_unavailable

type event = {
  identity : string;
  recorded_at : float;
  revision : int;
  kind : event_kind;
  before : fact list;
  after : fact list;
  reason : string option;
}

type activity = {
  events : event list;
  limit : int;
  journal_lines : int;
  notes : string list;
}

(** A captured, read-only connected neighbourhood around one selected event. *)
type chart = private {
  selected : event;
  events : event list;
  facts : fact list;
  journal_lines : int;
  limit : int;
  notes : string list;
}

type t = chart

type snapshot = {
  fact : fact;
  revision : int;
  category : string;
  origin : string;
  first_seen : float;
  last_seen : float;
  activity_entries : int option;
}

type diagram =
  | Lineage of chart
  | Current_snapshot of snapshot

val equal_event_kind : event_kind -> event_kind -> bool

val select : event_id:string -> activity -> chart option
(** Returns [None] when [event_id] is absent from [activity.events]. Otherwise
    retains the exact connected component of observed memory identities in
    original persisted event order. *)

val kind_label : ko:bool -> event_kind -> string
(** Shared change icon and word for tables, SVG cards, graphs, and trees. *)

val fact_claim_text : ko:bool -> chart -> fact -> string
(** Resolve the observed claim body for [fact.memory_id] within [chart], or an
    explicit unreported marker when no non-empty claim was observed. *)

val fact_status : ko:bool -> chart -> fact -> string * string
(** Returns [(machine_status, localized_badge)] where [machine_status] is one of
    ["retained"], ["consumed"], or ["unconfirmed"]. *)

val dedup_notes : string list -> string list
(** Sanitize and deduplicate observation notes while preserving first-seen order. *)

val wrap_full_lines : max_cells:int -> string -> string list
(** Word- and grapheme-cluster-aware line wrapper preserving 100% of text
    without ellipsis truncation, measured via
    {!Masc_tui_term.Grapheme.display_width}. *)

val format_instant : ?tz_offset_sec:int -> now:float -> float -> string
(** Pure calendar formatter matching same-day ([HH:MM]), same-year
    ([MM-DD HH:MM]), and cross-year ([YYYY-MM-DD HH:MM]) precision without
    calling [Unix]. *)

val snapshot_lines :
  ?tz_offset_sec:int -> ko:bool -> ?now:float -> max_width:int -> snapshot -> string list

val snapshot_mermaid :
  ?tz_offset_sec:int -> ko:bool -> ?now:float -> snapshot -> string
(** A current fact is one node with no transition and no journal edges. *)

val transition_svg :
  ?tz_offset_sec:int ->
  ko:bool ->
  now:float ->
  palette:Masc_tui_term.Palette.t ->
  chart ->
  string
(** 3-stage Before -> Change/Reason -> After SVG card for the selected
    transition with full wrapped claims, fact IDs, optional reason box,
    deduplicated notes, and observed terminal palette colors (RFC-0515 §2.5). *)

val formation_graph_json :
  ?tz_offset_sec:int ->
  ko:bool ->
  ?now:float ->
  ?palette:Masc_tui_term.Palette.t ->
  ?keeper_name:string ->
  chart ->
  string
(** Structured JSON scene for Pele [Graph] mode covering the connected memory-ID
    neighbourhood, marking the selected change with [★] and [Relation_unavailable]
    edges as dashed. *)

val mermaid : ?tz_offset_sec:int -> ko:bool -> ?now:float -> chart -> string
(** Styled Mermaid [flowchart TD] covering the connected lineage neighbourhood
    with full wrapped claims, selected-change star, deduplicated notes, and
    dotted edges for [Relation_unavailable]. *)

val transition_mermaid :
  ?tz_offset_sec:int -> ko:bool -> ?now:float -> chart -> string
(** Palette-independent Mermaid fallback with the same single-transition scope
    as {!transition_svg}. Never expands the default focus view to connected
    history. *)
