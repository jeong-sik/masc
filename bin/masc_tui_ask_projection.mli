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

val empty_draft : ask_id:string -> draft
val draft_ask_id : draft -> string

val draft_for : draft option -> row:Masc.Tui_decode.ask_row -> draft
(** The draft when it belongs to [row], a fresh one otherwise. Moving the
    cursor to another ask therefore starts clean without the caller having to
    remember to reset, which is the whole class of bug this removes. *)

val response_for :
  draft -> question:Masc.Tui_decode.ask_question -> draft_response option

val summarize_answer : draft -> row:Masc.Tui_decode.ask_row -> string
(** A human line for what the draft answers, in the labels the operator saw
    (never choice ids): chosen labels joined per question, a written answer
    quoted, a skipped question named. Empty when nothing is answered yet, so a
    caller can fall back to the Keeper name alone. *)

val toggle_choice :
  draft ->
  question:Masc.Tui_decode.ask_question ->
  choice:Masc.Tui_decode.ask_choice ->
  draft
(** [Ask_single] replaces the selection, and re-picking the chosen id clears
    it, so a mis-press needs no second key. [Ask_multi] adds or removes;
    removing the last one clears the response, because an empty selection is
    not an answer. Taking the choice rather than an id means an id this ask
    never offered cannot be drafted. *)

type free_text_slot

val free_text_slot : Masc.Tui_decode.ask_question -> free_text_slot option
(** [None] when the question offers choices only. A slot is the only way to
    reach [set_text], so the editor cannot open on a question whose answer the
    server would refuse. *)

val free_text_hint : free_text_slot -> string option
val set_text : draft -> slot:free_text_slot -> text:string -> draft
(** Blank text clears the response instead of recording it: the domain rejects
    a blank write, and an editor emptied by backspaces means unanswered. *)

val skip : draft -> question:Masc.Tui_decode.ask_question -> draft
val clear : draft -> question:Masc.Tui_decode.ask_question -> draft

type readiness =
  | Ready of Yojson.Safe.t  (** the [answers] array, in the ask's order *)
  | Missing of Masc.Tui_decode.ask_question list
  | Not_open
      (** Already answered or withdrawn. A surface that offered submit here
          would be promising something the store settles by first write. *)

val readiness : draft -> row:Masc.Tui_decode.ask_row -> readiness
(** A draft belonging to another ask contributes nothing, so the answer is
    every question missing -- which is true, not a guess. *)

val request_body :
  answers:Yojson.Safe.t ->
  actor_id:string option ->
  session_id:string option ->
  Yojson.Safe.t

type gate =
  | Ask_gate_blocked_inflight
  | Ask_gate_arm of string  (** the ask id now armed *)
  | Ask_gate_submit

val gate_transition :
  inflight:bool -> pending:string option -> ask_id:string -> gate
(** Two presses to answer, matching the approval queue: an answer is a fold
    that settles on first write and cannot be taken back. *)

val reconcile_cursor :
  current_rows:Masc.Tui_decode.ask_row list ->
  cursor:int ->
  next_rows:Masc.Tui_decode.ask_row list ->
  int
(** Follows the selected ask across a snapshot replacement, falling back to
    the bounded numeric cursor only when that ask is gone. *)
