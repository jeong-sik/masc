(** The absorb gate of a librarian pass (RFC-librarian-absorb-gate).

    A librarian answer names current memories a new claim absorbs. Before
    the answer is applied, each absorbed memory is cut into statements and a
    judgment model (TypeSafe Jev) is asked, per statement, whether the claim
    conveys it. A memory with a statement the claim does not convey is taken
    out of the answer's [absorbed] list and stays current; the new claim is
    still applied. The rest are absorbed as the answer said.

    The gate only ever narrows [absorbed]. When the model cannot be asked --
    no key, the lane or the gate turned off -- the answer is applied as it
    came, which is what happened before the gate. When it was asked and did
    not answer -- a transport or decoding failure -- the answer is applied
    except for what could not have been judged for its size
    ({!request_bytes_limit}), which stays current: that part of the verdict
    is the gate's own and does not depend on the model. *)

(** {1 Statements} *)

val statements : string -> string list
(** A memory cut into the statements the model is asked about: line breaks,
    then sentence ends ([. ! ?] before whitespace, [다.], [;] before
    whitespace, and [ — ]); nothing dropped; a piece
    shorter than {!min_statement_chars} characters carried into the next;
    every resulting statement is kept. Sentence boundaries match the scorer
    in issue #37079; the gate evaluates the full memory rather than a sample.
    Whitespace is ASCII whitespace only: a non-ASCII space is an ordinary
    character, the same on both sides of the golden (the calibration corpus
    held none; see the script). *)

val min_statement_chars : int

(** {1 Judgment} *)

type evaluate =
  state:Yojson.Safe.t
  -> questions:(string * Typesafeai_types.question) list
  -> (Typesafeai_types.eval_response, string) result
(** One evaluation request. {!run} installs {!Typesafeai_client.evaluate};
    a test installs a function that answers from a table. *)

type source_verdict =
  { memory_id : string
  ; into : string
  ; statements : int
  ; not_conveyed : int  (** statements the claim did not convey *)
  }

type judged =
  { absorbed : Keeper_memory_os_types.absorbed_statement list
        (** the answer's absorptions the gate lets through, in the answer's order *)
  ; left : source_verdict list
        (** memories that stay current: at least one statement not conveyed *)
  ; conveyed : source_verdict list  (** memories absorbed: every statement conveyed *)
  ; unjudged : Keeper_memory_os_types.absorbed_statement list
        (** absorptions the gate could not judge because the answer names a
            claim or a memory the pass did not carry; applied as they came *)
  ; unjudgeable : Keeper_memory_os_types.absorbed_statement list
        (** absorptions the gate could not judge because the claim, or a
            statement of the memory, does not fit a request
            ({!request_bytes_limit}); the memory stays current *)
  ; requests : int  (** evaluation requests made *)
  }

type outcome =
  | Open of
      { reason : string
      ; absorbed : Keeper_memory_os_types.absorbed_statement list
      ; left : source_verdict list
      ; unjudgeable : Keeper_memory_os_types.absorbed_statement list
      }
      (** the model stopped answering. What the gate had decided by then
          stays decided: [unjudgeable] (too large to ask,
          {!request_bytes_limit}) and [left] (a completed answer showed a
          statement not conveyed) stay current; [absorbed] is the answer's
          list without them, applied as answered. [reason] is for the log. *)
  | Judged of judged

val conveyed_boundary : float
(** A statement is conveyed when its [noul] is at least this: the midpoint
    of a yes/no probability, not a tuned number. The verdict does depend on
    it. Re-counting the scoring of issue #37079 (84 production sources, 314
    statements) at 0.3 / 0.5 / 0.7: statement-level agreement with the list
    scorer 89 / 88 / 82%, sources whose verdict agrees with that scorer
    87 / 88 / 76%, sources absorbed 51 / 38 / 19%, and 11 / 0 / 16 of the 84
    sources change verdict against 0.5; 16% of statements fall between 0.3
    and 0.7 (the question's ends, 0.94 and 0.10, are means). The midpoint
    sits on the agreement plateau (0.3 to 0.5) and absorbs the same share
    as the independent scorer (38%). Moving it trades absorption for
    retention, which RFC-librarian-absorb-gate section 7 leaves to phase 2,
    not to this constant. *)

val questions_per_request : int
(** Statements are asked in requests of at most this many questions. The
    model evaluates a request's questions in parallel; the limit bounds one
    request's size, not the number of statements judged. *)

val state_bytes_limit : int
(** The claim, sent as the state, is at most this many bytes: half of
    {!request_bytes_limit}, so the questions sharing the request with it
    always have the other half. A claim over it cannot be asked about;
    every memory it absorbs stays current. *)

val request_bytes_limit : int
(** A request carries at most this many bytes of claim and questions (each
    statement with the fixed instruction and criteria text sent beside it):
    the smallest request bound among the routes the lane can use (32k
    tokens on OpenRouter, 64k at TypeSafe) taken in bytes, so a request is
    never refused for its size. A statement that does not fit a request
    beside its claim cannot be judged, and its memory stays current rather
    than being absorbed on a predictable refusal. *)

val judge
  :  evaluate:evaluate
  -> facts:Keeper_memory_os_types.fact list
  -> new_claims:Keeper_memory_os_types.fact list
  -> absorbed:Keeper_memory_os_types.absorbed_statement list
  -> outcome
(** [facts] are the current memories the pass read, before the answer removes
    absorbed memories; [new_claims] the claims the answer adds; [absorbed] the
    absorptions it states. One request per absorbing claim, chunked by
    {!questions_per_request}. *)

(** {1 Entry point} *)

val run
  :  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t
  -> keeper_id:string
  -> facts:Keeper_memory_os_types.fact list
  -> new_claims:Keeper_memory_os_types.fact list
  -> absorbed:Keeper_memory_os_types.absorbed_statement list
  -> unit
  -> Keeper_memory_os_types.absorbed_statement list
(** The absorptions to apply. Reads {!Typesafeai_config}: without a key, or
    with the lane turned off, returns [absorbed] unchanged and says nothing.
    Otherwise judges with {!Typesafeai_client.evaluate} and writes one keeper
    log line with the counts, or the reason the gate stayed open. *)
