(** Keeper_memory_os_edges — the associative layer of the Memory OS
    (RFC-0246 §2.7). An [edge] is one observed association event between two
    facts, identified by their normalized claim keys
    ([Keeper_memory_os_types.normalize_claim]). Edges are append-only; the
    Hebbian strength of an association is the count of observed events, derived
    at read time by [aggregate].

    Only relations with a deterministic producer exist here. [Relates] is the
    co-occurrence relation: two claims extracted into the same episode are, by
    construction of the librarian's single-episode extraction, about the same
    stretch of work, so they are associated. Causal relations (a fact that
    diagnoses / derives / verifies another) have no deterministic producer in
    this system — labelling them would need an LLM classifier, which RFC-0246
    rejects — so they are deliberately absent until a producer for them exists. *)

(* Closed relation taxonomy. Grows one arm at a time, each arm landing WITH its
   producer; [Unknown] is the visible escape for a relation string read off disk
   that this build has no arm for (graceful-degrade, never a silent default). *)
type relation =
  | Relates
  | Unknown of string

val relation_of_string : string -> relation
val relation_to_string : relation -> string

(* One append-only association event. For the undirected [Relates], the producer
   emits endpoints in canonical order ([src] <= [dst]) so that the (A,B) and
   (B,A) observations fold to the same association. *)
type edge =
  { src : string
  ; dst : string
  ; relation : relation
  ; trace_id : string
  ; created_at : float
  ; schema_version : string
  }

val edge_to_json : edge -> Yojson.Safe.t
val edge_of_json : Yojson.Safe.t -> edge option

(* A read-time fold of edge events into per-(src, dst, relation) associations.
   [weight] is the number of observed co-occurrence events (Hebbian strength);
   [first_seen]/[last_seen] bracket them. *)
type association =
  { a_src : string
  ; a_dst : string
  ; a_relation : relation
  ; weight : int
  ; first_seen : float
  ; last_seen : float
  }

(* Deterministic co-occurrence producer: every unordered pair of distinct claim
   keys within [episode] yields one [Relates] edge, in canonical endpoint order.
   An episode with [n] distinct claim keys emits exactly [n*(n-1)/2] edges; a
   self-pair and within-episode duplicate pairs cannot occur because keys are
   deduplicated first. The episode's own [trace_id]/[created_at] are the edge
   provenance. *)
val co_occurrence_edges : Keeper_memory_os_types.episode -> edge list

(* Fold append-only edge events into associations, sorted deterministically by
   (src, dst, relation). *)
val aggregate : edge list -> association list

(* One-step spreading activation (RFC-0246 §2.7, P2a-2). Given each recalled
   fact's [base] score keyed by claim key, and the [associations] among facts,
   return an additive boost per key: [alpha] times the association-weighted
   average of the base scores of that key's neighbours that are themselves in
   [base]. A key with no in-[base] neighbour receives no entry. With [alpha] <= 0
   the result is empty (recall stays byte-identical). The boost is bounded by
   [alpha] * (max neighbour base score), so the relative order of strongly-scored
   facts is preserved while a low-lexical fact linked to recalled facts is lifted. *)
val activation_boosts
  :  alpha:float
  -> associations:association list
  -> base:(string * float) list
  -> (string * float) list
