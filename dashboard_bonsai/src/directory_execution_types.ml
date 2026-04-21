open! Core

type diagnostic =
  { health_state : string option
  ; continuity_state : string option
  ; last_error : string option
  ; summary : string option
  ; keepalive_running : bool option
  }

type keeper =
  { name : string
  ; agent_name : string option
  ; status : string
  ; phase : string option
  ; pipeline_stage : string option
  ; paused : bool option
  ; model : string option
  ; active_model : string option
  ; active_model_label : string option
  ; last_model_used : string option
  ; last_model_used_label : string option
  ; context_ratio : float option
  ; context_tokens : int option
  ; context_max : int option
  ; generation : int option
  ; turn_count : int option
  ; last_turn_ago_s : float option
  ; last_autonomous_action_at : string option
  ; last_heartbeat : string option
  ; keepalive_running : bool option
  ; runtime_blocker_class : string option
  ; runtime_blocker_summary : string option
  ; runtime_blocker_continue_gate : bool option
  ; last_blocker : string option
  ; diagnostic : diagnostic option
  }

type response =
  { generated_at : string
  ; keepers : keeper list
  }

let fixture : response = { generated_at = ""; keepers = [] }

let string_field ?(default = "") json key =
  match Yojson.Safe.Util.member key json with
  | `String s -> s
  | _ -> default
;;

let string_opt_field json key =
  match Yojson.Safe.Util.member key json with
  | `String s ->
    let trimmed = String.strip s in
    if String.is_empty trimmed then None else Some trimmed
  | _ -> None
;;

let int_opt_field json key =
  match Yojson.Safe.Util.member key json with
  | `Int i -> Some i
  | `Intlit s -> Option.try_with (fun () -> Int.of_string s)
  | _ -> None
;;

let float_opt_field json key =
  match Yojson.Safe.Util.member key json with
  | `Float f -> Some f
  | `Int i -> Some (Float.of_int i)
  | `Intlit s -> Option.try_with (fun () -> Float.of_string s)
  | _ -> None
;;

let bool_opt_field json key =
  match Yojson.Safe.Util.member key json with
  | `Bool b -> Some b
  | _ -> None
;;

let list_field f json key =
  match Yojson.Safe.Util.member key json with
  | `List xs -> List.map xs ~f
  | _ -> []
;;

let diagnostic_of_yojson json =
  match json with
  | `Null -> None
  | _ ->
    Some
      { health_state = string_opt_field json "health_state"
      ; continuity_state = string_opt_field json "continuity_state"
      ; last_error = string_opt_field json "last_error"
      ; summary = string_opt_field json "summary"
      ; keepalive_running = bool_opt_field json "keepalive_running"
      }
;;

let keeper_of_yojson json =
  { name = string_field json "name"
  ; agent_name = string_opt_field json "agent_name"
  ; status = string_field json "status"
  ; phase = string_opt_field json "phase"
  ; pipeline_stage = string_opt_field json "pipeline_stage"
  ; paused = bool_opt_field json "paused"
  ; model = string_opt_field json "model"
  ; active_model = string_opt_field json "active_model"
  ; active_model_label = string_opt_field json "active_model_label"
  ; last_model_used = string_opt_field json "last_model_used"
  ; last_model_used_label = string_opt_field json "last_model_used_label"
  ; context_ratio = float_opt_field json "context_ratio"
  ; context_tokens = int_opt_field json "context_tokens"
  ; context_max = int_opt_field json "context_max"
  ; generation = int_opt_field json "generation"
  ; turn_count = int_opt_field json "turn_count"
  ; last_turn_ago_s = float_opt_field json "last_turn_ago_s"
  ; last_autonomous_action_at = string_opt_field json "last_autonomous_action_at"
  ; last_heartbeat = string_opt_field json "last_heartbeat"
  ; keepalive_running = bool_opt_field json "keepalive_running"
  ; runtime_blocker_class = string_opt_field json "runtime_blocker_class"
  ; runtime_blocker_summary = string_opt_field json "runtime_blocker_summary"
  ; runtime_blocker_continue_gate =
      bool_opt_field json "runtime_blocker_continue_gate"
  ; last_blocker = string_opt_field json "last_blocker"
  ; diagnostic =
      diagnostic_of_yojson (Yojson.Safe.Util.member "diagnostic" json)
  }
;;

let response_of_yojson json =
  { generated_at = string_field json "generated_at"
  ; keepers = list_field keeper_of_yojson json "keepers"
  }
;;
