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

let runtime_scope_label json id =
  Yojson.Safe.Util.(runtime_row json id |> member "quota_scope" |> to_string)
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
  let before = resolved () in
  let claude_label = runtime_scope_label before "usage_claude.sonnet" in
  let codex_label = runtime_scope_label before "usage_codex.sol" in
  (* Before any report both scopes are listed, and say so. *)
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

let test_official_client_home_owns_usage_across_provider_rows () =
  let snapshot = Runtime.For_testing.snapshot () in
  let temp = Filename.get_temp_dir_name () in
  let home_a = Filename.concat temp "masc-usage-home-a" in
  let home_b = Filename.concat temp "masc-usage-home-b" in
  let config first_home second_home =
    Printf.sprintf
      {|[providers.usage_shared_one]
protocol = "claude-code"
command = "/usr/bin/true"
is-non-interactive = true
account-home = %S

[providers.usage_shared_two]
protocol = "claude-code"
command = "/usr/bin/true"
is-non-interactive = true
account-home = %S

[models.sonnet]
api-name = "sonnet"
max-context = 200000

[usage_shared_one.sonnet]
[usage_shared_two.sonnet]

[runtime]
default = "usage_shared_one.sonnet"
|}
      first_home second_home
  in
  let load source =
    with_temp_file ~suffix:".toml" source (fun path ->
      match Runtime.init_default ~config_path:path with
      | Ok () -> ()
      | Error msg -> failf "fixture runtime.toml should load: %s" msg)
  in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       load (config home_a home_a);
       let old_scope = scope_of "usage_shared_one.sonnet" in
       let shared_scope = scope_of "usage_shared_two.sonnet" in
       check bool "same CLI home shares one quota scope" true
         (Runtime_quota_window.scope_equal old_scope shared_scope);
       let report =
         In_channel.with_open_bin claude_fixture_path In_channel.input_all
         |> Yojson.Safe.from_string
         |> Usage.decode_claude_rate_limit_event
         |> decode_ok
       in
       Usage.record ~scope:old_scope ~observed_at:1790180000.0 report;
       let first = resolved () in
       let shared_label = runtime_scope_label first "usage_shared_one.sonnet" in
       check string "same CLI home has one public account id" shared_label
         (runtime_scope_label first "usage_shared_two.sonnet");
       let shared_row = usage_row first shared_label in
       check (list string) "both provider ids share the reported row"
         [ "usage_shared_one"; "usage_shared_two" ]
         Yojson.Safe.Util.(shared_row |> member "providers" |> to_list |> List.map to_string);
       check bool "first account path is absent from public JSON" false
         (String_util.contains_substring (Yojson.Safe.to_string first) home_a);
       load (config home_b home_a);
       let new_scope = scope_of "usage_shared_one.sonnet" in
       check bool "changed home has a different scope" false
         (Runtime_quota_window.scope_equal old_scope new_scope);
       let after = resolved () in
       let fresh_label = runtime_scope_label after "usage_shared_one.sonnet" in
       let retained_label = runtime_scope_label after "usage_shared_two.sonnet" in
       check bool "distinct CLI homes have distinct public account ids" false
         (String.equal fresh_label retained_label);
       let fresh_row = usage_row after fresh_label in
       check string "changed home has no report" "not_reported_since_start"
         Yojson.Safe.Util.(fresh_row |> member "state" |> to_string);
       let retained_row = usage_row after retained_label in
       check (list string) "old report belongs only to the unchanged home"
         [ "usage_shared_two" ]
         Yojson.Safe.Util.(retained_row |> member "providers" |> to_list |> List.map to_string);
       let public_json = Yojson.Safe.to_string after in
       List.iter
         (fun home ->
            check bool ("account path is absent from public JSON: " ^ home) false
              (String_util.contains_substring public_json home))
         [ home_a; home_b ];
       let unconfigured_count json =
         Yojson.Safe.Util.(json |> member "provider_usage_windows" |> to_list)
         |> List.filter (fun row ->
           Yojson.Safe.Util.(row |> member "providers" |> to_list) = [])
         |> List.length
       in
       let before_retirement = unconfigured_count after in
       load (config home_b home_b);
       let retired = resolved () in
       check int "retired account keeps one unconfigured report"
         (before_retirement + 1) (unconfigured_count retired);
       check bool "retired home path is absent from public JSON" false
         (String_util.contains_substring (Yojson.Safe.to_string retired) home_a))
