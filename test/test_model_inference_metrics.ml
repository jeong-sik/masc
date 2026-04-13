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
    ?(latency_ms=500) ?(cost_usd=0.01) ?(tools_used=[]) () =
  `Assoc [
    ("ts_unix", `Float ts);
    ("tool_call_count", `Int (List.length tools_used));
    ("tools_used", `List (List.map (fun s -> `String s) tools_used));
    ("telemetry", `Assoc [
      ("model_used", `String model);
      ("tokens_per_second", `Float (Float.of_int output_tokens /. (Float.of_int latency_ms /. 1000.0)));
      ("request_latency_ms", `Int latency_ms);
      ("input_tokens", `Int input_tokens);
      ("output_tokens", `Int output_tokens);
      ("cache_read_tokens", `Int 0);
      ("reasoning_tokens", `Int 0);
      ("fallback_applied", `Bool false);
      ("cost_usd", `Float cost_usd);
    ]);
  ]

let error_entry ~cascade_name ~ts () =
  `Assoc [
    ("ts_unix", `Float ts);
    ("tool_call_count", `Int 0);
    ("tools_used", `List []);
    ("telemetry", `Assoc [
      ("cascade_name", `String cascade_name);
      ("candidate_models", `List [`String "model-a"; `String "model-b"]);
      ("error_category", `String "timeout");
      ("outcome", `String "error");
    ]);
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
    check int "entry_count" 2 s.entry_count;
    check int "success_count" 2 s.success_count;
    check int "error_count" 0 s.error_count;
    check int "total_input_tokens" 350 s.total_input_tokens;
    check int "total_output_tokens" 180 s.total_output_tokens;
    check int "total_tool_calls" 3 s.total_tool_calls;
    check bool "cost > 0" true (s.total_cost_usd > 0.0);
    check bool "avg_tool_calls > 0" true (s.avg_tool_calls_per_turn > 0.0);
    check bool "latency > 0" true (s.avg_latency_ms > 0.0);
    check bool "tok/s > 0" true (s.avg_tok_per_sec > 0.0))

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
    check int "error_count" 1 em.error_count;
    check int "success_count" 0 em.success_count)

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
    check int "success_count" 1 (m |> member "success_count" |> to_int);
    check bool "total_cost_usd = 0.05" true
      (Float.abs (m |> member "total_cost_usd" |> to_float) -. 0.05 < 0.001);
    check bool "has top_tools list" true
      (match m |> member "top_tools" with `List _ -> true | _ -> false);
    check bool "has recent_entries list" true
      (match m |> member "recent_entries" with `List _ -> true | _ -> false);
    check int "total_error_entries" 0
      (json |> member "total_error_entries" |> to_int))

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
      test_case "json roundtrip" `Quick test_json_roundtrip;
    ];
  ]
