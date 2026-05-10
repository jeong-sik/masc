(** Tests for Model_inference_metrics — per-model aggregate inference stats. *)

module M = Masc_mcp.Model_inference_metrics

open Alcotest

(* ── Helpers ─────────────────────────────────────── *)

let test_dir () =
  let tmp = Filename.temp_file "masc_model_metrics" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let make_keeper_dir base name =
  let keepers = Filename.concat base ".masc/keepers" in
  let rec mkdir_p dir =
    if not (Sys.file_exists dir) then begin
      mkdir_p (Filename.dirname dir);
      Unix.mkdir dir 0o755
    end
  in
  mkdir_p keepers;
  Filename.concat keepers (name ^ ".decisions.jsonl")

let write_decisions path entries =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    List.iter (fun json ->
      output_string oc (Yojson.Safe.to_string json);
      output_char oc '\n'
    ) entries
  )

let iso_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let write_costs base entries =
  let masc_dir = Filename.concat base ".masc" in
  let rec mkdir_p dir =
    if not (Sys.file_exists dir) then begin
      mkdir_p (Filename.dirname dir);
      Unix.mkdir dir 0o755
    end
  in
  mkdir_p masc_dir;
  let path = Filename.concat masc_dir "costs.jsonl" in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    List.iter (fun json ->
      output_string oc (Yojson.Safe.to_string json);
      output_char oc '\n'
    ) entries
  )

let now_unix () = Unix.gettimeofday ()

let success_entry ~model ~ts ?(input_tokens=100) ?(output_tokens=50)
    ?(latency_ms=500) ?prompt_per_second ?peak_memory_gb
    ?provider ?provider_kind ?usage_trust ?(usage_anomaly_reasons=[])
    ?(cost_usd=0.01) ?(tools_used=[]) () =
  let extra_telemetry_fields =
    (match prompt_per_second with
     | Some v -> [("prompt_per_second", `Float v)]
     | None -> [])
    @
    (match peak_memory_gb with
     | Some v -> [("peak_memory_gb", `Float v)]
     | None -> [])
    @
    (match provider with
     | Some v -> [("provider", `String v)]
     | None -> [])
    @
    (match provider_kind with
     | Some v -> [("provider_kind", `String v)]
     | None -> [])
    @
    (match usage_trust with
     | Some v -> [("usage_trust", `String v)]
     | None -> [])
    @
    (match usage_anomaly_reasons with
     | [] -> []
     | reasons ->
         [
           ( "usage_anomaly_reasons",
             `List (List.map (fun reason -> `String reason) reasons) );
         ])
  in
  `Assoc [
    ("ts_unix", `Float ts);
    ("tool_call_count", `Int (List.length tools_used));
    ("tools_used", `List (List.map (fun s -> `String s) tools_used));
    ("telemetry", `Assoc ([
      ("model_used", `String model);
      ("tokens_per_second", `Float (Float.of_int output_tokens /. (Float.of_int latency_ms /. 1000.0)));
      ("request_latency_ms", `Int latency_ms);
      ("input_tokens", `Int input_tokens);
      ("output_tokens", `Int output_tokens);
      ("cache_read_tokens", `Int 0);
      ("reasoning_tokens", `Int 0);
      ("fallback_applied", `Bool false);
      ("cost_usd", `Float cost_usd);
    ] @ extra_telemetry_fields));
  ]

