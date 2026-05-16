(** Dashboard_goals_types — pure types + task helpers extracted from
    Dashboard_goals (1998 LoC godfile).

    See dashboard_goals_types.mli for rationale and contract. *)

open Yojson.Safe.Util

type tree_node = {
  goal : Goal_store.goal;
  children : tree_node list;
  tasks : (Masc_domain.task * string) list;
  convergence : float;
  health : string;
  badges : string list;
  last_activity_at : string;
  stagnation_seconds : int;
  linked_keeper_names : string list;
  pending_approval_count : int;
  infra_risk_count : int;
  linkage_source : string;
  linkage_warning_count : int;
  status_reason : string;
  blocking_source : string;
  blocking_reason : string;
  latest_keeper_ref : string option;
  latest_turn_ref : int option;
  stalled_since : string option;
  activity_observation : string;
  stagnation_status : string;
}

type goal_detail_keeper = {
  meta : Keeper_types.keeper_meta;
  latest_receipt : Yojson.Safe.t option;
  runtime_trust : Yojson.Safe.t;
}

type attainment_unit =
  | Percent
  | Count
  | Unknown

let task_is_linked_to_goal (task : Masc_domain.task) goal_id =
  Convergence.task_matches_goal ~goal_id task

let task_linkage_source_opt (task : Masc_domain.task) goal_id =
  match task.goal_id with
  | Some task_goal_id when String.equal task_goal_id goal_id -> Some "explicit"
  | Some _ -> None
  | None ->
      if task_is_linked_to_goal task goal_id then Some "title_tag" else None

let task_assignee (task : Masc_domain.task) : string option =
  Masc_domain.task_assignee_of_status task.task_status

let task_status_label (task : Masc_domain.task) : string =
  match task.task_status with
  | Masc_domain.Todo -> "pending"
  | Masc_domain.Claimed _ -> "claimed"
  | Masc_domain.InProgress _ -> "in_progress"
  | Masc_domain.AwaitingVerification _ -> "awaiting_verification"
  | Masc_domain.Done _ -> "completed"
  | Masc_domain.Cancelled _ -> "cancelled"

let task_is_terminal (task : Masc_domain.task) : bool =
  Masc_domain.task_status_is_terminal task.task_status

let task_is_done (task : Masc_domain.task) : bool =
  Masc_domain.task_status_is_done task.task_status

let task_updated_at (task : Masc_domain.task) : string =
  match task.task_status with
  | Masc_domain.Done { completed_at; _ } -> completed_at
  | Masc_domain.Cancelled { cancelled_at; _ } -> cancelled_at
  | Masc_domain.InProgress { started_at; _ } -> started_at
  | Masc_domain.AwaitingVerification { submitted_at; _ } -> submitted_at
  | Masc_domain.Claimed { claimed_at; _ } -> claimed_at
  | Masc_domain.Todo -> task.created_at

let dedupe_sort values =
  values |> List.sort_uniq String.compare

let link_source_of_values values =
  let normalized =
    values
    |> List.filter (fun value -> value <> "" && not (String.equal value "none"))
    |> dedupe_sort
  in
  match normalized with
  | [] -> "none"
  | [ source ] -> source
  | _ -> "mixed"
let receipt_error_kind json =
  match json |> member "error" with
  | `Assoc _ as error -> error |> member "kind" |> to_string_option
  | _ -> None

let receipt_error_message json =
  match json |> member "error" with
  | `Assoc _ as error -> error |> member "message" |> to_string_option
  | _ -> None

let receipt_sandbox_kind json =
  json |> member "sandbox" |> member "kind" |> to_string_option

let receipt_approval_profile json =
  json |> member "approval" |> member "profile" |> to_string_option

let receipt_cascade_name json =
  json |> member "cascade" |> member "name" |> to_string_option

let receipt_cascade_outcome json =
  json |> member "cascade" |> member "outcome" |> to_string_option

let receipt_cascade_fallback_applied json =
  json |> member "cascade" |> member "fallback_applied" |> to_bool_option
  |> Option.value ~default:false

let receipt_outcome json =
  json |> member "outcome" |> to_string_option

let receipt_started_at json =
  json |> member "started_at" |> to_string_option

