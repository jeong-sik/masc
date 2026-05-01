open Base

(** Tool_local_runtime_bench — concurrency benchmark against the
    local runtime pool.

    {b Include cascade:} starts with [include Tool_local_runtime_http]
    so the 2-layer chain
    ([Tool_local_runtime_core] -> [Tool_local_runtime_http] -> here)
    propagates through {!Tool_local_runtime}.

    Single public entry: {!run_bench}.  Internal helpers
    ({!pctl} percentile, {!error_message_of_http_error},
    per-runtime breakdown aggregators, runtime-pool resolution
    helpers, {!ensure_runtime_reachable}, {!oas_completion_at})
    stay private — the .mli pins the bench result schema, not the
    plumbing that produces it. *)

include module type of struct
  include Tool_local_runtime_http
end

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
(** [run_bench ?model_id ?runtime_pool ~parallelism ~rounds ~prompt
      ~max_tokens ~timeout_sec ()] runs a concurrency benchmark.

    {b Reachability gate}: returns [Error _] immediately if
    {!ensure_runtime_reachable} fails for the requested
    [runtime_pool].  No samples are taken.

    {b Schedule}: [rounds] sequential rounds, each with
    [parallelism] concurrent fibers via {!Eio.Fiber.all}.  Total
    [parallelism * rounds] requests issued.

    {b Per-fiber timeout}: [timeout_sec] enforced via
    {!Eio.Time.with_timeout_exn}.  Timeouts count as failures with
    [error = "timeout"].

    {b Result schema} (on [Ok]):

    {[
      \{
        "server_url": string,
        "source": "oas_complete",
        "model_id": string|null,
        "runtime_pool": string|null,
        "parallelism": int,
        "rounds": int,
        "total_requests": int,
        "success_count": int,
        "failure_count": int,
        "success_rate": float in \[0.0, 1.0\],
        "p50_latency_ms": int|null,
        "p95_latency_ms": int|null,
        "max_latency_ms": int|null,
        "configured_max_concurrent_models": int,
        "configured_capacity": int,
        "measured_ceiling": int|null,
        "per_runtime_breakdown": [object],
        "errors": [string]
      \}
    ]}

    [errors] is sorted + deduped via {!List.sort_uniq}.
    [per_runtime_breakdown] is sorted by [runtime_id] for
    deterministic output.  Side effect: calls
    {!Local_runtime_pool.record_measured_ceiling} with the
    success count so the ceiling carries over to subsequent runs. *)
