(** The Terminal tab of Keeper detail: a Keeper's Execute output as a terminal
    shows it, oldest row first with the newest at the bottom, following the
    newest row until the reader scrolls up.

    The server keeps the rows and numbers them
    ([GET /api/v1/dashboard/execute-output-snapshot/<keeper>]). This module
    decides what each row is, whether rows need a stream tag, and what a
    scroll does to the view. Drawing is the caller's.

    Pure, so those decisions are testable without a terminal. *)

(** {1 Rows} *)

(** One row as the snapshot carries it, oldest first. *)
type line =
  { seq : int
  ; stream_id : int option
  ; stream : string
        (** What the server calls the row: [cmd], [stdout], [stderr] or
            [status]. *)
  ; text : string
  }

type phase =
  | Command  (** A command the Keeper ran. *)
  | Gate_observation  (** The Gate's trial run of a command. *)

type outcome =
  | Result_unknown
  | Request_not_sent
  | Observation_ended

(** How a command ended, from the JSON a [status] row carries. *)
type status =
  | Process of Unix.process_status
  | Outcome of phase * outcome
      (** No exit status: the endpoint did not report one. *)
  | Rejected of { why : string; reason : string option }
      (** Stopped before it ran, with the server's tag for why. *)
  | Unrecognized of string
      (** A status this reader has no word for: the text as the server wrote
          it. *)

val parse_status : string -> status

type kind =
  | Command_start  (** The first row of a command line. *)
  | Command_more  (** A later row of the same command line. *)
  | Stdout
  | Stderr
  | Status of status
  | Foreign of string
      (** A stream name the server added after this reader was written. *)

type row =
  { seq : int
  ; stream_id : int option
  ; kind : kind
  ; text : string
  }

val rows : line list -> row list
(** The rows in the order given. A [cmd] row continues the command above it
    when that row is a [cmd] row of the same stream; the window can start in
    the middle of a command, and that row then reads as a start. *)

val tagged : row list -> bool
(** Whether one command's rows are split by another's, which happens when
    commands overlap. Each row then needs its stream tag to say whose it is.
    Commands that take turns need none: the command line above each row says
    whose output follows. *)

val unseen : seen:line list -> latest:line list -> int
(** How many rows of [latest] are newer than every row of [seen]. *)

val tab_width : int
(** Cells between tab stops. *)

val expand_tabs : column:int -> string -> string * int
(** The text with each tab replaced by the spaces that reach the next tab
    stop, counting cells the way the pane draws them, and the column the
    text ends at. [column] is where the text starts, so a row cut into
    runs by its colours keeps one set of stops. A terminal does this itself;
    drawn as a control byte a tab would read as [\x09] in the middle of a
    table. *)

(** {1 Following and paused} *)

(** What the reader is looking at. [Following] draws the newest rows of
    whatever was read last. [Paused] draws the reading as it was when the
    reader scrolled up, so output that arrives meanwhile does not move the
    rows under their eyes.

    [back] counts the drawn rows between the bottom of the window and the
    bottom of the output, so [0] is the bottom and the same count reads the
    same place in either direction. It is at least [1]. *)
type 'snapshot hold =
  | Following
  | Paused of { frozen : 'snapshot; back : int }

val back : 'snapshot hold -> int
(** [0] while following. *)

val window :
  content_height:int -> total_rows:int -> 'snapshot hold -> int * int
(** The first row and clamped distance from the bottom for the actual content
    height. A stopped-stream notice does not change the output rows or height. *)

val scroll_to : live:'snapshot option -> back:int -> 'snapshot hold -> 'snapshot hold
(** Put the window [back] rows above the bottom. [back <= 0] follows. Leaving
    the bottom keeps [live], the reading on screen, so the rows stay still;
    with nothing read yet there is nothing to keep and the view keeps
    following. The frame reports its own clamp through this too. *)

val older : live:'snapshot option -> by:int -> 'snapshot hold -> 'snapshot hold
(** [by] rows toward the oldest output. [by <= 0] changes nothing. Saturates
    rather than wrapping. *)

val newer : by:int -> 'snapshot hold -> 'snapshot hold
(** [by] rows toward the newest output; reaching the bottom follows again.
    [by <= 0] changes nothing. *)

val oldest : live:'snapshot option -> 'snapshot hold -> 'snapshot hold
(** As far from the bottom as there is output; the frame reports where that
    landed. *)

val newest : 'snapshot hold -> 'snapshot hold

val shown : live:'snapshot option -> 'snapshot hold -> 'snapshot option
(** The reading to draw: the frozen one while paused, [live] otherwise. *)
