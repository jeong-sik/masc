type t =
  | Docker_run
  | Native_shell
  | Tool_dispatch
  | Llm_call
  | Other of string

let to_string = function
  | Docker_run -> "docker_run"
  | Native_shell -> "native_shell"
  | Tool_dispatch -> "tool_dispatch"
  | Llm_call -> "llm_call"
  | Other name -> name
;;

let default_sec = function
  | Docker_run -> 20.0
  | Native_shell -> 5.0
  | Tool_dispatch -> 15.0
  | Llm_call -> 1.0
  | Other _ -> 1.0
;;

let clamp floor value =
  Float.max (default_sec floor) value
;;

let is_load_bearing = function
  | Docker_run | Native_shell | Tool_dispatch -> true
  | Llm_call | Other _ -> false
;;
