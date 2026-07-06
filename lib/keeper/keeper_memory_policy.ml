(** Keeper_memory — memory-bank paths, reward-model evaluation,
    state snapshots, recall scoring, and metrics summaries.

    Spec navigation (OCaml -> TLA+) — plan §19 anchor pattern.
    Authoritative spec mirror is
    [specs/keeper-state-machine/KeeperMemoryLifecycle.tla] (#8642 family).

    The spec preamble cites this module field-by-field:
      short_mem / mid_mem / long_mem  -> rows with [horizon] in
                                         {"short_term", "mid_term",
                                          "long_term"}, see the
                                         constants [short_term_horizon],
                                         [mid_term_horizon],
                                         [long_term_horizon].
      provenanced  -> rows with non-empty trace_id / source
                      (lives in keeper_memory_bank, not this file).
      producer     -> [memory_horizon_of_kind_opt] (strict).

    This block is the reverse-direction citation so code search for
    "KeeperMemoryLifecycle" lands here.  Citations are by symbol name,
    not line number: the spec preamble used to carry "ml:155 / ml:156 /
    ml:157" for the horizon constants but those drifted (>+30 once
    `compaction_outcome` fields were inserted between the citation and
    the constants) and were removed — symbol names are the stable anchor
    (iter 64 N-2.a; guarded by scripts/audit-ocaml-spec-nav-line-refs.sh,
    iter 72 R-1.a).

    Spec safety goals (line 9-13):
      - every persisted note has provenance
      - overflow / handoff do not silently drop retained notes
      - handoff clears stale short-term notes
      - each tier stays within its configured bound

    Sibling spec anchors deferred:
      - keeper_memory_bank.ml (open_short / provenanced semantics) *)

open Keeper_meta_contract

(* Static patterns for [STATE] block detection, hoisted from
   [find_state_block].  [Re.compile] runs once at module load. *)
let state_start_re = Re.str "[STATE]" |> Re.compile
let state_end_re = Re.str "[/STATE]" |> Re.compile

type keeper_state_snapshot = {
  priority: int option;
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
  priority = None;
  goal = None;
  progress = None;
  done_summary = None;
  next_summary = None;
  next_items = [];
  decisions = [];
  open_questions = [];
  constraints = [];
}

(* Provenance of a turn's continuity snapshot, produced by the four-way
   extraction cascade in [Keeper_agent_run_response_text]. Serialized to the turn
   sidecar via [state_snapshot_source_to_string]; nothing parses it back in OCaml,
   so there is no [of_string]. RFC-0242 §3.2 replaces the prior untyped string +
   [String.starts_with ~prefix:"synthesized_"] classifier (the prefix matched no
   producer — dead permissive match). *)
