(** Outer OCaml 5.5 + Eio application shell for MASC TUI v2.

    Orchestrates the 3-domain runtime ([Ui] 4M / [Io] 4M / [Worker] 4M),
    alt-screen + Kitty [CSI u] + bracketed paste + SGR mouse + raw [Termios]
    with guaranteed reverse-order [Eio.Switch.on_release] teardown, dedicated
    stdin {!Masc_tui_term.Input_decoder} fiber, bounded 3 ms
    {!Masc_tui_net.Ui_bus} batch drain, pure {!Masc_tui_store.Update.step},
    differential {!Masc_tui_term.Presenter} with CSI 2026 and backpressure
    frame skipping, dynamic [SIGWINCH] resize, and pure 0 Hz idle sleep. *)

open Masc_tui_store
open Masc_tui_term
open Masc_tui_ui

type render_frame =
  model:Model.t -> cache:Card.Cache.t -> Cell_grid.t -> Presenter.cursor
(** First-class pure frame-rendering callback supplied by the binary entrypoint
    (e.g. wiring [masc_tui_screens]) so [masc_tui_app] stays decoupled from
    screen implementations. *)

val drain_budget_ns : int64
(** Per-frame UI bus batch-drain cap: [3_000_000L] ns (3 ms). *)

val voice_tick_interval_ns : int64
(** Voice recording elapsed-time tick cadence: [100_000_000L] ns (100 ms / 10 Hz). *)

val probe_timeout_s : float
(** Bounded non-blocking startup terminal probe deadline ([0.15] seconds) so
    non-responding terminals never hang TUI startup. *)

val palette_requested_of_env : getenv:(string -> string option) -> bool
(** Decide whether to query OSC 10/11/4 palette at startup: returns [false] when
    [TERM] is absent, empty, or case-insensitively ["dumb"] (regardless of
    [MASC_TUI_FORCE_COLOR]), or when [NO_COLOR] is non-empty without
    [MASC_TUI_FORCE_COLOR=1]. *)

val collect_startup_probe :
  ?timeout_s:float ->
  ?max_bytes:int ->
  clock:_ Eio.Time.clock ->
  fd:Unix.file_descr ->
  palette_requested:bool ->
  unit ->
  Probe.decoder
(** Collect startup terminal replies (CSI 16t cell pixels, optional OSC 10/11/4
    palette, Kitty APC G graphics) from [fd] within [timeout_s] without blocking
    or discarding early user keystrokes. Callers should pass an [O_NONBLOCK]
    descriptor; reads are additionally guarded with zero-timeout [Unix.select]
    against spurious wakeups, and [Unix_error] on [await_readable]/[read]
    returns the accumulated decoder cleanly while preserving
    [Eio.Cancel.Cancelled]. Stops immediately on [Input_ready] or
    [Replies_ready] and returns the live {!Probe.decoder} with intact replay
    and pending state for handoff to the input reader. *)

val apply_probe_observation :
  presenter:Presenter.t -> Probe.observation -> unit
(** Publish [obs] to {!Probe.set_current_observation}, update
    {!Palette.set_current} when a palette was observed, and update [presenter]'s
    {!Presenter.capabilities} with observed [graphics] and [cell_pixels]. *)

val apply_terminal_reply :
  probe_decoder:Probe.decoder ->
  Input_decoder.terminal_reply ->
  Probe.observation option
(** Feed a late {!Input_decoder.terminal_reply} back into the owning
    [probe_decoder]. Returns [Some obs] iff the observed capabilities changed. *)

val is_ctrl_c : Input_decoder.key_event -> bool
(** [true] iff [ev] represents [Ctrl+C] (e.g. Kitty [CSI u] [\x1b[99;5u]] or
    raw control byte). *)

val default_mouse_capture : bool
(** Default terminal mouse tracking state ([false] so native drag-select copy
    works out of the box; toggled at runtime via bare [m]). *)

val mouse_capture_seq : bool -> string
(** Exact escape sequence emitted when toggling/restoring mouse tracking:
    enables button/wheel SGR reporting ([\x1b[?1000h\x1b[?1006h], never
    [?1002h] drag hijack) when [true], and disables all mouse modes when [false]. *)

val should_toggle_mouse_capture : Model.t -> Input_decoder.key_event -> bool
(** [true] iff [ev] is unmodified bare [m] (or its Korean 2-bulsik IME
    equivalent ['ㅡ']) while no overlay, text-capture surface, or
    micro/too-small viewport gate is active. *)

val dispatch_decoded_events :
  signals:Signals.t ->
  bell:Wake_bell.t ->
  input_queue:Msg.t Eio.Stream.t ->
  ?on_reply:(Input_decoder.terminal_reply -> unit) ->
  Input_decoder.event list ->
  unit
(** Route decoded terminal input events into {!Signals}, {!Wake_bell}, and
    [input_queue]. [Ctrl+C] arms/confirms interrupt; ordinary keys, bracketed
    pastes, and mouse events withdraw an armed interrupt. Late terminal probe
    replies invoke [on_reply] when supplied. *)

val should_emit_tick :
  now_ns:int64 ->
  last_voice_tick_ns:int64 ->
  toast_expires_ns:int64 option ->
  voice_recording:bool ->
  bool * int64 option
(** Pure active-timer gate returning [(emit_tick_now, next_extra_deadline_ns)].
    Returns [(false, None)] when idle (0 Hz pure sleep). When voice recording is
    active, emits ticks strictly at {!voice_tick_interval_ns} cadence rather
    than spinning every render wakeup. *)

val clock_minute_of_unix : float -> int64
(** Whole wall-clock minute index ([floor wall_unix / 60]), or [0L] for
    non-finite / non-positive timestamps. *)

val next_minute_tick :
  now_ns:int64 ->
  wall_unix:float ->
  last_minute:int64 ->
  bool * int64 * int64
(** Pure 1-minute wall-clock boundary scheduler returning
    [(minute_due, current_minute, next_boundary_deadline_ns)]. Keeps the
    top-right clock and relative ages fresh while remaining 0 Hz between minute
    boundaries. *)

val local_tz_offset_sec : ?at:float -> unit -> int
(** Local timezone offset from UTC in seconds (e.g. [+32400] for KST), sampled
    once at startup so pure renderers never call {!Unix}. *)

val write_exit_line_fd : Unix.file_descr -> Masc_tui_core.Exit_reason.t -> unit
(** Write the canonical [[masc-tui] exit: <reason>\n] line to [fd] without
    raising on broken pipes or non-blocking descriptors. *)

val run : cli:Cli_args.config -> render_frame:render_frame -> unit -> int
(** Run the interactive TUI session for [cli] and return the process exit code
    ([0] on normal exit, [2] on non-TTY stdin/stdout or [TERM=dumb], [1] on
    abnormal exception). *)

val run_argv : ?argv:string array -> render_frame:render_frame -> unit -> int
(** Parse [argv] via {!Cli_args.parse_and_dispatch}, servicing [--version],
    [--build-commit], and [--help] without touching TTY, then run {!run}. *)
