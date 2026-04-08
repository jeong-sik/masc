(** Dashboard Labels — Pure translation from raw states to operator-readable text.

    No side effects, no IO. All functions take raw values and return human-readable strings.
    This module has NO dependency on Dashboard to avoid circular deps.
    Dashboard and Dashboard_attention both depend on this module. *)

(* ===== Shared Types (to break circular dependency) ===== *)

(** Lane summary — extracted from swarm JSON, used by both Dashboard and Dashboard_attention *)
type swarm_lane_summary = {
  label: string;
  present: bool;
  phase: string;
  motion_state: string;
  age: string;
  current_step: string;
  hard_flags: string list;
}

(** Room snapshot — shared between Dashboard and Dashboard_attention *)
type room_snapshot = {
  room_id: string;
  is_current: bool;
  agents: Types.agent list;
  tasks: Types.task list;
  messages: Types.message list;
  locks: int;
}

(* ===== ISO Timestamp Parsing (moved here to break cycle) ===== *)

(** Parse dashboard timestamps as UTC.
    Dashboard surfaces mostly emit whole-second ISO8601 timestamps, but a few
    read models still append fractional seconds. Strip the fractional suffix so
    we stay aligned with the canonical UTC parser used elsewhere in the repo. *)
let parse_iso_timestamp (s : string) : float option =
  let normalized =
    let trimmed = String.trim s in
    let len = String.length trimmed in
    if len = 0 then None
    else
      match String.index_opt trimmed '.' with
      | Some dot when dot > 0 && trimmed.[len - 1] = 'Z' ->
          Some (String.sub trimmed 0 dot ^ "Z")
      | _ -> Some trimmed
  in
  Option.bind normalized Types.parse_iso8601_opt

let format_elapsed now timestamp fallback =
  match parse_iso_timestamp timestamp with
  | Some ts ->
      let elapsed = now -. ts in
      if elapsed < 60.0 then Printf.sprintf "%.0fs ago" elapsed
      else if elapsed < 3600.0 then Printf.sprintf "%.0fm ago" (elapsed /. 60.0)
      else Printf.sprintf "%.1fh ago" (elapsed /. 3600.0)
  | None -> fallback

(* ===== Agent Status Translation ===== *)

(** Threshold in seconds for considering an agent "stuck" *)
let stuck_threshold_sec = 900.0 (* 15 minutes *)

(** Threshold in seconds for "quiet" warning *)
let quiet_threshold_sec = Env_config.InternalTimers.label_quiet_threshold_sec

(** Translate agent status + elapsed time into operator-readable description. *)
let translate_agent_status ~(now : float) (status : Types.agent_status)
    (last_seen_iso : string) : string =
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
let translate_lane_status ~(phase : string) ~(motion_state : string)
    ~(age : string) : string =
  match (phase, motion_state) with
  | "executing", "moving" -> Printf.sprintf "Running (last %s)" age
  | "executing", "stalled" -> "STALLED - no progress"
  | "executing", "waiting" -> "Waiting (has workers)"
  | "dispatching", _ -> "Assigning work to agents"
  | "awaiting_approval", _ -> "BLOCKED - needs your approval"
  | "blocked", _ -> "BLOCKED"
  | "completed", _ -> "Done"
  | "forming", _ -> "Not started"
  | phase, motion ->
      Printf.sprintf "%s / %s" phase motion

(* ===== Flag Code Translation ===== *)

(** Translate raw flag codes to human-readable descriptions. *)
let translate_flag_code (code : string) : string =
  match code with
  | "pending_manual_confirmation" -> "Waiting for your approval"
  | "missing_trace_events" -> "No audit trail"
  | "missing_worker_binding" -> "No assigned workers"
  | "projected_only" -> "No managed runtime (projection only)"
  | "stale_data" -> "Data may be outdated"
  | "mixed_runtime_sources" -> "Mixed managed/projected sources"
  | "duration_reached" -> "Time limit reached"
  | "min_agents_violation" -> "Below minimum agent count"
  | other -> other

(* ===== Severity Icons ===== *)

let severity_icon (severity : string) : string =
  match severity with
  | "critical" | "bad" -> "[!]"
  | "warning" | "warn" -> "[~]"
  | "info" -> "[i]"
  | _ -> "[ ]"

(* ===== Health Verdict ===== *)

(** Produce a one-line health summary from lane summaries.
    A lane can be both stalled and blocked (lane_phase maps stalled motion
    to "blocked" phase), so we count distinct lanes needing attention. *)
let health_verdict (lanes : swarm_lane_summary list) : string =
  let needs_attention (l : swarm_lane_summary) =
    String.equal l.motion_state "stalled"
    || String.equal l.phase "awaiting_approval"
    || String.equal l.phase "blocked"
  in
  let moving =
    List.filter (fun (l : swarm_lane_summary) ->
      String.equal l.motion_state "moving") lanes
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