let cost_entry ~model ~ts ?(input_tokens=100) ?(output_tokens=50)
    ?(latency_ms=500) ?tokens_per_second ?provider
    ?(provider_kind="ollama") () =
  let tok_fields =
    match tokens_per_second with
    | Some v -> [("tokens_per_second", `Float v)]
    | None -> []
  in
  let provider_fields =
    match provider with
    | Some value -> [ ("provider", `String value) ]
    | None -> []
  in
  `Assoc ([
    ("timestamp", `String (iso_of_unix ts));
    ("agent", `String "keeper");
    ("provider_kind", `String provider_kind);
    ("model", `String model);
    ("input_tokens", `Int input_tokens);
    ("output_tokens", `Int output_tokens);
    ("cost_usd", `Float 0.0);
    ("usage_missing", `Bool false);
    ("source", `String "auto_trajectory");
    ("request_latency_ms", `Int latency_ms);
  ] @ provider_fields @ tok_fields)

let error_entry ~cascade_name ~ts ?provider () =
  `Assoc [
    ("ts_unix", `Float ts);
    ("tool_call_count", `Int 0);
    ("tools_used", `List []);
    ("telemetry", `Assoc [
      ("provider",
        match provider with
        | Some v -> `String v
        | None -> `Null);
      ("cascade_name", `String cascade_name);
      ("candidate_models", `List [`String "model-a"; `String "model-b"]);
      ("error_category", `String "timeout");
      ("outcome", `String "error");
    ]);
  ]

let success_entry_without_usage ~model ~ts ?provider
    ?(telemetry_reported = false)
    ?(coverage_reason = "missing_usage_and_inference")
    ?(coverage_stage = "oas")
    ?turn_lane
    ?stop_reason
    () =
  let extra_fields =
    match provider with
    | Some value -> [ ("provider", `String value) ]
    | None -> []
  in
  let diag_fields =
    [ ("usage_reported", `Bool false)
    ; ("telemetry_reported", `Bool telemetry_reported)
    ; ("coverage_reason", `String coverage_reason)
    ; ("coverage_stage", `String coverage_stage)
    ]
    @
    (match turn_lane with
     | Some value -> [ ("turn_lane", `String value) ]
     | None -> [])
    @
    (match stop_reason with
     | Some value -> [ ("stop_reason", `String value) ]
     | None -> [])
  in
  `Assoc [
    ("ts_unix", `Float ts);
    ("tool_call_count", `Int 0);
    ("tools_used", `List []);
    ("telemetry", `Assoc ([
      ("model_used", `String model);
      ("outcome", `String "success");
      ("fallback_applied", `Bool false);
    ] @ extra_fields @ diag_fields));
  ]

(* ── Tests ───────────────────────────────────────── *)

let test_empty_dir () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    check int "total_entries" 0 agg.total_entries;
    check int "total_error_entries" 0 agg.total_error_entries;
    check int "models count" 0 (List.length agg.models))

let test_single_model_success () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "luna" in
    let ts = now_unix () in
    write_decisions path [
      success_entry ~model:"claude-sonnet" ~ts:(ts -. 10.0)
        ~input_tokens:200 ~output_tokens:100 ~latency_ms:1000
        ~provider:"claude" ~cost_usd:0.005
        ~tools_used:["shell"; "read"] ();
      success_entry ~model:"claude-sonnet" ~ts:(ts -. 5.0)
        ~input_tokens:150 ~output_tokens:80 ~latency_ms:800
        ~provider:"claude" ~cost_usd:0.003 ~tools_used:["shell"] ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    check int "total_entries" 2 agg.total_entries;
    check int "total_error_entries" 0 agg.total_error_entries;
    check int "models" 1 (List.length agg.models);
    let s = List.hd agg.models in
    check string "model_id" "claude-sonnet" s.model_id;
    check (option string) "provider" (Some "claude") s.provider;
    check int "entry_count" 2 s.entry_count;
    check int "success_count" 2 s.success_count;
    check int "error_count" 0 s.error_count;
    check (option int) "total_input_tokens" (Some 350) s.total_input_tokens;
    check (option int) "total_output_tokens" (Some 180) s.total_output_tokens;
    check int "usage samples" 2 s.usage_sample_count;
    check int "telemetry samples" 2 s.telemetry_sample_count;
    check int "total_tool_calls" 3 s.total_tool_calls;
    check bool "cost > 0" true
      (Option.value ~default:0.0 s.total_cost_usd > 0.0);
    check bool "avg_tool_calls > 0" true (s.avg_tool_calls_per_turn > 0.0);
    check bool "latency > 0" true
      (Option.value ~default:0.0 s.avg_latency_ms > 0.0);
    check bool "tok/s > 0" true
      (Option.value ~default:0.0 s.avg_tok_per_sec > 0.0))

let test_provider_kind_classifies_bare_model_provider () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "kinded" in
    let ts = now_unix () in
    let provider_kind =
      Llm_provider.Provider_config.string_of_provider_kind
        Llm_provider.Provider_config.Kimi_cli
    in
    write_decisions path [
      success_entry ~model:"kimi-k2.5" ~ts:(ts -. 5.0)
        ~provider_kind ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    check int "total_entries" 1 agg.total_entries;
    let s = List.hd agg.models in
    check string "model stays bare" "kimi-k2.5" s.model_id;
    check (option string) "provider from provider_kind"
      (Some "kimi_cli") s.provider;
    let recent = List.hd s.recent_entries in
    check (option string) "recent provider from provider_kind"
      (Some "kimi_cli") recent.re_provider;
    let rollup = M.provider_rollup agg in
    check int "provider rollup keeps entry" 1 (List.length rollup);
    check string "rollup provider" "kimi_cli"
      (List.hd rollup).M.ps_provider)

let test_untrusted_usage_excluded_from_aggregates () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "meter" in
    let ts = now_unix () in
    write_decisions path [
      success_entry ~model:"llama:qwen3.5-27b" ~ts:(ts -. 10.0)
        ~input_tokens:100 ~output_tokens:20 ~latency_ms:1000 ();
      success_entry ~model:"llama:qwen3.5-27b" ~ts:(ts -. 5.0)
        ~input_tokens:1_721_506 ~output_tokens:900 ~latency_ms:1000
        ~usage_trust:"untrusted"
        ~usage_anomaly_reasons:["input_tokens_gt_1m"] ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    check int "total entries retained for diagnosis" 2 agg.total_entries;
    check int "models" 1 (List.length agg.models);
    let s = List.hd agg.models in
    check (option int) "trusted input total only" (Some 100)
      s.total_input_tokens;
    check (option int) "trusted output total only" (Some 20)
      s.total_output_tokens;
    check int "usage sample count excludes untrusted" 1 s.usage_sample_count;
    check int "usage missing counts untrusted" 1 s.usage_missing_count;
    check (option (float 0.001)) "tok/s excludes untrusted outlier"
      (Some 20.0) s.avg_tok_per_sec;
    check (option string) "coverage flags untrusted usage"
      (Some "untrusted_usage") s.primary_coverage_reason;
    let recent = List.hd s.recent_entries in
    check (option string) "recent usage trust" (Some "untrusted")
      recent.re_usage_trust;
    check (option int) "recent untrusted input hidden" None
      recent.re_input_tokens;
    check (list string) "recent anomaly reasons"
      ["input_tokens_gt_1m"] recent.re_usage_anomaly_reasons)

let test_error_turns_counted () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "dreamer" in
    let ts = now_unix () in
    write_decisions path [
      success_entry ~model:"qwen-35b" ~ts:(ts -. 20.0) ();
      error_entry ~cascade_name:"local_only" ~ts:(ts -. 10.0) ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    check int "total_entries" 2 agg.total_entries;
    check int "total_error_entries" 1 agg.total_error_entries;
    (* Error attributed to first candidate "model-a" *)
    let error_model = List.find_opt (fun (s : M.model_stats) ->
      s.model_id = "model-a") agg.models in
    check bool "error model found" true (Option.is_some error_model);
    let em = Option.get error_model in
    check (option string) "error provider unresolved" None em.provider;
    check int "error_count" 1 em.error_count;
    check int "success_count" 0 em.success_count;
    check (option (float 0.001)) "error model latency unknown" None em.avg_latency_ms;
    check (option int) "error model input unknown" None em.total_input_tokens;
    check (option (float 0.001)) "error model cost unknown" None em.total_cost_usd)

let test_multi_model () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "multi" in
    let ts = now_unix () in
    write_decisions path [
      success_entry ~model:"claude-sonnet" ~ts:(ts -. 30.0)
        ~tools_used:["read"; "write"] ();
      success_entry ~model:"gpt-4o" ~ts:(ts -. 20.0)
        ~tools_used:["search"] ();
      success_entry ~model:"claude-sonnet" ~ts:(ts -. 10.0)
        ~tools_used:["read"] ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    check int "total_entries" 3 agg.total_entries;
    check int "models" 2 (List.length agg.models);
    (* claude-sonnet has 2 entries, should be first (sorted by entry_count desc) *)
    let first = List.hd agg.models in
    check string "first model" "claude-sonnet" first.model_id;
    check int "first entry_count" 2 first.entry_count)

let test_top_tools_per_model () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "tooler" in
    let ts = now_unix () in
    write_decisions path [
      success_entry ~model:"m1" ~ts:(ts -. 30.0)
        ~tools_used:["shell"; "shell"; "read"] ();
      success_entry ~model:"m1" ~ts:(ts -. 20.0)
        ~tools_used:["shell"; "write"] ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let s = List.hd agg.models in
    check bool "has top_tools" true (List.length s.top_tools > 0);
    (* shell should be #1 with count 3 *)
    let (top_tool, top_count) = List.hd s.top_tools in
    check string "top tool" "shell" top_tool;
    check int "top count" 3 top_count)

let test_recent_entries () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "recent" in
    let ts = now_unix () in
    write_decisions path (
      List.init 8 (fun i ->
        success_entry ~model:"m1" ~ts:(ts -. Float.of_int (i * 10))
          ~input_tokens:(100 + i * 10) ~output_tokens:50
          ~latency_ms:500 ~cost_usd:0.01 ())
    );
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let s = List.hd agg.models in
    check int "recent_entries capped at 5" 5 (List.length s.recent_entries);
    (* First recent entry should be the most recent (highest ts_unix) *)
    let first_re = List.hd s.recent_entries in
    check bool "most recent first" true (first_re.re_ts_unix >= (ts -. 1.0)))

let test_window_filter () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "window" in
    let ts = now_unix () in
    write_decisions path [
      success_entry ~model:"m1" ~ts:(ts -. 30.0) ();       (* within 1 min *)
      success_entry ~model:"m1" ~ts:(ts -. 120.0) ();      (* outside 1 min *)
    ];
    let agg = M.compute ~base_path:base ~window_minutes:1 in
    check int "only recent entry" 1 agg.total_entries)

let test_json_roundtrip () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "json" in
    let ts = now_unix () in
    write_decisions path [
      success_entry ~model:"test-model" ~ts:(ts -. 10.0)
        ~tools_used:["t1"] ~cost_usd:0.05 ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let json = M.to_json agg in
    let open Yojson.Safe.Util in
    let models = json |> member "models" |> to_list in
    check bool "has models" true (List.length models > 0);
    let m = List.hd models in
    check bool "provider unresolved -> null" true
      (match m |> member "provider" with `Null -> true | _ -> false);
    check int "success_count" 1 (m |> member "success_count" |> to_int);
    check int "usage_sample_count" 1
      (m |> member "usage_sample_count" |> to_int);
    check bool "total_cost_usd = 0.05" true
      (Float.abs (m |> member "total_cost_usd" |> to_float) -. 0.05 < 0.001);
    check bool "has top_tools list" true
      (match m |> member "top_tools" with `List _ -> true | _ -> false);
    check bool "has recent_entries list" true
      (match m |> member "recent_entries" with `List _ -> true | _ -> false);
    check int "total_error_entries" 0
      (json |> member "total_error_entries" |> to_int))

let test_prompt_tps_and_peak_memory_aggregates () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "mlx_vlm" in
    let ts = now_unix () in
    write_decisions path [
      success_entry ~model:"mlx-vlm" ~ts:(ts -. 15.0)
        ~prompt_per_second:1200.0 ~peak_memory_gb:18.5 ();
      success_entry ~model:"mlx-vlm" ~ts:(ts -. 5.0)
        ~prompt_per_second:1500.0 ~peak_memory_gb:20.25 ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let s = List.hd agg.models in
    check bool "prompt avg present" true (Option.is_some s.prompt_avg_tok_per_sec);
    check (float 0.001) "prompt avg" 1350.0
      (Option.value ~default:0.0 s.prompt_avg_tok_per_sec);
    check (float 0.001) "prompt p50" 1350.0
      (Option.value ~default:0.0 s.prompt_p50_tok_per_sec);
    check (float 0.001) "prompt p95" 1485.0
      (Option.value ~default:0.0 s.prompt_p95_tok_per_sec);
    check (float 0.001) "max peak mem" 20.25
      (Option.value ~default:0.0 s.max_peak_memory_gb);
    let first_recent = List.hd s.recent_entries in
    check (option string) "recent provider derived"
      None first_recent.re_provider;
    check (float 0.001) "recent prompt tok/s" 1500.0
      (Option.value ~default:0.0 first_recent.re_prompt_tok_per_sec);
    check (float 0.001) "recent peak memory" 20.25
      (Option.value ~default:0.0 first_recent.re_peak_memory_gb);
    let json = M.to_json agg in
    let open Yojson.Safe.Util in
    let m = json |> member "models" |> to_list |> List.hd in
    check (float 0.001) "prompt avg json" 1350.0
      (m |> member "prompt_avg_tok_per_sec" |> to_float);
    check (float 0.001) "max peak mem json" 20.25
      (m |> member "max_peak_memory_gb" |> to_float);
    let recent = m |> member "recent_entries" |> to_list |> List.hd in
    check bool "recent provider null" true
      (match recent |> member "provider" with `Null -> true | _ -> false);
    check (float 0.001) "recent prompt json" 1500.0
      (recent |> member "prompt_tok_per_sec" |> to_float);
    check (float 0.001) "recent peak mem json" 20.25
      (recent |> member "peak_memory_gb" |> to_float))

let test_missing_usage_serializes_unknowns () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "missing_usage" in
    let ts = now_unix () in
    write_decisions path [
      success_entry_without_usage ~model:"kimi-for-coding" ~ts:(ts -. 5.0)
        ~provider:"kimi_cli" ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let s = List.hd agg.models in
    check int "success_count" 1 s.success_count;
    check int "usage samples" 0 s.usage_sample_count;
    check int "telemetry samples" 0 s.telemetry_sample_count;
    check (option int) "input unknown" None s.total_input_tokens;
    check (option (float 0.001)) "latency unknown" None s.avg_latency_ms;
    check (option (float 0.001)) "cost unknown" None s.total_cost_usd;
    let recent = List.hd s.recent_entries in
    check (option int) "recent input unknown" None recent.re_input_tokens;
    check (option (float 0.001)) "recent latency unknown" None recent.re_latency_ms;
    let json = M.to_json agg in
    let open Yojson.Safe.Util in
    let m = json |> member "models" |> to_list |> List.hd in
    check bool "json input null" true
      (match m |> member "total_input_tokens" with `Null -> true | _ -> false);
    check bool "json latency null" true
      (match m |> member "avg_latency_ms" with `Null -> true | _ -> false);
    let recent_json = m |> member "recent_entries" |> to_list |> List.hd in
    check bool "recent json input null" true
      (match recent_json |> member "input_tokens" with `Null -> true | _ -> false))

let test_coverage_diagnostics_survive_aggregation () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "coverage_diag" in
    let ts = now_unix () in
    write_decisions path [
      success_entry_without_usage ~model:"glm-coding-plan:glm-5"
        ~ts:(ts -. 5.0)
        ~provider:"glm-coding"
        ~turn_lane:"text_only"
        ~stop_reason:"turn_budget_exhausted(3/3)"
        ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let s = List.hd agg.models in
    check string "coverage status" "none" s.coverage_status;
    check int "usage missing count" 1 s.usage_missing_count;
    check int "telemetry missing count" 1 s.telemetry_missing_count;
    check (option string) "primary coverage reason"
      (Some "missing_usage_and_inference")
      s.primary_coverage_reason;
    check (option string) "primary coverage stage"
      (Some "oas")
      s.primary_coverage_stage;
    check int "coverage reason counts" 1 (List.length s.coverage_reason_counts);
    let recent = List.hd s.recent_entries in
    check string "recent outcome" "success" recent.re_outcome;
    check (option string) "recent stop reason"
      (Some "turn_budget_exhausted(3/3)")
      recent.re_stop_reason;
    check (option string) "recent turn lane"
      (Some "text_only")
      recent.re_turn_lane;
    check (option bool) "recent usage_reported"
      (Some false) recent.re_usage_reported;
    check (option bool) "recent telemetry_reported"
      (Some false) recent.re_telemetry_reported;
    check (option string) "recent coverage reason"
      (Some "missing_usage_and_inference")
      recent.re_coverage_reason;
    check (option string) "recent coverage stage"
      (Some "oas")
      recent.re_coverage_stage;
    let json = M.to_json agg in
    let open Yojson.Safe.Util in
    let m = json |> member "models" |> to_list |> List.hd in
    check string "json coverage status" "none"
      (m |> member "coverage_status" |> to_string);
    check int "json usage missing count" 1
      (m |> member "usage_missing_count" |> to_int);
    check int "json telemetry missing count" 1
      (m |> member "telemetry_missing_count" |> to_int);
    check string "json primary coverage reason"
      "missing_usage_and_inference"
      (m |> member "primary_coverage_reason" |> to_string);
    check string "json primary coverage stage"
      "oas"
      (m |> member "primary_coverage_stage" |> to_string);
    let reason_counts = m |> member "coverage_reason_counts" |> to_list in
    check int "json reason count length" 1 (List.length reason_counts);
    check string "json reason count reason"
      "missing_usage_and_inference"
      (List.hd reason_counts |> member "reason" |> to_string);
    let recent_json = m |> member "recent_entries" |> to_list |> List.hd in
    check string "recent json outcome" "success"
      (recent_json |> member "outcome" |> to_string);
    check string "recent json stage" "oas"
      (recent_json |> member "coverage_stage" |> to_string))

let test_costs_jsonl_backfills_wall_tok_per_sec () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let ts = now_unix () in
    write_costs base [
      cost_entry ~model:"qwen3.6:27b-coding-nvfp4" ~ts
        ~input_tokens:100 ~output_tokens:50 ~latency_ms:250 ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let s = List.hd agg.models in
    check string "cost model"
      "ollama:qwen3.6:27b-coding-nvfp4" s.model_id;
    check int "one cost entry" 1 s.entry_count;
    check (option (float 0.001)) "wall tok/sec from cost latency"
      (Some 200.0) s.avg_tok_per_sec;
    check int "usage sample" 1 s.usage_sample_count;
    check int "telemetry sample" 1 s.telemetry_sample_count)

let test_costs_jsonl_zero_latency_is_missing () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let ts = now_unix () in
    write_costs base [
      cost_entry ~model:"qwen3.6:27b-coding-nvfp4" ~ts
        ~input_tokens:100 ~output_tokens:50 ~latency_ms:0 ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let s = List.hd agg.models in
    check int "one cost entry" 1 s.entry_count;
    check (option (float 0.001)) "zero latency not averaged"
      None s.avg_latency_ms;
    check (option (float 0.001)) "zero latency not p50"
      None s.p50_latency_ms;
    check (option (float 0.001)) "zero latency does not derive tok/sec"
      None s.avg_tok_per_sec;
    check int "usage sample preserved" 1 s.usage_sample_count;
    check int "telemetry sample absent" 0 s.telemetry_sample_count;
    let recent = List.hd s.recent_entries in
    check (option (float 0.001)) "recent latency unknown"
      None recent.re_latency_ms;
    let bucket_total =
      List.fold_left
        (fun acc (bucket : M.latency_bucket) -> acc + bucket.count)
        0 agg.latency_buckets
    in
    check int "zero latency skipped from buckets" 0 bucket_total)

let test_costs_jsonl_dedupes_matching_decision_sample () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "dedupe" in
    let ts = now_unix () in
    write_decisions path [
      success_entry ~model:"ollama:qwen3.6:27b-coding-nvfp4" ~ts
        ~input_tokens:100 ~output_tokens:50 ~latency_ms:500 ();
    ];
    write_costs base [
      cost_entry ~model:"ollama:qwen3.6:27b-coding-nvfp4" ~ts
        ~input_tokens:100 ~output_tokens:50 ~latency_ms:250 ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let s = List.hd agg.models in
    check int "matching cost sample deduped" 1 s.entry_count;
    check (option (float 0.001)) "decision tok/sec preserved"
      (Some 100.0) s.avg_tok_per_sec)

let test_cost_latency_json_composes_axes_and_percentiles () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "cost_latency" in
    let ts = now_unix () in
    write_decisions path [
      success_entry ~model:"claude-sonnet" ~provider:"anthropic"
        ~ts:(ts -. 30.0)
        ~input_tokens:100 ~output_tokens:50 ~latency_ms:100
        ~cost_usd:0.03 ();
      success_entry ~model:"claude-sonnet" ~provider:"anthropic"
        ~ts:(ts -. 20.0)
        ~input_tokens:10 ~output_tokens:5 ~latency_ms:200
        ~cost_usd:0.02 ();
      success_entry ~model:"gpt-4o" ~provider:"openai"
        ~ts:(ts -. 10.0)
        ~input_tokens:20 ~output_tokens:10 ~latency_ms:1000
        ~cost_usd:0.01 ();
    ];
    let json = M.compute_cost_latency_json ~base_path:base ~window_minutes:60 in
    let open Yojson.Safe.Util in
    let per_agent = json |> member "perAgent" |> to_list in
    check int "perAgent row count" 2 (List.length per_agent);
    let first = List.hd per_agent in
    check string "highest cost first" "claude-sonnet"
      (first |> member "agent" |> to_string);
    check int "input tokens summed" 110
      (first |> member "in_tok" |> to_int);
    check int "output tokens summed" 55
      (first |> member "out_tok" |> to_int);
    check (float 0.001) "cost summed" 0.05
      (first |> member "cost" |> to_float);

    let matrix = json |> member "matrix" in
    check (list string) "provider axis sorted"
      ["anthropic"; "openai"]
      (matrix |> member "providers" |> to_list |> List.map to_string);
    check (list string) "model axis follows model aggregate order"
      ["claude-sonnet"; "gpt-4o"]
      (matrix |> member "models" |> to_list |> List.map to_string);
    let grid = matrix |> member "grid" |> to_list in
    let row0 = List.nth grid 0 |> to_list |> List.map to_float in
    let row1 = List.nth grid 1 |> to_list |> List.map to_float in
    check (list (float 0.001)) "anthropic row costs" [0.05; 0.0] row0;
    check (list (float 0.001)) "openai row costs" [0.0; 0.01] row1;

    check (float 0.001) "global p50" 200.0
      (json |> member "p50" |> to_float);
    check (float 0.001) "global p95" 920.0
      (json |> member "p95" |> to_float);
    check (float 0.001) "global cost" 0.06
      (json |> member "total_cost_usd" |> to_float);
    check int "window" 60
      (json |> member "window_minutes" |> to_int);
    let buckets = json |> member "latencyBuckets" |> to_list in
    check int "bucket count" 4 (List.length buckets);
    check int "sub-second bucket count" 2
      (List.hd buckets |> member "n" |> to_int);
    check int "1s-4s bucket count" 1
      (List.nth buckets 1 |> member "n" |> to_int))

let test_cost_latency_json_preserves_missing_latency_as_null () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "cost_latency_missing" in
    let ts = now_unix () in
    write_decisions path [
      `Assoc [
        ("ts_unix", `Float (ts -. 10.0));
        ("tool_call_count", `Int 0);
        ("tools_used", `List []);
        ("telemetry", `Assoc [
          ("model_used", `String "unlatenced-model");
          ("provider", `String "local");
          ("input_tokens", `Int 100);
          ("output_tokens", `Int 50);
          ("cost_usd", `Float 0.01);
        ]);
      ];
    ];
    let json = M.compute_cost_latency_json ~base_path:base ~window_minutes:60 in
    let open Yojson.Safe.Util in
    let per_agent = json |> member "perAgent" |> to_list in
    check int "perAgent row count" 1 (List.length per_agent);
    let row = List.hd per_agent in
    check bool "per-agent p50 missing is null" true
      (match row |> member "p50_ms" with `Null -> true | _ -> false);
    check bool "per-agent p95 missing is null" true
      (match row |> member "p95_ms" with `Null -> true | _ -> false);
    check bool "global p50 missing is null" true
      (match json |> member "p50" with `Null -> true | _ -> false);
    check bool "global p95 missing is null" true
      (match json |> member "p95" with `Null -> true | _ -> false))

