module F = Masc.Fleet_stream
module Keeper_fleet_blocker = Masc.Keeper_fleet_blocker
module Keeper_fleet_grade = Masc.Keeper_fleet_grade
module Terminal_text = Masc_tui_ansi.Terminal_text

let blocker_phrase = function
  | Keeper_fleet_blocker.Keeper_bootstrap_disabled -> "keeper bootstrap off"
  | No_executable_keeper_fibers -> "no keeper can take a turn"
  | Turn_configuration_error -> "config-blocked keepers"
  | Official_client_recovery_required -> "session recovery required"
  | Reaction_capacity_below_target -> "turn capacity below target"
  | Active_task_owner_without_executable_fiber -> "task owner without fiber"
  | Durable_paused_autoboot_enabled -> "autoboot keepers paused"

let status_text = Keeper_fleet_grade.wire_name

let status_is_ok = function
  | Keeper_fleet_grade.Fleet_ok -> true
  | Keeper_fleet_grade.(Fleet_degraded | Fleet_blocked) -> false

let blocker_text (fleet : F.fleet) = Option.map blocker_phrase fleet.fs_blocker

(* The phase snapshot partitions failing Keepers into retrying, configuration
   errors and official-client session recovery, so the classes drawn sum to
   the failing count. The latter two need more than the same turn again. *)
let failing_text (fleet : F.fleet) =
  if fleet.fs_failing_count = 0 then None
  else
    let classes =
      List.filter
        (fun (_, count) -> count > 0)
        [ ("retrying", fleet.fs_recovering_count)
        ; ("config-blocked", fleet.fs_turn_configuration_error_count)
        ; ( "session-recovery-required"
          , fleet.fs_official_client_recovery_required_count )
        ]
    in
    let failing = Printf.sprintf "failing %d" fleet.fs_failing_count in
    match classes with
    | [] -> Some failing
    | _ ->
        Some
          (Printf.sprintf "%s (%s)" failing
             (String.concat " \xc2\xb7 "
                (List.map
                   (fun (label, count) -> Printf.sprintf "%s %d" label count)
                   classes)))

let failure_text = function
  | Masc_tui_fleet_stream.Refused { status; detail } ->
      Printf.sprintf "fleet stream refused with %d: %s" status
        (Terminal_text.single_line detail)
  | Schema_mismatch { expected; received } ->
      Printf.sprintf "fleet stream is schema %d, this build reads %d" received expected
  | Frame_rejected detail ->
      "fleet stream sent a frame this build cannot read: "
      ^ Terminal_text.single_line detail

let outage_reason_text = function
  | F.Scan_timed_out -> "refresh timed out"
  | F.Scan_failed -> "refresh failed"

let unavailable_text ~now ~(degradation : F.degradation) ~disconnected_since =
  let reason = outage_reason_text degradation.reason in
  let scan =
    match Masc_tui_message_layout.age_text ~now ~since:degradation.since with
    | Some age -> Printf.sprintf "not observed · %s for %s" reason age
    | None -> "not observed · " ^ reason
  in
  match disconnected_since with
  | None -> scan
  | Some since ->
    let loss = match Masc_tui_message_layout.age_text ~now ~since with
      | Some age -> "stream lost " ^ age ^ " ago"
      | None -> "stream lost"
    in
    scan ^ " · " ^ loss

(* No reading was ever told and the stream is down, so nothing was observed
   and the screen says the stream is the reason, not a scan. *)
let unreachable_text ~now ~since =
  match Masc_tui_message_layout.age_text ~now ~since with
  | Some age -> "not observed \xc2\xb7 stream lost " ^ age ^ " ago"
  | None -> "not observed \xc2\xb7 stream lost"

(* While the scans fail or the stream is down, the counts beside this are the
   last reading (#38499). The age is taken from [now] at draw time, so it keeps
   growing between events instead of freezing at the age the event had. A
   clock ahead of this one has no age to give, and the tag still says the
   reading is stale. *)
let trouble_text ~now = function
  | Masc_tui_fleet_stream.Scans_failing { F.since; reason } ->
      let reason = outage_reason_text reason in
      (match Masc_tui_message_layout.age_text ~now ~since with
       | Some age -> Printf.sprintf "stale \xc2\xb7 scans failing for %s (%s)" age reason
       | None -> Printf.sprintf "stale (%s)" reason)
  | Disconnected { since } ->
      (match Masc_tui_message_layout.age_text ~now ~since with
       | Some age -> Printf.sprintf "stale \xc2\xb7 stream lost %s ago" age
       | None -> "stale (stream lost)")

(* The task owners the fleet has no fiber for, and how much of that reading is
   missing. A Keeper whose profile does not load is a scan error: its tasks are
   left out of the count, and only a backlog failure moves the fleet status off
   "ok", so an unread Keeper left the row saying nothing at all. The count is
   drawn beside its own shortfall rather than alone.

   [None] where there is neither: a zero over a complete reading is a row spent
   saying nothing happened. *)
let owner_scan_text (fleet : F.fleet) =
  let owners = fleet.fs_active_task_owner_without_fiber_count in
  let unread = fleet.fs_active_task_owner_scan_error_count in
  if owners = 0 && unread = 0 then None
  else if unread = 0 then
    Some (Printf.sprintf "task owner without fiber %d" owners)
  else
    (* [+] because the number is a lower bound, not a total: the unread
       sources held whatever they held. The Changes pane spells an open
       record's call count the same way for the same reason. Without it a
       scan that read nothing said "0", which reads as "there are none"
       while the row's own parenthesis says nobody looked. *)
    Some
      (Printf.sprintf "task owner without fiber %d+ (%s unread)" owners
         (Masc_tui_message_layout.count_noun unread "source"))
