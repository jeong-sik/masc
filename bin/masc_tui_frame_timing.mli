(** Frame-time histogram for the TUI, off unless MASC_TUI_FRAME_TIMING names a
    file to append the summary to.

    Percentiles rather than a mean: a frame loop is judged by its bad frames,
    and a p99 of 80 ms is a visible stutter that a 4 ms mean hides.

    A sample may carry a tag -- the surface the frame drew. One histogram over
    a session that visited five surfaces says the loop is slow; the per-tag
    lines say which surface made it so. *)

type phase =
  | Build  (** state -> frame *)
  | Present  (** frame -> terminal *)

val max_frames_per_phase : int
val max_stage_samples : int
(** Opt-in reports keep only the first 512 frames of each phase and the first
    4096 stage records. They explicitly count omissions once these short-run
    limits are reached. *)

val max_surface_runs : int
(** Opt-in reports keep the first 4096 surface runs ({!Surface_runs}). *)

val enabled : bool
(** Whether the environment asked for timing. When false, timer helpers read no
    clocks and retain no samples. Caller checks and helper calls still have
    unmeasured instruction overhead. *)

type chat_page_application = {
  keeper : string;
  generation : int;
  page_rows : int;
  before_rows : int;
  after_rows : int;
  draft_preserved : bool;
  scroll_preserved : bool;
  pin_preserved : bool;
}

val note_chat_page_application : chat_page_application -> unit
(** Observe a successfully admitted older page, with the next Build ordinal.
    UI-domain use only. Callers capture metadata only when {!enabled}.
    [draft_preserved] compares the input revision token, [scroll_preserved]
    the integer scroll, and [pin_preserved] the pin option's physical identity
    immediately before and after admission. These do not establish attachment,
    cursor, later viewport or physical-paint preservation. Contains no draft contents or
    cursor bytes. Retains the first {!max_frames_per_phase} events and reports
    omissions. This diagnostic never grants request or workspace authority. *)

type ask_owner = Keeper of string | Installation of string
type ask_identity = {
  owner : ask_owner;
  ask_id : string;
  source_turn_ref : string option;
  is_open : bool;
}
type asks_application =
  | Applied of { open_count : int; rows : ask_identity list }
  | Reset

val note_asks_application : asks_application -> unit
(** Record only an actual successful application or clearing of the UI's Ask
    snapshot. Failed loads retain its identity and epoch, but the actual Home
    reading below separately determines current/stale eligibility. Callers
    guard payload construction with {!enabled}; no snapshot traversal when off.
    UI-domain use only, between synchronous Builds. This is diagnostic history,
    never read authority or a snapshot cache. *)

type questions_reading =
  | Questions_current
  | Questions_unread
  | Questions_stale
  | Questions_failed
  | Questions_unavailable

val note_home_forced : questions_reading -> unit
(** Mark the current synchronous Build only when its Home lazy is forced,
    with the actual [approvals_questions_reading] used by Home. This reading
    is separate from retained snapshot identity: a failed refresh keeps the
    application epoch while changing current to stale. Does not force Home,
    traverse a snapshot, read a clock or perform I/O. *)

module Ask_samples : sig
  type t
  type view = Unknown | Cleared of int | Current of int
  val empty : t
  val add : t -> at_ns:int64 -> before_build:int -> asks_application -> t
  val for_build : t -> int -> view
  val raw_lines : t -> string list
  (** Retain the first {!max_frames_per_phase} application/reset events with
      actual ordered identities. Omitted metadata makes later Builds Unknown.
      [before_build] uses the next Build ordinal, avoiding clock-tie inference. *)
end

val note_presented : surface:string -> unit
(** Record that a frame of [surface] reached the terminal. A frame is a write
    that opens with the presenter's frame start: each frame the presenter
    wrote, each batch the machine screen wrote, and each {!note_external}
    write. Call it once for each, in the order written; a frame the presenter
    found unchanged wrote nothing and is not one. UI-domain use only. Does
    nothing when timing is off. *)

val note_external : surface:string -> write:(string -> unit) -> frame_start:string -> unit
(** A surface drawn outside the presenter has the terminal. When timing is on
    and the last frame recorded showed another surface, or none, write
    [frame_start], a frame start that draws nothing, and record a frame of
    [surface]. Otherwise do nothing, so a loop that calls it on every pass
    while the surface has the terminal records it once. UI-domain use only. *)

(** The surface of each written frame, as runs, so a reader that counts the
    frames the terminal received can tell which surface each one showed. *)
module Surface_runs : sig
  type t
  val empty : t
  val add : t -> surface:string -> t
  (** The next written frame. It extends the current run when it shows the
      same surface, and starts a run otherwise. *)
  val showing : t -> surface:string -> bool
  (** Whether the last frame added showed [surface], also past
      {!max_surface_runs}. *)
  val raw_lines : t -> string list
  (** One [masc.tui.surface_run.v1] line per kept run, in order, with its
      surface and the ordinal of its first written frame, then one
      [masc.tui.surface_runs.v1] line with the number of written frames, kept
      runs and omitted runs. Once {!max_surface_runs} runs are kept, later
      runs are omitted and that line names the written frame from which the
      surface is unknown; otherwise that field is [null]. *)
