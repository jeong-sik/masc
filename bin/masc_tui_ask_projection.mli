(** Answering a Keeper's question from the terminal.

    The domain requires one response per question of an ask and reports every
    violation together, so a surface that posts a question at a time makes the
    human pay a round trip per mistake. This module holds the whole answer as
    a draft and names what is still missing before the POST rather than after
    it. Nothing here talks to the network: the executable stays untestable,
    every decision it makes does not. *)

type draft_response =
  | Draft_chose of string list
      (** Choice ids in the order the operator picked them. Ids, never labels:
          rewording a choice cannot orphan a draft. *)
  | Draft_wrote of string
  | Draft_skipped
      (** Read the question and declined it. The domain treats this as an
          answer; leaving it out is [Unanswered] and refused. *)

type draft

type answer_feedback = private {
  af_asker : Masc.Tui_decode_asks.ask_asker;
  af_ask_id : string;
  af_source_turn_ref : Ids.Turn_ref.t option;
  af_receipt : (Masc.Tui_decode_asks.answer_receipt, string) result;
  af_submitted_label : string option;
}
(** Last observed answer receipt, not current Keeper execution status. Only
    a newly recorded canonical answer may retain the submitted choice label.
    An existing winner or uncertain/refused write never inherits that label. *)

val answer_feedback :
  ?source_turn_ref:Ids.Turn_ref.t ->
  asker:Masc.Tui_decode_asks.ask_asker -> ask_id:string -> submitted_label:string ->
  (Masc.Tui_decode_asks.answer_receipt, string) result -> answer_feedback

val asker_to_json : Masc.Tui_decode_asks.ask_asker -> Yojson.Safe.t
(** The Keeper's name or the installation's declaration id, for logs. *)

val answer_feedback_to_json : answer_feedback -> Yojson.Safe.t
(** Original request identities and typed recording/delivery facts only.
    Choice/free-text bodies and server error details are not logged. *)

type followup_source_state = Followup_pending | Followup_received | Followup_unconfirmed
type 'a followup_observation = private {
  fo_value : 'a option;
  fo_state : followup_source_state;
}
(** [None] means this source has never supplied an admitted observation.
    Pending peers are not represented by fabricated unavailable/empty values. *)

type followup_view = private {
  fv_identity : Masc.Tui_decode_asks.ask_followup_identity option;
  fv_reactions : Masc.Tui_decode_asks.ask_reactions followup_observation;
  fv_tools : Masc.Tui_decode_asks.ask_tool_actions followup_observation;
  fv_task : Masc.Tui_decode_asks.ask_linked_task followup_observation;
}
type followup
val begin_followup : previous:followup option -> followup
val followup_view : followup -> followup_view
val observe_followup :
  followup -> Masc.Tui_decode_asks.ask_followup_event -> (followup, string) result
val finish_followup : followup -> (unit, string) result -> followup * (unit, string) result
(** One strict stream per read. Original answer and linked Task identities cannot
    change across refreshes. A failed/incomplete transport retains admitted
    sources; only unfinished sources become unconfirmed. Beginning a new read
    retains prior facts as earlier evidence until that source arrives again. *)
val followup_to_json : followup -> Yojson.Safe.t
(** Observation states, canonical identities and execution facts, excluding
    question/answer bodies, Task descriptions and error details. *)

type origin = private {
  ao_keeper_name : string;
  ao_ask_id : string;
  ao_source_turn_ref : Ids.Turn_ref.t option;
}
(** Recorded question origin, independent of current selection and live work.
    Opening it requires no read or action on the Keeper. *)

