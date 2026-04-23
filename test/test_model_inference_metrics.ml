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

let now_unix () = Unix.gettimeofday ()

let success_entry ~model ~ts ?(input_tokens=100) ?(output_tokens=50)
    ?(latency_ms=500) ?prompt_per_second ?peak_memory_gb
    ?provider ?(cost_usd=0.01) ?(tools_used=[]) () =
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

let success_entry_without_usage ~model ~ts ?provider () =
  let extra_fields =
    match provider with
    | Some value -> [ ("provider", `String value) ]
    | None -> []
  in
  `Assoc [
    ("ts_unix", `Float ts);
    ("tool_call_count", `Int 0);
    ("tools_used", `List []);
    ("telemetry", `Assoc ([
      ("model_used", `String model);
      ("fallback_applied", `Bool false);
    ] @ extra_fields));
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
        ~cost_usd:0.005 ~tools_used:["shell"; "read"] ();
      success_entry ~model:"claude-sonnet" ~ts:(ts -. 5.0)
        ~input_tokens:150 ~output_tokens:80 ~latency_ms:800
        ~cost_usd:0.003 ~tools_used:["shell"] ();
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

(* ── Runner ──────────────────────────────────────── *)

let () =
  run "Model_inference_metrics" [
    "basics", [
      test_case "empty dir" `Quick test_empty_dir;
      test_case "single model success" `Quick test_single_model_success;
      test_case "error turns counted" `Quick test_error_turns_counted;
      test_case "multi model sorted" `Quick test_multi_model;
      test_case "window filter" `Quick test_window_filter;
    ];
    "enrichment", [
      test_case "top tools per model" `Quick test_top_tools_per_model;
      test_case "recent entries capped" `Quick test_recent_entries;
      test_case "prompt tps and peak memory aggregates" `Quick test_prompt_tps_and_peak_memory_aggregates;
      test_case "missing usage serializes unknowns" `Quick test_missing_usage_serializes_unknowns;
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
  ]
