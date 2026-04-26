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
  ;;
end

module Deadline = struct
  type t =
    { layer : Layer.t
    ; origin : string
    ; wall_cap_s : float
    ; set_at : float
    }

  let make ~layer ~origin ~wall_cap_s ~now = { layer; origin; wall_cap_s; set_at = now }
  let elapsed t ~now = now -. t.set_at
  let remaining t ~now = t.wall_cap_s -. elapsed t ~now
end

let default_overshoot_slack_s = 5.0

(* #9662: counter for cooperative-cancel overshoot events.

   The 2026-04-23 production trace observed [keeper_llm_bridge]
   timing out at 596.6s against a 573s budget — a 23.6s overshoot.
   Eio's cooperative cancellation only fires at the next yield, so
   a fiber blocked inside an uncancellable region (native HTTP
   read, syscall, non-yielding loop) keeps running past the
   [with_timeout_exn] deadline.  The WARN log already surfaces
   the excess; this counter lets operators alert on the rate
   without log scraping and attribute overshoots to a specific
   [(layer, origin)] pair.

   Labels:
     [layer]  : Layer.to_string output (oas_bridge / tool /
                keeper_turn / keeper_cycle / shutdown)
     [origin] : free-form site name passed by caller (e.g.,
                "keeper_llm_bridge", a tool name).  Caller
                discipline keeps cardinality bounded — origin
                strings are intended to be small, named sites,
                not user-supplied identifiers.

   Cardinality: ~5 layers × ~20 origins = ~100 series. *)
let metric_overshoot_total = Prometheus.metric_timeout_policy_overshoot

let overshoot_warn ?(slack_s = default_overshoot_slack_s) ~deadline ~actual_wall_s () =
  let excess = actual_wall_s -. deadline.Deadline.wall_cap_s in
  if excess > slack_s
  then (
    Log.Keeper.warn
      "timeout_policy: overshoot layer=%s origin=%s budget=%.1fs actual=%.1fs \
       excess=%.1fs slack=%.1fs (cooperative-cancel miss; fiber likely blocked in \
       uncancellable region)"
      (Layer.to_string deadline.Deadline.layer)
      deadline.Deadline.origin
      deadline.Deadline.wall_cap_s
      actual_wall_s
      excess
      slack_s;
    Prometheus.inc_counter
      metric_overshoot_total
      ~labels:
        [ "layer", Layer.to_string deadline.Deadline.layer
        ; "origin", deadline.Deadline.origin
        ]
      ();
    true)
  else false
;;