type state_snapshot_source =
  | Structured_state_tool
      (* Reported by the removed [keeper_report_state] tool. Currently
         unreachable: [reported_state_snapshot] is hard-[None]
         (keeper_agent_run_finalize_response.ml:reported_state_snapshot_from_checkpoint).
         Removed when RFC-0242 §3.1 wires an enforced structured producer. *)
  | Structured_state_reply (* Parsed from a JSON object in the model's reply. *)
  | State_block (* Parsed from a [STATE] prose block in the reply. *)
  | Synthesized (* Fabricated from run metadata when no state was emitted. *)

let state_snapshot_source_to_string = function
  | Structured_state_tool -> "model_structured_state_tool"
  | Structured_state_reply -> "model_structured_state"
  | State_block -> "model_state_block"
  | Synthesized -> "synthesized"

let state_snapshot_source_is_synthetic = function
  | Synthesized -> true
  | Structured_state_tool | Structured_state_reply | State_block -> false

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

type compaction_source =
  | Pre_dispatch_hygiene
  | MASC_policy
  | Memory_bank

let compaction_source_to_string = function
  | Pre_dispatch_hygiene -> "pre_dispatch_hygiene"
  | MASC_policy -> "masc_policy"
  | Memory_bank -> "memory_bank"

let compaction_source_of_string_opt (s : string) : compaction_source option =
  match s with
  | "pre_dispatch_hygiene" -> Some Pre_dispatch_hygiene
  | "masc_policy" -> Some MASC_policy
  | "memory_bank" -> Some Memory_bank
  | _ -> None

type compaction_error =
  | Read_error
  | Write_error of string
  | Schema_mismatch

let compaction_error_to_string = function
  | Read_error -> "read_error"
  | Write_error msg -> "write_error: " ^ msg
  | Schema_mismatch -> "schema_mismatch"
;;

type memory_bank_compaction = {
  performed: bool;
  source: compaction_source option;
  target_notes: int;
  before_notes: int;
  after_notes: int;
  dropped_notes: int;
  dedup_dropped: int;
  invalid_dropped: int;
  dropped_by_kind: (string * int) list;
  error: compaction_error option;
}

let no_memory_bank_compaction = {
  performed = false;
  source = None;
  target_notes = 0;
  before_notes = 0;
  after_notes = 0;
  dropped_notes = 0;
  dedup_dropped = 0;
  invalid_dropped = 0;
  dropped_by_kind = [];
  error = None;
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

(* Strict JSON horizon parser: returns [None] for missing or unknown
   horizon strings so callers can reject non-canonical rows. *)
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


let split_state_items (s : string) : string list =
  s
  |> String.split_on_char ';'
  |> List.map String.trim
  |> List.filter (fun x -> x <> "")
  |> (fun xs -> List.filteri (fun i _ -> i < 6) xs)

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
        | Some v -> { acc with goal = String_util.trim_nonempty v }
        | None ->
            (match strip_prefix_ci ~prefix:"DONE:" line with
            | Some v -> { acc with done_summary = String_util.trim_nonempty v;
                                   progress = (match acc.progress with
                                               | None -> String_util.trim_nonempty v
                                               | existing -> existing) }
            | None ->
            (match strip_prefix_ci ~prefix:"Progress:" line with
            | Some v -> { acc with progress = String_util.trim_nonempty v }
            | None ->
                (match strip_prefix_ci ~prefix:"NEXT PLAN:" line with
                | Some v -> { acc with next_summary = String_util.trim_nonempty v }
                | None ->
                (match strip_prefix_ci ~prefix:"NEXT:" line with
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
  if snapshot.priority = None
     && snapshot.goal = None
     && snapshot.progress = None
     && snapshot.done_summary = None
     && snapshot.next_summary = None
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
           | items -> Some (String.concat "; " (List.filteri (fun i _ -> i < 3) (List.map String.trim items))))
        "Next";
      maybe_line
        (fun () ->
           match snapshot.decisions with
           | [] -> None
           | items -> Some (String.concat "; " (List.filteri (fun i _ -> i < 3) (List.map String.trim items))))
        "Decisions";
      maybe_line
        (fun () ->
           match snapshot.open_questions with
           | [] -> None
           | items -> Some (String.concat "; " (List.filteri (fun i _ -> i < 3) (List.map String.trim items))))
        "OpenQuestions";
      maybe_line
        (fun () ->
           match snapshot.constraints with
           | [] -> None
           | items -> Some (String.concat "; " (List.filteri (fun i _ -> i < 3) (List.map String.trim items))))
        "Constraints";
    ]
    |> List.filter_map (fun x -> x)
  in
  if lines = [] then "No continuity snapshot available." else String.concat "\n" lines

(* Gen7 (2026-04-17): snapshot size cap applied before persistence.

   Gen3 (PR #7647) trimmed backward fields at prompt injection and
   Gen4 (PR #7668) scrubbed [STATE] blocks during runtime compaction
   on the consumption side. Growth of [meta.continuity_summary] itself
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
let default_continuity_summary_max_chars = 5_600

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
    priority = snapshot.priority;
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

let cap_continuity_summary_text
    ?(max_chars = default_continuity_summary_max_chars)
    (text : string) : string =
  let trimmed = String.trim text in
  if trimmed = "" then ""
  else
    String_util.utf8_safe ~max_bytes:(max_chars + 3) ~suffix:"…" trimmed
    |> String_util.to_string

(* RFC-MASC-001 Phase 1 post-mortem (Gen3 2026-04-17):
   [keeper_state_snapshot_to_summary_text] renders every field for audit/persistence.
   Injecting it verbatim into the next prompt creates a prose-level echo loop:
   LLM reads its own past [Done]/[Decisions] narrative and reproduces a
   near-identical one. Strip backward-looking fields at prompt assembly so the
   LLM sees only forward-looking context (Goal, Next plan, Next, OpenQuestions,
   Constraints). Persistence still retains the full summary. *)
let filter_forward_looking_summary =
  Keeper_memory_policy_summary_filter.filter_forward_looking_summary

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
       | Some ts ->
           let trimmed = String.trim ts in
           if trimmed <> "" then "Updated: " ^ trimmed else ""
       | None -> "");
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

let read_progress_snapshot ~(config : Workspace.config) ~(name : string)
    : keeper_state_snapshot option =
  match
    let path = Keeper_types_support.keeper_progress_path config name in
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

let read_progress_snapshot_cache ~(config : Workspace.config) ~(name : string)
    : progress_snapshot_cache option =
  let path = Keeper_types_support.keeper_progress_path config name in
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
    let bounded = cap_continuity_summary_text trimmed in
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
        bounded;
      ]

let keeper_state_snapshot_to_json (snapshot : keeper_state_snapshot) : Yojson.Safe.t =
  `Assoc [
    ("priority", match snapshot.priority with Some p -> `Int p | None -> `Null);
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
  let string_opt key = Json_util.get_string json key in
  let string_list key =
    match Json_util.assoc_member_opt key json with
    | Some (`List items) ->
      List.filter_map (function `String s -> Some s | _ -> None) items
    | _ -> []
  in
  let snapshot =
    { priority = Json_util.get_int json "priority"
    ; goal = string_opt "goal"
    ; progress = string_opt "progress"
    ; done_summary = string_opt "done_summary"
    ; next_summary = string_opt "next_summary"
    ; next_items = string_list "next_items"
    ; decisions = string_list "decisions"
    ; open_questions = string_list "open_questions"
    ; constraints = string_list "constraints"
    }
  in
  if snapshot.priority = None
     && snapshot.goal = None
     && snapshot.progress = None
     && snapshot.done_summary = None
     && snapshot.next_summary = None
     && snapshot.next_items = []
     && snapshot.decisions = []
     && snapshot.open_questions = []
     && snapshot.constraints = []
  then None
  else Some snapshot

(** Structured JSON wrapper for Checkpoint.working_context.
    Embeds the snapshot under a "state_snapshot" key alongside a
    "version" tag so future schema evolution is backward-compatible. *)
let structured_working_context_of_snapshot
    (snapshot : keeper_state_snapshot) : Yojson.Safe.t =
  `Assoc [
    ("version", `Int 1);
    ("state_snapshot", keeper_state_snapshot_to_json snapshot);
  ]

let replay_metadata_provenance_fields = function
  | None -> []
  | Some state_snapshot_source ->
      let synthetic = state_snapshot_source_is_synthetic state_snapshot_source in
      [
        ("state_snapshot_source", `String (state_snapshot_source_to_string state_snapshot_source));
        ("state_snapshot_synthetic", `Bool synthetic);
        ("state_snapshot_live_observation", `Bool (not synthetic));
        ("state_snapshot_model_authored", `Bool (not synthetic));
      ]

let replay_metadata_of_snapshot
    ?state_snapshot_source
    (snapshot : keeper_state_snapshot) : Yojson.Safe.t =
  `Assoc
    ([
       ("kind", `String replay_metadata_kind);
       ("version", `Int replay_metadata_version);
       ("payload", keeper_state_snapshot_to_json snapshot);
     ]
     @ replay_metadata_provenance_fields state_snapshot_source)

let snapshot_of_replay_metadata
    (json : Yojson.Safe.t) : keeper_state_snapshot option =
  let kind = Json_util.get_string json "kind" in
  let version = Json_util.get_int json "version" in
  match kind, version with
  | Some kind, Some 1 when String.equal kind replay_metadata_kind ->
      (match Json_util.assoc_member_opt "payload" json with
       | Some payload -> keeper_state_snapshot_of_json payload
       | None -> None)
  | _ -> None

let with_snapshot_metadata
    ?state_snapshot_source
    (msg : Agent_sdk.Types.message)
    (snapshot : keeper_state_snapshot) : Agent_sdk.Types.message =
  let metadata =
    ( replay_metadata_key,
      replay_metadata_of_snapshot ?state_snapshot_source snapshot )
    :: List.remove_assoc replay_metadata_key msg.metadata
  in
  { msg with metadata }

let snapshot_of_message_metadata
    (msg : Agent_sdk.Types.message) : keeper_state_snapshot option =
  match List.assoc_opt replay_metadata_key msg.metadata with
  | Some json -> snapshot_of_replay_metadata json
  | None -> None

let snapshot_of_message
    (msg : Agent_sdk.Types.message) : keeper_state_snapshot option =
  match snapshot_of_message_metadata msg with
  | Some _ as snapshot -> snapshot
  | None ->
      parse_state_snapshot_from_reply (Agent_sdk.Types.text_of_message msg)

let replay_snapshot_empty_text_only
    (msg : Agent_sdk.Types.message) : bool =
  match msg.Agent_sdk.Types.role with
  | Agent_sdk.Types.Assistant ->
      Option.is_some (snapshot_of_message_metadata msg)
      && List.for_all
           (function
             | Agent_sdk.Types.Text text -> String.trim text = ""
             | Agent_sdk.Types.Thinking _
             | Agent_sdk.Types.ReasoningDetails _
             | Agent_sdk.Types.RedactedThinking _
             | Agent_sdk.Types.ToolUse _
             | Agent_sdk.Types.ToolResult _
             | Agent_sdk.Types.Image _
             | Agent_sdk.Types.Document _
             | Agent_sdk.Types.Audio _ ->
                 false)
           msg.content
  | Agent_sdk.Types.System
  | Agent_sdk.Types.User
  | Agent_sdk.Types.Tool ->
      false

let drop_empty_replay_snapshot_suffix
    (messages : Agent_sdk.Types.message list) : Agent_sdk.Types.message list =
  let rec drop = function
    | msg :: rest when replay_snapshot_empty_text_only msg -> drop rest
    | rev_messages -> rev_messages
  in
  messages |> List.rev |> drop |> List.rev

(** Extract a [keeper_state_snapshot] from the structured JSON stored in
    [Checkpoint.working_context].  Returns [None] if the JSON does not
    contain a valid version-1 state_snapshot. *)
let snapshot_of_structured_working_context
    (json : Yojson.Safe.t) : keeper_state_snapshot option =
  match snapshot_of_replay_metadata json with
  | Some _ as snapshot -> snapshot
  | None ->
      let version = Json_util.get_int json "version" in
      (match version with
       | Some 1 ->
           (match Json_util.assoc_member_opt "state_snapshot" json with
            | Some snapshot_json -> keeper_state_snapshot_of_json snapshot_json
            | None -> None)
       | _ -> None)

let structured_state_snapshot_of_json
    (json : Yojson.Safe.t) : keeper_state_snapshot option =
  match snapshot_of_structured_working_context json with
  | Some _ as snapshot -> snapshot
  | None -> keeper_state_snapshot_of_json json

let structured_param ~name ~description ~param_type ~required =
  { Agent_sdk.Types.name = name; description; param_type; required }

let structured_state_snapshot_schema :
    keeper_state_snapshot Agent_sdk.Structured.schema =
  { Agent_sdk.Structured.name = "keeper_state_snapshot";
    description =
      "Structured keeper continuity state for the completed turn. Return only \
       this JSON object when the runtime requests structured state.";
    params =
      [ structured_param
          ~name:"priority"
          ~description:"Self-evaluated priority score (1-100) for how critical the decisions and next steps in this generation are."
          ~param_type:Agent_sdk.Types.Integer
          ~required:false
      ; structured_param
          ~name:"goal"
          ~description:"Current keeper goal, if still relevant."
          ~param_type:Agent_sdk.Types.String
          ~required:false
      ; structured_param
          ~name:"progress"
          ~description:"Short factual progress summary for this generation."
          ~param_type:Agent_sdk.Types.String
          ~required:false
      ; structured_param
          ~name:"done_summary"
          ~description:"What was completed this generation."
          ~param_type:Agent_sdk.Types.String
          ~required:false
      ; structured_param
          ~name:"next_summary"
          ~description:"What the next generation should do or inspect first."
          ~param_type:Agent_sdk.Types.String
          ~required:false
      ; structured_param
          ~name:"next_items"
          ~description:"Concrete next items as strings."
          ~param_type:Agent_sdk.Types.Array
          ~required:false
      ; structured_param
          ~name:"decisions"
          ~description:"Model-authored decisions from this generation."
          ~param_type:Agent_sdk.Types.Array
          ~required:false
      ; structured_param
          ~name:"open_questions"
          ~description:"Unresolved questions as strings."
          ~param_type:Agent_sdk.Types.Array
          ~required:false
      ; structured_param
          ~name:"constraints"
          ~description:"Active constraints as strings."
          ~param_type:Agent_sdk.Types.Array
          ~required:false
      ];
    parse =
      (fun json ->
        match structured_state_snapshot_of_json json with
        | Some snapshot -> Ok snapshot
        | None ->
            Error
              "structured keeper state is empty or does not match the snapshot \
               schema");
  }

let strip_json_markdown_fences (text : string) : string =
  let trimmed = String.trim text in
  if not (String.starts_with ~prefix:"```" trimmed) then trimmed
  else
    match String.split_on_char '\n' trimmed with
    | first :: body when String.starts_with ~prefix:"```" (String.trim first) ->
        let body =
          match List.rev body with
          | last :: rest when String.starts_with ~prefix:"```" (String.trim last) ->
              List.rev rest
          | _ -> body
        in
        String.concat "\n" body |> String.trim
    | _ -> trimmed

type structured_state_snapshot_reply_parse_error =
  | Structured_state_snapshot_reply_empty
  | Structured_state_snapshot_reply_json_parse_error of string
  | Structured_state_snapshot_reply_schema_mismatch

let structured_state_snapshot_reply_parse_error_to_string = function
  | Structured_state_snapshot_reply_empty -> "empty_reply"
  | Structured_state_snapshot_reply_json_parse_error message ->
    "json_parse_error: " ^ message
  | Structured_state_snapshot_reply_schema_mismatch -> "schema_mismatch"
;;

let parse_structured_state_snapshot_from_reply_result
    (reply : string)
    : (keeper_state_snapshot, structured_state_snapshot_reply_parse_error) result =
  let text = strip_json_markdown_fences reply in
  if String.trim text = ""
  then Error Structured_state_snapshot_reply_empty
  else (
    match Yojson.Safe.from_string text with
    | exception Yojson.Json_error message ->
      Error (Structured_state_snapshot_reply_json_parse_error message)
    | json ->
      (match structured_state_snapshot_of_json json with
       | Some snapshot -> Ok snapshot
       | None -> Error Structured_state_snapshot_reply_schema_mismatch))
;;

let parse_structured_state_snapshot_from_reply
    (reply : string) : keeper_state_snapshot option =
  match parse_structured_state_snapshot_from_reply_result reply with
  | Ok snapshot -> Some snapshot
  | Error Structured_state_snapshot_reply_empty
  | Error (Structured_state_snapshot_reply_json_parse_error _)
  | Error Structured_state_snapshot_reply_schema_mismatch ->
    None

let latest_state_snapshot_from_messages (messages : Agent_sdk.Types.message list) :
    keeper_state_snapshot option =
  let rec loop (msgs : Agent_sdk.Types.message list) =
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

let tuned_priority_for_candidate
    ~(kind : string)
    ~(text : string) : int =
  ignore text; (* Heuristics removed. Priority is now LLM-evaluated. *)
  let base = priority_for_kind ~kind in
  max 1 (min 100 base)

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
    so generation continuity is never broken. Budget exhaustion is a
    continuation checkpoint, not a model-authored decision or task
    completion, so it records only progress and next-cycle guidance. *)
let synthesize_state_from_run_result
    ~(goal : string)
    ~(tools_used : string list)
    ~(stop_reason : string)
    ~(response_text : string)
    : keeper_state_snapshot =
  let budget_exhausted = String.equal stop_reason "budget_exhausted" in
  let progress =
    match tools_used with
    | [] -> None
    | ts ->
      let unique = List.sort_uniq String.compare ts in
      Some (Printf.sprintf "Used: %s" (String.concat ", " unique))
  in
  let next_summary =
    if budget_exhausted
    then
      Some
        "Resume from the OAS checkpoint and inspect the latest assistant/tool \
         context before choosing the next action."
    else None
  in
  let decisions =
    (* The visible reply is persisted as an assistant message. Synthetic state
       must not replay an unstructured preview as a durable decision. *)
    ignore response_text;
    []
  in
  { priority = None;
    goal = (let g = String.trim goal in if g = "" then None else Some g);
    progress;
    done_summary = (if budget_exhausted then None else progress);
    next_summary;
    next_items = [];
    decisions;
    open_questions = [];
    constraints = [];
  }
