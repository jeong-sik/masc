(** Memory_oas_bridge — bridges MASC's institution / procedural
    memory layer onto the OAS [Agent_sdk.Memory.t] long-term store.

    Two responsibilities:
    - {b Round-trip} between [Institution_eio.episode]
      (MASC JSONL log) and [Agent_sdk.Memory.episode] (OAS
      long-term store) so the two persistence paths share a
      single semantic model.
    - {b Flush + reload} the OAS memory back to the MASC
      JSONL files via {!flush_episodes} /
      {!flush_procedures} / {!flush_incremental}, and pull
      the latest slice for prompt injection via
      {!load_episodes_text} / {!load_procedures_text} /
      {!load_institution_text}.

    The .ml is 825 lines with many internal helpers
    (file-stamp caching, episode / procedure dedup,
    metadata accessors, error-kind normalisation, stress
    metric emission).  External callers reach 14 dotted
    symbols; everything else stays private at this
    boundary. *)

(** {1 Backend constructors} *)

val make_backend :
  ?base_dir:string ->
  agent_name:string ->
  session_id:string ->
  unit ->
  Agent_sdk.Memory.long_term_backend
(** Builds the JSONL long-term backend rooted at
    [base_dir / .masc / oas-memory / <agent_name>] (the
    [base_dir] resolver falls back to
    {!Env_config.base_path} when omitted). *)

val create_memory :
  agent_name:string ->
  ?base_dir:string ->
  ?session_id:string ->
  unit ->
  Agent_sdk.Memory.t
(** Creates an [Agent_sdk.Memory.t] backed by {!make_backend}.
    [session_id] defaults to a timestamp-based id from
    {!Time_compat.now}.  Filesystem-first: no PG, no
    network. *)

(** {1 OAS / MASC episode round-trip} *)

val oas_procedure_of_masc :
  Procedural_memory.procedure -> Agent_sdk.Memory.procedure
(** Converts a MASC {!Procedural_memory.procedure} into the
    OAS shape.  [pattern] becomes both [pattern] and
    [action] (MASC combines the trigger / action in
    [pattern]); the metadata bag carries [agent_name],
    [created_at], and [evidence_count] so the reverse
    direction can recover them. *)

(** {1 Episode persistence} *)

val store_episode_from_snapshot :
  memory:Agent_sdk.Memory.t ->
  keeper_name:string ->
  turn:int ->
  trace_id:string ->
  Keeper_memory_policy.keeper_state_snapshot ->
  unit
(** Captures a successful keeper turn into the OAS memory
    store: serialises the [goal] / [progress] /
    [done_summary] tuple from the snapshot, attaches
    [keeper_name] / [turn] / [trace_id] metadata, and
    writes via [Agent_sdk.Memory.store_episode]. *)

(** Typed wrapper for failed-turn error-kind labels. JSON/status/metric
    surfaces continue to render the stable string label. *)
type error_kind = private Error_kind of string

val error_kind_of_string : string -> error_kind
val error_kind_to_string : error_kind -> string

val store_failed_turn_episode :
  memory:Agent_sdk.Memory.t ->
  keeper_name:string ->
  turn:int ->
  trace_id:string ->
  error_kind:error_kind ->
  error_message:string ->
  unit ->
  unit
(** Captures a failed keeper turn into the OAS memory
    store.  Length-caps [error_message] via
    {!String_util.utf8_safe} (preview at 403 bytes,
    context at 4099 bytes) so a runaway stack trace cannot
    blow up the JSONL row.  Calls
    {!emit_stress_for_failure} on a known timeout-class
    [error_kind] for downstream stress accounting. *)

(** {1 Failure-learning helpers} *)

val failure_learnings :
  error_kind:error_kind -> error_preview:string -> string list
(** Builds the canonical [learnings] list for a failed
    episode: [["failure_kind: <normalised>"]] plus, when
    non-empty, ["error_preview: <preview>"].
    [normalize_error_kind] collapses empty / whitespace
    inputs to ["unspecified"] so downstream filters never
    see a blank kind. *)

val record_failure_lesson :
  memory:Agent_sdk.Memory.t ->
  pattern:string ->
  summary:string ->
  ?action:string ->
  ?stdout:string ->
  ?stderr:string ->
  ?diff_summary:string ->
  ?trace_summary:string ->
  ?metric_name:string ->
  ?metric_error:string ->
  participants:string list ->
  metadata:(string * Yojson.Safe.t) list ->
  unit ->
  unit
