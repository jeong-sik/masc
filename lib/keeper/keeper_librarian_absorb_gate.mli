(** The absorb gate of a librarian pass (RFC-librarian-absorb-gate).

    A librarian answer names current memories a new claim absorbs. Before
    the answer is applied, each absorbed memory is cut into statements and a
    judgment model (TypeSafe Jev) is asked, per statement, whether the claim
    conveys it. A memory with a statement the claim does not convey is taken
    out of the answer's [absorbed] list and stays current; the new claim is
    still applied. The rest are absorbed as the answer said.

    The gate only ever narrows [absorbed]. When the model cannot be asked --
    no key, the lane turned off, a transport or decoding failure -- the
    answer is applied as it came, which is what happened before the gate. *)

(** {1 Statements} *)

val statements : string -> string list
(** A memory cut into the statements the model is asked about: line breaks,
    then sentence ends ([. ! ?] before whitespace, [다.], [;] before
    whitespace, and [ — ]); backticks dropped; a piece
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
  | Open of string
      (** the model did not answer; [absorbed] is applied as it came. The
          string says why, for the log. *)
  | Judged of judged

val conveyed_boundary : float
(** A statement is conveyed when its [noul] is at least this. It is the
    boundary of a yes/no probability, not a tuned number; the calibration in
    issue #37079 (floor 0.94, ceiling 0.10) and the 88% statement-level
    agreement with the list scorer were both measured at it. *)

val questions_per_request : int
(** Statements are asked in requests of at most this many questions. The
    model evaluates a request's questions in parallel; the limit bounds one
    request's size, not the number of statements judged. *)

val request_bytes_limit : int
(** A request carries at most this many bytes of claim and statements, well
    under the model's 64k-token request and 32k-token state limits, so a
    request is never refused for its size. A claim or a statement that does
    not fit cannot be judged, and its memory stays current rather than being
    absorbed on a predictable refusal. *)

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
