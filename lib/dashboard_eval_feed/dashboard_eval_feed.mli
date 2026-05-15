(** Dashboard_eval_feed — read-only consumer for OAS eval verdicts.

    Parses swiss-verdict JSON (RFC-OAS-002 schema v1) produced by the OAS
    harness and exposes eval snapshots for dashboard rendering.

    This module only reads.  It never writes or modifies eval data.
    Data ownership belongs to OAS ({!Agent_sdk.Harness}). *)

type layer_result_json = {
  layer_name : string;
  passed : bool;
  score : float option;
  evidence : string list;
  detail : string option;
}

type swiss_verdict_json = {
  schema_version : int;
  all_passed : bool;
  coverage : float;
  layer_results : layer_result_json list;
}

type eval_snapshot = {
  agent_name : string;
  session_id : string option;
  worker_run_id : string;
  timestamp : float;
  verdict : swiss_verdict_json;
  baseline_status : string option;
      (** ["Improved"] | ["Regressed"] | ["Unchanged"] *)
}

val read_verdict_json : Yojson.Safe.t -> (swiss_verdict_json, string) result
(** Parse a swiss-verdict JSON value conforming to RFC-OAS-002 schema v1.
    Returns [Error] if [schema_version] is not [1] or required fields are
    missing. *)

val list_agents : base_path:string -> string list
(** Return sorted agent names that have eval data under
    [<base_path>/.oas/eval/].  Returns an empty list when the
    directory does not exist.  Never raises. *)

val read_latest :
  base_path:string -> agent_name:string -> limit:int -> eval_snapshot list
(** Read the most recent [limit] eval snapshots for [agent_name].

    File path convention: [<base_path>/.oas/eval/<agent_name>/*.json].
    Each JSON file is expected to contain an eval envelope with a
    [verdict] field conforming to the swiss-verdict schema.

    Returns an empty list when the directory does not exist or contains
    no parseable files.  Never raises. *)

val snapshot_to_json : eval_snapshot -> Yojson.Safe.t
(** Serialize an eval snapshot to JSON for HTTP responses. *)

val verdict_to_json : swiss_verdict_json -> Yojson.Safe.t
(** Serialize a swiss verdict to JSON. *)