(** Records a failure lesson via
    {!Agent_sdk.Lesson_memory.record_failure}.  All optional
    fields default to [None] so the caller only fills in
    what the failure path actually produced.  Returns
    [unit] (the underlying record-failure result is
    intentionally discarded — callers do not branch on
    persistence success). *)

(** {1 Flush (MASC JSONL ← OAS memory)} *)

val flush_episodes :
  memory:Agent_sdk.Memory.t -> agent_name:string -> int
(** Drains every episode held in [memory] that is not yet
    persisted to the institution JSONL log.  Returns the
    number of new rows written.  Idempotent — re-running
    after a clean flush returns 0 (the persisted-id cache
    skips duplicates). *)

val flush_procedures :
  memory:Agent_sdk.Memory.t -> agent_name:string -> int
(** Drains every procedure held in [memory] that has
    changed since the last flush.  Dedup happens by
    [Procedural_memory.procedure.id] keeping the entry
    with the latest [last_applied] timestamp.  Returns the
    number of rows written. *)

val flush_incremental :
  memory:Agent_sdk.Memory.t -> agent_name:string -> int * int
(** Convenience wrapper around {!flush_episodes} +
    {!flush_procedures}.  Returns
    [(episodes_written, procedures_written)]. *)

(** {1 Load (prompt-context text)} *)

val load_episodes_text : limit:int -> string option
(** Reads the most recent [limit] entries from the
    institution JSONL log and renders them as a single
    Markdown-ish block suitable for prepending to a
    keeper's prompt.  Returns [None] when the log is empty
    or unreadable. *)

val load_procedures_text :
  agent_name:string -> limit:int -> string option
(** Reads the top [limit] procedures (by confidence) for
    [agent_name] from the procedural-memory backend and
    renders them for prompt injection.  Same fail-soft
    contract as {!load_episodes_text}. *)

val load_world_text :
  backend:Agent_sdk.Memory.long_term_backend option ->
  memory:Agent_sdk.Memory.t ->
  limit:int ->
  string option
(** Reads long-term OAS memory entries whose keys start with
    ["world"] and renders them for prompt injection.  This is
    intentionally sourced from [Agent_sdk.Memory.t] rather than keeper
    runtime state so user-authored world memory can reach the
    deliberation/prompt path. *)

val load_institution_text :
  config:Coord_utils.config -> string option
(** Reads the structured [institution.json] under [config]
    and renders the welcome banner via
    {!Institution_eio.load_and_format_for_welcome}.
    Returns [None] when the file is missing or any
    load / parse step fails. *)

(** {1 Lesson retrieval} *)

val render_lesson_prompt_context :
  memory:Agent_sdk.Memory.t ->
  pattern:string ->
  limit:int ->
  string option
(** Retrieves the top [limit] lessons matching [pattern]
    via {!Agent_sdk.Lesson_memory.retrieve_lessons} and renders
    them through {!Agent_sdk.Lesson_memory.render_prompt_context}
    for prompt injection.  Returns [None] when no lesson
    matches; the caller ([tool_autoresearch_cycle.ml])
    branches on the [option] to decide whether to attach
    the block. *)

(** {1 Failure metrics + stress mapping} *)

val institution_episode_failure_kind_metric : string
(** Metric name (canonical
    [masc_institution_episode_failure_kind_total]) for the
    Prometheus counter that tracks failed-episode kinds.
    Pinned at this boundary because
    [test/test_institution_episodes_failure_learnings_10325.ml]
    asserts the wire string for telemetry compatibility. *)

val timeout_error_kinds : error_kind list
(** SSOT list of typed error-kind labels the
    {!stress_kind_for_error_kind} mapper treats as
    timeout-class.  Pinned because
    [test/test_agent_stress_timeout_wire_10341.ml] asserts
    its length to keep the catalogue from drifting. *)

val stress_kind_for_error_kind :
  error_kind -> Agent_stress.stress_kind option
(** Maps an error kind label onto an
    {!Agent_stress.kind} when the kind belongs to the
    timeout family ([timeout_error_kinds] internal list).
    Returns [None] for non-timeout errors so the caller
    can decide whether to bump a stress counter at all.
    Tested by
    [test/test_agent_stress_timeout_wire_10341.ml]. *)
