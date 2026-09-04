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

val add_journaled : t -> Masc.Keeper_chat_event_log.journaled_event list -> unit
(** Every line of a v2 page, in journal order, through {!delta_of_journaled};
    lines already held by seq are skipped. A line that maps to no delta still
    holds its seq (see {!last_seq}). *)

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
