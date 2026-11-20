(** What wakes the TUI's main loop, and when it has to wake by itself
    (RFC tui-idle-wait).

    The loop sleeps until terminal input arrives, a {!source} rings its
    {!bell}, or the earliest {!deadline} passes. A writer that changes state
    the loop reads from outside the loop's own fiber rings the bell; a
    decision that turns on a clock notes when it will answer differently
    ({!reached}). Nothing here reads the terminal. *)

(** One writer that changes what the loop reads, outside the loop's fiber. *)
type source =
  | Mailbox  (** [enqueue_async]: an async message for the loop. *)
  | Workspace_result  (** [Masc_tui_workspace_result] published a result. *)
  | Preference_written  (** [Masc_tui_preference_writer] finished a write. *)
  | Keeper_preference_written  (** [Masc_tui_config] finished a Keeper list preference write. *)
  | Refresh_progress  (** A running HTTP refresh reported progress. *)
  | Settings_reread  (** The screen settings reread resolved. *)
  | Credential_prepared  (** Workspace access preparation finished. *)
  | History_read  (** A Keeper chat history read published rows or a page. *)
  | Ask_answer_receipt  (** An ask answer's receipt returned. *)
  | Ask_answer_completion  (** An ask answer's completion returned. *)
  | Runtime_assignment_saved  (** A runtime assignment save moved on. *)
  | Keeper_settings_saved  (** A Keeper settings save moved on. *)
  | Runtime_form_saved  (** A runtime form save moved on. *)
  | Keeper_creation_observed  (** A Keeper creation moved on. *)
  | Task_dispatched  (** A Task dispatch completed. *)
  | Console_write  (** A log line reached the terminal outside the frame. *)
  | Terminal_write_lost  (** The terminal writer failed a write. *)
  | Resize_signal  (** SIGWINCH or SIGCONT. *)
  | Interrupt_signal  (** SIGINT. *)
  | Terminate_signal  (** SIGTERM, SIGHUP or SIGQUIT. *)
  | Server_start_settled
      (** A server this TUI started answered [/health], exited, or ran out
          of attempts. *)

val all_sources : source list
(** Every constructor, in declaration order. *)

type bell

val create : unit -> bell

val loop : bell
(** The one bell the main loop waits on. Writers ring this one. *)

val ring : bell -> source -> unit
(** Record that [source] changed something and wake a fiber in {!await}.
    Safe from a signal handler, another domain and a system thread. *)

val await : bell -> unit
(** Inside Eio: return once any source has rung since the last {!take},
    at once when one already has. A ring between the check and the sleep
    is not lost. *)

val take : bell -> source list
(** The sources rung since the last call, in declaration order, and forget
    them. A ring after this call wakes the next {!await}. *)

(** Why the loop has to wake at a time. *)
type deadline_reason =
  | Frame_slot  (** A requested frame waits for its interval. *)
  | After_frame  (** The pass after a frame: launchers read what it drew. *)
  | Time_text  (** The last frame's time text reads differently. *)
  | Owed_read_retry  (** A failed or placeholder read's wait ends. *)
  | Refresh_retry  (** A failing [/health] probe's owed pass is due. *)
  | Roster_row_scheduled  (** A Keeper row is scheduled to be read again. *)
  | Engine_sample  (** The engine graphs' next sample is due. *)
  | Play_room_read  (** The play room beside a game reads again. *)
  | Tool_series_reread  (** The tool series is read again. *)
  | Provider_history_day  (** A new day owes the provider history. *)
  | Harness_stale  (** The harness reading turns stale. *)
  | Identity_attempt_deadline  (** A login attempt's consent deadline passes. *)
  | Identity_login_expiry  (** A shown login expires. *)
  | Quit_notice_expiry  (** An armed quit's notice leaves the screen. *)
  | Emblem_step  (** The About candle's next step. *)
  | Paste_quiet  (** A paste without its end marker has been quiet long enough to recover. *)
  | Drain_budget_spent  (** The drain left work when its pass budget ran out. *)
  | Machine_view_cadence  (** A game is on screen (RFC tui-idle-wait §2.3). *)
  | Wall_clock_recheck
      (** A wall-clock instant is noted further away than
          {!wall_clock_recheck_s}: the wall clock is read again (§6). *)

(** Which clock a reason's instants are read on. A wall-clock instant can
    move against the loop's own clock: the machine sleeps, or the clock is
    set. *)
type clock = Monotonic | Wall

val clock_of : deadline_reason -> clock
(** The clock column of RFC tui-idle-wait §2.2. *)

val wall_clock_recheck_s : float
(** How far ahead a wall-clock instant is noted at most, so a machine that
    slept or a clock that was set is seen this long after at the latest
    (RFC tui-idle-wait §6). *)

(** An instant on the loop's own clock, [Mtime_clock.elapsed_ns], the clock
    a {!deadline}'s [at_ns] is on. Only {!Mono.now} makes one from the clock;
    the other functions move from an instant already on it. A wall-clock reading
    ([Unix.gettimeofday]) is a [float], so it does not type-check where a
    decision compares instants on this clock (#53581). *)
module Mono : sig
  type t = private int64
  (** Nanoseconds on [Mtime_clock.elapsed_ns]. *)

  val now : unit -> t

  val after : t -> float -> t
  (** [seconds] after an instant. A negative or nan wait is the instant
      itself; a wait past the clock's range, [infinity] among them, is the
      clock's end. *)

  val compare : t -> t -> int

  val seconds_since : t -> since:t -> float
  (** How long after [since] the instant is, in seconds; before [since] it
      is negative. *)

  val of_wall : now:t -> wall_now:float -> float -> t
  (** The instant on this clock that a wall-clock instant names, [now] and
      [wall_now] being read together: [now] plus what remains until it. A
      wall-clock instant already past is [now]. Every wall-clock instant that
      reaches this clock goes through here (RFC tui-idle-wait §3.2). *)
end

type deadline = { reason : deadline_reason; at_ns : int64 }
(** [at_ns] is a {!Mono.t}'s nanoseconds. *)

val earliest : deadline list -> deadline option
(** The deadline with the smallest [at_ns], [None] for none. *)

val in_seconds : deadline_reason -> now_ns:int64 -> float -> deadline
(** A deadline [seconds] after [now_ns]. A negative or nan wait is due at
    [now_ns]; a wait past the clock's range, [infinity] among them, is due at
    its end. *)

val reached : deadline_reason -> now:float -> at:float -> bool
(** [now >= at] for two instants on the reason's clock ({!clock_of}). While
    it answers [false], [at] is noted for this pass ({!Pass}), so the loop
    wakes when the answer changes. A wall-clock [at] more than
    {!wall_clock_recheck_s} away is noted as [Wall_clock_recheck] that far
    away instead. A non-finite instant is never reached and is not noted. *)

val reached_mono : deadline_reason -> now:Mono.t -> at:Mono.t -> bool
(** [now >= at] on the loop's clock. While it answers [false], [at] is noted
    for this pass ({!Pass}). *)

val reached_ns : deadline_reason -> now_ns:int64 -> at_ns:int64 -> bool
(** {!reached_mono} on raw [Mtime_clock.elapsed_ns] nanoseconds. *)

(** What the decisions of one loop pass noted. The window runs from the end
    of one wait to the start of the next: every per-pass decision runs again
    inside it, so what an earlier pass noted is dropped. *)
module Pass : sig
  val begin_pass : unit -> unit
  val note : deadline -> unit
  val noted : unit -> deadline option
end

(** The moments only the main loop knows, read just before it waits. *)
type loop_moments = {
  frame_due_ns : int64 option;  (** A requested frame's slot ([Render_schedule.frame_due_ns]). *)
  frame_drawn : bool;  (** A frame went out since the last wait (§3.4). *)
  machine_view : bool;  (** A game is on screen, not its menu (§2.3). *)
}

val machine_view_cadence_s : float

val next_deadline : now_ns:int64 -> loop_moments -> deadline option
(** The earliest of the loop's own moments and what this pass noted. *)

type wait = { within_s : float option; bell : bell option }
(** How long one terminal read may wait: [within_s] seconds or, with
    [None], until input or the bell. A [bell] ends the wait when it rings. *)

val within : float -> wait
(** At most this many seconds, for input only. *)

val until : now_ns:int64 -> bell -> deadline option -> wait
(** Until input, a ring of [bell], or [deadline]. *)
