(** Raw-mode termios lifecycle and POSIX/BSD [c_cc] special-key reclamation,
    with cancellation-safe [Eio.Switch.on_release] teardown. *)

type reclaimed_key =
  | Literal_next    (** VLNEXT (Ctrl-V) *)
  | Discard_output  (** VDISCARD (Ctrl-O on BSD) *)
  | Delayed_suspend (** VDSUSP (Ctrl-Y on BSD) *)
  | Quit            (** VQUIT (Ctrl-backslash) *)

val key_char : Unix.file_descr -> reclaimed_key -> int
(** Current character in [0..255], or [-1] if [fd] is not a TTY or platform lacks the slot. *)

val set_key_char : Unix.file_descr -> reclaimed_key -> int -> bool
val disable_key : Unix.file_descr -> reclaimed_key -> bool

type snapshot
(** Captured [c_cc] characters for all reclaimed keys prior to {!reclaim}. *)

val snapshot : Unix.file_descr -> snapshot
val reclaim : Unix.file_descr -> unit
val restore : Unix.file_descr -> snapshot -> unit

type restore_outcome =
  | Restored
  | Already_restored
  | Terminal_gone of Unix.error

type raw_session

val enter_raw_mode : Unix.file_descr -> (raw_session, Unix.error) result
(** Put [fd] into raw TUI mode (keeping [ISIG] active for Ctrl-C/Ctrl-Z while
    reclaiming VLNEXT/VDISCARD/VDSUSP/VQUIT). *)

val restore_raw_mode : raw_session -> restore_outcome
(** Idempotently restore saved [Unix.terminal_io] and reclaimed keys. *)

val with_raw_mode_switch :
  sw:Eio.Switch.t -> Unix.file_descr -> (raw_session, Unix.error) result
(** Enter raw mode and register idempotent restoration on [Eio.Switch.on_release]. *)
