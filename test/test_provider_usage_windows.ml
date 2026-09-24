(* Provider usage windows, end to end on the operator surface: a report as the
   CLI sent it is decoded, recorded against the runtime's quota scope, and
   read back from GET /api/v1/runtime/resolved. *)

open Alcotest
open Masc
module Usage = Runtime_provider_usage_window

(* Claude Code 2.1.280 stream-json, captured 2026-09-23 from a real turn. *)
let claude_fixture_path = "fixtures/claude-code-2.1.280-rate-limit-event.jsonl"

(* Shape from codex-cli 0.156.0's generated schema
   (v2/AccountRateLimitsUpdatedNotification.json): both windows used up. *)
let codex_exhausted_params =
  {|{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1790200000},"secondary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1790640000},"credits":null,"planType":"pro","rateLimitReachedType":null}}|}
;;

(* A sparse update: null windows carry no value this time. *)
let codex_sparse_params =
  {|{"rateLimits":{"limitId":"codex","primary":null,"secondary":null}}|}
;;

let runtime_toml =
  "[providers.usage_claude]\n\
   protocol = \"claude-code\"\n\
   command = \"/usr/bin/true\"\n\
   is-non-interactive = true\n\
   \n\
   [providers.usage_codex]\n\
   protocol = \"codex-app-server\"\n\
   command = \"/usr/bin/true\"\n\
   is-non-interactive = true\n\
   \n\
   [models.sonnet]\n\
   api-name = \"sonnet\"\n\
   max-context = 200000\n\
   \n\
   [models.sol]\n\
   api-name = \"gpt-5.6-sol\"\n\
   max-context = 400000\n\
   \n\
   [usage_claude.sonnet]\n\
   \n\
   [usage_codex.sol]\n\
   \n\
   [runtime]\n\
   default = \"usage_claude.sonnet\"\n"
;;

let with_temp_file ~suffix content f =
  let path = Filename.temp_file "provider-usage-windows" suffix in
  Out_channel.with_open_bin path (fun oc -> output_string oc content);
  Fun.protect ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ()) (fun () -> f path)
;;

(* The table is process-wide and has no reset. This binary is the only one
   that records into it, and its provider ids are its own, so the scopes it
   reads start empty. *)
let with_runtimes f =
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       with_temp_file ~suffix:".toml" runtime_toml (fun path ->
         match Runtime.init_default ~config_path:path with
         | Error msg -> failf "fixture runtime.toml should load: %s" msg
         | Ok () -> f ()))
;;

let scope_of runtime_id =
  match Runtime.quota_scope_of_runtime_id runtime_id with
  | Some scope -> scope
  | None -> failf "runtime %s has no quota scope" runtime_id
;;

let decode_ok = function
  | Ok (report : Usage.report) -> report
  | Error error -> fail (Usage.decode_error_to_string error)
;;

let resolved () =
  Server_dashboard_runtime_resolved_json.build
    ~generated_at_iso:"2026-09-23T00:00:00Z"
    ~config:(Workspace.default_config (Filename.get_temp_dir_name ()))
;;

let usage_row json scope_label =
  Yojson.Safe.Util.(json |> member "provider_usage_windows" |> to_list)
  |> List.find_opt (fun row -> Yojson.Safe.Util.(row |> member "scope" |> to_string) = scope_label)
  |> function
  | Some row -> row
  | None -> failf "no provider_usage_windows row for %s" scope_label
;;

let runtime_row json id =
  Yojson.Safe.Util.(json |> member "runtimes" |> to_list)
  |> List.find (fun row -> Yojson.Safe.Util.(row |> member "id" |> to_string) = id)
;;

let window_summary row =
  Yojson.Safe.Util.(
    row
    |> member "windows"
    |> to_list
    |> List.map (fun window ->
      Printf.sprintf
        "%s %s=%s resets=%s source=%s"
        (window |> member "window" |> member "kind" |> to_string)
        (window |> member "utilization" |> member "unit" |> to_string)
        (Yojson.Safe.to_string (window |> member "utilization" |> member "value"))
        (Yojson.Safe.to_string (window |> member "resets_at"))
        (window |> member "source" |> to_string)))
;;

