(** Where each Keeper's latest request started
    (RFC librarian-call-only-proposes §11.3).

    The request builder writes a start when it composes a request from the
    Keeper's history, and the next request overwrites it. It lives in this
    process only: nothing is written to disk or to the turn record, so after
    a restart a Keeper has no start until its next request.

    A start is compared with the Memory writer's read end ({!standing}). A
    request that starts past the read end leaves out messages that are in
    neither Memory nor the request. That is warning W2 (§12.2).

    Both counts are messages of the Keeper's checkpoint history, the count
    {!Keeper_turn_log.mark} keeps. A [Reset] in the turn log starts that
    count again, so counts taken on two sides of one cannot be compared. *)

(** Where the Keeper's turn log ended when the request went out. *)
type log_end =
  | Ended_at of int
  (** Lines that start at this offset or later were written after the
      request. *)
  | Unread (** The tail of the turn log could not be read. *)

type t =
  { trace_id : string
  ; sends_from : int
  (** The request sends every history message from this position on, and
      leaves out the one just before it. 0 when it sends the whole history. *)
  ; log_end : log_end
  }

(** [sends_from history ~first_atom] is the position just after the last
    message of an atom before [first_atom]: the [sends_from] of a request
    that carries [history] from [first_atom] on. Pinned messages ride every
    request, so a pinned message never moves it. Atoms are numbered by
    {!Runtime_model_input_tail_window.annotate}. *)
val sends_from : Agent_core.Types.message list -> first_atom:int -> int

(** The start of a request composed now. Reads the tail of [keeper_name]'s
    turn log for {!log_end}, and logs why when that read fails. *)
val of_request
  :  config:Workspace.config
  -> keeper_name:string
  -> trace_id:string
  -> sends_from:int
  -> t

(** Replaces [keeper_name]'s start. *)
val record : config:Workspace.config -> keeper_name:string -> t -> unit

val latest : config:Workspace.config -> keeper_name:string -> t option

(** Drops [keeper_name]'s start, for a Keeper that is deleted. *)
val forget : config:Workspace.config -> keeper_name:string -> unit

(** Why a start and a read end cannot be compared. *)
type unresolved =
  | Other_trace (** The writer read another trace. *)
  | Reset_between of { offset : int }
  (** A [Reset] line at byte [offset] of the turn log lies after the older
      of the two. *)
  | Log_end_unread (** The start's {!log_end} is {!Unread}. *)
  | Lines_unread
  (** The turn log lines between the two could not be read, or one of them
      does not decode. *)

type standing =
  | Unknown_until_next_request
  (** No request has started since this process did. *)
  | View_unavailable
  (** The writer has no view: it is booting, stopped, or not there. *)
  | No_read_end
  (** The writer has read nothing of the turn log, so no request starts past
      its read end. *)
  | Not_behind of
      { sends_from : int
      ; read_end : int
      }
  | Behind of
      { sends_from : int
      ; read_end : int
      }
  (** W2: the messages from [read_end] to [sends_from] include one that is in
      neither Memory nor the request. *)
  | Not_comparable of unresolved

(** Which turn log lines decide whether a start and a read end count the same
    messages. *)
type lines =
  | From_read_unit of
      { line : int
      ; within : Librarian_log.within
      }
  (** The writer's read unit was written before the request: from that unit
      to the end, as {!Keeper_covered_point.read_unread_lines} reads them. *)
  | From_request of { log_end : int }
  (** The writer read lines written after the request: every line from
      [log_end] to the end. *)

(** The comparison, with the lines read through [lines_since]. A [Reset]
    after the newer of the two does not change either count, and it still
    makes them [Not_comparable]: the scan does not stop there. *)
val of_view
  :  lines_since:(lines -> Keeper_covered_point.unread_lines)
  -> t
  -> Librarian_writer.view
  -> standing

(** [Reset_at] for the first [Reset] line that starts at [from] or later. *)
val resets_from : turns_path:string -> from:int -> Keeper_covered_point.unread_lines

(** [keeper_name]'s latest start against the view of its writer in this
    workspace. Reads the turn log lines {!of_view} names. *)
val standing : config:Workspace.config -> keeper_name:string -> standing
