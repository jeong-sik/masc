(** The key bindings, declared once.

    Dispatch stays the ordered match in masc_tui.ml — this table does not
    route keys. It is the single source the *displays* read: footer hints and
    the help overlay project from here, so they cannot drift from each other
    the way twenty-four hand-written footer strings and a second hand-written
    help table did (the old help documented g/G/f on System logs, where none
    of them are bound).

    Conventions the projections enforce: keys spell as typed (j/k, Enter,
    Esc, Tab, Ctrl-B); hints read [key:label] joined by two spaces; groups
    print in a fixed order so the same action sits in the same place on
    every screen. *)

type group =
  | Navigate  (** moving the cursor or the viewport *)
  | Act       (** doing something to the thing under the cursor *)
  | Search    (** finding a row *)
  | Meta      (** refresh, surface switching, quit *)

type binding = {
  key : string;
  label : string;      (** the footer's short word *)
  help : string option;  (** the overlay's longer sentence; [label] if absent *)
  group : group;
}

val global : binding list
(** Bindings that work on every surface: Tab, r, i, ?, :, Ctrl-B, Ctrl-T, q. *)

val for_surface : Masc_tui_types.surface -> binding list
(** The surface's own bindings, in declaration order within each group.
    Feeds both projections; a surface whose footer is not yet converted is
    still read by the help overlay. *)

val footer_hints : Masc_tui_types.surface -> string
(** [key:label] pairs joined by two spaces, groups in Navigate, Act, Search,
    Meta order. *)

val footer_hints_overview : task_focus:bool -> string
(** The Overview footer. Separate from {!footer_hints} because Overview owns
    one runtime fact the static table cannot: whether j/k currently drives
    the task list (task_focus) or the event list. The projection relabels
    j/k by focus and drops the keys dead in the other mode — the table
    stays the SSOT, no second key list. *)

val footer_hints_fusion_detail : scroll:int -> max_scroll:int -> string
(** The Fusion detail footer. Separate from {!footer_hints} because it appends
    the live scroll position, which the static per-surface table cannot know. *)

val help_sections : unit -> (string * (string * string) list) list
(** The help overlay's sections: Global first, then one section per surface
    that declares bindings, titled with the strip's spelling. *)
