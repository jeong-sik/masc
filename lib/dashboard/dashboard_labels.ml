(** Dashboard Labels — Pure translation from raw states to operator-readable text.

    No side effects, no IO. All functions take raw values and return human-readable strings.
    This module has NO dependency on Dashboard to avoid circular deps.
    Dashboard and Dashboard_attention both depend on this module. *)

(* ===== Shared Types (to break circular dependency) ===== *)

(** Lane summary — extracted from swarm JSON, used by both Dashboard and Dashboard_attention.
    Phase/motion_state/hard_flags use variants from Swarm_status_types to make
    exhaustive matching possible and catch new values at compile time. *)
type swarm_lane_summary = {
  label: string;
  present: bool;
  phase: Swarm_status_types.lane_phase;
  motion_state: Swarm_status_types.lane_motion;
  age: string;
  current_step: string;
  hard_flags: Swarm_status_types.flag_code list;
}

(** Coord snapshot — shared between Dashboard and Dashboard_attention *)
type room_snapshot = {
  room_id: string;
  is_current: bool;
  agents: Types.agent list;
  tasks: Types.task list;
  messages: Types.message list;
  locks: int;
}

(* ===== ISO Timestamp Parsing (moved here to break cycle) ===== *)

(** Parse dashboard timestamps to Unix time.
    Accepts canonical UTC timestamps, fractional-second RFC3339 variants,
    numeric UTC offsets, and bare local timestamps from older read models. *)
let parse_iso_timestamp (s : string) : float option =
  let is_digit c = c >= '0' && c <= '9' in
  let all_digits raw =
    let len = String.length raw in
    len > 0 && String.for_all is_digit raw
  in
  let parse_tz_offset raw =
    let len = String.length raw in
    if len = 0 then None
    else
      let sign =
        match raw.[0] with
        | '+' -> 1
        | '-' -> -1
        | _ -> 0
      in
      if sign = 0 then None
      else
        match len with
        | 6 when raw.[3] = ':' ->
            let hh = String.sub raw 1 2 in
            let mm = String.sub raw 4 2 in
            if all_digits hh && all_digits mm then
              Some (sign * ((int_of_string hh * 3600) + (int_of_string mm * 60)))
            else
              None
        | 5 ->
            let hh = String.sub raw 1 2 in
            let mm = String.sub raw 3 2 in
            if all_digits hh && all_digits mm then
              Some (sign * ((int_of_string hh * 3600) + (int_of_string mm * 60)))
            else
              None
        | _ -> None
  in
  let parse_fraction_seconds raw =
    if not (all_digits raw) then None
    else
      let numerator =
        String.fold_left
          (fun acc ch -> (acc *. 10.0) +. float_of_int (Char.code ch - Char.code '0'))
          0.0 raw
      in
      Some (numerator /. (10.0 ** float_of_int (String.length raw)))
  in
  let split_timezone raw =
    let len = String.length raw in
    if len = 0 then None
    else
      match raw.[len - 1] with
      | 'Z' | 'z' -> Some (String.sub raw 0 (len - 1), Some 0)
      | _ ->
          let suffix_opt width =
            if len > width then Some (String.sub raw (len - width) width) else None
          in
          (match Option.bind (suffix_opt 6) parse_tz_offset with
          | Some offset -> Some (String.sub raw 0 (len - 6), Some offset)
          | None -> (
              match Option.bind (suffix_opt 5) parse_tz_offset with
              | Some offset -> Some (String.sub raw 0 (len - 5), Some offset)
              | None -> Some (raw, None)))
  in
  let split_fraction raw =
    match String.index_opt raw '.' with
    | None -> Some (raw, 0.0)
    | Some dot ->
        let main = String.sub raw 0 dot in
        let fraction = String.sub raw (dot + 1) (String.length raw - dot - 1) in
        if String.length main <> 19 then None
        else Option.map (fun fraction_s -> (main, fraction_s)) (parse_fraction_seconds fraction)
  in
  let parse_main raw =
    if String.length raw <> 19 then None
    else
      try
        Some
          (Scanf.sscanf raw "%04d-%02d-%02dT%02d:%02d:%02d"
             (fun year mon day hour min sec -> (year, mon, day, hour, min, sec)))
      with
      | Scanf.Scan_failure _ | Failure _ | End_of_file -> None
  in
  let trimmed = String.trim s in
  if trimmed = "" then None
  else
    match split_timezone trimmed with
    | None -> None
    | Some (raw_main, source_offset_opt) -> (
        match split_fraction raw_main with
        | None -> None
        | Some (main, fraction_s) -> (
            match parse_main main with
            | None -> None
            | Some (year, mon, day, hour, min, sec) ->
                let tm =
                  {
                    Unix.tm_sec = sec;
                    tm_min = min;
                    tm_hour = hour;
                    tm_mday = day;
                    tm_mon = mon - 1;
                    tm_year = year - 1900;
                    tm_wday = 0;
                    tm_yday = 0;
                    tm_isdst = false;
                  }
                in
                let local_epoch, _ = Unix.mktime tm in
                let utc_tm = Unix.gmtime local_epoch in
                let utc_as_local, _ = Unix.mktime utc_tm in
                let local_offset_s = local_epoch -. utc_as_local in
                let source_offset_s =
                  match source_offset_opt with
                  | Some offset -> float_of_int offset
                  | None -> local_offset_s
                in
                Some (local_epoch +. local_offset_s -. source_offset_s +. fraction_s)))

