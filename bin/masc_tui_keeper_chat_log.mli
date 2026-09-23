(** One operation's keeper chat turn as an event log keyed by journal seq
    (RFC-0412 §3.3, stage 3a). The live SSE decoder and the v2 journal
    endpoint feed the same log; {!Masc_tui_keeper_chat_transcript} projects
    it. Entries are kept in insertion order; both producers deliver seqs in
    increasing order (the live wire in publish order, a v2 page in journal
    order), so insertion order is seq order. A seq that arrives below the
    position held ({!resume_position}) is accepted where it lands, not
    reordered. *)

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
    for still counts for {!resume_position} and for deduplication. *)

val add_journaled :
  t ->
  Masc.Keeper_chat_event_log.journaled_event list ->
  (Masc.Keeper_chat_event_log.journaled_event * Masc_tui_keeper_chat_live.delta) list
(** Every line of a v2 page, in journal order, through {!delta_of_journaled};
    lines already held by seq are skipped. A line that maps to no delta still
    holds its seq ({!hold_seq}). Returns the lines whose delta the log took,
    each with that delta, in journal order: the one fold of a page, so a
    projection kept as the fold of the log applies exactly these, at each
    line's own [ts]. *)

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

val resume_position : t -> Masc.Keeper_chat_event_log.replay_position
(** Where a resume of this turn starts: after the highest seq held, or the
    whole turn while none is. A journal page holds every line's seq, drawn
    or not; the live wire can hold only the seqs of frames that produced a
    delta, because the decoder reports deltas, not frames. So after the same
    turn the journal-fed log's position can exceed the wire-fed one by the
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
  ; next_since_seq : Masc.Keeper_chat_event_log.replay_position
        (** The position to ask the next page from, in the response spelling
            ({!Masc.Keeper_chat_event_log.replay_position_of_yojson}: null is
            the whole journal, an integer >= 0 the seq to read after). *)
  ; next_since_offset : Masc.Keeper_chat_event_log.page_start
        (** The byte offset past the last event served, or the offset the
            page was asked from when it served none: where the next page
            starts reading, sent back beside [next_since_seq]. *)
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
      (** The turn ended and no journal exists for it: the server cannot say
          whether retention removed it or an append never created it, only
          that there is nothing to reload, now or later. The v1 rows are all
          there is. *)
  | Journal_unavailable of string
      (** The journal exists and could not be read now; the server's message. *)
  | Cursor_refused of
      { refusal : Masc.Keeper_chat_event_log.cursor_refusal
      ; message : string
      }
      (** 400 on one of the journal's cursor codes: the seq and byte cursors
          this read held no longer place in the journal, which is what a
          journal replaced or shortened under a page-by-page read looks like.
          Nothing is remembered for the operation: the next load starts from
          the first row, where no cursor is held, so it cannot be refused the
          same way. *)
  | Events_refused of string
      (** 401/403: this client's credential, not the journal. One sentence
          for the operator; the pane stops asking for journals this session. *)
  | Events_denied of string
      (** A 401/403 that names no auth code: the handler refused this read.
          The status and the server's own sentence. *)
  | Events_undecodable of string
      (** A body this build cannot read, an error with no known code (the
          status and what came back), or a page that claimed more without
          advancing ({!read_whole_journal}). *)
  | Events_transport of string  (** The request never got an answer. *)

val events_error_to_string : events_error -> string

val events_query
  :  encode_value:(string -> string)
  -> operation_id:string
  -> since_seq:Masc.Keeper_chat_event_log.replay_position
  -> since_offset:Masc.Keeper_chat_event_log.page_start
  -> limit:int
  -> string
(** The query string of one events request, after the ["?"]: [operation_id],
    the two cursors in their request spelling (each absent for its own "from
    the start"), and [limit]. [encode_value] encodes the operation id for a
    query value. *)

val decode_events_error : status:int -> credential_sent:bool -> string -> events_error
(** The typed error behind a non-2xx events response: 401/403 are
    {!Events_refused} ([credential_sent] is whether the request carried a
    bearer), the envelope's [error] code names the journal errors and the
    three cursor refusals
    ({!Masc.Keeper_chat_event_log.cursor_refusal_of_wire}), anything else is
    {!Events_undecodable}. *)

val read_whole_journal :
  fetch:
    (since_seq:Masc.Keeper_chat_event_log.replay_position ->
     since_offset:Masc.Keeper_chat_event_log.page_start ->
     (events_page, events_error) result) ->
  since_seq:Masc.Keeper_chat_event_log.replay_position ->
  (Masc.Keeper_chat_event_log.journaled_event list, events_error) result
(** Every line past [since_seq] (the whole journal, or after a held seq),
    page by page through [fetch]. The first page is asked from the first row
    ({!Masc.Keeper_chat_event_log.first_row}), every later one from the
    [next_since_offset] of the
    page before, beside its [next_since_seq]. The read follows [has_more]
    while both cursors advance past the ones asked from. The first error ends
    the read; a page that claims more without advancing is
    {!Events_undecodable}, naming the positions, never a shorter [Ok]. *)
