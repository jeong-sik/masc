(** Artifact_store — MASC CDAL artifact storage backend.

    Stores evaluator results, intervention summaries, and acceptance
    verdicts with stable metadata. Compatible with OAS Proof_store
    namespace for cross-system artifact joins.

    URI scheme: [masc-artifact://{session_id}/{artifact_type}/{artifact_id}]
    Filesystem layout: [{base_dir}/cdal/{artifact_type}/{artifact_id}.json] *)

type artifact_kind =
  | Evaluator_result
  | Intervention_summary
  | Acceptance_verdict
  | Evidence_bundle

type artifact_metadata = {
  artifact_id : string;
  kind : artifact_kind;
  producer : string;
  schema_version : string;
  created_at_iso : string;
  owner : string;
  session_id : string;
}

type config = {
  base_dir : string;
}

val default_config : session_id:string -> config
(** Default config using session artifacts_dir convention. *)

val init : config -> unit
(** Create directory structure for the artifact store. *)

val write : config -> metadata:artifact_metadata -> payload:Yojson.Safe.t -> unit
(** Write an artifact with metadata envelope. *)

val read : config -> kind:artifact_kind -> artifact_id:string ->
  (artifact_metadata * Yojson.Safe.t, string) result
(** Read an artifact by kind and id. Returns metadata + payload. *)

val list_artifacts : config -> kind:artifact_kind -> artifact_metadata list
(** List all artifacts of a given kind. *)

val make_ref : session_id:string -> kind:artifact_kind -> artifact_id:string -> string
(** Construct a [masc-artifact://] URI reference. *)

val kind_to_string : artifact_kind -> string
val kind_of_string : string -> (artifact_kind, string) result

val metadata_to_yojson : artifact_metadata -> Yojson.Safe.t
val metadata_of_yojson : Yojson.Safe.t -> (artifact_metadata, string) result