let test_reports_reach_the_resolved_document () =
  with_runtimes @@ fun () ->
  let claude_scope = scope_of "usage_claude.sonnet" in
  let codex_scope = scope_of "usage_codex.sol" in
  let claude_label = Runtime_quota_window.scope_to_string claude_scope in
  let codex_label = Runtime_quota_window.scope_to_string codex_scope in
  (* Before any report both scopes are listed, and say so. *)
  let before = resolved () in
  check bool "since is the process start" true
    (Yojson.Safe.Util.(before |> member "provider_usage_windows_since" |> to_number)
     = Usage.recording_since);
  List.iter
    (fun label ->
       let row = usage_row before label in
       check string (label ^ " state before any report") "not_reported_since_start"
         Yojson.Safe.Util.(row |> member "state" |> to_string);
       check int (label ^ " has no windows") 0 (List.length (window_summary row)))
    [ claude_label; codex_label ];
  let claude_line = In_channel.with_open_bin claude_fixture_path In_channel.input_all in
  let claude_report =
    decode_ok (Usage.decode_claude_rate_limit_event (Yojson.Safe.from_string claude_line))
  in
  Usage.record ~scope:claude_scope ~observed_at:1790180000.0 claude_report;
  let codex_report =
    decode_ok (Usage.decode_codex_rate_limits_updated (Yojson.Safe.from_string codex_exhausted_params))
  in
  Usage.record ~scope:codex_scope ~observed_at:1790180100.0 codex_report;
  (* A later sparse update names no window; what was heard stands. *)
  Usage.record
    ~scope:codex_scope
    ~observed_at:1790180200.0
    (decode_ok (Usage.decode_codex_rate_limits_updated (Yojson.Safe.from_string codex_sparse_params)));
  let after = resolved () in
  let claude_row = usage_row after claude_label in
  check string "claude state" "reported" Yojson.Safe.Util.(claude_row |> member "state" |> to_string);
  check (list string) "claude windows as reported"
    [ "five_hour fraction=0.67 resets=1790187000 source=claude_code.rate_limit_event"
    ; "seven_day fraction=0.44 resets=1790640000 source=claude_code.rate_limit_event"
    ]
    (window_summary claude_row);
  check (list string) "claude providers" [ "usage_claude" ]
    Yojson.Safe.Util.(claude_row |> member "providers" |> to_list |> List.map to_string);
  let codex_row = usage_row after codex_label in
  check (list string) "codex windows as reported, sparse update kept them"
    [ "five_hour percent=100 resets=1790200000 source=codex.account_rate_limits_updated"
    ; "seven_day percent=100 resets=1790640000 source=codex.account_rate_limits_updated"
    ]
    (window_summary codex_row);
  List.iter
    (fun window ->
       check string "codex limit id" "codex"
         Yojson.Safe.Util.(window |> member "limit_id" |> to_string);
       check (float 0.0) "observed_at of the report that named the window" 1790180100.0
         Yojson.Safe.Util.(window |> member "observed_at" |> to_number))
    Yojson.Safe.Util.(codex_row |> member "windows" |> to_list);
  (* An observation, not a gate: 100 % used leaves the runtime's quota state
     untouched. *)
  check bool "codex runtime is not held back by a usage report" false
    Yojson.Safe.Util.(runtime_row after "usage_codex.sol" |> member "quota_exhausted" |> to_bool)
;;

let test_malformed_window_is_a_typed_error () =
  let line =
    {|{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":"67%","resetsAt":1790187000}}},"session_id":"s"}|}
  in
  match Usage.decode_claude_rate_limit_event (Yojson.Safe.from_string line) with
  | Error (Usage.Wrong_type { path; expected = _ }) ->
    check string "names the field"
      "rate_limit_event.rate_limit_info.unifiedWindows.five_hour.utilization" path
  | Error error -> failf "unexpected error: %s" (Usage.decode_error_to_string error)
  | Ok _ -> fail "a string utilization was accepted"
;;

let () =
  run
    "provider_usage_windows"
    [ ( "resolved"
      , [ test_case "reports reach the resolved document" `Quick
            test_reports_reach_the_resolved_document
        ; test_case "malformed window is a typed error" `Quick
            test_malformed_window_is_a_typed_error
        ] )
    ]
;;
