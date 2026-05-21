(** Task-state probing detection for keeper_bash command-shape guidance. *)

let mentions_task_state_file =
  Keeper_shell_bash_task_state.command_mentions_task_state_file
;;

let looks_like_http_probe =
  Keeper_shell_bash_task_state.command_looks_like_task_state_http_probe
;;

let looks_like_discovery =
  Keeper_shell_bash_task_state.command_looks_like_task_state_discovery
;;

let hint = Keeper_shell_bash_task_state.task_state_shell_hint
let alternatives = Keeper_shell_bash_task_state.task_state_shell_alternatives
