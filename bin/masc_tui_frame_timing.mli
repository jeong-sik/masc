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

val enabled : bool
(** Whether the environment asked for timing. False costs one boolean test per
    frame and nothing else. *)

val time : phase -> (unit -> 'a) -> 'a
(** Run [f], recording how long it took when {!enabled}. Returns what [f]
    returns either way. *)

val time_tagged : phase -> tag:('a -> string) -> (unit -> 'a) -> 'a
(** Like {!time}, but the sample carries [tag result]. The tag is read from
    the result because a frame's surface is only known once it is built. *)

val report : unit -> unit
(** Append the summary to the configured file. Silent when timing is off, and
    on a file that cannot be opened -- a diagnostic must not take the process
    down with it. *)

(** The samples and their summary, without the clock or the file, so the
    report's shape can be checked with numbers chosen by a test. *)
module Samples : sig
  type t

  val empty : t

  val add : t -> phase -> tag:string option -> ms:float -> t
  (** Record one frame. Ordinals count per phase, in the order of {!add}. *)

  val summary_lines : t -> string list
  (** One line per phase with frames, mean, p50, p95, p99 and max; then one
      line per tag of that phase, most frames first; then the five worst
      frames with their ordinal and tag. A phase with no samples prints
      nothing. *)
end
