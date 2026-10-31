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

val enabled : bool
(** Whether the environment asked for timing. When false, timer helpers read no
    clocks and retain no samples. Caller checks and helper calls still have
    unmeasured instruction overhead. *)

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
