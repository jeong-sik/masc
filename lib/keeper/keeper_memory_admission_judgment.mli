(** Pure boundary for Librarian judgments about pending explicit-write inputs.
    Parsing or verifying a judgment neither admits Memory nor consumes a queue. *)

type outcome =
  | Incorporated of string
  | Already_represented of string
  | Not_durable
  | Deferred
(** The strings name exact claims in the final Memory selection. They are
    references, not a semantic similarity test or copies of candidate text. *)

type judgment =
  { request_id : string
  ; outcome : outcome
  ; reason : string
  }

val unwrap :
  batch:Keeper_memory_admission_queue.batch -> Yojson.Safe.t ->
  ((Yojson.Safe.t * judgment list), string) result
(** Require the exact wrapper [{memory: object, candidates: [...]}]. Each
    candidate has exactly [request_id], [outcome], [memory_claim] and [reason].
    Every batch request must occur exactly once. Incorporated/already-represented
    outcomes require a nonblank claim; other outcomes require null. Reasons
    must be nonblank. Returns judgments in batch order and the untouched Memory
    object, whose existing domain parser remains responsible for its schema. *)

val verify :
  facts:Keeper_memory_os_types.fact list -> judgment list -> (unit, string) result
(** Every named claim must exist exactly in the final selected facts. This is
    reference integrity, not proof of the model's semantic judgment. The commit
    owner must also protect those destinations against concurrent retirement. *)

val settled : judgment list -> bool
(** False if any candidate is Deferred. The first admission slice commits only
    a settled whole batch; callers must not commit a partial prefix here. *)

val output_schema : memory_schema:Yojson.Safe.t -> Yojson.Safe.t
(** Strict structured-output envelope around the caller's original Memory
    schema. Nullable claim fields are required; decoding enforces their
    outcome-specific meaning and complete candidate coverage. *)

val prompt_suffix : batch:Keeper_memory_admission_queue.batch -> string
(** Describes the separate candidate authority and strict response wrapper,
    carrying original candidate payloads as untrusted proposed data. *)

type retirement_evidence =
  | Available of Keeper_memory_os_current.archived_fact list
  | Unavailable of string
(** Read-only historical evidence; unavailable history is never an empty archive. *)

val retirement_prompt_suffix :
  batch:Keeper_memory_admission_queue.batch -> retirement_evidence -> string
(** Include only originals with the exact memory identity of a pending candidate,
    linked to its request IDs. No matching originals produces the empty string.
    The archive omits current identities, later re-additions or absorptions and
    removals without explicit reasons. Absence proves no historical negative.
    This evidence neither authorizes restoration nor rejects a candidate. It is
    a pre-call observation and does not protect against retirement after reading. *)
