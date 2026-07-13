type target_type =
  | Workspace
  | Keeper
  | Goal

let target_type_to_string = function
  | Workspace -> "workspace"
  | Keeper -> "keeper"
  | Goal -> "goal"
;;

let target_type_of_string = function
  | "workspace" -> Some Workspace
  | "keeper" -> Some Keeper
  | "goal" -> Some Goal
  | _ -> None
;;

let all_target_types = [ Workspace; Keeper; Goal ]
let valid_target_type_strings = List.map target_type_to_string all_target_types
let workspace_target_type = target_type_to_string Workspace
let keeper_target_type = target_type_to_string Keeper
let goal_target_type = target_type_to_string Goal
let workspace_target_type_error = "target_type must be " ^ workspace_target_type

let invalid_target_type_message =
  "target_type must be one of: " ^ String.concat ", " valid_target_type_strings
;;

let keeper_recover = "keeper_recover"
