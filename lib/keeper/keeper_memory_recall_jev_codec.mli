(** The three recall questions on the Jev wire
    (docs/rfc/RFC-keeper-recall-reaches-the-turn.md, sections 4.2 and 4.3):
    how a request is built and how an answer is read. Nothing is sent here.

    Question (a) asks per candidate whether the turn could use the memory.
    Its wording is the one measured in layer 0 (two labels, 10 runs on one
    Keeper). Questions (b) and (c) have not been run against Jev yet. *)

(** Which of the three questions a request asks: (a) per candidate, (b) per
    turn, (c) per carried candidate. *)
type request_kind =
  | Candidate_question
  | Turn_question
  | Time_question

val request_kind_token : request_kind -> string
(** [candidates], [turn], [time]. *)

type request =
  { kind : request_kind
  ; state : Yojson.Safe.t
  ; questions : (string * Typesafeai_types.question) list
  }
(** What {!Typesafeai_types.request_to_yojson} takes besides the model id, and
    the question it asks. A record of a request reads [kind] and does not infer
    it from the shape of [state]. *)

type build_error =
  | Duplicate_candidate_id of string
      (** Two candidates share an id; a request would hold one question key
          twice. Nothing is dispatched. *)
  | Choice_set_invalid of string
      (** The option set of a question could not be built; carries the
          client's reason. *)
  | Guidance_unavailable of string
      (** Required managed guidance could not be resolved or rendered. *)

type guidance
(** Immutable prompt and criterion snapshot shared by every question in one
    recall flow, including capacity partitions and later time questions. *)

val load_guidance : question_ids:string list -> (guidance, build_error) result
(** Resolve every managed instruction and criterion once, then render all
    original candidate/time questions eagerly. Requires original candidate IDs;
    it does not invent a validation ID. The immutable map supports only these
    IDs and their subsets, with no renderer or registry lookup after loading. *)

(** One read answer. [Not_decoded] carries the reason for the evaluation
    record. The probabilities and confidence of an [Answered] value are
    reported values; nothing in this module or in the reduction branches on
    them. *)
type 'a answer =
  | Answered of 'a Typesafeai_types.decoded_choice
  | Not_decoded of string

val candidate_request :
  guidance:guidance -> purpose:Yojson.Safe.t -> Keeper_memory_recall_candidates.piece ->
  (request, build_error) result
(** Question (a). [state] holds the purpose and the candidate lines, and every
    candidate gets one question, keyed by its id, whose instructions are short
    and name the entry to read. The rules sit in the instructions, not in
    [state], so an untrusted claim never shares a field with them. *)

val decode_candidates :
  Keeper_memory_recall_candidates.piece -> Typesafeai_types.eval_response ->
  (string * Keeper_memory_recall_judgment.candidate_decision answer) list
(** One entry per candidate of the piece, in piece order. A response with a
    duplicate or an unknown answer id leaves every candidate of the piece
    [Not_decoded]. A missing answer or an answer that does not decode leaves
    that candidate [Not_decoded]. The client rejects an answer whose label is
    not the most probable option; such a candidate is [Not_decoded] too.

    What the client has already refused never reaches this function. A
    response whose answers are malformed in structure (a repeated answer key,
    a confidence outside 0 to 1, an empty probability map, an unknown answer
    type) fails as a whole in the client and comes back as a failed request
    with status 200. A caller that counts failures by reason maps that status
    to [Invalid_answer]; otherwise those pieces count as [Provider_failed].
    The duplicate check here serves responses that were not built by the
    client. *)

val candidate_result :
  id:string -> Keeper_memory_recall_judgment.candidate_decision answer ->
  Keeper_memory_recall_judgment.candidate_result

val turn_request :
  guidance:guidance -> purpose:Yojson.Safe.t -> (request, build_error) result
(** Question (b). [state] holds the purpose and no candidates. *)

val decode_turn :
  Typesafeai_types.eval_response ->
  Keeper_memory_recall_judgment.turn_need answer
(** Exactly one answer under the turn question id is accepted. *)

val turn_answer :
  Keeper_memory_recall_judgment.turn_need answer ->
  Keeper_memory_recall_judgment.turn_answer

val time_request :
  guidance:guidance -> Keeper_memory_recall_candidates.piece -> (request, build_error) result
(** Question (c), for candidates question (a) carried. Same shape as
    {!candidate_request} except that [state] holds no purpose: the question is
    about the memory alone, so the turn input is not sent. *)

val decode_time :
  Keeper_memory_recall_candidates.piece -> Typesafeai_types.eval_response ->
  (string * Keeper_memory_recall_judgment.time_nature answer) list
(** Same reading rules as {!decode_candidates}. *)

val time_mark :
  Keeper_memory_recall_judgment.time_nature answer ->
  Keeper_memory_recall_judgment.time_mark
(** [Not_decoded] is [Time_unjudged], never [Marked Standing]. *)
