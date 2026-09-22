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

(** Whether a binding answers while a surface's detail is open.

    A surface that owns a detail draws one footer for two states, so it used
    to advertise exactly one key the dispatcher refuses in the state on
    screen: [Right / Enter] once a detail is already open, [[ / ]] while it
    is not. The fact was in the table already, but only as prose inside
    [help], which no footer can read. *)
type detail_state =
  | Either  (** answers in both states; the default *)
  | List_only  (** only while no detail is open *)
  | Detail_only  (** only while a detail is open *)

type binding = {
  key : string;
  label : string;      (** the footer's short word *)
  help : string option;  (** the overlay's longer sentence; [label] if absent *)
  group : group;
  detail : detail_state;  (** which of a detail-owning surface's two states *)
}

val expand_turn_key : string
(** Ctrl-S: fold the turn dashboard to its progress line, or unfold it. *)

val expand_turn_label : string
(** How that key is printed on the folded line. Beside the byte so the name
    and the binding cannot drift apart. *)

val voice_speak_key : string
val voice_listen_key : string
(** Ctrl-Y and Ctrl-A as the table spells them, for the rows that name them
    beside a draft or a capture. *)


val roster_toggle_key : string
(** Ctrl-B, as the roster pane's title names it. *)

val keeper_calls_key : string
(** [t] on a keeper: the Keeper Calls view, where a call's served input and
    output are drawn whole. *)

val context_inspector_key : string
val context_inspector_label : string
(** Ctrl-X: the byte the chat matches and the name the context header prints
    beside the figure it explains. The table lists no footer binding for it;
    its home is that row. *)

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

val footer_hints : ?detail_open:bool -> Masc_tui_types.surface -> string
(** [key:label] pairs joined by two spaces, groups in Navigate, Act, Search,
    Meta order.

    [detail_open] is how a surface that owns a detail says which of its two
    states is on screen, so the footer drops the key the dispatcher refuses
    there. A surface without a detail leaves it out and every binding stands.
    Left out by a surface that does own one, every binding stands too -- the
    behaviour from before this argument existed, and the one
    {!has_detail_scoped_keys} exists to catch. *)

val has_detail_scoped_keys : Masc_tui_types.surface -> bool
(** Whether this surface's table scopes any binding to one of the two states,
    and so owes [footer_hints] a [~detail_open] from both of its renderers.
    Read by the test that keeps a new detail-owning surface from landing
    without it. *)

val footer_hints_config : pane:Masc_tui_types.config_pane -> string
(** Config bindings available on the active pane. The surface-wide help keeps
    the union, with pane restrictions explained by each binding. *)

val footer_hints_board_compose_writing : string
(** The Board draft while it takes letters: a literal "type to write" and the
    keys that are not letters. *)

val footer_hints_board_compose_armed : reply:bool -> string
(** The Board draft's send menu after Esc. [reply] drops the hearth cycle a
    comment has no use for. *)

val footer_hints_approval_detail : string
(** The keys an open approval answers to. The decision keys are one item
    ("y / n"), the spelling {!Masc_tui_footer} pins, so a narrow row gives up
    the scroll before it gives up the answer. *)

val footer_hints_voice_agent : unit -> string
(** The keeper-voice screen's own row: the keeper axis, the voice axis, the
    write and the way out. Its keys are not the Config pane's, so the row is
    the screen's rather than the pane's. *)

val footer_hints_prompt_assets : string
(** The prompts pane while it shows the read-only runtime assets: its keys
    without the ones that edit the registry, and [o] named for the way back. *)

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

val footer_hints_runtime : mode:Masc_tui_types.runtime_mode -> string
(** The Runtime footer: {!for_surface} [Runtime] with [p] labelled for where it
    goes from [mode], and [e] only on the keeper-lane reading. *)

val footer_hints_resources : detail_focus:bool -> string
(** The Resources footer, with [j/k] relabelled for the focused pane. All
    other keys still project from {!for_surface}. *)

val footer_hints_board_read : focus_posts:bool -> split:bool -> string
(** The Board read footer. [focus_posts] is whether j/k moves the post list
    beside the open post rather than scrolling it; [split] is whether that
    list is on screen, which is when h/l and Ctrl-W have a pane to reach. The
    vote, reply and copy keys are the Board surface list's own bindings. *)

val footer_hints_fusion_detail : position:string -> string
(** The Fusion detail footer. Separate from {!footer_hints} because it appends
    the window the renderer drew, which the static per-surface table cannot
    know. *)

val footer_hints_lanes_run_list : string
(** The Lanes run-list footer: the drill-down under a standalone lane row. *)

val footer_hints_lanes_run_detail : position:string option -> string
(** The Lanes run-detail footer, with the window the stacked Input/Output list
    drew appended the way the Fusion detail footer does; [None] where the two
    split panes' titles already name theirs. *)

(** The Lanes lane-notice footer. The pane is static, so it keeps only the
    way back plus the shared tail. *)

val footer_hints_git_changes : string
(** The shared Git changes list under Repositories, Code, and Chat. *)

val footer_hints_git_diff : string
(** The Git diff view for a changed file in repository changes. *)

val footer_hints_memory_facts : string
(** The Memory fact browser opened by Enter on a health row: row movement,
    the category cycle, search, and the way back to the table. *)

val bindings_memory_facts : binding list
(** The fact browser's own keys. Separate from {!for_surface} because they are
    conditional on the browser being open: the health row's [Enter], [s] and
    [Esc] mean other things under these names, so [?] files them under Memory
    with the screen named. *)

val bindings_memory_fact_detail : binding list
(** The reading the browser's [Enter] opens. One fact scrolls under the
    cursor instead of the cursor moving rows, so it owns page and edge keys
    the browser row has none of; [?] files them under Memory with the screen
    named. *)

val memory_fact_detail_hints : string
(** The keys the reading's footer row leads with, [key:label] joined by two
    spaces. Projects {!bindings_memory_fact_detail}, so the footer and the
    help sheet cannot name different keys. The renderer leads the row with the
    window marker, which is not a key. *)

val keeper_detail_tab_bindings :
  Masc_tui_types.keeper_detail_tab -> binding list
(** A detail tab's own keys. Separate from {!for_surface} because they are
    conditional on the tab, not the surface: listing them per surface would
    advertise them on the tabs where they do nothing. *)

val key_atoms : string -> string list
(** The single keys a binding's [key] names: ["d/m/s"] is [d], [m] and [s],
    ["b / e / u u"] is [b], [e] and [u], ["arrows+enter"] is [arrows] and
    [enter]. Sorted, without repeats. *)

val keeper_detail_tab_taken_keys : Masc_tui_types.keeper_detail_tab -> string list
(** The single keys the tab's own bindings answer ({!key_atoms}); a Keeper
    control on one of them does something else on that tab. *)

val keeper_detail_tab_hint : Masc_tui_types.keeper_detail_tab -> string
(** The keys the Keeper detail footer leads with, [key:label] joined by two
    spaces, led by the tab switch. Projects {!keeper_detail_tab_bindings} so
    the footer and the help sheet cannot name different keys. *)

val sheet_bindings : Masc_tui_types.surface -> binding list
(** {!for_surface} as the help sheet lists it: without the refresh / next /
    quit tail the Global section already names. A surface that labels one of
    those keys its own way keeps it. *)

val here_marker : string
(** Marker appended to the current surface section title in {!help_sections}. *)

val help_surfaces : (string * Masc_tui_types.surface) list
(** One sheet section per surface family, and the surface it answers for. Read
    by the guard that checks a destination the palette offers by name is named
    that way on the sheet. *)

val help_sections :
  ?current:Masc_tui_types.surface -> unit -> (string * (string * string) list) list
(** Sections for the help sheet. [current] puts that surface's own section
    first and marks it, so the sheet opens on an answer rather than on a list
    to search. Omitted, the order is the strip's, as it was before the sheet
    knew where the reader was. *)
(** The help overlay's sections: Global first, then one section per surface
    that declares bindings, titled with the strip's spelling. *)

val footer_hints_browser_lane : string
