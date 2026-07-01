let contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop i =
    i + needle_len <= haystack_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let runtime_toml_with_lane =
  {|
[runtime]
default = "primary.test_model"

[runtime.lanes.resilient]
strategy = "ordered"
candidates = [ "primary.test_model", "fallback.test_model" ]

[providers.primary]
display-name = "Primary Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[providers.fallback]
display-name = "Fallback Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:2"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[primary.test_model]
is-default = true
max-concurrent = 1

[fallback.test_model]
max-concurrent = 1
|}

let runtime_toml_unknown_lane_candidate =
  {|
[runtime]
default = "primary.test_model"

[runtime.lanes.resilient]
strategy = "ordered"
candidates = [ "primary.test_model", "missing.test_model" ]

[providers.primary]
display-name = "Primary Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[primary.test_model]
is-default = true
max-concurrent = 1
|}

let runtime_toml_lane_shadows_runtime =
  {|
[runtime]
default = "primary.test_model"

[runtime.lanes."primary.test_model"]
strategy = "ordered"
candidates = [ "fallback.test_model" ]

[providers.primary]
display-name = "Primary Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[providers.fallback]
display-name = "Fallback Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:2"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[primary.test_model]
is-default = true
max-concurrent = 1

[fallback.test_model]
max-concurrent = 1
|}

let with_runtime_config toml f =
  let snapshot = Runtime.For_testing.snapshot () in
  let path = Filename.temp_file "runtime_failover_" ".toml" in
  write_file path toml;
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       match Runtime.init_default ~config_path:path with
       | Ok () -> f ()
       | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e)

let test_lane_loads_ordered_candidates () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    match Runtime.get_lane_by_id "resilient" with
    | None -> Alcotest.fail "expected lane 'resilient' to be configured"
    | Some lane ->
      Alcotest.(check string) "lane id" "resilient" (Runtime_lane.id lane);
      Alcotest.(check (list string))
        "ordered candidates"
        [ "primary.test_model"; "fallback.test_model" ]
        (Runtime_lane.ordered_candidates lane))

let test_lanes_accessor_returns_declared_lanes () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    let lanes = Runtime.lanes () in
    Alcotest.(check int) "one lane declared" 1 (List.length lanes);
    Alcotest.(check string)
      "lane id via lanes ()"
      "resilient"
      (Runtime_lane.id (List.hd lanes)))

let test_resolve_assignment_prefers_lane_over_runtime () =
  with_runtime_config runtime_toml_lane_shadows_runtime (fun () ->
    match Runtime.resolve_assignment "primary.test_model" with
    | `Missing -> Alcotest.fail "expected assignment to resolve"
    | `Single_runtime _ -> Alcotest.fail "expected lane to shadow runtime"
    | `Lane lane ->
      Alcotest.(check string)
        "lane id shadows runtime id"
        "primary.test_model"
        (Runtime_lane.id lane);
      Alcotest.(check (list string))
        "lane candidates"
        [ "fallback.test_model" ]
        (Runtime_lane.ordered_candidates lane))

let test_resolve_assignment_to_single_runtime () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    match Runtime.resolve_assignment "fallback.test_model" with
    | `Missing -> Alcotest.fail "expected runtime to resolve"
    | `Lane _ -> Alcotest.fail "expected single runtime, not lane"
    | `Single_runtime rt ->
      Alcotest.(check string) "runtime id" "fallback.test_model" rt.Runtime.id)

let test_resolve_assignment_missing () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    match Runtime.resolve_assignment "not.configured" with
    | `Missing -> ()
    | `Single_runtime _ | `Lane _ ->
      Alcotest.fail "expected missing assignment")

let test_unknown_lane_candidate_rejected_at_load () =
  let path = Filename.temp_file "runtime_failover_bad_" ".toml" in
  write_file path runtime_toml_unknown_lane_candidate;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       match Runtime.load_list ~config_path:path with
       | Ok _ -> Alcotest.fail "expected load to fail on unknown lane candidate"
       | Error msg ->
         Alcotest.(check bool)
           "error names unknown candidate"
           true
           (contains ~needle:"missing.test_model" msg))

let () =
  Alcotest.run
    "keeper_turn_driver_failover"
    [
      ( "runtime_lane_resolution"
      , [
          Alcotest.test_case
            "lane loads ordered candidate ids"
            `Quick
            test_lane_loads_ordered_candidates;
          Alcotest.test_case
            "lanes accessor returns declared lanes"
            `Quick
            test_lanes_accessor_returns_declared_lanes;
          Alcotest.test_case
            "resolve_assignment prefers lane over runtime"
            `Quick
            test_resolve_assignment_prefers_lane_over_runtime;
          Alcotest.test_case
            "resolve_assignment returns single runtime"
            `Quick
            test_resolve_assignment_to_single_runtime;
          Alcotest.test_case
            "resolve_assignment reports missing id"
            `Quick
            test_resolve_assignment_missing;
          Alcotest.test_case
            "unknown lane candidate rejected at load"
            `Quick
            test_unknown_lane_candidate_rejected_at_load;
        ] );
    ]
