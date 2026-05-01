open Base

(** Tool_local_runtime_status — Runtime pool status reporting.

    Aggregates configured runtime snapshots, healthy counts, matching
    processes, and optional model inventory into a single dashboard
    payload. *)

(** [runtime_status_json ?include_models ()] returns a JSON object
    summarising the local llama runtime pool. When [include_models]
    is [true] (default) each runtime fetches its model list and the
    aggregate [models] field is populated. Observations include
    warnings about misconfigured capacity, missing processes, or
    runtime parse errors. *)
val runtime_status_json : ?include_models:bool -> unit -> Yojson.Safe.t
