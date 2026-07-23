(** Keeper lifecycle phase variant + bijection helpers.

    SSOT for the lifecycle phase enum referenced by the
    [Keeper_state_machine] FSM, dashboard UI, persona audits, and
    operator-facing keeper status surfaces. Verbatim extract from the
    head of [Keeper_state_machine]; the parent retains a transparent
    variant alias so existing exhaustive matches at ~109 call sites
    continue to type-check unchanged.

    Pure variant + total bijection (modulo unknown-string -> None on
    parse). No FSM transitions or entry actions live here — those
    stay in the parent because they depend on [conditions] / [event]
    types still under iteration. *)

type phase =
  | Offline
  | Running
  | Failing
  | Overflowed
  | Compacting
  | HandingOff
  | Draining
  | Paused
  | Stopped
  | Crashed
  | Restarting
  | Dead

let phase_to_string = function
  | Offline -> "offline"
  | Running -> "running"
  | Failing -> "failing"
  | Overflowed -> "overflowed"
  | Compacting -> "compacting"
  | HandingOff -> "handing_off"
  | Draining -> "draining"
  | Paused -> "paused"
  | Stopped -> "stopped"
  | Crashed -> "crashed"
  | Restarting -> "restarting"
  | Dead -> "dead"
;;

let phase_of_string = function
  | "offline" -> Some Offline
  | "running" -> Some Running
  | "failing" -> Some Failing
  | "overflowed" -> Some Overflowed
  | "compacting" -> Some Compacting
  | "handing_off" -> Some HandingOff
  | "draining" -> Some Draining
  | "paused" -> Some Paused
  | "stopped" -> Some Stopped
  | "crashed" -> Some Crashed
  | "restarting" -> Some Restarting
  | "dead" -> Some Dead
  | _ -> None
;;

let all_phases =
  [ Offline
  ; Running
  ; Failing
  ; Overflowed
  ; Compacting
  ; HandingOff
  ; Draining
  ; Paused
  ; Stopped
  ; Crashed
  ; Restarting
  ; Dead
  ]
;;
