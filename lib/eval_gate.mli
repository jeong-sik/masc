(** Eval_gate — Pre/Post execution gates for Keeper tool calls.

    Multi-layer defense (Swiss Cheese Model):
    1. Destructive operation detection
    2. Tool allowlist
    3. Entropy check

    Cost thresholds are advisory telemetry only and must not reject execution. *)

(** {1 Configuration} *)

type gate_config = {
  max_cost_usd : float;
  (** Advisory cost threshold used for reporting/warnings only. *)
  max_tool_calls_per_turn : int;
  entropy_threshold : int;
  destructive_check_enabled : bool;
  allowlist_enabled : bool;
  allowed_tools : string list;
  denied_tools : string list;
}

val gate_config_to_yojson : gate_config -> Yojson.Safe.t
val gate_config_of_yojson : Yojson.Safe.t -> (gate_config, string) result

val default_config : gate_config

(** {1 Destructive detection} *)

val normalize_command : string -> string
(** Normalize a shell command for pattern matching. *)

val detect_destructive :
  Destructive_ops_policy.t -> string -> (string * string) option
(** Returns [(pattern, description)] if command matches a destructive
    pattern from the supplied policy. The policy is passed explicitly
    so enforcement never depends on a hard-coded module-level catalogue. *)

(** Closed taxonomy of shell-evasion meta-patterns detected by
    {!detect_evasion_typed} / {!detect_evasion}.  New entries force the
    type + the [evasion_indicators] catalogue to update in lockstep —
    no runtime drift surface. *)
type evasion_kind =
  | Variable_expansion
  | Hex_escape
  | Octal_escape
  | Base64_decode_pipe
  | Eval_invocation
  | Xargs_destructive

val evasion_kind_to_string : evasion_kind -> string
(** Snake_case rendering for log / metric emission.  Pinned wording —
    do not change without synchronizing with future telemetry. *)

type evasion_indicator = {
  kind : evasion_kind;
  pattern : string;
  description : string;
}

val detect_evasion_typed : string -> evasion_indicator option
(** Returns the full typed indicator (kind + regex + description) for
    the first match.  Use this when the caller needs to discriminate
    by kind; {!detect_evasion} drops the kind for backward-compatible
    string-tuple returns. *)

val detect_evasion : string -> (string * string) option
(** Returns [(pattern, description)] if command shows evasion attempt.
    Thin wrapper over {!detect_evasion_typed} that drops the typed
    kind — preserved for callers that consume the string-tuple shape. *)

val extract_all_strings_from_json : string -> string option
(** Concatenate every string leaf of a JSON args payload for destructive-pattern
    scanning. [None] when [json_str] is unparseable — RFC-0305: the caller must
    fail closed rather than scan an empty string, which would let a malformed
    args payload skip the destructive check. *)

(** {1 Pre-execution gate} *)

val pre_check :
  config:gate_config ->
  destructive_ops_policy:Destructive_ops_policy.t ->
  accumulated_cost:float ->
  trajectory_acc:Trajectory.accumulator option ->
  tool_name:string ->
  args_json:string ->
  Trajectory.gate_decision

(** {1 Post-execution evaluation} *)

type post_eval_result = {
  has_error : bool;
  error_message : string option;
  cost_usd : float;
  should_warn : bool;
  warning : string option;
}

val post_eval_result_to_yojson : post_eval_result -> Yojson.Safe.t

val post_eval :
  config:gate_config ->
  tool_name:string ->
  result:string ->
  duration_ms:int ->
  accumulated_cost:float ->
  post_eval_result

(** {1 Guarded execution} *)

val guarded_execute :
  config:gate_config ->
  destructive_ops_policy:Destructive_ops_policy.t ->
  accumulated_cost:float ->
  trajectory_acc:Trajectory.accumulator option ->
  tool_name:string ->
  args_json:string ->
  execute:(unit -> string) ->
  Trajectory.gate_decision * string option * post_eval_result option * int
