let parse_iso_opt = function
  | Some raw when String.trim raw <> "" -> (
      try Some (Masc_domain.parse_iso8601 raw) with Failure _ -> None)
  | _ -> None

let first_some a b = match a with Some _ as v -> v | None -> b

let string_contains = String_util.string_contains_substring

let string_contains_ci = String_util.string_contains_substring_ci


module String_set = Set_util.StringSet

let dedup_strings (xs : string list) : string list =
  let rec go seen acc = function
    | [] -> List.rev acc
    | x :: rest ->
      if String_set.mem x seen then go seen acc rest
      else go (String_set.add x seen) (x :: acc) rest
  in
  go String_set.empty [] xs

let string_list_of_json json =
  match json with
  | `List items ->
      items
      |> List.filter_map (function
             | `String value -> String_util.trim_to_option value
             | _ -> None)
  | _ -> []

let member_assoc key json =
  match json with
  | `Assoc fields -> (match List.assoc_opt key fields with Some v -> v | None -> `Null)
  | _ -> `Null

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

let unknown_status_label = "unknown"

let rec take n items =
  if n <= 0 then [] else match items with [] -> [] | x :: xs -> x :: take (n - 1) xs

let compact_text = String_util.compact_text

let normalized_text_key text =
  compact_text ~max_len:512 text |> String.trim |> String.lowercase_ascii

(** {1 Session JSON accessors}

    Canonical accessors for the nested session payload structure.
    A session JSON may carry its detail inside a ["status"] sub-object
    (when the status field is itself an [`Assoc]) or directly at the
    top level.  [session_payload_json] normalises this. *)

let session_payload_json session_json =
  match member_assoc "status" session_json with
  | `Assoc _ as payload -> payload
  | _ -> session_json

let session_meta_json session_json =
  session_payload_json session_json |> member_assoc "session"

let session_summary_json session_json =
  session_payload_json session_json |> member_assoc "summary"

let session_team_health_json session_json =
  session_payload_json session_json |> member_assoc "team_health"

let session_communication_json session_json =
  session_payload_json session_json |> member_assoc "communication_metrics"

let session_status_opt session_json =
  let summary = session_summary_json session_json in
  let meta = session_meta_json session_json in
  match String_util.trim_to_option (string_field "status" summary) with
  | Some _ as value -> value
  | None -> (
      match String_util.trim_to_option (string_field "status" meta) with
      | Some _ as value -> value
      | None -> String_util.trim_to_option (string_field "status" session_json))

let session_recent_events session_json =
  list_field "recent_events" session_json

let event_detail_json event_json =
  member_assoc "detail" event_json

(** Health severity level — ordered by {!Health_status.rank}.
    Parsed from dashboard/operator JSON at the call site via
    [health_level_of_string], then used in typed predicates below. *)
type health_level = Health_status.t

let health_level_of_string = Health_status.of_string

let string_of_health_level = Health_status.to_string

let severity_rank_of_health_level = Health_status.rank

(** Session lifecycle — parsed from session JSON at call sites.
    The variant makes the different terminal sets visible:
    - [is_session_terminal]: Completed | Cancelled | Failed | Stopped
    - [is_session_blocked]: Failed | Cancelled | Interrupted
    - dashboard_briefing terminal: Completed | Interrupted | Cancelled | Expired *)
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
  | SL_unknown -> unknown_status_label

(** Status/health classification predicates — single source of truth.
    Used across dashboard, briefing, and operator modules. *)

let is_keeper_offline status =
  List.mem status [ "offline"; "inactive"; "error" ]

let is_health_critical = Health_status.requires_operator_action

let is_health_warning health =
  match Health_status.rank health with
  | 1 | 2 -> true
  | _ -> false

let is_health_at_risk health = Health_status.rank health >= 2

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
