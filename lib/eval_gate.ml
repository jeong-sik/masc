(** Eval_gate — Pre/Post execution gates for Keeper tool calls.

    Multi-layer defense (Swiss Cheese Model):
    1. Destructive operation detection — reject bash commands with rm/drop/etc.
    2. Tool allowlist — reject tools not in keeper's permitted set
    3. Entropy check — reject if same tool called N+ times consecutively

    Cost thresholds are advisory telemetry only and must not reject execution.

    Each gate check is independent: any single rejection blocks execution.
    This prevents a failure in one layer from being masked by another.

    @since 2.73.0 *)

(** Cost warning ratio (80%% of budget). Standard capacity planning threshold. *)
let eval_cost_warn_ratio = 0.8

(* ================================================================ *)
(* Configuration                                                     *)
(* ================================================================ *)

type gate_config = {
  max_cost_usd : float;
  (** Per-session advisory cost threshold.
      Default 0.50 USD. Based on observed MASC keeper sessions averaging
      $0.02-0.15 per session (local llama + GLM fallback). 0.50 is ~3x the
      worst-case observed session cost. This value may drive warnings and
      reporting, but never gates tool execution. *)

  max_tool_calls_per_turn : int;
  (** Max tool calls in a single LLM turn (before yielding control).
      Default 10. Claude/GPT typically issue 1-5 tool calls per turn in
      agentic loops. 10 provides 2x headroom. Beyond 10, the agent is
      likely in a retry loop or stuck — better to force a new turn for
      fresh reasoning. *)

  entropy_threshold : int;
  (** Consecutive calls to the same tool before triggering a rejection.
      Default 3. Empirically, 2 consecutive identical calls is common
      (retry after transient failure). 3+ usually indicates a stuck loop
      (e.g., repeatedly calling masc_status with no state change).
      Set higher for tools with legitimate repeated use (e.g., broadcast). *)

  destructive_check_enabled : bool; (** Check bash commands for destructive patterns *)
  allowlist_enabled : bool;         (** Enforce tool allowlist *)
  allowed_tools : string list;      (** Empty = all tools allowed *)
  denied_tools : string list;       (** Explicit deny list (overrides allow) *)
} [@@deriving yojson { strict = false }]

let default_config : gate_config = {
  max_cost_usd = 0.50;
  max_tool_calls_per_turn = 10;
  entropy_threshold = 3;
  destructive_check_enabled = true;
  allowlist_enabled = false;
  allowed_tools = [];
  denied_tools = [];
}

type tool_policy = {
  allowed : string list;
  denied : string list;
  allowlist_enabled : bool;
}

let tool_policy_of_config (config : gate_config) =
  {
    allowed = config.allowed_tools;
    denied = config.denied_tools;
    allowlist_enabled = config.allowlist_enabled;
  }

(* ================================================================ *)
(* Destructive pattern detection                                     *)
(* ================================================================ *)

(** Convert a loaded policy into the (substring, description) list
    used by [detect_destructive].  Drops the typed class field because
    this layer only needs (substring, desc) for its return shape;
    callers that need the class go through [Shell_safety_types.classify_destructive]
    over [Destructive_ops_policy.patterns]. *)
let patterns_of_policy (policy : Destructive_ops_policy.t) : (string * string) list =
  List.map
    (fun { Shell_safety_types.pattern; description; class_ = _ } ->
       pattern, description)
    (Destructive_ops_policy.patterns policy)

(** Normalize a command string for pattern matching.
    Strips inline single/double quotes and collapses whitespace.
    This catches simple evasion like 'r''m' '-rf' or r"m" -rf
    without requiring full shell AST parsing.

    Known limitations (documented in test_eval_gate_evasion.ml):
    - Variable expansion ($\{IFS\}, $cmd) is not resolved
    - Hex/octal escapes (\\x72\\x6d) are not decoded
    - Command substitution ($(echo rm)) is not evaluated *)
