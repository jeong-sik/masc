(** Pure admission of approval evidence into canonical conversation history.
    The identity is carried by the evidence message itself, never a Context
    flag. Removing that message during compaction removes admission evidence.
    A returned checkpoint is only a candidate: callers must persist it before
    acknowledging input, while retaining the independent unfinished operation. *)

type identity

type error =
  | Invalid_identity
  | Invalid_input
  | Malformed_marker
  | Conflicting_evidence
  | Duplicate_admission

val error_to_string : error -> string

(** [evidence_fingerprint] identifies durable effect evidence, independent of
    whether this invocation executed or merely recovered that same evidence. *)
val identity :
  approval_id:string -> evidence_fingerprint:string -> (identity, error) result

type admission =
  | Admission_new of Agent_core.Checkpoint.t
  | Admission_resume of Agent_core.Checkpoint.t

(** Require an untagged User message. Matching admission preserves the entire
    checkpoint, including newer intervening conversation. A malformed marker,
    duplicate admission, or conflicting evidence is an explicit error. A
    compaction-rewritten message retains its content and other metadata, loses
    its stale marker, and the canonical input is admitted again. *)
val prepare :
  identity:identity -> message:Agent_core.Types.message ->
  Agent_core.Checkpoint.t -> (admission, error) result

(** Whether this transmission view still contains intact admitted evidence.
    This is not persistence authority; [prepare] validates canonical history. *)
val contains : identity:identity -> message:Agent_core.Types.message ->
  Agent_core.Types.message list -> bool
