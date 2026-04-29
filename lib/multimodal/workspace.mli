(** Workspace — multimodal artifact registry + gallery.

    Cycle 24-25 / Tier A7 (first half).

    {1 What this module is}

    A persistent registry binding {!Artifact_id.t} → {!Artifact.any},
    bundled with a {!Multimodal_hydrator.provenance_dag} and
    queryable views (timeline by creation time, filter by kind,
    metadata-key search). The runtime backbone of the
    "workspace gallery" surface; the dashboard
    `/api/v1/artifacts/*` route in the A7 second-half PR
    consumes this registry without modifying it.

    {1 Persistence semantics}

    Workspace values are immutable — every mutation
    ({!add}, {!add_edge}, {!remove}) returns a new value with
    the same id-key contract. Callers that need a long-lived
    workspace store the value behind a ref or atomic.

    {1 Why not just use a [Hashtbl]?}

    The dashboard route + tests need a deterministic snapshot.
    A [Hashtbl] surfaces insertion-order or hash-derived
    iteration order across OCaml versions; the immutable
    record here uses an association list keyed on
    {!Artifact_id.t} (UUID v7 is monotonic) so {!timeline}
    returns the same order regardless of host.

    @stability Evolving
    @since 0.18.10 *)

(** {1 Workspace value} *)

type t

val empty : t
(** A workspace with zero artifacts and an empty
    {!Multimodal_hydrator.provenance_dag}. *)

(** {1 Mutators (return new value)} *)

val add : t -> Artifact.any -> t
(** [add ws artifact] inserts (or replaces) the artifact
    keyed by its id. *)

val add_edge :
  t ->
  from_id:Shared_types.Artifact_id.t ->
  to_id:Shared_types.Artifact_id.t ->
  t
(** Append a provenance edge to the workspace's DAG. Both
    endpoints must already be present — [add_edge] is a
    no-op (returns the workspace unchanged) when either is
    missing, mirroring the
    {!Multimodal_hydrator.add_edge} dedupe semantics. *)

val remove : t -> Shared_types.Artifact_id.t -> t
(** [remove ws id] drops the artifact at [id] (no-op if
    absent). DAG edges referencing the dropped id are
    {b not} pruned — Tier A10 may add a verification helper
    that flags orphan edges. *)

(** {1 Queries} *)

val find_by_id :
  t -> Shared_types.Artifact_id.t -> Artifact.any option

val all : t -> Artifact.any list
(** All artifacts in id order (UUID v7 ⇒ creation-time
    monotonic). *)

val size : t -> int

val list_by_kind_tag :
  t -> Artifact.kind_tag -> Artifact.any list
(** Artifacts whose kind matches the supplied tag. *)

val timeline : t -> Artifact.any list
(** Artifacts sorted by [provenance.created_at] ascending. *)

val search_metadata_key : t -> string -> Artifact.any list
(** Artifacts whose [metadata] is an [`Assoc] containing the
    given key. *)

val provenance_dag : t -> Multimodal_hydrator.provenance_dag
(** Direct access to the DAG (for use with
    {!Multimodal_hydrator.hydrate}). *)

val origins_of :
  t ->
  Shared_types.Artifact_id.t ->
  Shared_types.Artifact_id.t list

val descendants_of :
  t ->
  Shared_types.Artifact_id.t ->
  Shared_types.Artifact_id.t list

(** {1 JSON} *)

val to_json : t -> Yojson.Safe.t
(** Encodes the registry as
    [\{ "artifacts": [ ... ], "dag": {...} \}]. *)