let normalize_command (cmd : string) : string =
  let buf = Buffer.create (String.length cmd) in
  let in_single = ref false in
  let in_double = ref false in
  let last_was_space = ref false in
  String.iter (fun c ->
    match c with
    | '\'' when not !in_double ->
      in_single := not !in_single
    | '"' when not !in_single ->
      in_double := not !in_double
    | ' ' | '\t' | '\n' | '\r' ->
      if not !last_was_space then begin
        Buffer.add_char buf ' ';
        last_was_space := true
      end
    | '\\' -> ()  (* strip backslash escapes *)
    | _ ->
      Buffer.add_char buf c;
      last_was_space := false
  ) cmd;
  String.trim (Buffer.contents buf)

(** Closed taxonomy of shell-evasion meta-patterns.  Each kind names a
    construct that could hide destructive intent from
    {!detect_destructive}'s substring matching; the regex + description
    live together in {!evasion_indicators} so a new entry forces the
    type + the list to update in lockstep (compiler-enforced, not
    runtime-test-enforced).

    Drift surface previously: a [(string * string) list] of (regex,
    desc) with no compile-time guarantee that every kind documented
    in the function comment had a corresponding entry. *)
type evasion_kind =
  | Variable_expansion
  | Hex_escape
  | Octal_escape
  | Base64_decode_pipe
  | Eval_invocation
  | Xargs_destructive

let evasion_kind_to_string = function
  | Variable_expansion -> "variable_expansion"
  | Hex_escape -> "hex_escape"
  | Octal_escape -> "octal_escape"
  | Base64_decode_pipe -> "base64_decode_pipe"
  | Eval_invocation -> "eval_invocation"
  | Xargs_destructive -> "xargs_destructive"

type evasion_indicator = {
  kind : evasion_kind;
  pattern : string;
  description : string;
}

(** Suspicious shell meta-patterns that indicate possible evasion
    attempts.  Each entry binds a typed {!evasion_kind} to its regex
    + operator-visible description.  Checked on the raw
    (un-normalized) command to catch patterns that normalization
    would strip. *)
