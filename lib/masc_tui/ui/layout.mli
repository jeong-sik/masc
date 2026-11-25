(** Responsive 4-breakpoint classification, deterministic constraint layout
    splits, v2.5 spatial rhythm spacing helpers, chrome row budgets, and
    empty-card non-eviction collapsing.

    Pure geometry only — zero global state, zero terminal I/O. *)

module Rect = Masc_tui_core.Rect

type breakpoint =
  | Wide      (** [cols >= 140 && rows >= 36] *)
  | Standard  (** [cols >= 100 && rows >= 28] (when not {!Wide}) *)
  | Compact   (** [cols >= 80 && rows >= 24] (when not {!Wide} or {!Standard}) *)
  | Micro     (** [cols < 80 || rows < 24] *)

type constraint_ =
  | Fixed of int
  | Ratio of float
  | Min_max of { min : int; max : int; weight : int }
  | Flex of int

type 'a card_slot = {
  id : 'a;
  is_empty : bool;
  constraint_ : constraint_;
}

val equal_breakpoint : breakpoint -> breakpoint -> bool
val breakpoint_name : breakpoint -> string

val classify_viewport : cols:int -> rows:int -> breakpoint
(** Deterministically classify terminal dimensions into one of the 4 exact
    breakpoints. *)

val is_too_small_blocker : cols:int -> rows:int -> bool
(** [true] only when [< 40] cols or [< 12] rows; {!Micro} remains a usable
    non-corrupting minimal cockpit above this threshold. *)

val chrome_rows :
  breakpoint -> composer_expanded:bool -> approval_strip:bool -> int
(** Exact top+bottom chrome height budget for [breakpoint]. At {!Compact}, an
    idle empty composer folds into the footer (3 rows total); expanding the
    composer adds 1 row; an active approval strip adds 1 row on non-Micro. *)

(** {1 v2.5 Spatial Rhythm & Anti-Void Helpers} *)

val outer_margin : breakpoint -> int
(** Outer viewport horizontal margin per side: [1] on {!Wide}/{!Standard},
    [0] on {!Compact}/{!Micro}. *)

val card_gap_x : breakpoint -> int
(** Horizontal inter-card gutter: [2] on {!Wide}, [1] on {!Standard}/{!Compact},
    [0] on {!Micro}. *)

val card_gap_y : breakpoint -> int
(** Vertical inter-card gutter: [1] on {!Wide}/{!Standard},
    [0] on {!Compact}/{!Micro}. *)

val card_pad_x : breakpoint -> int
(** Card interior horizontal padding inside [│ ... │]: [2] on {!Wide}/{!Standard},
    [1] on {!Compact}/{!Micro}. *)

val card_pad_x_for_width : breakpoint -> int -> int
(** Card padding for an interior of the given width. *)

val table_col_gap : breakpoint -> int
(** Table column gap: [2] on {!Wide}/{!Standard}, [1] on {!Compact}/{!Micro}. *)

val tab_gap : breakpoint -> int
(** Spacing between top-rail workspace tabs / filter chips: [2] on
    {!Wide}/{!Standard}, [1] on {!Compact}/{!Micro}. *)

val sub_tab_gap : breakpoint -> int
(** Spacing between sub-tab labels: [3] on {!Wide}/{!Standard},
    [2] on {!Compact}/{!Micro}. *)

val inset_body : breakpoint -> Rect.t -> Rect.t
(** Apply {!outer_margin} left & right to a viewport body rectangle so cards
    breathe cleanly off the terminal walls on {!Wide}/{!Standard}. *)

val adaptive_list_height :
  items:int -> ?overhead:int -> min_h:int -> max_h:int -> unit -> int
(** Anti-void card height [clamp(items + overhead, min_h, max_h)] (default
    [overhead = 4]: 2 borders + 1 header + 1 breathing/notice row). *)

(** {1 Constraint Partitioning} *)

val allocate : total:int -> ?gap:int -> constraint_ list -> int list
(** Allocate [total] integer cells across [constraints] separated by [gap]
    (default [0]). The returned list always has the same length as
    [constraints], all sizes are non-negative, and the sum of sizes plus gaps
    never exceeds [max 0 total]. *)

val split_h : ?gap:int -> Rect.t -> constraint_ list -> Rect.t list
(** Partition [rect] horizontally left-to-right according to [constraints]. *)

val split_v : ?gap:int -> Rect.t -> constraint_ list -> Rect.t list
(** Partition [rect] vertically top-to-bottom according to [constraints]. *)

val split_h_bp : breakpoint -> Rect.t -> constraint_ list -> Rect.t list
(** {!split_h} using {!card_gap_x} for [breakpoint]. *)

val split_v_bp : breakpoint -> Rect.t -> constraint_ list -> Rect.t list
(** {!split_v} using {!card_gap_y} for [breakpoint]. *)

val adaptive_split_2 :
  ?stack_on_compact:bool ->
  ?left_ratio:float ->
  ?top_ratio:float ->
  breakpoint ->
  Rect.t ->
  Rect.t * Rect.t
(** Master-detail 2-pane split: splits horizontally with {!card_gap_x} on
    {!Wide}/{!Standard} (and {!Compact} when [stack_on_compact = false]), or
    stacks vertically with {!card_gap_y} on narrow viewports. Defaults:
    [stack_on_compact = true], [left_ratio = 0.48], [top_ratio = 0.46]. *)

val collapse_empty_cards :
  ?gap:int -> Rect.t -> 'a card_slot list -> ('a * Rect.t) list * 'a list
(** Empty-state non-eviction helper: removes slots with [is_empty = true],
    returns their IDs in the second list so callers can surface them as compact
    top-rail badges, and redistributes 100% of [rect] across active cards. *)
