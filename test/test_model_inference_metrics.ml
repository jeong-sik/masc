(** Tests for Model_inference_metrics — per-model aggregate inference stats. *)

module M = Model_inference_metrics

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

let inference_identity_values ?identity_seed ~model ~ts () =
  let seed =
    match identity_seed with
    | Some seed -> seed
    | None -> Printf.sprintf "%s|%.6f" model ts
  in
  "trace-" ^ Digest.to_hex (Digest.string seed), 1, 0

let write_costs base entries =
  let costs_dir = Filename.concat base ".masc/costs" in
  let store = Dated_jsonl.create ~base_dir:costs_dir () in
  List.iter (Dated_jsonl.append store) entries

let cost_day_file base =
  let costs_dir = Filename.concat base ".masc/costs" in
  let rec jsonl_files path =
    if Sys.is_directory path
    then
      Sys.readdir path
      |> Array.to_list
      |> List.concat_map (fun name -> jsonl_files (Filename.concat path name))
    else if Filename.check_suffix path ".jsonl"
    then [ path ]
    else []
  in
  match jsonl_files costs_dir with
  | [ path ] -> path
  | paths ->
    failf "expected one cost day file, found %d" (List.length paths)

let append_raw_line path line =
  let oc = open_out_gen [ Open_append ] 0o644 path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () ->
       output_string oc line;
       output_char oc '\n')

let now_unix () = Unix.gettimeofday ()

let recent_hour_bucket_timestamp () =
  let now = now_unix () in
  let hour_sec = 3600.0 in
  let hour_start = floor (now /. hour_sec) *. hour_sec in
  if now -. hour_start >= 120.0 then now -. 60.0 else hour_start -. 60.0

let runtime_lane_label_for_test model_key =
  "runtime_lane_" ^ String.sub (Digest.to_hex (Digest.string model_key)) 0 12

