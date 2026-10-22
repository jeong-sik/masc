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
  | Mouse_left_drag of int * int
  | Mouse_left_release of int * int
      (** [(row, column)] of an unmodified left-button press, of where the
          pointer moved with the button still down, and of where it came up,
          1-based as the terminal reported them. The loop reads the three as
          one gesture: a release where the press landed is a click, and a
          drag selects text inside the pane the press landed in. *)
  | Mouse_wheel of Masc.Tui_mouse_protocol.wheel_direction * int * int
      (** A wheel notch and the [(row, column)] it happened at. The loop
          gives a notch over the Activity pane to the pane and turns every
          other one into the [wheel-up] / [wheel-down] key the surfaces bind,
          so no surface learned a new key when the pane appeared. *)

val create_input_reader : unit -> input_reader
val paste_phase : input_reader -> paste_phase
val input_reader_has_ready_input : input_reader -> bool
val input_reader_has_started_input : input_reader -> bool
(** Input is queued or already retained in the decoder, including partial
    pastes, recovered tails and incomplete terminal/UTF-8 sequences held by
    either the normal decoder or the original startup probe. Does not
    consume input. A terminal handoff must preserve this input's owner. *)
val input_holds_incomplete_sequence : input_reader -> bool
val cancel_incomplete_sequence : input_reader -> unit
val input_byte_ready : input_reader -> bool
val paste_can_recover : input_reader -> paste_clock -> bool
val cancel_armed : paste_clock -> bool
val arm_cancel : paste_clock -> unit
val read_input : ?timeout:float -> input_reader -> unit -> input_event option
(** [None] means no decoded event is ready within this read, including a
    partial paste or sequence retained for the next read. *)
type terminal_probe_progress = Probe_pending | Probe_installed | Probe_unchanged
val prepare_terminal_probe :
  sw:Eio.Switch.t option -> clock:float Eio.Time.clock_ty Eio.Resource.t option ->
  input_reader -> palette_requested:bool -> unit
(** Start this fresh reader's original probe under [sw], after its query was
    written and after authoritative settings/session setup. With a switch and
    clock, return after scheduling: only the original child reads stdin/buffer
    until {!poll_terminal_probe} installs its result. Normal input readiness and
    reads never compete with it. A pending read waits for the original promise
    or its caller's existing render deadline, without consuming stdin or spinning.

    Without either runtime resource, preserve synchronous collection/installation.
    A supplied switch is checked first. Existing reply/input early handoff,
    capture deadline/byte cap, decoder, buffer and physical I/O settlement remain.
    Exceptions/cancellation propagate, never defaults; releasing a wait does not
    cancel the original switch-owned producer. Call only once on a fresh reader. *)
val poll_terminal_probe : input_reader -> terminal_probe_progress
(** Owning loop only: inspect without waiting, install the exact returned
    decoder and publish its current immutable observation before normal input.
    [Probe_installed] requests a repaint once; later calls are unchanged.
    Failure propagates. Installation is not paint or useful input proof. *)
val install_terminal_probe : input_reader -> Masc_tui_terminal_probe.decoder -> unit
val install_terminal_probe_publisher :
  input_reader -> publish:(Masc_tui_terminal_probe.observation -> unit) -> unit
(** Publishes current replies once, then only changed immutable observations.
    The same owner receives replies before and after byte-filter completion. *)
val observe_terminal_reply : input_reader -> Masc_tui_input_decoder.reply -> unit
(** Consume a normal decoder reply into the installed probe's original owner,
    including late palette, theme, query graphics and cell dimensions. No read
    or clock; reply publication runs on the owning input path. *)
val observe_capabilities_applied : input_reader -> Masc_tui_terminal_probe.observation -> unit
val observe_input_received : input_reader -> input_event -> unit
(** Actual main-loop boundaries only. Input reception is not acceptance,
    dispatch success or paint. Synthetic recovered input is not a new decode. *)
val startup_observations : input_reader -> Masc_tui_startup_observation.t list
val report_startup_observations : input_reader -> unit
(** Snapshot each original capture, including failures and missing phases.
    No missing worker result is inferred from caller interruption. *)
val abandon_draining : input_reader -> unit
val recover_paste : input_reader -> Masc_tui_paste.t option
