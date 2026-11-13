(** The immutable original of one verifier review attempt.

    A verifier's review asks a tool-capable reviewer for a verdict on a fixed
    subject (a verification request), with the evidence the verifier captured
    and the lookup grants the producer was given. This module names that
    input as data so a worker handed the value can only answer the review,
    not widen the subject, swap the evidence or restore a closure it was
    never given.

    Unlike the HITL judge original (an approval has one bundled context), a
    verifier review keeps its pieces apart so that a worker cannot flatten
    away the distinction that protects evidence: the subject, the question
    the verifier asked of it, and the lookup grants the reviewer held. The
    three are fixed together for one attempt. The next attempt asks the same
    subject and question with the lookup grants current at that attempt
    ({!successor}). Nothing here reads a store, calls a model or rebuilds a
    tool dispatch, so an original prepared for one verification cannot be
    applied to a different attempt.

    The module owns the review's system prompt and output contract; the
    worker's request builder reads them from here, so a prepared original and
    the prompt the worker renders cannot drift apart. *)

type t

val schema : string
(** The wire schema name carried by {!to_json}. *)

val system_prompt
  :  lookup_schemas:string list
  -> question:Task.Anti_rationalization.verdict_question
  -> lookup_root:Task.Anti_rationalization.lookup_root
  -> Task.Anti_rationalization.review_request
  -> (string, string) result
(** The review system prompt as {!Task.Anti_rationalization} renders it for the
    fixed question, lookup root and review request. [lookup_schemas] are the
    tool names the reviewer held; the lookup section names them but the dispatch
    is never consulted, so rendering authorises no read. A template that does
    not render is an error, not a fallback, because a silent fallback would let
    a re-rendered prompt drift from the one the original fixed. {!prepare}
    captures the result so the value carries the exact text. *)

val canonical_output_contract : unit -> string
(** The output-contract sentence with the canonical verdict schema. *)

type lookup =
  { granted_root : Task.Anti_rationalization.lookup_root
  ; granted_tools : string list
  ; question_digest : string
  ; authority_digest : string
  }
(** What one attempt captures from a host-built task review surface: the
    lookup root, the tool names the reviewer holds and the two canonical
    digests. The dispatch function is deliberately absent, so this value
    authorises no read. *)

val lookup_of_authority : Verification_authority_tools.task_review -> lookup
(** Read the root, tool names, question digest and authority digest of one
    task review surface. *)

val prepare
  :  generator_runtime:string option
  -> verification_id:string
  -> attempt:int
  -> question:Task.Anti_rationalization.verdict_question
  -> lookup:lookup
  -> Task.Anti_rationalization.review_request
  -> (t, string) result
(** Capture the original of one review attempt. Both digests must be canonical
    SHA-256 text and the tool names non-empty. This does not mutate the
    request, bind a lane or call a model. *)

val verification_id : t -> string
val attempt : t -> int
val review_request : t -> Task.Anti_rationalization.review_request
val generator_runtime : t -> string option
(** Captured producer runtime evidence, never rebuilt from a later runtime alias. *)
val question : t -> Task.Anti_rationalization.verdict_question
val question_binding : t -> string
(** The canonical question digest of the host-built task review surface. *)
val lookup_root : t -> Task.Anti_rationalization.lookup_root
val lookup_schemas : t -> string list
val authority_binding : t -> string
(** The canonical authority digest of the host-built task review surface. *)
val system_prompt_text : t -> string
val system_instructions : t -> string
(** The exact separate verifier system instructions captured at preparation. *)
val output_contract : t -> string

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Strict inverse of {!to_json}: the schema name, the exact field set and the
    field types must match, and the fixed subject, question and lookup grants
    round-trip unchanged. Unknown or missing fields are errors. *)

val digest : t -> (string, string) result
(** SHA-256 of the canonical JSON of {!to_json}. Equal originals have equal
    digests whatever the key order they were read in. *)

type successor_error =
  | Question_changed
  | Prompt_unavailable of string
  | Successor_unavailable of string

val successor : lookup:lookup -> t -> (t, successor_error) result
(** The next attempt asks the parent's question with the current lookup. The
    verification id, review request, question (with its few-shot block),
    captured producer runtime and question digest come from the parent. The
    lookup root, tool names and authority digest come from [lookup]. The
    prompt is rendered now from them, the instructions from the current
    prompt template, and the output contract is this build's.

    A [lookup] whose question digest differs from the parent's is
    [Question_changed]. A prompt or instruction template that cannot be
    rendered now is [Prompt_unavailable]; it says nothing about the parent.
    Any other refusal is [Successor_unavailable]. *)

val is_successor_of : parent:t -> t -> bool
(** [true] when the child is the next attempt of [parent] and asks the same
    question. Lookup grants and rendered text may differ, because each attempt
    takes the authority current when it was prepared. *)