let format_elapsed now timestamp fallback =
  match parse_iso_timestamp timestamp with
  | Some ts ->
      let elapsed = now -. ts in
      if elapsed < 60.0 then Printf.sprintf "%.0fs ago" elapsed
      else if elapsed < 3600.0 then Printf.sprintf "%.0fm ago" (elapsed /. 60.0)
      else Printf.sprintf "%.1fh ago" (elapsed /. 3600.0)
  | None -> fallback

(* ===== Agent Status Translation ===== *)

(** Translate agent status + elapsed time into operator-readable description. *)
let translate_agent_status ~(now : float) (status : Types.agent_status)
    (last_seen_iso : string) : string =
  let quiet_threshold_sec =
    Runtime_params.get Governance_registry.dashboard_agent_quiet_threshold_sec
  in
  let stuck_threshold_sec =
    Runtime_params.get Governance_registry.dashboard_agent_stuck_threshold_sec
  in
  let elapsed_opt = parse_iso_timestamp last_seen_iso in
  let elapsed_sec =
    match elapsed_opt with Some ts -> now -. ts | None -> 0.0
  in
  match status with
  | Types.Active when elapsed_sec > stuck_threshold_sec ->
      Printf.sprintf "STUCK (%.0fm, needs check)" (elapsed_sec /. 60.0)
  | Types.Busy when elapsed_sec > stuck_threshold_sec ->
      Printf.sprintf "STUCK (%.0fm, marked busy but no progress)"
        (elapsed_sec /. 60.0)
  | Types.Active when elapsed_sec > quiet_threshold_sec ->
      Printf.sprintf "quiet (%.0fm)" (elapsed_sec /. 60.0)
  | Types.Active -> "working"
  | Types.Busy -> "working (busy)"
  | Types.Listening -> "idle"
  | Types.Inactive -> "offline"

(** Classify an agent for grouping: Working, Stuck, Idle, or Offline.
    Offline agents (Inactive) are separated from Idle (Listening) so that
    downstream capacity logic does not treat offline agents as available. *)
type agent_group = Working | Stuck | Idle | Offline [@@deriving eq]

let classify_agent ~(now : float) (agent : Types.agent) : agent_group =
  let stuck_threshold_sec =
    Runtime_params.get Governance_registry.dashboard_agent_stuck_threshold_sec
  in
  let elapsed_opt = parse_iso_timestamp agent.last_seen in
  let elapsed_sec =
    match elapsed_opt with Some ts -> now -. ts | None -> 0.0
  in
  match agent.status with
  | Types.Active | Types.Busy when elapsed_sec > stuck_threshold_sec -> Stuck
  | Types.Active | Types.Busy -> Working
  | Types.Listening -> Idle
  | Types.Inactive -> Offline

(* ===== Lane Status Translation ===== *)

(** Translate lane phase + motion_state into a single human-readable sentence. *)
let translate_lane_status ~(phase : Swarm_status_types.lane_phase)
    ~(motion_state : Swarm_status_types.lane_motion) ~(age : string) : string =
  let open Swarm_status_types in
  match (phase, motion_state) with
  | Executing, Moving -> Printf.sprintf "Running (last %s)" age
  | Executing, Stalled -> "STALLED - no progress"
  | Executing, Waiting -> "Waiting (has workers)"
  | Dispatching, _ -> "Assigning work to agents"
  | Awaiting_approval, _ -> "BLOCKED - needs your approval"
  | Blocked, _ -> "BLOCKED"
  | Lane_completed, _ -> "Done"
  | Forming, _ -> "Not started"
  | Executing, Terminal ->
      Printf.sprintf "%s / %s"
        (Swarm_status_json.lane_phase_to_string phase)
        (Swarm_status_json.lane_motion_to_string motion_state)

(* ===== Flag Code Translation ===== *)

(** Translate raw flag codes to human-readable descriptions. *)
let translate_flag_code (code : Swarm_status_types.flag_code) : string =
  let open Swarm_status_types in
  match code with
  | Pending_manual_confirmation -> "Waiting for your approval"
  | Missing_trace_events -> "No audit trail"
  | Missing_worker_binding -> "No assigned workers"
  | Projected_only -> "No managed runtime (projection only)"
  | Stale_data -> "Data may be outdated"
  | Missing_runtime_progress -> "No runtime progress"
  | Dashboard_source_split -> "Dashboard source split"

(* ===== Severity Icons ===== *)

let severity_icon (severity : Swarm_status_types.flag_severity) : string =
  let open Swarm_status_types in
  match severity with
  | Flag_bad -> "[!]"
  | Flag_warn -> "[~]"

(* ===== Health Verdict ===== *)

(** Produce a one-line health summary from lane summaries.
    A lane can be both stalled and blocked (lane_phase maps stalled motion
    to "blocked" phase), so we count distinct lanes needing attention. *)
let health_verdict (lanes : swarm_lane_summary list) : string =
  let open Swarm_status_types in
  let needs_attention (l : swarm_lane_summary) =
    l.motion_state = Stalled || l.phase = Awaiting_approval || l.phase = Blocked
  in
  let moving =
    List.filter (fun (l : swarm_lane_summary) -> l.motion_state = Moving) lanes
  in
  let attention_count =
    List.length (List.filter needs_attention lanes)
  in
  let total = List.length lanes in
  if total = 0 then "No active lanes"
  else if attention_count > 0 then
    Printf.sprintf "%d lane%s active, %d needs attention"
      total (if total > 1 then "s" else "")
      attention_count
  else
    Printf.sprintf "%d lane%s running (%d moving)"
      total (if total > 1 then "s" else "")
      (List.length moving)