let receipt_ended_at json =
  json |> member "ended_at" |> to_string_option

let receipt_turn_count json =
  json |> member "turn_count" |> to_int_option

let trust_disposition json =
  json |> member "disposition" |> to_string_option

let trust_disposition_reason json =
  json |> member "disposition_reason" |> to_string_option

let trust_attention_reason json =
  json |> member "attention_reason" |> to_string_option

let trust_needs_attention json =
  json |> member "needs_attention" |> to_bool_option
  |> Option.value ~default:false

let trust_snapshot_unavailable json =
  String.equal
    (json |> member "disposition_reason" |> to_string_option
     |> Option.value ~default:"")
    "runtime_trust_snapshot_unavailable"

let trust_turn_id json =
  json |> member "turn_id" |> to_int_option

let trust_latest_event json =
  match json |> member "latest_causal_event" with
  | `Assoc _ as event -> Some event
  | _ -> None

let trust_latest_event_ts json =
  Option.bind (trust_latest_event json) (fun event ->
      event |> member "ts" |> to_string_option )

let trust_latest_event_ts_unix json =
  Option.bind (trust_latest_event json) (fun event ->
      event |> member "ts_unix" |> to_float_option )

let trust_sandbox_risk json =
  String.equal
    (json |> member "disposition_reason" |> to_string_option
     |> Option.value ~default:"")
    "sandbox_violation"

let trust_cascade_risk json =
  String.equal
    (json |> member "disposition_reason" |> to_string_option
     |> Option.value ~default:"")
    "cascade_exhausted"

let receipt_has_error json =
  match receipt_error_kind json with
  | Some _ -> true
  | None ->
      (match receipt_outcome json with
       | Some "completed" | Some "success" | Some "not_observed" | None -> false
       | Some _ -> false)

let receipt_has_sandbox_risk json =
  match receipt_sandbox_kind json with
  | Some "local" -> false
  | Some "docker" -> false
  | Some _ | None -> false

let receipt_has_cascade_risk json =
  receipt_cascade_fallback_applied json
  ||
  match receipt_cascade_outcome json with
  | Some "passed_to_next_model" -> true
  | _ -> false

let iso_max left right =
  if String.compare left right >= 0 then left else right

let latest_iso ?fallback values =
  match values with
  | [] -> fallback
  | first :: rest ->
      Some (List.fold_left iso_max first rest)

let stagnation_threshold_seconds = function
  | Goal_store.Short -> 6 * 3600
  | Goal_store.Mid -> 24 * 3600
  | Goal_store.Long -> 72 * 3600

let human_duration seconds =
  if seconds < 3600 then Printf.sprintf "%dm" (seconds / 60)
  else if seconds < 86400 then Printf.sprintf "%dh" (seconds / 3600)
  else Printf.sprintf "%dd" (seconds / 86400)

(** {1 Metric parsing utilities — pure tokenizer + percent/count inference} *)

let clamp_float lower upper value =
  if value < lower then lower else if value > upper then upper else value

let pct_of_float value =
  int_of_float (floor (clamp_float 0.0 100.0 value +. 0.5))

let json_float_opt = function
  | Some value -> `Float value
  | None -> `Null

let json_int_opt = function
  | Some value -> `Int value
  | None -> `Null

let attainment_unit_to_string = function
  | Percent -> "percent"
  | Count -> "count"
  | Unknown -> "unknown"

let contains_ci haystack needle =
  String_util.contains_substring_ci haystack needle

(* Token-split that respects camelCase AND acronym boundaries.

   - lower → upper splits (so [successRate] → [success; rate])
   - upper → upper-followed-by-lower splits (so [APIRatio] →
     [api; ratio]; [PRCount] → [pr; count])
   - consecutive uppercase letters not followed by a lowercase stay
     glued (so [API] → [api], [HTTP] → [http])

   Without the acronym rule, common acronym-prefixed metric names
   regressed against percent inference: post-#13170 review noted
   that names like [APIRatio] / [PRCount] still missed the percent
   token even after the camelCase fix.  The split point is the
   *last* uppercase letter in a run — that is the start of the
   following lowercase word — not every uppercase letter, so
   abbreviations stay intact. *)
let metric_word_tokens raw =
  let len = String.length raw in
  let tokens = ref [] in
  let current = Buffer.create 16 in
  let flush () =
    if Buffer.length current > 0 then (
      tokens := Buffer.contents current :: !tokens;
      Buffer.clear current)
  in
  let is_lower c = c >= 'a' && c <= 'z' in
  let is_upper c = c >= 'A' && c <= 'Z' in
  let next_at i = if i + 1 < len then Some raw.[i + 1] else None in
  let prev_at i = if i > 0 then Some raw.[i - 1] else None in
  for i = 0 to len - 1 do
    let ch = raw.[i] in
    match ch with
    | 'A' .. 'Z' ->
        let prev_lower =
          match prev_at i with Some c -> is_lower c | None -> false
        in
        let prev_upper =
          match prev_at i with Some c -> is_upper c | None -> false
        in
        let next_lower =
          match next_at i with Some c -> is_lower c | None -> false
        in
        if prev_lower then flush ()
        else if prev_upper && next_lower then flush ();
        Buffer.add_char current (Char.lowercase_ascii ch)
    | 'a' .. 'z' | '0' .. '9' ->
        Buffer.add_char current ch
    | _ ->
        flush ()
  done;
  flush ();
  List.rev !tokens

(* Post-#13131 review (P1): substring match on "rate"/"ratio"/"pct"
   gave false positives for metric names like "iteration_rate"-vs-
   "iterate", "operation"-vs-"ratio".  Match against tokenized words
   (alphanumerics split on punctuation) so only the actual metric
   nouns trigger the percent inference. *)
let metric_word_implies_percent token =
  match token with
  | "percent" | "pct" | "ratio" | "rate" | "completion" -> true
  | _ -> false

let metric_implies_percent metric =
  match metric with
  | None -> false
  | Some raw ->
      contains_ci raw "%"
      || List.exists metric_word_implies_percent (metric_word_tokens raw)

let metric_count_token = function
  | "task" | "tasks" | "todo" | "todos" | "issue" | "issues" | "ticket"
  | "tickets" | "pr" | "prs" | "done" ->
      true
  | _ ->
      false

let metric_has_pull_request_phrase tokens =
  let rec loop = function
    | "pull" :: next :: _ when next = "request" || next = "requests" -> true
    | _ :: rest -> loop rest
    | [] -> false
  in
  loop tokens

let metric_supports_count_target metric =
  match metric with
  | None -> true
  | Some raw ->
      let tokens = metric_word_tokens raw in
      List.exists metric_count_token tokens
      || metric_has_pull_request_phrase tokens

let target_value_implies_percent raw =
  contains_ci raw "%"
  || contains_ci raw "percent"
  || contains_ci raw "pct"

let strip_number_group_separators token =
  let buffer = Buffer.create (String.length token) in
  String.iter
    (fun ch ->
      if ch <> ',' then
        Buffer.add_char buffer ch)
    token;
  Buffer.contents buffer

let parse_first_float raw =
  let len = String.length raw in
  let is_digit = function
    | '0' .. '9' -> true
    | _ -> false
  in
  let is_start = function
    | '0' .. '9' | '+' | '-' | '.' -> true
    | _ -> false
  in
  let is_part ~start index =
    match raw.[index] with
    | '0' .. '9' | '.' -> true
    | '+' | '-' -> index = start
    | ',' ->
        index > 0 && index + 1 < len && is_digit raw.[index - 1]
        && is_digit raw.[index + 1]
    | _ -> false
  in
  let rec token_end start index =
    if index >= len || not (is_part ~start index) then index
    else token_end start (index + 1)
  in
  let rec search index =
    if index >= len then None
    else if is_start raw.[index] then
      let stop = token_end index index in
      let token = String.sub raw index (stop - index) in
      match float_of_string_opt (strip_number_group_separators token) with
      | Some value when Float.is_finite value -> Some value
      | Some _ | None -> search stop
    else
      search (index + 1)
  in
  search 0

let parsed_target_unit metric raw =
  if target_value_implies_percent raw || metric_implies_percent metric then
    Percent
  else
    Count
