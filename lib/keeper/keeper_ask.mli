(** Keeper_ask — surface-neutral structured question lifecycle.

    A Keeper asks a human a question that carries named choices, then keeps
    working. The answer arrives later, from whichever surface the human is at,
    and reaches the Keeper as a wake.

    This is not the Gate approval queue. Gate answers "may I run this tool" and
    carries [tool_name] and [input_hash]; its response vocabulary is closed at
    [Approve | Reject of string]. This module answers "which way should I go",
    and its choices have no tool behind them.

    There is no expiry and no timeout. An unanswered question stays open until
    a human answers it or the asking Keeper withdraws it. A Keeper that asked
    is not suspended and holds no lane.

    {!question}, {!ask}, and {!parse_answers} return [result] and the
    corresponding types are [private], so a question nobody can answer and an
    answer naming a choice that was never offered are both unrepresentable. *)

(** {1 Choices} *)

type invalid_choice =
  | Choice_id_blank
  | Choice_label_blank

type choice = private {
  choice_id : string;
      (** Stable identity. Answers reference this, never [label]: editing the
          wording of a choice must not orphan answers already recorded. *)
  label : string;
  description : string option;
}

val choice :
  choice_id:string ->
  label:string ->
  ?description:string ->
  unit ->
  (choice, invalid_choice) result

(** {1 Questions} *)

type answer_mode =
  | Single
  | Multi

type free_text =
  | Free_text_allowed of { hint : string option }
  | Choices_only

type invalid_question =
  | Question_id_blank
  | Header_blank
  | Prompt_blank
  | No_way_to_answer
      (** No choices were offered and free text was refused, so no submission
          could ever satisfy this question. *)
  | Duplicate_choice_ids of string list

type question = private {
  question_id : string;
  header : string;  (** Short label for narrow surfaces such as the TUI. *)
  prompt : string;
  choices : choice list;
  mode : answer_mode;
  free_text : free_text;
}

val question :
  question_id:string ->
  header:string ->
  prompt:string ->
  choices:choice list ->
  mode:answer_mode ->
  free_text:free_text ->
  (question, invalid_question) result

(** {1 Asks} *)

type invalid_ask =
  | Ask_id_blank
  | Keeper_name_blank
  | No_questions
  | Duplicate_question_ids of string list

type ask = private {
  ask_id : string;
  keeper_name : string;
  questions : question list;
  context : string option;
      (** Why the Keeper is asking, in its own words. Surfaces render this
          beside the prompt: a reader who cannot see the reason cannot tell a
          decision that matters from one that does not. *)
  turn_id : int option;
  task_id : string option;
  goal_id : string option;
  continuation : Keeper_continuation_channel.t;
      (** Where the answer is delivered back. [Unrouted] records that the
          origin could not be determined rather than picking a default. *)
  asked_at : float;
}

val ask :
  ask_id:string ->
  keeper_name:string ->
  questions:question list ->
  ?context:string ->
  ?turn_id:int ->
  ?task_id:string ->
  ?goal_id:string ->
  continuation:Keeper_continuation_channel.t ->
  asked_at:float ->
  unit ->
  (ask, invalid_ask) result

(** {1 Answers} *)

type response =
  | Chose of { choice_ids : string list }
  | Wrote of string
  | Skipped
      (** The human read the question and declined to answer it. Distinct from
          an absent submission, which is [Unanswered] and rejected. *)

type answer = private {
  question_id : string;
  response : response;
}

type invalid_answer =
  | Unknown_question of { question_id : string }
  | Unknown_choice of { question_id : string; choice_id : string }
  | Duplicate_choice of { question_id : string; choice_id : string }
  | Multiple_choices_for_single of { question_id : string; count : int }
  | Empty_selection of { question_id : string }
  | Free_text_not_offered of { question_id : string }
  | Free_text_blank of { question_id : string }
  | Answered_twice of { question_id : string }
  | Unanswered of { question_id : string }

val parse_answers :
  ask:ask ->
  submissions:(string * response) list ->
  (answer list, invalid_answer list) result
(** Checks every submission against the question it names, and requires one
    submission per question of the ask. Every violation is reported, not just
    the first: a surface that re-prompts one field at a time makes the human
    pay a round trip per mistake. Returned answers follow the ask's question
    order, not the submission order. *)

(** {1 Responders} *)

type responder = {
  surface : Surface_ref.t;
  actor_id : string option;
  display_name : string option;
}

(** {1 Events} *)

type event =
  | Asked of ask
  | Answered of {
      ask_id : string;
      answers : answer list;
      responder : responder;
      answered_at : float;
    }
  | Withdrawn of {
      ask_id : string;
      reason : string;
      withdrawn_at : float;
    }
      (** The asking Keeper no longer needs the answer. Withdrawal is the
          Keeper's own act; nothing withdraws a question on its behalf after
          some interval. *)

(** {1 Projection} *)

type resolution =
  | Open
  | Answered_by of {
      answers : answer list;
      responder : responder;
      answered_at : float;
    }
  | Withdrawn_because of { reason : string; withdrawn_at : float }

val fold_events : event list -> (string * (ask * resolution)) list
(** Folds an append-only event log into one row per [ask_id], in the order the
    asks were first recorded. The first terminal event for an ask wins: a
    second [Answered] for an ask already answered is dropped, so two surfaces
    racing to answer the same question resolve to whichever write landed
    first. An [Answered] or [Withdrawn] naming an unknown ask is dropped. *)

val open_asks : event list -> ask list

(** {1 Labels and codecs} *)

val event_to_json : event -> Yojson.Safe.t
val event_of_json : Yojson.Safe.t -> (event, string) result

val invalid_choice_to_string : invalid_choice -> string
val invalid_question_to_string : invalid_question -> string
val invalid_ask_to_string : invalid_ask -> string
val invalid_answer_to_string : invalid_answer -> string
