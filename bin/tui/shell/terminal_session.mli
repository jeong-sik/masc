(** Terminal ownership, raw-mode/signal lifecycle, resize tracking, frame
    presentation state, and window-title synchronization. *)

type t

val create : unit -> t
(** Snapshot current termios and reclaimed keys, detect extended terminal
    capabilities, synchronize MSX output policy, and allocate session state. *)

val enter : t -> unit
(** Register [at_exit] restoration/reporting hooks (preserving LIFO restore
    order), install POSIX signal handlers, and enter raw mode. *)

val create_render_schedule : unit -> Masc_tui_render_schedule.t
(** Build the 60 Hz coalescing render scheduler. *)

val setup_screen : t -> unit
(** Enter the alternate screen, enable mouse tracking, bracketed paste, and
    Kitty keyboard disambiguation (when supported), and observe out-of-band
    console writes. Call only after {!enter}. *)

val restore : t -> unit
(** Best-effort restoration of saved termios, reclaimed keys, alternate
    screen, and dynamic title on shutdown. *)

val hand_off : t -> unit
(** Suspend mouse reporting and restore canonical terminal settings before
    yielding the terminal to a child process. *)

val take_back : t -> unit
(** Reclaim raw mode, alternate screen, mouse tracking, and bracketed paste
    after a child process exits or after [SIGTSTP] resume. *)

val restore_for_music : t -> unit
(** Leave bracketed paste and Kitty keyboard protocol in addition to
    {!hand_off} before handing the terminal to the music workbench. *)

val reenter_from_music : t -> unit
(** Undo {!restore_for_music} and reclaim full terminal ownership. *)

val request_full_repaint : t -> unit
(** Record a resize/capability invalidation generation and wake the loop. *)

val set_keeper_preference_exit_warnings : t -> string list -> unit
(** Store unresolved Keeper preference warnings printed once during exit
    cleanup. *)

val presenter : t -> Masc_tui_frame_presenter.t
val exit_signals : t -> Masc_tui_exit_signals.t
val resize_requested : t -> bool
val take_resize_request : t -> bool
val resize_generation : t -> int
val bump_resize_generation : t -> unit

val toggle_mouse_tracking : t -> unit
val toggle_mouse_tracking_key : string
val toggle_roster_pane_key : string
val toggle_acting_pane_key : string
val toggle_browser_lane_key : string

val discard_frame_for_new_size
  : Masc_tui_frame_presenter.t -> Masc_tui_render_schedule.t -> unit

val invalidate_frame_for_resize
  : Masc_tui_frame_presenter.t -> Masc_tui_render_schedule.t -> unit

val request_console_write_repair : Masc_tui_render_schedule.t -> unit

val present_title : t -> Masc_tui_types.state -> unit
(** Emit an OSC 0 window/tab title update when dynamic titles are enabled. *)
