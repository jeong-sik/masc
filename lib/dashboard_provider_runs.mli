(** Dashboard_provider_runs — Single-agent provider runs for the
    operator dashboard.

    Owns 3 contract entries used by
    {!Server_routes_http_routes_provider_runs}:

    + {!provider_inventory_json} — JSON snapshot of all
      registered providers + per-provider model lists.
    + {!start_run} — fork a fiber-backed single-agent run; the
      [run_id] is the lookup key for {!run_status_json}.
    + {!run_status_json} — fetch the JSON state of a previously
      started run.

    Internal: 35+ helpers + 4 types ([discovery_info],
    [provider_snapshot], [run_status],  [run_record]) +
    state cells stay private — the
    [(string, run_record) Hashtbl.t] index, the
    {!Eio.Mutex.t} guarding it, the [finished_run_ttl_seconds]
    GC cap, [max_finished_runs] (= 128) overflow gate,
    [trim_nonempty] / [dedupe_keep_order] string helpers,
    {!string_of_run_status}, JSON serializers
    ([discovery_info_to_json], [provider_snapshot_to_json],
    [run_record_to_json]), Hashtbl mutators
    ([set_run_record], [update_run_record], [find_run_record]),
    [make_run_id], model-list resolvers
    ([model_id_of_label], [catalog_models_for_provider],
    [default_model_for_provider],
    [candidate_models_for_provider]), [llama_snapshot] +
    [provider_snapshot_of_adapter] + [provider_snapshots] +
    [provider_snapshot_by_name],
    [response_text_of_api_response],
    [provider_label_for_model],
    [resolve_provider_run_request], [is_label_runnable],
    [run_system_prompt], [execute_single_agent_run], plus the
    GC helpers ([is_terminal_status], [run_sort_key],
    [drop_oldest_finished], [prune_run_records_locked]).
    All consumed only inside the 3 public entries. *)

val provider_inventory_json : unit -> Yojson.Safe.t
(** [provider_inventory_json ()] returns a JSON object
    [{ updated_at; summary; providers }] where:

    - [updated_at] is the current ISO timestamp.
    - [summary.providers] / [summary.local_models] /
      [summary.cloud_models] / [summary.cli_models] are
      cardinality counts.
    - [providers] is an array of provider snapshots covering
      direct-API + CLI-agent + local providers.

    Read-only — no run state is touched. *)

val start_run :
  sw:Eio.Switch.t ->
  net:Eio_context.eio_net option ->
  provider:string ->
  model_opt:string option ->
  prompt:string ->
  (Yojson.Safe.t, string) result
(** [start_run ~sw ~net ~provider ~model_opt ~prompt] queues a
    new single-agent run.  Validation:

    + [provider] must be a registered runnable provider.
    + [model_opt = None] falls back to the provider's default
      model; missing default returns [Error _].
    + [model_opt = Some m] is checked against the provider's
      announced model list (when the list is non-empty).
    + [prompt] must be non-empty after trim.

    On success, the run record is created with status [Queued],
    a fiber is forked under [~sw] which transitions the record
    through [Running] -> [Completed] / [Failed].
    [Eio.Cancel.Cancelled] inside the fiber transitions the
    record to [Failed] with reason
    ["Dashboard single-agent run cancelled"] before re-raising.

    Returned [Yojson.Safe.t] is
    [{ run_id; status; provider; model }] — callers poll via
    {!run_status_json}. *)

val run_status_json :
  string -> (Yojson.Safe.t, string) result
(** [run_status_json run_id] returns the JSON encoding of the
    {!run_record} for [run_id], or [Error] when no record
    exists.  Records older than [finished_run_ttl_seconds]
    (env-driven) are pruned during background sweeps —
    [run_id] lookup may legitimately return [Error] for old
    completed runs.  Pinned at the contract seam: drift to
    silent fallbacks would break operator-visible "run
    expired" feedback. *)
