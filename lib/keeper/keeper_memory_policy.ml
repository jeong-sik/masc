(** Keeper_memory — memory-bank paths, reward-model evaluation,
    state snapshots, recall scoring, and metrics summaries. *)

open Keeper_types

(* Static patterns for [STATE] block detection, hoisted from
   [find_state_block].  [Re.compile] runs once at module load. *)
let state_start_re = Re.str "[STATE]" |> Re.compile
let state_end_re = Re.str "[/STATE]" |> Re.compile

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
  dropped_by_kind: (string * int) list;
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
  dropped_by_kind = [];
}

let keeper_memory_schema_version = 2
let replay_metadata_key = "masc.replay"
let replay_metadata_kind = "state_snapshot"
let replay_metadata_version = 1

let short_term_horizon = "short_term"
let mid_term_horizon = "mid_term"
let long_term_horizon = "long_term"

(* Strict classifier: returns [None] for unknown kinds so callers can
   distinguish "rule fired" from "fall-through default". See #8826. *)
let memory_horizon_of_kind_opt (kind : string) : string option =
  match String.lowercase_ascii (String.trim kind) with
  | "next" | "open_question" | "progress" -> Some short_term_horizon
  | "goal" | "decision" | "constraints" -> Some mid_term_horizon
  | "long_term" -> Some long_term_horizon
  | _ -> None

(* Back-compat wrapper: warns once per unknown kind and falls back to
   [mid_term_horizon] (the legacy permissive default). The explicit warn
   converts the silent #8605-family fallback into an observable signal
   without changing the legacy classification result. *)
let memory_horizon_of_kind (kind : string) : string =
  match memory_horizon_of_kind_opt kind with
  | Some h -> h
  | None ->
      Log.Memory.warn
        "memory_horizon_of_kind: unknown kind %S -> mid_term (drift; see #8826)"
        kind;
      mid_term_horizon

(* Strict JSON horizon parser: returns [None] for missing or unknown
   horizon strings so callers can decide whether to consult [kind] or
   reject the row. *)
let memory_horizon_of_json_opt (json : Yojson.Safe.t) : string option =
  match
    Safe_ops.json_string ~default:"" "horizon" json
    |> String.trim
    |> String.lowercase_ascii
  with
  | "short_term" -> Some short_term_horizon
  | "mid_term" -> Some mid_term_horizon
  | "long_term" -> Some long_term_horizon
  | _ -> None

(* Back-compat wrapper: when the JSON [horizon] is absent or unknown we
   fall through to [memory_horizon_of_kind kind] (which itself warns on
   unknown). The cascade is preserved exactly; the new wrapper just
   exposes a strict variant for new callers. *)
let memory_horizon_of_json ~(kind : string) (json : Yojson.Safe.t) : string =
  match memory_horizon_of_json_opt json with
  | Some h -> h
  | None -> memory_horizon_of_kind kind

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
  match Re.exec_opt state_start_re reply with
  | None -> None
  | Some g ->
    let start_idx = Re.Group.start g 0 in
    let body_start = start_idx + String.length "[STATE]" in
    (match Re.exec_opt ~pos:body_start state_end_re reply with
     | None -> None
     | Some g2 ->
       let end_idx = Re.Group.start g2 0 in
       if end_idx <= body_start then None
       else Some (String.sub reply body_start (end_idx - body_start)))

let state_snapshot_of_lines (lines : string list) : keeper_state_snapshot option =
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
      state_snapshot_of_lines lines

let state_snapshot_of_summary_text (text : string) : keeper_state_snapshot option =
  text
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")
  |> state_snapshot_of_lines

let forward_looking_snapshot
    (snapshot : keeper_state_snapshot) : keeper_state_snapshot =
  { snapshot with progress = None; done_summary = None }

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
  | Some s ->
      Some (String_util.utf8_safe ~max_bytes:(max_chars + 3) ~suffix:"…" s
            |> String_util.to_string)

let cap_list ~max_items ~max_item_chars items =
  let rec take n = function
    | _ when n <= 0 -> []
    | [] -> []
    | x :: rest -> x :: take (n - 1) rest
  in
  take max_items items
  |> List.map (fun item ->
      String_util.utf8_safe ~max_bytes:(max_item_chars + 3) ~suffix:"…" item |> String_util.to_string)

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
  let inert_next_markers =
    [
      "stay_silent";
      "stay silent";
      "wait for new actionable work";
      "nothing to do";
      "no actionable work";
      "do nothing";
      "all non-destructive actions exhausted";
      "대기 유지";
      "침묵";
      "할 일 없음";
      "아무것도 하지";
    ]
  in
  let stale_tool_surface_markers =
    [
      "masc_* only";
      "mcp__masc__ only";
      "no keeper_* tools";
      "no keeper tools";
      "tool surface: masc";
      "tool-surface: masc";
    ]
  in
  let strip_labeled_value ~prefixes line =
    let trimmed = String.trim line in
    let rec loop = function
      | [] -> None
      | prefix :: rest -> (
          match strip_prefix_ci ~prefix trimmed with
          | Some value -> Some value
          | None -> loop rest)
    in
    loop prefixes
  in
  let is_backward_line line =
    let trimmed = String.trim line in
    List.exists
      (fun label ->
        let prefix = label ^ ":" in
        String.length trimmed >= String.length prefix
        && String.sub trimmed 0 (String.length prefix) = prefix)
      backward_labels
  in
  let is_inert_next_line line =
    match strip_labeled_value ~prefixes:[ "Next plan:"; "Next:" ] line with
    | None -> false
    | Some value ->
        let payload = String.trim value in
        payload <> ""
        && List.exists
             (fun marker -> String_util.contains_substring_ci payload marker)
             inert_next_markers
  in
  let is_stale_tool_surface_line line =
    let payload = String.trim line in
    String_util.contains_substring_ci payload "tool"
    && (List.exists
          (fun marker -> String_util.contains_substring_ci payload marker)
          stale_tool_surface_markers
        || (String_util.contains_substring_ci payload "only"
            && (String_util.contains_substring_ci payload "allowed tool"
                || String_util.contains_substring_ci payload "available tool"
                || String_util.contains_substring_ci payload "visible tool"
                || String_util.contains_substring_ci payload "tool surface"
                || String_util.contains_substring_ci payload "tool-surface")))
  in
  let kept =
    summary
    |> String.split_on_char '\n'
    |> List.filter (fun line -> not (is_backward_line line))
    |> List.filter (fun line -> not (is_inert_next_line line))
    |> List.filter (fun line -> not (is_stale_tool_surface_line line))
    |> List.filter (fun line -> String.trim line <> "")
  in
  match kept with
  | [] -> ""
  | _ -> String.concat "\n" kept

let progress_markdown_of_snapshot
    ?generation
    ?updated_at
    (snapshot : keeper_state_snapshot) : string =
  let snapshot = forward_looking_snapshot snapshot in
  let body = keeper_state_snapshot_to_summary_text snapshot in
  let header =
    [
      "# Keeper Progress";
      (match generation with
       | Some g when g >= 0 -> Printf.sprintf "Generation: %d" g
       | _ -> "");
      (match updated_at with
       | Some ts when String.trim ts <> "" -> "Updated: " ^ String.trim ts
       | _ -> "");
      "This file is a filesystem-first recovery cache. Re-verify live world state before acting.";
    ]
    |> List.filter (fun line -> String.trim line <> "")
  in
  match String.trim body with
  | "" -> String.concat "\n" (header @ [ "No forward-looking state available." ]) ^ "\n"
  | body -> String.concat "\n" (header @ [ ""; body ]) ^ "\n"

let short_term_prompt_text_of_snapshot
    (snapshot : keeper_state_snapshot) : string =
  let parts =
    [
      (match snapshot.next_summary with
       | Some text when String.trim text <> "" ->
           Some ("Next plan: " ^ String.trim text)
       | _ -> None);
      (match snapshot.next_items with
       | [] -> None
       | items ->
           Some ("Next steps: " ^ String.concat "; " (List.map String.trim items)));
      (match snapshot.open_questions with
       | [] -> None
       | items ->
           Some ("Open questions: " ^ String.concat "; " (List.map String.trim items)));
    ]
    |> List.filter_map Fun.id
  in
  match parts with
  | [] -> ""
  | _ -> "Short-term memory:\n" ^ String.concat "\n" parts

let mid_term_prompt_text_of_snapshot
    (snapshot : keeper_state_snapshot) : string =
  let parts =
    [
      (match snapshot.goal with
       | Some text when String.trim text <> "" ->
           Some ("Goal: " ^ String.trim text)
       | _ -> None);
      (match snapshot.decisions with
       | [] -> None
       | items ->
           Some ("Decisions: " ^ String.concat "; " (List.map String.trim items)));
      (match snapshot.constraints with
       | [] -> None
       | items ->
           Some ("Constraints: " ^ String.concat "; " (List.map String.trim items)));
    ]
    |> List.filter_map Fun.id
  in
  match parts with
  | [] -> ""
  | _ -> "Mid-term memory:\n" ^ String.concat "\n" parts

type progress_snapshot_cache = {
  generation : int option;
  snapshot : keeper_state_snapshot;
}

let progress_generation_of_text (text : string) : int option =
  text
  |> String.split_on_char '\n'
  |> List.find_map (fun line ->
         match strip_prefix_ci ~prefix:"Generation:" line with
         | None -> None
         | Some raw -> int_of_string_opt (String.trim raw))

let progress_snapshot_cache_of_text (text : string) : progress_snapshot_cache option =
  match state_snapshot_of_summary_text text with
  | None -> None
  | Some snapshot ->
      Some {
        generation = progress_generation_of_text text;
        snapshot;
      }

let prompt_memory_sections_of_snapshot
    ~(current_generation : int)
    ?source_generation
    (snapshot : keeper_state_snapshot) : string list =
  let allow_short_term =
    match source_generation with
    | Some generation -> generation = current_generation
    | None -> true
  in
  [
    (if allow_short_term
     then short_term_prompt_text_of_snapshot snapshot
     else "");
    mid_term_prompt_text_of_snapshot snapshot;
  ]
  |> List.filter (fun text -> String.trim text <> "")

let read_progress_snapshot ~(config : Coord.config) ~(name : string)
    : keeper_state_snapshot option =
  match
    let path = keeper_progress_path config name in
    if not (Fs_compat.file_exists path) then
      None
    else
      try progress_snapshot_cache_of_text (Fs_compat.load_file path)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | _ -> None
  with
  | None -> None
  | Some cache -> Some cache.snapshot

let read_progress_snapshot_cache ~(config : Coord.config) ~(name : string)
    : progress_snapshot_cache option =
  let path = keeper_progress_path config name in
  if not (Fs_compat.file_exists path) then
    None
  else
    try
      progress_snapshot_cache_of_text (Fs_compat.load_file path)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> None

let write_progress_snapshot_path
    ~(path : string)
    ?generation
    ?updated_at
    (snapshot : keeper_state_snapshot) : (unit, string) result =
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file_atomic path
    (progress_markdown_of_snapshot ?generation ?updated_at snapshot)

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

let replay_metadata_of_snapshot
    (snapshot : keeper_state_snapshot) : Yojson.Safe.t =
  `Assoc [
    ("kind", `String replay_metadata_kind);
    ("version", `Int replay_metadata_version);
    ("payload", keeper_state_snapshot_to_json snapshot);
  ]

let snapshot_of_replay_metadata
    (json : Yojson.Safe.t) : keeper_state_snapshot option =
  try
    let open Yojson.Safe.Util in
    let kind = json |> member "kind" |> to_string_option in
    let version = json |> member "version" |> to_int_option in
    match kind, version with
    | Some kind, Some 1 when String.equal kind replay_metadata_kind ->
        keeper_state_snapshot_of_json (json |> member "payload")
    | _ -> None
  with
  | Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> None

let with_snapshot_metadata
    (msg : Oas.Types.message)
    (snapshot : keeper_state_snapshot) : Oas.Types.message =
  let metadata =
    (replay_metadata_key, replay_metadata_of_snapshot snapshot)
    :: List.remove_assoc replay_metadata_key msg.metadata
  in
  { msg with metadata }

let snapshot_of_message_metadata
    (msg : Oas.Types.message) : keeper_state_snapshot option =
  match List.assoc_opt replay_metadata_key msg.metadata with
  | Some json -> snapshot_of_replay_metadata json
  | None -> None

let snapshot_of_message
    (msg : Oas.Types.message) : keeper_state_snapshot option =
  match snapshot_of_message_metadata msg with
  | Some _ as snapshot -> snapshot
  | None ->
      parse_state_snapshot_from_reply (Oas.Types.text_of_message msg)

(** Extract a [keeper_state_snapshot] from the structured JSON stored in
    [Checkpoint.working_context].  Returns [None] if the JSON does not
    contain a valid version-1 state_snapshot. *)
let snapshot_of_structured_working_context
    (json : Yojson.Safe.t) : keeper_state_snapshot option =
  match snapshot_of_replay_metadata json with
  | Some _ as snapshot -> snapshot
  | None ->
      (try
         let open Yojson.Safe.Util in
         let version = json |> member "version" |> to_int_option in
         match version with
         | Some 1 ->
             let snapshot_json = json |> member "state_snapshot" in
             keeper_state_snapshot_of_json snapshot_json
         | _ -> None
       with
       | Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> None)

let latest_state_snapshot_from_messages (messages : Oas.Types.message list) :
    keeper_state_snapshot option =
  let rec loop (msgs : Oas.Types.message list) =
    match msgs with
    | [] -> None
    | msg :: rest ->
      match snapshot_of_message msg with
      | None -> loop rest
      | Some snapshot -> Some snapshot
  in
  loop (List.rev messages)

let priority_for_kind ~(kind : string) : int =
  match kind with
  | "constraints" -> 90
  | "decision" -> 86
  | "long_term" -> 95
  | "next" -> 80
  | "open_question" -> 76
  | "goal" -> 72
  | "progress" -> 66
  | _ -> 60

(* Byte-wise containment via [String_util.contains_substring_ci] —
   per-call [Re.compile] is gone and the two [String.lowercase_ascii]
   allocations are avoided since the helper folds case inline. *)
let contains_any_ci (text : string) (needles : string list) : bool =
  List.exists (String_util.contains_substring_ci text) needles

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

(** SSOT for canonical memory kind strings accepted by [keeper_memory_search]
    and produced by [keeper_memory_bank]. Mirrored (with a sync regression
    test) in [Tool_shard.memory_kind_enum_strings] because a direct
    dependency would create a Tool_shard -> Keeper_* -> Tool_shard cycle
    (#8467/#8480 pattern). Issue #8527. *)
let valid_memory_kind_strings : string list = List.map fst (kind_caps ())

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
    if trimmed = "" then None
    else
      Some (String_util.utf8_safe ~max_bytes:103 ~suffix:"..." trimmed
            |> String_util.to_string)
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
   | Some _ | None ->
     (match snapshot.progress with
      | Some p when String.trim p <> "" ->
        Buffer.add_string buf (Printf.sprintf "DONE: %s\n" p)
      | Some _ | None -> ()));
  (match snapshot.next_summary with
   | Some n when String.trim n <> "" ->
     Buffer.add_string buf (Printf.sprintf "NEXT: %s\n" n)
   | Some _ | None -> ());
  (match snapshot.goal with
   | Some g when String.trim g <> "" ->
     Buffer.add_string buf (Printf.sprintf "Goal: %s\n" g)
   | Some _ | None -> ());
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