val origin_of_row : Masc.Tui_decode_asks.ask_row -> origin option
val origin_of_feedback : answer_feedback -> origin option
(** [None] for an installation's question: it was asked by no Keeper turn. *)
val same_origin : origin -> origin -> bool
val origin_to_json : origin -> Yojson.Safe.t

val empty_draft : ask:Masc.Tui_decode_asks.ask_key -> draft
val draft_ask : draft -> Masc.Tui_decode_asks.ask_key

val draft_for : draft option -> row:Masc.Tui_decode_asks.ask_row -> draft
(** The draft when it belongs to [row], a fresh one otherwise. Moving the
    cursor to another ask therefore starts clean without the caller having to
    remember to reset, which is the whole class of bug this removes. *)

val response_for :
  draft -> question:Masc.Tui_decode_asks.ask_question -> draft_response option

val summarize_answer : draft -> row:Masc.Tui_decode_asks.ask_row -> string
(** A human line for what the draft answers, in the labels the operator saw
    (never choice ids): chosen labels joined per question, a written answer
    quoted, a skipped question named. Empty when nothing is answered yet, so a
    caller can fall back to the Keeper name alone. *)

val open_rows :
  Masc.Tui_decode_asks.asks_snapshot -> Masc.Tui_decode_asks.ask_row list
(** The asks still waiting on a human, in wire order. The panel, its footer,
    and the executable all walk this list; a second copy of the predicate is
    how the cursor and the drawn rows come to disagree about which ask is
    selected. *)

val newly_opened_asks :
  previous:Masc.Tui_decode_asks.asks_snapshot option ->
  current:Masc.Tui_decode_asks.asks_snapshot ->
  Masc.Tui_decode_asks.ask_key list
(** Asks open in [current] but not in [previous] — the questions that
    arrived since the last read. A re-read of the same asks, and a first read
    (no previous), both return none, so a caller rings once per new question
    rather than once per poll or once at start-up. *)

val should_ring_for_new_ask :
  arrived:Masc.Tui_decode_asks.ask_key list -> operator_is_watching_asks:bool -> bool
(** Whether an arrival should ring: something arrived ([arrived] non-empty) and
    the operator is not already watching the asks surface. The watching flag is
    the caller's to compute from the surface (and later window focus). *)

val toggle_choice :
  draft ->
  question:Masc.Tui_decode_asks.ask_question ->
  choice:Masc.Tui_decode_asks.ask_choice ->
  draft
(** [Ask_single] replaces the selection, and re-picking the chosen id clears
    it, so a mis-press needs no second key. [Ask_multi] adds or removes;
    removing the last one clears the response, because an empty selection is
    not an answer. Taking the choice rather than an id means an id this ask
    never offered cannot be drafted. *)

type free_text_slot

val free_text_slot : ask:Masc.Tui_decode_asks.ask_key -> Masc.Tui_decode_asks.ask_question -> free_text_slot
(** Every question offers an operator-written alternative. The slot binds the
    editor to the ask and the question, including questions that only offered
    choices. Both, because a question id is unique only inside its ask:
    masc_ask numbers every ask's questions from [q1]. *)

val alternative_position : Masc.Tui_decode_asks.ask_question -> int option
(** The next digit after the choices when it fits in 1-9; otherwise use [t]. *)

val free_text_hint : free_text_slot -> string option

val free_text_ask : free_text_slot -> Masc.Tui_decode_asks.ask_key
(** Which ask the slot writes to. A snapshot can move the cursor to another ask
    while the operator types; the text still belongs to this one. *)

val free_text_question_id : free_text_slot -> string
(** Which question the slot writes to. The editor holds a slot while the
    operator types, and the panel has to know which row to draw the caret
    on; reading it back here keeps the answer in one place rather than
    storing the id a second time beside the slot. *)

val set_text : draft -> slot:free_text_slot -> text:string -> draft
(** Blank text clears the response instead of recording it: the domain rejects
    a blank write, and an editor emptied by backspaces means unanswered. A
    draft for another ask than the slot's comes back unchanged. *)

val skip : draft -> question:Masc.Tui_decode_asks.ask_question -> draft
val clear : draft -> question:Masc.Tui_decode_asks.ask_question -> draft

type readiness =
  | Ready of Yojson.Safe.t  (** the [answers] array, in the ask's order *)
  | Missing of Masc.Tui_decode_asks.ask_question list
  | Not_open
      (** Already answered or withdrawn. A surface that offered submit here
          would be promising something the store settles by first write. *)

val readiness : draft -> row:Masc.Tui_decode_asks.ask_row -> readiness
(** A draft belonging to another ask contributes nothing, so the answer is
    every question missing -- which is true, not a guess. *)

val request_body :
  answers:Yojson.Safe.t ->
  session_id:string option ->
  Yojson.Safe.t

val installation_request_body :
  declaration_id:string -> ask_id:string -> answers:Yojson.Safe.t -> session_id:string option ->
  Yojson.Safe.t
(** The body of [POST /api/v1/lane-addons/ask-answer]: the declaration, the
    ask, the answers and the session only, because the route refuses any
    other field. *)

type gate =
  | Ask_gate_blocked_inflight
  | Ask_gate_arm of Masc.Tui_decode_asks.ask_key  (** the ask now armed *)
  | Ask_gate_submit

val gate_transition :
  inflight:bool -> pending:Masc.Tui_decode_asks.ask_key option -> ask:Masc.Tui_decode_asks.ask_key -> gate
(** Two presses to answer, matching the approval queue: an answer is a fold
    that settles on first write and cannot be taken back. *)

type cursor =
  | On of int
      (** The open ask at this position is selected. *)
  | Released of int
      (** The selected ask left the list -- answered here or elsewhere -- and
          nothing is selected. The position is where [\[] and [\]] resume.

          Falling back to the ask that slid into the same position let the
          keys typed for the answered question answer the next one: two asks
          answered four seconds apart, both with their first choice, the
          second one never read (ask0319873c920b4606). *)

val initial_cursor : cursor
(** Before the operator has chosen anything, the first ask is selected. *)

val reconcile_cursor :
  current_rows:Masc.Tui_decode_asks.ask_row list ->
  cursor:cursor ->
  next_rows:Masc.Tui_decode_asks.ask_row list ->
  cursor
(** Follows the selected ask across a snapshot replacement. When that ask is
    gone the cursor is [Released]; it never selects another ask by itself. A
    released cursor stays released. *)

val selected_row :
  Masc.Tui_decode_asks.ask_row list -> cursor -> Masc.Tui_decode_asks.ask_row option
(** The selected ask, or [None] when nothing is selected. *)

val selected_index : Masc.Tui_decode_asks.ask_row list -> cursor -> int option

val move_cursor :
  Masc.Tui_decode_asks.ask_row list -> cursor -> delta:int -> cursor
(** One press of [\[] or [\]]. A released cursor first selects the ask at its
    resume position without moving, so the operator sees what they picked
    before any key can answer it. *)
