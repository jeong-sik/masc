(** Keeper_memory — memory-bank paths, reward-model evaluation,
    state snapshots, recall scoring, and metrics summaries. *)

open Keeper_types

type keeper_policy_observation = {
  source_kind: string;
  room_id: string option;
  from_agent: string;
  message: string;
  direct_mention: bool;
  has_question: bool;
  message_chars: int;
  total_turns: int;
  active_goal_count: int;
  joined_room_count: int;
  last_turn_ago_s: float;
}

let observation_has_question (message : string) =
  String.contains message '?'

let keeper_policy_observation_of_room_message
    ~(meta : keeper_meta)
    ~(room_id : string)
    (msg : Types.message) : keeper_policy_observation =
  let now_ts = Time_compat.now () in
  let mention_targets =
    if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]
  in
  let last_turn_ago_s =
    if meta.runtime.usage.last_turn_ts <= 0.0 then 0.0 else max 0.0 (now_ts -. meta.runtime.usage.last_turn_ts)
  in
  {
    source_kind = "room_message";
    room_id = Some room_id;
    from_agent = msg.from_agent;
    message = msg.content;
    direct_mention = Mention.any_mentioned ~targets:mention_targets msg.content;
    has_question = observation_has_question msg.content;
    message_chars = String.length msg.content;
    total_turns = meta.runtime.usage.total_turns;
    active_goal_count = List.length meta.active_goal_ids;
    joined_room_count = List.length meta.joined_room_ids;
    last_turn_ago_s;
  }

type alert_channel_result = {
  channel: string;
  attempted: bool;
  success: bool;
  attempts: int;
  detail: string option;
}

type interesting_alert_result = {
  enabled: bool;
  triggered: bool;
  score: float;
  threshold: float;
  reasons: string list;
  keywords: string list;
  alert_id: string option;
  channels: alert_channel_result list;
  retry_queued: bool;
  deadlettered: bool;
}

let empty_interesting_alert_result = {
  enabled = false;
  triggered = false;
  score = 0.0;
  threshold = 0.0;
  reasons = [];
  keywords = [];
  alert_id = None;
  channels = [];
  retry_queued = false;
  deadlettered = false;
}

