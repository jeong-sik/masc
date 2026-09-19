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
  ; probabilities : float list
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
val eval_response_of_yojson : Yojson.Safe.t -> (eval_response, string) result

(** The closed option set of one [Choice] question. The request's criteria and
    the decoding of its answer are both built from this one value, so they
    cannot name different options. *)
type 'option choice_set =
  { options : 'option list
  ; label : 'option -> string
      (** The key the request sends for this option and the answer returns. *)
  ; describe : 'option -> string option
  }

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
