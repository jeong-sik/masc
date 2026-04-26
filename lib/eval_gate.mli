(** Eval_gate — Pre/Post execution gates for Keeper tool calls.

    Multi-layer defense (Swiss Cheese Model):
    1. Cost budget check
    2. Destructive operation detection
    3. Tool allowlist
    4. Entropy check *)

(** {1 Configuration} *)

type gate_config =
  { max_cost_usd : float
  ; max_tool_calls_per_turn : int
  ; entropy_threshold : int
  ; destructive_check_enabled : bool
  ; allowlist_enabled : bool
  ; allowed_tools : string list
  ; denied_tools : string list
  }

val gate_config_to_yojson : gate_config -> Yojson.Safe.t
val gate_config_of_yojson : Yojson.Safe.t -> (gate_config, string) result
val default_config : gate_config

(** {1 Destructive detection} *)

(** Normalize a shell command for pattern matching. *)
val normalize_command : string -> string

(** The canonical 19-entry substring pattern catalogue used by
    [detect_destructive]. Exposed so the AST shadow classifier
    (see [Worker_dev_tools.classify_destructive]) can enforce
    a covenant that every pattern maps to a typed class. *)
val destructive_patterns : (string * string) list

(** Returns [(pattern, description)] if command matches a destructive pattern. *)
val detect_destructive : string -> (string * string) option

(** Returns [(indicator, description)] if command shows evasion attempt. *)
val detect_evasion : string -> (string * string) option

(** {1 Pre-execution gate} *)

val pre_check
  :  config:gate_config
  -> accumulated_cost:float
  -> trajectory_acc:Trajectory.accumulator option
  -> tool_name:string
  -> args_json:string
  -> Trajectory.gate_decision

(** {1 Post-execution evaluation} *)

type post_eval_result =
  { has_error : bool
  ; error_message : string option
  ; cost_usd : float
  ; should_warn : bool
  ; warning : string option
  }

val post_eval_result_to_yojson : post_eval_result -> Yojson.Safe.t

val post_eval
  :  config:gate_config
  -> tool_name:string
  -> result:string
  -> duration_ms:int
  -> accumulated_cost:float
  -> post_eval_result

(** {1 JSON serialization (legacy aliases)} *)

val gate_config_to_json : gate_config -> Yojson.Safe.t
val post_eval_to_json : post_eval_result -> Yojson.Safe.t

(** {1 Guarded execution} *)

val guarded_execute
  :  config:gate_config
  -> accumulated_cost:float
  -> trajectory_acc:Trajectory.accumulator option
  -> tool_name:string
  -> args_json:string
  -> execute:(unit -> string)
  -> Trajectory.gate_decision * string option * post_eval_result option * int