;;

let test_default_and_explicit_home_share_scope
    ~client ~protocol ~model ~api_name ~max_context ~resolve_home () =
  let home =
    match resolve_home None with
    | Some path -> path
    | None -> failf "%s default home cannot be resolved" client
  in
  let implicit_id = "usage_" ^ client ^ "_default" in
  let explicit_id = "usage_" ^ client ^ "_explicit" in
  let source =
    Printf.sprintf
      {|[providers.%s]
protocol = %S
command = "/usr/bin/true"
is-non-interactive = true

[providers.%s]
protocol = %S
command = "/usr/bin/true"
is-non-interactive = true
account-home = %S

[models.%s]
api-name = %S
max-context = %d

[%s.%s]
[%s.%s]

[runtime]
default = %S
|}
      implicit_id protocol explicit_id protocol home model api_name max_context
      implicit_id model explicit_id model (implicit_id ^ "." ^ model)
  in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       with_temp_file ~suffix:".toml" source (fun path ->
         match Runtime.init_default ~config_path:path with
         | Ok () -> ()
         | Error msg -> failf "fixture runtime.toml should load: %s" msg);
       let implicit = scope_of (implicit_id ^ "." ^ model) in
       let explicit = scope_of (explicit_id ^ "." ^ model) in
       check bool (client ^ " implicit and explicit same home share scope") true
         (Runtime_quota_window.scope_equal implicit explicit);
       let json = resolved () in
       let implicit_label = runtime_scope_label json (implicit_id ^ "." ^ model) in
       check string "implicit and explicit home have one public account id" implicit_label
         (runtime_scope_label json (explicit_id ^ "." ^ model));
       let row = usage_row json implicit_label in
       check (list string) "one row names both providers"
         [ implicit_id; explicit_id ]
         Yojson.Safe.Util.(row |> member "providers" |> to_list |> List.map to_string);
       check bool "default home path is absent from public JSON" false
         (String_util.contains_substring (Yojson.Safe.to_string json) home))
;;

let test_codex_default_and_explicit_home_share_scope =
  test_default_and_explicit_home_share_scope
    ~client:"codex" ~protocol:"codex-app-server" ~model:"sol"
    ~api_name:"gpt-5.6-sol" ~max_context:400000
    ~resolve_home:Runtime_codex_app_server.effective_account_home
;;

let test_claude_default_and_explicit_home_share_scope =
  test_default_and_explicit_home_share_scope
    ~client:"claude" ~protocol:"claude-code" ~model:"sonnet"
    ~api_name:"sonnet" ~max_context:200000
    ~resolve_home:Runtime_claude_code.effective_account_home
;;

(* A read without the per-limit map falls back to the single [rateLimits];
   a map of the wrong type is refused with its path, not skipped. *)
let test_codex_read_falls_back_and_refuses_a_bad_map () =
  let read json = Usage.decode_codex_rate_limits_read (Yojson.Safe.from_string json) in
  let single =
    decode_ok
      (read
         {|{"rateLimits":{"limitId":"codex","primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1790300000}},"rateLimitsByLimitId":null}|})
  in
  check string "source" "codex.account_rate_limits_read" (Usage.source_to_string single.source);
  check int "the single snapshot is read" 1 (List.length single.windows);
  match read {|{"rateLimits":{"primary":null},"rateLimitsByLimitId":[1]}|} with
  | Error (Usage.Wrong_type { path; expected = _ }) ->
    check string "names the map" "account/rateLimits/read.rateLimitsByLimitId" path
  | Error error -> failf "unexpected error: %s" (Usage.decode_error_to_string error)
  | Ok _ -> fail "a list map was accepted"
;;

(* --- HTTP usage endpoints: responses captured 2026-09-24, identifiers
   removed. --- *)

let openrouter_key_response =
  {|{"data":{"label":"k","limit":100,"limit_reset":null,"limit_remaining":0,"usage":100.034,"usage_daily":0,"usage_weekly":33.86,"usage_monthly":100.03,"is_free_tier":false,"free_model_daily_requests":{"used":0,"limit":1000,"remaining":1000}}}|}
;;

let zai_quota_limit_response =
  {|{"code":200,"msg":"Operation successful","success":true,"data":{"level":"max","limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"usage":4000,"currentValue":270,"remaining":3730,"percentage":6,"nextResetTime":1790326488997,"usageDetails":[{"modelCode":"search-prime","usage":270}]},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":4,"nextResetTime":1790259391823}]}}|}
;;

let kimi_coding_usages_response =
  {|{"usage":{"limit":"100","used":"15","remaining":"85","resetTime":"2026-09-30T10:10:16.485718Z"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"20","remaining":"80","resetTime":"2026-09-24T15:10:16.485718Z"}}],"usages":{"limit_5h":{"used_ratio":0,"reset_time":"2026-09-24T15:10:15Z"},"limit_7d":{"used_ratio":0,"reset_time":"2026-09-30T10:10:15Z"}},"booster_wallet":{"balance":"0"}}|}
