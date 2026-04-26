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
;;

let make_runtime ?model ?(max_concurrency = 2) id base_url =
  { Local_runtime_pool.id
  ; base_url
  ; model
  ; max_concurrency
  ; active_slots = 0
  ; queue_depth = 0
  ; latency_ema_ms = None
  ; failure_streak = 0
  ; cooldown_until = None
  ; last_error = None
  ; total_started = 0
  ; total_success = 0
  ; total_failure = 0
  }
;;

let install_pool runtimes =
  Local_runtime_pool.pool
  := { Local_runtime_pool.empty_pool with
       runtimes
     ; fingerprint = Local_runtime_pool.current_fingerprint ()
     }
;;

let test_parse_runtime_env () =
  Local_runtime_pool.reset ();
  (* OAS 0.112.0 auto-appends Ollama endpoint (http://127.0.0.1:11434) to
     LLM_ENDPOINTS.  ollama_endpoint is a module-level constant so env changes
     at test time have no effect.  Include it in the LLM_ENDPOINTS list to
     keep the count predictable via deduplication. *)
  with_env
    "LLM_ENDPOINTS"
    (Some "http://127.0.0.1:19001,http://127.0.0.1:19002,http://127.0.0.1:11434")
  @@ fun () ->
  let snapshots = Local_runtime_pool.snapshots () in
  Alcotest.(check int) "runtime count" 3 (List.length snapshots);
  let runtime_ids =
    snapshots
    |> List.map (fun (runtime : Local_runtime_pool.runtime_snapshot) -> runtime.id)
  in
  Alcotest.(check bool) "contains local-19001" true (List.mem "local-19001" runtime_ids);
  Alcotest.(check bool) "contains local-19002" true (List.mem "local-19002" runtime_ids);
  Alcotest.(check bool) "contains local-11434" true (List.mem "local-11434" runtime_ids)
;;

let test_parse_llm_endpoints_env () =
  Local_runtime_pool.reset ();
  with_env "MASC_LOCAL_RUNTIMES_JSON" None
  @@ fun () ->
  with_env "MASC_LLAMA_RUNTIMES_JSON" None
  @@ fun () ->
  with_env
    "LLM_ENDPOINTS"
    (Some "http://127.0.0.1:19001, http://127.0.0.1:19002, http://127.0.0.1:11434")
  @@ fun () ->
  let snapshots = Local_runtime_pool.snapshots () in
  Alcotest.(check int) "runtime count" 3 (List.length snapshots);
  let runtime_ids =
    snapshots
    |> List.map (fun (runtime : Local_runtime_pool.runtime_snapshot) -> runtime.id)
  in
  Alcotest.(check bool) "contains local-19001" true (List.mem "local-19001" runtime_ids);
  Alcotest.(check bool) "contains local-19002" true (List.mem "local-19002" runtime_ids);
  Alcotest.(check bool) "contains local-11434" true (List.mem "local-11434" runtime_ids)
;;

let test_acquire_and_release () =
  Local_runtime_pool.reset ();
  install_pool
    [ make_runtime "local-a" "http://127.0.0.1:19001" ~max_concurrency:2
    ; make_runtime "local-b" "http://127.0.0.1:19002" ~model:"qwen-b" ~max_concurrency:2
    ];
  let assignment =
    match
      Local_runtime_pool.acquire
        ~preferred_pool:"local-a"
        ~model_name:(Some "explicit-model")
        ()
    with
    | Ok assignment -> assignment
    | Error err -> failwith err
  in
  Alcotest.(check string) "preferred runtime selected" "local-a" assignment.runtime_id;
  Alcotest.(check string) "model preserved" "explicit-model" assignment.model_name;
  Local_runtime_pool.release assignment.lease ~success:true ~latency_ms:123 ();
  let snapshot =
    Local_runtime_pool.snapshots ()
    |> List.find (fun (runtime : Local_runtime_pool.runtime_snapshot) ->
      String.equal runtime.id "local-a")
  in
  Alcotest.(check int) "active slots released" 0 snapshot.active_slots;
  Alcotest.(check int) "success count recorded" 1 snapshot.total_success
;;

let test_acquire_prefers_exact_model_match () =
  Local_runtime_pool.reset ();
  install_pool
    [ make_runtime "generic" "http://127.0.0.1:8185" ~max_concurrency:2
    ; make_runtime "lead" "http://127.0.0.1:8186" ~model:"qwen35-lead" ~max_concurrency:2
    ; make_runtime
        "worker"
        "http://127.0.0.1:8187"
        ~model:"qwen9-worker"
        ~max_concurrency:2
    ];
  let assignment =
    match Local_runtime_pool.acquire ~model_name:(Some "qwen9-worker") () with
    | Ok assignment -> assignment
    | Error err -> failwith err
  in
  Alcotest.(check string) "exact runtime selected" "worker" assignment.runtime_id;
  Alcotest.(check string) "requested model preserved" "qwen9-worker" assignment.model_name;
  Local_runtime_pool.release assignment.lease ~success:true ()
;;

let test_acquire_rejects_mismatched_preferred_model_pool () =
  Local_runtime_pool.reset ();
  install_pool
    [ make_runtime "lead" "http://127.0.0.1:8285" ~model:"qwen35-lead" ~max_concurrency:2
    ; make_runtime
        "worker"
        "http://127.0.0.1:8286"
        ~model:"qwen9-worker"
        ~max_concurrency:2
    ];
  match
    Local_runtime_pool.acquire ~preferred_pool:"lead" ~model_name:(Some "qwen9-worker") ()
  with
  | Ok _ -> Alcotest.fail "preferred pool with mismatched model should fail"
  | Error message ->
    Alcotest.(check string)
      "mismatch error"
      "no local runtime configured for model qwen9-worker in runtime pool lead"
      message
;;

let test_select_runtime_from_empty_returns_error () =
  match Local_runtime_pool.select_runtime_from [] () with
  | Ok _ -> Alcotest.fail "empty runtime list should be rejected"
  | Error message ->
    Alcotest.(check string) "empty runtime error" "no local runtimes configured" message
;;

let test_acquire_requires_explicit_or_runtime_model () =
  Local_runtime_pool.reset ();
  install_pool
    [ make_runtime "local-no-model" "http://127.0.0.1:7085" ~max_concurrency:1 ];
  match
    Local_runtime_pool.acquire ~preferred_pool:"local-no-model" ~model_name:None ()
  with
  | Ok _ -> Alcotest.fail "runtime without model should reject implicit acquire"
  | Error message ->
    Alcotest.(check string)
      "explicit model error"
      "no explicit model provided for local runtime local-no-model; set spawn_model or \
       runtime.model"
      message
;;

let test_record_measured_ceiling () =
  Local_runtime_pool.reset ();
  Local_runtime_pool.record_measured_ceiling 12;
  Local_runtime_pool.record_measured_ceiling 8;
  Alcotest.(check (option int))
    "ceiling is max"
    (Some 12)
    (Local_runtime_pool.measured_ceiling ())
;;

let test_failure_cooldown_from_env () =
  Local_runtime_pool.reset ();
  with_env "MASC_LOCAL_RUNTIME_COOLDOWN_SEC" (Some "120")
  @@ fun () ->
  install_pool
    [ make_runtime "local-c" "http://127.0.0.1:9085" ~model:"qwen-c" ~max_concurrency:1 ];
  let fail_once () =
    let assignment =
      match Local_runtime_pool.acquire ~preferred_pool:"local-c" ~model_name:None () with
      | Ok assignment -> assignment
      | Error err -> failwith err
    in
    Local_runtime_pool.release
      assignment.lease
      ~success:false
      ~error:"Connection refused"
      ()
  in
  fail_once ();
  fail_once ();
  fail_once ();
  let snapshot =
    Local_runtime_pool.snapshots ()
    |> List.find (fun (runtime : Local_runtime_pool.runtime_snapshot) ->
      String.equal runtime.id "local-c")
  in
  Alcotest.(check int) "failure streak recorded" 3 snapshot.failure_streak;
  Alcotest.(check bool) "cooldown active" true (Option.is_some snapshot.cooldown_until);
  Alcotest.(check int) "failure count recorded" 3 snapshot.total_failure
;;

let () =
  Alcotest.run
    "test_local_runtime_pool"
    [ ( "local_runtime_pool"
      , [ Alcotest.test_case "parse runtime env" `Quick test_parse_runtime_env
        ; Alcotest.test_case "parse LLM_ENDPOINTS env" `Quick test_parse_llm_endpoints_env
        ; Alcotest.test_case "acquire and release" `Quick test_acquire_and_release
        ; Alcotest.test_case
            "acquire prefers exact model match"
            `Quick
            test_acquire_prefers_exact_model_match
        ; Alcotest.test_case
            "acquire rejects mismatched preferred model pool"
            `Quick
            test_acquire_rejects_mismatched_preferred_model_pool
        ; Alcotest.test_case
            "empty runtime set returns error"
            `Quick
            test_select_runtime_from_empty_returns_error
        ; Alcotest.test_case
            "acquire requires explicit model when runtime omits it"
            `Quick
            test_acquire_requires_explicit_or_runtime_model
        ; Alcotest.test_case
            "failure cooldown from env"
            `Quick
            test_failure_cooldown_from_env
        ; Alcotest.test_case "record measured ceiling" `Quick test_record_measured_ceiling
        ] )
    ]
;;
