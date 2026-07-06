(** Tests for K2 decisions and memory log telemetry feeds.

    Covers:
    - evidence_refs populated from real reference lists only (not prose)
    - Limit clamping at both producer and route boundary
    - Memory log IDs are collision-resistant for same-timestamp rows
    - JSON shape matches spec:
      {id, ts, ts_unix, keeper, decision_type, summary, evidence_refs[]}
      {id, ts, ts_unix, keeper, kind, summary} *)

open Alcotest
module Workspace = Masc.Workspace
module Dash = Dashboard_http_keeper
module Feeds = Dashboard_http_keeper_feeds
module Keeper_config = Masc.Keeper_config
module Keeper_fs = Masc.Keeper_fs
module Keeper_types = Keeper_types
module Provider_routes = Server_routes_http_routes_provider_runs
module Json = Yojson.Safe.Util

let test_counter = ref 0

let tmpdir prefix =
  incr test_counter;
  Filename.temp_dir (Printf.sprintf "%s_%d_" prefix !test_counter) ""
;;

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)
;;

let runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}
;;

let init_runtime_default_for_tests base_dir =
  let path = Filename.concat base_dir "runtime.toml" in
  write_file path runtime_toml;
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e
;;

let with_config f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = tmpdir "dashboard_k2_feeds" in
  init_runtime_default_for_tests base_dir;
  let config = Workspace.default_config base_dir in
  f config
;;

let keeper_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String name
          ; "agent_name", `String name
          ; "trace_id", `String ("trace-" ^ name)
          ; "runtime_id", `String (Keeper_config.default_runtime_id ())
          ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)
;;

let append_jsonl path json =
  let (_ : string) = Keeper_fs.ensure_dir (Filename.dirname path) in
  Masc.Keeper_types_support.append_jsonl_line path json
;;

let strings json = json |> Json.to_list |> List.map Json.to_string

let string_field key json =
  match Yojson.Safe.Util.member key json with
  | `String value -> value
  | other ->
    fail
      (Printf.sprintf
         "field %s is not string: %s"
         key
         (Yojson.Safe.to_string other))
;;

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if idx + needle_len > haystack_len
    then false
    else if String.equal (String.sub haystack idx needle_len) needle
    then true
    else loop (idx + 1)
  in
  String.equal needle "" || loop 0
;;

let replace_keeper_dir_with_file config content =
  let keepers_dir = Keeper_types_profile.keeper_dir config in
  Fs_compat.mkdir_p (Filename.dirname keepers_dir);
  write_file keepers_dir content
;;

let test_provider_routes_keeper_scan_surfaces_keeper_names_failure () =
  with_config
  @@ fun config ->
  replace_keeper_dir_with_file config "not a keeper directory";
  let scan = Provider_routes.provider_dashboard_keeper_meta_scan config in
  check bool "keeper names marked unknown" false scan.keeper_names_known;
  check int "no keepers on discovery failure" 0 (List.length scan.keepers);
  check int "one keeper discovery read error" 1 (List.length scan.read_errors);
  match scan.read_errors with
  | [ error ] ->
    check string "read error source" "keeper_names_result" (string_field "source" error);
    check
      bool
      "read error mentions keepers path"
      true
      (contains_substring ~needle:"keepers" (string_field "message" error))
  | _ -> fail "expected one keeper discovery read error"
;;

let test_provider_routes_keeper_scan_surfaces_meta_read_failure () =
  with_config
  @@ fun config ->
  let keepers_dir = Keeper_types_profile.keeper_dir config in
  Fs_compat.mkdir_p keepers_dir;
  write_file (Filename.concat keepers_dir "broken.json") "{not-json";
  let scan = Provider_routes.provider_dashboard_keeper_meta_scan config in
  check bool "keeper names remain known" true scan.keeper_names_known;
  check int "corrupt keeper meta omitted" 0 (List.length scan.keepers);
  check int "one keeper meta read error" 1 (List.length scan.read_errors);
  match scan.read_errors with
  | [ error ] ->
    check string "read error source" "read_meta" (string_field "source" error);
    check string "read error keeper" "broken" (string_field "keeper" error);
    check bool "read error message present" true
      (String.length (string_field "message" error) > 0)
  | _ -> fail "expected one keeper meta read error"
;;