;;

let ollama_usage_response =
  {|{"activity":{"requests":1},"limits":{"session":{"usage":0,"models":[]},"weekly":{"usage":1,"models":[{"name":"m","request_count":48876}]}}}|}
;;

let kind_to_string : Usage.window_kind -> string = function
  | Five_hour -> "five_hour"
  | Seven_day -> "seven_day"
  | Duration_minutes minutes -> Printf.sprintf "%d minutes" minutes
  | Provider_label label -> Printf.sprintf "label %S" label
;;

let utilization_to_string : Usage.utilization -> string = function
  | Fraction value -> Printf.sprintf "fraction %g" value
  | Percent value -> Printf.sprintf "percent %d" value
;;

(* Every field of a window, so a decoder that changes any of them fails. *)
let window_to_string (window : Usage.window) =
  Printf.sprintf
    "limit=%s %s %s resets=%s"
    (Option.value ~default:"-" window.limit_id)
    (kind_to_string window.kind)
    (utilization_to_string window.utilization)
    (Option.fold ~none:"-" ~some:string_of_int window.resets_at)
;;

let decoded_windows decode ~source body =
  let report = decode_ok (decode (Yojson.Safe.from_string body)) in
  check string "source" source (Usage.source_to_string report.source);
  List.map window_to_string report.windows
;;

let refused decode body =
  match decode (Yojson.Safe.from_string body) with
  | Error error -> Usage.decode_error_to_string error
  | Ok (_ : Usage.report) -> failf "accepted: %s" body
;;

let test_openrouter_key () =
  check (list string) "windows"
    [ "limit=- label \"credit limit\" fraction 1 resets=-"
    ; "limit=- label \"free model requests, daily\" fraction 0 resets=-"
    ]
    (decoded_windows Usage.decode_openrouter_key ~source:"openrouter.key"
       openrouter_key_response);
  check (list string) "a stated reset period is not part of the label, which keys the row"
    [ "limit=- label \"credit limit\" fraction 0.25 resets=-" ]
    (decoded_windows Usage.decode_openrouter_key ~source:"openrouter.key"
       {|{"data":{"limit":20,"limit_reset":"monthly","limit_remaining":15}}|});
  check (list string) "a null limit has no credit window" []
    (decoded_windows Usage.decode_openrouter_key ~source:"openrouter.key"
       {|{"data":{"limit":null,"limit_remaining":null}}|});
  check string "limit_remaining as a string is refused with its path"
    "openrouter-key.data.limit_remaining must be a number"
    (refused Usage.decode_openrouter_key
       {|{"data":{"limit":100,"limit_remaining":"0"}}|});
  check string "limit_remaining above limit is refused"
    "openrouter-key.data.limit_remaining must be within 0..100"
    (refused Usage.decode_openrouter_key {|{"data":{"limit":100,"limit_remaining":150}}|});
  check string "a negative limit_remaining is refused"
    "openrouter-key.data.limit_remaining must be within 0..100"
    (refused Usage.decode_openrouter_key {|{"data":{"limit":100,"limit_remaining":-1}}|});
  check string "free requests used above limit is refused"
    "openrouter-key.data.free_model_daily_requests.used must be within 0..1000"
    (refused Usage.decode_openrouter_key
       {|{"data":{"limit":null,"free_model_daily_requests":{"used":1001,"limit":1000}}}|})
;;

