(** Board_curation — AI curation readonly surface for the board.

    Implements the board AI curation contract described in the
    board-ai-curation-readonly PR split.  Provides:

    - A typed curation snapshot: AI-produced ordering, highlighted
      post IDs, overall rationale, and operator-auditable provenance.
    - In-memory singleton store of the latest snapshot (single-writer;
      callers must serialise [submit_snapshot] if needed).
    - JSON projection used by the HTTP read endpoint.
    - Test-only [reset_for_test] for isolation.

    Design properties:
    - Read-only surface: no board posts are mutated.
    - Operator-auditable: [provenance] is a free-form JSON blob that
      callers populate with model name, parameters, run metadata etc.
    - Crypto IDs: snapshot IDs carry a ["cu-"] prefix and are
      generated via {!Mirage_crypto_rng}.
    - No persistent storage in this module: snapshots are ephemeral
      in-process.  Callers that need durable history should persist
      the JSON blob returned by {!snapshot_to_yojson}.

    @since board-ai-curation-readonly *)

(** {1 Types} *)

type curation_snapshot = {
  id : string;
  (** Cryptographic ID, prefix ["cu-"]. *)
  generated_at : float;
  (** Unix timestamp of when the curation was produced. *)
  submitted_by : string;
  (** Agent or keeper name that submitted the snapshot. *)
  model : string option;
  (** AI model used to produce the curation, if known. *)
  ordering : string list;
  (** Post IDs in AI-suggested reading order (most relevant first). *)
  highlights : string list;
  (** Subset of [ordering] marked as especially noteworthy. *)
  rationale : string;
  (** Human-readable explanation of the curation decisions. *)
  provenance : Yojson.Safe.t;
  (** Operator-auditable provenance blob (model params, run metadata,
      etc.).  Opaque to this module; callers control the schema. *)
}

(** {1 ID generation} *)

val generate_id : unit -> string
(** [generate_id ()] creates a fresh cryptographic snapshot ID with
    prefix ["cu-"].  Requires {!Mirage_crypto_rng} to be seeded. *)

(** {1 JSON serialisation} *)

val snapshot_to_yojson : curation_snapshot -> Yojson.Safe.t
(** Wire encoder.  Emits all fields; [model] is ["null"] when absent;
    [provenance] is inlined as-is. *)

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
