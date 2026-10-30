(** Board_curation — AI curation projection surface for the board.

    Implements the board AI curation contract described in the
    board AI curation PR split.  Provides:

    - A typed curation snapshot: AI-produced summary, ordering,
      highlighted post IDs, tag suggestions, question/answer matches,
      health score, overall rationale, and operator-auditable provenance.
    - In-memory singleton store of the latest snapshot (single-writer;
      callers must serialise [submit_snapshot] if needed).
    - JSON projection used by the HTTP read endpoint.
    - Test-only [reset_for_test] for isolation.

    Design properties:
    - Projection-only surface: snapshots may be submitted, but board posts,
      comments, and votes are not mutated.
    - Operator-auditable: [provenance] is a free-form JSON blob that
      callers populate with source window, run metadata etc.
    - Crypto IDs: snapshot IDs carry a ["cu-"] prefix and are
      generated via {!Mirage_crypto_rng}.
    - No persistent storage in this module: snapshots are ephemeral
      in-process.  Callers that need durable history should persist
      the JSON blob returned by {!snapshot_to_yojson}.

    @since board-ai-curation *)

(** {1 Types} *)

type curation_snapshot = {
  id : string;
  (** Cryptographic ID, prefix ["cu-"]. *)
  generated_at : float;
  (** Unix timestamp of when the curation was produced. *)
  submitted_by : string;
  (** Agent identifier that submitted the snapshot. *)
  summary : string option;
  (** Optional TL;DR summary of the current board window. *)
  ordering : string list;
  (** Post IDs in AI-suggested reading order (most relevant first). *)
  highlights : string list;
  (** Subset of [ordering] marked as especially noteworthy. *)
  tag_suggestions : curation_tag_suggestion list;
  (** Suggested tags by post. *)
  answer_matches : curation_answer_match list;
  (** Candidate question/answer matches. *)
  rationale : string;
  (** Human-readable explanation of the curation decisions. *)
  provenance : Yojson.Safe.t;
  (** Operator-auditable provenance blob.  Opaque to this module;
      callers control the schema. *)
}

and curation_tag_suggestion = {
  post_id : string;
  tags : string list;
  rationale : string;
}

and curation_answer_match = {
  question_post_id : string;
  answer_post_id : string;
  score : float;
  rationale : string;
}

(** {1 ID generation} *)

val generate_id : unit -> string
(** [generate_id ()] creates a fresh cryptographic snapshot ID with
    prefix ["cu-"].  Requires {!Mirage_crypto_rng} to be seeded. *)

(** {1 JSON serialisation} *)

val snapshot_to_yojson : curation_snapshot -> Yojson.Safe.t
(** Wire encoder.  Emits all fields; [provenance] is inlined as-is. *)

(** {1 In-memory store} *)

val submit_snapshot : curation_snapshot -> unit
(** Replace the current latest snapshot.  Not thread-safe — callers
    must serialise concurrent writes. *)

val latest_snapshot : unit -> curation_snapshot option
(** Return the most recently submitted snapshot, or [None] if no
    snapshot has been submitted yet. *)

(** {2 Test helpers} *)

(** (**/**)  Hidden from rendered docs — white-box test helpers only. *)

val reset_for_test : unit -> unit
(** Drop the in-memory snapshot.  Safe to call only before concurrent
    fibers exist. *)
