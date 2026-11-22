(** Non-blocking ordered terminal byte sink backed by a dedicated POSIX writer
    thread, plus Kitty [CSI u] / alt-screen lifecycle sequences and
    [Eio.Switch.on_release] teardown. *)

val set_on_write_lost : (unit -> unit) -> unit
(** Register an optional wake callback fired from the writer thread when a
    stdout write fails (e.g. to signal the UI wake bell). *)

val write_all_fd :
  ?stall_limit_s:float ->
  ?on_progress:(unit -> unit) ->
  Unix.file_descr ->
  string ->
  (unit, Unix.error) result
(** Write every byte of [bytes] to [fd], retrying [EINTR] and waiting for
    writability via [Unix.select] on [EAGAIN]/[EWOULDBLOCK] so non-blocking
    PTYs/pipes never truncate large CSI 2026 frames. Aborts with [Error EAGAIN]
    if no forward write progress occurs for [stall_limit_s] seconds. *)

val write : string -> unit
(** Append bytes to the lock-free atomic queue without blocking the UI domain. *)

val flush : unit -> unit
(** Wake the writer systhread to emit queued bytes. *)

val behind : unit -> bool
(** [true] while bytes are queued or mid-[write(2)], allowing the render loop
    to coalesce intermediate frames on slow links. *)

val take_lost : unit -> bool
(** Returns [true] if a write failed since the last call, clearing the flag. *)

type drained =
  | Drained
  | Abandoned

val handoff_limit_s : float
(** Maximum time without terminal read progress before {!drain} gives up. *)

val drain : within_s:float -> drained
(** Wait until queued bytes reach stdout or stall past [within_s]. *)

val enter_screen_seq :
  kitty_keyboard:bool -> mouse:bool -> bracketed_paste:bool -> string
(** Enter alt-screen, hide cursor, enable optional bracketed paste, SGR mouse,
    and Kitty keyboard protocol ([CSI > 1 u]). *)

val leave_screen_seq : kitty_keyboard:bool -> string
(** Pop Kitty keyboard protocol ([CSI < u]), disable paste/mouse, show cursor,
    reset SGR, and leave alt-screen. *)

val install_switch_teardown :
  sw:Eio.Switch.t ->
  kitty_keyboard:bool ->
  ?on_after_drain:(unit -> unit) ->
  unit ->
  unit
(** Register cancellation-safe terminal restoration on [Eio.Switch.on_release]:
    emits {!leave_screen_seq}, drains stdout within {!handoff_limit_s}, and
    invokes [on_after_drain]. *)
