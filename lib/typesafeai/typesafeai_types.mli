(** TypeSafe AI (System One) core types and JSON codecs.
    Designed for zero-parsing, typed, calibrated decision models. *)

type model =
  | Jev_latest
  | Jev_preview
  | Custom of string

val model_to_string : model -> string
val model_of_string : string -> model

type choice_question =
  { instructions : string
  ; criteria : (string * string option) list
  }

type score_question =
  { instructions : string
  ; criteria : string list
  }

type noul_question =
  { instructions : string
  ; criteria : (string * string) option (** Optional (true_meaning, false_meaning) *)
  }

type question =
  | Choice of choice_question
  | Score of score_question
  | Noul of noul_question

type choice_answer =
  { choice : string
  ; probabilities : (string * float) list
  ; confidence : float
  }

type score_answer =
  { score : float
  ; probabilities : (int * float) list
  ; confidence : float
  }

type noul_answer =
  { noul : float
  }

type answer =
  | Choice_answer of choice_answer
  | Score_answer of score_answer
  | Noul_answer of noul_answer

type usage =
  { input_tokens : int
  ; output_tokens : int
  }

type eval_response =
  { model : string
  ; answers : (string * answer) list
  ; usage : usage option
  }

val question_to_yojson : question -> Yojson.Safe.t
val request_to_yojson :
  model:string ->
  state:Yojson.Safe.t ->
  questions:(string * question) list ->
  Yojson.Safe.t

val answer_of_yojson : Yojson.Safe.t -> (answer, string) result
(** Rejects non-finite values in every numeric answer field, including
    confidence and probability maps, before they can enter durable JSON. *)

val answer_to_yojson : answer -> Yojson.Safe.t
val eval_response_of_yojson : Yojson.Safe.t -> (eval_response, string) result
(** Usage is known only when both token counts are non-negative integers.
    Absent or malformed usage stays [None] without rejecting valid answers;
    it is never fabricated as a measured zero. *)

(** The closed option set of one [Choice] question. The request's criteria and
    the decoding of its answer are both built from this one value, so they
    cannot name different options. *)
type 'option choice_set

val choice_set :
  options:'option list ->
  label:('option -> string) ->
  describe:('option -> string option) ->
  ('option choice_set, string) result
(** [label] is the key the request sends for an option and the answer
    returns. [Error] when [options] is empty or two options share a label:
    a question with no option has nothing to ask, and a shared label would
    send one criteria key twice and read an answer back as whichever option
    came first. *)

val choice_of_set : instructions:string -> 'option choice_set -> question
(** A [Choice] question whose criteria are the set's [options], in order. *)

type 'option decoded_choice =
  { choice : 'option
  ; probabilities : ('option * float) list
  ; confidence : float
  }

val decode_choice :
  'option choice_set -> answer -> ('option decoded_choice, string) result
(** [Error] when [answer] is not a choice answer, or when its choice or any of
    its probability keys is not the label of an option in the set. *)