let alert_channel_result_to_json (r : alert_channel_result) : Yojson.Safe.t =
  `Assoc [
    ("channel", `String r.channel);
    ("attempted", `Bool r.attempted);
    ("success", `Bool r.success);
    ("attempts", `Int r.attempts);
    ("detail",
      match r.detail with
      | Some d when String.trim d <> "" -> `String d
      | _ -> `Null);
  ]

type keeper_state_snapshot = {
  goal: string option;
  progress: string option;
  done_summary: string option;
  next_summary: string option;
  next_items: string list;
  decisions: string list;
  open_questions: string list;
  constraints: string list;
}

let empty_keeper_state_snapshot = {
  goal = None;
  progress = None;
  done_summary = None;
  next_summary = None;
  next_items = [];
  decisions = [];
  open_questions = [];
  constraints = [];
}

type keeper_memory_line = {
  kind: string;
  text: string;
  priority: int;
  ts_unix: float;
}

type keeper_memory_summary = {
  total_notes: int;
  last_ts_unix: float;
  top_kind: string option;
  kind_counts: (string * int) list;
  recent_notes: keeper_memory_line list;
}

type memory_bank_compaction = {
  performed: bool;
  reason: string option;
  target_notes: int;
  before_notes: int;
  after_notes: int;
  dropped_notes: int;
  dedup_dropped: int;
  invalid_dropped: int;
}

let no_memory_bank_compaction = {
  performed = false;
  reason = None;
  target_notes = 0;
  before_notes = 0;
  after_notes = 0;
  dropped_notes = 0;
  dedup_dropped = 0;
  invalid_dropped = 0;
}

let trim_nonempty (s : string) : string option =
  let t = String.trim s in
  if t = "" then None else Some t

let split_state_items (s : string) : string list =
  s
  |> String.split_on_char ';'
  |> List.map String.trim
  |> List.filter (fun x -> x <> "")
  |> take 6

let strip_prefix_ci ~(prefix : string) (s : string) : string option =
  let s = String.trim s in
  let plen = String.length prefix in
  if String.length s < plen then None
  else
    let head = String.sub s 0 plen |> String.lowercase_ascii in
    if head = String.lowercase_ascii prefix then
      Some (String.sub s plen (String.length s - plen) |> String.trim)
    else
      None

let find_state_block (reply : string) : string option =
  let start_re = Re.str "[STATE]" |> Re.compile in
  let end_re = Re.str "[/STATE]" |> Re.compile in
  match Re.exec_opt start_re reply with
  | None -> None
  | Some g ->
    let start_idx = Re.Group.start g 0 in
    let body_start = start_idx + String.length "[STATE]" in
    (match Re.exec_opt ~pos:body_start end_re reply with
     | None -> None
     | Some g2 ->
       let end_idx = Re.Group.start g2 0 in
       if end_idx <= body_start then None
       else Some (String.sub reply body_start (end_idx - body_start)))

let parse_state_snapshot_from_reply (reply : string) : keeper_state_snapshot option =
  match find_state_block reply with
  | None -> None
  | Some body ->
      let lines =
        body
        |> String.split_on_char '\n'
        |> List.map String.trim
        |> List.filter (fun line -> line <> "")
      in
      let snapshot =
        List.fold_left
          (fun acc line ->
            match strip_prefix_ci ~prefix:"Goal:" line with
            | Some v -> { acc with goal = trim_nonempty v }
            | None ->
                (match strip_prefix_ci ~prefix:"DONE:" line with
                | Some v -> { acc with done_summary = trim_nonempty v;
                                       progress = (match acc.progress with
                                                   | None -> trim_nonempty v
                                                   | existing -> existing) }
                | None ->
                (match strip_prefix_ci ~prefix:"Progress:" line with
                | Some v -> { acc with progress = trim_nonempty v }
                | None ->
                    (match strip_prefix_ci ~prefix:"NEXT:" line with
                    | Some v -> { acc with next_summary = trim_nonempty v;
                                           next_items = (match acc.next_items with
                                                         | [] -> split_state_items v
                                                         | existing -> existing) }
                    | None ->
                    (match strip_prefix_ci ~prefix:"Next:" line with
                    | Some v -> { acc with next_items = split_state_items v }
                    | None ->
                        (match strip_prefix_ci ~prefix:"Decisions:" line with
                        | Some v -> { acc with decisions = split_state_items v }
                        | None ->
                            (match strip_prefix_ci ~prefix:"OpenQuestions:" line with
                            | Some v ->
                                { acc with open_questions = split_state_items v }
                            | None ->
                                (match strip_prefix_ci
                                         ~prefix:"Constraints:" line
                                 with
                                | Some v ->
                                    { acc with constraints = split_state_items v }
                                | None -> acc))))))))
          empty_keeper_state_snapshot lines
      in
      if snapshot.goal = None
         && snapshot.progress = None
         && snapshot.next_items = []
         && snapshot.decisions = []
         && snapshot.open_questions = []
         && snapshot.constraints = []
      then
        None
      else
        Some snapshot

let keeper_state_snapshot_to_summary_text (snapshot : keeper_state_snapshot) : string =
  let maybe_line match_fn label =
    match match_fn () with
    | None -> None
    | Some value -> Some (Printf.sprintf "%s: %s" label value)
  in
  let lines =
    [
      maybe_line
        (fun () ->
           match snapshot.goal with
           | Some v when String.trim v <> "" -> Some (String.trim v)
           | _ -> None)
        "Goal";
      maybe_line
        (fun () ->
           match snapshot.done_summary with
           | Some v when String.trim v <> "" -> Some (String.trim v)
           | _ ->
             match snapshot.progress with
             | Some v when String.trim v <> "" -> Some (String.trim v)
             | _ -> None)
        "Done";
      maybe_line
        (fun () ->
           match snapshot.next_summary with
           | Some v when String.trim v <> "" -> Some (String.trim v)
           | _ -> None)
        "Next plan";
      maybe_line
        (fun () ->
           match snapshot.next_items with
           | [] -> None
           | items -> Some (String.concat "; " (take 3 (List.map String.trim items))))
        "Next";
      maybe_line
        (fun () ->
           match snapshot.decisions with
           | [] -> None
           | items -> Some (String.concat "; " (take 3 (List.map String.trim items))))
        "Decisions";
      maybe_line
        (fun () ->
           match snapshot.open_questions with
           | [] -> None
           | items -> Some (String.concat "; " (take 3 (List.map String.trim items))))
        "OpenQuestions";
      maybe_line
        (fun () ->
           match snapshot.constraints with
           | [] -> None
           | items -> Some (String.concat "; " (take 3 (List.map String.trim items))))
        "Constraints";
    ]
    |> List.filter_map (fun x -> x)
  in
  if lines = [] then "No continuity snapshot available." else String.concat "\n" lines

(* Gen7 (2026-04-17): snapshot size cap applied before persistence.

   Gen3 (PR #7647) trimmed backward fields at prompt injection and
   Gen4 (PR #7668) scrubbed [STATE] blocks in OAS compaction, both on
   the consumption side. Growth of [meta.continuity_summary] itself
   was still unbounded: if the LLM produces a longer [STATE] block
   each turn (more decisions, longer goal prose), the parsed snapshot
   and its rendered summary grow monotonically.

   This cap runs in [keeper_post_turn.apply_continuity_summary] before
   [keeper_state_snapshot_to_summary_text], bounding:
     - each string field (goal / progress / done_summary / next_summary)
       to [max_string_chars]
     - each list field (next_items / decisions / open_questions /
       constraints) to [max_list_items] items, with each item trimmed
       to [max_item_chars]

   Cap is applied post-parse, pre-render. Audit integrity is preserved
   because we keep the same shape; what drops is just the tail of long
   prose and surplus list items. *)

let default_max_string_chars = 400
let default_max_list_items = 5
let default_max_item_chars = 200

let cap_string ~max_chars = function
  | None -> None
  | Some s when String.length s <= max_chars -> Some s
  | Some s -> Some (String.sub s 0 max_chars ^ "…")

let cap_list ~max_items ~max_item_chars items =
  let rec take n = function
    | _ when n <= 0 -> []
    | [] -> []
    | x :: rest -> x :: take (n - 1) rest
  in
  take max_items items
  |> List.map (fun item ->
      if String.length item <= max_item_chars then item
      else String.sub item 0 max_item_chars ^ "…")

let cap_snapshot
    ?(max_string_chars = default_max_string_chars)
    ?(max_list_items = default_max_list_items)
    ?(max_item_chars = default_max_item_chars)
    (snapshot : keeper_state_snapshot) : keeper_state_snapshot =
  {
    goal = cap_string ~max_chars:max_string_chars snapshot.goal;
    progress = cap_string ~max_chars:max_string_chars snapshot.progress;
    done_summary = cap_string ~max_chars:max_string_chars snapshot.done_summary;
    next_summary = cap_string ~max_chars:max_string_chars snapshot.next_summary;
    next_items =
      cap_list ~max_items:max_list_items ~max_item_chars snapshot.next_items;
    decisions =
      cap_list ~max_items:max_list_items ~max_item_chars snapshot.decisions;
    open_questions =
      cap_list ~max_items:max_list_items ~max_item_chars snapshot.open_questions;
    constraints =
      cap_list ~max_items:max_list_items ~max_item_chars snapshot.constraints;
  }

(* RFC-MASC-001 Phase 1 post-mortem (Gen3 2026-04-17):
   [keeper_state_snapshot_to_summary_text] renders every field for audit/persistence.
   Injecting it verbatim into the next prompt creates a prose-level echo loop:
   LLM reads its own past [Done]/[Decisions] narrative and reproduces a
   near-identical one. Strip backward-looking fields at prompt assembly so the
   LLM sees only forward-looking context (Goal, Next plan, Next, OpenQuestions,
   Constraints). Persistence still retains the full summary. *)
let filter_forward_looking_summary (summary : string) : string =
  let backward_labels = [ "Done"; "Progress"; "Decisions" ] in
  let is_backward_line line =
    let trimmed = String.trim line in
    List.exists
      (fun label ->
        let prefix = label ^ ":" in
        String.length trimmed >= String.length prefix
        && String.sub trimmed 0 (String.length prefix) = prefix)
      backward_labels
  in
  let kept =
    summary
    |> String.split_on_char '\n'
    |> List.filter (fun line -> not (is_backward_line line))
    |> List.filter (fun line -> String.trim line <> "")
  in
  match kept with
  | [] -> ""
  | _ -> String.concat "\n" kept

let continuity_fallback_summary_text
    ~(continuity_summary : string)
    ~(last_continuity_update_ts : float) : string =
  let trimmed = String.trim continuity_summary in
  if trimmed = "" then
    "No continuity snapshot available."
  else
    let freshness_line =
      if last_continuity_update_ts > 0.0 then
        let age_s = max 0.0 (Time_compat.now () -. last_continuity_update_ts) in
        Printf.sprintf "Freshness: %.0fs since last continuity update." age_s
      else
        "Freshness: unknown (last continuity update timestamp unavailable)."
    in
    String.concat "\n"
      [
        "Continuity source: persisted keeper meta fallback.";
        freshness_line;
        "Checkpoint note: latest checkpoint [STATE] snapshot unavailable.";
        "Treat the following as prior context only and re-verify blockers, constraints, and repo state against the live world state before acting.";
        trimmed;
      ]

let keeper_state_snapshot_to_json (snapshot : keeper_state_snapshot) : Yojson.Safe.t =
  `Assoc [
    ("goal", Json_util.string_opt_to_json snapshot.goal);
    ("progress", Json_util.string_opt_to_json snapshot.progress);
    ("done_summary", Json_util.string_opt_to_json snapshot.done_summary);
    ("next_summary", Json_util.string_opt_to_json snapshot.next_summary);
    ("next_items", `List (List.map (fun s -> `String s) snapshot.next_items));
    ("decisions", `List (List.map (fun s -> `String s) snapshot.decisions));
    ("open_questions", `List (List.map (fun s -> `String s) snapshot.open_questions));
    ("constraints", `List (List.map (fun s -> `String s) snapshot.constraints));
  ]

