module Render_schedule = Masc_tui_render_schedule

(** A write outside the frame presenter makes its cached screen untrustworthy.
    The marker stays set until a presentation consumes it, so the loop may
    inspect it without stealing the presenter's invalidation signal. *)
let frame_damaged = Atomic.make false

let note () = Atomic.set frame_damaged true

let request_repaint render_schedule =
  if Atomic.get frame_damaged then
    Render_schedule.request render_schedule Render_schedule.Force

let consume_damage () = Atomic.exchange frame_damaged false

let console_sink_writes_to_terminal () =
  (* stdout is already required to be a TTY. Device/inode equality is too
     strict here: reopening the same controlling terminal via [/dev/tty] can
     produce a distinct node identity while still corrupting stdout's frame. *)
  try Unix.isatty Unix.stderr
  with
  | Unix.Unix_error _ -> false
