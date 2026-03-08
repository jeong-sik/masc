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

let test_parse_runtime_env () =
  let json =
    {|[
      {"id":"local-a","base_url":"http://127.0.0.1:8085","model":"qwen-a","max_concurrency":12},
      {"id":"local-b","base_url":"http://127.0.0.1:8086","model":"qwen-a","max_concurrency":10}
    ]|}
  in
  with_env "MASC_LLAMA_RUNTIMES_JSON" (Some json) @@ fun () ->
  let snapshots = Local_runtime_pool.snapshots () in
  Alcotest.(check int) "runtime count" 2 (List.length snapshots);
  Alcotest.(check int) "configured capacity" 22
    (Local_runtime_pool.configured_capacity ());
  let runtime_ids =
    snapshots |> List.map (fun (runtime : Local_runtime_pool.runtime_snapshot) -> runtime.id)
  in
  Alcotest.(check bool) "contains local-a" true (List.mem "local-a" runtime_ids);
  Alcotest.(check bool) "contains local-b" true (List.mem "local-b" runtime_ids)

let test_acquire_and_release () =
  let json =
    {|[
      {"id":"local-a","base_url":"http://127.0.0.1:8085","model":"qwen-a","max_concurrency":2},
      {"id":"local-b","base_url":"http://127.0.0.1:8086","model":"qwen-b","max_concurrency":2}
    ]|}
  in
  with_env "MASC_LLAMA_RUNTIMES_JSON" (Some json) @@ fun () ->
  let assignment =
    match
      Local_runtime_pool.acquire ~preferred_pool:"local-a"
        ~model_name:(Some "explicit-model") ()
    with
    | Ok assignment -> assignment
    | Error err -> failwith err
  in
  Alcotest.(check string) "preferred runtime selected" "local-a"
    assignment.runtime_id;
  Alcotest.(check string) "model preserved" "explicit-model"
    assignment.model_name;
  Local_runtime_pool.release assignment.lease ~success:true ~latency_ms:123 ();
  let snapshot =
    Local_runtime_pool.snapshots ()
    |> List.find (fun (runtime : Local_runtime_pool.runtime_snapshot) ->
           String.equal runtime.id "local-a")
  in
  Alcotest.(check int) "active slots released" 0 snapshot.active_slots;
  Alcotest.(check int) "success count recorded" 1 snapshot.total_success

let test_record_measured_ceiling () =
  Local_runtime_pool.record_measured_ceiling 12;
  Local_runtime_pool.record_measured_ceiling 8;
  Alcotest.(check (option int)) "ceiling is max" (Some 12)
    (Local_runtime_pool.measured_ceiling ())

let test_failure_cooldown_from_env () =
  let json =
    {|[
      {"id":"local-c","base_url":"http://127.0.0.1:9085","model":"qwen-c","max_concurrency":1}
    ]|}
  in
  with_env "MASC_LLAMA_RUNTIME_COOLDOWN_SEC" (Some "120") @@ fun () ->
  with_env "MASC_LLAMA_RUNTIMES_JSON" (Some json) @@ fun () ->
  let fail_once () =
    let assignment =
      match Local_runtime_pool.acquire ~preferred_pool:"local-c" ~model_name:None () with
      | Ok assignment -> assignment
      | Error err -> failwith err
    in
    Local_runtime_pool.release assignment.lease ~success:false
      ~error:"Connection refused" ()
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
  Alcotest.(check bool) "cooldown active" true
    (Option.is_some snapshot.cooldown_until);
  Alcotest.(check int) "failure count recorded" 3 snapshot.total_failure

let () =
  Alcotest.run "test_local_runtime_pool"
    [
      ( "local_runtime_pool",
        [
          Alcotest.test_case "parse runtime env" `Quick test_parse_runtime_env;
          Alcotest.test_case "acquire and release" `Quick test_acquire_and_release;
          Alcotest.test_case "failure cooldown from env" `Quick
            test_failure_cooldown_from_env;
          Alcotest.test_case "record measured ceiling" `Quick
            test_record_measured_ceiling;
        ] );
    ]
