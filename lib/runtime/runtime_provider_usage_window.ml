(** Provider-reported usage windows.  See the [.mli] for the contract. *)

type window_kind =
  | Five_hour
  | Seven_day
  | Duration_minutes of int
  | Provider_label of string

type utilization =
  | Fraction of float
  | Percent of int

type source =
  | Claude_code_rate_limit_event
  | Codex_account_rate_limits_updated
  | Codex_account_rate_limits_read
  | Openrouter_key_read
  | Zai_quota_limit_read
  | Kimi_coding_usages_read
  | Ollama_usage_read
  | Antigravity_usage_read
  | Muse_usage_read

type window =
  { limit_id : string option
  ; kind : window_kind
  ; utilization : utilization
  ; resets_at : int option
  }

type report =
  { source : source
  ; windows : window list
  }

type decode_error =
  | Expected_object of { path : string }
  | Missing_field of { path : string }
  | Wrong_type of
      { path : string
      ; expected : string
      }
  | Unexpected_value of
      { path : string
      ; expected : string
      }
  | Not_successful of
      { path : string
      ; message : string option
      }
  | Duplicate_window of
      { path : string
      ; limit_id : string option
      ; kind : window_kind
      }

let window_kind_to_string = function
  | Five_hour -> "5h"
  | Seven_day -> "7d"
  | Duration_minutes minutes -> Printf.sprintf "%d minutes" minutes
  | Provider_label label -> Printf.sprintf "label %S" label
;;

let decode_error_to_string = function
  | Expected_object { path } -> Printf.sprintf "%s must be an object" path
  | Missing_field { path } -> Printf.sprintf "%s is missing" path
  | Wrong_type { path; expected } -> Printf.sprintf "%s must be %s" path expected
  | Unexpected_value { path; expected } -> Printf.sprintf "%s must be %s" path expected
  | Not_successful { path; message = Some message } ->
    Printf.sprintf "%s is not true: %s" path message
  | Not_successful { path; message = None } -> Printf.sprintf "%s is not true" path
  | Duplicate_window { path; limit_id = Some limit_id; kind } ->
    Printf.sprintf
      "%s states the window (limit %s, %s) twice"
      path
      limit_id
      (window_kind_to_string kind)
  | Duplicate_window { path; limit_id = None; kind } ->
    Printf.sprintf "%s states the window (%s) twice" path (window_kind_to_string kind)
;;

let source_to_string = function
  | Claude_code_rate_limit_event -> "claude_code.rate_limit_event"
  | Codex_account_rate_limits_updated -> "codex.account_rate_limits_updated"
  | Codex_account_rate_limits_read -> "codex.account_rate_limits_read"
  | Openrouter_key_read -> "openrouter.key"
  | Zai_quota_limit_read -> "zai.quota_limit"
  | Kimi_coding_usages_read -> "kimi_coding.usages"
  | Ollama_usage_read -> "ollama.usage"
  | Antigravity_usage_read -> "antigravity.usage"
  | Muse_usage_read -> "muse.usage_read"
;;

let ( let* ) = Result.bind

let fields_at ~path = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Expected_object { path })
;;

let member_path path name = path ^ "." ^ name

let required ~path name fields =
  match List.assoc_opt name fields with
  | Some json -> Ok json
  | None -> Error (Missing_field { path = member_path path name })
;;

(* Absent and null both mean the provider stated no value. *)
let optional_int ~path name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some _ -> Error (Wrong_type { path = member_path path name; expected = "an integer or null" })
;;

let optional_string ~path name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error (Wrong_type { path = member_path path name; expected = "a string or null" })
;;

let map_result f items =
  List.fold_right
    (fun item acc ->
       let* rest = acc in
       let* value = f item in
       Ok (value :: rest))
    items
    (Ok [])
;;

