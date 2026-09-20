(** Explicit synthetic measurements, separate from operational Librarian runs.
    The output JSON file is authoritative; a blob is only a published copy. *)

type fact = { id : string; claim : string } [@@deriving yojson]
type source_turn = { trace_id : string; turn : int; text : string } [@@deriving yojson]
type answer_context =
  { keeper_name : string
  ; trace_id : string
  ; read_position : int
  ; facts : fact list
  ; unread : string
  }
[@@deriving yojson]
type case = { id : string; source : source_turn; context : answer_context }
[@@deriving yojson]
type dataset = { synthetic : bool; cases : case list } [@@deriving yojson]

type prompt = { system : string; user : string } [@@deriving yojson]
type generation_request =
  { runtime_id : string
  ; requested_model : string
  ; prompt : prompt
  ; prepared_requests : Llm_provider.Request_wire_observer.observation list
  }
[@@deriving yojson]
type text_response = { response_id : string; model : string; text : string }
[@@deriving yojson]
type generation = { request : generation_request; response : text_response }
[@@deriving yojson]
type failed_generation =
  { request : generation_request
  ; error : string
  ; incomplete_response : text_response option
  }
[@@deriving yojson]
type judge_request =
  { endpoint : string
  ; model : string
  ; question_id : string
  ; reference : string
  ; question : string
  ; answer : string
  ; instructions : string
  ; true_criteria : string
  ; false_criteria : string
  }
[@@deriving yojson]
type judgment =
  { request : judge_request
  ; response_model : string
  ; request_body_sha256 : string
  ; probability : float
  }
[@@deriving yojson]
type failed_judgment = { request : judge_request; error : string } [@@deriving yojson]
type progress =
  | Not_started
  | Question_failed of failed_generation
  | Question_ready of generation
  | Answer_failed of generation * failed_generation
  | Answer_ready of generation * generation
  | Judge_failed of generation * generation * failed_judgment
  | Scored of generation * generation * judgment
[@@deriving yojson]
type sample = { case : case; progress : progress } [@@deriving yojson]
type t =
  { schema : string
  ; run_id : string
  ; started_at : string
  ; input_path : string
  ; input_sha256 : string
  ; output_path : string
  ; config_revision : string
  ; binary_commit : string option
  ; executable_sha256 : string option
  ; samples : sample list
  }

val schema : string
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
(** Checks schema, unique sample IDs and finite probabilities in [0,1]. *)
val parse_dataset : Yojson.Safe.t -> (dataset, string) result
(** Requires explicit synthetic input, nonempty cases and unique IDs. *)
val sha256 : string -> string
val question_prompt : source_turn -> prompt
val answer_prompt : question:string -> answer_context -> prompt
(** This boundary cannot access the reference source turn. *)
val judge_request : endpoint:string -> model:string -> case ->
  question:string -> answer:string -> judge_request
val judge_state : judge_request -> Yojson.Safe.t
val judge_questions : judge_request -> (string * Typesafeai_types.question) list
val judgment : judge_request -> Typesafeai_client.evaluated -> (judgment, string) result
(** Requires exactly the requested Noul answer and a finite raw probability. *)
