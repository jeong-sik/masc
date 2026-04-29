(** Worker_container — local-worker meta / checkpoint /
    tool-builder layer.

    Sits between {!Worker_container_types} (cycle 191) and
    {!Worker_container_runners} (which does
    [include Worker_container] + a top-level cascade-include
    in its .mli).  Type identity propagates end-to-end via
    [include module type of struct include M end]
    (cycle 187 rationale).

    External surface (15 entries — 11 dotted callers + 4
    additional helpers consumed unqualified by
    {!Worker_container_runners} through the cascade):
    - File paths: {!worker_container_dir},
      {!worker_raw_trace_path},
      {!ensure_worker_container_dirs}.
    - Meta JSON: {!load_worker_meta}, {!save_worker_meta},
      {!make_worker_meta}.
    - Checkpoint JSON: {!load_worker_checkpoint},
      {!save_worker_checkpoint}.
    - Session id: {!resolved_mcp_session_id},
      {!evidence_session_id_of_worker_run}.
    - Tool catalogue: {!session_min_tool_names}.
    - Tool builders: {!build_oas_mcp_tools},
      {!build_local_shell_tools}.
    - Provider: {!oas_provider_of_label},
      {!resolve_oas_provider_of_label}.
    - Audit + run helpers: {!append_worker_completion_log},
      {!build_resume_config}, {!materialize_direct_evidence}.

    Internal helpers stay private at this boundary
    ([worker_container_root], [safe_worker_token],
    [worker_meta_path], [worker_checkpoint_path],
    [worker_turn_log_path], [oas_tool_error],
    [oas_trace_session_root], [stable_worker_session_id],
    [oas_worker_evidence_session_id],
    [worker_meta_allowed_fields],
    [worker_meta_removed_fields],
    [validate_worker_meta_fields], [worker_meta_to_yojson],
    [worker_meta_of_yojson], [worker_container_state],
    [append_worker_turn_log], [start_worker_heartbeat],
    [oas_tool_names]). *)

include module type of struct
  include Worker_container_types
end

(** {1 Per-worker filesystem paths} *)

val worker_container_dir :
  base_path:string -> worker_name:string -> string
(** Resolves [<base_path>/.masc/local-workers/<safe-token>/].
    [worker_name] is sanitised to ASCII alphanumeric +
    [-_.] before being joined onto the root, so a name
    with shell metacharacters cannot escape the
    local-workers root. *)

val worker_raw_trace_path :
  base_path:string -> worker_name:string -> string
(** [{!worker_container_dir} / "raw-trace.jsonl"] —
    handed to the OAS raw-trace writer when materializing
    direct evidence. *)

val ensure_worker_container_dirs :
  base_path:string -> worker_name:string -> unit
(** Creates the {!worker_container_dir} chain if missing.
    Idempotent — touches a [.keep] sentinel and removes
    it, so the directory always exists before subsequent
    writers run. *)

(** {1 Worker meta (JSON-persisted)} *)

val load_worker_meta :
  base_path:string ->
  worker_name:string ->
  worker_container_meta option
(** Reads [meta.json] under {!worker_container_dir}.
    Returns [None] when the file is missing, the JSON
    fails to parse, or validation rejects unknown /
    removed fields.  Validation errors are logged via
    [Log.LocalWorker.warn] for operator visibility. *)

val save_worker_meta :
  base_path:string ->
  worker_name:string ->
  worker_container_meta ->
  (unit, string) result

val make_worker_meta :
  base_path:string ->
  workspace_path:string ->
  worker_name:string ->
  mcp_session_id:string ->
  role:string option ->
  selection_note:string option ->
  runtime_backend:Worker_execution_backend.t ->
  effective_model:string ->
  thinking_enabled:bool option ->
  timeout_seconds:int option ->
  worker_container_meta
(** Builds a fresh {!worker_container_meta} with derived
    [checkpoint_path] / [turn_log_path], [version =
    {!worker_container_version}], and [last_run_at = None]. *)

(** {1 Checkpoint persistence} *)

val load_worker_checkpoint :
  base_path:string ->
  worker_name:string ->
  Oas.Checkpoint.t option
(** Reads [checkpoint.json] via {!Oas.Checkpoint.of_string}.
    Returns [None] on missing file, parse failure, or
    [Sys_error]. *)

val save_worker_checkpoint :
  base_path:string ->
  worker_name:string ->
  Oas.Checkpoint.t ->
  (unit, string) result

(** {1 Session id resolution} *)

val resolved_mcp_session_id :
  base_path:string -> worker_name:string -> string
