(** Worker_container — local-worker meta / checkpoint /
    tool-builder layer.

    Sits between {!Worker_container_types} (cycle 191) and
    {!Worker_container_runners} (which does
    [include Worker_container] + a top-level runtime-include
    in its .mli).  Type identity propagates end-to-end via
    [include module type of struct include M end]
    (cycle 187 rationale).

    External surface (15 entries — 11 dotted callers + 4
    additional helpers consumed unqualified by
    {!Worker_container_runners} through the runtime):
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
    - Tool builders: {!build_oas_mcp_tools}.
    - Provider: {!oas_provider_of_label},
      {!resolve_oas_provider_of_label}.
    - Audit + run helpers: {!append_worker_completion_log},
      {!build_resume_config}.

    Internal helpers stay private at this boundary
    ([worker_container_root], [safe_worker_token],
    [worker_meta_path], [worker_checkpoint_path],
    [worker_turn_log_path], [oas_tool_error],
    [stable_worker_session_id],
    [oas_worker_evidence_session_id],
    [worker_meta_allowed_fields],
    [worker_meta_removed_fields],
    [validate_worker_meta_fields], [worker_meta_to_yojson],
    [worker_meta_of_yojson], [worker_container_state],
    [append_worker_turn_log], [start_worker_heartbeat]). *)

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
    Idempotent — touches a [.keep] marker and removes
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
    {!worker_container_version}], no active
    [mcp_client_session_started_at], and [last_run_at =
    None].  The bounded client session opens immediately before
    [Agent.run]. *)

(** {1 Checkpoint persistence} *)

val load_worker_checkpoint :
  base_path:string ->
  worker_name:string ->
  Agent_sdk.Checkpoint.t option
(** Reads [checkpoint.json] via {!Agent_sdk.Checkpoint.of_string}.
    Returns [None] on missing file, parse failure, or
    [Sys_error]. *)

val save_worker_checkpoint :
  base_path:string ->
  worker_name:string ->
  Agent_sdk.Checkpoint.t ->
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
    otherwise.  Feeds the [evidence_session_id] column of
    {!append_worker_completion_log}. *)

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
  (Agent_sdk.Tool.t list, string) result
(** Builds the OAS-formatted MASC tool list for a local
    worker.  Filters {!list_masc_tools} by
    {!session_min_tool_names}, then wraps each schema with
    a [call_fn] that injects [agent_name] when required,
    dispatches via {!call_masc_tool}, and converts MASC
    errors into [Agent_sdk.Types.tool_result]. *)

(** {1 Provider resolution} *)

val oas_provider_of_label :
  string -> (Agent_sdk.Provider.config, string) result
(** Parses a model label (e.g. ["openai:gpt-4.1"]) into an
    {!Agent_sdk.Provider.config}.  Errors when
    {!Runtime_model_string.parse_model_string} returns [None]. *)

val resolve_oas_provider_of_label :
  string -> (Agent_sdk.Provider.config * string, string) result
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
  ?raw_trace_run:Agent_sdk.Raw_trace.run_ref ->
  ?evidence_session_id:string ->
  unit ->
  (unit, string) result
(** Appends one line to [turns.jsonl] summarising a
    completed run.  [prompt] / [output] are length-capped
    via {!safe_text_for_followup}. *)

(** {1 Resume config builder} *)

val build_resume_config :
  worker_name:string ->
  provider:Agent_sdk.Provider.config ->
  model_id:string ->
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  max_turns:int ->
  thinking_enabled:bool ->
  hooks:Agent_sdk.Hooks.hooks ->
  raw_trace:Agent_sdk.Raw_trace.t ->
  ?periodic_callbacks:Agent_sdk.Agent.periodic_callback list ->
  ?guardrails:Agent_sdk.Guardrails.t ->
  unit ->
  Agent_sdk.Types.agent_config * Agent_sdk.Agent.options
(** Assembles the [(config, options)] pair consumed by
    [Agent_sdk.Agent.resume].  [config] inherits
    {!Agent_sdk.Types.default_config} and overrides
    [name] / [model] / [system_prompt] / [max_turns] /
    [enable_thinking] / [tool_choice = Auto]. Provider/model sampling and
    output defaults remain OAS-owned. [guardrails] defaults to the unrestricted
    worker surface; the concrete [tools] list is the exposure SSOT. *)
