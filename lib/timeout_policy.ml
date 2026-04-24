module Layer = struct
  type t =
    | Tool
    | Oas_bridge
    | Keeper_turn
    | Keeper_cycle
    | Shutdown

  let to_string = function
    | Tool -> "tool"
    | Oas_bridge -> "oas_bridge"
    | Keeper_turn -> "keeper_turn"
    | Keeper_cycle -> "keeper_cycle"
    | Shutdown -> "shutdown"
end

module Deadline = struct
  type t = {
    layer : Layer.t;
    origin : string;
    wall_cap_s : float;
    set_at : float;
  }

  let make ~layer ~origin ~wall_cap_s ~now =
    { layer; origin; wall_cap_s; set_at = now }

  let elapsed t ~now = now -. t.set_at
  let remaining t ~now = t.wall_cap_s -. elapsed t ~now
end

let default_overshoot_slack_s = 5.0

let overshoot_warn ?(slack_s = default_overshoot_slack_s) ~deadline ~actual_wall_s () =
  let excess = actual_wall_s -. deadline.Deadline.wall_cap_s in
  if excess > slack_s then begin
    Log.Keeper.warn
      "timeout_policy: overshoot layer=%s origin=%s budget=%.1fs actual=%.1fs excess=%.1fs slack=%.1fs (cooperative-cancel miss; fiber likely blocked in uncancellable region)"
      (Layer.to_string deadline.Deadline.layer)
      deadline.Deadline.origin
      deadline.Deadline.wall_cap_s
      actual_wall_s
      excess
      slack_s;
    true
  end
  else
    false
