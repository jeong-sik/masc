(** Keeper_telemetry_feedback — compute behavioral statistics from
    decision logs and render them as a prompt block for keeper
    self-assessment.

    Reads {keeper_name}.decisions.jsonl, filters entries within a
    configurable time window, and produces aggregate stats.
    The rendered block presents data only — the LLM decides how to act. *)

type behavioral_stats = {
  window_hours : int;
  total_turns : int;
  silent_turns : int;
  silent_ratio : float;
  tool_use_turns : int;
  text_response_turns : int;
  unique_tools_used : string list;
  tool_utilization_rate : float;
  last_visible_action_age_sec : int;
  work_discovery_count : int;
}

let empty_stats ~window_hours =
  { window_hours;
    total_turns = 0;
    silent_turns = 0;
    silent_ratio = 0.0;
    tool_use_turns = 0;
    text_response_turns = 0;
    unique_tools_used = [];
    tool_utilization_rate = 0.0;
    last_visible_action_age_sec = 0;
    work_discovery_count = 0;
  }

(* ------------------------------------------------------------------ *)
(* Decision log parsing                                                *)
(* ------------------------------------------------------------------ *)

type parsed_decision = {
  timestamp_unix : float option;
  outcome : string;
  tool_call_count : int;
  tools_used : string list;
}

let parse_decision_line (line : string) : parsed_decision option =
  match Yojson.Safe.from_string line with
  | json ->
    let timestamp_unix = Safe_ops.json_float_opt "timestamp_unix" json in
    let outcome =
      Safe_ops.json_string_opt "outcome" json
      |> Option.value ~default:"unknown"
    in
    let tool_call_count =
      Safe_ops.json_int_opt "tool_call_count" json
      |> Option.value ~default:0
    in
    let tools_used = Safe_ops.json_string_list "tools_used" json in
    Some { timestamp_unix; outcome; tool_call_count; tools_used }
  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
  | exception exn ->
    Log.Keeper.warn "telemetry_feedback: turn record parse failed: %s"
      (Printexc.to_string exn);
    None

(* ------------------------------------------------------------------ *)
(* Stats computation                                                   *)
(* ------------------------------------------------------------------ *)

(* Scale the tail-read limit to the configured window so we never drop
   in-window entries due to truncation.  At up to 3 turns/min, one hour
   produces at most 180 lines; multiply by window_hours and add a small
   buffer.  Hard floor 500 (tiny or zero windows), hard ceiling 10_000
   (memory safety).  window_hours <= 0 is treated as window_hours = 0 and
   falls through to the 500-line floor. *)
let tail_limit_for ~window_hours =
  max 500 (min 10_000 (window_hours * 180 + 200))

let compute_stats ~decision_log_path ~window_hours =
  let now_ts = Unix.gettimeofday () in
  let window_start = now_ts -. (float_of_int window_hours *. 3600.0) in
  let lines =
    try Dated_jsonl.load_tail_lines decision_log_path
          ~max_lines:(tail_limit_for ~window_hours)
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> []
  in
  let decisions =
    lines
    |> List.filter_map parse_decision_line
    |> List.filter (fun d ->
      match d.timestamp_unix with
      | Some ts -> ts >= window_start
      | None -> false)
  in
  let total_turns = List.length decisions in
  if total_turns = 0 then
    empty_stats ~window_hours
  else
    let is_silent d =
      String.lowercase_ascii d.outcome = "proactive_silent"
      || String.lowercase_ascii d.outcome = "noop"
    in
    let silent_turns =
      List.length (List.filter is_silent decisions)
    in
    let tool_use_turns =
      List.length (List.filter (fun d -> d.tool_call_count > 0) decisions)
    in
    let text_response_turns =
      List.length (List.filter (fun d ->
        (not (is_silent d)) && d.tool_call_count = 0) decisions)
    in
    let all_tools =
      decisions
      |> List.concat_map (fun d -> d.tools_used)
    in
    let unique_tools =
      List.sort_uniq String.compare all_tools
    in
    let total_tool_calls =
      List.fold_left (fun acc d -> acc + d.tool_call_count) 0 decisions
    in
    let last_visible_ts =
      decisions
      |> List.filter (fun d -> not (is_silent d))
      |> List.fold_left (fun acc d ->
        match d.timestamp_unix with
        | Some ts -> max acc ts
        | None -> acc) 0.0
    in
    let last_visible_action_age_sec =
      if last_visible_ts <= 0.0 then
        int_of_float (now_ts -. window_start)
      else
        int_of_float (max 0.0 (now_ts -. last_visible_ts))
    in
    let silent_ratio =
      float_of_int silent_turns /. float_of_int total_turns
    in
    let tool_utilization_rate =
      if total_tool_calls > 0 then
        float_of_int tool_use_turns /. float_of_int total_turns
      else 0.0
    in
    { window_hours;
      total_turns;
      silent_turns;
      silent_ratio;
      tool_use_turns;
      text_response_turns;
      unique_tools_used = unique_tools;
      tool_utilization_rate;
      last_visible_action_age_sec;
      work_discovery_count = 0;
    }

(* ------------------------------------------------------------------ *)
(* Proactive cache layer                                               *)
(* ------------------------------------------------------------------ *)

type stats_cache = {
  stats : behavioral_stats;
  computed_at : float;
}

let stats_caches : (string, stats_cache) Hashtbl.t = Hashtbl.create 8
let stats_mu = Eio.Mutex.create ()

let refresh_stats ~keeper_name ~decision_log_path ~window_hours =
  let stats = compute_stats ~decision_log_path ~window_hours in
  Eio.Mutex.use_rw ~protect:true stats_mu (fun () ->
    Hashtbl.replace stats_caches keeper_name
      { stats; computed_at = Unix.gettimeofday () })

(** Return cached stats for a keeper. Returns [None] if no cache entry exists
    (first turn before refresh loop has run). Callers should handle [None]
    by omitting the telemetry block rather than showing "last 0h". *)
let get_cached_stats ~keeper_name : behavioral_stats option =
  Eio.Mutex.use_ro stats_mu (fun () ->
    match Hashtbl.find_opt stats_caches keeper_name with
    | Some c -> Some c.stats
    | None -> None)

let get_cache_age_sec ~keeper_name =
  Eio.Mutex.use_ro stats_mu (fun () ->
    match Hashtbl.find_opt stats_caches keeper_name with
    | Some c -> Some (Unix.gettimeofday () -. c.computed_at)
    | None -> None)

(** Start a background fiber that periodically refreshes telemetry stats.
    The fiber is linked to [sw] — when the keeper's switch is cancelled
    (stop/crash), the fiber terminates automatically via Eio.Cancel.Cancelled. *)
let start_refresh_loop ~sw ~clock ~keeper_name ~decision_log_path
    ~window_hours ~interval_sec ~stop =
  Eio.Fiber.fork ~sw (fun () ->
    while not (Atomic.get stop) do
      (try refresh_stats ~keeper_name ~decision_log_path ~window_hours
       with
       | Eio.Cancel.Cancelled _ as ex ->
           let bt = Printexc.get_raw_backtrace () in
           Printexc.raise_with_backtrace ex bt
       | ex ->
           Log.Keeper.warn "telemetry refresh failed for %s: %s"
             keeper_name (Printexc.to_string ex));
      if not (Atomic.get stop) then
        Eio.Time.sleep clock (float_of_int interval_sec)
    done)

(* render_feedback_block + format_age_sec removed in #6814:
   behavioral self-assessment no longer injected into keeper prompt. *)