(** Returns the persisted [mcp_session_id] from worker
    meta when available, otherwise falls back to the
    digest-based [stable_worker_session_id]. *)

val evidence_session_id_of_worker_run :
  string option -> string option
(** Trims and returns [Some] when non-empty, [None]
    otherwise.  Pairs with {!materialize_direct_evidence}
    to skip evidence persistence on missing run id. *)

(** {1 Tool catalogue} *)

val session_min_tool_names : string list
(** Minimal MASC tool surface a local worker needs.  Used
    as the [allowed_names] filter in
    {!build_oas_mcp_tools}. *)

(** {1 Tool builders} *)

val build_oas_mcp_tools :
  sw:Eio.Switch.t ->
  auth_token:string option ->
  session_id:string ->
  worker_name:string ->
  (Oas.Tool.t list, string) result
(** Builds the OAS-formatted MASC tool list for a local
    worker.  Filters {!list_masc_tools} by
    {!session_min_tool_names}, then wraps each schema with
    a [call_fn] that injects [agent_name] when required,
    dispatches via {!call_masc_tool}, and converts MASC
    errors into [Oas.Types.tool_result]. *)

val build_local_shell_tools :
  room_config:Coord.config option ->
  worker_name:string ->
  workdir:string ->
  (Oas.Tool.t list, string) result
(** Builds the local-shell tool subset (process exec /
    file IO).  Errors when {!Process_eio.get_proc_mgr} or
    {!Process_eio.get_clock} are unavailable.  Hooks
    telemetry through [room_config] when an Eio fs is
    present; missing either drops telemetry silently. *)

(** {1 Provider resolution} *)

val oas_provider_of_label :
  string -> (Oas.Provider.config, string) result
(** Parses a model label (e.g. ["openai:gpt-4.1"]) into an
    {!Oas.Provider.config}.  Errors when
    {!Cascade_config.parse_model_string} returns [None]. *)

val resolve_oas_provider_of_label :
  string -> (Oas.Provider.config * string, string) result
(** Like {!oas_provider_of_label} but additionally returns
    the parsed [model_id] so callers do not have to
    re-parse the label to feed both fields into
    {!build_resume_config}. *)

(** {1 Turn-log audit trail} *)

val append_worker_completion_log :
  base_path:string ->
  worker_name:string ->
  prompt:string ->
  tool_names:string list ->
  status:string ->
  output:string ->
  ?error:string ->
  ?raw_trace_run:Oas.Raw_trace.run_ref ->
  ?evidence_session_id:string ->
  ?proof_run_id:string ->
  ?proof_result_status:string ->
  unit ->
  (unit, string) result
(** Appends one line to [turns.jsonl] summarising a
    completed run.  [prompt] / [output] are length-capped
    via {!safe_text_for_followup}. *)

(** {1 Resume config builder} *)

val build_resume_config :
  worker_name:string ->
  provider:Oas.Provider.config ->
  model_id:string ->
  system_prompt:string ->
  tools:Oas.Tool.t list ->
  max_turns:int ->
  thinking_enabled:bool ->
  hooks:Oas.Hooks.hooks ->
  raw_trace:Oas.Raw_trace.t ->
  ?periodic_callbacks:Oas.Agent.periodic_callback list ->
  ?guardrails:Oas.Guardrails.t ->
  ?tool_retry_policy:Oas.Tool_retry_policy.t ->
  unit ->
  Oas.Types.agent_config * Oas.Agent.options
(** Assembles the [(config, options)] pair consumed by
    [Oas.Agent.resume].  [config] inherits
    {!Oas.Types.default_config} and overrides
    [name] / [model] / [system_prompt] / [max_tokens]
    ({!local_worker_max_tokens}) / [max_turns] /
    [temperature] / [top_p] / [top_k] / [enable_thinking]
    / [tool_choice = Auto].  [min_p] stays [None] —
    cloud providers reject the field even at no-op 0.0.
    [guardrails] defaults to an [AllowList] of every tool
    name in [tools]. *)

(** {1 Direct-evidence persistence} *)

val materialize_direct_evidence :
  base_path:string ->
  worker_name:string ->
  worker_run_id:string option ->
  meta:worker_container_meta ->
  prompt:string ->
  workspace_path:string ->
  agent:Oas.Agent.t ->
  raw_trace:Oas.Raw_trace.t ->
  unit
(** Writes a direct-evidence bundle under
    [<base_path>/.masc/oas-runtime/...] when
    [worker_run_id] is present (no-op otherwise).
    Aliases are deduped through
    {!unique_preserve_order}; failures log via
    [Log.LocalWorker.error] but never re-raise. *)