let test_provider_routes_feed_json_merges_keeper_scan_read_errors () =
  with_config
  @@ fun config ->
  replace_keeper_dir_with_file config "not a keeper directory";
  let scan = Provider_routes.provider_dashboard_keeper_meta_scan config in
  let existing_error =
    `Assoc [ "source", `String "existing_feed_error"; "message", `String "bad row" ]
  in
  let json =
    Provider_routes.provider_dashboard_json_with_keeper_meta_scan
      scan
      (`Assoc
        [ "events", `List []
        ; "read_error_count", `Int 1
        ; "read_errors", `List [ existing_error ]
        ])
  in
  check
    bool
    "merged json marks keeper names unknown"
    false
    Json.(json |> member "keeper_names_known" |> to_bool);
  check
    int
    "keeper meta scan error count"
    1
    Json.(json |> member "keeper_meta_read_error_count" |> to_int);
  check
    int
    "combined read error count"
    2
    Json.(json |> member "read_error_count" |> to_int);
  let read_errors = Json.(json |> member "read_errors" |> to_list) in
  check int "combined read errors" 2 (List.length read_errors);
  check
    bool
    "existing feed read error preserved"
    true
    (contains_substring
       ~needle:"existing_feed_error"
       (Yojson.Safe.to_string (`List read_errors)))
;;

(* --- Decision log tests --- *)

let test_parse_decision_event_result_surfaces_parse_errors () =
  let parse line_index line =
    Feeds.parse_decision_event_result
      ~keeper_name:"k2-decision-parser"
      ~line_index
      line
  in
  (match parse 7 "{not-json" with
   | Ok _ -> fail "expected malformed JSON to return Error"
   | Error error ->
     check int "json error line index" 7 error.Feeds.line_index;
     check bool "json error message present" true
       (String.length error.Feeds.message > 0));
  match parse 8 "[]" with
  | Ok _ -> fail "expected non-object JSON to return Error"
  | Error error ->
    check int "shape error line index" 8 error.Feeds.line_index;
    check bool "shape error message is specific" true
      (contains_substring
         ~needle:"dashboard decision log row must be object"
         error.Feeds.message)
;;

let test_decisions_log_evidence_refs_are_real_refs () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-decisions" in
  let path = Masc.Keeper_types_support.keeper_decision_log_path config meta.name in
  append_jsonl
    path
    (`Assoc
        [ "ts_unix", `Float 1_000.0
        ; "keeper_name", `String meta.name
        ; "summary", `String "prose summary is not an evidence ref"
        ]);
  append_jsonl
    path
    (`Assoc
        [ "ts_unix", `Float 1_001.0
        ; "keeper_name", `String meta.name
        ; "summary", `String "new prose summary"
        ; ( "evidence_refs"
          , `List [ `String "trace:k2"; `String ""; `String " artifact:k2 " ] )
        ]);
  let json = Dash.keeper_decisions_log_json ~config ~keepers:[ meta ] ~limit:10 () in
  let events = Json.(json |> member "events" |> to_list) in
  check int "events" 2 (List.length events);
  match events with
  | newest :: older :: _ ->
    check
      (list string)
      "real evidence refs"
      [ "trace:k2"; "artifact:k2" ]
      Json.(newest |> member "evidence_refs" |> strings);
    check
      (list string)
      "prose summary not used as evidence"
      []
      Json.(older |> member "evidence_refs" |> strings)
  | _ -> fail "expected newest and older events"
;;

let test_decisions_log_clamps_low_limit () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-decision-limit" in
  let path = Masc.Keeper_types_support.keeper_decision_log_path config meta.name in
  append_jsonl
    path
    (`Assoc
        [ "ts_unix", `Float 1_000.0
        ; "keeper_name", `String meta.name
        ]);
  let json = Dash.keeper_decisions_log_json ~config ~keepers:[ meta ] ~limit:0 () in
  check int "clamped limit" 1 Json.(json |> member "limit" |> to_int);
  check int "one event" 1 Json.(json |> member "events" |> to_list |> List.length)
;;

let test_decisions_log_clamps_high_limit () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-decision-hilimit" in
  let json = Dash.keeper_decisions_log_json ~config ~keepers:[ meta ] ~limit:999 () in
  check int "clamped high limit" 200 Json.(json |> member "limit" |> to_int)
;;

let test_decisions_log_json_shape () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-decisions-shape" in
  let path = Masc.Keeper_types_support.keeper_decision_log_path config meta.name in
  append_jsonl
    path
    (`Assoc
        [ "ts_unix", `Float 1_234.0
        ; "keeper_name", `String meta.name
        ; "outcome", `String "assert"
        ; "blocker", `String "missing config"
        ]);
  let json = Dash.keeper_decisions_log_json ~config ~keepers:[ meta ] ~limit:10 () in
  let events = Json.(json |> member "events" |> to_list) in
  check int "one event" 1 (List.length events);
  let event = List.hd events in
  check bool "has id" true (Json.(event |> member "id" |> to_string) <> "");
  check string "has ts" "1970-01-01T00:20:34Z" Json.(event |> member "ts" |> to_string);
  check (float 0.001) "ts_unix" 1234.0 Json.(event |> member "ts_unix" |> to_float);
  check string "keeper" meta.name Json.(event |> member "keeper" |> to_string);
  check
    string
    "decision_type"
    "assert"
    Json.(event |> member "decision_type" |> to_string);
  check
    bool
    "summary contains blocker"
    true
    (let s = Json.(event |> member "summary" |> to_string) in
     contains_substring ~needle:"blocked" s)