let test_zai_quota_limit () =
  check (list string) "windows"
    [ "limit=TIME_LIMIT label \"TIME_LIMIT, 1 x unit 5\" percent 6 resets=1790326488"
    ; "limit=TOKENS_LIMIT five_hour percent 4 resets=1790259391"
    ]
    (decoded_windows Usage.decode_zai_quota_limit ~source:"zai.quota_limit"
       zai_quota_limit_response);
  check (list string) "same limit type with known and unknown unit codes stays distinct"
    [ "limit=CREDIT_LIMIT five_hour percent 12 resets=-"
    ; "limit=CREDIT_LIMIT label \"CREDIT_LIMIT, 1 x unit 6\" percent 34 resets=-"
    ]
    (decoded_windows Usage.decode_zai_quota_limit ~source:"zai.quota_limit"
       {|{"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":12},{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":34}]}}|});
  check string "success false is refused with its msg"
    "zai-quota-limit.success is not true: Unauthorized"
    (refused Usage.decode_zai_quota_limit
       {|{"code":401,"msg":"Unauthorized","success":false,"data":null}|});
  check string "a missing percentage is refused with its path"
    "zai-quota-limit.data.limits[0].percentage is missing"
    (refused Usage.decode_zai_quota_limit
       {|{"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5}]}}|});
  check string "a percentage above 100 is refused"
    "zai-quota-limit.data.limits[0].percentage must be within 0..100"
    (refused Usage.decode_zai_quota_limit
       {|{"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":101}]}}|});
  check string "a negative percentage is refused"
    "zai-quota-limit.data.limits[0].percentage must be within 0..100"
    (refused Usage.decode_zai_quota_limit
       {|{"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":-1}]}}|});
  check string "a number of 0 is refused"
    "zai-quota-limit.data.limits[0].number must be greater than 0"
    (refused Usage.decode_zai_quota_limit
       {|{"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":0,"percentage":4}]}}|});
  check string "two rows with one (limit_id, kind) are refused, not last-wins"
    "zai-quota-limit.data states the window (limit TOKENS_LIMIT, 5h) twice"
    (refused Usage.decode_zai_quota_limit
       {|{"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":4},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":90}]}}|})
;;

let test_kimi_coding_usages () =
  check (list string) "windows; usages.*.used_ratio is not read"
    [ "limit=- five_hour fraction 0.2 resets=1790262616"
    ; "limit=- label \"usage (provider resetTime)\" fraction 0.15 resets=1790763016"
    ]
    (decoded_windows Usage.decode_kimi_coding_usages ~source:"kimi_coding.usages"
       kimi_coding_usages_response);
  check (list string) "10080 minutes is seven_day"
    [ "limit=- seven_day fraction 0.5 resets=-" ]
    (decoded_windows Usage.decode_kimi_coding_usages ~source:"kimi_coding.usages"
       {|{"limits":[{"window":{"duration":10080,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"10","used":"5"}}]}|});
  check string "an hour unit is refused, not converted"
    "kimi-coding-usages.limits[0].window.timeUnit must be TIME_UNIT_MINUTE"
    (refused Usage.decode_kimi_coding_usages
       {|{"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"100","used":"20"}}]}|});
  check string "a count that is not all digits is refused"
    "kimi-coding-usages.limits[0].detail.used must be a decimal integer string"
    (refused Usage.decode_kimi_coding_usages
       {|{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"12a"}}]}|});
  check string "used above limit is refused"
    "kimi-coding-usages.limits[0].detail.used must be within 0..100"
    (refused Usage.decode_kimi_coding_usages
       {|{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"101"}}]}|});
  check string "plan usage above limit is refused"
    "kimi-coding-usages.usage.used must be within 0..10"
    (refused Usage.decode_kimi_coding_usages
       {|{"limits":[],"usage":{"limit":"10","used":"11"}}|});
  check string "a duration of 0 is refused"
    "kimi-coding-usages.limits[0].window.duration must be greater than 0"
    (refused Usage.decode_kimi_coding_usages
       {|{"limits":[{"window":{"duration":0,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"20"}}]}|});
  check string "two limits of one length are refused, not last-wins"
    "kimi-coding-usages states the window (5h) twice"
    (refused Usage.decode_kimi_coding_usages
       {|{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"20"}},{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"90"}}]}|})
;;

