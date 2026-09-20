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
    whitespace, and [ — ]); markup ([**] and backticks) dropped; a piece
    shorter than {!min_statement_chars} characters carried into the next;
    at most {!max_statements_per_memory} kept, spread evenly over the memory.
    The same cut the scorer in issue #37079 used, so its calibration of the
    question applies. Whitespace is ASCII whitespace. *)

val min_statement_chars : int
val max_statements_per_memory : int

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

val judge
  :  evaluate:evaluate
  -> facts:Keeper_memory_os_types.fact list
  -> new_claims:Keeper_memory_os_types.fact list
  -> absorbed:Keeper_memory_os_types.absorbed_statement list
  -> outcome
(** [facts] are the current memories the pass read (the answer's
    projection); [new_claims] the claims the answer adds; [absorbed] the
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