;;

let test_decisions_json_terminal_reason_duration_fallback () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-decision-terminal-duration" in
  let path = Masc.Keeper_types_support.keeper_decision_log_path config meta.name in
  append_jsonl
    path
    (`Assoc
        [ "ts_unix", `Float 1_300.0
        ; "keeper_name", `String meta.name
        ; "outcome", `String "error"
        ; "choice", `String "use_shell"
        ; "reason", `String "verify touched test target"
        ; ( "context"
          , `Assoc
              [ "file_path", `String "runtime.ts"
              ; "line", `Int 19
              ; "goal_id", `String "goal-decision"
              ; "task_id", `String "task-decision"
              ; "log_id", `String "decision-turn-19"
              ] )
        ; "latency_ms", `Int 321
        ; ( "terminal_reason"
          , `Assoc
              [ "code", `String "provider_error"
              ; "source", `String "typed"
              ; "severity", `String "bad"
              ; "summary", `String "provider failed"
              ] )
        ]);
  let compact =
    Dash.keeper_decisions_json ~config ~keepers:[ meta ] ~limit:10 ()
  in
  check string "compact dashboard surface" "/api/v1/dashboard/keeper-decisions"
    Json.(compact |> member "dashboard_surface" |> to_string);
  check string "compact source" "keeper_decision_log"
    Json.(compact |> member "source" |> to_string);
  check string "compact durable store" ".masc/keepers/:name.decisions.jsonl"
    Json.(compact |> member "retention" |> member "durable_store" |> to_string);
  let compact_event =
    match Json.(compact |> member "events" |> to_list) with
    | event :: _ -> event
    | [] -> fail "expected compact decision event"
  in
  check string "compact terminal reason" "provider_error"
    Json.(compact_event |> member "terminal_reason_code" |> to_string);
  check (float 0.001) "compact duration fallback" 321.0
    Json.(compact_event |> member "duration_ms" |> to_float);
  check string "compact choice" "use_shell"
    Json.(compact_event |> member "choice" |> to_string);
  check string "compact reason" "verify touched test target"
    Json.(compact_event |> member "reason" |> to_string);
  check string "compact context file" "runtime.ts"
    Json.(compact_event |> member "context" |> member "file_path" |> to_string);
  check int "compact context line" 19
    Json.(compact_event |> member "context" |> member "line" |> to_int);
  check string "compact context goal" "goal-decision"
    Json.(compact_event |> member "context" |> member "goal_id" |> to_string);
  check string "compact context task" "task-decision"
    Json.(compact_event |> member "context" |> member "task_id" |> to_string);
  check string "compact context log" "decision-turn-19"
    Json.(compact_event |> member "context" |> member "log_id" |> to_string);
  let log =
    Dash.keeper_decisions_log_json ~config ~keepers:[ meta ] ~limit:10 ()
  in
  let log_event =
    match Json.(log |> member "events" |> to_list) with
    | event :: _ -> event
    | [] -> fail "expected decision log event"
  in
  check string "log terminal reason" "provider_error"
    Json.(log_event |> member "terminal_reason_code" |> to_string);
  check (float 0.001) "log duration fallback" 321.0
    Json.(log_event |> member "duration_ms" |> to_float);
  check bool "log summary includes reason" true
    (let s = Json.(log_event |> member "summary" |> to_string) in
     contains_substring ~needle:"reason: provider_error" s)
;;

