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
  tool_success_rate : float;
  last_visible_action_age_sec : int;
  pr_workflow_attempts : int;
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
    tool_success_rate = 0.0;
    last_visible_action_age_sec = 0;
    pr_workflow_attempts = 0;
    work_discovery_count = 0;
  }

(* ------------------------------------------------------------------ *)
(* JSON field extraction helpers                                       *)
(* ------------------------------------------------------------------ *)

let json_float_opt key (json : Yojson.Safe.t) : float option =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Float f) -> Some f
     | Some (`Int i) -> Some (float_of_int i)
     | _ -> None)
  | _ -> None

let json_string_opt key (json : Yojson.Safe.t) : string option =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String s) -> Some s
     | _ -> None)
  | _ -> None

let json_int_opt key (json : Yojson.Safe.t) : int option =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Int i) -> Some i
     | Some (`Float f) -> Some (int_of_float f)
     | _ -> None)
  | _ -> None

let json_string_list key (json : Yojson.Safe.t) : string list =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`List items) ->
       List.filter_map (function
         | `String s -> Some s
         | _ -> None) items
     | _ -> [])
  | _ -> []

(* ------------------------------------------------------------------ *)
(* Decision log parsing                                                *)
(* ------------------------------------------------------------------ *)

type parsed_decision = {
  timestamp_unix : float;
  outcome : string;
  tool_call_count : int;
  tools_used : string list;
}

let parse_decision_line (line : string) : parsed_decision option =
  match Yojson.Safe.from_string line with
  | json ->
    let timestamp_unix =
      json_float_opt "timestamp_unix" json
      |> Option.value ~default:0.0
    in
    let outcome =
      json_string_opt "outcome" json
      |> Option.value ~default:"unknown"
    in
    let tool_call_count =
      json_int_opt "tool_call_count" json
      |> Option.value ~default:0
    in
    let tools_used = json_string_list "tools_used" json in
    Some { timestamp_unix; outcome; tool_call_count; tools_used }
  | exception _ -> None

(* ------------------------------------------------------------------ *)
(* Stats computation                                                   *)
(* ------------------------------------------------------------------ *)

let compute_stats ~decision_log_path ~window_hours =
  let now_ts = Unix.gettimeofday () in
  let window_start = now_ts -. (float_of_int window_hours *. 3600.0) in
  let lines =
    try
      let content = Fs_compat.load_file decision_log_path in
      String.split_on_char '\n' content
      |> List.filter (fun s -> String.trim s <> "")
    with _ -> []
  in
  let decisions =
    lines
    |> List.filter_map parse_decision_line
    |> List.filter (fun d -> d.timestamp_unix >= window_start)
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
    let pr_workflow_attempts =
      List.length (List.filter (fun d ->
        List.exists (fun t ->
          String.lowercase_ascii t = "keeper_pr_workflow") d.tools_used
      ) decisions)
    in
    let last_visible_ts =
      decisions
      |> List.filter (fun d -> not (is_silent d))
      |> List.fold_left (fun acc d ->
        max acc d.timestamp_unix) 0.0
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
    let tool_success_rate =
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
      tool_success_rate;
      last_visible_action_age_sec;
      pr_workflow_attempts;
      work_discovery_count = 0;
    }

(* ------------------------------------------------------------------ *)
(* Prompt rendering                                                    *)
(* ------------------------------------------------------------------ *)

let format_age_sec (sec : int) : string =
  if sec < 60 then Printf.sprintf "%ds" sec
  else if sec < 3600 then Printf.sprintf "%dm %ds" (sec / 60) (sec mod 60)
  else
    let h = sec / 3600 in
    let m = (sec mod 3600) / 60 in
    Printf.sprintf "%dh %dm" h m

let render_feedback_block ~(stats : behavioral_stats) =
  if stats.total_turns = 0 then
    Printf.sprintf
      "### Behavioral Self-Assessment (last %dh)\n\
       - No turns recorded in this window.\n\n"
      stats.window_hours
  else
    let tools_str =
      match stats.unique_tools_used with
      | [] -> "none"
      | ts -> String.concat ", " ts
    in
    Printf.sprintf
      "### Behavioral Self-Assessment (last %dh)\n\
       - Turns: %d total (%d silent, %d active)\n\
       - Silent ratio: %.1f%%\n\
       - Tool use turns: %d (success rate: %.1f%%)\n\
       - Text-only response turns: %d\n\
       - Last visible action: %s ago\n\
       - PR workflow attempts: %d\n\
       - Unique tools used: %s\n\n"
      stats.window_hours
      stats.total_turns stats.silent_turns
      (stats.total_turns - stats.silent_turns)
      (stats.silent_ratio *. 100.0)
      stats.tool_use_turns (stats.tool_success_rate *. 100.0)
      stats.text_response_turns
      (format_age_sec stats.last_visible_action_age_sec)
      stats.pr_workflow_attempts
      tools_str
