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

(* The body in MoonshotAI/kimi-code#3951, the same shape the live endpoint
   answered on 2026-09-25: a count whose value is zero is left out, so the
   5-hour [detail] has no [used] and the weekly [usage] no [remaining]. *)
let kimi_coding_usages_zero_counts_left_out =
  {|{"usage":{"limit":"100","used":"100","resetTime":"2026-09-24T02:09:07.465054Z"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","remaining":"100","resetTime":"2026-09-21T01:09:07.465054Z"}}],"usages":{"limit_5h":{"used_ratio":0,"reset_time":"2026-09-21T01:09:06Z"},"limit_7d":{"used_ratio":0,"reset_time":"2026-09-24T02:09:06Z"}}}|}
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
  check (list string) "a count left out is read from the other one"
    [ "limit=- five_hour fraction 0 resets=1789952947"
    ; "limit=- label \"usage (provider resetTime)\" fraction 1 resets=1790215747"
    ]
    (decoded_windows Usage.decode_kimi_coding_usages ~source:"kimi_coding.usages"
       kimi_coding_usages_zero_counts_left_out);
  check string "used and remaining that do not add up to the limit are refused"
    "kimi-coding-usages.limits[0].detail.remaining must be 80 (limit - used)"
    (refused Usage.decode_kimi_coding_usages
       {|{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"20","remaining":"70"}}]}|});
  check string "neither used nor remaining is refused"
    "kimi-coding-usages.limits[0].detail.used or remaining is missing"
    (refused Usage.decode_kimi_coding_usages
       {|{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100"}}]}|});
  check string "remaining above limit is refused"
    "kimi-coding-usages.limits[0].detail.remaining must be within 0..100"
    (refused Usage.decode_kimi_coding_usages
       {|{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","remaining":"101"}}]}|});
  check (list string) "a null count is a count left out"
    [ "limit=- five_hour fraction 0.25 resets=-" ]
    (decoded_windows Usage.decode_kimi_coding_usages ~source:"kimi_coding.usages"
       {|{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":null,"remaining":"75"}}]}|});
  check (list string) "no remaining is all of the limit used"
    [ "limit=- five_hour fraction 1 resets=-" ]
    (decoded_windows Usage.decode_kimi_coding_usages ~source:"kimi_coding.usages"
       {|{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","remaining":"0"}}]}|});
  check string "used above limit is refused when remaining is present too"
    "kimi-coding-usages.limits[0].detail.used must be within 0..100"
    (refused Usage.decode_kimi_coding_usages
       {|{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"101","remaining":"0"}}]}|});
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

(* agy 1.2.11's answer to [agy -p "/usage" --output-format json], taken on
   2026-09-26. The last bucket is disabled: the weekly limit of its group is
   spent, so the 5-hour one does not apply. *)
let antigravity_usage_response =
  {|{"conversation_id":"","status":"SUCCESS","response":"Gemini Models\tWeekly Limit Remaining\t10%\t2026-09-30T02:25:23Z\nGemini Models\tFive Hour Limit Remaining\t75%\t2026-09-26T06:57:49Z\nClaude and GPT models\tWeekly Limit Remaining\t0%\t2026-09-28T07:40:27Z\nClaude and GPT models\tFive Hour Limit Remaining\tdisabled\t\n","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"command":{"name":"usage","data":{"description":"Within each group, models share a weekly limit and a 5-hour limit. Quota is consumed proportionally to the cost of the tokens. Thus, limits will last longer with shorter tasks or using more cost-effective models. The 5-hour limit smooths out aggregate demand to fairly distribute global capacity across all users, while your weekly limit is tied directly to your individual tier.","groups":[{"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","description":"You have used some of your weekly limit, it will fully refresh in 3 days, 23 hours.","window":"weekly","remaining_fraction":0.10123226791620255,"reset_time":"2026-09-30T02:25:23Z"},{"id":"gemini-5h","name":"Five Hour Limit Remaining","description":"You have used some of your 5-hour limit, it will fully refresh in 4 hours, 28 minutes.","window":"5h","remaining_fraction":0.7511405348777771,"reset_time":"2026-09-26T06:57:49Z"}]},{"name":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[{"id":"3p-weekly","name":"Weekly Limit Remaining","description":"You have hit your weekly limit, it refreshes in 2 days, 5 hours. If on a supported paid plan, you can use AI credits in the interim or upgrade to a higher tier.","window":"weekly","remaining_fraction":0,"reset_time":"2026-09-28T07:40:27Z"},{"id":"3p-5h","name":"Five Hour Limit Remaining","description":"You have hit your weekly limit, the 5-hour limit does not currently apply. Your weekly limit will fully refresh in 2 days, 5 hours.","window":"5h","disabled":true,"remaining_fraction":0.41568121314048767}]}]}}}|}
;;

(* One bucket inside the envelope [agy] prints, for the refusals. *)
let antigravity_answer ?(status = "SUCCESS") ?(num_turns = 0) buckets =
  Printf.sprintf
    {|{"status":%S,"num_turns":%d,"command":{"name":"usage","data":{"groups":[{"name":"g","buckets":[%s]}]}}}|}
    status
    num_turns
    (String.concat "," buckets)
;;

let test_antigravity_usage () =
  check (list string) "every bucket that applies; used is 1 - remaining_fraction"
    [ "limit=gemini-weekly seven_day fraction 0.898768 resets=1790735123"
    ; "limit=gemini-5h five_hour fraction 0.248859 resets=1790405869"
    ; "limit=3p-weekly seven_day fraction 1 resets=1790581227"
    ]
    (decoded_windows Usage.decode_antigravity_usage ~source:"antigravity.usage"
       antigravity_usage_response);
  check (list string) "a bucket without a reset time keeps none"
    [ "limit=b five_hour fraction 0.5 resets=-" ]
    (decoded_windows Usage.decode_antigravity_usage ~source:"antigravity.usage"
       (antigravity_answer [ {|{"id":"b","window":"5h","remaining_fraction":0.5}|} ]));
  check string "an answer that ran a turn is refused"
    "antigravity-usage.num_turns must be 0 (a usage answer runs no turn)"
    (refused Usage.decode_antigravity_usage (antigravity_answer ~num_turns:1 []));
  check string "a failed answer is refused"
    "antigravity-usage.status must be SUCCESS"
    (refused Usage.decode_antigravity_usage (antigravity_answer ~status:"ERROR" []));
  check string "another command's answer is refused"
    "antigravity-usage.command.name must be usage"
    (refused Usage.decode_antigravity_usage
       {|{"status":"SUCCESS","num_turns":0,"command":{"name":"quota","data":{"groups":[]}}}|});
  check string "a window other than 5h or weekly is refused, not guessed"
    "antigravity-usage.command.data.groups[0].buckets[0].window must be \"5h\" or \"weekly\""
    (refused Usage.decode_antigravity_usage
       (antigravity_answer [ {|{"id":"b","window":"daily","remaining_fraction":0.5}|} ]));
  check string "a remaining fraction above 1 is refused"
    "antigravity-usage.command.data.groups[0].buckets[0].remaining_fraction must be within 0..1"
    (refused Usage.decode_antigravity_usage
       (antigravity_answer [ {|{"id":"b","window":"5h","remaining_fraction":1.5}|} ]));
  check string "a reset time that is not RFC 3339 is refused"
    "antigravity-usage.command.data.groups[0].buckets[0].reset_time must be an RFC 3339 time"
    (refused Usage.decode_antigravity_usage
       (antigravity_answer
          [ {|{"id":"b","window":"5h","remaining_fraction":0.5,"reset_time":"tomorrow"}|} ]));
  check string "one bucket id stated twice is refused"
    "antigravity-usage.command.data states the window (limit b, 5h) twice"
    (refused Usage.decode_antigravity_usage
       (antigravity_answer
          [ {|{"id":"b","window":"5h","remaining_fraction":0.5}|}
          ; {|{"id":"b","window":"5h","remaining_fraction":0.4}|}
          ]))
;;

let test_antigravity_version () =
  let version = Alcotest.(option (triple int int int)) in
  check version "the CLI's own line" (Some (1, 2, 11))
    (Runtime_antigravity_usage.parse_version "1.2.11\n");
  check version "a prefix is not a version" None
    (Runtime_antigravity_usage.parse_version "v1.2.11");
  check version "two parts are not a version" None
    (Runtime_antigravity_usage.parse_version "1.2");
  check version "a suffix is not a version" None
    (Runtime_antigravity_usage.parse_version "1.2.11-beta");
  check (triple int int int) "the first print-mode /usage without a turn" (1, 1, 11)
    Runtime_antigravity_usage.minimum_version
;;

(* --- Reading scopes: the fetch is injected, so no request leaves. --- *)

module Read = Runtime_provider_usage_read

let http_readable ~provider_id ~url ~key ~refresh_s =
  { Read.scope = Runtime_quota_window.scope_of_credential ~provider_id None
  ; how =
      Http
        { credential = Llm_provider.Provider_config.Static_credential, Llm_provider.Secret.of_string key
        ; usage_read = { shape = Runtime_schema.Ollama_usage; url; refresh_s }
        }
  }
;;

let reported scope =
  match Usage.state ~scope with
  | Usage.Reported _ -> true
  | Usage.Not_reported_since_start -> false
;;

let codex_exec : Runtime_execution.codex_app_server =
  { Runtime_execution.cli_path = "/usr/bin/true"; model = None; timeout_s = 1.0 }

let antigravity_exec : Runtime_execution.antigravity_cli =
  { Runtime_execution.cli_path = "/usr/bin/true"
  ; model = "gemini-fixture"
  ; agent = None
  ; effort = None
  ; oauth_source = "/nonexistent/oauth"
  ; timeout_s = 1.0
  ; add_dirs = []
  }

let no_antigravity ~scope:_ _ = fail "an Antigravity read was asked for"

(* One scope raising, over HTTP or through an official client, is logged
   and the scopes after it are still read. *)
let test_a_raising_scope_does_not_stop_the_rest () =
  let raising = http_readable ~provider_id:"usage_read_raises" ~url:"https://raise.invalid" ~key:"k" ~refresh_s:None in
  let codex_raising =
    { Read.scope = Runtime_quota_window.scope_of_credential ~provider_id:"usage_read_codex_raises" None
    ; how = Codex codex_exec
    }
  in
  let antigravity_raising =
    { Read.scope =
        Runtime_quota_window.scope_of_credential ~provider_id:"usage_read_antigravity_raises" None
    ; how = Antigravity antigravity_exec
    }
  in
  let after = http_readable ~provider_id:"usage_read_after" ~url:"https://ok.invalid" ~key:"k" ~refresh_s:None in
  let fetch ~api_key:_ url =
    if String.equal url "https://ok.invalid"
    then Ok ollama_usage_response
    else failwith "connection closed by peer"
  in
  let codex ~scope:_ _ = failwith "codex app-server died" in
  let antigravity ~scope:_ _ = failwith "agy died" in
  Read.read_scopes ~codex ~antigravity ~fetch
    [ raising; codex_raising; antigravity_raising; after ];
  check bool "the raising scope recorded nothing" false (reported raising.scope);
  check bool "the scope after it was read" true (reported after.scope)
;;

(* An empty key is refused before any request. *)
let test_an_empty_key_sends_no_request () =
  let empty = http_readable ~provider_id:"usage_read_empty_key" ~url:"https://ok.invalid" ~key:"" ~refresh_s:None in
  let fetch ~api_key:_ _ = fail "a request was sent with an empty key" in
  Read.read_scopes ~codex:(fun ~scope:_ _ -> Ok ()) ~antigravity:no_antigravity ~fetch [ empty ];
  check bool "nothing recorded" false (reported empty.scope)
;;

(* --- Repeating a read: [run_full]'s clock moves only when every fiber
   waits, so periods of minutes cost no real time. The catalogue is a ref
   that a fetch changes, the way a config save changes the runtime
   catalogue between two repeats. --- *)

let start_period_s = 600.0
let changed_period_s = 60.0
let second_account_period_s = 900.0

let fetch_counting counts ~on_fetch ~api_key:_ url =
  let count = 1 + Option.value ~default:0 (Hashtbl.find_opt counts url) in
  Hashtbl.replace counts url count;
  on_fetch url count;
  Ok ollama_usage_response
;;

let fetched counts url = Option.value ~default:0 (Hashtbl.find_opt counts url)

(* The first read changes the declared period and the second removes the
   account. The period a lookup finds is the wait after that read, so the
   waits are the start period, the start period again (found before the
   change), then the changed period; the lookup after it finds nothing and
   the repeats end. *)
let test_repeats_follow_the_catalogue_and_end_when_it_drops_the_account () =
  Eio_mock.Backend.run_full
  @@ fun env ->
  let clock = env#clock in
  let url = "https://ok.invalid/follow" in
  let account refresh_s =
    http_readable ~provider_id:"usage_refresh_follows" ~url ~key:"k" ~refresh_s
  in
  let catalogue = ref [ account (Some start_period_s) ] in
  let counts = Hashtbl.create 1 in
  let on_fetch _url = function
    | 1 -> catalogue := [ account (Some changed_period_s) ]
    | _ -> catalogue := []
  in
  let started = Eio.Time.now clock in
  Read.refresh_readables
    ~clock
    ~fetch:(fetch_counting counts ~on_fetch)
    ~catalogue:(fun () -> !catalogue);
  check int "two repeats before the account left" 2 (fetched counts url);
  check (float 1e-6) "the waits the catalogue declared"
    (start_period_s +. start_period_s +. changed_period_s)
    (Eio.Time.now clock -. started);
  check bool "a repeat recorded its answer" true
    (reported (account None).scope)
;;

(* Two accounts repeat side by side on their own periods. An account whose
   static key is empty, and one that declares no refresh, never repeat. *)
let test_only_accounts_that_can_answer_repeat_each_on_its_period () =
  Eio_mock.Backend.run_full
  @@ fun env ->
  let clock = env#clock in
  let first = "https://ok.invalid/first" in
  let second = "https://ok.invalid/second" in
  let empty_key = "https://ok.invalid/empty-key" in
  let no_refresh = "https://ok.invalid/no-refresh" in
  let catalogue =
    ref
      [ http_readable ~provider_id:"usage_refresh_first" ~url:first ~key:"k"
          ~refresh_s:(Some start_period_s)
      ; http_readable ~provider_id:"usage_refresh_second" ~url:second ~key:"k"
          ~refresh_s:(Some second_account_period_s)
      ; http_readable ~provider_id:"usage_refresh_empty_key" ~url:empty_key ~key:""
          ~refresh_s:(Some start_period_s)
      ; http_readable ~provider_id:"usage_refresh_none" ~url:no_refresh ~key:"k"
          ~refresh_s:None
      ]
  in
  let counts = Hashtbl.create 4 in
  let total = ref 0 in
  (* Reads land at 600 (first), 900 (second) and 1200 (first); the third
     empties the catalogue, so both accounts stop at their next lookup. *)
  let on_fetch _url _count =
    incr total;
    if !total = 3 then catalogue := []
  in
  Read.refresh_readables
    ~clock
    ~fetch:(fetch_counting counts ~on_fetch)
    ~catalogue:(fun () -> !catalogue);
  check int "the first account, every 600 s" 2 (fetched counts first);
  check int "the second account, every 900 s" 1 (fetched counts second);
  check int "an empty static key is never repeated" 0 (fetched counts empty_key);
  check int "an account without refresh-s is never repeated" 0 (fetched counts no_refresh)
;;

(* A repeat whose read raises is logged, and the next repeat still reads. *)
let test_a_raising_repeat_does_not_end_the_repeats () =
  Eio_mock.Backend.run_full
  @@ fun env ->
  let clock = env#clock in
  let readable =
    http_readable ~provider_id:"usage_refresh_raises_once" ~url:"https://ok.invalid" ~key:"k"
      ~refresh_s:(Some changed_period_s)
  in
  let catalogue = ref [ readable ] in
  let fetches = ref 0 in
  let fetch ~api_key:_ _ =
    incr fetches;
    if !fetches = 1
    then failwith "connection reset by peer"
    else (
      catalogue := [];
      Ok ollama_usage_response)
  in
  Read.refresh_readables ~clock ~fetch ~catalogue:(fun () -> !catalogue);
  check int "the repeat after the raising one still read" 2 !fetches;
  check bool "the later read recorded its answer" true (reported readable.scope)
;;

let () =
  run
    "provider_usage_windows"
    [ ( "resolved"
      , [ test_case "reports reach the resolved document" `Quick
            test_reports_reach_the_resolved_document
        ; test_case "malformed window is a typed error" `Quick
            test_malformed_window_is_a_typed_error
        ; test_case "codex read falls back and refuses a bad map" `Quick
            test_codex_read_falls_back_and_refuses_a_bad_map
        ] )
    ; ( "http usage endpoints"
      , [ test_case "openrouter-key" `Quick test_openrouter_key
        ; test_case "zai-quota-limit" `Quick test_zai_quota_limit
        ; test_case "kimi-coding-usages" `Quick test_kimi_coding_usages
        ; test_case "ollama-usage" `Quick test_ollama_usage
        ] )
    ; ( "antigravity /usage"
      , [ test_case "antigravity-usage" `Quick test_antigravity_usage
        ; test_case "version" `Quick test_antigravity_version
        ] )
    ; ( "reading scopes"
      , [ test_case "a raising scope does not stop the rest" `Quick
            test_a_raising_scope_does_not_stop_the_rest
        ; test_case "an empty key sends no request" `Quick test_an_empty_key_sends_no_request
        ] )
    ; ( "repeating a read"
      , [ test_case "repeats follow the catalogue and end when it drops the account" `Quick
            test_repeats_follow_the_catalogue_and_end_when_it_drops_the_account
        ; test_case "only accounts that can answer repeat, each on its period" `Quick
            test_only_accounts_that_can_answer_repeat_each_on_its_period
        ; test_case "a raising repeat does not end the repeats" `Quick
            test_a_raising_repeat_does_not_end_the_repeats
        ] )
    ]
;;
