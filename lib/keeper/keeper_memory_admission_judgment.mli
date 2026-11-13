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
  ((Yojson.Safe.t * judgment list * string list), string) result
(** Require the exact wrapper [{memory: object, candidates: [...], change_support: [...]}]. Each
    candidate has exactly [request_id], [outcome], [memory_claim] and [reason].
    Every batch request must occur exactly once. Incorporated/already-represented
    outcomes require a nonblank claim; other outcomes require null. Reasons
    must be nonblank. Returns judgments in batch order and the untouched Memory
    object plus declared supporting request IDs. The existing domain parser remains responsible for the Memory schema. *)

val verify :
  facts:Keeper_memory_os_types.fact list -> judgment list -> (unit, string) result
(** Every named claim must exist exactly in the final selected facts. This is
    reference integrity, not proof of the model's semantic judgment. The commit
    owner must also protect those destinations against concurrent retirement. *)

val settled_requests : judgment list -> string list
(** Candidate request IDs whose judgment is not Deferred. This does not imply
    that a proposed disposition is independent of deferred knowledge. *)

val verify_support :
  additions:Keeper_memory_os_types.fact list ->
  change_support:string list -> judgment list -> (unit, string) result
(** Require unique, known supporting requests with Incorporated or
    Already_represented outcomes. Each addition must be named by an
    Incorporated supporting request: a new claim that absorbs no current
    memory, or that revises a dropped one through [supersedes]. Drops and
    merges (new claims that only absorb current memories) need no support:
    they rest on the current Memory the admission read whole (RFC-0517 §7.1).
    The caller decides which new claims are additions. This validates declared
    references, not the model's semantic completeness or truth. *)

val output_schema : memory_schema:Yojson.Safe.t -> Yojson.Safe.t
(** Strict structured-output envelope around the caller's original Memory
    schema. Nullable claim fields are required; decoding enforces their
    outcome-specific meaning and complete candidate coverage. *)

val prompt_suffix : instructions:string -> batch:Keeper_memory_admission_queue.batch -> string
(** Frame the supplied managed policy with original candidate payloads as
    untrusted proposed data. The preparation owner validates and captures the
    instruction resolution before calling this pure formatter. *)

type retirement_evidence =
  | Available of Keeper_memory_os_current.archived_fact list
  | Unavailable of string
(** Read-only historical evidence; unavailable history is never an empty archive. *)

val retirement_prompt_needed :
  batch:Keeper_memory_admission_queue.batch -> retirement_evidence -> bool
(** The suffix needs policy for unavailable history or at least one exact
    candidate identity match. Shares the formatter's payload derivation. *)

val retirement_prompt_suffix :
  instructions:string -> batch:Keeper_memory_admission_queue.batch -> retirement_evidence -> string
(** Frame the supplied managed retirement policy with originals that have
    the exact memory identity of a pending candidate,
    linked to its request IDs. No matching originals produces the empty string.
    The archive omits current identities, later re-additions or absorptions and
    removals without explicit reasons. Absence proves no historical negative.
    This evidence neither authorizes restoration nor rejects a candidate. It is
    a pre-call observation and does not protect against retirement after reading. *)