(* ── thinking_fraction tests ─────────────────────── *)

let success_entry_with_thinking ~model ~ts ~thinking_enabled () =
  let thinking_field = match thinking_enabled with
    | Some b -> [("thinking_enabled", `Bool b)]
    | None -> []
  in
  `Assoc [
    ("ts_unix", `Float ts);
    ("tool_call_count", `Int 0);
    ("tools_used", `List []);
    ("telemetry", `Assoc ([
      ("model_used", `String model);
      ("tokens_per_second", `Float 10.0);
      ("request_latency_ms", `Int 500);
      ("input_tokens", `Int 100);
      ("output_tokens", `Int 50);
      ("cache_read_tokens", `Int 0);
      ("reasoning_tokens", `Int 0);
      ("fallback_applied", `Bool false);
      ("cost_usd", `Float 0.01);
    ] @ thinking_field));
  ]

let test_thinking_fraction_mixed () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "thinking_mixed" in
    let ts = now_unix () in
    (* 3 true + 5 false reported, 2 missing. fraction = 3 / (3+5) = 0.375 *)
    let entries =
      List.init 3 (fun i ->
        success_entry_with_thinking ~model:"m1"
          ~ts:(ts -. Float.of_int (i * 5))
          ~thinking_enabled:(Some true) ())
      @ List.init 5 (fun i ->
        success_entry_with_thinking ~model:"m1"
          ~ts:(ts -. Float.of_int ((i + 3) * 5))
          ~thinking_enabled:(Some false) ())
      @ List.init 2 (fun i ->
        success_entry_with_thinking ~model:"m1"
          ~ts:(ts -. Float.of_int ((i + 8) * 5))
          ~thinking_enabled:None ())
    in
    write_decisions path entries;
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let s = List.hd agg.models in
    check int "entry_count" 10 s.entry_count;
    check bool "thinking_fraction present" true
      (Option.is_some s.thinking_fraction);
    let f = Option.get s.thinking_fraction in
    check (float 0.001) "thinking_fraction = 3/8" 0.375 f)

let test_thinking_fraction_all_missing () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "thinking_missing" in
    let ts = now_unix () in
    write_decisions path [
      success_entry_with_thinking ~model:"m1" ~ts:(ts -. 5.0)
        ~thinking_enabled:None ();
      success_entry_with_thinking ~model:"m1" ~ts:(ts -. 10.0)
        ~thinking_enabled:None ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let s = List.hd agg.models in
    check bool "thinking_fraction None" true
      (Option.is_none s.thinking_fraction))

let test_thinking_fraction_json_serialization () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "thinking_json" in
    let ts = now_unix () in
    write_decisions path [
      success_entry_with_thinking ~model:"m1" ~ts:(ts -. 5.0)
        ~thinking_enabled:(Some true) ();
      success_entry_with_thinking ~model:"m1" ~ts:(ts -. 10.0)
        ~thinking_enabled:(Some false) ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let json = M.to_json agg in
    let open Yojson.Safe.Util in
    let models = json |> member "models" |> to_list in
    let m = List.hd models in
    check (float 0.001) "thinking_fraction in JSON"
      0.5 (m |> member "thinking_fraction" |> to_float))

(* ── Bucket tests ───────────────────────────────── *)

let success_entry_with_cache ~model ~ts ?(input_tokens=100) ~cache_read () =
  `Assoc [
    ("ts_unix", `Float ts);
    ("tool_call_count", `Int 0);
    ("tools_used", `List []);
    ("telemetry", `Assoc [
      ("model_used", `String model);
      ("tokens_per_second", `Float 10.0);
      ("request_latency_ms", `Int 500);
      ("input_tokens", `Int input_tokens);
      ("output_tokens", `Int 50);
      ("cache_read_tokens", `Int cache_read);
      ("reasoning_tokens", `Int 0);
      ("fallback_applied", `Bool false);
      ("cost_usd", `Float 0.01);
    ]);
  ]

let test_buckets_empty_dir () =
  let dir = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let result = M.aggregate_buckets ~base_path:dir ~window_min:60 ~bucket_min:5 in
    check int "empty → no models" 0 (List.length result))

let test_buckets_single_bucket () =
  let dir = test_dir () in
  let path = make_keeper_dir dir "single_bucket" in
  let now = now_unix () in
  write_decisions path [
    success_entry ~model:"model-a" ~ts:now ();
    success_entry ~model:"model-a" ~ts:(now -. 30.0) ();
  ];
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let result = M.aggregate_buckets ~base_path:dir ~window_min:60 ~bucket_min:60 in
    check int "one model" 1 (List.length result);
    let m = List.hd result in
    check string "model_id" "model-a" m.mb_model_id;
    check int "one bucket (60min window, 60min bucket)" 1 (List.length m.mb_buckets))

let test_buckets_sparse () =
  let dir = test_dir () in
  let path = make_keeper_dir dir "sparse" in
  let now = now_unix () in
  write_decisions path [
    success_entry ~model:"model-b" ~ts:now ();
    success_entry ~model:"model-b" ~ts:(now -. 600.0) ();
  ];
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let result = M.aggregate_buckets ~base_path:dir ~window_min:60 ~bucket_min:5 in
    check int "one model" 1 (List.length result);
    let m = List.hd result in
    check bool "sparse → 2 distinct buckets (10min apart, 5min width)"
      true (List.length m.mb_buckets >= 2))

let test_buckets_cache_hit_ratio_zero_denom () =
  let dir = test_dir () in
  let path = make_keeper_dir dir "cache_zero" in
  let now = now_unix () in
  write_decisions path [
    success_entry_with_cache ~model:"model-c" ~ts:now ~input_tokens:0 ~cache_read:0 ();
  ];
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let result = M.aggregate_buckets ~base_path:dir ~window_min:60 ~bucket_min:60 in
    check int "one model" 1 (List.length result);
    let m = List.hd result in
    let b = List.hd m.mb_buckets in
    check bool "cache_hit_ratio present" true (Option.is_some b.b_cache_hit_ratio);
    check bool "cache_hit_ratio not NaN" true
      (not (Float.is_nan (Option.value ~default:0.0 b.b_cache_hit_ratio)));
    check (option (float 0.001)) "cache_hit_ratio = 0.0 when both tokens=0"
      (Some 0.0) b.b_cache_hit_ratio)

let test_buckets_with_compute () =
  let dir = test_dir () in
  let path = make_keeper_dir dir "bucketed_compute" in
  let now = now_unix () in
  write_decisions path [
    success_entry ~model:"model-x" ~ts:now ();
  ];
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let agg = M.compute_with_buckets ~base_path:dir ~window_minutes:60 ~bucket_minutes:5 in
    check int "bucket_minutes populated" 5 agg.bucket_minutes;
    let m = List.hd agg.models in
    check bool "model_stats.buckets non-empty" true (List.length m.buckets > 0);
    let b = List.hd m.buckets in
    check int "bucket entry_count" 1 b.b_entry_count)

(* ── provider_rollup ─────────────────────────────── *)

(* We build aggregates by hand instead of going through [M.compute] so
   these tests verify only the rollup math (weighted means, entry_count
   sums, model_count grouping) without depending on the jsonl parser.
   That keeps the assertions robust to future changes in decisions.jsonl
   shape. *)

let zero_model_stats (model_id : string) ~provider ~entry_count
    : M.model_stats =
  {
    model_id;
    provider;
    entry_count;
    avg_tok_per_sec = None;
    p50_tok_per_sec = None;
    p95_tok_per_sec = None;
    prompt_avg_tok_per_sec = None;
    prompt_p50_tok_per_sec = None;
    prompt_p95_tok_per_sec = None;
    hw_decode_avg_tok_per_sec = None;
    hw_decode_p50_tok_per_sec = None;
    hw_decode_p95_tok_per_sec = None;
    max_peak_memory_gb = None;
    thinking_fraction = None;
    avg_latency_ms = None;
    p50_latency_ms = None;
    p95_latency_ms = None;
    total_input_tokens = None;
    total_output_tokens = None;
    total_cache_read_tokens = None;
    total_reasoning_tokens = None;
    usage_sample_count = entry_count;
    telemetry_sample_count = entry_count;
    usage_missing_count = 0;
    telemetry_missing_count = 0;
    coverage_status = "full";
    primary_coverage_stage = None;
    primary_coverage_reason = None;
    coverage_reason_counts = [];
    fallback_count = 0;
    success_count = entry_count;
    error_count = 0;
    total_cost_usd = None;
    avg_tool_calls_per_turn = 0.0;
    total_tool_calls = 0;
    top_tools = [];
    recent_entries = [];
    buckets = [];
  }

let test_provider_rollup_empty_aggregate () =
  let agg : M.aggregate =
    { window_minutes = 30
    ; bucket_minutes = 0
    ; models = []
    ; total_entries = 0
    ; total_error_entries = 0
    ; latency_buckets = []
    }
  in
  check int "empty models gives empty rollup" 0
    (List.length (M.provider_rollup agg))

let test_provider_rollup_skips_unknown_provider () =
  let m1 = zero_model_stats "glm-coding:auto" ~provider:(Some "glm-coding")
             ~entry_count:5 in
  let m2 = zero_model_stats "bare-model" ~provider:None ~entry_count:3 in
  let agg : M.aggregate =
    { window_minutes = 30; bucket_minutes = 0; models = [m1; m2]
    ; total_entries = 8; total_error_entries = 0; latency_buckets = [] }
  in
  let rollup = M.provider_rollup agg in
  check int "only provider=Some survives" 1 (List.length rollup);
  let stats = List.hd rollup in
  check string "provider" "glm-coding" stats.ps_provider;
  check int "entry_count" 5 stats.ps_entry_count

let test_provider_rollup_weighted_mean () =
  (* Two models on the same provider with different entry_counts should
     produce an entry-weighted mean, not a simple average:
     (100 * 20 + 50 * 80) / (20 + 80) = (2000 + 4000) / 100 = 60.0 *)
  let m1 =
    { (zero_model_stats "ollama:qwen3.6" ~provider:(Some "ollama")
                         ~entry_count:20)
      with avg_tok_per_sec = Some 100.0 }
  in
  let m2 =
    { (zero_model_stats "ollama:qwen3.5" ~provider:(Some "ollama")
                         ~entry_count:80)
      with avg_tok_per_sec = Some 50.0 }
  in
  let agg : M.aggregate =
    { window_minutes = 30; bucket_minutes = 0; models = [m1; m2]
    ; total_entries = 100; total_error_entries = 0; latency_buckets = [] }
  in
  let rollup = M.provider_rollup agg in
  let stats = List.hd rollup in
  check int "merged entry_count" 100 stats.ps_entry_count;
  check int "model_count" 2 stats.ps_model_count;
  (match stats.ps_avg_tok_per_sec with
   | Some v ->
     (* Alcotest doesn't export float approx eq by default; allow 0.01. *)
     if Float.abs (v -. 60.0) > 0.01 then
       failf "weighted mean expected ~60.0 but got %f" v
   | None -> fail "weighted mean should be Some")

let test_provider_rollup_all_none_yields_none () =
  (* Two models with every perf field None — the rollup must not
     invent zeros where upstream reported nothing. *)
  let m1 = zero_model_stats "x:1" ~provider:(Some "x") ~entry_count:5 in
  let m2 = zero_model_stats "x:2" ~provider:(Some "x") ~entry_count:5 in
  let agg : M.aggregate =
    { window_minutes = 30; bucket_minutes = 0; models = [m1; m2]
    ; total_entries = 10; total_error_entries = 0; latency_buckets = [] }
  in
  let rollup = M.provider_rollup agg in
  let stats = List.hd rollup in
  check (option (float 0.0001)) "avg_tok_per_sec stays None"
    None stats.ps_avg_tok_per_sec;
  check (option (float 0.0001)) "avg_prompt_tok_per_sec stays None"
    None stats.ps_avg_prompt_tok_per_sec;
  check (option (float 0.0001)) "p95_latency_ms stays None"
    None stats.ps_p95_latency_ms

let test_provider_rollup_sort_by_entry_count_desc () =
  let a = zero_model_stats "a:1" ~provider:(Some "a") ~entry_count:3 in
  let b = zero_model_stats "b:1" ~provider:(Some "b") ~entry_count:10 in
  let c = zero_model_stats "c:1" ~provider:(Some "c") ~entry_count:7 in
  let agg : M.aggregate =
    { window_minutes = 30; bucket_minutes = 0; models = [a; b; c]
    ; total_entries = 20; total_error_entries = 0; latency_buckets = [] }
  in
  let rollup = M.provider_rollup agg in
  let names = List.map (fun s -> s.M.ps_provider) rollup in
  check (list string) "sorted by entry_count desc" ["b"; "c"; "a"] names

let test_provider_rollup_json_shape () =
  let m =
    { (zero_model_stats "kimi_cli:kimi" ~provider:(Some "kimi_cli")
                         ~entry_count:42)
      with avg_tok_per_sec = Some 25.0
         ; prompt_avg_tok_per_sec = Some 180.0
         ; p95_latency_ms = Some 3200.0 }
  in
  let agg : M.aggregate =
    { window_minutes = 30; bucket_minutes = 0; models = [m]
    ; total_entries = 42; total_error_entries = 0; latency_buckets = [] }
  in
  let json = M.provider_stats_to_json (List.hd (M.provider_rollup agg)) in
  match json with
  | `Assoc fields ->
    check string "provider"
      (match List.assoc "provider" fields with `String s -> s | _ -> "!")
      "kimi_cli";
    check int "request_count surfaces entry_count"
      42
      (match List.assoc "entry_count" fields with `Int n -> n | _ -> -1);
    (match List.assoc "avg_prompt_tok_per_sec" fields with
     | `Float f when Float.abs (f -. 180.0) < 0.01 -> ()
     | _ -> fail "avg_prompt_tok_per_sec should be Float 180.0")
  | _ -> fail "provider_stats_to_json should return an Assoc"

(* ── Runner ──────────────────────────────────────── *)

let () =
  run "Model_inference_metrics" [
    "basics", [
      test_case "empty dir" `Quick test_empty_dir;
      test_case "single model success" `Quick test_single_model_success;
      test_case "provider_kind classifies bare model provider" `Quick
        test_provider_kind_classifies_bare_model_provider;
      test_case "untrusted usage excluded from aggregates" `Quick
        test_untrusted_usage_excluded_from_aggregates;
      test_case "error turns counted" `Quick test_error_turns_counted;
      test_case "multi model sorted" `Quick test_multi_model;
      test_case "window filter" `Quick test_window_filter;
    ];
    "enrichment", [
      test_case "top tools per model" `Quick test_top_tools_per_model;
      test_case "recent entries capped" `Quick test_recent_entries;
      test_case "prompt tps and peak memory aggregates" `Quick test_prompt_tps_and_peak_memory_aggregates;
      test_case "missing usage serializes unknowns" `Quick test_missing_usage_serializes_unknowns;
      test_case "coverage diagnostics survive aggregation" `Quick test_coverage_diagnostics_survive_aggregation;
      test_case "costs.jsonl backfills wall tok/sec" `Quick test_costs_jsonl_backfills_wall_tok_per_sec;
      test_case "costs.jsonl zero latency stays missing" `Quick test_costs_jsonl_zero_latency_is_missing;
      test_case "costs.jsonl dedupes matching decision sample" `Quick test_costs_jsonl_dedupes_matching_decision_sample;
      test_case "cost latency json composes axes and percentiles" `Quick test_cost_latency_json_composes_axes_and_percentiles;
      test_case "cost latency json preserves missing latency nulls" `Quick test_cost_latency_json_preserves_missing_latency_as_null;
      test_case "json roundtrip" `Quick test_json_roundtrip;
    ];
    "thinking_fraction", [
      test_case "mixed reported yields fraction" `Quick test_thinking_fraction_mixed;
      test_case "all missing yields None" `Quick test_thinking_fraction_all_missing;
      test_case "json serialization" `Quick test_thinking_fraction_json_serialization;
    ];
    "buckets", [
      test_case "empty dir → no buckets" `Quick test_buckets_empty_dir;
      test_case "single bucket window" `Quick test_buckets_single_bucket;
      test_case "sparse entries → distinct buckets" `Quick test_buckets_sparse;
      test_case "cache_hit_ratio zero denom" `Quick test_buckets_cache_hit_ratio_zero_denom;
      test_case "compute_with_buckets integration" `Quick test_buckets_with_compute;
    ];
    "provider_rollup", [
      test_case "empty aggregate gives empty rollup" `Quick
        test_provider_rollup_empty_aggregate;
      test_case "skips models with provider=None" `Quick
        test_provider_rollup_skips_unknown_provider;
      test_case "entry-weighted mean across models" `Quick
        test_provider_rollup_weighted_mean;
      test_case "all-None perf fields preserve None in rollup" `Quick
        test_provider_rollup_all_none_yields_none;
      test_case "sorted by entry_count descending" `Quick
        test_provider_rollup_sort_by_entry_count_desc;
      test_case "provider_stats_to_json shape" `Quick
        test_provider_rollup_json_shape;
    ];
  ]
