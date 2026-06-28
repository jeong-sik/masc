val dashboard_runtime_probe_http_json : ?force:bool -> unit -> Yojson.Safe.t
val dashboard_runtime_probe_payload_json_of_runtimes : ?default_id:string -> Runtime.t list -> Yojson.Safe.t
val dashboard_runtime_probe_payload_json_for_tests : ?default_id:string -> Runtime.t list -> Yojson.Safe.t

val set_dashboard_runtime_probe_runner_for_tests : (unit -> Yojson.Safe.t) -> unit
val clear_dashboard_runtime_probe_runner_for_tests : unit -> unit

val set_dashboard_runtime_provider_http_get_for_tests :
  (url:string ->
   headers:(string * string) list ->
   timeout_sec:float ->
   (int * (string * string) list * string, string) result) ->
  unit
val clear_dashboard_runtime_provider_http_get_for_tests : unit -> unit

val clear_dashboard_runtime_probe_cache_for_tests : unit -> unit
val set_dashboard_runtime_probe_cache_for_tests : probe:Yojson.Safe.t -> age_sec:float -> unit -> unit

val maybe_fork_dashboard_runtime_probe_refresh : unit -> unit

val dashboard_runtime_probe_failure_envelope_of_exn : exn -> Yojson.Safe.t

val runtime_inventory_source : string
