(** Owns terminal bytes, startup probe replay, input decoding and paste recovery.
    Readiness races the deadline; the consuming read remains outside that race.
    Use one reader throughout a terminal session. *)

type input_reader

type paste_clock

type paste_phase =
  | No_paste
  | Pasting of paste_clock
  | Draining_tail of paste_clock

type input_event =
  | Key of string
  | Pasted of Masc_tui_paste.t
  | Graphics_reply of string
      (** The body of an APC the terminal sent back, between [ESC _ G] and
          [ESC \\]. Only the graphics capability query asks for one -- every
          placement says q=2 -- but a reply that is never read is not silent:
          stdin here is the key stream, so its bytes are typed into whatever
          the operator was writing. Reading it is what keeps that from
          happening, whether or not anyone is waiting for it. *)
  | Mouse_left_press of int * int
  | Mouse_left_release of int * int
      (** [(row, column)] of an unmodified left-button press, 1-based as the
          terminal reported it. Only surfaces that map frame rows to their own
          rows consume one; everywhere else it is inert, like a wheel notch on
          a surface with nothing to scroll. *)
  | Mouse_wheel of Masc.Tui_decode.wheel_direction * int * int
      (** A wheel notch and the [(row, column)] it happened at. The loop
          gives a notch over the Activity pane to the pane and turns every
          other one into the [wheel-up] / [wheel-down] key the surfaces bind,
          so no surface learned a new key when the pane appeared. *)

val create_input_reader : unit -> input_reader
val paste_phase : input_reader -> paste_phase
val input_reader_has_ready_input : input_reader -> bool
val input_holds_incomplete_sequence : input_reader -> bool
val cancel_incomplete_sequence : input_reader -> unit
val input_byte_ready : input_reader -> bool
val paste_can_recover : input_reader -> paste_clock -> bool
val cancel_armed : paste_clock -> bool
val arm_cancel : paste_clock -> unit
val read_input : ?timeout:float -> input_reader -> unit -> input_event option
(** [None] means no decoded event is ready within this read, including a
    partial paste or sequence retained for the next read. *)
val read_terminal_probe :
  input_reader -> palette_requested:bool ->
  Masc_tui_terminal_probe.decoder * Masc_tui_terminal_probe.result
val install_terminal_probe : input_reader -> Masc_tui_terminal_probe.decoder -> unit
val install_late_palette_publisher :
  input_reader -> request_full_repaint:(int -> unit) -> unit
val abandon_draining : input_reader -> unit
val recover_paste : input_reader -> Masc_tui_paste.t option
