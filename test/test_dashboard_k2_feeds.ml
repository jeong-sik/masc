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
module Keeper_config = Masc.Keeper_config
module Keeper_fs = Masc.Keeper_fs
module Keeper_types = Keeper_types
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

(* --- Decision log tests --- *)

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

(* --- Memory log tests --- *)

let memory_horizon kind =
  match Masc.Keeper_memory_policy.memory_kind_of_wire kind with
  | Some memory_kind ->
    Masc.Keeper_memory_policy.memory_horizon_of_kind memory_kind
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

let () =
  run
    "dashboard_k2_feeds"
    [ ( "decision log"
      , [ test_case
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
        ] )
    ; ( "memory log"
      , [ test_case
            "ids distinguish same timestamp rows"
            `Quick
            test_memory_log_ids_distinguish_same_timestamp_rows
        ; test_case "kind mapping (episode/fact/plan)" `Quick test_memory_log_kind_mapping
        ] )
    ]
;;