let evasion_indicators : evasion_indicator list = [
  { kind = Variable_expansion;
    pattern = {|\$[({]|};
    description = "variable expansion or command substitution" };
  { kind = Hex_escape;
    pattern = {|\\x[0-9a-fA-F]|};
    description = "hex escape sequence" };
  { kind = Octal_escape;
    pattern = {|\\[0-7][0-7]|};
    description = "octal escape sequence" };
  { kind = Base64_decode_pipe;
    pattern = {|base64.*-d|};
    description = "base64 decode pipe (possible payload obfuscation)" };
  { kind = Eval_invocation;
    pattern = {|eval |};
    description = "eval invocation (arbitrary code execution)" };
  { kind = Xargs_destructive;
    pattern = {|xargs.*rm|xargs.*kill|};
    description = "xargs with destructive command" };
]

(** Check for shell evasion indicators in the raw (un-normalized) command.
    Returns Some(pattern, description) if a suspicious construct is found.
    This supplements [detect_destructive] by catching meta-patterns that
    normalization-based substring matching cannot handle.

    Preserves the existing [(pattern, description)] return shape for
    callers that render the matched substring. The typed kind is
    available via {!detect_evasion_typed} for callers that need to
    discriminate. *)
(** Precompile each evasion pattern once at module load.  [detect_evasion_typed]
    runs in the pre-check gate for every shell tool invocation; the previous
    code recompiled all {!evasion_indicators} patterns ([Re.Pcre.re |> Re.compile])
    on every call.  Pairing the compiled regex with its indicator keeps the
    typed return value unchanged and matches the module-level-compile idiom used
    by [drift_guard] / [cache_eio]. *)
let compiled_evasion_indicators : (Re.re * evasion_indicator) list =
  List.map
    (fun (indicator : evasion_indicator) ->
      (Re.Pcre.re indicator.pattern |> Re.compile, indicator))
    evasion_indicators

let detect_evasion_typed (command : string) : evasion_indicator option =
  let cmd_lower = String.lowercase_ascii command in
  List.find_map
    (fun (re, indicator) ->
      if Safe_ops.protect ~default:false (fun () -> Re.execp re cmd_lower)
      then Some indicator
      else None)
    compiled_evasion_indicators

let detect_evasion (command : string) : (string * string) option =
  match detect_evasion_typed command with
  | None -> None
  | Some { pattern; description; _ } -> Some (pattern, description)

(** Check if a bash command contains destructive patterns.
    Returns None if safe, Some(pattern, description) if dangerous.

    Two-pass detection:
    1. Normalized substring matching against [destructive_patterns]
    2. Raw regex matching against [evasion_indicators] for meta-patterns
       that normalization cannot catch (hex escapes, variable expansion, etc.)

    Both passes must clear for the command to be considered safe. *)
let detect_destructive (policy : Destructive_ops_policy.t) (command : string)
  : (string * string) option
  =
  if not (Destructive_ops_policy.enabled policy) then None
  else
    let cmd_lower = String.lowercase_ascii (normalize_command command) in
    match
      List.find_opt (fun (pattern, _desc) ->
        String_util.contains_substring_ci cmd_lower pattern)
        (patterns_of_policy policy)
    with
    | Some _ as hit -> hit
    | None -> detect_evasion command

(* ================================================================ *)
(* Pre-execution gate                                                *)
(* ================================================================ *)

(** Run all pre-execution checks. Returns Pass or Reject with reason.

    The checks run in order of cheapest-to-evaluate first:
    1. Deny list (O(n) string compare)
    2. Allowlist (O(n) string compare)
    3. Turn call limit (int compare)
    4. Entropy (list scan)
    5. Destructive pattern (string scan, only for bash tools)

    Cost is telemetry-only and is intentionally not checked here.

    First rejection wins — remaining checks are skipped. *)

(* RFC-0305: return [None] on unparseable JSON rather than [""].  The caller
   scans the result for destructive patterns; collapsing a parse failure to an
   empty string let a malformed args payload skip the destructive check
   (no match on ""), which is fail-open for a bash-capable tool.  A malformed
   args_json on a destructive tool is already abnormal, so the caller rejects
   it fail-closed. *)
let extract_all_strings_from_json (json_str : string) : string option =
  try
    let rec go = function
      | `String s -> s
      | `List lst -> String.concat " " (List.map go lst)
      | `Assoc fields -> String.concat " " (List.map (fun (_, v) -> go v) fields)
      | _ -> ""
    in
    Some (go (Yojson.Safe.from_string json_str))
  with Yojson.Json_error _ -> None

let pre_check
    ~(config : gate_config)
    ~(destructive_ops_policy : Destructive_ops_policy.t)
    ~(accumulated_cost : float)
    ~(trajectory_acc : Trajectory.accumulator option)
    ~(tool_name : string)
    ~(args_json : string)
  : Trajectory.gate_decision =
  ignore accumulated_cost;

  let tool_policy = tool_policy_of_config config in
  let deny_hit = List.mem tool_name tool_policy.denied in
  let allow_hit =
    not tool_policy.allowlist_enabled
    || tool_policy.allowed = []
    || List.mem tool_name tool_policy.allowed
  in

  (* 1. Shared allow/deny policy *)
  if deny_hit then
    Trajectory.Reject (Printf.sprintf "tool '%s' is in deny list" tool_name)
  else if not allow_hit then
    Trajectory.Reject (Printf.sprintf "tool '%s' not in allowlist" tool_name)

  (* 2. Turn call limit *)
  else begin
    match trajectory_acc with
    | Some acc ->
        let calls_this_turn = Trajectory.calls_in_current_turn acc in
        if calls_this_turn >= config.max_tool_calls_per_turn then
          Trajectory.Reject (Printf.sprintf "turn call limit: %d >= %d max"
            calls_this_turn config.max_tool_calls_per_turn)
        else
          (* 5. Entropy detection *)
          let entropy = Trajectory.detect_entropy ~threshold:config.entropy_threshold
            ~args_json acc tool_name in
          begin match entropy with
          | Some (_name, count) ->
              let args_preview_opt =
                try
                  let json = Yojson.Safe.from_string args_json in
                  Observability_redact.redact_tool_input ~tool_name json
                with Yojson.Json_error _ ->
                  Some (Observability_redact.redact_preview args_json)
              in
              let reason = match args_preview_opt with
                | None ->
                    Printf.sprintf
                      "entropy detected: '%s' called %d consecutive times (threshold: %d)"
                      tool_name count config.entropy_threshold
                | Some args_preview ->
                    Printf.sprintf
                      "entropy detected: '%s' called %d consecutive times with args=%s (threshold: %d)"
                      tool_name count args_preview config.entropy_threshold
              in
              Trajectory.Reject reason
          | None ->
              (* 6. Destructive pattern check (bash tools only) *)
              if config.destructive_check_enabled
                 && Tool_capability.has Tool_capability.Destructive tool_name then
                (match extract_all_strings_from_json args_json with
                 | None ->
                     (* RFC-0305: unparseable args on a destructive tool cannot
                        be screened — fail closed rather than scan "". *)
                     Trajectory.Reject (Printf.sprintf
                       "unparseable args for destructive tool '%s' (fail-closed)"
                       tool_name)
                 | Some cmd_str ->
                     begin match detect_destructive destructive_ops_policy cmd_str with
                     | Some (pattern, desc) ->
                         Trajectory.Reject (Printf.sprintf
                           "destructive pattern in %s: '%s' (%s)" tool_name pattern desc)
                     | None -> Trajectory.Pass
                     end)
              else
                Trajectory.Pass
          end
    | None ->
        (* No trajectory accumulator — skip entropy and turn-limit checks *)
        if config.destructive_check_enabled
           && Tool_capability.has Tool_capability.Destructive tool_name then
          (* Reuse [extract_all_strings_from_json] (was a duplicated inline
             extractor); RFC-0305: [None] on unparseable args → fail closed. *)
          (match extract_all_strings_from_json args_json with
           | None ->
               Trajectory.Reject (Printf.sprintf
                 "unparseable args for destructive tool '%s' (fail-closed)"
                 tool_name)
           | Some cmd_str ->
               begin match detect_destructive destructive_ops_policy cmd_str with
               | Some (pattern, desc) ->
                   Trajectory.Reject (Printf.sprintf
                     "destructive pattern in %s: '%s' (%s)" tool_name pattern desc)
               | None -> Trajectory.Pass
               end)
        else
          Trajectory.Pass
  end

(* ================================================================ *)
(* Post-execution evaluation                                         *)
(* ================================================================ *)

type post_eval_result = {
  has_error : bool;
  error_message : string option;
  cost_usd : float;
  should_warn : bool;      (** true if result is suspicious but not fatal *)
  warning : string option;
} [@@deriving to_yojson]

(** Evaluate a tool call result after execution.
    Returns evaluation metadata for trajectory recording. *)
let post_eval
    ~(config : gate_config)
    ~(tool_name : string)
    ~(result : string)
    ~(duration_ms : int)
    ~(accumulated_cost : float)
    : post_eval_result =

  let cost = Trajectory.tool_cost_estimate tool_name in

  (* Check for error indicators in result *)
  let has_error =
    try
      let json = Yojson.Safe.from_string result in
      (match Json_util.assoc_member_opt "error" json with
       | Some `Null -> false
       | Some (`String "") -> false
       | Some (`String _) -> true
       | _ -> false)
    with Yojson.Json_error _ -> false
  in

  let error_message =
    if has_error then
      try
        let json = Yojson.Safe.from_string result in
        match Safe_ops.json_string_opt "error" json with
        | Some s -> Some s
        | None -> Some "unknown error in result"
      with Yojson.Json_error _ -> Some "unknown error in result"
    else None
  in

  (* Warn if approaching advisory cost threshold.
     80%% threshold: standard practice from capacity planning (e.g., disk usage
     alerts at 80%%). Gives ~20%% remaining budget for the agent to wrap up
     gracefully. This is not a hard wall. *)
  let new_cost = accumulated_cost +. cost in
  let cost_warn_ratio = eval_cost_warn_ratio in
  let approaching_limit =
    config.max_cost_usd > 0.0 && new_cost >= config.max_cost_usd *. cost_warn_ratio
  in
  let should_warn = approaching_limit in
  let warning =
    if approaching_limit then
      Some (Printf.sprintf "approaching advisory cost threshold: $%.4f / $%.4f (%.0f%%)"
        new_cost config.max_cost_usd (new_cost /. config.max_cost_usd *. 100.0))
    else None
  in

  (* Warn on unusually long execution.
     30s threshold: most MASC tool calls complete in <5s (workspace ops, broadcasts).
     The slowest normal operations (Neo4j queries, runtime LLM calls) take 10-20s.
     30s indicates either a hung connection or an unexpectedly large operation
     that may be consuming shared resources. *)
  let slow_threshold_ms = 30_000 in
  let slow_warn =
    if duration_ms > slow_threshold_ms then
      Some (Printf.sprintf "slow tool execution: %s took %dms" tool_name duration_ms)
    else None
  in

  let combined_warning =
    match warning, slow_warn with
    | Some w1, Some w2 -> Some (w1 ^ "; " ^ w2)
    | Some w, None | None, Some w -> Some w
    | None, None -> None
  in

  { has_error;
    error_message;
    cost_usd = cost;
    should_warn = should_warn || (duration_ms > slow_threshold_ms);
    warning = combined_warning;
  }

(* ================================================================ *)
(* JSON serialization                                                *)
(* ================================================================ *)

(* ================================================================ *)
(* Convenience: wrap execute with pre+post gate                      *)
(* ================================================================ *)

(** Wrap a tool execution function with pre-check and post-eval.
    Returns (gate_decision, result option, post_eval option, duration_ms).

    If pre-check rejects, the execution function is never called.
    This is the main integration point for keeper_tool_surface.ml. *)
let guarded_execute
    ~(config : gate_config)
    ~(destructive_ops_policy : Destructive_ops_policy.t)
    ~(accumulated_cost : float)
    ~(trajectory_acc : Trajectory.accumulator option)
    ~(tool_name : string)
    ~(args_json : string)
    ~(execute : unit -> string)
    : Trajectory.gate_decision * string option * post_eval_result option * int =

  let decision = pre_check ~config ~destructive_ops_policy ~accumulated_cost
    ~trajectory_acc ~tool_name ~args_json in

  let record_trajectory ~gate_decision ~result ~error ~duration_ms =
    match trajectory_acc with
    | None -> ()
    | Some acc ->
        let now = Time_compat.now () in
        let entry : Trajectory.tool_call_entry = {
          ts = now;
          ts_iso = Types_core.iso8601_of_unix_seconds now;
          turn = acc.turn;
          round = Trajectory.calls_in_current_turn acc + 1;
          tool_name;
          args_json;
          gate_decision;
          result;
          duration_ms;
          error;
          cost_usd = Trajectory.tool_cost_estimate tool_name;
          (* RFC-0233: this gate path has no paired tool_calls row to join
             against; id adoption for worker-gate executions is deferred. *)
          execution_id = None;
        } in
        Trajectory.record_entry acc entry
  in

  match decision with
  | Trajectory.Reject _reason ->
      record_trajectory ~gate_decision:decision ~result:None ~error:None
        ~duration_ms:0;
      (decision, None, None, 0)
  | Trajectory.Pass ->
      let t0 = Time_compat.now () in
      let error_ref = ref None in
      let result =
        try execute ()
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          let msg = Printexc.to_string exn in
          error_ref := Some msg;
          (* Caught tool-execution exception (Cancelled is re-raised above):
             degraded-with-recovery — the gate records the error and returns an
             error result — so [Warn], not [Info]
             (docs/spec/18-log-severity-taxonomy.md § 2). *)
          Log.Harness.warn "eval_gate tool %s failed: %s" tool_name msg;
          Yojson.Safe.to_string (`Assoc [
            ("error", `String "Tool execution failed (internal error)");
            ("tool", `String tool_name);
          ])
      in
      let t1 = Time_compat.now () in
      let duration_ms = int_of_float ((t1 -. t0) *. 1000.0) in

      record_trajectory ~gate_decision:decision ~result:(Some result)
        ~error:!error_ref ~duration_ms;

      let eval = post_eval ~config ~tool_name ~result ~duration_ms
        ~accumulated_cost in

      (decision, Some result, Some eval, duration_ms)
