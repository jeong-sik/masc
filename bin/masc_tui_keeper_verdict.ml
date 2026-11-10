module Decode = Masc.Tui_decode
module Pulse = Masc.Keeper_turn_pulse

type t = Failing of { resting : bool } | Paused | Recovered | Sound | Other

let recovery_slots = 24

let failed_recently ~now = function
  | None -> false
  | Some ({ slots; known_since = _ } : Pulse.pulse) ->
      let since = Pulse.slot_start now - ((recovery_slots - 1) * Pulse.slot_seconds) in
      List.exists (fun (slot : Pulse.slot) ->
        slot.starts_at >= since && slot.tally.failed + slot.tally.rested > 0) slots

let of_runtime ~now = function
  | None -> Other
  | Some (runtime : Decode.keeper_runtime) ->
      if runtime.kr_paused then Paused
      else match Decode.keeper_health_reading runtime.kr_health with
      | Decode.Health_failing ->
          let resting = match runtime.kr_runtime_path_rest with
            | Ok (Some (Decode.Path_rest_resting _)) -> true
            | Ok (Some (Decode.Path_rest_serving _)) | Ok None | Error _ -> false in
          Failing { resting }
      | Decode.Health_running | Decode.Health_idle ->
          if failed_recently ~now runtime.kr_recent_turns then Recovered else Sound
      | Decode.Health_offline ->
          if failed_recently ~now runtime.kr_recent_turns then Recovered else Other
