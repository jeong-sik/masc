(** Chronicle vector index — Master Report Dim02 P1 vector embedder
    (RFC-0035 PR-9).

    In-memory cosine-similarity index over {!Chronicle_event} entries
    paired with caller-supplied embedding vectors. The Master Report
    Librarian Agent (§2.4) describes a "vector + keyword hybrid
    retriever". {!Chronicle_librarian} (PR-5) covers the keyword side
    with {!Cognitive_gravity}'s ranker; this module covers the vector
    side with cosine similarity over plain [float array] embeddings.

    Boundary discipline:

    - This module owns the in-memory store, dimension consistency
      check, cosine math, and top-k retrieval.
    - Embedding production is the caller's responsibility — host
      systems plug in BGE-M3 / Supabase pgvector / OpenAI embeddings
      via their own adapters. The lib accepts any [float array] and
      checks only dimensionality consistency, not provenance.

    Pure OCaml: no Eio, no I/O, no global state. Vectors are
    immutable [float array] copies on insert (call sites can mutate
    after [add] without affecting the index).

    @stability Evolving
    @since 0.19.19 *)

(** A dense embedding vector. Length must match the index's
    dimensionality after the first {!add}. *)
type vector = float array

(** A chronicle event paired with its embedding. *)
type entry = {
  event : Chronicle_event.t;
  embedding : vector;
}

(** Opaque vector index. Maintains insertion order; ties under
    cosine similarity break by insertion order (stable sort). *)
type index

(** [empty ?dim ()] returns an empty index. If [dim] is [None],
    the dimensionality is inferred from the first {!add} call.
    If [dim] is [Some n], every {!add} must supply an embedding of
    exactly length [n]. *)
val empty : ?dim:int -> unit -> index

(** Number of entries in the index. *)
val len : index -> int

(** Dimensionality of the index after at least one entry was added,
    or the explicit [dim] passed to {!empty}. Returns [None] for an
    empty index that was created without an explicit [dim]. *)
val dim : index -> int option

(** [add idx entry] appends [entry] and returns the new index. The
    embedding's length must match the index's dimensionality (if
    already set) or define it (if not). Returns [Error msg] on
    dimension mismatch. *)
val add : index -> entry -> (index, string) result

(** [add_event idx event embedding] is a convenience that constructs
    the {!entry} value internally. *)
val add_event :
  index -> Chronicle_event.t -> vector -> (index, string) result

(** All entries in insertion order. *)
val to_list : index -> entry list

(** {1 Vector math} *)

(** Cosine similarity in the closed interval [-1.0, 1.0]. Returns
    [0.0] when either vector has zero magnitude. *)
val cosine_similarity : vector -> vector -> float

(** [normalize v] returns a new vector with unit L2 norm. Returns a
    zero vector unchanged. *)
val normalize : vector -> vector

(** {1 Retrieval} *)

(** [search idx ~query ?limit ()] ranks every entry in [idx] by
    cosine similarity to [query] and returns the top [limit] paired
    with their similarity scores. When [limit] is absent, returns
    the full ranking.

    The query vector's length must match the index's dimensionality;
    [Error] is raised via [invalid_arg] otherwise so call sites
    catch dimension mismatch deterministically. *)
val search :
  index ->
  query:vector ->
  ?limit:int ->
  unit ->
  (Chronicle_event.t * float) list
