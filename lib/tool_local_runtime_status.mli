
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

type runtime_status_read_error =
  | Runtime_model_fetch_error of
      { base_url : string
      ; endpoint : string
      ; message : string
      }
  | Runtime_process_discovery_error of string

type runtime_status_with_errors =
  { status_json : Yojson.Safe.t
  ; read_errors : runtime_status_read_error list
  }

val runtime_status_read_error_to_string : runtime_status_read_error -> string
val runtime_status_read_error_to_yojson : runtime_status_read_error -> Yojson.Safe.t

val runtime_status_json_with_errors :
  ?include_models:bool -> unit -> runtime_status_with_errors
(** Result-aware variant of {!runtime_status_json}. The legacy JSON function
    still returns a JSON object, but this API preserves model-fetch and process
    discovery diagnostics for callers that must not infer "empty runtime data"
    from failed probes. *)

module For_testing : sig
  val with_dependencies :
    fetch_models_at:(string -> (string * string list, string) result)
    -> discover_processes:
         (unit -> (Tool_local_runtime_core.llama_process list, string) result)
    -> (unit -> 'a)
    -> 'a
end