(* Claude Code names the windows by key.  Only the two keys observed on the
   wire have names here; anything else keeps the provider's own label. *)
let claude_window_kind = function
  | "five_hour" -> Five_hour
  | "seven_day" -> Seven_day
  | label -> Provider_label label
;;

let claude_window ~path (key, json) =
  let path = member_path path key in
  let* fields = fields_at ~path json in
  let* utilization =
    let* value = required ~path "utilization" fields in
    match value with
    | `Float fraction -> Ok (Fraction fraction)
    | `Int whole -> Ok (Fraction (Float.of_int whole))
    | _ ->
      Error (Wrong_type { path = member_path path "utilization"; expected = "a number" })
  in
  let* resets_at = optional_int ~path "resetsAt" fields in
  Ok { limit_id = None; kind = claude_window_kind key; utilization; resets_at }
;;

let decode_claude_rate_limit_event json =
  let path = "rate_limit_event" in
  let* fields = fields_at ~path json in
  let* info = required ~path "rate_limit_info" fields in
  let path = member_path path "rate_limit_info" in
  let* info_fields = fields_at ~path info in
  let* windows =
    match List.assoc_opt "unifiedWindows" info_fields with
    | None | Some `Null -> Ok []
    | Some unified ->
      let path = member_path path "unifiedWindows" in
      let* entries = fields_at ~path unified in
      map_result (claude_window ~path) entries
  in
  Ok { source = Claude_code_rate_limit_event; windows }
;;

(* Window lengths, in minutes, that have a name.  Codex states the length of
   each window; these are exact lengths, not ranges. *)
let five_hour_minutes = 5 * 60
let seven_day_minutes = 7 * 24 * 60

let kind_of_minutes minutes =
  if Int.equal minutes five_hour_minutes
  then Five_hour
  else if Int.equal minutes seven_day_minutes
  then Seven_day
  else Duration_minutes minutes
;;

let codex_window_kind ~slot = function
  | Some minutes -> kind_of_minutes minutes
  | None -> Provider_label slot
;;

let codex_window ~path ~limit_id ~slot fields =
  match List.assoc_opt slot fields with
  | None | Some `Null -> Ok None
  | Some json ->
    let path = member_path path slot in
    let* window_fields = fields_at ~path json in
    let* used_percent =
      match List.assoc_opt "usedPercent" window_fields with
      | Some (`Int percent) -> Ok percent
      | Some _ ->
        Error (Wrong_type { path = member_path path "usedPercent"; expected = "an integer" })
      | None -> Error (Missing_field { path = member_path path "usedPercent" })
    in
    let* duration = optional_int ~path "windowDurationMins" window_fields in
    let* resets_at = optional_int ~path "resetsAt" window_fields in
    Ok
      (Some
         { limit_id
         ; kind = codex_window_kind ~slot duration
         ; utilization = Percent used_percent
         ; resets_at
         })
;;

(* One [RateLimitSnapshot]: the [rateLimits] of an update or a read, or one
   bucket of a read's [rateLimitsByLimitId]. *)
let codex_snapshot ?keyed_by ~path snapshot =
  let* snapshot_fields = fields_at ~path snapshot in
  let* stated = optional_string ~path "limitId" snapshot_fields in
  (* A bucket of [rateLimitsByLimitId] is keyed by its limit id, so the key
     names it when the snapshot itself does not. *)
  let limit_id = match stated with Some _ -> stated | None -> keyed_by in
  let* primary = codex_window ~path ~limit_id ~slot:"primary" snapshot_fields in
  let* secondary = codex_window ~path ~limit_id ~slot:"secondary" snapshot_fields in
  Ok (List.filter_map Fun.id [ primary; secondary ])
;;

let decode_codex_rate_limits_updated params =
  let path = "account/rateLimits/updated" in
  let* fields = fields_at ~path params in
  let* snapshot = required ~path "rateLimits" fields in
  let* windows = codex_snapshot ~path:(member_path path "rateLimits") snapshot in
  Ok { source = Codex_account_rate_limits_updated; windows }
;;

(* The read answers with both views of the same account. The per-limit map
   carries every metered limit; the single [rateLimits] mirrors one of them
   for older clients, so it is read only when the map is absent or null. *)
let decode_codex_rate_limits_read response =
  let path = "account/rateLimits/read" in
  let* fields = fields_at ~path response in
  let* windows =
    match List.assoc_opt "rateLimitsByLimitId" fields with
    | Some (`Assoc buckets) ->
      let path = member_path path "rateLimitsByLimitId" in
      let* per_bucket =
        map_result
          (fun (key, snapshot) ->
             codex_snapshot ~keyed_by:key ~path:(member_path path key) snapshot)
          buckets
      in
      Ok (List.concat per_bucket)
    | None | Some `Null ->
      let* snapshot = required ~path "rateLimits" fields in
      codex_snapshot ~path:(member_path path "rateLimits") snapshot
    | Some _ ->
      Error
        (Wrong_type
           { path = member_path path "rateLimitsByLimitId"; expected = "an object or null" })
  in
  Ok { source = Codex_account_rate_limits_read; windows }
;;

(* --- HTTP usage endpoints ---------------------------------------------- *)

let index_path path index = Printf.sprintf "%s[%d]" path index

let list_at ~path = function
  | `List items -> Ok items
  | _ -> Error (Wrong_type { path; expected = "an array" })
;;

let map_indexed ~path f items =
  map_result
    (fun (index, item) -> f ~path:(index_path path index) item)
    (List.mapi (fun index item -> index, item) items)
;;

(* A JSON number either way: these endpoints write whole values as integers
   ([0], [1], [100]) and others as floats. *)
let number_at ~path = function
  | `Int value -> Ok (Float.of_int value)
  | `Float value -> Ok value
  | _ -> Error (Wrong_type { path; expected = "a number" })
;;

let int_at ~path = function
  | `Int value -> Ok value
  | _ -> Error (Wrong_type { path; expected = "an integer" })
;;

let string_at ~path = function
  | `String value -> Ok value
  | _ -> Error (Wrong_type { path; expected = "a string" })
;;

let bool_at ~path = function
  | `Bool value -> Ok value
  | _ -> Error (Wrong_type { path; expected = "a boolean" })
;;

let required_as read ~path name fields =
  let* json = required ~path name fields in
  read ~path:(member_path path name) json
;;

(* Absent and null both mean the provider stated no such value. *)
let optional_as read ~path name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some json -> Result.map Option.some (read ~path:(member_path path name) json)
;;

(* Absent and null both mean the provider stated no such object. *)
let optional_object ~path name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some json ->
    let path = member_path path name in
    let* object_fields = fields_at ~path json in
    Ok (Some (path, object_fields))
;;

let greater_than_zero = "greater than 0"

let positive_int ~path value =
  if value > 0
  then Ok value
  else Error (Unexpected_value { path; expected = greater_than_zero })
;;

let positive_number ~path value =
  if Float.compare value 0.0 > 0
  then Ok value
  else Error (Unexpected_value { path; expected = greater_than_zero })
;;

let fraction_of_counts ~used ~limit = Fraction (Float.of_int used /. Float.of_int limit)

let within ~path ~expected ~low ~high value =
  if Float.compare value low >= 0 && Float.compare value high <= 0
  then Ok value
  else Error (Unexpected_value { path; expected })
;;

(* A count of [limit]: [used] or [remaining] outside 0..limit would read as a
   fraction below 0 or above 1. *)
let count_within_limit ~path ~limit value =
  within
    ~path
    ~expected:(Printf.sprintf "within 0..%d" limit)
    ~low:0.0
    ~high:(Float.of_int limit)
    (Float.of_int value)
  |> Result.map (fun (_ : float) -> value)
;;

let equal_window_kind left right =
  match left, right with
  | Five_hour, Five_hour | Seven_day, Seven_day -> true
  | Duration_minutes a, Duration_minutes b -> Int.equal a b
  | Provider_label a, Provider_label b -> String.equal a b
  | (Five_hour | Seven_day | Duration_minutes _ | Provider_label _), _ -> false
;;

(* {!record} keeps one row per (limit_id, kind), so a report that states the
   same key twice would keep whichever came last.  Such a report is refused
   instead. *)
let distinct_windows ~path (report : report) =
  let same (a : window) (b : window) =
    Option.equal String.equal a.limit_id b.limit_id && equal_window_kind a.kind b.kind
  in
  let rec first_duplicate = function
    | [] -> None
    | (window : window) :: rest ->
      if List.exists (same window) rest then Some window else first_duplicate rest
  in
  match first_duplicate report.windows with
  | None -> Ok report
  | Some window ->
    Error (Duplicate_window { path; limit_id = window.limit_id; kind = window.kind })
;;

(* OpenRouter, GET /api/v1/key (openrouter.ai/docs/api-reference/limits).
   [limit] null means the key has no credit cap, so there is no credit
   window.  The response states no reset time.  [limit_reset] is not read:
   the label is part of the row key in {!record}, so a label carrying the
   reset period would leave the old row behind when the period changes. *)
let openrouter_credit_window ~path fields =
  match List.assoc_opt "limit" fields with
  | None | Some `Null -> Ok None
  | Some limit_json ->
    let limit_path = member_path path "limit" in
    let* limit = number_at ~path:limit_path limit_json in
    let* limit = positive_number ~path:limit_path limit in
    let* remaining = required_as number_at ~path "limit_remaining" fields in
    let* remaining =
      within
        ~path:(member_path path "limit_remaining")
        ~expected:(Printf.sprintf "within 0..%g" limit)
        ~low:0.0
        ~high:limit
        remaining
    in
    Ok
      (Some
         { limit_id = None
         ; kind = Provider_label "credit limit"
         ; utilization = Fraction ((limit -. remaining) /. limit)
         ; resets_at = None
         })
;;

let openrouter_free_requests_window ~path fields =
  let* free = optional_object ~path "free_model_daily_requests" fields in
  match free with
  | None -> Ok None
  | Some (path, free_fields) ->
    let* used = required_as int_at ~path "used" free_fields in
    let* limit = required_as int_at ~path "limit" free_fields in
    let* limit = positive_int ~path:(member_path path "limit") limit in
    let* used = count_within_limit ~path:(member_path path "used") ~limit used in
    Ok
      (Some
         { limit_id = None
         ; kind = Provider_label "free model requests, daily"
         ; utilization = fraction_of_counts ~used ~limit
         ; resets_at = None
         })
;;

let decode_openrouter_key json =
  let path = "openrouter-key" in
  let* fields = fields_at ~path json in
  let* data = required ~path "data" fields in
  let path = member_path path "data" in
  let* data_fields = fields_at ~path data in
  let* credit = openrouter_credit_window ~path data_fields in
  let* free = openrouter_free_requests_window ~path data_fields in
  distinct_windows
    ~path
    { source = Openrouter_key_read; windows = List.filter_map Fun.id [ credit; free ] }
;;

(* Z.AI [unit] codes.  Only [3] is known to be hours: the TOKENS_LIMIT row
   with [unit 3, number 5] is the plan's 5-hour window.  Any other code keeps
   the provider's own words instead of a guessed length. *)
let zai_unit_hours = 3
let minutes_per_hour = 60
let ms_per_second = 1000
let percent_whole = 100

let zai_window_kind ~limit_type ~unit ~number =
  if Int.equal unit zai_unit_hours
  then kind_of_minutes (number * minutes_per_hour)
  else Provider_label (Printf.sprintf "%s, %d x unit %d" limit_type number unit)
;;

let zai_limit ~path json =
  let* fields = fields_at ~path json in
  let* limit_type = required_as string_at ~path "type" fields in
  let* unit = required_as int_at ~path "unit" fields in
  let* number = required_as int_at ~path "number" fields in
  let* number = positive_int ~path:(member_path path "number") number in
  let* percentage = required_as int_at ~path "percentage" fields in
  let* percentage =
    count_within_limit ~path:(member_path path "percentage") ~limit:percent_whole percentage
  in
  let* next_reset_ms = optional_int ~path "nextResetTime" fields in
  Ok
    { limit_id = Some limit_type
    ; kind = zai_window_kind ~limit_type ~unit ~number
    ; utilization = Percent percentage
    ; resets_at = Option.map (fun ms -> ms / ms_per_second) next_reset_ms
    }
;;

(* Z.AI, GET /api/monitor/usage/quota/limit (undocumented; the vendor's own
   coding plugin calls it). *)
let decode_zai_quota_limit json =
  let path = "zai-quota-limit" in
  let* fields = fields_at ~path json in
  let* success = required ~path "success" fields in
  let success_path = member_path path "success" in
  let* () =
    match success with
    | `Bool true -> Ok ()
    | `Bool false ->
      let* message = optional_string ~path "msg" fields in
      Error (Not_successful { path = success_path; message })
    | _ -> Error (Wrong_type { path = success_path; expected = "a boolean" })
  in
  let* data = required ~path "data" fields in
  let path = member_path path "data" in
  let* data_fields = fields_at ~path data in
  let* limits = required_as list_at ~path "limits" data_fields in
  let* windows = map_indexed ~path:(member_path path "limits") zai_limit limits in
  distinct_windows ~path { source = Zai_quota_limit_read; windows }
;;

(* Kimi writes counts as decimal strings ("100").  Only plain digits are a
   count: [int_of_string] alone would also take "0x10", "1_0" and "-5". *)
let is_decimal_digit c = Char.compare c '0' >= 0 && Char.compare c '9' <= 0

let decimal_string_at ~path json =
  let* raw = string_at ~path json in
  let parsed =
    if String.length raw > 0 && String.for_all is_decimal_digit raw
    then int_of_string_opt raw
    else None
  in
  match parsed with
  | Some value -> Ok value
  | None -> Error (Wrong_type { path; expected = "a decimal integer string" })
;;

let optional_rfc3339 ~path name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some json ->
    let path = member_path path name in
    let* raw = string_at ~path json in
    (match Time_codec.parse_rfc3339_whole_seconds raw with
     | Ok seconds -> Ok (Some (Float.to_int seconds))
     | Error Time_codec.Invalid_rfc3339 ->
       Error (Wrong_type { path; expected = "an RFC 3339 timestamp" }))
;;

(* What a Kimi count object has used of its [limit]. The counts are
   protobuf JSON (int64 as decimal strings, enums by name), which leaves out
   a field whose value is zero: on 2026-09-25 the answer, like the body in
   MoonshotAI/kimi-code#3951, carried [limits[].detail] as limit/remaining
   (nothing used) and the top-level [usage] as limit/used (nothing left).
   So either count gives the other; both present must add up to [limit],
   and neither present is refused. *)
let kimi_used ~path ~limit fields =
  let* used = optional_as decimal_string_at ~path "used" fields in
  let* remaining = optional_as decimal_string_at ~path "remaining" fields in
  let used_path = member_path path "used" in
  let remaining_path = member_path path "remaining" in
  match used, remaining with
  | Some used, None -> count_within_limit ~path:used_path ~limit used
  | None, Some remaining ->
    let* remaining = count_within_limit ~path:remaining_path ~limit remaining in
    Ok (limit - remaining)
  | Some used, Some remaining ->
    let* used = count_within_limit ~path:used_path ~limit used in
    if used + remaining = limit
    then Ok used
    else
      Error
        (Unexpected_value
           { path = remaining_path; expected = Printf.sprintf "%d (limit - used)" (limit - used) })
  | None, None -> Error (Missing_field { path = member_path path "used or remaining" })
;;

(* One Kimi [detail] object, or the top-level [usage]: what it used of
   [limit]. *)
let kimi_count_window ~path ~kind fields =
  let* limit = required_as decimal_string_at ~path "limit" fields in
  let* limit = positive_int ~path:(member_path path "limit") limit in
  let* used = kimi_used ~path ~limit fields in
  let* resets_at = optional_rfc3339 ~path "resetTime" fields in
  Ok { limit_id = None; kind; utilization = fraction_of_counts ~used ~limit; resets_at }
;;

let kimi_minute_unit = "TIME_UNIT_MINUTE"

let kimi_window_minutes ~path fields =
  let* window = required ~path "window" fields in
  let path = member_path path "window" in
  let* window_fields = fields_at ~path window in
  let* time_unit = required_as string_at ~path "timeUnit" window_fields in
  if String.equal time_unit kimi_minute_unit
  then (
    let* duration = required_as int_at ~path "duration" window_fields in
    positive_int ~path:(member_path path "duration") duration)
  else
    Error (Unexpected_value { path = member_path path "timeUnit"; expected = kimi_minute_unit })
;;

let kimi_limit ~path json =
  let* fields = fields_at ~path json in
  let* minutes = kimi_window_minutes ~path fields in
  let* detail = required ~path "detail" fields in
  let path = member_path path "detail" in
  let* detail_fields = fields_at ~path detail in
  kimi_count_window ~path ~kind:(kind_of_minutes minutes) detail_fields
;;

(* Kimi, GET /coding/v1/usages (undocumented; the vendor's own CLI calls it).
   [usages.*.used_ratio] is not read: on the same response it contradicts
   the top-level [usage] (used 100 of 100 with [limit_7d] ratio 0, while the
   account was refused for its weekly limit), an open upstream issue,
   MoonshotAI/kimi-code#3951.  The top-level [usage] states no window
   length. Its [resetTime] is preserved without guessing the period. *)
let decode_kimi_coding_usages json =
  let path = "kimi-coding-usages" in
  let* fields = fields_at ~path json in
  let* limits = required_as list_at ~path "limits" fields in
  let* windows = map_indexed ~path:(member_path path "limits") kimi_limit limits in
  let* plan = optional_object ~path "usage" fields in
  let* plan_windows =
    match plan with
    | None -> Ok []
    | Some (path, plan_fields) ->
      let* window =
        kimi_count_window ~path ~kind:(Provider_label "usage (provider resetTime)") plan_fields
      in
      Ok [ window ]
  in
  distinct_windows ~path { source = Kimi_coding_usages_read; windows = windows @ plan_windows }
;;

(* Ollama, GET https://ollama.com/api/usage (undocumented; the vendor's own
   client calls it).  The observed session/weekly response reports [usage]
   as a 0-1 fraction: masc live log 2026-09-24 shows 21 refusals "you have
   reached your weekly usage limit" while weekly.usage was 1.  Other account
   plans may return a different shape; refuse an unknown value with its path.
   The observed response states no reset time and no session length. *)
let ollama_window ~path ~kind name fields =
  let* entry = optional_object ~path name fields in
  match entry with
  | None -> Ok None
  | Some (path, entry_fields) ->
    let* usage = required_as number_at ~path "usage" entry_fields in
    let* usage =
      within ~path:(member_path path "usage") ~expected:"within 0..1" ~low:0.0 ~high:1.0 usage
    in
    Ok (Some { limit_id = None; kind; utilization = Fraction usage; resets_at = None })
;;

let decode_ollama_usage json =
  let path = "ollama-usage" in
  let* fields = fields_at ~path json in
  let* limits = required ~path "limits" fields in
  let path = member_path path "limits" in
  let* limit_fields = fields_at ~path limits in
  let* session = ollama_window ~path ~kind:(Provider_label "session") "session" limit_fields in
  let* weekly = ollama_window ~path ~kind:Seven_day "weekly" limit_fields in
  distinct_windows
    ~path
    { source = Ollama_usage_read; windows = List.filter_map Fun.id [ session; weekly ] }
;;

(* Antigravity, [agy -p "/usage" --output-format json]. agy 1.1.11 answers
   the read-only slash commands in print mode "without starting an agent
   turn, spending quota, or leaving a conversation behind" (its bundled
   changelog); the JSON shape is not documented and is decoded as agy 1.2.11
   answered it on 2026-09-26. An older agy sends "/usage" to the model as a
   prompt, and that answer is a turn: [num_turns] must be 0. Each
   [command.data.groups[].buckets[]] is one window keyed by its [id]. A bucket
   marked [disabled] does not currently apply ("the 5-hour limit does not
   currently apply" while the weekly one is spent), so it is no window. *)
let antigravity_window_kind ~path json =
  let* window = string_at ~path json in
  match window with
  | "5h" -> Ok Five_hour
  | "weekly" -> Ok Seven_day
  | _ -> Error (Unexpected_value { path; expected = "\"5h\" or \"weekly\"" })
;;

let antigravity_reset_time ~path json =
  let* value = string_at ~path json in
  match Time_codec.parse_rfc3339_whole_seconds value with
  | Ok seconds -> Ok (Float.to_int seconds)
  | Error (_ : Time_codec.parse_error) ->
    Error (Unexpected_value { path; expected = "an RFC 3339 time" })
;;

let antigravity_bucket ~path json =
  let* fields = fields_at ~path json in
  let* disabled = optional_as bool_at ~path "disabled" fields in
  match disabled with
  | Some true -> Ok None
  | Some false | None ->
    let* limit_id = required_as string_at ~path "id" fields in
    let* kind = required_as antigravity_window_kind ~path "window" fields in
    let* remaining = required_as number_at ~path "remaining_fraction" fields in
    let* remaining =
      within
        ~path:(member_path path "remaining_fraction")
        ~expected:"within 0..1"
        ~low:0.0
        ~high:1.0
        remaining
    in
    let* resets_at = optional_as antigravity_reset_time ~path "reset_time" fields in
    Ok
      (Some
         { limit_id = Some limit_id
         ; kind
         ; utilization = Fraction (1.0 -. remaining)
         ; resets_at
         })
;;

let antigravity_group ~path json =
  let* fields = fields_at ~path json in
  let* buckets = required_as list_at ~path "buckets" fields in
  let* windows = map_indexed ~path:(member_path path "buckets") antigravity_bucket buckets in
  Ok (List.filter_map Fun.id windows)
;;

let required_word ~path name expected fields =
  let* value = required_as string_at ~path name fields in
  if String.equal value expected
  then Ok ()
  else Error (Unexpected_value { path = member_path path name; expected })
;;

let decode_antigravity_usage json =
  let path = "antigravity-usage" in
  let* fields = fields_at ~path json in
  let* () = required_word ~path "status" "SUCCESS" fields in
  let* num_turns = required_as int_at ~path "num_turns" fields in
  let* () =
    if Int.equal num_turns 0
    then Ok ()
    else
      Error
        (Unexpected_value
           { path = member_path path "num_turns"
           ; expected = "0 (a usage answer runs no turn)"
           })
  in
  let* command = required ~path "command" fields in
  let path = member_path path "command" in
  let* command_fields = fields_at ~path command in
  let* () = required_word ~path "name" "usage" command_fields in
  let* data = required ~path "data" command_fields in
  let path = member_path path "data" in
  let* data_fields = fields_at ~path data in
  let* groups = required_as list_at ~path "groups" data_fields in
  let* windows = map_indexed ~path:(member_path path "groups") antigravity_group groups in
  distinct_windows ~path { source = Antigravity_usage_read; windows = List.concat windows }
;;

let muse_window ~path name fields =
  let* entry = optional_object ~path name fields in
  match entry with
  | None -> Ok None
  | Some (path, entry_fields) ->
    let* used = required_as int_at ~path "usedPercent" entry_fields in
    let* resets_ms = required_as int_at ~path "resetsAtMs" entry_fields in
    let* minutes =
      match name with
      | "weekly" -> Ok None
      | _ ->
        required_as int_at ~path "windowDurationMins" entry_fields
        |> Result.map Option.some
    in
    let kind =
      match minutes with
      | None -> Seven_day
      | Some 300 -> Five_hour
      | Some minutes -> Duration_minutes minutes
    in
    Ok
      (Some
         { limit_id = None
         ; kind
         ; utilization = Percent used
         ; resets_at = Some (resets_ms / 1000)
         })
;;

let decode_muse_usage_read json =
  let path = "muse-usage-read" in
  let* fields = fields_at ~path json in
  let* entry = optional_object ~path "usage" fields in
  match entry with
  | None -> Ok { source = Muse_usage_read; windows = [] }
  | Some (path, usage_fields) ->
    let* window = muse_window ~path "window" usage_fields in
    let* weekly = muse_window ~path "weekly" usage_fields in
    distinct_windows
      ~path
      { source = Muse_usage_read; windows = List.filter_map Fun.id [ window; weekly ] }
;;

type recorded =
  { window : window
  ; source : source
  ; observed_at : float
  }

type scope_state =
  | Not_reported_since_start
  | Reported of recorded * recorded list

let recording_since = Time_compat.now ()

(* scope -> (limit_id, kind) -> latest recorded.  Guarded by a
   [Stdlib.Mutex] like {!Runtime_quota_window}: nothing inside the lock
   suspends. *)
let table : (Runtime_quota_window.scope, (string option * window_kind, recorded) Hashtbl.t) Hashtbl.t =
  Hashtbl.create 4
;;

let mu = Stdlib.Mutex.create ()

let record ~scope ~observed_at (report : report) =
  match report.windows with
  | [] -> ()
  | windows ->
    Stdlib.Mutex.protect mu (fun () ->
      let by_window =
        match Hashtbl.find_opt table scope with
        | Some by_window -> by_window
        | None ->
          let by_window = Hashtbl.create 4 in
          Hashtbl.replace table scope by_window;
          by_window
      in
      List.iter
        (fun (window : window) ->
           let key = window.limit_id, window.kind in
           match Hashtbl.find_opt by_window key with
           | Some held when Float.compare held.observed_at observed_at > 0 -> ()
           | Some _ | None ->
             Hashtbl.replace by_window key { window; source = report.source; observed_at })
        windows)
;;

let kind_rank = function
  | Five_hour -> 0
  | Seven_day -> 1
  | Duration_minutes _ -> 2
  | Provider_label _ -> 3
;;

let compare_kind left right =
  match left, right with
  | Duration_minutes a, Duration_minutes b -> Int.compare a b
  | Provider_label a, Provider_label b -> String.compare a b
  | (Five_hour | Seven_day | Duration_minutes _ | Provider_label _), _ ->
    Int.compare (kind_rank left) (kind_rank right)
;;

let compare_recorded (left : recorded) (right : recorded) =
  match Option.compare String.compare left.window.limit_id right.window.limit_id with
  | 0 -> compare_kind left.window.kind right.window.kind
  | order -> order
;;

let state ~scope =
  let held =
    Stdlib.Mutex.protect mu (fun () ->
      match Hashtbl.find_opt table scope with
      | None -> []
      | Some by_window -> Hashtbl.fold (fun _ recorded acc -> recorded :: acc) by_window [])
  in
  match List.sort compare_recorded held with
  | [] -> Not_reported_since_start
  | first :: rest -> Reported (first, rest)
;;

let recorded_scopes () =
  Stdlib.Mutex.protect mu (fun () -> Hashtbl.fold (fun scope _ acc -> scope :: acc) table [])
;;
