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
  (* An unparseable [last_seen] is absence of liveness evidence, so it stays an
     [option] here instead of collapsing to an elapsed of 0.0. That collapse
     read as "seen just now" and put an agent with a corrupt timestamp in the
     healthiest bucket the label has. #9751 settled the direction for the
     missing-field case and keeper_status_runtime.ml applies it to the derived
     age; the label follows the same rule and names the gap rather than
     printing a minute count it does not have. *)
  match status, parse_iso_timestamp last_seen_iso with
  | (Masc_domain.Active | Masc_domain.Busy), None ->
      "STUCK (no liveness evidence)"
  | Masc_domain.Active, Some ts when now -. ts > stuck_threshold_sec ->
      Printf.sprintf "STUCK (%.0fm, needs check)" ((now -. ts) /. 60.0)
  | Masc_domain.Busy, Some ts when now -. ts > stuck_threshold_sec ->
      Printf.sprintf "STUCK (%.0fm, marked busy but no progress)"
        ((now -. ts) /. 60.0)
  | Masc_domain.Active, Some ts when now -. ts > quiet_threshold_sec ->
      Printf.sprintf "quiet (%.0fm)" ((now -. ts) /. 60.0)
  | Masc_domain.Active, Some _ -> "working"
  | Masc_domain.Busy, Some _ -> "working (busy)"
  | Masc_domain.Listening, _ -> "idle"
  | Masc_domain.Inactive, _ -> "offline"

(** Classify an agent for grouping: Working, Stuck, Idle, or Offline.
    Offline agents (Inactive) are separated from Idle (Listening) so that
    downstream capacity logic does not treat offline agents as available. *)
type agent_group = Working | Stuck | Idle | Offline [@@deriving eq]

let classify_agent ~(now : float) (agent : Masc_domain.agent) : agent_group =
  let stuck_threshold_sec =
    Runtime_params.get Runtime_settings.dashboard_agent_stuck_threshold_sec
  in
  (* Same rule as [translate_agent_status]: no parseable timestamp is no
     liveness evidence. Only [Active]/[Busy] claim to be running, so only they
     turn [Stuck] on missing evidence — [Listening] and [Inactive] keep their
     status-derived group. *)
  match agent.status, parse_iso_timestamp agent.last_seen with
  | (Masc_domain.Active | Masc_domain.Busy), None -> Stuck
  | (Masc_domain.Active | Masc_domain.Busy), Some ts
    when now -. ts > stuck_threshold_sec -> Stuck
  | (Masc_domain.Active | Masc_domain.Busy), Some _ -> Working
  | Masc_domain.Listening, _ -> Idle
  | Masc_domain.Inactive, _ -> Offline
