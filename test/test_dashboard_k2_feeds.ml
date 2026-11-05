(** Tests for the keeper decisions dashboard feed ([keeper_decisions_json]).

    Covers:
    - the requested limit clamps to the range 1 to 200
    - terminal reason and duration read from the decision-log row
    - usage, stop reason and error category read from the turn telemetry
      object *)

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
          ; "trace_id", `String ("trace-" ^ name)
          ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)
;;

let append_jsonl path json =
  let (_ : string) = Keeper_fs.ensure_dir (Filename.dirname path) in
  Masc.Keeper_types_support.append_jsonl_line path json
;;


(* --- Decision log tests --- *)

let test_decisions_json_clamps_limit () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-decision-limit" in
  let limit_of requested =
    Json.(
      Dash.keeper_decisions_json ~config ~keepers:[ meta ] ~limit:requested ()
      |> member "limit"
      |> to_int)
  in
  check int "low limit clamps to 1" 1 (limit_of 0);
  check int "high limit clamps to 200" 200 (limit_of 999)
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
    Json.(compact_event |> member "context" |> member "log_id" |> to_string)
;;

(* The turn row as Keeper_unified_metrics_decision writes it: usage, stop
   reason and error category sit inside [telemetry], never at the top level
   (#31729). *)
let test_decisions_json_reads_turn_telemetry () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-decision-telemetry" in
  let path = Masc.Keeper_types_support.keeper_decision_log_path config meta.name in
  append_jsonl
    path
    (`Assoc
        [ "event", `String "turn"
        ; "ts_unix", `Float 1_400.0
        ; "keeper_name", `String meta.name
        ; "outcome", `String "success"
        ; "latency_ms", `Int 900
        ; ( "telemetry"
          , `Assoc
              [ "outcome", `String "success"
              ; "stop_reason", `String "end_turn"
              ; "input_tokens", `Int 1200
              ; "output_tokens", `Int 340
              ; "cost_usd", `Float 0.0125
              ] )
        ]);
  append_jsonl
    path
    (`Assoc
        [ "event", `String "turn"
        ; "ts_unix", `Float 1_401.0
        ; "keeper_name", `String meta.name
        ; "outcome", `String "error"
        ; ( "telemetry"
          , `Assoc
              [ "error_category", `String "provider_error"
              ; "outcome", `String "error"
              ; "usage_reported", `Bool false
              ] )
        ]);
  let compact = Dash.keeper_decisions_json ~config ~keepers:[ meta ] ~limit:10 () in
  let failed, succeeded =
    match Json.(compact |> member "events" |> to_list) with
    | [ newest; older ] -> newest, older
    | events -> failf "expected two decision events, got %d" (List.length events)
  in
  check string "stop reason" "end_turn"
    Json.(succeeded |> member "stop_reason" |> to_string);
  check int "input tokens" 1200 Json.(succeeded |> member "input_tokens" |> to_int);
  check int "output tokens" 340 Json.(succeeded |> member "output_tokens" |> to_int);
  check (float 1e-9) "cost" 0.0125 Json.(succeeded |> member "cost_usd" |> to_float);
  check string "error category" "provider_error"
    Json.(failed |> member "error_category" |> to_string);
  check bool "an unreported cost stays null" true
    (Json.(failed |> member "cost_usd") = `Null)
;;

let () =
  run
    "dashboard_k2_feeds"
    [ ( "decision log"
      , [ test_case
            "clamps the requested limit"
            `Quick
            test_decisions_json_clamps_limit
        ; test_case
            "terminal reason and duration fallback"
            `Quick
            test_decisions_json_terminal_reason_duration_fallback
        ; test_case
            "turn telemetry fields come from the telemetry object"
            `Quick
            test_decisions_json_reads_turn_telemetry
        ] )
    ]
;;