end

val time : phase -> (unit -> 'a) -> 'a
(** Run [f], recording how long it took when {!enabled}. Returns what [f]
    returns either way. *)

val time_tagged : phase -> tag:('a -> string) -> (unit -> 'a) -> 'a
(** Like {!time}, but the sample carries [tag result]. The tag is read from
    the result because a frame's surface is only known once it is built. *)

val time_stage : name:string -> (unit -> 'a) -> 'a
val time_stage_tagged : name:('a -> string) -> (unit -> 'a) -> 'a
val note_stage : name:string -> unit
val start_stage : unit -> int64 option
val finish_stage : name:string -> int64 option -> unit
(** Stage samples inside a Build carry that Build's frame number. Samples
    outside Build, such as Board fetch and decode, contribute one duration
    per call to their percentile population and are reported separately.
    A note records a branch such as a cold cache without claiming a duration.
    Build residuals subtract the union of timed stage intervals, so nested or
    overlapping stages are counted once. Individual stage totals still include
    their nested work and must not be added as an exclusive decomposition.
    Finish only after a successful return; a raising
    Build may retain earlier stages without a corresponding successful frame. *)

val time_present :
  tag:string ->
  write:(string -> unit) ->
  flush:(unit -> unit) ->
  (write:(string -> unit) -> flush:(unit -> unit) -> 'a) -> 'a
(** Time one Present, keeping the write/flush wall times and byte/call counts
    on that same sample. When disabled, pass the original callbacks through.
    Callbacks, results and exceptions keep their original order and meaning.
    As with {!time}, a raising presentation does not produce a sample.

    The worst Present lines include this breakdown. [other] is total minus
    write and flush; it includes diff preparation, state updates, observation
    overhead and any scheduling/GC delays outside those calls. Buffered
    [output_string] can itself write to the terminal, so either call can
    block. These are elapsed times, not CPU time or physical display latency. *)

val report : unit -> unit
(** Append the summary to the configured file. Silent when timing is off, and
    on a file that cannot be opened -- a diagnostic must not take the process
    down with it. *)

(** The samples and their summary, without the clock or the file, so the
    report's shape can be checked with numbers chosen by a test. *)
module Samples : sig
  type t

  type output = {
    write_ms : float;
    flush_ms : float;
    bytes : int;
    writes : int;
    flushes : int;
  }

  val empty : t

  val add : t -> phase -> tag:string option -> ms:float -> t
  (** Record one frame. Ordinals count per phase, in the order of {!add}. *)

  val add_present : t -> tag:string -> ms:float -> output:output -> t
  (** Record a Present with its own output measurements. An unchanged frame
      has zero calls and bytes; it still occupies a Present ordinal. *)

  type raw_output = {
    write_ns : int64;
    flush_ns : int64;
    bytes : int;
    writes : int;
    flushes : int;
  }

  val add_timed : t -> phase -> tag:string option ->
    started_ns:int64 -> completed_ns:int64 -> home_questions:questions_reading option ->
    output:raw_output option -> t
  val raw_lines : asks:Ask_samples.t -> t -> string list
  (** All retained actual timer samples, with exact decimal-string int64
      start/end/elapsed nanoseconds. Build records carry the applied event
      identity and actual typed reading at Home force; [None] means Home was
      not forced. Present does not infer a Build or reading.
      Aggregate-only synthetic [add] values have no fabricated raw clock. *)

  val summary_lines : t -> string list
  (** One line per phase with frames, mean, p50, p95, p99 and max; then one
      line per tag of that phase, most frames first; then the five worst
      frames with their ordinal and tag. A phase with no samples prints
      nothing. *)
end

module Stage_samples : sig
  type t
  val empty : t
  val add : t -> frame:int option -> name:string -> ms:float option -> t
  val add_timed : t -> frame:int option -> name:string ->
    started_ns:int64 -> completed_ns:int64 -> t
  val raw_lines : t -> string list
  (** Actual stage timers retain exact nanosecond windows; branch notes have
      no fabricated timer. The existing stage/frame caps and omissions apply. *)
  val summary_lines : t -> string list
  type build_residual = { frame : int; uncovered_ns : int64 }
  val build_residuals : t -> Samples.t -> build_residual list
  (** In Build order, exact elapsed nanoseconds outside the union of its stage
      windows. Requires a timed Build and at least one timed stage. Branch notes
      and outside-Build stages do not contribute. Omit a Build if stage records
      were dropped for it or an earlier Build, a measured stage has no window,
      or any window is reversed, negative or outside that Build. All windows
      must come from the same process clock; aggregate-only durations cannot
      establish overlap. This is uncovered wall time, not exclusive CPU time. *)
  val residual_lines : t -> Samples.t -> string list
  (** Format {!build_residuals}. Includes unmeasured work, observation overhead
      and scheduling/GC delays; not an overhead estimate by itself. *)
end
