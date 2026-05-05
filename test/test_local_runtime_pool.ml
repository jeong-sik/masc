open Masc_mcp

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
  | Some v -> Unix.putenv name v
  | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let make_runtime ?model ?(max_concurrency = 2) id base_url =
  {
    Local_runtime_pool.id;
    base_url;
    model;
    max_concurrency;
    active_slots = 0;
    queue_depth = 0;
    latency_ema_ms = None;
    failure_streak = 0;
    cooldown_until = None;
    last_error = None;
    total_started = 0;
    total_success = 0;
    total_failure = 0;
  }

let install_pool runtimes =
  Local_runtime_pool.pool :=
    {
      Local_runtime_pool.empty_pool with
      runtimes;
      fingerprint = Local_runtime_pool.current_fingerprint ();
    }

let test_parse_runtime_env () =
  Local_runtime_pool.reset ();
  (* OAS 0.112.0 auto-appends Ollama endpoint (http://127.0.0.1:11434) to
     LLM_ENDPOINTS.  ollama_endpoint is a module-level constant so env changes
     at test time have no effect.  Include it in the LLM_ENDPOINTS list to
     keep the count predictable via deduplication. *)
  with_env "LLM_ENDPOINTS"
    (Some "http://127.0.0.1:19001,http://127.0.0.1:19002,http://127.0.0.1:11434")
  @@ fun () ->
  let snapshots = Local_runtime_pool.snapshots () in
  Alcotest.(check int) "runtime count" 3 (List.length snapshots);
  let runtime_ids =
    snapshots |> List.map (fun (runtime : Local_runtime_pool.runtime_snapshot) -> runtime.id)
  in
  Alcotest.(check bool) "contains local-19001" true (List.mem "local-19001" runtime_ids);
  Alcotest.(check bool) "contains local-19002" true (List.mem "local-19002" runtime_ids);
  Alcotest.(check bool) "contains local-11434" true (List.mem "local-11434" runtime_ids)

let test_parse_llm_endpoints_env () =
  Local_runtime_pool.reset ();
  with_env "MASC_LOCAL_RUNTIMES_JSON" None @@ fun () ->
  with_env "MASC_LLAMA_RUNTIMES_JSON" None @@ fun () ->
  with_env "LLM_ENDPOINTS"
    (Some "http://127.0.0.1:19001, http://127.0.0.1:19002, http://127.0.0.1:11434")
  @@ fun () ->
  let snapshots = Local_runtime_pool.snapshots () in
  Alcotest.(check int) "runtime count" 3 (List.length snapshots);
  let runtime_ids =
    snapshots
    |> List.map (fun (runtime : Local_runtime_pool.runtime_snapshot) -> runtime.id)
  in
  Alcotest.(check bool) "contains local-19001" true
    (List.mem "local-19001" runtime_ids);
  Alcotest.(check bool) "contains local-19002" true
    (List.mem "local-19002" runtime_ids);
  Alcotest.(check bool) "contains local-11434" true
    (List.mem "local-11434" runtime_ids)

(* [test_acquire_and_release] / [test_acquire_prefers_exact_model_match]
   / [test_acquire_rejects_mismatched_preferred_model_pool] removed
   2026-05-05 — covered the acquire/release surface that was archived.
   See docs/audit-responses/2026-05-05-dashboard-heuristic.md §7.1. *)

let test_select_runtime_from_empty_returns_error () =
  match Local_runtime_pool.select_runtime_from [] () with
  | Ok _ -> Alcotest.fail "empty runtime list should be rejected"
  | Error message ->
      Alcotest.(check string) "empty runtime error"
        "no local runtimes configured" message

(* [test_acquire_requires_explicit_or_runtime_model] removed 2026-05-05 —
   covered the acquire surface that was archived. *)

let test_record_measured_ceiling () =
  Local_runtime_pool.reset ();
  Local_runtime_pool.record_measured_ceiling 12;
  Local_runtime_pool.record_measured_ceiling 8;
  Alcotest.(check (option int)) "ceiling is max" (Some 12)
    (Local_runtime_pool.measured_ceiling ())

(* [test_failure_cooldown_from_env] removed 2026-05-05 — exercised the
   failure-streak path through release/acquire which was archived. *)

let () =
  Alcotest.run "test_local_runtime_pool"
    [
      ( "local_runtime_pool",
        [
          Alcotest.test_case "parse runtime env" `Quick test_parse_runtime_env;
          Alcotest.test_case "parse LLM_ENDPOINTS env" `Quick
            test_parse_llm_endpoints_env;
          Alcotest.test_case "empty runtime set returns error" `Quick
            test_select_runtime_from_empty_returns_error;
          Alcotest.test_case "record measured ceiling" `Quick
            test_record_measured_ceiling;
        ] );
    ]
