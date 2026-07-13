(** Product-owned operator action vocabulary.

    This module is only a closed parser/serializer for the MASC operator
    surface. It assigns no authorization category or OAS approval policy.
    Every accepted action uses the same explicit confirmation flow. *)

type t =
  | Broadcast
  | Namespace_pause
  | Namespace_resume
  | Social_sweep
  | Keeper_message
  | Keeper_probe
  | Keeper_recover
  | Task_inject

let to_string = function
  | Broadcast -> "broadcast"
  | Namespace_pause -> "namespace_pause"
  | Namespace_resume -> "namespace_resume"
  | Social_sweep -> "social_sweep"
  | Keeper_message -> "keeper_message"
  | Keeper_probe -> "keeper_probe"
  | Keeper_recover -> Operator_action_constants.keeper_recover
  | Task_inject -> "task_inject"
;;

let of_string = function
  | "broadcast" -> Some Broadcast
  | "namespace_pause" -> Some Namespace_pause
  | "namespace_resume" -> Some Namespace_resume
  | "social_sweep" -> Some Social_sweep
  | "keeper_message" -> Some Keeper_message
  | "keeper_probe" -> Some Keeper_probe
  | action when String.equal action Operator_action_constants.keeper_recover ->
    Some Keeper_recover
  | "task_inject" -> Some Task_inject
  | _ -> None
;;

let all =
  [ Broadcast
  ; Namespace_pause
  ; Namespace_resume
  ; Social_sweep
  ; Keeper_message
  ; Keeper_probe
  ; Keeper_recover
  ; Task_inject
  ]
;;

let strings = List.map to_string all
let is_allowed action = Option.is_some (of_string action)

(* Confirmation is uniform, not inferred from a subjective action class. *)
let requires_confirmation action = is_allowed action
