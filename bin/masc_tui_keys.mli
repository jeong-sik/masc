(** The key bindings, declared once.

    Dispatch mostly stays the ordered match in masc_tui.ml. Cross-surface
    shortcuts whose spelling is shared with the displays classify here too.
    Footer hints and the help overlay project from the same binding records,
    so behaviour and the two displays cannot silently choose different keys.

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
(** Shared bindings shown once in Help. Text input and modal panels can own a
    printable key before its cross-surface fallback runs; each such binding's
    help text states that boundary. *)

val opens_keepers : message_mode:bool -> string -> bool
(** Whether [key] is the shared Keepers jump after earlier input owners have
    declined it. Message mode never treats printable [2] as this jump. *)

val cancels_two_press :
  input_seen:bool -> key:string option -> second_press:string list -> bool
(** Whether the input the loop just read cancels a standing two-press
    confirmation whose second press is one of [second_press].

    [input_seen] is whether the loop read anything at all: it also turns on
    a timeout, and a turn that read nothing cancels nothing. [key] is what
    it read, and it is [None] for a mouse report, a paste, and a graphics
    reply -- deliberate input that is not the second press, so it cancels.

    The dispatch loop restated this rule once per armed field, and the
    connector unbind's restatement read the timeout turn as an unrelated
    key: its arm lived for one loop iteration, and two [u] presses removed a
    binding only when both bytes arrived in the same read. *)

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

type code_pane =
  | Code_tree  (** the file list has focus *)
  | Code_file  (** a file is open and nothing covers it *)
  | Code_overlay  (** history, diff or notes is drawn over the file *)

val footer_hints_code : pane:code_pane -> string
(** The Code footer, narrowed to what [pane] answers.

    Separate from {!footer_hints} because this surface has three modes and a
    key live in one is dead in another. It was a literal in the renderer
    naming [d], [H], [m] and [w], which is why the three language-server
    questions never appeared on the screen they work on, and why blame and
    the row search did not either when they arrived. *)

val footer_hints_resources : detail_focus:bool -> string
(** The Resources footer, with [j/k] relabelled for the focused pane. All
    other keys still project from {!for_surface}. *)

val footer_hints_fusion_detail : scroll:int -> max_scroll:int -> string
(** The Fusion detail footer. Separate from {!footer_hints} because it appends
    the live scroll position, which the static per-surface table cannot know. *)

val footer_hints_lanes_run_list : string
(** The Lanes run-list footer: the drill-down under a standalone lane row. *)

val footer_hints_lanes_run_detail : scroll:int -> max_scroll:int -> string
(** The Lanes run-detail footer, with the synchronized Input/Output scroll
    position appended the same way the Fusion detail footer does. *)

(** The Lanes lane-notice footer. The pane is static, so it keeps only the
    way back plus the shared tail. *)

val footer_hints_git_changes : string
(** The shared Git changes list under Repositories, Code, and Chat. *)

val footer_hints_git_diff : string
(** The Git diff view for a changed file in repository changes. *)

val footer_hints_memory_facts : string
(** The Memory fact browser opened by Enter on a health row: row movement,
    the category cycle, search, and the way back to the table. *)

val footer_hints_metrics : string
(** The Metrics telemetry dashboard footer. *)

val keeper_detail_tab_bindings :
  Masc_tui_types.keeper_detail_tab -> binding list
(** A detail tab's own keys. Separate from {!for_surface} because they are
    conditional on the tab, not the surface: listing them per surface would
    advertise them on the tabs where they do nothing. *)

val keeper_detail_tab_hint : Masc_tui_types.keeper_detail_tab -> string
(** The compact strip beside the tab row, [key:label] joined by two spaces,
    led by the tab switch. Projects {!keeper_detail_tab_bindings} so the
    strip and the help sheet cannot name different keys. *)

val help_sections :
  ?current:Masc_tui_types.surface -> unit -> (string * (string * string) list) list
(** Sections for the help sheet. [current] puts that surface's own section
    first and marks it, so the sheet opens on an answer rather than on a list
    to search. Omitted, the order is the strip's, as it was before the sheet
    knew where the reader was. *)
(** The help overlay's sections: Global first, then one section per surface
    that declares bindings, titled with the strip's spelling. *)