let success_entry ~model ~ts ?identity_seed ?(input_tokens=100) ?(output_tokens=50)
    ?(cache_read_tokens=0) ?(cache_creation_tokens=0)
    ?(latency_ms=500) ?prompt_per_second ?peak_memory_gb
    ?provider ?provider_kind ?usage_trust ?(usage_anomaly_reasons=[])
    ?(cost_usd=0.01) ?(tools_used=[]) () =
  let trace_id, keeper_turn_id, agent_core_turn_ordinal =
    inference_identity_values ?identity_seed ~model ~ts ()
  in
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
    ("trace_id", `String trace_id);
    ("turn_id", `Int keeper_turn_id);
    ("tool_call_count", `Int (List.length tools_used));
    ("tools_used", `List (List.map (fun s -> `String s) tools_used));
    ("telemetry", `Assoc ([
      ("model_used", `String model);
      ("outcome", `String "success");
      ("turn_count", `Int 1);
      ("agent_core_turn_ordinal", `Int agent_core_turn_ordinal);
      ("usage_reported", `Bool true);
      ("telemetry_reported", `Bool true);
      ("tokens_per_second", `Float (Float.of_int output_tokens /. (Float.of_int latency_ms /. 1000.0)));
      ("request_latency_ms", `Int latency_ms);
      ("input_tokens", `Int input_tokens);
      ("output_tokens", `Int output_tokens);
      ("cache_read_tokens", `Int cache_read_tokens);
      ("cache_creation_tokens", `Int cache_creation_tokens);
      ("reasoning_tokens", `Int 0);
      ("cost_usd", `Float cost_usd);
    ] @ extra_telemetry_fields));
  ]

let cost_entry ~model ~ts ?identity_seed ?(input_tokens=100) ?(output_tokens=50)
    ?(latency_ms=500) ?tokens_per_second ?provider
    ?(provider_kind="ollama") () =
  let trace_id, keeper_turn_id, agent_core_turn_ordinal =
    inference_identity_values ?identity_seed ~model ~ts ()
  in
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
    ("task_id", `Null);
    ("provider_kind", `String provider_kind);
    ("model", `String model);
    ("input_tokens", `Int input_tokens);
    ("output_tokens", `Int output_tokens);
    ("cost_usd", `Float 0.0);
    ("usage_missing", `Bool false);
    ("usage_projection", `String "resolved_delta");
    ("source", `String "auto_trajectory");
    ("trace_id", `String trace_id);
    ("keeper_turn_id", `Int keeper_turn_id);
    ("agent_core_turn_ordinal", `Int agent_core_turn_ordinal);
    ("request_latency_ms", `Int latency_ms);
  ] @ provider_fields @ tok_fields)

let error_entry ~runtime_id ~ts ?provider () =
  `Assoc [
    ("ts_unix", `Float ts);
    ("tool_call_count", `Int 0);
    ("tools_used", `List []);
    ("telemetry", `Assoc [
      ("provider",
        match provider with
        | Some v -> `String v
        | None -> `Null);
      ("runtime_id", `String runtime_id);
      ("error_category", `String "timeout");
      ("outcome", `String "error");
      ("usage_reported", `Bool false);
      ("telemetry_reported", `Bool false);
    ]);
  ]

let success_entry_without_usage ~model ~ts ?provider
    ?(telemetry_reported = false)
    ?(coverage_reason = "missing_usage_and_inference")
    ?(coverage_stage = "agent_core")
    ?turn_lane
    ?stop_reason
    () =
  let trace_id, keeper_turn_id, agent_core_turn_ordinal =
    inference_identity_values ~model ~ts ()
  in
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
    ("trace_id", `String trace_id);
    ("turn_id", `Int keeper_turn_id);
    ("tool_call_count", `Int 0);
    ("tools_used", `List []);
    ("telemetry", `Assoc ([
      ("model_used", `String model);
      ("outcome", `String "success");
      ("turn_count", `Int 1);
      ("agent_core_turn_ordinal", `Int agent_core_turn_ordinal);
    ] @ extra_fields @ diag_fields));
  ]

let success_entry_without_model ~runtime_id ~ts ?(tool_count = 1) () =
  let trace_id, keeper_turn_id, agent_core_turn_ordinal =
    inference_identity_values ~model:runtime_id ~ts ()
  in
  `Assoc [
    ("ts_unix", `Float ts);
    ("trace_id", `String trace_id);
    ("turn_id", `Int keeper_turn_id);
    ("tool_call_count", `Int tool_count);
    ("tools_used", `List [ `String "masc_board_comment" ]);
    ( "telemetry",
      `Assoc [
        ("model_used", `Null);
        ("selected_model", `Null);
        ("runtime_id", `String runtime_id);
        ("outcome", `String "success");
        ("turn_count", `Int 1);
        ("agent_core_turn_ordinal", `Int agent_core_turn_ordinal);
        ("stop_reason", `String "completed");
        ("usage_reported", `Bool false);
        ("telemetry_reported", `Bool false);
        ("coverage_stage", `String "agent_core");
        ("coverage_reason", `String "missing_usage_and_inference");
      ] );
  ]

let sparse_provider_context_entry ~outcome ~runtime_id ~ts () =
  let trace_id, keeper_turn_id, agent_core_turn_ordinal =
    inference_identity_values ~model:runtime_id ~ts ()
  in
  let identity_fields =
    if String.equal outcome "success"
    then
      [ "turn_count", `Int 1
      ; "agent_core_turn_ordinal", `Int agent_core_turn_ordinal
      ]
    else []
  in
  `Assoc [
    ("ts_unix", `Float ts);
    ("trace_id", `String trace_id);
    ("turn_id", `Int keeper_turn_id);
    ("outcome", `String outcome);
    ("tool_call_count", `Int 0);
    ("tools_used", `List []);
    ( "provider_context",
      `Assoc [
        ("runtime_id", `String runtime_id);
        ("selected_model", `Null);
      ] );
    ( "telemetry",
      `Assoc ([
        ("outcome", `String outcome);
        ("model_used", `Null);
        ("selected_model", `Null);
        ("usage_reported", `Bool false);
        ("telemetry_reported", `Bool false);
        ( "coverage_stage",
          `String (if String.equal outcome "error" then "unknown" else "agent_core") );
        ( "coverage_reason",
          `String
            (if String.equal outcome "error"
             then "error_turn"
             else "missing_usage_and_inference") );
      ] @ identity_fields) );
  ]

let check_hw_decode_field ~name json expected =
  match
    Model_inference_metrics_parser.parse_telemetry_entry json ~since_unix:0.0
  with
  | Ok entry ->
    check (option (float 0.001)) name expected entry.hw_decode_tok_per_sec
  | Error _ -> fail (name ^ ": telemetry row did not parse")
;;

let test_hw_decode_parser_reads_current_field () =
  let ts = now_unix () in
  let trace_id, keeper_turn_id, agent_core_turn_ordinal =
    inference_identity_values ~model:"model" ~ts ()
  in
  let row key =
    `Assoc
      [ "ts_unix", `Float ts
      ; "trace_id", `String trace_id
      ; "turn_id", `Int keeper_turn_id
      ; "tool_call_count", `Int 0
      ; "tools_used", `List []
      ; ( "telemetry"
        , `Assoc
            [ "model_used", `String "model"
            ; "outcome", `String "success"
            ; "turn_count", `Int 1
            ; "agent_core_turn_ordinal", `Int agent_core_turn_ordinal
            ; "usage_reported", `Bool false
            ; "telemetry_reported", `Bool true
            ; key, `Float 42.0
            ] )
      ]
  in
  check_hw_decode_field
    ~name:"current field"
    (row "hw_decode_tokens_per_second")
    (Some 42.0)
;;

let test_cost_parser_reads_current_hw_decode_field () =
  let ts = now_unix () in
  let row key =
    match cost_entry ~model:"model" ~ts () with
    | `Assoc fields -> `Assoc ((key, `Float 42.0) :: fields)
    | _ -> fail "cost entry must be an object"
  in
  let parse name json expected =
    match Model_inference_metrics_parser.parse_cost_entry json ~since_unix:0.0 with
    | Ok entry ->
      check (option (float 0.001)) name expected entry.hw_decode_tok_per_sec
    | Error _ -> fail (name ^ ": cost row did not parse")
  in
  parse "current cost field" (row "hw_decode_tokens_per_second") (Some 42.0)
;;

let test_cost_parser_requires_usage_missing () =
  let ts = now_unix () in
  let row =
    match cost_entry ~model:"model" ~ts () with
    | `Assoc fields ->
      `Assoc (List.filter (fun (key, _) -> not (String.equal key "usage_missing")) fields)
    | _ -> fail "cost entry must be an object"
  in
  match Model_inference_metrics_parser.parse_cost_entry row ~since_unix:0.0 with
  | Error (Model_inference_metrics_entry.Invalid_current_cost_row _) -> ()
  | Error error ->
    fail
      ("wrong parse error: "
       ^ Model_inference_metrics_entry.parse_error_label error)
  | Ok _ -> fail "cost row without usage_missing must be rejected"
;;

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
    check (option string) "provider" None s.provider;
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

let test_provider_kind_is_not_reconstructed () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "kinded" in
    let ts = now_unix () in
    let provider_kind = "kimi_cli" in
    write_decisions path [
      success_entry ~model:"kimi-k2.6" ~ts:(ts -. 5.0)
        ~provider_kind ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    check int "total_entries" 1 agg.total_entries;
    let s = List.hd agg.models in
    check string "model stays bare" "kimi-k2.6" s.model_id;
    check (option string) "provider not reconstructed" None s.provider;
    let recent = List.hd s.recent_entries in
    check (option string) "recent provider not reconstructed" None recent.re_provider;
    ())

let test_usage_labels_never_suppress_raw_aggregates () =
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
      success_entry ~model:"llama:qwen3.5-27b" ~ts:(ts -. 2.0)
        ~input_tokens:0 ~output_tokens:0 ~latency_ms:1000 ();
      success_entry ~model:"llama:qwen3.5-27b" ~ts:(ts -. 1.0)
        ~input_tokens:(-7) ~output_tokens:5 ~latency_ms:1000 ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    check int "total entries retained for diagnosis" 4 agg.total_entries;
    check int "models" 1 (List.length agg.models);
    let s = List.hd agg.models in
    check (option int) "raw input total" (Some 1_721_599)
      s.total_input_tokens;
    check (option int) "raw output total" (Some 925)
      s.total_output_tokens;
    check int "all reported usage samples count" 4 s.usage_sample_count;
    check int "invalidity is not missing usage" 0 s.usage_missing_count;
    check (option (float 0.001)) "all reported tok/s observations remain"
      (Some 231.25) s.avg_tok_per_sec;
    check (option (float 0.001)) "cost is not suppressed by usage label"
      (Some 0.04) s.total_cost_usd;
    let large =
      List.find
        (fun (recent : M.recent_entry) ->
          recent.re_input_tokens = Some 1_721_506)
        s.recent_entries
    in
    check (option string) "trust label retained as provenance"
      (Some "untrusted") large.re_usage_trust;
    check (option int) "large input remains visible" (Some 1_721_506)
      large.re_input_tokens;
    check (list string) "anomaly reason retained as provenance"
      ["input_tokens_gt_1m"] large.re_usage_anomaly_reasons;
    let negative =
      List.find
        (fun (recent : M.recent_entry) -> recent.re_input_tokens = Some (-7))
        s.recent_entries
    in
    check (option string) "negative input is explicitly invalid"
      (Some "untrusted") negative.re_usage_trust;
    check (list string) "negative reason is explicit"
      ["negative_input_tokens"] negative.re_usage_anomaly_reasons)

let test_error_turns_counted () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "alice" in
    let ts = now_unix () in
    write_decisions path [
      success_entry ~model:"qwen-35b" ~ts:(ts -. 20.0) ();
      error_entry ~runtime_id:"local_only" ~ts:(ts -. 10.0) ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    check int "total_entries" 2 agg.total_entries;
    check int "total_error_entries" 1 agg.total_error_entries;
    (* Error attributed to the dispatched runtime_id *)
    let error_model = List.find_opt (fun (s : M.model_stats) ->
      s.model_id = "local_only (runtime)") agg.models in
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
      success_entry ~model:"gpt" ~ts:(ts -. 20.0)
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
          ~cache_read_tokens:(if i = 0 then 32 else 0)
          ~cache_creation_tokens:(if i = 0 then 8 else 0)
          ~latency_ms:500 ~cost_usd:0.01 ())
    );
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let s = List.hd agg.models in
    check int "recent_entries capped at 5" 5 (List.length s.recent_entries);
    (* First recent entry should be the most recent (highest ts_unix) *)
    let first_re = List.hd s.recent_entries in
    check bool "most recent first" true (first_re.re_ts_unix >= (ts -. 1.0));
    check (option int) "recent cache read" (Some 32)
      first_re.re_cache_read_tokens;
    check (option int) "recent cache creation" (Some 8)
      first_re.re_cache_creation_tokens)

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
        ~cache_read_tokens:21
        ~cache_creation_tokens:7
        ~tools_used:["t1"] ~cost_usd:0.05 ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let json = M.to_json agg in
    let open Yojson.Safe.Util in
    let models = json |> member "models" |> to_list in
    check bool "has models" true (List.length models > 0);
    let m = List.hd models in
    check string "model id redacted" (runtime_lane_label_for_test "test-model")
      (m |> member "model_id" |> to_string);
    check bool "provider redacted -> null" true
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
    let recent = m |> member "recent_entries" |> to_list |> List.hd in
    check int "recent cache_read_tokens" 21
      (recent |> member "cache_read_tokens" |> to_int);
    check int "recent cache_creation_tokens" 7
      (recent |> member "cache_creation_tokens" |> to_int);
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
    check (option int) "recent cache read unknown" None
      recent.re_cache_read_tokens;
    check (option int) "recent cache creation unknown" None
      recent.re_cache_creation_tokens;
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
      (match recent_json |> member "input_tokens" with `Null -> true | _ -> false);
    check bool "recent json cache read null" true
      (match recent_json |> member "cache_read_tokens" with `Null -> true | _ -> false);
    check bool "recent json cache creation null" true
      (match recent_json |> member "cache_creation_tokens" with
       | `Null -> true
       | _ -> false))

let test_coverage_diagnostics_survive_aggregation () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "coverage_diag" in
    let ts = now_unix () in
    write_decisions path [
      success_entry_without_usage ~model:"glm-coding:glm-5"
        ~ts:(ts -. 5.0)
        ~provider:"glm-coding"
        ~turn_lane:"text_only"
        ~stop_reason:"completed"
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
      (Some "agent_core")
      s.primary_coverage_stage;
    check int "coverage reason counts" 1 (List.length s.coverage_reason_counts);
    let recent = List.hd s.recent_entries in
    check string "recent outcome" "success" recent.re_outcome;
    check (option string) "recent stop reason"
      (Some "completed")
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
      (Some "agent_core")
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
      "agent_core"
      (m |> member "primary_coverage_stage" |> to_string);
    let reason_counts = m |> member "coverage_reason_counts" |> to_list in
    check int "json reason count length" 1 (List.length reason_counts);
    check string "json reason count reason"
      "missing_usage_and_inference"
      (List.hd reason_counts |> member "reason" |> to_string);
    let recent_json = m |> member "recent_entries" |> to_list |> List.hd in
    check string "recent json outcome" "success"
      (recent_json |> member "outcome" |> to_string);
    check string "recent json stage" "agent_core"
      (recent_json |> member "coverage_stage" |> to_string))

let test_success_without_model_uses_runtime_attribution () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "null_model" in
    let ts = now_unix () in
    write_decisions path [
      success_entry_without_model ~runtime_id:"runtime.glm-coding-with-spark"
        ~ts:(ts -. 5.0) ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    check int "null-model row retained" 1 agg.total_entries;
    check int "one attributed bucket" 1 (List.length agg.models);
    let s = List.hd agg.models in
    check string "runtime attribution"
      "runtime.glm-coding-with-spark (runtime)"
      s.model_id;
    check int "success count" 1 s.success_count;
    check int "tool calls preserved" 1 s.total_tool_calls;
    check (option string) "coverage reason retained"
      (Some "missing_usage_and_inference")
      s.primary_coverage_reason)

let test_provider_context_attribution_survives_sparse_telemetry () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "provider_context_sparse" in
    let ts = now_unix () in
    write_decisions path [
      sparse_provider_context_entry ~outcome:"success"
        ~runtime_id:"runtime.coding_plan"
        ~ts:(ts -. 5.0) ();
      sparse_provider_context_entry ~outcome:"error"
        ~runtime_id:"runtime.coding_plan"
        ~ts:(ts -. 10.0) ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    check int "sparse rows retained" 2 agg.total_entries;
    check int "error row counted" 1 agg.total_error_entries;
    check int "one attributed bucket" 1 (List.length agg.models);
    let s = List.hd agg.models in
    check string "provider_context runtime attribution"
      "runtime.coding_plan (runtime)"
      s.model_id;
    check int "success count" 1 s.success_count;
    check int "error count" 1 s.error_count)

let test_cost_ledger_backfills_wall_tok_per_sec () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let ts = now_unix () in
    write_costs base [
      cost_entry ~model:"qwen3.6:27b-coding-nvfp4" ~ts
        ~input_tokens:100 ~output_tokens:50 ~latency_ms:250 ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let s = List.hd agg.models in
    check string "cost model" "qwen3.6:27b-coding-nvfp4" s.model_id;
    check int "one cost entry" 1 s.entry_count;
    check (option (float 0.001)) "wall tok/sec from cost latency"
      (Some 200.0) s.avg_tok_per_sec;
    check int "usage sample" 1 s.usage_sample_count;
    check int "telemetry sample" 1 s.telemetry_sample_count)

let test_cost_model_field_is_not_rewritten_from_provider () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let ts = now_unix () in
    write_costs base [
      cost_entry ~model:"shared-model" ~provider_kind:"ollama" ~ts
        ~input_tokens:10 ~output_tokens:5 ();
      cost_entry ~model:"shared-model" ~provider_kind:"anthropic" ~ts:(ts -. 1.0)
        ~input_tokens:20 ~output_tokens:10 ();
    ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    check int "one model bucket" 1 (List.length agg.models);
    let stats = List.hd agg.models in
    check string "model field remains authoritative" "shared-model" stats.model_id;
    check int "both rows retained" 2 stats.entry_count;
    check (option int) "tokens aggregate without provider rewrite" (Some 30)
      stats.total_input_tokens)

let test_cost_ledger_zero_latency_is_missing () =
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

let test_exact_identity_merges_decision_and_cost () =
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
    check int "exactly matching rows merged" 1 s.entry_count;
    check (option (float 0.001)) "cost observation supplies wall tok/sec"
      (Some 200.0) s.avg_tok_per_sec;
    check int "decision tool fields survive merge" 0 s.total_tool_calls)
;;

let test_nearby_equal_usage_without_identity_match_stays_distinct () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "nearby-distinct" in
    let ts = now_unix () in
    write_decisions
      path
      [ success_entry
          ~model:"same-model"
          ~ts
          ~input_tokens:100
          ~output_tokens:50
          () ];
    write_costs
      base
      [ cost_entry
          ~model:"same-model"
          ~ts:(ts -. 1.0)
          ~input_tokens:100
          ~output_tokens:50
          () ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    let stats = List.hd agg.models in
    check int "both exact identities remain" 2 stats.entry_count)
;;

let test_duplicate_exact_identity_is_excluded_and_diagnosed () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "identity-conflict" in
    let ts = now_unix () in
    write_decisions
      path
      [ success_entry
          ~model:"same-model"
          ~ts
          ~identity_seed:"duplicate-identity"
          () ];
    write_costs
      base
      [ cost_entry
          ~model:"same-model"
          ~ts
          ~identity_seed:"duplicate-identity"
          ()
      ; cost_entry
          ~model:"same-model"
          ~ts:(ts -. 1.0)
          ~identity_seed:"duplicate-identity"
          ()
      ];
    let agg = M.compute ~base_path:base ~window_minutes:60 in
    check int "conflicting identity is excluded" 0 agg.total_entries;
    check int "conflicting identity creates no aggregate" 0
      (List.length agg.models);
    match agg.cost_read with
    | Error error ->
      failf "cost store read failed: %s" (Dated_jsonl.read_error_to_string error)
    | Ok diagnostics ->
      check int "all conflicting rows diagnosed" 3
        diagnostics.identity_conflict_rows)
;;

let test_cost_read_diagnostics_reach_api () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let ts = now_unix () in
    write_costs
      base
      [ cost_entry ~model:"valid" ~ts ()
      ; `String "schema-invalid"
      ];
    append_raw_line (cost_day_file base) "{";
    let json = M.compute ~base_path:base ~window_minutes:60 |> M.to_json in
    let diagnostics = Yojson.Safe.Util.member "cost_ledger_read" json in
    check string "cost read state" "available"
      Yojson.Safe.Util.(diagnostics |> member "state" |> to_string);
    check int "malformed rows" 1
      Yojson.Safe.Util.(diagnostics |> member "malformed_rows" |> to_int);
    check int "schema violation rows" 1
      Yojson.Safe.Util.(diagnostics |> member "schema_violation_rows" |> to_int);
    check int "identity conflicts" 0
      Yojson.Safe.Util.(diagnostics |> member "identity_conflict_rows" |> to_int))
;;

let test_cost_read_failure_is_not_empty_success () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let keeper_path = make_keeper_dir base "decision-survives-cost-error" in
    write_decisions
      keeper_path
      [ success_entry ~model:"decision-model" ~ts:(now_unix ()) () ];
    let costs_dir = Filename.concat base ".masc/costs" in
    (* A read failure must surface as [unavailable], not empty success:
       [.masc/costs] as a regular file is present but not listable. *)
    let masc_dir = Filename.concat base ".masc" in
    if not (Sys.file_exists masc_dir) then Unix.mkdir masc_dir 0o755;
    let oc = open_out costs_dir in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc "{}");
    let json = M.compute ~base_path:base ~window_minutes:60 |> M.to_json in
    check int "decision metrics remain available" 1
      Yojson.Safe.Util.(json |> member "total_entries" |> to_int);
    let diagnostics = Yojson.Safe.Util.member "cost_ledger_read" json in
    check string "cost read state" "unavailable"
      Yojson.Safe.Util.(diagnostics |> member "state" |> to_string);
    let detail = Yojson.Safe.Util.(diagnostics |> member "detail" |> to_string) in
    check bool "typed read detail is surfaced" true
      (String_util.contains_substring detail costs_dir))
;;

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
      success_entry ~model:"gpt" ~provider:"openai"
        ~ts:(ts -. 10.0)
        ~input_tokens:20 ~output_tokens:10 ~latency_ms:1000
        ~cost_usd:0.01 ();
    ];
    let json = M.compute_cost_latency_json ~base_path:base ~window_minutes:60 in
    let open Yojson.Safe.Util in
    let per_agent = json |> member "perAgent" |> to_list in
    check int "perAgent row count" 2 (List.length per_agent);
    let first = List.hd per_agent in
    check string "highest cost first redacted"
      (runtime_lane_label_for_test "claude-sonnet")
      (first |> member "agent" |> to_string);
    check int "input tokens summed" 110
      (first |> member "in_tok" |> to_int);
    check int "output tokens summed" 55
      (first |> member "out_tok" |> to_int);
    check (float 0.001) "cost summed" 0.05
      (first |> member "cost" |> to_float);

    let matrix = json |> member "matrix" in
    check (list string) "provider axis redacted"
      ["runtime"]
      (matrix |> member "providers" |> to_list |> List.map to_string);
    check (list string) "model axis redacted"
      [
        runtime_lane_label_for_test "claude-sonnet";
        runtime_lane_label_for_test "gpt";
      ]
      (matrix |> member "models" |> to_list |> List.map to_string);
    let grid = matrix |> member "grid" |> to_list in
    let row0 = List.nth grid 0 |> to_list |> List.map to_float in
    check (list (float 0.001)) "runtime row costs" [0.05; 0.01] row0;

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

let test_public_runtime_lane_label_is_stable_across_windows () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "stable_lane" in
    let ts = now_unix () in
    write_decisions path [
      success_entry ~model:"old-busier-model" ~ts:(ts -. 120.0)
        ~input_tokens:10 ();
      success_entry ~model:"old-busier-model" ~ts:(ts -. 130.0)
        ~input_tokens:10 ();
      success_entry ~model:"stable-model" ~ts:(ts -. 10.0)
        ~input_tokens:300 ();
    ];
    let label_with_input expected_input json =
      let open Yojson.Safe.Util in
      json
      |> member "models"
      |> to_list
      |> List.find_map (fun model_json ->
        if model_json |> member "total_input_tokens" |> to_int = expected_input then
          Some (model_json |> member "model_id" |> to_string)
        else
          None)
    in
    let full =
      M.compute ~base_path:base ~window_minutes:60 |> M.to_json
      |> label_with_input 300
    in
    let short =
      M.compute ~base_path:base ~window_minutes:1 |> M.to_json
      |> label_with_input 300
    in
    let expected = Some (runtime_lane_label_for_test "stable-model") in
    check (option string) "full window label" expected full;
    check (option string) "short window label" expected short)

let test_cost_latency_json_preserves_missing_latency_as_null () =
  let base = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let path = make_keeper_dir base "cost_latency_missing" in
    let ts = now_unix () in
    let row_ts = ts -. 10.0 in
    let trace_id, keeper_turn_id, agent_core_turn_ordinal =
      inference_identity_values ~model:"unlatenced-model" ~ts:row_ts ()
    in
    write_decisions path [
      `Assoc [
        ("ts_unix", `Float row_ts);
        ("trace_id", `String trace_id);
        ("turn_id", `Int keeper_turn_id);
        ("tool_call_count", `Int 0);
        ("tools_used", `List []);
        ("telemetry", `Assoc [
          ("model_used", `String "unlatenced-model");
          ("outcome", `String "success");
          ("turn_count", `Int 1);
          ("agent_core_turn_ordinal", `Int agent_core_turn_ordinal);
          ("usage_reported", `Bool true);
          ("telemetry_reported", `Bool false);
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
  let trace_id, keeper_turn_id, agent_core_turn_ordinal =
    inference_identity_values ~model ~ts ()
  in
  let thinking_field = match thinking_enabled with
    | Some b -> [("thinking_enabled", `Bool b)]
    | None -> []
  in
  `Assoc [
    ("ts_unix", `Float ts);
    ("trace_id", `String trace_id);
    ("turn_id", `Int keeper_turn_id);
    ("tool_call_count", `Int 0);
    ("tools_used", `List []);
    ("telemetry", `Assoc ([
      ("model_used", `String model);
      ("outcome", `String "success");
      ("turn_count", `Int 1);
      ("agent_core_turn_ordinal", `Int agent_core_turn_ordinal);
      ("usage_reported", `Bool true);
      ("telemetry_reported", `Bool true);
      ("tokens_per_second", `Float 10.0);
      ("request_latency_ms", `Int 500);
      ("input_tokens", `Int 100);
      ("output_tokens", `Int 50);
      ("cache_read_tokens", `Int 0);
      ("reasoning_tokens", `Int 0);
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
  let trace_id, keeper_turn_id, agent_core_turn_ordinal =
    inference_identity_values ~model ~ts ()
  in
  `Assoc [
    ("ts_unix", `Float ts);
    ("trace_id", `String trace_id);
    ("turn_id", `Int keeper_turn_id);
    ("tool_call_count", `Int 0);
    ("tools_used", `List []);
    ("telemetry", `Assoc [
      ("model_used", `String model);
      ("outcome", `String "success");
      ("turn_count", `Int 1);
      ("agent_core_turn_ordinal", `Int agent_core_turn_ordinal);
      ("usage_reported", `Bool true);
      ("telemetry_reported", `Bool true);
      ("tokens_per_second", `Float 10.0);
      ("request_latency_ms", `Int 500);
      ("input_tokens", `Int input_tokens);
      ("output_tokens", `Int 50);
      ("cache_read_tokens", `Int cache_read);
      ("reasoning_tokens", `Int 0);
      ("cost_usd", `Float 0.01);
    ]);
  ]

let bucket_models = function
  | Ok (models, _diagnostics) -> models
  | Error error ->
    failf "cost store read failed: %s" (Dated_jsonl.read_error_to_string error)

let test_buckets_empty_dir () =
  let dir = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let result =
      M.aggregate_buckets ~base_path:dir ~window_min:60 ~bucket_min:5
      |> bucket_models
    in
    check int "empty → no models" 0 (List.length result))

let test_buckets_single_bucket () =
  let dir = test_dir () in
  let path = make_keeper_dir dir "single_bucket" in
  let now = recent_hour_bucket_timestamp () in
  write_decisions path [
    success_entry ~model:"claude" ~ts:now ();
    success_entry ~model:"claude" ~ts:(now -. 30.0) ();
  ];
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let result =
      M.aggregate_buckets ~base_path:dir ~window_min:60 ~bucket_min:60
      |> bucket_models
    in
    check int "one model" 1 (List.length result);
    let m = List.hd result in
    check string "model_id" "claude" m.mb_model_id;
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
    let result =
      M.aggregate_buckets ~base_path:dir ~window_min:60 ~bucket_min:5
      |> bucket_models
    in
    check int "one model" 1 (List.length result);
    let m = List.hd result in
    check bool "sparse → 2 distinct buckets (10min apart, 5min width)"
      true (List.length m.mb_buckets >= 2))

let test_buckets_cache_hit_ratio_zero_denom () =
  let dir = test_dir () in
  let path = make_keeper_dir dir "cache_zero" in
  let now = now_unix () in
  write_decisions path [
    success_entry_with_cache ~model:"kimi-k2.6" ~ts:now ~input_tokens:0 ~cache_read:0 ();
  ];
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let result =
      M.aggregate_buckets ~base_path:dir ~window_min:60 ~bucket_min:60
      |> bucket_models
    in
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

(* ── Hand-built aggregate fixtures ────────────── *)

(* Built by hand instead of going through [M.compute] so the assertions
   below do not depend on the jsonl parser, and stay robust to future
   changes in the decisions.jsonl shape. *)

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
    total_cache_creation_tokens = None;
    total_reasoning_tokens = None;
    usage_sample_count = entry_count;
    telemetry_sample_count = entry_count;
    usage_missing_count = 0;
    telemetry_missing_count = 0;
    coverage_status = "full";
    primary_coverage_stage = None;
    primary_coverage_reason = None;
    coverage_reason_counts = [];
    success_count = entry_count;
    error_count = 0;
    total_cost_usd = None;
    avg_tool_calls_per_turn = 0.0;
    total_tool_calls = 0;
    top_tools = [];
    recent_entries = [];
    buckets = [];
  }

let successful_cost_read : M.cost_read_result =
  Ok
    { malformed_rows = 0
    ; schema_violation_rows = 0
    ; identity_conflict_rows = 0
    }

let test_prompt_feedback_empty_aggregate () =
  let agg : M.aggregate =
    { window_minutes = 60
    ; bucket_minutes = 0
    ; models = []
    ; total_entries = 0
    ; total_error_entries = 0
    ; latency_buckets = []
    ; cost_read = successful_cost_read
    }
  in
  check string "empty aggregate renders empty prompt block" ""
    (M.render_keeper_prompt_feedback agg)

let test_prompt_feedback_redacts_provider_model_identity () =
  let raw_model = "openrouter:secret-model" in
  let lane = runtime_lane_label_for_test raw_model in
  let stats =
    { (zero_model_stats raw_model ~provider:(Some "openrouter") ~entry_count:10)
      with success_count = 7
         ; error_count = 3
         ; p95_latency_ms = Some 130_000.0
         ; avg_tok_per_sec = Some 12.5
         ; total_input_tokens = Some 1000
         ; total_output_tokens = Some 250
         ; usage_missing_count = 1
         ; telemetry_missing_count = 1
         ; coverage_status = "partial"
    }
  in
  let agg : M.aggregate =
    { window_minutes = 120
    ; bucket_minutes = 0
    ; models = [ stats ]
    ; total_entries = 10
    ; total_error_entries = 3
    ; latency_buckets = []
    ; cost_read = successful_cost_read
    }
  in
  let text = M.render_keeper_prompt_feedback agg in
  check bool "contains redacted lane label" true (String_util.contains_substring text lane);
  check bool "contains total turns" true (String_util.contains_substring text "total_turns=10");
  check bool "contains error rate" true (String_util.contains_substring text "error_rate=30.0%");
  check bool "does not expose provider" false (String_util.contains_substring text "openrouter");
  check bool "does not expose raw model" false (String_util.contains_substring text "secret-model")

let test_prompt_feedback_is_cost_independent () =
  let render total_cost_usd =
    let stats =
      { (zero_model_stats "runtime:test" ~provider:None ~entry_count:1) with
        total_cost_usd
      }
    in
    M.render_keeper_prompt_feedback
      { window_minutes = 30
      ; bucket_minutes = 0
      ; models = [ stats ]
      ; total_entries = 1
      ; total_error_entries = 0
      ; latency_buckets = []
      ; cost_read = successful_cost_read
      }
  in
  let baseline = render None in
  List.iter
    (fun total_cost_usd ->
       check string "cost does not alter planning feedback" baseline
         (render total_cost_usd))
    [ Some 0.0; Some 1234.5678 ];
  List.iter
    (fun forbidden ->
       check bool ("planning feedback excludes " ^ forbidden) false
         (String_util.contains_substring baseline forbidden))
    [ "cost="; "cost_usd"; "$" ]

let test_usage_signal_uses_tokens_not_cost () =
  let entry : Model_inference_metrics_entry.raw_entry =
    { model = "runtime"
    ; provider = None
    ; inference_identity = None
    ; ts_unix = 0.0
    ; outcome = "success"
    ; stop_reason = None
    ; turn_lane = None
    ; tok_per_sec = None
    ; prompt_tok_per_sec = None
    ; hw_decode_tok_per_sec = None
    ; peak_memory_gb = None
    ; thinking_enabled = None
    ; latency_ms = None
    ; input_tokens = None
    ; output_tokens = None
    ; cache_read_tokens = None
    ; cache_creation_tokens = None
    ; reasoning_tokens = None
    ; cost_usd = Some 12.34
    ; tool_call_count = 0
    ; tools_used = []
    ; usage_reported = None
    ; telemetry_reported = None
    ; usage_trust = None
    ; usage_anomaly_reasons = []
    ; coverage_reason = None
    ; coverage_stage = None
    ; is_error = false
    ; streaming_ttfrc_ms = None
    ; streaming_inter_chunk_count = None
    ; streaming_inter_chunk_avg_ms = None
    }
  in
  check bool "billing alone is not usage evidence" false
    (Model_inference_metrics_reader.usage_signal_present entry);
  let cache_creation_only =
    { entry with cost_usd = None; cache_creation_tokens = Some 1 }
  in
  check bool "cache creation is usage evidence" true
    (Model_inference_metrics_reader.usage_signal_present cache_creation_only)

(* ── Runner ──────────────────────────────────────── *)

let () =
  run "Model_inference_metrics" [
    "basics", [
      test_case "empty dir" `Quick test_empty_dir;
      test_case "single model success" `Quick test_single_model_success;
      test_case "provider_kind is not reconstructed" `Quick
        test_provider_kind_is_not_reconstructed;
      test_case "usage labels never suppress raw aggregates" `Quick
        test_usage_labels_never_suppress_raw_aggregates;
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
      test_case "success without model uses runtime attribution" `Quick
        test_success_without_model_uses_runtime_attribution;
      test_case "provider_context attribution survives sparse telemetry" `Quick
        test_provider_context_attribution_survives_sparse_telemetry;
      test_case "decision parser reads current hw-decode field" `Quick
        test_hw_decode_parser_reads_current_field;
      test_case "cost parser reads current hw-decode field" `Quick
        test_cost_parser_reads_current_hw_decode_field;
      test_case "cost parser requires usage_missing" `Quick
        test_cost_parser_requires_usage_missing;
      test_case "cost ledger backfills wall tok/sec" `Quick
        test_cost_ledger_backfills_wall_tok_per_sec;
      test_case "cost model field is not rewritten from provider" `Quick
        test_cost_model_field_is_not_rewritten_from_provider;
      test_case "cost ledger zero latency stays missing" `Quick
        test_cost_ledger_zero_latency_is_missing;
      test_case "exact identity merges decision and cost" `Quick
        test_exact_identity_merges_decision_and_cost;
      test_case "nearby equal usage stays distinct" `Quick
        test_nearby_equal_usage_without_identity_match_stays_distinct;
      test_case "duplicate exact identity is excluded" `Quick
        test_duplicate_exact_identity_is_excluded_and_diagnosed;
      test_case "cost read diagnostics reach API" `Quick
        test_cost_read_diagnostics_reach_api;
      test_case "cost read failure is not empty success" `Quick
        test_cost_read_failure_is_not_empty_success;
      test_case "cost latency json composes axes and percentiles" `Quick test_cost_latency_json_composes_axes_and_percentiles;
      test_case "public runtime lane label is stable across windows" `Quick
        test_public_runtime_lane_label_is_stable_across_windows;
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
    "prompt_feedback", [
      test_case "empty aggregate renders empty" `Quick
        test_prompt_feedback_empty_aggregate;
      test_case "redacts provider and model identity" `Quick
        test_prompt_feedback_redacts_provider_model_identity;
    ];
    "pricing_firewall", [
      test_case "prompt feedback is cost independent" `Quick
        test_prompt_feedback_is_cost_independent;
      test_case "usage signal uses tokens, not cost" `Quick
        test_usage_signal_uses_tokens_not_cost;
    ];
  ]
