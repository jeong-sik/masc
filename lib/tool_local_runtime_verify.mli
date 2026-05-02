
(** Tool_local_runtime_verify — Runtime contract verification for
    local LLM runtime pools (llama.cpp / Ollama).

    Exposes 3 verification entries.  The .ml does
    [include Tool_local_runtime_http] for internal access to HTTP
    helpers ([trim_to_option], discovery resolution, etc.); those
    helpers are intentionally hidden from external callers via
    this .mli — verify is the contract layer, http is the
    implementation layer.

    Internal: ~25 helpers stay private —
    \[runtime_snapshots_for_pool], \[safe_discovery_endpoints],
    \[discovery_endpoints_for_pool], \[active_slots_of_json],
    \[slot_count_of_json], the 4 [endpoint_*] field projectors,
    \[first_endpoint_url], \[error_message_of_http_error],
    \[probe_chat_completion_compatible], \[chat_contract_probe_body],
    \[chat_contract_reachable], \[chat_contract_status],
    \[runtime_verify_json_from_discovery] /
    \[runtime_verify_json_legacy] (the two backends behind
    {!runtime_verify_json}).  Plus the 3 [Oas_types] alias
    + the [include Tool_local_runtime_http] cascade.  All
    consumed only inside {!runtime_verify_json}'s pipeline. *)

val provider_health_reachable :
  status:int option -> body:string option -> bool
(** [provider_health_reachable ~status ~body] is [true] iff
    [status = Some 200].  [body] is currently ignored — the
    health endpoint is a status-code-only check.  Drift to
    body-content validation would change "what counts as
    reachable" and need a coordinated update with the
    health-check probe. *)

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
(** [classify_runtime_blocker ~provider_reachable ~slot_reachable
      ~chat_contract_status ~expected_model ~actual_model_id
      ~expected_slots ~actual_slots_total ~expected_ctx
      ~actual_ctx ~chat_completion_compatible] grades a runtime
    snapshot through 6 cascading checks.  Returns
    [(blocker_code, message)]:

    + [(Some "provider_unreachable", _)] when provider or slots
      endpoint failed.
    + [(Some "provider_protocol_incompatible", _)] when chat
      completions probe failed.
    + [(Some "provider_model_mismatch", _)] when expected_model
      is set but actual differs (or actual is missing).
    + [(Some "slot_count_insufficient", _)] when actual slots
      below expected.
    + [(Some "ctx_mismatch", _)] when expected_ctx differs from
      actual.
    + [(Some "chat_contract_incompatible", _)] when contract
      status is ["rejected"].
    + [(None, None)] when all checks pass.

    Pinned blocker codes — operator dashboards parse these
    strings.  Drift breaks tooltip + alerting downstream. *)

val runtime_verify_json :
  ?runtime_pool:string ->
  ?expected_slots:int ->
  ?expected_ctx:int ->
  ?expected_model:string ->
  unit ->
  Yojson.Safe.t
(** [runtime_verify_json ?runtime_pool ?expected_slots
      ?expected_ctx ?expected_model ()] runs the full runtime
    verification pipeline against either the discovery cache
    (when an endpoint set is resolvable for [?runtime_pool]) or
    the legacy single-host probe (fallback).

    Returns a JSON object with health/slot/ctx/model
    diagnostics + the {!classify_runtime_blocker} verdict.  [?runtime_pool]
    selects the pool by name; default behaviour is "use the
    default pool" via {!Local_runtime_pool.default_pool_label}. *)
