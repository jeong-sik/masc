(** What one keeper turn looks like while it is still running.

    {!Masc_tui_keeper_chat_live} says what arrived; this accumulates it into
    the shape the chat pane draws: the assistant text so far, the reasoning so
    far, and one row per tool call with the argument a reader identifies it by.

    It holds no authority over the turn. The recorded reply still comes from
    the strict whole-body decode when the stream ends, and this is discarded
    at that point. *)

(** How far along the turn is, as far as the stream has said. *)
type phase =
  | Waiting  (** The request went out; the run has not started. *)
  | Working  (** The run started and the stream is open. *)
  | Stream_ended  (** The run reported it finished. *)
  | Stream_failed of string  (** The run reported an error. *)

(** What came of an operator's request to interrupt this turn.

    [Signal_sent] is not "the turn stopped". The server reports whether it
    signalled the running fiber, and a turn parked in an uncancellable section
    keeps going after a signal lands — reading it as the outcome is what hid a
    63-minute hang (masc #29229). The stream ending is the proof. *)
type interrupt =
  | Not_requested
  | Signal_sent of { turn_id : int option }
  | Signal_declined of string
      (** The server accepted the request and did not signal — no turn in
          flight, or the cancel itself failed. Carries its reason. *)
  | Signal_error of string  (** The request never got an answer. *)

(** One tool call the turn made. *)
type tool_call =
  { call_id : string
  ; tool_name : string
  ; args : string  (** Argument text accumulated so far. *)
  ; subject : string option
      (** The one argument a reader names the call by, or [None] while the
          arguments are still arriving or carry no known key. Same naming as
          the connector trail and the dashboard. *)
  ; ended : bool
  ; result_ready : bool
  }

(** Lines the live reader could not read. Kept because a pane that drops what
    it does not understand looks like a keeper that did nothing. *)
type unreadable =
  { count : int
  ; last_detail : string
  }

type t

val create : keeper_name:string -> request_id:string -> t
val keeper_name : t -> string
val request_id : t -> string

val apply : t -> Masc_tui_keeper_chat_live.delta -> unit
(** Fold one delta in. Deltas for an unknown call id are dropped: a tool row
    with no name says less than no row, which is the same call the connector
    trail makes. *)

val note_interrupt : t -> interrupt -> unit

val phase : t -> phase
val interrupt : t -> interrupt
val text : t -> string
val thinking : t -> string
val tool_calls : t -> tool_call list  (** In the order the stream opened them. *)
val unreadable : t -> unreadable option

val tool_rows : t -> string list
(** One line per tool call, in stream order, the way the pane draws them: a
    marker for how far the call got, the tool's name, and the argument it is
    known by.

    The same strings are used for the live rows and for the row block kept in
    the transcript once the turn ends, so what an operator watched and what
    they scroll back to are not formatted by two different functions. *)

(** How a status row reads. *)
type status_kind =
  | Progress  (** How the turn is going. *)
  | Attention  (** Something an operator has to know about. *)

val status_rows : t -> (status_kind * string) list
(** The status rows the chat pane draws for this turn.

    Returned as a list rather than drawn directly because the pane's row
    budget has to know how many there are before it lays the pane out, and the
    budget answering differently from the drawing is how the unavailable row
    once went missing while the send hint still read Enter:send
    (see [keeper_message_status_rows]). One list, counted and drawn. *)