let test_decisions_json_surfaces_malformed_rows () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-decision-parse-errors" in
  let path = Masc.Keeper_types_support.keeper_decision_log_path config meta.name in
  let (_ : string) = Keeper_fs.ensure_dir (Filename.dirname path) in
  let valid_row =
    `Assoc
      [ "ts_unix", `Float 1_400.0
      ; "keeper_name", `String meta.name
      ; "event", `String "tool_exec"
      ; "outcome", `String "success"
      ]
    |> Yojson.Safe.to_string
  in
  write_file path ("{not-json\n" ^ valid_row ^ "\n[]\n");
  let json = Dash.keeper_decisions_json ~config ~keepers:[ meta ] ~limit:10 () in
  let events = Json.(json |> member "events" |> to_list) in
  check int "valid decision rows still surface" 1 (List.length events);
  check string "valid event type survives malformed neighbors" "tool_exec"
    Json.(List.hd events |> member "event_type" |> to_string);
  check int "root exposes parse error count" 2
    Json.(json |> member "read_error_count" |> to_int);
  let errors = Json.(json |> member "read_errors" |> to_list) in
  check int "root read errors" 2 (List.length errors);
  (match errors with
   | first :: _ ->
     check
       string
       "parse error source"
       "dashboard_keeper_decisions_jsonl"
       Json.(first |> member "source" |> to_string);
     check string "parse error keeper" meta.name
       Json.(first |> member "keeper" |> to_string)
   | [] -> fail "expected read errors")
;;

let test_decisions_log_json_surfaces_malformed_rows () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-decision-log-parse-errors" in
  let path = Masc.Keeper_types_support.keeper_decision_log_path config meta.name in
  let (_ : string) = Keeper_fs.ensure_dir (Filename.dirname path) in
  let valid_row =
    `Assoc
      [ "ts_unix", `Float 1_500.0
      ; "keeper_name", `String meta.name
      ; "outcome", `String "success"
      ; "channel", `String "reactive"
      ]
    |> Yojson.Safe.to_string
  in
  write_file path ("{not-json\n" ^ valid_row ^ "\n[]\n");
  let json = Dash.keeper_decisions_log_json ~config ~keepers:[ meta ] ~limit:10 () in
  let events = Json.(json |> member "events" |> to_list) in
  check int "valid log rows still surface" 1 (List.length events);
  check string "valid log decision type survives malformed neighbors" "success"
    Json.(List.hd events |> member "decision_type" |> to_string);
  check int "log feed exposes parse error count" 2
    Json.(json |> member "read_error_count" |> to_int);
  let errors = Json.(json |> member "read_errors" |> to_list) in
  check int "log feed read errors" 2 (List.length errors);
  (match errors with
   | first :: _ ->
     check
       string
       "log parse error source"
       "dashboard_keeper_decisions_log_jsonl"
       Json.(first |> member "source" |> to_string);
     check string "log parse error keeper" meta.name
       Json.(first |> member "keeper" |> to_string)
   | [] -> fail "expected log read errors")
;;

(* --- Memory log tests --- *)

let memory_horizon kind =
  match Masc.Keeper_memory_policy.memory_horizon_of_kind_opt kind with
  | Some horizon -> horizon
  | None -> fail ("unknown memory kind: " ^ kind)
;;

let memory_row ?(kind = "goal") ?(trace_id = "trace-memory") ?(generation = 1)
    ~ts text =
  `Assoc
    [ "schema_version", `Int 2
    ; "kind", `String kind
    ; "horizon", `String (memory_horizon kind)
    ; "source", `String "tool_result"
    ; "trace_id", `String trace_id
    ; "generation", `Int generation
    ; "text", `String text
    ; "priority", `Int 10
    ; "ts_unix", `Float ts
    ]
;;

let test_memory_log_ids_distinguish_same_timestamp_rows () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-memory" in
  let path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
  append_jsonl
    path
    (memory_row
       ~trace_id:"trace-memory-alpha"
       ~ts:2_000.0
       "Ship K2 memory feed row alpha");
  append_jsonl
    path
    (memory_row
       ~trace_id:"trace-memory-beta"
       ~ts:2_000.0
       "Ship K2 memory feed row beta");
  let json = Dash.keeper_memory_log_json ~config ~keepers:[ meta ] ~limit:999 () in
  check int "clamped high limit" 200 Json.(json |> member "limit" |> to_int);
  let entries = Json.(json |> member "entries" |> to_list) in
  check int "entries" 2 (List.length entries);
  let ids = entries |> List.map (fun row -> Json.(row |> member "id" |> to_string)) in
  match ids with
  | [ first; second ] -> check bool "ids differ" true (not (String.equal first second))
  | _ -> fail "expected two memory ids"
;;

