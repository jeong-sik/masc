(** Product-owned operator action vocabulary.

    A closed set of names and, for each, the kind of target it addresses. It
    assigns no authorization category or AGENT_CORE approval policy. Every
    accepted action uses the same explicit confirmation flow. *)

type t =
  | Broadcast
  | Namespace_pause
  | Namespace_resume
  | Task_inject
  | Keeper_message
  | Keeper_probe
  | Keeper_recover
[@@deriving enumerate]

let to_string = function
  | Broadcast -> "broadcast"
  | Namespace_pause -> "namespace_pause"
  | Namespace_resume -> "namespace_resume"
  | Task_inject -> "task_inject"
  | Keeper_message -> "keeper_message"
  | Keeper_probe -> "keeper_probe"
  | Keeper_recover -> Operator_action_constants.keeper_recover
;;

(* Read off [to_string] and the derived [all], so a new action is parsed as
   soon as it has a name. *)
let of_string raw = List.find_opt (fun action -> String.equal (to_string action) raw) all

let target_type = function
  | Broadcast | Namespace_pause | Namespace_resume | Task_inject ->
    Operator_action_constants.Workspace
  | Keeper_message | Keeper_probe | Keeper_recover -> Operator_action_constants.Keeper
;;

let target_type_string action =
  Operator_action_constants.target_type_to_string (target_type action)
;;

let strings = List.map to_string all

(* Confirmation is uniform, not inferred from a subjective action class. *)
let requires_confirmation (_ : t) = true
