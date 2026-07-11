(** Trajectory — JSONL-based tool call trajectory logging for Keeper Harness.

    Records every tool call invocation (pre + post) to enable:
    - Deterministic replay of agent behavior
    - Cost accumulation and budget enforcement
    - Entropy detection (repeated tool calls)
    - Behavioral evaluation via eval_harness.ml

    Each keeper session produces a trajectory file at:
      .masc/trajectories/{keeper_name}/{trace_id}.jsonl

    @since 2.73.0 *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type gate_decision =
  | Pass
  | Reject of string  (** reason *)

type tool_call_entry = {
  ts : float;                       (** Unix timestamp *)
  ts_iso : string;                  (** ISO8601 string *)
  turn : int;                       (** Turn number within session *)
  round : int;                      (** Tool round within turn (1-3) *)
  tool_name : string;
  args_json : string;               (** Raw JSON string of arguments *)
  gate_decision : gate_decision;    (** Pre-execution gate result *)
  result : string option;           (** None if gated/pending, Some output *)
  duration_ms : int;                (** Wall-clock execution time *)
  error : string option;            (** Exception message if failed *)
  cost_usd : float;                 (** Estimated cost of this call *)
  execution_id : string option;
      (** RFC-0233 canonical join key minted at the dispatch boundary; the
          tool_calls JSONL row for the same execution carries the identical
          value. Plain string here: Trajectory is a dependency-leaf
          persistence record, the typed [Ids.Execution_id.t] lives at the
          mint site. *)
}

type gate_decode_summary = {
  parsed_gate_count : int;
  legacy_default_count : int;
}

type entries_read_result = {
  entries : tool_call_entry list;
  gate_decode : gate_decode_summary;
}

type trajectory_outcome =
  | Completed
  | Failed of string
  | Timeout
  | CostExceeded
  | Gated of string  (** rejected by pre-execution gate *)

type trajectory = {
  scenario_id : string option;      (** None for live runs, Some for eval *)
  keeper_name : string;
  trace_id : string;
  generation : int;
  started_at : float;
  ended_at : float;
  entries : tool_call_entry list;
  total_cost_usd : float;
  total_turns : int;
  total_tool_calls : int;
  outcome : trajectory_outcome;
  task_id : string option;
  (** Claimed task ID for cost attribution.
      Set when keeper claims a task via keeper_task_claim or masc_transition;
      None if no task claimed.
      Enables per-task cost aggregation from trajectory summaries. *)
}

(* ================================================================ *)
(* Thinking entries                                                  *)
(* ================================================================ *)

type thinking_entry = {
  ts : float;
  ts_iso : string;
  turn : int;
  content : string;
  content_length : int;
  redacted : bool;
}

type trajectory_line =
  | Tool_call of tool_call_entry
  | Thinking of thinking_entry

(* ================================================================ *)
(* Cost estimation                                                  *)
(* ================================================================ *)

(* model_token_pricing and estimate_turn_cost removed (#3029).
   Pricing belongs to OAS runtime, not MASC.
   MASC records cost_usd from OAS responses via emit_cost_event. *)

(** Rough per-call cost estimates for keeper tools.
    Most are local/free; only MODEL-calling tools have cost. *)
let tool_cost_estimate (tool_name : string) : float =
  match tool_name with
  (* MODEL-intensive tools *)
  | "keeper_board_post" -> 0.002
  | "keeper_board_comment" -> 0.001
  | "tool_execute" -> 0.0001
  | "tool_edit_file" | "tool_write_file" -> 0.0001
  (* Read-only tools are essentially free *)
  | _ -> 0.0

(* ================================================================ *)
(* JSON serialization                                               *)
(* ================================================================ *)

let gate_decision_to_json = function
  | Pass -> `Assoc [("status", `String "pass")]
  | Reject reason -> `Assoc [("status", `String "reject"); ("reason", `String reason)]

let outcome_to_json = function
  | Completed -> `String "completed"
  | Failed msg -> `Assoc [("status", `String "failed"); ("reason", `String msg)]
  | Timeout -> `String "timeout"
  | CostExceeded -> `String "cost_exceeded"
  | Gated reason -> `Assoc [("status", `String "gated"); ("reason", `String reason)]

let outcome_to_string = function
  | Completed -> "completed"
  | Failed msg -> Printf.sprintf "failed: %s" msg
  | Timeout -> "timeout"
  | CostExceeded -> "cost_exceeded"
  | Gated reason -> Printf.sprintf "gated: %s" reason

(** Default truncation limit for result text in JSONL persistence. *)
let default_result_truncation = 500

let entry_to_json ?(result_max_len = default_result_truncation)
    ?runtime_contract ?action_radius (e : tool_call_entry) : Yojson.Safe.t =
  let runtime_contract_field =
    match runtime_contract with
    | Some value -> [ ("runtime_contract", value) ]
    | None -> []
  in
  let action_radius_field =
    match action_radius with
    | Some value -> [ ("action_radius", value) ]
    | None -> []
  in
  `Assoc
    ([
       ("ts", `Float e.ts);
       ("ts_iso", `String e.ts_iso);
       ("turn", `Int e.turn);
       ("round", `Int e.round);
       ("tool_name", `String e.tool_name);
       ( "args",
         (try Yojson.Safe.from_string e.args_json with
          | Yojson.Json_error _ -> `String e.args_json) );
       ("gate", gate_decision_to_json e.gate_decision);
       ( "result",
         (match e.result with
          | None -> `Null
          | Some r ->
              if result_max_len > 0 then
                `String
                  (String_util.utf8_safe
                     ~max_bytes:(result_max_len + 3)
                     ~suffix:"..."
                     r
                   |> String_util.to_string)
              else `String r) );
       ("duration_ms", `Int e.duration_ms);
       ("error", Json_util.string_opt_to_json e.error);
       ("cost_usd", `Float e.cost_usd);
     ]
    @ (match e.execution_id with
       | Some id -> [ ("execution_id", `String id) ]
       | None -> [])
    @ runtime_contract_field @ action_radius_field)

let default_thinking_truncation = 2000

let thinking_entry_to_json ?(content_max_len = default_thinking_truncation) (e : thinking_entry) : Yojson.Safe.t =
  let content =
    if content_max_len > 0 then
      String_util.utf8_safe ~max_bytes:(content_max_len + 3) ~suffix:"..."
        e.content
      |> String_util.to_string
    else e.content
  in
  `Assoc [
    ("type", `String "thinking");
    ("ts", `Float e.ts);
    ("ts_iso", `String e.ts_iso);
    ("turn", `Int e.turn);
    ("content", `String content);
    ("content_length", `Int e.content_length);
    ("redacted", `Bool e.redacted);
  ]

let trajectory_line_to_json ?(result_max_len = default_result_truncation)
    ?(content_max_len = default_thinking_truncation) = function
  | Tool_call e -> entry_to_json ~result_max_len e
  | Thinking e -> thinking_entry_to_json ~content_max_len e

let trajectory_to_json (t : trajectory) : Yojson.Safe.t =
  `Assoc [
    ("scenario_id", Json_util.string_opt_to_json t.scenario_id);
    ("keeper_name", `String t.keeper_name);
    ("trace_id", `String t.trace_id);
    ("generation", `Int t.generation);
    ("started_at", `Float t.started_at);
    ("ended_at", `Float t.ended_at);
    ("total_cost_usd", `Float t.total_cost_usd);
    ("total_turns", `Int t.total_turns);
    ("total_tool_calls", `Int t.total_tool_calls);
    ("outcome", outcome_to_json t.outcome);
    ("task_id", Json_util.string_opt_to_json t.task_id);
    ("entries", `List (List.map entry_to_json t.entries));
  ]

(* ================================================================ *)
(* JSON deserialization                                             *)
(* ================================================================ *)
(* Decoders live next to the serializers above so both the read paths and
   the append-time affinity aggregate (below) can reuse them; they depend
   only on the [tool_call_entry] type and [Json_util], not on any file I/O
   or accumulator state. *)

let gate_decision_of_json = function
  | `Assoc fields -> (
      match List.assoc_opt "status" fields with
      | Some (`String status) -> (
          match String.lowercase_ascii status with
          | "pass" | "passed" -> (Pass, true)
          | "reject" | "rejected" | "gated" ->
              let reason =
                match List.assoc_opt "reason" fields with
                | Some (`String value) when String.trim value <> "" -> value
                | _ -> "persisted gate rejection"
              in
              (Reject reason, true)
          | _ -> (Pass, false))
      | _ -> (Pass, false))
  | _ -> (Pass, false)

let tool_call_entry_of_json (json : Yojson.Safe.t) :
    (tool_call_entry * bool) option =
  try
    match Json_util.assoc_member_opt "type" json with
    | Some (`String "trajectory_summary") -> None
    | Some (`String "thinking") -> None
    | _ ->
        let gate_decision, parsed_gate =
          gate_decision_of_json (Option.value ~default:`Null (Json_util.assoc_member_opt "gate" json))
        in
        Some
          ( {
              ts = (match Json_util.assoc_member_opt "ts" json with Some (`Float f) -> f | Some (`Int n) -> Float.of_int n | _ -> 0.0);
              ts_iso = (match Json_util.assoc_member_opt "ts_iso" json with Some (`String s) -> s | _ -> "");
              turn = (match Json_util.assoc_member_opt "turn" json with Some (`Int n) -> n | _ -> 0);
              round = (match Json_util.assoc_member_opt "round" json with Some (`Int n) -> n | _ -> 0);
              tool_name = (match Json_util.assoc_member_opt "tool_name" json with Some (`String s) -> s | _ -> "");
              args_json = Option.value ~default:`Null (Json_util.assoc_member_opt "args" json) |> Yojson.Safe.to_string;
              gate_decision;
              result =
                (match Json_util.assoc_member_opt "result" json with
                 | None | Some `Null -> None
                 | Some (`String s) -> Some s
                 | Some _ -> None);
              duration_ms = (match Json_util.assoc_member_opt "duration_ms" json with Some (`Int n) -> n | _ -> 0);
              error =
                (match Json_util.assoc_member_opt "error" json with
                 | None | Some `Null -> None
                 | Some (`String s) -> Some s
                 | Some _ -> None);
              cost_usd = (match Json_util.assoc_member_opt "cost_usd" json with Some (`Float f) -> f | Some (`Int n) -> Float.of_int n | _ -> 0.0);
              execution_id =
                (match Json_util.assoc_member_opt "execution_id" json with
                 | Some (`String s) -> Some s
                 | _ -> None);
            },
            parsed_gate )
  with
  | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None

(** Single definition of "this tool call counts as a failure" so the
    dashboard aggregation ([aggregate_tool_stats]) and the append-time
    affinity aggregate classify identically and cannot drift apart. *)
let entry_is_failure (e : tool_call_entry) : bool =
  Option.is_some e.error
  || (match e.gate_decision with Reject _ -> true | Pass -> false)

(* ================================================================ *)
(* File I/O                                                         *)
(* ================================================================ *)

let trajectories_dir (masc_root : string) (keeper_name : string) : string =
  Filename.concat masc_root (Printf.sprintf "trajectories/%s" keeper_name)

let trajectory_path (masc_root : string) (keeper_name : string) (trace_id : string) : string =
  Filename.concat (trajectories_dir masc_root keeper_name)
    (Printf.sprintf "%s.jsonl" trace_id)

(* RFC-0108: the inline per-path Stdlib.Mutex + fresh-fd helper
   (PR-4 #15926) is removed here. [Fs_compat.append_jsonl] (post-RFC-0108
   #15936) now provides the equivalent per-path cross-domain guarantee
   via its own registry, so the trajectory-local copy is redundant.
   Calls below delegate directly. *)

(* ── In-memory round counter ──────────────────────────────────────
   Replaces the read-all-entries-just-to-count-round pattern.
   Key: (keeper_name, trace_id, turn) -> count of tool calls in that turn.
   Hydrated lazily on first access per key. *)

let round_counters : (string * string * int, int) Hashtbl.t = Hashtbl.create 64
let round_high_water : (string * string * int, int) Hashtbl.t = Hashtbl.create 64
let round_counters_mu = Stdlib.Mutex.create ()

(* Initial tail window (in lines) read to hydrate a turn's round count from
   disk. A single turn's tool-call count is far below this bound, so one
   tail read normally captures the whole turn plus the previous-turn boundary.
   Chosen well above realistic per-turn tool-call counts to avoid widening. *)
let default_hydrate_tail_lines = 512

(* Upper bound on the tail window before falling back to a full-file scan.
   Doubling from [default_hydrate_tail_lines] yields 512→1024→2048→4096→8192.
   Beyond this a turn is assumed pathological and a full scan is used so the
   count is never silently truncated. *)
let max_hydrate_tail_lines = 8192

(** Extract the [turn] field from a trajectory JSONL line.  Returns [None] for
    non-entry rows, malformed [turn] fields, and invalid JSON.  Such lines are
    skipped rather than counted or treated as turn-boundaries. *)
let entry_turn_of_line ~(trace_id : string) (line : string) : int option =
  match Yojson.Safe.from_string line with
  | json -> (
      match Json_util.assoc_member_opt "turn" json with
      | Some (`Int n) -> Some n
      | None -> None
      | Some other ->
          Log.Keeper.warn
            "Skipping trajectory line with non-int turn during next_round \
             (trace_id=%s, turn_kind=%s)"
            trace_id (Yojson.Safe.to_string other);
          None)
  | exception Yojson.Json_error msg ->
      Log.Keeper.warn
        "Failed to parse trajectory JSON during next_round (trace_id=%s): %s"
        trace_id msg;
      None
  | exception exn ->
      Log.Keeper.warn
        "Unexpected error reading trajectory line (trace_id=%s): %s" trace_id
        (Printexc.to_string exn);
      None

(** Count entries whose [turn = target_turn] within a tail [window] by scanning
    newest→oldest, stopping at the first line strictly older than [target_turn].
    turn is monotonically non-decreasing in append-only file order, so once a
    line with [entry_turn < target_turn] is seen every earlier line is a past
    turn and the scan stops.

    Returns [(count, boundary_found)]. [boundary_found] is true only when a
    strictly-older line was seen, i.e. the window definitely contained the turn
    boundary and [count] is complete. When false, the window may have been
    truncated before the boundary and the caller must widen it or fall back. *)
let count_current_turn_backward ~(trace_id : string) ~(target_turn : int)
    (window : string list) : int * bool =
  (* [window] is oldest-first (load_tail_lines order); reverse to scan the
     newest line first so we can stop as soon as the boundary appears. *)
  let rec scan count = function
    | [] -> (count, false)
    | line :: older -> (
        match entry_turn_of_line ~trace_id line with
        | None -> scan count older (* unparseable: warn+skip, not a boundary *)
        | Some entry_turn ->
            if entry_turn = target_turn then scan (count + 1) older
            else if entry_turn < target_turn then (count, true) (* boundary *)
            else (
              (* entry_turn > target_turn cannot occur under monotonic turn:
                 future turns are appended after, not before, the current turn.
                 Exclude it from the count but keep scanning (do not treat it as
                 a boundary) so an upstream anomaly cannot silently truncate. *)
              Log.Keeper.warn
                "next_round saw future turn %d > %d in trajectory tail \
                 (trace_id=%s); excluding from round count"
                entry_turn target_turn trace_id;
              scan count older))
  in
  scan 0 (List.rev window)

(** Full-file scan fallback: count entries whose [turn = target_turn] across the
    whole trajectory file. Restores the pre-tail-read O(file) cost, used only
    when a turn exceeds [max_hydrate_tail_lines] tool calls. *)
let full_scan_round_count ~(path : string) ~(trace_id : string)
    ~(target_turn : int) : int =
  Fs_compat.load_file path
  |> String.split_on_char '\n'
  |> List.filter (fun line -> String.trim line <> "")
  |> List.fold_left
       (fun acc line ->
         match entry_turn_of_line ~trace_id line with
         | Some n when n = target_turn -> acc + 1
         | _ -> acc)
       0

(** Count existing entries for [turn] by reading a bounded tail of the file
    instead of the whole file. Widens the window (doubling) if the boundary is
    not reached, and only falls back to a full scan past [max_hydrate_tail_lines]
    so the count is exact for every turn size. *)
let hydrate_round_count ~(masc_root : string) ~(keeper_name : string)
    ~(trace_id : string) ~(turn : int) : int =
  let path = trajectory_path masc_root keeper_name trace_id in
  if not (Sys.file_exists path) then 0
  else
    let rec attempt max_lines =
      let window = Dated_jsonl.load_tail_lines path ~max_lines in
      let n = List.length window in
      let count, boundary_found =
        count_current_turn_backward ~trace_id ~target_turn:turn window
      in
      if boundary_found || n < max_lines then
        (* boundary_found: the previous-turn marker was inside the window.
           n < max_lines: load_tail_lines returned fewer lines than requested,
           so the window already spans the whole file — trajectory JSONL is
           append-only with one record per line and no interior blank lines —
           and [count] is complete even without an explicit boundary (e.g. the
           first turn, whose entries reach the top of the file). *)
        count
      else if max_lines >= max_hydrate_tail_lines then (
        (* Window filled to the cap without reaching the boundary. Fall back to
           a full scan rather than risk under-counting a pathologically large
           turn. This restores the pre-optimization cost for that rare case
           only, and never silently truncates. *)
        Log.Keeper.warn
          "next_round tail window exhausted at %d lines without turn boundary \
           (trace_id=%s, turn=%d); falling back to full scan"
          max_lines trace_id turn;
        full_scan_round_count ~path ~trace_id ~target_turn:turn)
      else attempt (max_lines * 2)
    in
    attempt default_hydrate_tail_lines

(** Evict cache entries for turns older than [turn] under the same
    (keeper_name, trace_id). Round counts for a past turn are never queried
    again in the normal monotonic path, so retaining the active hydrated
    counter would grow the table without bound over a long session. Issued
    high-water marks are intentionally retained separately; if a late
    out-of-order caller asks for an older turn, [next_round] must not hand out
    a duplicate round number already returned by this process. Caller must
    hold [round_counters_mu]. *)
let evict_past_turn_keys ~(keeper_name : string) ~(trace_id : string)
    ~(turn : int) : unit =
  let stale =
    Hashtbl.fold
      (fun ((k, t, kt) as key) _ acc ->
        if String.equal k keeper_name && String.equal t trace_id && kt < turn
        then key :: acc
        else acc)
      round_counters []
  in
  List.iter (Hashtbl.remove round_counters) stale

(** Get the next round number for a given (keeper_name, trace_id, turn).
    Lazily hydrates from disk on first access, then increments in-memory.
    This avoids reading the entire JSONL file on every tool call. *)
let next_round ~(masc_root : string) ~(keeper_name : string) ~(trace_id : string) ~(turn : int) : int =
  let key = (keeper_name, trace_id, turn) in
  Stdlib.Mutex.protect round_counters_mu (fun () ->
    let current =
      match Hashtbl.find_opt round_counters key with
      | Some n -> n
      | None ->
        let hydrated =
          hydrate_round_count ~masc_root ~keeper_name ~trace_id ~turn
        in
        let issued =
          match Hashtbl.find_opt round_high_water key with
          | Some n -> n
          | None -> 0
        in
        max hydrated issued
    in
    let next = current + 1 in
    Hashtbl.replace round_counters key next;
    Hashtbl.replace round_high_water key next;
    evict_past_turn_keys ~keeper_name ~trace_id ~turn;
    next)

(** Reset round counters for testing. *)
let reset_round_counters_for_testing () =
  Stdlib.Mutex.protect round_counters_mu (fun () ->
    Hashtbl.reset round_counters;
    Hashtbl.reset round_high_water)

(** Append a thinking block entry to the JSONL trajectory file. *)
let append_thinking ~(masc_root : string) ~(keeper_name : string) ~(trace_id : string)
    (entry : thinking_entry) : unit =
  let dir = trajectories_dir masc_root keeper_name in
  Fs_compat.mkdir_p dir;
  let path = trajectory_path masc_root keeper_name trace_id in
  (* 남김없이: the thinking trajectory is the eval/audit SSOT, so persist the
     FULL untruncated reasoning text. Truncation is a read/display concern
     ([content_max_len] query param on the trajectory endpoint), never a
     write-time one — truncating here destroyed reasoning before it was ever
     stored. [content_length] still records the true length either way. *)
  let json = thinking_entry_to_json ~content_max_len:0 entry in
  Fs_compat.append_jsonl path json

(** Write a trajectory summary line (appended after session ends). *)
let append_summary ~(masc_root : string) ~(keeper_name : string) ~(trace_id : string)
    (traj : trajectory) : unit =
  let dir = trajectories_dir masc_root keeper_name in
  Fs_compat.mkdir_p dir;
  let path = trajectory_path masc_root keeper_name trace_id in
  let summary = `Assoc [
    ("type", `String "trajectory_summary");
    ("keeper_name", `String traj.keeper_name);
    ("trace_id", `String traj.trace_id);
    ("generation", `Int traj.generation);
    ("total_cost_usd", `Float traj.total_cost_usd);
    ("total_turns", `Int traj.total_turns);
    ("total_tool_calls", `Int traj.total_tool_calls);
    ("outcome", outcome_to_json traj.outcome);
    ("task_id", Json_util.string_opt_to_json traj.task_id);
    ("started_at", `Float traj.started_at);
    ("ended_at", `Float traj.ended_at);
  ] in
  Fs_compat.append_jsonl path summary

(* ================================================================ *)
(* Tool-affinity aggregate (append-time, per-keeper)                 *)
(* ================================================================ *)
(* Keeper_tool_affinity.pre_populate_from_history used to rescan every
   .jsonl trace file for a keeper on every turn's tool setup (up to GBs of
   history parsed per turn on the main Eio domain — the "server freeze" P0).
   This section materializes the counts that scan produced at APPEND time
   instead: a small per-keeper snapshot file that is updated incrementally
   on flush and read cheaply at setup. Only tool_name/call_count/
   success_count/last_used timestamp are tracked — the exact inputs
   [Keeper_tool_affinity.compute_affinity] scores on.

   Windowing: counts are bucketed by UTC day so the affinity read can still
   honour its rolling lookback window (default 7d, capped 30d). A pure
   lifetime total would keep pre-populating tools unused for weeks; day
   buckets preserve the windowed semantics. The one deviation from the old
   per-second [ts >= since] cutoff is that the boundary day is included
   whole — entries in the partial [since] day are counted even if their
   timestamp is just before [since]. Buckets fully inside/outside the
   window match the old scan exactly. *)

(* Seconds per UTC day for day-bucketing. Mirrors [Masc_time_constants.day]
   (workspace SSOT for 86400.0); kept local so [Trajectory] stays the
   dependency leaf its dune stanza documents, rather than pulling in
   masc.config for one conversion factor. *)
let seconds_per_day = 86_400.

(* Bucket retention horizon. Must be >= the largest lookback window
   Keeper_tool_affinity can request (its LOOKBACK_DAYS env clamps at 30);
   the extra day keeps the window's boundary day present despite sub-day
   read/prune skew. Lowering this below that cap would silently drop
   buckets a windowed read still needs. *)
let affinity_aggregate_retention_days = 31

let aggregate_schema_version = 1

(* Snapshot lives in the keeper trajectory dir but must never be picked up
   by the .jsonl trace scanners (read_entries_since / telemetry_unified);
   the ".json" (not ".jsonl") suffix keeps it out of every [check_suffix
   ".jsonl"] filter. *)
let aggregate_snapshot_basename = "_tool_affinity_aggregate.v1.json"

type tool_day_bucket = {
  bucket_day : int;              (** [floor(ts / seconds_per_day)], UTC day index. *)
  bucket_call_count : int;
  bucket_success_count : int;
  bucket_last_ts : float;        (** max [ts] observed in this (tool, day). *)
  bucket_last_iso : string;      (** [ts_iso] paired with [bucket_last_ts]. *)
}

type tool_affinity_bucket_series = {
  series_tool_name : string;
  series_buckets : tool_day_bucket list;
}

type tool_affinity_aggregate = {
  aggregate_version : int;
  aggregate_keeper_name : string;
  aggregate_updated_at : float;
  aggregate_tools : tool_affinity_bucket_series list;
}

type aggregate_load_error =
  | Aggregate_missing            (** No snapshot file yet. *)
  | Aggregate_unreadable of string  (** File exists but I/O failed. *)
  | Aggregate_corrupt of string     (** File read but JSON/schema invalid. *)

let day_index_of_ts (ts : float) : int =
  int_of_float (Float.floor (ts /. seconds_per_day))

let aggregate_snapshot_path (masc_root : string) (keeper_name : string) : string =
  Filename.concat (trajectories_dir masc_root keeper_name) aggregate_snapshot_basename

(* ── Serialization ── *)

let tool_day_bucket_to_json (b : tool_day_bucket) : Yojson.Safe.t =
  `Assoc [
    ("day", `Int b.bucket_day);
    ("count", `Int b.bucket_call_count);
    ("success", `Int b.bucket_success_count);
    ("last_ts", `Float b.bucket_last_ts);
    ("last_iso", `String b.bucket_last_iso);
  ]

let tool_affinity_aggregate_to_json (a : tool_affinity_aggregate) : Yojson.Safe.t =
  `Assoc [
    ("version", `Int a.aggregate_version);
    ("keeper_name", `String a.aggregate_keeper_name);
    ("updated_at", `Float a.aggregate_updated_at);
    ( "tools",
      `List
        (List.map
           (fun (s : tool_affinity_bucket_series) ->
             `Assoc
               [ ("name", `String s.series_tool_name);
                 ("buckets", `List (List.map tool_day_bucket_to_json s.series_buckets)) ])
           a.aggregate_tools) );
  ]

(* Strict decoders: a malformed bucket/series fails the whole snapshot
   (returns None) rather than silently dropping rows. A None surfaces as
   [Aggregate_corrupt] and triggers a full-scan rebuild, so partial data is
   never trusted. (Parse, don't validate.) *)
let tool_day_bucket_of_json (json : Yojson.Safe.t) : tool_day_bucket option =
  match json with
  | `Assoc _ -> (
      match
        ( Json_util.assoc_member_opt "day" json,
          Json_util.assoc_member_opt "count" json,
          Json_util.assoc_member_opt "success" json,
          Json_util.assoc_member_opt "last_ts" json,
          Json_util.assoc_member_opt "last_iso" json )
      with
      | ( Some (`Int day),
          Some (`Int count),
          Some (`Int success),
          Some last_ts_json,
          Some (`String last_iso) ) ->
          let last_ts =
            match last_ts_json with
            | `Float f -> Some f
            | `Int n -> Some (Float.of_int n)
            | _ -> None
          in
          Option.map
            (fun bucket_last_ts ->
              { bucket_day = day; bucket_call_count = count;
                bucket_success_count = success; bucket_last_ts;
                bucket_last_iso = last_iso })
            last_ts
      | _ -> None)
  | _ -> None

let tool_affinity_bucket_series_of_json (json : Yojson.Safe.t) :
    tool_affinity_bucket_series option =
  match json with
  | `Assoc _ -> (
      match
        ( Json_util.assoc_member_opt "name" json,
          Json_util.assoc_member_opt "buckets" json )
      with
      | Some (`String name), Some (`List bucket_jsons) ->
          let buckets = List.map tool_day_bucket_of_json bucket_jsons in
          if List.exists Option.is_none buckets then None
          else
            Some
              { series_tool_name = name;
                series_buckets = List.filter_map Fun.id buckets }
      | _ -> None)
  | _ -> None

let tool_affinity_aggregate_of_json (json : Yojson.Safe.t) :
    tool_affinity_aggregate option =
  match json with
  | `Assoc _ -> (
      match
        ( Json_util.assoc_member_opt "version" json,
          Json_util.assoc_member_opt "keeper_name" json,
          Json_util.assoc_member_opt "updated_at" json,
          Json_util.assoc_member_opt "tools" json )
      with
      | ( Some (`Int version),
          Some (`String keeper_name),
          Some updated_at_json,
          Some (`List tool_jsons) )
        when version = aggregate_schema_version ->
          let updated_at =
            match updated_at_json with
            | `Float f -> Some f
            | `Int n -> Some (Float.of_int n)
            | _ -> None
          in
          let tools = List.map tool_affinity_bucket_series_of_json tool_jsons in
          if List.exists Option.is_none tools then None
          else
            (match updated_at with
            | None -> None
            | Some aggregate_updated_at ->
              Some
                { aggregate_version = version;
                  aggregate_keeper_name = keeper_name;
                  aggregate_updated_at;
                  aggregate_tools = List.filter_map Fun.id tools })
      | _ -> None)
  | _ -> None

(* ── Snapshot persistence ── *)

let read_aggregate_snapshot ~(masc_root : string) ~(keeper_name : string) :
    (tool_affinity_aggregate, aggregate_load_error) result =
  let path = aggregate_snapshot_path masc_root keeper_name in
  match
    (try `Loaded (Fs_compat.load_file_opt path)
     with Sys_error msg -> `Io msg)
  with
  | `Io msg -> Error (Aggregate_unreadable msg)
  | `Loaded None -> Error Aggregate_missing
  | `Loaded (Some content) -> (
      match
        (try Some (Yojson.Safe.from_string content)
         with Yojson.Json_error _ -> None)
      with
      | None -> Error (Aggregate_corrupt "invalid json")
      | Some json -> (
          match tool_affinity_aggregate_of_json json with
          | Some agg when String.equal agg.aggregate_keeper_name keeper_name -> Ok agg
          | Some agg ->
            Error
              (Aggregate_corrupt
                 (Printf.sprintf
                    "keeper_name mismatch: snapshot=%S requested=%S"
                    agg.aggregate_keeper_name keeper_name))
          | None -> Error (Aggregate_corrupt "schema mismatch")))

let persist_aggregate_snapshot ~(masc_root : string) ~(keeper_name : string)
    (agg : tool_affinity_aggregate) : (unit, string) result =
  let dir = trajectories_dir masc_root keeper_name in
  Fs_compat.mkdir_p dir;
  let path = aggregate_snapshot_path masc_root keeper_name in
  let report =
    Fs_compat.save_file_atomic_eio path
      (Yojson.Safe.to_string (tool_affinity_aggregate_to_json agg))
  in
  Fs_compat.Durable_mutation.fold_report report
    ~not_committed:(fun report ->
      Error (Fs_compat.Durable_mutation.report_to_string report))
    ~committed_not_durable:(fun report ->
      Log.Misc.warn
        "trajectory aggregate committed with sync debt path=%s detail=%s"
        path
        (Fs_compat.Durable_mutation.report_to_string report);
      Ok ())
    ~durable:(fun report ->
      (match report.diagnostics with
       | [] -> ()
       | _ ->
         Log.Misc.warn
           "trajectory aggregate durable with cleanup diagnostics path=%s detail=%s"
           path
           (Fs_compat.Durable_mutation.report_to_string report));
      Ok ())

(* ── In-memory aggregation ── *)

let empty_tool_affinity_aggregate (keeper_name : string) : tool_affinity_aggregate =
  { aggregate_version = aggregate_schema_version;
    aggregate_keeper_name = keeper_name;
    aggregate_updated_at = 0.0;
    aggregate_tools = [] }

let fold_entry_into_aggregate (agg : tool_affinity_aggregate)
    (e : tool_call_entry) : tool_affinity_aggregate =
  let day = day_index_of_ts e.ts in
  let is_fail = entry_is_failure e in
  let success_delta = if is_fail then 0 else 1 in
  let new_bucket () =
    { bucket_day = day; bucket_call_count = 1;
      bucket_success_count = success_delta;
      bucket_last_ts = e.ts; bucket_last_iso = e.ts_iso }
  in
  let inc_bucket (b : tool_day_bucket) =
    let last_ts, last_iso =
      if e.ts > b.bucket_last_ts then (e.ts, e.ts_iso)
      else (b.bucket_last_ts, b.bucket_last_iso)
    in
    { b with
      bucket_call_count = b.bucket_call_count + 1;
      bucket_success_count = b.bucket_success_count + success_delta;
      bucket_last_ts = last_ts;
      bucket_last_iso = last_iso }
  in
  let update_series (s : tool_affinity_bucket_series) =
    let matched = ref false in
    let buckets =
      List.map
        (fun (b : tool_day_bucket) ->
          if b.bucket_day = day then (matched := true; inc_bucket b) else b)
        s.series_buckets
    in
    let buckets = if !matched then buckets else new_bucket () :: buckets in
    { s with series_buckets = buckets }
  in
  let matched_tool = ref false in
  let tools =
    List.map
      (fun (s : tool_affinity_bucket_series) ->
        if s.series_tool_name = e.tool_name then (matched_tool := true; update_series s)
        else s)
      agg.aggregate_tools
  in
  let tools =
    if !matched_tool then tools
    else { series_tool_name = e.tool_name; series_buckets = [ new_bucket () ] } :: tools
  in
  { agg with aggregate_tools = tools }

let prune_aggregate ~(now : float) (agg : tool_affinity_aggregate) :
    tool_affinity_aggregate =
  let cutoff_day =
    day_index_of_ts
      (now -. (float_of_int affinity_aggregate_retention_days *. seconds_per_day))
  in
  let tools =
    List.filter_map
      (fun (s : tool_affinity_bucket_series) ->
        match
          List.filter (fun (b : tool_day_bucket) -> b.bucket_day >= cutoff_day) s.series_buckets
        with
        | [] -> None
        | kept -> Some { s with series_buckets = kept })
      agg.aggregate_tools
  in
  { agg with aggregate_tools = tools; aggregate_updated_at = now }

let merge_entries_into_aggregate ~(now : float) (agg : tool_affinity_aggregate)
    (entries : tool_call_entry list) : tool_affinity_aggregate =
  List.fold_left fold_entry_into_aggregate agg entries |> prune_aggregate ~now

let build_tool_affinity_aggregate ~(keeper_name : string) ~(now : float)
    (entries : tool_call_entry list) : tool_affinity_aggregate =
  merge_entries_into_aggregate ~now (empty_tool_affinity_aggregate keeper_name) entries

(* Serializes snapshot read-modify-write for one keeper. Snapshot files are
   per-keeper derived caches; a slow file operation for one keeper must not
   block aggregate updates for unrelated keepers. *)
let aggregate_snapshot_guards :
    (string * string, Stdlib.Mutex.t) Hashtbl.t =
  Hashtbl.create 32

let aggregate_snapshot_guards_mu = Stdlib.Mutex.create ()

let aggregate_snapshot_guard ~(masc_root : string) ~(keeper_name : string) :
    Stdlib.Mutex.t =
  Stdlib.Mutex.protect aggregate_snapshot_guards_mu (fun () ->
    let key = (masc_root, keeper_name) in
    match Hashtbl.find_opt aggregate_snapshot_guards key with
    | Some mu -> mu
    | None ->
      let mu = Stdlib.Mutex.create () in
      Hashtbl.add aggregate_snapshot_guards key mu;
      mu)

let with_aggregate_snapshot_guard ~(masc_root : string) ~(keeper_name : string)
    (f : unit -> 'a) : 'a =
  Stdlib.Mutex.protect (aggregate_snapshot_guard ~masc_root ~keeper_name) f

(* A cold/corrupt snapshot rebuild scans JSONL and then seeds the aggregate.
   Same-keeper JSONL writes must not interleave with that scan: otherwise a
   just-persisted entry can be missed by the scan and then no-op while the
   snapshot is still missing, or be scanned and incremented again. This guard
   wraps the append/flush write plus aggregate update for that keeper. *)
let aggregate_rebuild_guards :
    (string * string, Stdlib.Mutex.t) Hashtbl.t =
  Hashtbl.create 32

let aggregate_rebuild_guards_mu = Stdlib.Mutex.create ()

let aggregate_rebuild_guard ~(masc_root : string) ~(keeper_name : string) :
    Stdlib.Mutex.t =
  Stdlib.Mutex.protect aggregate_rebuild_guards_mu (fun () ->
    let key = (masc_root, keeper_name) in
    match Hashtbl.find_opt aggregate_rebuild_guards key with
    | Some mu -> mu
    | None ->
      let mu = Stdlib.Mutex.create () in
      Hashtbl.add aggregate_rebuild_guards key mu;
      mu)

let with_aggregate_rebuild_guard ~(masc_root : string) ~(keeper_name : string)
    (f : unit -> 'a) : 'a =
  Stdlib.Mutex.protect (aggregate_rebuild_guard ~masc_root ~keeper_name) f

let update_aggregate_from_entries ~(masc_root : string) ~(keeper_name : string)
    (entries : tool_call_entry list) : unit =
  match entries with
  | [] -> ()
  | _ ->
    with_aggregate_snapshot_guard ~masc_root ~keeper_name (fun () ->
      match read_aggregate_snapshot ~masc_root ~keeper_name with
      | Error Aggregate_missing ->
        (* No seeded snapshot yet. Seeding is done by the affinity read
           path's one-time full-scan rebuild, which produces a COMPLETE
           snapshot from on-disk history. Creating one from only this flush
           batch would be a partial the read path would then trust without
           rebuilding. Skip — the entries are already durable in JSONL and
           will be picked up by that rebuild. *)
        ()
      | Error (Aggregate_corrupt reason | Aggregate_unreadable reason) ->
        (* Do not overwrite a broken snapshot with a partial. Leave it so
           pre_populate_from_history's rebuild reseeds from disk. *)
        Log.Keeper.warn
          "trajectory: tool-affinity aggregate for %s not incremented (%s); \
           awaiting rebuild by pre_populate_from_history"
          keeper_name reason
      | Ok agg ->
        let now = Time_compat.now () in
        let updated = merge_entries_into_aggregate ~now agg entries in
        (match persist_aggregate_snapshot ~masc_root ~keeper_name updated with
         | Ok () -> ()
         | Error msg ->
           Log.Keeper.warn
             "trajectory: failed to persist tool-affinity aggregate for %s: %s"
             keeper_name msg))

let append_entry ?runtime_contract ?action_radius ~(masc_root : string)
    ~(keeper_name : string) ~(trace_id : string) (entry : tool_call_entry) :
    unit =
  with_aggregate_rebuild_guard ~masc_root ~keeper_name (fun () ->
    let dir = trajectories_dir masc_root keeper_name in
    Fs_compat.mkdir_p dir;
    let path = trajectory_path masc_root keeper_name trace_id in
    let json = entry_to_json ?runtime_contract ?action_radius entry in
    Fs_compat.append_jsonl path json;
    update_aggregate_from_entries ~masc_root ~keeper_name [ entry ])

(* ================================================================ *)
(* Trajectory accumulator (mutable, per-session)                    *)
(* ================================================================ *)

type pending_entry = {
  pe_json : Yojson.Safe.t;
}

type accumulator = {
  mutable entries : tool_call_entry list;
  mutable total_cost : float;
  mutable total_calls : int;
  mutable turn : int;
  keeper_name : string;
  trace_id : string;
  generation : int;
  started_at : float;
  masc_root : string;
  mutable task_id : string option;
  (** Claimed task ID for cost attribution.
      Starts as None; set via [set_task_id] when keeper claims a task.
      Propagated to trajectory record on [finalize]. *)
  pending_queue : pending_entry Queue.t;
  pending_mu : Stdlib.Mutex.t;
  mutable last_flush : float;
  mutable on_flush_error : (exn -> unit) option;
}

(* Global registry of active accumulators for batch flush.
   The background flush fiber iterates this to drain pending queues. *)
let active_accumulators : (string * string, accumulator) Hashtbl.t = Hashtbl.create 16
let active_acc_mu = Stdlib.Mutex.create ()

let register_accumulator (acc : accumulator) =
  Stdlib.Mutex.protect active_acc_mu (fun () ->
    Hashtbl.replace active_accumulators (acc.keeper_name, acc.trace_id) acc)

let unregister_accumulator (acc : accumulator) =
  Stdlib.Mutex.protect active_acc_mu (fun () ->
    Hashtbl.remove active_accumulators (acc.keeper_name, acc.trace_id))

let create_accumulator ?on_flush_error ~masc_root ~keeper_name ~trace_id ~generation () : accumulator =
  let acc = {
    entries = [];
    total_cost = 0.0;
    total_calls = 0;
    turn = 0;
    keeper_name;
    trace_id;
    generation;
    started_at = Time_compat.now ();
    masc_root;
    task_id = None;
    pending_queue = Queue.create ();
    pending_mu = Stdlib.Mutex.create ();
    last_flush = 0.0;
    on_flush_error;
  } in
  register_accumulator acc;
  acc

(** Bind a claimed task to this trajectory for cost attribution. *)
let set_task_id (acc : accumulator) (id : string) : unit =
  acc.task_id <- Some id

(** Clear task binding (e.g., after masc_transition action=done). *)
let clear_task_id (acc : accumulator) : unit =
  acc.task_id <- None

let increment_turn (acc : accumulator) : unit =
  acc.turn <- acc.turn + 1

let record_entry ?runtime_contract ?action_radius ?on_persist_error
    (acc : accumulator) (entry : tool_call_entry) : unit =
  acc.entries <- entry :: acc.entries;
  acc.total_cost <- acc.total_cost +. entry.cost_usd;
  acc.total_calls <- acc.total_calls + 1;
  (* Store on_persist_error for use during batch flush *)
  (match on_persist_error, acc.on_flush_error with
   | Some cb, None -> acc.on_flush_error <- Some cb
   | _ -> ());
  (* Enqueue for batched write instead of synchronous disk I/O *)
  let json = entry_to_json ?runtime_contract ?action_radius entry in
  Stdlib.Mutex.protect acc.pending_mu (fun () ->
    Queue.push { pe_json = json } acc.pending_queue)

(** Drain the pending queue and write all entries in a single batch.
    Acquires the per-accumulator mutex to safely drain the queue. *)
let flush_pending (acc : accumulator) : unit =
  let entries_to_flush =
    Stdlib.Mutex.protect acc.pending_mu (fun () ->
      if Queue.is_empty acc.pending_queue then []
      else
        let items = Queue.fold (fun acc pe -> pe :: acc) [] acc.pending_queue in
        Queue.clear acc.pending_queue;
        List.rev items)
  in
  match entries_to_flush with
  | [] -> ()
  | _ ->
    (try
       with_aggregate_rebuild_guard
         ~masc_root:acc.masc_root
         ~keeper_name:acc.keeper_name
         (fun () ->
           let dir = trajectories_dir acc.masc_root acc.keeper_name in
           Fs_compat.mkdir_p dir;
           let path = trajectory_path acc.masc_root acc.keeper_name acc.trace_id in
           let jsons = List.map (fun pe -> pe.pe_json) entries_to_flush in
           Fs_compat.append_jsonl_batch path jsons;
           acc.last_flush <- Time_compat.now ();
           (* Fold the just-persisted batch into the per-keeper tool-affinity
              aggregate so Keeper_tool_affinity reads it instead of rescanning
              the full trajectory (the P0 freeze). Gated on the JSONL write
              succeeding; the aggregate is a rebuildable derived cache, so the
              update is best-effort — [update_aggregate_from_entries] never
              raises and only increments an already-seeded snapshot. *)
           let flushed_entries =
             List.filter_map
               (fun pe ->
                 match tool_call_entry_of_json pe.pe_json with
                 | Some (entry, _parsed_gate) -> Some entry
                 | None -> None)
               entries_to_flush
           in
           update_aggregate_from_entries
             ~masc_root:acc.masc_root
             ~keeper_name:acc.keeper_name
             flushed_entries)
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.error "Failed to flush trajectory batch for %s: %s"
         acc.trace_id (Printexc.to_string exn);
       (match acc.on_flush_error with
        | None -> ()
        | Some report ->
            try report exn
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | report_exn ->
                Log.Keeper.warn
                  "Failed to report trajectory flush error for %s: %s"
                  acc.trace_id
                  (Printexc.to_string report_exn)))

(** Flush pending entries for all active accumulators.
    Called by the background flush fiber in server_runtime_bootstrap. *)
let flush_all_pending () : unit =
  let accs = Stdlib.Mutex.protect active_acc_mu (fun () ->
    Hashtbl.fold (fun _ acc accs -> acc :: accs) active_accumulators []) in
  List.iter flush_pending accs

let finalize (acc : accumulator) (outcome : trajectory_outcome) : trajectory =
  (* Flush any remaining pending entries before writing summary *)
  flush_pending acc;
  unregister_accumulator acc;
  let traj = {
    scenario_id = None;
    keeper_name = acc.keeper_name;
    trace_id = acc.trace_id;
    generation = acc.generation;
    started_at = acc.started_at;
    ended_at = Time_compat.now ();
    entries = List.rev acc.entries;
    total_cost_usd = acc.total_cost;
    total_turns = acc.turn;
    total_tool_calls = acc.total_calls;
    outcome;
    task_id = acc.task_id;
  } in
  (try append_summary ~masc_root:acc.masc_root ~keeper_name:acc.keeper_name
       ~trace_id:acc.trace_id traj
   with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Keeper.error "Failed to persist summary for %s: %s" acc.trace_id (Printexc.to_string exn));
  traj

(* ================================================================ *)
(* Entropy detection                                                *)
(* ================================================================ *)

(** Detect whether the current candidate call would make a consecutive streak of
    calls to [tool_name] reach or exceed [threshold]. The count includes the
    candidate call being checked, so rejection can occur before executing the
    threshold-th call.
    If [args_json] is provided, only consecutive calls with the same tool name
    and the same raw [args_json] string are counted; this is string equality,
    not semantic JSON equality. *)
let detect_entropy ?(threshold = 3) ?args_json (acc : accumulator) (tool_name : string) : (string * int) option =
  let recent =
    acc.entries
    |> List.to_seq
    |> Seq.take_while (fun e ->
         e.tool_name = tool_name &&
         match args_json with
         | Some args -> e.args_json = args
         | None -> true)
    |> List.of_seq
  in
  let count = List.length recent + 1 in  (* +1 for the upcoming call *)
  if count >= threshold then Some (tool_name, count)
  else None

(** Count tool calls in current turn. *)
let calls_in_current_turn (acc : accumulator) : int =
  List_util.count_if (fun (e : tool_call_entry) -> e.turn = acc.turn) acc.entries

(* ================================================================ *)
(* Tool stats aggregation                                          *)
(* ================================================================ *)

type tool_stat = {
  name : string;
  call_count : int;
  success_count : int;
  failure_count : int;
  avg_duration_ms : int;
  p95_duration_ms : int;
  max_duration_ms : int;
  total_cost_usd : float;
  last_used_at : string;
}

type hourly_bucket = {
  hour : string;
  call_count : int;
  error_count : int;
}

(** Compute p95 from a sorted int array. *)
let p95_of_sorted (durations : int array) : int =
  let n = Array.length durations in
  if n = 0 then 0
  else
    let idx = min (n - 1) (int_of_float (Float.round (float_of_int n *. 0.95))) in
    durations.(idx)

let aggregate_tool_stats (entries : tool_call_entry list) : tool_stat list =
  let tbl : (string, int list * int * int * float * float * string) Hashtbl.t =
    Hashtbl.create 32
  in
  List.iter (fun (e : tool_call_entry) ->
    let is_failure = entry_is_failure e in
    match Hashtbl.find_opt tbl e.tool_name with
    | None ->
      let succ = if is_failure then 0 else 1 in
      let fail = if is_failure then 1 else 0 in
      Hashtbl.replace tbl e.tool_name
        ([e.duration_ms], succ, fail, e.cost_usd, e.ts, e.ts_iso)
    | Some (durations, succ, fail, cost, max_ts, max_iso) ->
      let succ' = if is_failure then succ else succ + 1 in
      let fail' = if is_failure then fail + 1 else fail in
      let (ts', iso') = if e.ts > max_ts then (e.ts, e.ts_iso) else (max_ts, max_iso) in
      Hashtbl.replace tbl e.tool_name
        (e.duration_ms :: durations, succ', fail', cost +. e.cost_usd, ts', iso')
  ) entries;
  let stats = Hashtbl.fold (fun name (durations, succ, fail, cost, _max_ts, last_iso) acc ->
    let count = succ + fail in
    let total_dur = List.fold_left (+) 0 durations in
    let avg = if count > 0 then total_dur / count else 0 in
    let sorted = Array.of_list durations in
    Array.sort compare sorted;
    let max_d = if Array.length sorted > 0 then sorted.(Array.length sorted - 1) else 0 in
    { name;
      call_count = count;
      success_count = succ;
      failure_count = fail;
      avg_duration_ms = avg;
      p95_duration_ms = p95_of_sorted sorted;
      max_duration_ms = max_d;
      total_cost_usd = cost;
      last_used_at = last_iso;
    } :: acc
  ) tbl [] in
  List.sort (fun (a : tool_stat) (b : tool_stat) -> compare b.call_count a.call_count) stats

(** Truncate a Unix timestamp to the start of its UTC hour. *)
let hour_start_iso (ts : float) : string =
  let t = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:00:00Z"
    (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday t.tm_hour

let hourly_timeline (entries : tool_call_entry list) : hourly_bucket list =
  let tbl : (string, int * int) Hashtbl.t = Hashtbl.create 24 in
  List.iter (fun (e : tool_call_entry) ->
    let hour = hour_start_iso e.ts in
    let is_err = Option.is_some e.error in
    match Hashtbl.find_opt tbl hour with
    | None -> Hashtbl.replace tbl hour (1, if is_err then 1 else 0)
    | Some (c, errs) -> Hashtbl.replace tbl hour (c + 1, errs + (if is_err then 1 else 0))
  ) entries;
  let buckets = Hashtbl.fold (fun hour (call_count, error_count) acc ->
    { hour; call_count; error_count } :: acc
  ) tbl [] in
  List.sort (fun a b -> String.compare a.hour b.hour) buckets

let tool_stat_to_json (s : tool_stat) : Yojson.Safe.t =
  `Assoc [
    ("name", `String s.name);
    ("call_count", `Int s.call_count);
    ("success_count", `Int s.success_count);
    ("failure_count", `Int s.failure_count);
    ("avg_duration_ms", `Int s.avg_duration_ms);
    ("p95_duration_ms", `Int s.p95_duration_ms);
    ("max_duration_ms", `Int s.max_duration_ms);
    ("total_cost_usd", `Float s.total_cost_usd);
    ("last_used_at", `String s.last_used_at);
  ]

let hourly_bucket_to_json (b : hourly_bucket) : Yojson.Safe.t =
  `Assoc [
    ("hour", `String b.hour);
    ("call_count", `Int b.call_count);
    ("error_count", `Int b.error_count);
  ]

(** Read all .jsonl trace files for a keeper. Filter entries with ts >= since.
    Scans the keeper's trajectory directory for all trace files. *)
let read_entries_since_result ~(masc_root : string) ~(keeper_name : string)
    ~(since : float) : entries_read_result =
  let dir = trajectories_dir masc_root keeper_name in
  if not (Sys.file_exists dir) then
    { entries = []; gate_decode = { parsed_gate_count = 0; legacy_default_count = 0 } }
  else
    let files = Sys.readdir dir in
    let all_entries = ref [] in
    let parsed_gate_count = ref 0 in
    let legacy_default_count = ref 0 in
    Array.iter (fun fname ->
      if Filename.check_suffix fname ".jsonl" then begin
        let path = Filename.concat dir fname in
        (try
           let content = Fs_compat.load_file path in
           String.split_on_char '\n' content
           |> List.iter (fun line ->
             if String.trim line <> "" then
               try
                 let json = Yojson.Safe.from_string line in
                 (match tool_call_entry_of_json json with
                  | Some (entry, parsed_gate) when entry.ts >= since ->
                      if parsed_gate then incr parsed_gate_count
                      else incr legacy_default_count;
                      all_entries := entry :: !all_entries
                  | _ -> ())
               with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ())
         with Sys_error _ -> ())
      end
    ) files;
    {
      entries =
        List.sort
          (fun (a : tool_call_entry) (b : tool_call_entry) -> compare a.ts b.ts)
          !all_entries;
      gate_decode =
        {
          parsed_gate_count = !parsed_gate_count;
          legacy_default_count = !legacy_default_count;
        };
    }

let read_entries_since ~(masc_root : string) ~(keeper_name : string)
    ~(since : float) : tool_call_entry list =
  (read_entries_since_result ~masc_root ~keeper_name ~since).entries

(* ── Tool-affinity aggregate: windowed read + full-scan rebuild ── *)

(** Project the day-bucketed aggregate to per-tool [tool_stat]s over the
    rolling window [ts >= since]. Equivalent to
    [aggregate_tool_stats (read_entries_since ~since)] for the fields
    [Keeper_tool_affinity] consumes (call_count, success_count,
    last_used_at); latency and cost are 0 because this aggregate does not
    track them (compute_affinity ignores them). Buckets are day-aligned, so
    the window boundary is inclusive of the whole [since] day (see the
    section header). *)
let windowed_affinity_tool_stats (agg : tool_affinity_aggregate)
    ~(since : float) : tool_stat list =
  let since_day = day_index_of_ts since in
  agg.aggregate_tools
  |> List.filter_map (fun (s : tool_affinity_bucket_series) ->
    match
      List.filter (fun (b : tool_day_bucket) -> b.bucket_day >= since_day) s.series_buckets
    with
    | [] -> None
    | buckets ->
      let call_count =
        List.fold_left (fun acc (b : tool_day_bucket) -> acc + b.bucket_call_count) 0 buckets
      in
      let success_count =
        List.fold_left (fun acc (b : tool_day_bucket) -> acc + b.bucket_success_count) 0 buckets
      in
      let _, last_iso =
        List.fold_left
          (fun (max_ts, max_iso) (b : tool_day_bucket) ->
            if b.bucket_last_ts > max_ts then (b.bucket_last_ts, b.bucket_last_iso)
            else (max_ts, max_iso))
          (neg_infinity, "")
          buckets
      in
      Some
        { name = s.series_tool_name;
          call_count;
          success_count;
          failure_count = call_count - success_count;
          avg_duration_ms = 0;
          p95_duration_ms = 0;
          max_duration_ms = 0;
          total_cost_usd = 0.0;
          last_used_at = last_iso })
  (* Mirror aggregate_tool_stats' call_count-descending order so
     compute_affinity receives the same pre-sort ordering. *)
  |> List.sort (fun (a : tool_stat) (b : tool_stat) -> compare b.call_count a.call_count)

(** Reconstruct the aggregate from a full JSONL scan and persist it. The
    scan is the P0-freeze cost; callers wrap this in
    [Domain_pool_ref.submit_io_or_inline] to keep it off the main Eio
    domain (see Keeper_tool_affinity.pre_populate_from_history). Scans over
    the retention horizon so the snapshot serves any lookback up to the cap;
    the read then windows to the configured lookback. The missing/corrupt
    snapshot scan is serialized with same-keeper JSONL append/flush writes,
    so concurrent durable entries are either included in this scan or
    incremented immediately after the snapshot exists. *)
let rebuild_tool_affinity_aggregate ~(masc_root : string)
    ~(keeper_name : string) ~(now : float) : tool_affinity_aggregate =
  with_aggregate_rebuild_guard ~masc_root ~keeper_name (fun () ->
    match read_aggregate_snapshot ~masc_root ~keeper_name with
    | Ok existing -> existing
    | Error (Aggregate_missing | Aggregate_unreadable _ | Aggregate_corrupt _) ->
      let since =
        now -. (float_of_int affinity_aggregate_retention_days *. seconds_per_day)
      in
      let entries = read_entries_since ~masc_root ~keeper_name ~since in
      let scanned = build_tool_affinity_aggregate ~keeper_name ~now entries in
      with_aggregate_snapshot_guard ~masc_root ~keeper_name (fun () ->
        match read_aggregate_snapshot ~masc_root ~keeper_name with
        | Ok existing -> existing
        | Error (Aggregate_missing | Aggregate_unreadable _ | Aggregate_corrupt _) ->
          (match persist_aggregate_snapshot ~masc_root ~keeper_name scanned with
           | Ok () -> ()
           | Error msg ->
             Log.Keeper.warn
               "trajectory: failed to persist rebuilt tool-affinity aggregate for %s: %s"
               keeper_name msg);
          scanned))

(* ================================================================ *)
(* Read trajectory from JSONL (for replay/eval)                     *)
(* ================================================================ *)

let read_entries ~(masc_root : string) ~(keeper_name : string) ~(trace_id : string)
    : tool_call_entry list =
  let path = trajectory_path masc_root keeper_name trace_id in
  if not (Sys.file_exists path) then []
  else
    let content = Fs_compat.load_file path in
    String.split_on_char '\n' content
    |> List.filter (fun line -> String.trim line <> "")
    |> List.filter_map (fun line ->
        try
          let json = Yojson.Safe.from_string line in
          match tool_call_entry_of_json json with
          | Some (entry, _parsed_gate) -> Some entry
          | None -> None
        with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None)

type trajectory_line_decode_result =
  | Parsed_line of trajectory_line
  | Skipped_line
  | Malformed_line

let trajectory_line_of_json json =
  match Json_util.assoc_member_opt "type" json with
  | Some (`String "trajectory_summary") -> Skipped_line
  | Some (`String "thinking") ->
      Parsed_line
        (Thinking
           { ts =
               (match Json_util.assoc_member_opt "ts" json with
                | Some (`Float f) -> f
                | Some (`Int n) -> Float.of_int n
                | _ -> 0.0)
           ; ts_iso =
               (match Json_util.assoc_member_opt "ts_iso" json with
                | Some (`String s) -> s
                | _ -> "")
           ; turn =
               (match Json_util.assoc_member_opt "turn" json with
                | Some (`Int n) -> n
                | _ -> 0)
           ; content =
               (match Json_util.assoc_member_opt "content" json with
                | Some (`String s) -> s
                | _ -> "")
           ; content_length =
               (match Json_util.assoc_member_opt "content_length" json with
                | Some (`Int n) -> n
                | _ -> 0)
           ; redacted =
               (match Json_util.assoc_member_opt "redacted" json with
                | Some (`Bool b) -> b
                | _ -> false)
           })
  | _ ->
      (match tool_call_entry_of_json json with
       | Some (entry, _parsed_gate) -> Parsed_line (Tool_call entry)
       | None -> Malformed_line)
;;

(* Rows that fail to parse or decode here are silently dropped from the
   dashboard's /trajectory response with no signal at all -- unlike the
   internal_history merge path (see
   [Server_dashboard_http_keeper_api_trace.log_internal_history_skips]),
   which already tracks skipped/total and logs a per-read summary. Follow
   the same summarized-WARN pattern rather than warn-per-row: a busy trace
   file re-read on every dashboard poll would otherwise flood the log the
   same way the internal_history path did before that fix. *)
let log_trajectory_line_skips ~trace_id ~skipped ~total =
  if skipped > 0 then
    Log.Keeper.warn
      "trajectory trace %s: %d of %d rows did not decode to a trajectory \
       line (malformed JSON or unrecognized shape)"
      trace_id skipped total
;;

let trajectory_lines_of_jsonl_lines ~trace_id lines =
  let lines_rev, skipped, total =
    List.fold_left
      (fun (acc, skipped, total) line ->
         let decode =
           try Yojson.Safe.from_string line |> trajectory_line_of_json with
           | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> Malformed_line
         in
         match decode with
         | Parsed_line parsed -> parsed :: acc, skipped, total + 1
         | Skipped_line -> acc, skipped, total + 1
         | Malformed_line -> acc, skipped + 1, total + 1)
      ([], 0, 0)
      lines
  in
  log_trajectory_line_skips ~trace_id ~skipped ~total;
  List.rev lines_rev, skipped, total
;;

(** Read all trajectory lines including thinking entries. *)
let read_all_lines ~(masc_root : string) ~(keeper_name : string) ~(trace_id : string)
    : trajectory_line list =
  let path = trajectory_path masc_root keeper_name trace_id in
  if not (Sys.file_exists path) then []
  else
    let content = Fs_compat.load_file path in
    String.split_on_char '\n' content
    |> List.filter (fun line -> String.trim line <> "")
    |> trajectory_lines_of_jsonl_lines ~trace_id
    |> fun (lines, _skipped, _total) -> lines

let read_recent_lines
      ~(masc_root : string)
      ~(keeper_name : string)
      ~(trace_id : string)
      ~(max_lines : int)
  : trajectory_line list
  =
  let path = trajectory_path masc_root keeper_name trace_id in
  Dated_jsonl.load_tail_lines path ~max_lines
  |> trajectory_lines_of_jsonl_lines ~trace_id
  |> fun (lines, _skipped, _total) -> lines
