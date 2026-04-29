(** Provenance_stub — minimal artifact provenance record.

    Cycle 24 / Tier B8.

    Stub form: a flat record carrying the originating artifact ids,
    the producer name, and the creation timestamp. The follow-up
    Tier B9 (Multimodal_hydrator) will extend this into a Provenance
    DAG capturing transformation lineage between artifacts.

    Stored on every {!Artifact.t}. The stub is sufficient for B8's
    JSON round-trip, downstream filtering, and timeline rendering;
    the DAG arrives in B9 without renaming the existing fields.

    @stability Evolving
    @since 0.18.10 *)

type t = {
  origin_artifact_ids : Shared_types.Artifact_id.t list;
  created_by : string;
  created_at : float;
}

val empty : created_by:string -> created_at:float -> t
(** [empty ~created_by ~created_at] constructs a provenance with no
    origin artifacts. Useful when an artifact is the start of a new
    creation chain (no predecessors). *)

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