let test_memory_log_kind_mapping () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-memory-kind" in
  let path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
  (* progress -> episode *)
  append_jsonl
    path
    (memory_row
       ~kind:"progress"
       ~trace_id:"trace-progress"
       ~ts:3_000.0
       "Progress memory row p1");
  (* goal -> plan *)
  append_jsonl
    path
    (memory_row
       ~kind:"goal"
       ~trace_id:"trace-goal"
       ~ts:3_001.0
       "Goal memory row g1");
  (* long_term -> fact *)
  append_jsonl
    path
    (memory_row
       ~kind:"long_term"
       ~trace_id:"trace-long-term"
       ~ts:3_002.0
       "Long-term memory row fact b1");
  let json = Dash.keeper_memory_log_json ~config ~keepers:[ meta ] ~limit:10 () in
  let entries = Json.(json |> member "entries" |> to_list) in
  check int "entries" 3 (List.length entries);
  let kinds = List.map (fun e -> Json.(e |> member "kind" |> to_string)) entries in
  (* sorted newest-first: long_term(3_002), goal(3_001), progress(3_000) *)
  check (list string) "kind mapping" [ "fact"; "plan"; "episode" ] kinds
;;

let test_memory_log_surfaces_malformed_rows () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-memory-parse-errors" in
  let path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
  let (_ : string) = Keeper_fs.ensure_dir (Filename.dirname path) in
  let valid_row =
    memory_row
      ~kind:"goal"
      ~trace_id:"trace-memory-parse-valid"
      ~ts:4_000.0
      "Goal memory parse visibility row"
    |> Yojson.Safe.to_string
  in
  write_file path ("{not-json\n" ^ valid_row ^ "\n[]\n");
  let json = Dash.keeper_memory_log_json ~config ~keepers:[ meta ] ~limit:10 () in
  let entries = Json.(json |> member "entries" |> to_list) in
  check int "valid memory rows still surface" 1 (List.length entries);
  check string "valid memory kind survives malformed neighbors" "plan"
    Json.(List.hd entries |> member "kind" |> to_string);
  check int "memory feed exposes parse error count" 2
    Json.(json |> member "read_error_count" |> to_int);
  let errors = Json.(json |> member "read_errors" |> to_list) in
  check int "memory feed read errors" 2 (List.length errors);
  (match errors with
   | first :: _ ->
     check
       string
       "memory parse error source"
       "dashboard_keeper_memory_log_jsonl"
       Json.(first |> member "source" |> to_string);
     check string "memory parse error keeper" meta.name
       Json.(first |> member "keeper" |> to_string)
   | [] -> fail "expected memory read errors")
;;

let () =
  run
    "dashboard_k2_feeds"
    [ ( "decision log"
      , [ test_case
            "provider route scan surfaces keeper-name discovery failure"
            `Quick
            test_provider_routes_keeper_scan_surfaces_keeper_names_failure
        ; test_case
            "provider route scan surfaces keeper meta read failure"
            `Quick
            test_provider_routes_keeper_scan_surfaces_meta_read_failure
        ; test_case
            "provider route feed JSON merges keeper scan read errors"
            `Quick
            test_provider_routes_feed_json_merges_keeper_scan_read_errors
        ; test_case
            "parse result surfaces malformed input"
            `Quick
            test_parse_decision_event_result_surfaces_parse_errors
        ; test_case
            "keeps prose out of evidence refs"
            `Quick
            test_decisions_log_evidence_refs_are_real_refs
        ; test_case "clamps low limit" `Quick test_decisions_log_clamps_low_limit
        ; test_case "clamps high limit" `Quick test_decisions_log_clamps_high_limit
        ; test_case "json shape matches spec" `Quick test_decisions_log_json_shape
        ; test_case
            "terminal reason and duration fallback"
            `Quick
            test_decisions_json_terminal_reason_duration_fallback
        ; test_case
            "compact feed surfaces malformed rows"
            `Quick
            test_decisions_json_surfaces_malformed_rows
        ; test_case
            "log feed surfaces malformed rows"
            `Quick
            test_decisions_log_json_surfaces_malformed_rows
        ] )
    ; ( "memory log"
      , [ test_case
            "ids distinguish same timestamp rows"
            `Quick
            test_memory_log_ids_distinguish_same_timestamp_rows
        ; test_case "kind mapping (episode/fact/plan)" `Quick test_memory_log_kind_mapping
        ; test_case
            "surfaces malformed memory rows"
            `Quick
            test_memory_log_surfaces_malformed_rows
        ] )
    ]
;;
