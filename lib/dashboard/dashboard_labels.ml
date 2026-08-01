(** Dashboard Labels — Pure translation from raw states to operator-readable text.

    No side effects, no IO. All functions take raw values and return human-readable strings.
    This module has NO dependency on Dashboard to avoid circular deps.
    Dashboard and Dashboard_attention both depend on this module. *)

(* ===== Shared Types (to break circular dependency) ===== *)

(** Workspace snapshot — shared between Dashboard and Dashboard_attention *)
type workspace_snapshot = {
  workspace_id: string;
  agents: Masc_domain.agent list;
  tasks: Masc_domain.task list;
  messages: Masc_domain.message list;
  locks: int;
}

(* ===== RFC 3339 Timestamp Parsing ===== *)

let parse_iso_timestamp value = Time_codec.parse_rfc3339_opt value

let format_elapsed now timestamp fallback =
  match parse_iso_timestamp timestamp with
  | Some ts ->
      let elapsed = now -. ts in
      if elapsed < 60.0 then Printf.sprintf "%.0fs ago" elapsed
      else if elapsed < Masc_time_constants.hour then Printf.sprintf "%.0fm ago" (elapsed /. 60.0)
      else Printf.sprintf "%.1fh ago" (elapsed /. Masc_time_constants.hour)
  | None -> fallback

(* ===== Agent Status Translation ===== *)

(** Translate agent status + elapsed time into operator-readable description. *)
let translate_agent_status ~(now : float) (status : Masc_domain.agent_status)
    (last_seen_iso : string) : string =
  let quiet_threshold_sec =
    Runtime_params.get Runtime_settings.dashboard_agent_quiet_threshold_sec
  in
  let stuck_threshold_sec =
    Runtime_params.get Runtime_settings.dashboard_agent_stuck_threshold_sec
  in
  let elapsed_opt = parse_iso_timestamp last_seen_iso in
  let elapsed_sec =
    match elapsed_opt with Some ts -> now -. ts | None -> 0.0
  in
  match status with
  | Masc_domain.Active when elapsed_sec > stuck_threshold_sec ->
      Printf.sprintf "STUCK (%.0fm, needs check)" (elapsed_sec /. 60.0)
  | Masc_domain.Busy when elapsed_sec > stuck_threshold_sec ->
      Printf.sprintf "STUCK (%.0fm, marked busy but no progress)"
        (elapsed_sec /. 60.0)
  | Masc_domain.Active when elapsed_sec > quiet_threshold_sec ->
      Printf.sprintf "quiet (%.0fm)" (elapsed_sec /. 60.0)
  | Masc_domain.Active -> "working"
  | Masc_domain.Busy -> "working (busy)"
  | Masc_domain.Listening -> "idle"
  | Masc_domain.Inactive -> "offline"

(** Classify an agent for grouping: Working, Stuck, Idle, or Offline.
    Offline agents (Inactive) are separated from Idle (Listening) so that
    downstream capacity logic does not treat offline agents as available. *)
type agent_group = Working | Stuck | Idle | Offline [@@deriving eq]

let classify_agent ~(now : float) (agent : Masc_domain.agent) : agent_group =
  let stuck_threshold_sec =
    Runtime_params.get Runtime_settings.dashboard_agent_stuck_threshold_sec
  in
  let elapsed_opt = parse_iso_timestamp agent.last_seen in
  let elapsed_sec =
    match elapsed_opt with Some ts -> now -. ts | None -> 0.0
  in
  match agent.status with
  | Masc_domain.Active | Masc_domain.Busy when elapsed_sec > stuck_threshold_sec -> Stuck
  | Masc_domain.Active | Masc_domain.Busy -> Working
  | Masc_domain.Listening -> Idle
  | Masc_domain.Inactive -> Offline
