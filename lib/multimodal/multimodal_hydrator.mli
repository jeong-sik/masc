(** Multimodal_hydrator — provenance DAG + callback-driven hydration.

    Cycle 24 / Tier B9.

    {1 What this module is}

    A non-invasive layer above {!Artifact.t} that adds:
    - a {!provenance_dag} value carrying [(from_id → to_id)]
      edges between artifacts, queryable both directions.
    - a {!hydrate} routine that, given a [fetch_artifact] callback
      and a list of artifact ids, produces a list of fully-loaded
      {!Artifact.any} values along with their provenance neighbours.

    {1 Why a callback (and not a direct keeper_artifact_hydrator wrap)}

    INTEGRATED §A3.2 forbids any modification of
    [lib/keeper/keeper_artifact_hydrator.\{mli,ml\}] — the existing
    consumers of that hydrator must continue working unchanged.
    A direct wrapper inside [lib/multimodal/] would require the
    multimodal sub-library to import the keeper sub-library, which
    in turn pulls in [autonomous] / [resilience] / the entire main
    library, producing a circular dependency.

    Instead this module accepts a [fetch_artifact] callback and
    leaves wiring to the caller. Tier A7 (which already lives at
    a level above both [keeper] and [multimodal]) supplies a
    [fetch_artifact] that delegates to [keeper_artifact_hydrator]
    on the keeper side, leaving the existing hydrator untouched.

    {1 Provenance DAG}

    The DAG is a flat edge list — no transitive closure cached;
    queries traverse on demand. Cycles are not enforced absent
    in {!add_edge} (the keeper does not produce cyclic provenance
    by construction); future tiers may add a runtime guard if
    serialised input is admitted.

    @stability Evolving
    @since 0.18.10 *)

(** {1 Provenance DAG} *)

(** [edges = (from_id, to_id)] meaning [to_id] was derived from
    [from_id]. *)
type provenance_dag

val empty_dag : provenance_dag

val add_edge :
  provenance_dag ->
  from_id:Shared_types.Artifact_id.t ->
  to_id:Shared_types.Artifact_id.t ->
  provenance_dag
(** Append an edge. Duplicates are deduped so the DAG carries at
    most one edge per [(from_id, to_id)] pair. *)

val edges : provenance_dag -> (Shared_types.Artifact_id.t * Shared_types.Artifact_id.t) list
(** Edges in insertion order, deduped. *)

val origins_of :
  provenance_dag ->
  Shared_types.Artifact_id.t ->
  Shared_types.Artifact_id.t list
(** [origins_of dag id] returns all [from_id] for edges
    [(from_id, id)]. Direct predecessors only — transitive
    ancestors require iteration. *)

val descendants_of :
  provenance_dag ->
  Shared_types.Artifact_id.t ->
  Shared_types.Artifact_id.t list
(** [descendants_of dag id] returns all [to_id] for edges
    [(id, to_id)]. Direct successors only. *)

val dag_to_json : provenance_dag -> Yojson.Safe.t

val dag_of_json : Yojson.Safe.t -> (provenance_dag, string) result

(** {1 Hydrated artifact} *)

(** An {!Artifact.any} bundled with its direct origins and
    descendants from the [provenance_dag] used for the lookup. *)
type hydrated = {
  artifact : Artifact.any;
  origins : Shared_types.Artifact_id.t list;
  descendants : Shared_types.Artifact_id.t list;
}

(** {1 Hydrate}

    Resolve an id list into hydrated artifacts via a caller-
    supplied [fetch_artifact] callback. Ids that the callback
    cannot resolve (returns [None]) are skipped silently — the
    output preserves order of the surviving entries. *)

val hydrate :
  fetch_artifact:(Shared_types.Artifact_id.t -> Artifact.any option) ->
  dag:provenance_dag ->
  ids:Shared_types.Artifact_id.t list ->
  hydrated list
