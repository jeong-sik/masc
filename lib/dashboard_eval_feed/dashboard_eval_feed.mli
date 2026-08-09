(** Dashboard_eval_feed — read-only consumer for AGENT_CORE eval verdicts.

    Parses swiss-verdict JSON (Agent Core contract schema v1) produced by the AGENT_CORE
    harness and exposes eval snapshots for dashboard rendering.

    This module only reads.  It never writes or modifies eval data.
    Data ownership belongs to AGENT_CORE ({!Agent_core.Harness}). *)

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
(** Parse a swiss-verdict JSON value conforming to Agent Core contract schema v1.
    Returns [Error] if [schema_version] is not [1] or required fields are
    missing. *)

val list_agents : base_path:string -> string list
(** Return sorted agent names that have eval data under
    [<base_path>/.agent_core/eval/].  Returns an empty list when the
    directory does not exist.  Missing eval data is a normal fresh-boot
    state and does not log a warning.  Never raises. *)

val read_latest :
  base_path:string -> agent_name:string -> limit:int -> eval_snapshot list
(** Read the most recent [limit] eval snapshots for [agent_name].

    File path convention: [<base_path>/.agent_core/eval/<agent_name>/*.json].
    Each JSON file is expected to contain an eval envelope with a
    [verdict] field conforming to the swiss-verdict schema.

    Returns an empty list when the directory does not exist or contains
    no parseable files.  Missing eval data is a normal fresh-boot state
    and does not log a warning.  Never raises. *)

val snapshot_to_json : eval_snapshot -> Yojson.Safe.t
(** Serialize an eval snapshot to JSON for HTTP responses. *)

val verdict_to_json : swiss_verdict_json -> Yojson.Safe.t
(** Serialize a swiss verdict to JSON. *)
