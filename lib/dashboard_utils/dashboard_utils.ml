let iso_of_unix unix_ts =
  let tm = Unix.gmtime unix_ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let parse_iso_opt = function
  | Some raw when String.trim raw <> "" -> (
      try Some (Types.parse_iso8601 raw) with Failure _ -> None)
  | _ -> None

(* Delegate to Base — qualified access, no `open Base` *)
let first_some = Base.Option.first_some

let string_contains ~needle haystack =
  Base.String.is_substring haystack ~substring:needle

let string_contains_ci ~needle haystack =
  Base.String.is_substring
    (Base.String.lowercase haystack)
    ~substring:(Base.String.lowercase needle)

let trim_to_option text =
  let trimmed = String.trim text in
  if trimmed = "" then None else Some trimmed

let dedup_strings (xs : string list) : string list =
  let rec go seen acc = function
    | [] -> List.rev acc
    | x :: rest ->
      if Base.Set.mem seen x then go seen acc rest
      else go (Base.Set.add seen x) (x :: acc) rest
  in
  go (Base.Set.empty (module Base.String)) [] xs

let string_list_of_json json =
  match json with
  | `List items ->
      items
      |> List.filter_map (function
             | `String value -> trim_to_option value
             | _ -> None)
  | _ -> []

let json_string_option value =
  match value with
  | Some text when String.trim text <> "" -> `String (String.trim text)
  | _ -> `Null

let option_to_json f = function
  | Some value -> f value
  | None -> `Null

let member_assoc key json =
  match json with
  | `Assoc fields -> (match List.assoc_opt key fields with Some v -> v | None -> `Null)
  | _ -> `Null

let int_field ?(default = 0) key json =
  match member_assoc key json with
  | `Int v -> v
  | `Intlit raw -> (Option.value ~default:default (int_of_string_opt raw))
  | `Float v -> int_of_float v
  | _ -> default

let string_field ?(default = "") key json =
  match member_assoc key json with
  | `String v -> v
  | _ -> default

let list_field key json =
  match member_assoc key json with
  | `List items -> items
  | _ -> []

let severity_rank s =
  match String.lowercase_ascii s with
  | "bad" | "risk" | "critical" -> 2
  | "warn" | "watch" | "interrupted" | "degraded" -> 1
  | _ -> 0

let status_rank = function
  | "busy" -> 4
  | "active" -> 3
  | "listening" -> 2
  | "idle" -> 1
  | _ -> 0

let rec take n items =
  if n <= 0 then [] else match items with [] -> [] | x :: xs -> x :: take (n - 1) xs

let compact_text ?(max_len = 160) raw =
  let normalized =
    String.trim raw
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun v -> v <> "")
    |> String.concat " "
    |> String.trim
  in
  if normalized = "" then ""
  else String_util.utf8_safe ~max_bytes:((max_len - 1) + 3) ~suffix:"\xe2\x80\xa6" normalized |> String_util.to_string

let string_list_json values =
  `List (List.map (fun v -> `String v) values)

let normalized_text_key text =
  compact_text ~max_len:512 text |> String.trim |> String.lowercase_ascii

(** Health severity level — ordered from worst to best.
    Parsed from dashboard/operator JSON at the call site via
    [health_level_of_string], then used in typed predicates below. *)
type health_level =
  | HL_critical
  | HL_bad
  | HL_risk
  | HL_warn
  | HL_degraded
  | HL_ok
  | HL_unknown  (** Unparseable or missing health string *)

let health_level_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "critical" -> HL_critical
  | "bad" -> HL_bad
  | "risk" -> HL_risk
  | "warn" | "watch" -> HL_warn
  | "degraded" | "interrupted" -> HL_degraded
  | "ok" | "good" | "healthy" -> HL_ok
  | _ -> HL_unknown

let string_of_health_level = function
  | HL_critical -> "critical"
  | HL_bad -> "bad"
  | HL_risk -> "risk"
  | HL_warn -> "warn"
  | HL_degraded -> "degraded"
  | HL_ok -> "ok"
  | HL_unknown -> "unknown"

let severity_rank_of_health_level = function
  | HL_critical | HL_bad | HL_risk -> 2
  | HL_warn | HL_degraded -> 1
  | HL_ok | HL_unknown -> 0

(** Session lifecycle — parsed from session JSON at call sites.
    The variant makes the different terminal sets visible:
    - [is_session_terminal]: Completed | Cancelled | Failed | Stopped
    - [is_session_blocked]: Failed | Cancelled | Interrupted
    - dashboard_mission terminal: Completed | Interrupted | Cancelled | Expired *)
type session_lifecycle =
  | SL_active
  | SL_running
  | SL_paused
  | SL_completed
  | SL_cancelled
  | SL_failed
  | SL_stopped
  | SL_interrupted
  | SL_expired
  | SL_unknown

let session_lifecycle_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "active" -> SL_active
  | "running" -> SL_running
  | "paused" -> SL_paused
  | "completed" -> SL_completed
  | "cancelled" -> SL_cancelled
  | "failed" -> SL_failed
  | "stopped" -> SL_stopped
  | "interrupted" -> SL_interrupted
  | "expired" -> SL_expired
  | _ -> SL_unknown

let string_of_session_lifecycle = function
  | SL_active -> "active"
  | SL_running -> "running"
  | SL_paused -> "paused"
  | SL_completed -> "completed"
  | SL_cancelled -> "cancelled"
  | SL_failed -> "failed"
  | SL_stopped -> "stopped"
  | SL_interrupted -> "interrupted"
  | SL_expired -> "expired"
  | SL_unknown -> "unknown"

(** Status/health classification predicates — single source of truth.
    Used across dashboard, briefing, and operator modules. *)

let is_keeper_offline status =
  List.mem status [ "offline"; "inactive"; "error" ]

let is_health_critical = function
  | HL_bad | HL_critical -> true
  | HL_risk | HL_warn | HL_degraded | HL_ok | HL_unknown -> false

let is_health_warning = function
  | HL_warn | HL_degraded -> true
  | HL_critical | HL_bad | HL_risk | HL_ok | HL_unknown -> false

let is_health_at_risk = function
  | HL_bad | HL_risk | HL_critical -> true
  | HL_warn | HL_degraded | HL_ok | HL_unknown -> false

let is_session_terminal = function
  | SL_completed | SL_cancelled | SL_failed | SL_stopped -> true
  | SL_active | SL_running | SL_paused | SL_interrupted | SL_expired | SL_unknown -> false

let is_session_blocked = function
  | SL_failed | SL_cancelled | SL_interrupted -> true
  | SL_active | SL_running | SL_paused | SL_completed | SL_stopped | SL_expired | SL_unknown -> false

(** Dashboard tone — severity indicator for UI rendering.
    ADT eliminates catch-all patterns and enforces exhaustive matching.
    Serialized to string at JSON boundaries only. *)
type tone = Tone_ok | Tone_warn | Tone_bad

let string_of_tone = function
  | Tone_ok -> "ok"
  | Tone_warn -> "warn"
  | Tone_bad -> "bad"

let tone_rank = function
  | Tone_bad -> 2
  | Tone_warn -> 1
  | Tone_ok -> 0
