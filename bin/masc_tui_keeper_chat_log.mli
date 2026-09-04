(** One operation's keeper chat turn as an event log keyed by journal seq
    (RFC-0412 §3.3, stage 3a). The live SSE decoder and the v2 journal
    endpoint feed the same log; {!Masc_tui_keeper_chat_transcript} projects
    it. Entries are kept in insertion order; both producers deliver seqs in
    increasing order (the live wire in publish order, a v2 page in journal
    order), so insertion order is seq order. A seq that arrives below
    [last_seq] is accepted where it lands, not reordered. *)

type entry =
  { seq : int option
        (** Journal position of the frame that carried the delta. [None] for
            frames that never went through the bus (the acceptance event, the
            settle-time run_error); such entries are never deduplicated. *)
  ; attempt : int  (** 0-based runtime attempt this entry belongs to. *)
  ; delta : Masc_tui_keeper_chat_live.delta
  }

type t

val create : keeper_name:string -> request_id:string -> started_at:float -> t
val keeper_name : t -> string
val request_id : t -> string
val started_at : t -> float

val add : t -> seq:int option -> Masc_tui_keeper_chat_live.delta -> bool
(** Appends unless [seq] is [Some n] and an entry with seq [n] is already
    held; returns whether it was added. A [Runtime_attempt_started] delta
    advances the attempt before it is stored, so it is the first entry of the
    new attempt. *)

val hold_seq : t -> int -> unit
(** Holds a journal position without an entry: a line the pane draws nothing
    for still counts for {!last_seq} and for deduplication. *)

val add_journaled : t -> Masc.Keeper_chat_event_log.journaled_event list -> unit
(** Every line of a v2 page, in journal order, through {!delta_of_journaled};
    lines already held by seq are skipped. A line that maps to no delta still
    holds its seq ({!hold_seq}). *)

val delta_of_journaled :
  Masc.Keeper_chat_events.keeper_chat_event -> Masc_tui_keeper_chat_live.delta option
(** Total over the journal event type: one arm per constructor, no wildcard.
    One delta at most per event — the log holds one entry per seq, and the
    type says so. An event the live view draws nothing for — adapter-only
    blocks, stream bookkeeping, message start and end — maps to [None],
    exactly where the server's AG-UI projection maps to [None] or to a frame
    the live decoder ignores. The stage-3a golden test pins that a journal
    page and the wire decode to the same deltas. *)

val entries : t -> entry list  (** Insertion order. *)

val last_seq : t -> int
(** Highest seq held, or [-1]. A journal page holds every line's seq, drawn
    or not; the live wire can hold only the seqs of frames that produced a
    delta, because the decoder reports deltas, not frames. So after the same
    turn the journal-fed log's [last_seq] can exceed the wire-fed one by the
    trailing undrawn frames — harmless for a [since_seq] resume, which then
    replays a few frames that draw nothing. *)
val attempt : t -> int  (** Current attempt; [0] before any retry. *)

val commit : t -> unit
(** The turn settled: the log is the committed record of it. Idempotent. *)

val committed : t -> bool

val revision : t -> int
(** Bumped by every mutation; the memo key for anything derived from the log. *)

type events_page =
  { operation_id : string
  ; events : Masc.Keeper_chat_event_log.journaled_event list
  ; has_more : bool
  ; next_since_seq : int
  }

val decode_events_page : Yojson.Safe.t -> (events_page, string) result
(** Strict decode of a [masc.keeper_chat_events.v2] body: the schema tag must
    match and every element must decode as a journal line. *)

(** Why a v2 events request did not return a page. The codes are the
    endpoint's ([unknown_operation] 404, [journal_pruned] 410,
    [journal_unreadable] / [journal_corrupt] 503); a body this build cannot
    read and a request that never got an answer are the two remaining
    shapes. *)
type events_error =
  | Unknown_operation  (** No operation of that id: nothing to reload. *)
  | Journal_pruned
      (** The turn ran and its journal has since been retained away; the v1
          rows are all there is. *)
  | Journal_unavailable of string
      (** The journal exists and could not be read now; the server's message. *)
  | Events_refused of string
      (** 401/403: this client's credential, not the journal. One sentence
          for the operator; the pane stops asking for journals this session. *)
  | Events_undecodable of string
      (** A body this build cannot read, or an error with no known code; the
          status and what came back. *)
  | Events_transport of string  (** The request never got an answer. *)

val events_error_to_string : events_error -> string

val decode_events_error : status:int -> credential_sent:bool -> string -> events_error
(** The typed error behind a non-2xx events response: 401/403 are
    {!Events_refused} ([credential_sent] is whether the request carried a
    bearer), the envelope's [error] code names the journal errors, anything
    else is {!Events_undecodable}. *)

val read_whole_journal :
  fetch:(since_seq:int -> (events_page, events_error) result) ->
  since_seq:int ->
  (Masc.Keeper_chat_event_log.journaled_event list, events_error) result
(** Every line after [since_seq], page by page through [fetch], following
    [has_more] only while [next_since_seq] advances. The first error ends the
    read. *)
