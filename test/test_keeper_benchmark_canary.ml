open Alcotest
module KBC = Masc_mcp.Keeper_benchmark_canary
module KML = Masc_mcp.Keeper_model_labels
module KT = Masc_mcp.Keeper_types
module TQB = Masc_mcp.Tool_call_quality_benchmark

let with_env name value_opt f =
  let previous =
    match Sys.getenv_opt name with
    | Some value -> Some value
    | None -> None
  in
  (match value_opt with
   | Some value -> Unix.putenv name value
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some value -> Unix.putenv name value
      | None -> Unix.putenv name "")
    f
;;

let with_temp_file contents f =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "keeper-benchmark-canary-%d-%f.json"
         (Unix.getpid ())
         (Unix.gettimeofday ()))
  in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr oc;
      if Sys.file_exists path then Sys.remove path)
    (fun () ->
       output_string oc contents;
       close_out oc;
       f path)
;;

let make_meta ?(name = "analyst") ?(models = []) () =
  let base_fields =
    [ "name", `String name
    ; "agent_name", `String ("keeper-" ^ name ^ "-agent")
    ; "trace_id", `String "trace-keeper-benchmark-canary"
    ; "cascade_name", `String Masc_mcp.Keeper_config.default_cascade_name
    ; "last_model_used", `String ""
    ]
  in
  let fields =
    match models with
    | [] -> base_fields
    | _ -> ("models", `List (List.map (fun value -> `String value) models)) :: base_fields
  in
  match KT.meta_of_json (`Assoc fields) with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)
;;

let recommendation_for keeper_profile (manifest : KBC.manifest) =
  List.find_opt
    (fun (recommendation : KBC.recommendation) ->
       String.equal recommendation.keeper_profile keeper_profile)
    manifest.recommendations
;;

let test_build_manifest_picks_only_fully_passing_rows () =
  let row
        ?(cases_total = 1)
        ?(cases_passed = 1)
        ?(unsupported_runs = 0)
        ?(runtime_unreachable_runs = 0)
        ?stability_score
        ~provider
        ~model
        ~keeper_profile
        ~composite_score
        ()
    =
    { TQB.provider = Some provider
    ; model = Some model
    ; keeper_profile = Some keeper_profile
    ; cases_total
    ; cases_passed
    ; task_pass_rate = 1.0
    ; correct_tool_rate = 1.0
    ; arg_valid_rate = 1.0
    ; recovery_rate = 1.0
    ; unnecessary_tool_rate = 0.0
    ; avg_tool_calls = 1.0
    ; p95_latency_ms = 1000.0
    ; avg_input_tokens = 100.0
    ; avg_output_tokens = 50.0
    ; avg_cost_usd = 0.0
    ; composite_score
    ; unsupported_runs
    ; runtime_unreachable_runs
    ; stability_score
    ; tool_sequence_consistency_rate = stability_score
    ; prompt_fingerprint_consistency_rate = stability_score
    ; pass_consistency_rate = Some 1.0
    ; repeated_case_groups =
        (match stability_score with
         | Some _ -> 1
         | None -> 0)
    }
  in
  let summary =
    { TQB.cases_total = 4
    ; runs_total = 7
    ; scored_runs = 6
    ; unsupported_runs = 1
    ; runtime_unreachable_runs = 0
    ; unknown_case_runs = 0
    ; grouped_by_provider_model_keeper =
        [ row
            ~provider:"openai"
            ~model:"gpt-5.4"
            ~keeper_profile:"bench-analyst"
            ~composite_score:100.0
            ~cases_total:2
            ~cases_passed:2
            ~stability_score:1.0
            ()
        ; row
            ~provider:"openai"
            ~model:"gpt-5.4-mini"
            ~keeper_profile:"bench-verifier"
            ~composite_score:100.0
            ~stability_score:0.6666666667
            ()
        ; row
            ~provider:"openai"
            ~model:"gpt-5.4"
            ~keeper_profile:"bench-executor"
            ~composite_score:75.0
            ~cases_passed:0
            ()
        ]
    ; grouped_by_provider_model = []
    ; grouped_by_keeper_profile = []
    }
  in
  let manifest = KBC.build_manifest summary in
  check int "analyst+verifier only" 2 (List.length manifest.recommendations);
  let analyst =
    match recommendation_for "bench-analyst" manifest with
    | Some recommendation -> recommendation
    | None -> fail "missing bench-analyst recommendation"
  in
  check string "analyst recommended model" "openai:gpt-5.4" analyst.model_label;
  let verifier =
    match recommendation_for "bench-verifier" manifest with
    | Some recommendation -> recommendation
    | None -> fail "missing bench-verifier recommendation"
  in
  check string "verifier recommended model" "openai:gpt-5.4-mini" verifier.model_label;
  check
    bool
    "executor excluded because corpus did not fully pass"
    true
    (recommendation_for "bench-executor" manifest = None)
;;

let test_runtime_canary_prepends_recommended_model_only_without_explicit_models () =
  let manifest_json =
    { KBC.version = 1
    ; generated_at = "2026-04-21T00:00:00Z"
    ; source_summary_path = None
    ; recommendations =
        [ { KBC.keeper_profile = "bench-analyst"
          ; model_label = "test-provider:test-model"
          ; composite_score = 100.0
          ; task_pass_rate = 1.0
          ; stability_score = Some 1.0
          ; cases_total = 2
          ; cases_passed = 2
          }
        ]
    }
    |> KBC.manifest_to_yojson
    |> Yojson.Safe.pretty_to_string
  in
  with_temp_file manifest_json (fun path ->
    KBC.reset_for_testing ();
    with_env "MASC_KEEPER_BENCH_CANARY_ENABLED" (Some "true") (fun () ->
      with_env "MASC_KEEPER_BENCH_CANARY_PATH" (Some path) (fun () ->
        let recommended = KBC.recommended_model_label_for_keeper ~keeper_name:"analyst" in
        check
          (option string)
          "bare keeper name resolves bench recommendation"
          (Some "test-provider:test-model")
          recommended;
        let labels = KML.configured_model_labels_of_meta (make_meta ~name:"analyst" ()) in
        check
          string
          "recommended model is prepended"
          "test-provider:test-model"
          (List.hd labels);
        let explicit_meta =
          { (make_meta ~name:"analyst" ()) with models = [ "explicit:model" ] }
        in
        let explicit_labels = KML.configured_model_labels_of_meta explicit_meta in
        check
          (list string)
          "explicit models stay untouched"
          [ "explicit:model" ]
          explicit_labels)))
;;

let () =
  run
    "keeper_benchmark_canary"
    [ ( "keeper_benchmark_canary"
      , [ test_case
            "build manifest from summary"
            `Quick
            test_build_manifest_picks_only_fully_passing_rows
        ; test_case
            "runtime canary prepends recommendation"
            `Quick
            test_runtime_canary_prepends_recommended_model_only_without_explicit_models
        ] )
    ]
;;
