module Tui_decode = Masc.Tui_decode
module Keeper_fleet_blocker = Masc.Keeper_fleet_blocker
module Terminal_text = Masc_tui_ansi.Terminal_text

let blocker_phrase = function
  | Keeper_fleet_blocker.Keeper_bootstrap_disabled -> "keeper bootstrap off"
  | No_executable_keeper_fibers -> "no keeper can take a turn"
  | Turn_configuration_error -> "config-blocked keepers"
  | Official_client_recovery_required -> "session recovery required"
  | Reaction_capacity_below_target -> "turn capacity below target"
  | Active_task_owner_without_executable_fiber -> "task owner without fiber"
  | Durable_paused_autoboot_enabled -> "autoboot keepers paused"

let blocker_text (fleet : Tui_decode.fleet_safety) =
  Option.map
    (function
      | Tui_decode.Blocker blocker -> blocker_phrase blocker
      | Unrecognised_blocker name -> "blocker: " ^ Terminal_text.single_line name)
    fleet.fs_blocker

(* The phase snapshot partitions failing Keepers into retrying, configuration
   errors and official-client session recovery, so the classes drawn sum to
   the failing count. The latter two need more than the same turn again. *)
let failing_text (fleet : Tui_decode.fleet_safety) =
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

(* The task owners the fleet has no fiber for, and how much of that reading is
   missing. A Keeper whose profile does not load is a scan error: its tasks are
   left out of the count, and only a backlog failure moves the fleet status off
   "ok", so an unread Keeper left the row saying nothing at all. The count is
   drawn beside its own shortfall rather than alone.

   [None] where there is neither: a zero over a complete reading is a row spent
   saying nothing happened. *)
let owner_scan_text (fleet : Tui_decode.fleet_safety) =
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
