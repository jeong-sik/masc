open Base

(** Tool_local_runtime — local model runtime management and
    benchmarking tools.

    Facade module that re-exports sub-modules and provides MCP
    dispatch / schemas.  Implementation split across:

    - {!Tool_local_runtime_core}: types, helpers, process discovery,
      model fetching.
    - {!Tool_local_runtime_http}: HTTP helpers (curl wrappers, JSON
      member access).
    - {!Tool_local_runtime_verify}: runtime contract verification.
    - {!Tool_local_runtime_bench}: concurrency benchmark.
    - {!Tool_local_runtime_status}: runtime pool status reporting.
    - {!Tool_local_runtime_probe}: native Ollama timing / KV
      inference probe.

    {b Include cascade:} starts with
    [include Tool_local_runtime_core], so callers reaching this
    module get the core types ([config] / [tool_result] / etc.) for
    free.

    Internal: 5 [handle_*] functions ([handle_models],
    [handle_runtime_status], [handle_runtime_verify],
    [handle_runtime_bench], [handle_runtime_ollama_probe]) plus
    the [Tool_spec.register] side-effect block stay private.  The
    .mli pins the dispatch / schemas contract — handler bodies are
    free to refactor. *)

include module type of struct
  include Tool_local_runtime_core
end

(** {1 Status / verify / probe / bench re-exports} *)

val runtime_status_json :
  ?include_models:bool -> unit -> Yojson.Safe.t
(** Re-export of {!Tool_local_runtime_status.runtime_status_json}. *)

val runtime_verify_json :
  ?runtime_pool:string ->
  ?expected_slots:int ->
  ?expected_ctx:int ->
  ?expected_model:string ->
  unit ->
  Yojson.Safe.t
(** Re-export of {!Tool_local_runtime_verify.runtime_verify_json}. *)

val runtime_ollama_probe_json :
  ?server_url:string ->
  ?model:string ->
  ?prompt:string ->
  ?probe_runs:int ->
  ?keep_alive:string ->
  ?max_tokens:int ->
  ?think_mode:Tool_local_runtime_probe.ollama_probe_think_mode ->
  ?timeout_sec:int ->
  ?ps_timeout_sec:int ->
  ?generate_when_unloaded:bool ->
  ?run_generate:bool ->
  unit ->
  Yojson.Safe.t
(** Re-export of {!Tool_local_runtime_probe.runtime_ollama_probe_json}.
    All parameters are optional with defaults: [probe_runs = 2],
    [max_tokens = 16], [think_mode = Think_auto],
    [timeout_sec = default_probe_timeout_sec],
    [ps_timeout_sec = default_ps_timeout_sec],
    [generate_when_unloaded = true], [run_generate = true]. *)

val run_bench :
  ?model_id:string ->
  ?runtime_pool:string ->
  parallelism:int ->
  rounds:int ->
  prompt:string ->
  max_tokens:int ->
  timeout_sec:int ->
  unit ->
  (Yojson.Safe.t, string) Result.t
(** Re-export of {!Tool_local_runtime_bench.run_bench}. *)

val provider_health_reachable :
  status:int option -> body:string option -> bool
(** Re-export of {!Tool_local_runtime_verify.provider_health_reachable}.
    [body] is unused; required for caller-shape compat. *)

val classify_runtime_blocker :
  provider_reachable:bool ->
  slot_reachable:bool ->
  chat_contract_status:string ->
  expected_model:string option ->
  actual_model_id:string option ->
  expected_slots:int option ->
  actual_slots_total:int ->
  expected_ctx:int option ->
  actual_ctx:int option ->
  chat_completion_compatible:bool ->
  string option * string option
(** Re-export of {!Tool_local_runtime_verify.classify_runtime_blocker}.
    Returns [(blocker_code, blocker_detail)] — both [None] when no
    blocker.  Blocker codes: [provider_unreachable] /
    [provider_model_mismatch] / [slot_count_insufficient] /
    [ctx_mismatch] / [chat_contract_incompatible]. *)

val ollama_loaded_models_of_ps_json :
  Yojson.Safe.t -> [> `Assoc of (string * Yojson.Safe.t) list ] list
(** Re-export of
    {!Tool_local_runtime_probe.ollama_loaded_models_of_ps_json}. *)

val ollama_probe_run_of_generate_json :
  run_index:int ->
  http_status:int option ->
  wall_clock_ms:int ->
  Yojson.Safe.t ->
  Tool_local_runtime_probe.ollama_probe_run
(** Re-export of
    {!Tool_local_runtime_probe.ollama_probe_run_of_generate_json}. *)

val kv_cache_assessment_json : Yojson.Safe.t list -> Yojson.Safe.t
(** Re-export of
    {!Tool_local_runtime_probe.kv_cache_assessment_json}. *)

(** {1 MCP dispatch contract} *)

val dispatch :
  'ctx ->
  name:string ->
  args:Yojson.Safe.t ->
  tool_result option
(** [dispatch ctx ~name ~args] dispatches the named MCP tool call.

    Recognised names:
    - [masc_runtime_verify] -> {!runtime_verify_json}
    - [masc_runtime_ollama_probe] -> {!runtime_ollama_probe_json}

    Returns [None] for unrecognised names so the caller can fall
    through to other dispatchers. *)

val schemas : Types.tool_schema list
(** Two schemas pinned at the contract seam:
    [masc_runtime_verify] (4 optional properties: [runtime_pool],
    [expected_model], [expected_slots], [expected_ctx]) and
    [masc_runtime_ollama_probe] (9 optional properties).  Adding a
    new tool requires extending both this list and {!dispatch}. *)

val tool_required_permission : string -> Types.permission option
(** [tool_required_permission name] returns
    [Some Types.CanReadState] for both [masc_runtime_verify] and
    [masc_runtime_ollama_probe], else [None].  Consumed during
    {!Tool_spec.register} setup at module init. *)