(** Deserialize a [keeper_state_snapshot] from JSON produced by
    [keeper_state_snapshot_to_json].  Returns [None] if the JSON is
    malformed or represents an empty snapshot (all fields absent/empty).
    RFC-MASC-001 Phase 1: structured working_context in Checkpoint. *)
let keeper_state_snapshot_of_json (json : Yojson.Safe.t) : keeper_state_snapshot option =
  try
    let open Yojson.Safe.Util in
    let string_opt key = json |> member key |> to_string_option in
    let string_list key =
      match json |> member key with
      | `List items ->
        List.filter_map (function `String s -> Some s | _ -> None) items
      | _ -> []
    in
    let snapshot =
      { goal = string_opt "goal"
      ; progress = string_opt "progress"
      ; done_summary = string_opt "done_summary"
      ; next_summary = string_opt "next_summary"
      ; next_items = string_list "next_items"
      ; decisions = string_list "decisions"
      ; open_questions = string_list "open_questions"
      ; constraints = string_list "constraints"
      }
    in
    if snapshot.goal = None
       && snapshot.progress = None
       && snapshot.done_summary = None
       && snapshot.next_summary = None
       && snapshot.next_items = []
       && snapshot.decisions = []
       && snapshot.open_questions = []
       && snapshot.constraints = []
    then None
    else Some snapshot
  with
  | Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> None

