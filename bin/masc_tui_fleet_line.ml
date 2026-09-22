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
