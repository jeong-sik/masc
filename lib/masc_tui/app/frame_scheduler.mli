(** Pure monotonic frame-pacing state machine and rolling frame telemetry.

    Drives 60 FPS (~16.67 ms) bursts during typing/streaming, 30 FPS (~33.33 ms)
    cadence during animations/passive updates, backpressure frame-skipping when
    {!Masc_tui_term.Terminal_out.behind} holds, and pure **0 Hz sleep**
    ([Next_deadline_ns None]) with 0% CPU when the UI is idle. *)

type pace =
  | Pace_interactive
      (** 60 FPS (~16.67 ms): keystrokes, scrolling, resize, active chat stream. *)
  | Pace_animation
      (** 30 FPS (~33.33 ms): passive SSE updates, indicators, subtle transitions. *)

val frame_interval_60fps_ns : int64
(** [16_666_667L] ns (~16.67 ms). *)

val frame_interval_30fps_ns : int64
(** [33_333_333L] ns (~33.33 ms). *)

val backpressure_retry_ns : int64
(** [8_000_000L] ns (8 ms) retry delay when stdout output is backed up. *)

val interval_ns : pace -> int64

type decision =
  | Render_now
  | Skip_backpressure of { retry_at_ns : int64 }
  | Wait_until of { deadline_ns : int64 }
  | Sleep_idle

type next_deadline =
  | Next_deadline_ns of int64 option
      (** [Next_deadline_ns None] means pure 0 Hz sleep until {!Wake_bell}
          rings. *)

type telemetry = {
  frames_rendered : int;
  frames_skipped_backpressure : int;
  last_render_us : int;
  last_diff_us : int;
  last_dirty_cells : int;
  last_bytes_emitted : int;
  avg_render_us : int;
  avg_diff_us : int;
  max_render_us : int;
  window_samples : int;
}

type t

val create : ?window_capacity:int -> unit -> t
(** Create a fresh scheduler marked dirty for the initial boot frame.
    [window_capacity] bounds the rolling telemetry window (default [60]). *)

val mark_dirty : ?pace:pace -> t -> t
(** Mark the framebuffer dirty. Defaults to {!Pace_interactive}; if already
    dirty at {!Pace_interactive}, marking with {!Pace_animation} preserves the
    faster interactive pace for the current frame. *)

val set_extra_deadline : int64 option -> t -> t
(** Register an optional future monotonic wakeup (e.g. toast expiry or active
    voice recording timer). Pass [None] when idle so {!next_deadline} returns
    [Next_deadline_ns None]. *)

val is_dirty : t -> bool
val current_pace : t -> pace

val decide : now_ns:int64 -> output_behind:bool -> t -> decision
(** Pure scheduling decision at monotonic timestamp [now_ns] given whether the
    non-blocking terminal writer currently has queued bytes. *)

val record_rendered :
  now_ns:int64 ->
  render_us:int ->
  diff_us:int ->
  dirty_cells:int ->
  bytes_emitted:int ->
  t ->
  t
(** Record a completed frame presentation, clearing the dirty bit and updating
    rolling telemetry. *)

val record_skipped_backpressure : now_ns:int64 -> t -> t
(** Record a frame skipped due to stdout backpressure while keeping the dirty
    flag armed for the retry slot. *)

val next_deadline : now_ns:int64 -> output_behind:bool -> t -> next_deadline
(** Next monotonic wakeup instant, or [Next_deadline_ns None] for pure 0 Hz
    idle sleep until {!Wake_bell} rings. *)

val telemetry : t -> telemetry