(** Structured JSON wrapper for Checkpoint.working_context.
    Embeds the snapshot under a "state_snapshot" key alongside a
    "version" tag so future schema evolution is backward-compatible. *)
let structured_working_context_of_snapshot
    (snapshot : keeper_state_snapshot) : Yojson.Safe.t =
  `Assoc [
    ("version", `Int 1);
    ("state_snapshot", keeper_state_snapshot_to_json snapshot);
  ]

(** Extract a [keeper_state_snapshot] from the structured JSON stored in
    [Checkpoint.working_context].  Returns [None] if the JSON does not
    contain a valid version-1 state_snapshot. *)
let snapshot_of_structured_working_context
    (json : Yojson.Safe.t) : keeper_state_snapshot option =
  try
    let open Yojson.Safe.Util in
    let version = json |> member "version" |> to_int_option in
    match version with
    | Some 1 ->
      let snapshot_json = json |> member "state_snapshot" in
      keeper_state_snapshot_of_json snapshot_json
    | _ -> None
  with
  | Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> None

let latest_state_snapshot_from_messages (messages : Agent_sdk.Types.message list) :
    keeper_state_snapshot option =
  let rec loop (msgs : Agent_sdk.Types.message list) =
    match msgs with
    | [] -> None
    | msg :: rest ->
      match parse_state_snapshot_from_reply (Agent_sdk.Types.text_of_message msg) with
      | None -> loop rest
      | Some snapshot -> Some snapshot
  in
  loop (List.rev messages)

let priority_for_kind ~(kind : string) : int =
  match kind with
  | "constraints" -> 90
  | "decision" -> 86
  | "next" -> 80
  | "open_question" -> 76
  | "goal" -> 72
  | "progress" -> 66
  | _ -> 60

let contains_any_ci (text : string) (needles : string list) : bool =
  let hay = String.lowercase_ascii text in
  List.exists
    (fun needle ->
      let n = String.lowercase_ascii needle in
      n <> "" && Re.execp (Re.str n |> Re.compile) hay)
    needles

