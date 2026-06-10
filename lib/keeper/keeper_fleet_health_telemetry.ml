(** Fleet health telemetry — implementation. *)

open Keeper_registry_types

type phase_counts =
  { online : int
  ; observe : int
  ; offline : int
  ; paused : int
  ; overflowed : int
  ; compacting : int
  ; handing_off : int
  ; draining : int
  ; stopped : int
  ; crashed : int
  ; restarting : int
  ; zombie : int
  ; dead : int
  ; total : int
  }

type keeper_health =
  { name : string
  ; phase : Keeper_state_machine.phase
  ; alive : bool
  ; restart_count : int
  ; last_restart_ago_sec : float option
  ; consecutive_failures : int
  ; dead_since_ago_sec : float option
  ; last_error : string option
  ; last_failure_reason : failure_reason option
  }

type anomaly_flags =
  { empty_fleet : bool
  ; all_dead : bool
  ; cascade_restart : bool
  ; multiple_paused : bool
  ; failure_spike : bool
  }

type telemetry_snapshot =
  { sampled_at : float
  ; counts : phase_counts
  ; keepers : keeper_health list
  ; anomalies : anomaly_flags
  ; dead_keepers : keeper_health list
  ; paused_keepers : keeper_health list
  }

(* ── Phase classification ───────────────────────────────── *)

let empty_phase_counts =
  { online = 0
  ; observe = 0
  ; offline = 0
  ; paused = 0
  ; overflowed = 0
  ; compacting = 0
  ; handing_off = 0
  ; draining = 0
  ; stopped = 0
  ; crashed = 0
  ; restarting = 0
  ; zombie = 0
  ; dead = 0
  ; total = 0
  }

let classify_phase_counts (entries : registry_entry list) =
  let fold_fn counts (entry : registry_entry) =
    let open Keeper_state_machine in
    let counts = { counts with total = counts.total + 1 } in
    match entry.phase with
    | Running -> { counts with online = counts.online + 1 }
    | Failing -> { counts with observe = counts.observe + 1 }
    | Offline -> { counts with offline = counts.offline + 1 }
    | Paused -> { counts with paused = counts.paused + 1 }
    | Overflowed -> { counts with overflowed = counts.overflowed + 1 }
    | Compacting -> { counts with compacting = counts.compacting + 1 }
    | HandingOff -> { counts with handing_off = counts.handing_off + 1 }
    | Draining -> { counts with draining = counts.draining + 1 }
    | Stopped -> { counts with stopped = counts.stopped + 1 }
    | Crashed -> { counts with crashed = counts.crashed + 1 }
    | Restarting -> { counts with restarting = counts.restarting + 1 }
    | Zombie -> { counts with zombie = counts.zombie + 1 }
    | Dead -> { counts with dead = counts.dead + 1 }
  in
  List.fold_left fold_fn empty_phase_counts entries

let alive_phases : Keeper_state_machine.phase list =
  [ Running; Failing ]

let is_alive (entry : registry_entry) =
  List.mem entry.phase alive_phases

let is_terminal_failure_phase = function
  | Keeper_state_machine.Dead | Keeper_state_machine.Zombie -> true
  | _ -> false

(* ── Per-keeper health ──────────────────────────────────── *)

let keeper_health_of_entry ~now (entry : registry_entry) =
  let last_restart_ago_sec =
    if entry.restart_count > 0 then Some (now -. entry.last_restart_ts)
    else None
  in
  let dead_since_ago_sec =
    Option.map (fun ts -> now -. ts) entry.dead_since_ts
  in
  { name = entry.name
  ; phase = entry.phase
  ; alive = is_alive entry
  ; restart_count = entry.restart_count
  ; last_restart_ago_sec
  ; consecutive_failures = entry.turn_consecutive_failures
  ; dead_since_ago_sec
  ; last_error = entry.last_error
  ; last_failure_reason = entry.last_failure_reason
  }

(* ── Anomaly detection ──────────────────────────────────── *)

let detect_anomalies
      ~now
      ~cascade_window_sec
      ~failure_spike_threshold
      (entries : registry_entry list)
      (healths : keeper_health list)
  =
  let total = List.length entries in
  let dead_count =
    List.length
      (List.filter (fun (e : registry_entry) -> is_terminal_failure_phase e.phase) entries)
  in
  let paused_count =
    List.length
      (List.filter
         (fun (e : registry_entry) -> e.phase = Keeper_state_machine.Paused)
         entries)
  in

  let empty_fleet = total = 0 in
  let all_dead = total > 0 && dead_count = total in

  let cascade_restart =
    let recent_restarts =
      List.filter
        (fun (e : registry_entry) ->
          e.restart_count > 0 && now -. e.last_restart_ts <= cascade_window_sec)
        entries
    in
    List.length recent_restarts >= 3
  in

  let multiple_paused = paused_count >= 2 in
  let failure_spike =
    List.exists (fun h -> h.consecutive_failures >= failure_spike_threshold) healths
  in

  { empty_fleet; all_dead; cascade_restart; multiple_paused; failure_spike }

(* ── Main entry point ───────────────────────────────────── *)

let summarize
      ~now
      ~stale_dead_threshold_sec:_
      ~cascade_window_sec
      ~failure_spike_threshold
      (entries : registry_entry list)
  =
  let counts = classify_phase_counts entries in
  let healths = List.map (keeper_health_of_entry ~now) entries in
  let anomalies = detect_anomalies ~now ~cascade_window_sec
    ~failure_spike_threshold entries healths in
  let dead_keepers =
    List.filter
      (fun h ->
        is_terminal_failure_phase h.phase)
      healths
  in
  let paused_keepers =
    List.filter (fun h -> h.phase = Keeper_state_machine.Paused) healths
  in
  { sampled_at = now
  ; counts
  ; keepers = healths
  ; anomalies
  ; dead_keepers
  ; paused_keepers
  }