let test_ollama_usage () =
  check (list string) "windows"
    [ "limit=- label \"session\" fraction 0 resets=-"
    ; "limit=- seven_day fraction 1 resets=-"
    ]
    (decoded_windows Usage.decode_ollama_usage ~source:"ollama.usage" ollama_usage_response);
  check (list string) "a float usage is a fraction; a missing entry is no window"
    [ "limit=- seven_day fraction 0.42 resets=-" ]
    (decoded_windows Usage.decode_ollama_usage ~source:"ollama.usage"
       {|{"limits":{"weekly":{"usage":0.42}}}|});
  check string "a missing limits object is refused" "ollama-usage.limits is missing"
    (refused Usage.decode_ollama_usage {|{"activity":{}}|});
  check string "usage above 1 is refused" "ollama-usage.limits.weekly.usage must be within 0..1"
    (refused Usage.decode_ollama_usage {|{"limits":{"weekly":{"usage":1.5}}}|});
  check string "a negative usage is refused" "ollama-usage.limits.session.usage must be within 0..1"
    (refused Usage.decode_ollama_usage {|{"limits":{"session":{"usage":-0.1}}}|})
;;

(* --- Reading scopes: the fetch is injected, so no request leaves. --- *)

module Read = Runtime_provider_usage_read

let http_readable ~provider_id ~url ~key =
  { Read.scope = Runtime_quota_window.scope_of_credential ~provider_id None
  ; how =
      Http
        { credential = Llm_provider.Provider_config.Static_credential, Llm_provider.Secret.of_string key
        ; usage_read = { shape = Runtime_schema.Ollama_usage; url }
        }
  }
;;

let reported scope =
  match Usage.state ~scope with
  | Usage.Reported _ -> true
  | Usage.Not_reported_since_start -> false
;;

let codex_exec : Runtime_execution.codex_app_server =
  { Runtime_execution.cli_path = "/usr/bin/true"; account_home = None; model = None; timeout_s = 1.0 }

(* One scope raising, over HTTP or through Codex, is logged and the scopes
   after it are still read. *)
let test_a_raising_scope_does_not_stop_the_rest () =
  let raising = http_readable ~provider_id:"usage_read_raises" ~url:"https://raise.invalid" ~key:"k" in
  let codex_raising =
    { Read.scope = Runtime_quota_window.scope_of_credential ~provider_id:"usage_read_codex_raises" None
    ; how = Codex codex_exec
    }
  in
  let after = http_readable ~provider_id:"usage_read_after" ~url:"https://ok.invalid" ~key:"k" in
  let fetch ~api_key:_ url =
    if String.equal url "https://ok.invalid"
    then Ok ollama_usage_response
    else failwith "connection closed by peer"
  in
  let codex ~scope:_ _ = failwith "codex app-server died" in
  Read.read_scopes ~codex ~fetch [ raising; codex_raising; after ];
  check bool "the raising scope recorded nothing" false (reported raising.scope);
  check bool "the scope after it was read" true (reported after.scope)
;;

(* An empty key is refused before any request. *)
let test_an_empty_key_sends_no_request () =
  let empty = http_readable ~provider_id:"usage_read_empty_key" ~url:"https://ok.invalid" ~key:"" in
  let fetch ~api_key:_ _ = fail "a request was sent with an empty key" in
  Read.read_scopes ~codex:(fun ~scope:_ _ -> Ok ()) ~fetch [ empty ];
  check bool "nothing recorded" false (reported empty.scope)
;;

let () =
  run
    "provider_usage_windows"
    [ ( "resolved"
      , [ test_case "reports reach the resolved document" `Quick
            test_reports_reach_the_resolved_document
        ; test_case "malformed window is a typed error" `Quick
            test_malformed_window_is_a_typed_error
        ; test_case "official client home owns usage" `Quick
            test_official_client_home_owns_usage_across_provider_rows
        ; test_case "Codex default and explicit home share scope" `Quick
            test_codex_default_and_explicit_home_share_scope
        ; test_case "Claude default and explicit home share scope" `Quick
            test_claude_default_and_explicit_home_share_scope
        ; test_case "codex read falls back and refuses a bad map" `Quick
            test_codex_read_falls_back_and_refuses_a_bad_map
        ] )
    ; ( "http usage endpoints"
      , [ test_case "openrouter-key" `Quick test_openrouter_key
        ; test_case "zai-quota-limit" `Quick test_zai_quota_limit
        ; test_case "kimi-coding-usages" `Quick test_kimi_coding_usages
        ; test_case "ollama-usage" `Quick test_ollama_usage
        ] )
    ; ( "reading scopes"
      , [ test_case "a raising scope does not stop the rest" `Quick
            test_a_raising_scope_does_not_stop_the_rest
        ; test_case "an empty key sends no request" `Quick test_an_empty_key_sends_no_request
        ] )
    ]
;;
