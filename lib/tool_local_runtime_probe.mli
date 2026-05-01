open Base

(** Tool_local_runtime_probe — Native Ollama timing and warm-state
    diagnostics.

    Probes [/api/ps] (loaded-model snapshot) + [/api/generate]
    (one-shot timing run) and folds results into a JSON KV-cache
    assessment.  Used by the dashboard runtime panel and CI
    health checks.

    The .ml does [include Tool_local_runtime_http] for internal
    access to HTTP helpers ([http_post_json_text_with_status],
    [trim_to_option], etc.).  The .mli intentionally does NOT
    mirror the cascade — those helpers are implementation
    detail; probe is the contract layer.

    Internal: ~22 helpers stay private — \[bool_opt_to_json] /
    \[clamp] / \[trim_to_option] / \[ns_to_ms] / \[tok_per_second] /
    \[collapse_preview] / \[truncate_text] / \[default_ps_timeout_sec] /
    \[generate_probe_skip_reason_to_string] / \[string_or_fallback] /
    \[loaded_model_name] / \[ollama_loaded_model_to_yojson] /
    \[ollama_probe_run_to_yojson] / \[default_probe_prompt] /
    \[fetch_ollama_ps] / \[select_effective_model] /
    \[failed_probe_run] / \[run_single_probe] /
    \[prompt_eval_duration_ms_of_run_json] /
    \[generate_probe_skip_reason] type + the
    [include Tool_local_runtime_http] cascade.  All consumed
    only inside {!runtime_ollama_probe_json}'s pipeline. *)

(** {1 Snapshot types} *)

type ollama_loaded_model = {
  name : string option;
  model : string option;
  size_vram_bytes : int option;
  context_length : int option;
  expires_at : string option;
}
(** Per-model row from [/api/ps].  Returned by
    {!ollama_loaded_models_of_ps_json}. *)

type ollama_probe_run = {
  run_index : int;
  http_status : int option;
  wall_clock_ms : int;
  total_duration_ms : float option;
  load_duration_ms : float option;
  prompt_eval_count : int option;
  prompt_eval_duration_ms : float option;
  prompt_tokens_per_second : float option;
  eval_count : int option;
  eval_duration_ms : float option;
  generation_tokens_per_second : float option;
  done_flag : bool option;
  done_reason : string option;
  thinking_present : bool;
  response_preview : string option;
  response_chars : int option;
  error : string option;
}
(** Single timing run from [/api/generate].  Returned by
    {!ollama_probe_run_of_generate_json}. *)

(** {1 Think-mode + decision variants} *)

(** Three-state think-mode selector.  [Think_auto] defers to
    Ollama's default. *)
type ollama_probe_think_mode =
  | Think_auto
  | Think_disabled
  | Think_enabled

(** Reason a generate-phase probe was skipped.  Pinned variant
    set — drift breaks operator dashboard tooltips. *)
type generate_probe_skip_reason =
  | No_effective_model
  | Status_only
  | Ps_preflight_error
  | Model_unloaded
  | Policy_skip

(** Generate-phase probe decision tree output.  Constructed by
    {!decide_generate_probe}; rendered to a string by
    {!generate_probe_decision_to_string}. *)
type generate_probe_decision =
  | Run_generate_probe
  | Skip_generate_probe of generate_probe_skip_reason

(** {1 Constants} *)

val default_probe_timeout_sec : int
(** [6].  Pinned upper bound for the [/api/generate] timeout in
    seconds.  Drift would change CI-vs-cold-start tradeoff. *)

(** {1 URL helpers} *)

val normalize_ollama_server_url : string -> string
(** [normalize_ollama_server_url raw] trims whitespace and
    strips trailing slashes.  Pure — used for path concatenation
    by {!ollama_ps_url} / {!ollama_generate_url}. *)

val ollama_ps_url : string -> string
(** [ollama_ps_url server_url] is
    [normalize_ollama_server_url server_url ^
    Masc_network_defaults.ollama_api_ps_path]. *)

val ollama_generate_url : string -> string
(** [ollama_generate_url server_url] is
    [normalize_ollama_server_url server_url ^
    Masc_network_defaults.ollama_api_generate_path]. *)

val ollama_http_error : string -> int option -> string
(** [ollama_http_error operation http_status] returns a pinned
    error message string ["ollama <op> returned http <code>"]
    or ["ollama <op> returned http unknown"] when status is
    [None].  Operator-visible — drift breaks log-grep patterns. *)

(** {1 Think mode parsing} *)

val ollama_probe_think_mode_to_string :
  ollama_probe_think_mode -> string
(** Canonical labels: ["auto"] / ["disabled"] / ["enabled"]. *)

val ollama_probe_think_mode_of_string :
  string -> ollama_probe_think_mode option
(** Permissive parser:

    - ["auto"] -> [Think_auto]
    - ["false"] / ["disabled"] / ["off"] / ["no"] -> [Think_disabled]
    - ["true"] / ["enabled"] / ["on"] / ["yes"] -> [Think_enabled]
    - anything else -> [None]

    Case-insensitive.  Pinned alias set — env-var input parsing
    depends on these synonyms. *)

val effective_think_enabled : ollama_probe_think_mode -> bool
(** [Think_enabled -> true], [Think_auto] / [Think_disabled ->
    false].  [Think_auto] is conservatively treated as
    "thinking off" for the boolean projection — Ollama itself
    decides at the protocol level. *)

(** {1 Generate-probe decision} *)

val generate_probe_decision_to_string :
  generate_probe_decision -> string
(** [Run_generate_probe -> "run_generate"];
    [Skip_generate_probe r -> generate_probe_skip_reason_to_string r]
    where the reasons map to ["no_effective_model"] /
    ["status_only"] / ["ps_error"] / ["model_unloaded"] /
    ["policy_skip"].  Pinned literal set — operator dashboards
    parse these. *)

val decide_generate_probe :
  effective_model:string option ->
  before_status:int option ->
  before_error:string option ->
  run_generate:bool ->
  generate_when_unloaded:bool ->
  effective_model_loaded_before:bool ->
  generate_probe_decision
(** Decision tree (top-down):

    + [None effective_model -> Skip No_effective_model]
    + [run_generate = false -> Skip Status_only]
    + [Some before_error -> Skip Ps_preflight_error]
    + [before_status = 200] AND model loaded OR
      [generate_when_unloaded] -> [Run_generate_probe]
    + [before_status = 200] AND not loaded -> [Skip Model_unloaded]
    + Else with model loaded OR [generate_when_unloaded] ->
      [Run_generate_probe]
    + Else -> [Skip Policy_skip]

    Order matters — pinned at contract seam. *)

val should_attempt_generate_probe :
  before_status:int option ->
  before_error:string option ->
  run_generate:bool ->
  generate_when_unloaded:bool ->
  effective_model_loaded_before:bool ->
  bool
(** Boolean projection of {!decide_generate_probe} with a
    sentinel [effective_model] of
    ["__probe_decision_compat__"] — used by callers that only
    need the run/skip bit and have already validated the model. *)

(** {1 JSON parsers} *)

val ollama_loaded_models_of_ps_json :
  Yojson.Safe.t -> [> `Assoc of (string * Yojson.Safe.t) list ] list
(** Parses the [models] array from a [/api/ps] response.  Each
    element is extracted into an internal {!ollama_loaded_model}
    record then re-serialized as a JSON [`Assoc] via the
    internal [ollama_loaded_model_to_yojson] encoder.  Returns
    an empty list when [models] is missing or malformed —
    fail-open by design.

    Return type is the open polymorphic variant
    [`Assoc of (string * Yojson.Safe.t) list] (not full
    [Yojson.Safe.t]) because the implementation is statically
    known to produce only [`Assoc] elements; the tighter type
    matches the {!Tool_local_runtime} re-export and lets
    callers skip the [`Assoc _ -> ...] match arm. *)

val ollama_probe_run_of_generate_json :
  run_index:int ->
  http_status:int option ->
  wall_clock_ms:int ->
  Yojson.Safe.t ->
  ollama_probe_run
(** Parses an [/api/generate] response into an
    {!ollama_probe_run} record.  Time fields converted from
    nanoseconds to milliseconds via internal [ns_to_ms] helper.
    Always returns a record — missing fields become [None]. *)

(** {1 Request body builder} *)

val request_body_json :
  think_enabled:bool ->
  keep_alive:string option ->
  model_id:string ->
  prompt:string ->
  max_tokens:int ->
  string
(** Serializes a [/api/generate] request body to a JSON string.
    Pinned fields: [model], [prompt], [stream=false], [think],
    optional [keep_alive] (when non-empty), and [options] with
    [temperature=0.0] + [num_predict=max_tokens].  Drift would
    change probe determinism. *)

(** {1 Aggregation} *)

val kv_cache_assessment_json :
  Yojson.Safe.t list -> Yojson.Safe.t
(** [kv_cache_assessment_json run_jsons] aggregates per-run JSON
    snapshots into a KV-cache effectiveness summary by examining
    [prompt_eval_duration_ms] across runs.  Fast subsequent
    runs indicate cached prompts; large variance indicates
    cache misses. *)

(** {1 Top-level probe} *)

val runtime_ollama_probe_json :
  ?server_url:string ->
  ?model:string ->
  ?prompt:string ->
  ?probe_runs:int ->
  ?keep_alive:string ->
  ?max_tokens:int ->
  ?think_mode:ollama_probe_think_mode ->
  ?timeout_sec:int ->
  ?ps_timeout_sec:int ->
  ?generate_when_unloaded:bool ->
  ?run_generate:bool ->
  unit ->
  Yojson.Safe.t
(** Top-level probe orchestrator.  Defaults: [probe_runs=2]
    (clamped to [\[1, 4]]), [max_tokens=16] (clamped to
    [\[1, 128]]), [think_mode=Think_auto],
    [timeout_sec=default_probe_timeout_sec] (clamped to
    [\[3, 300]]), [ps_timeout_sec=default_ps_timeout_sec]
    (clamped to [\[1, 30]]), [generate_when_unloaded=true],
    [run_generate=true].  Returns a JSON snapshot with
    [/api/ps] state + per-run timing + KV-cache assessment. *)