let signal_bonus ~(text : string) : int =
  let high_priority_words = [
    "risk"; "danger"; "unsafe"; "security"; "privacy"; "consent"; "guardrail";
    "위험"; "보안"; "개인정보"; "동의"; "안전";
    "blocker"; "deadline"; "ship"; "release"; "next step"; "todo"; "must";
    "막힘"; "차단"; "데드라인"; "배포"; "다음 단계"; "필수";
    "hypothesis"; "evidence"; "experiment"; "measure"; "benchmark"; "assume";
    "가설"; "근거"; "실험"; "측정"; "벤치";
    "preference"; "style"; "tone"; "boundary"; "expectation"; "trust";
    "선호"; "스타일"; "톤"; "경계"; "기대"; "신뢰";
    "required"; "중요"; "critical"
  ] in
  let uncertainty_words = [
    "unknown"; "unclear"; "maybe"; "tbd"; "later"; "todo"; "unsure";
    "모름"; "불명"; "아마"; "추정"; "미정"; "나중";
  ] in
  let keyword_bonus =
    if contains_any_ci text high_priority_words then 8 else 0
  in
  let uncertainty_penalty =
    if contains_any_ci text uncertainty_words then -8 else 0
  in
  keyword_bonus + uncertainty_penalty

let tuned_priority_for_candidate
    ~(kind : string)
    ~(text : string) : int =
  let base = priority_for_kind ~kind in
  let bonus = signal_bonus ~text in
  max 1 (min 100 (base + bonus))

let total_cap () : int = 12

let kind_caps () : (string * int) list =
  [ ("constraints", 2); ("decision", 2); ("next", 2); ("goal", 2); ("progress", 2); ("open_question", 2); ("long_term", 4) ]

let cap_for_kind (caps : (string * int) list) (kind : string) : int =
  List.assoc_opt kind caps |> Option.value ~default:1

(** Synthesize a [STATE] block from run metadata when the model omits one.
    Produces a deterministic snapshot from tool usage, stop reason, and goal
    so generation continuity is never broken. Tagged [SYNTHETIC] for
    downstream consumers to distinguish from model-generated blocks. *)
let synthesize_state_from_run_result
    ~(goal : string)
    ~(tools_used : string list)
    ~(stop_reason : string)
    ~(response_text : string)
    : keeper_state_snapshot =
  let progress =
    match tools_used with
    | [] -> Some "No tools used this generation"
    | ts ->
      let unique = List.sort_uniq String.compare ts in
      Some (Printf.sprintf "Used: %s" (String.concat ", " unique))
  in
  let next_items =
    if stop_reason = "budget_exhausted" then
      ["Continue previous work"; "Review results from last generation"]
    else []
  in
  let response_hint =
    let trimmed = String.trim response_text in
    if String.length trimmed > 100 then
      Some (String.sub trimmed 0 100 ^ "...")
    else if trimmed <> "" then Some trimmed
    else None
  in
  let decisions =
    match response_hint with
    | Some hint -> [Printf.sprintf "[SYNTHETIC] Last output: %s" hint]
    | None -> ["[SYNTHETIC] No visible output this generation"]
  in
  { goal = (let g = String.trim goal in if g = "" then None else Some g);
    progress;
    done_summary = progress;
    next_summary = (match next_items with
                    | [] -> None
                    | items -> Some (String.concat "; " items));
    next_items;
    decisions;
    open_questions = [];
    constraints = [];
  }

(** Render a [keeper_state_snapshot] back into a [\[STATE\]...\[/STATE\]] block. *)
let render_state_block (snapshot : keeper_state_snapshot) : string =
  let buf = Buffer.create 256 in
  Buffer.add_string buf "[STATE]\n";
  (match snapshot.done_summary with
   | Some d when String.trim d <> "" ->
     Buffer.add_string buf (Printf.sprintf "DONE: %s\n" d)
   | _ ->
     (match snapshot.progress with
      | Some p when String.trim p <> "" ->
        Buffer.add_string buf (Printf.sprintf "DONE: %s\n" p)
      | _ -> ()));
  (match snapshot.next_summary with
   | Some n when String.trim n <> "" ->
     Buffer.add_string buf (Printf.sprintf "NEXT: %s\n" n)
   | _ -> ());
  (match snapshot.goal with
   | Some g when String.trim g <> "" ->
     Buffer.add_string buf (Printf.sprintf "Goal: %s\n" g)
   | _ -> ());
  (match snapshot.next_items with
   | [] -> ()
   | items ->
     Buffer.add_string buf
       (Printf.sprintf "Next: %s\n" (String.concat "; " items)));
  (match snapshot.decisions with
   | [] -> ()
   | items ->
     Buffer.add_string buf
       (Printf.sprintf "Decisions: %s\n" (String.concat "; " items)));
  (match snapshot.open_questions with
   | [] -> ()
   | items ->
     Buffer.add_string buf
       (Printf.sprintf "OpenQuestions: %s\n" (String.concat "; " items)));
  (match snapshot.constraints with
   | [] -> ()
   | items ->
     Buffer.add_string buf
       (Printf.sprintf "Constraints: %s\n" (String.concat "; " items)));
  Buffer.add_string buf "[/STATE]";
  Buffer.contents buf
