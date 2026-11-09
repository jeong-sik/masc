(** The operator's reclamation of retired Keepers' Apple volumes, on the
    Tools surface's catalog pane.

    [masc_sandbox_volume_gc] needs [CanAdmin]. The TUI calls it with the
    operator's own credential. Neither a Claude session (a worker token) nor a
    Keeper (the tool is operator-only) can call it.

    The first press asks for a report, and nothing is deleted. The report
    names each retired Keeper's volumes and why they stay or can go. When it
    lists reclaim candidates, the next press asks the server to reclaim
    those Keepers by name; any other key first takes that back. The server
    judges again at that moment, deletes only the named Keepers it still
    judges candidates, and confirms each build-only volume right before it
    deletes it. A candidate that appeared after the report is not named and
    stays. The answer to the second press, not the report, says what was
    reclaimed.

    Below what the next press does, the pane shows the server's last
    periodic report: when it ran and the candidates it listed. The server
    only reports; deleting stays these two presses.

    The pane draws the answer in place rather than in a reading: a reading
    owns every key, and closing it would take the second press back. *)

(** ["masc_sandbox_volume_gc"]. *)
val tool : string

(** ["V"]. *)
val key : string

(** {!Masc.Keeper_volume_gc_host.claims_image}: the image the claims-read
    helper runs on, the same one the server's periodic report uses. Without
    an image the server reads no marker and reclaims nothing. *)
val claims_image : string

(** 60 s. A report lists the volumes once, reads the container inventory once
    per Keeper with a volume, and starts one [container run --rm] helper per
    unregistered Keeper with a work volume. On 2026-11-06 that was 29 Keepers
    (inventory 0.05-0.18 s each) and 3 helpers (1.41-1.60 s each for a
    [run --rm] of the general image), about 6-8 s against the default 10 s
    request limit. *)
val timeout_sec : float

type answer =
  | Report of Masc.Keeper_volume_gc_answer.t
  | Refused of string  (** The tool answered with an error, in its words. *)
  | Unreadable of string  (** The answer did not decode, and why. *)

val answer_of_text : is_error:bool -> string -> answer

(** What a press sends. *)
type request =
  | Report_request
  | Reclaim_request of string list
      (** The candidates the report listed, sent by name. The server judges
          them again and reclaims no other Keeper. *)

val execute : request -> bool

(** The tool arguments. Both send the claims image and [execute]. A reclaim
    also sends its names as [keepers]. *)
val arguments : request -> (string * Yojson.Safe.t) list

type phase =
  | Idle
  | Reporting
  | Armed of string list
      (** The last report listed these candidates; the next press reclaims
          them and no other Keeper. *)
  | Reclaiming

type shown =
  | Nothing_asked
  | Answered of answer
  | Unanswered of request * string
      (** No answer came back: transport, timeout or workspace. After a
          reclaim this does not say nothing was deleted. *)

type t = { phase : phase; shown : shown }

val initial : t

type press =
  | Send of request
  | Still_running

(** The first press reports, an armed press reclaims, and a press while a
    request is in flight sends nothing. *)
val press : t -> press

val sending : t -> request -> t

(** An answer arms the next press only when it is a report that deleted
    nothing and lists a reclaim candidate. *)
val answered : answer -> t

val unanswered : request -> string -> t

(** Any input other than the second press takes an armed reclaim back. A
    request in flight stays in flight. *)
val disarm : t -> t

type tone =
  | Plain
  | Dim
  | Bad

(** The line under the next press for the server's periodic report: when
    the last pass ended, by [timestamp], and the reclaim candidates it
    listed, or why it was skipped or failed. [None] is a server whose first
    pass has not ended. The line is only read: the second press sends the
    names of the first press's own report, not these. *)
val server_report_line :
  timestamp:(float -> string) -> Masc.Keeper_volume_gc_periodic.t option -> tone * string

(** The pane's lines: what the next press does, [server_report] when the
    catalog has a reading, then the last answer. Text from the server is made
    single-line for the terminal. *)
val lines : server_report:(tone * string) option -> t -> (tone * string) list

(** The footer line after an answer. *)
val status_line : t -> string
