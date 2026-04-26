(** Eval_gate — Pre/Post execution gates for Keeper tool calls.

    Multi-layer defense (Swiss Cheese Model):
    1. Cost budget check — reject if accumulated cost exceeds limit
    2. Destructive operation detection — reject bash commands with rm/drop/etc.
    3. Tool allowlist — reject tools not in keeper's permitted set
    4. Entropy check — reject if same tool called N+ times consecutively

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
  (** Per-session cost limit.
      Default 0.50 USD. Based on observed MASC keeper sessions averaging
      $0.02-0.15 per session (local llama + GLM fallback). 0.50 is ~3x the
      worst-case observed session cost, providing headroom without allowing
      runaway spending. Adjust upward if using expensive cloud models directly. *)

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

let tool_policy_of_config (config : gate_config) =
  let allow =
    if config.allowlist_enabled && config.allowed_tools <> [] then
      Tool_access_policy.Names config.allowed_tools
    else
      Tool_access_policy.All
  in
  {
    Tool_access_policy.allow;
    deny = Tool_access_policy.Names config.denied_tools;
  }

(* ================================================================ *)
(* Destructive pattern detection                                     *)
(* ================================================================ *)

(** Known destructive shell patterns.
    Each entry is (pattern, description) — pattern is matched against
    the command string after basic normalization. *)
let destructive_patterns : (string * string) list = [
  ("rm -rf", "recursive forced deletion");
  ("rm -r", "recursive deletion");
  ("rmdir", "directory removal");
  ("drop table", "SQL table drop");
  ("drop database", "SQL database drop");
  ("truncate table", "SQL table truncate");
  ("delete from", "SQL bulk delete");
  ("git push --force", "force push");
  ("git push -f", "force push");
  ("git reset --hard", "hard reset");
  ("git clean -f", "forced clean");
  ("chmod 777", "world-writable permissions");
  ("mkfs", "filesystem format");
  ("> /dev/", "device write");
  ("dd if=", "raw disk operation");
  ("kill -9", "forced process kill");
  ("pkill", "pattern-based process kill");
  ("shutdown", "system shutdown");
  ("reboot", "system reboot");
]

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

(** Suspicious shell meta-patterns that indicate possible evasion attempts.
    These don't match specific destructive commands but flag constructs
    that could hide destructive intent from substring matching.

    Each entry is (regex_pattern, description). Checked on the raw
    (un-normalized) command to catch patterns that normalization would strip. *)
let evasion_indicators : (string * string) list = [
  ({|\$[({]|}, "variable expansion or command substitution");
  ({|\\x[0-9a-fA-F]|}, "hex escape sequence");
  ({|\\[0-7][0-7]|}, "octal escape sequence");
  ({|base64.*-d|}, "base64 decode pipe (possible payload obfuscation)");
  ({|eval |}, "eval invocation (arbitrary code execution)");
  ({|xargs.*rm|xargs.*kill|}, "xargs with destructive command");
]

(** Check for shell evasion indicators in the raw (un-normalized) command.
    Returns Some(pattern, description) if a suspicious construct is found.
    This supplements [detect_destructive] by catching meta-patterns that
    normalization-based substring matching cannot handle. *)
let detect_evasion (command : string) : (string * string) option =
  let cmd_lower = String.lowercase_ascii command in
  List.find_opt (fun (pattern, _desc) ->
    Safe_ops.protect ~default:false (fun () ->
      let re = Re.Pcre.re pattern |> Re.compile in
      Re.execp re cmd_lower)
  ) evasion_indicators

(** Check if a bash command contains destructive patterns.
    Returns None if safe, Some(pattern, description) if dangerous.

    Two-pass detection:
    1. Normalized substring matching against [destructive_patterns]
    2. Raw regex matching against [evasion_indicators] for meta-patterns
       that normalization cannot catch (hex escapes, variable expansion, etc.)

    Both passes must clear for the command to be considered safe. *)
let detect_destructive (command : string) : (string * string) option =
  let cmd_lower = String.lowercase_ascii (normalize_command command) in
  match
    List.find_opt (fun (pattern, _desc) ->
      let pat_lower = String.lowercase_ascii pattern in
      let rec find_at i =
        if i + String.length pat_lower > String.length cmd_lower then false
        else if String.sub cmd_lower i (String.length pat_lower) = pat_lower then true
        else find_at (i + 1)
      in
      find_at 0
    ) destructive_patterns
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
    3. Cost budget (float compare)
    4. Turn call limit (int compare)
    5. Entropy (list scan)
    6. Destructive pattern (string scan, only for bash tools)

    First rejection wins — remaining checks are skipped. *)

let extract_all_strings_from_json (json_str : string) : string =
  try
    let rec go = function
      | `String s -> s
      | `List lst -> String.concat " " (List.map go lst)
      | `Assoc fields -> String.concat " " (List.map (fun (_, v) -> go v) fields)
      | _ -> ""
    in
    go (Yojson.Safe.from_string json_str)
  with Yojson.Json_error _ -> ""

let pre_check
    ~(config : gate_config)
    ~(accumulated_cost : float)
    ~(trajectory_acc : Trajectory.accumulator option)
    ~(tool_name : string)
    ~(args_json : string)
    : Trajectory.gate_decision =

  let tool_policy = tool_policy_of_config config in
  let deny_hit =
    Tool_access_policy.selector_matches_name tool_policy.deny tool_name
  in
  let allow_hit =
    Tool_access_policy.selector_matches_name tool_policy.allow tool_name
  in

  (* 1. Shared allow/deny policy *)
  if deny_hit then
    Trajectory.Reject (Printf.sprintf "tool '%s' is in deny list" tool_name)
  else if not allow_hit then
    Trajectory.Reject (Printf.sprintf "tool '%s' not in allowlist" tool_name)

  (* 3. Cost budget *)
  else if accumulated_cost >= config.max_cost_usd then
    Trajectory.Reject (Printf.sprintf "cost budget exceeded: $%.4f >= $%.4f limit"
      accumulated_cost config.max_cost_usd)

  (* 4. Turn call limit *)
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
                 && Tool_dispatch.is_destructive tool_name then
                let cmd_str = extract_all_strings_from_json args_json
                in
                begin match detect_destructive cmd_str with
                | Some (pattern, desc) ->
                    Trajectory.Reject (Printf.sprintf
                      "destructive pattern in %s: '%s' (%s)" tool_name pattern desc)
                | None -> Trajectory.Pass
                end
              else
                Trajectory.Pass
          end
    | None ->
        (* No trajectory accumulator — skip entropy and turn-limit checks *)
        if config.destructive_check_enabled
           && Tool_dispatch.is_destructive tool_name then
          let cmd_str =
            try
              let rec extract_strings = function
                | `String s -> s
                | `List lst -> String.concat " " (List.map extract_strings lst)
                | `Assoc fields -> String.concat " " (List.map (fun (_, v) -> extract_strings v) fields)
                | _ -> ""
              in
              extract_strings (Yojson.Safe.from_string args_json)
            with Yojson.Json_error _ -> ""
          in
          begin match detect_destructive cmd_str with
          | Some (pattern, desc) ->
              Trajectory.Reject (Printf.sprintf
                "destructive pattern in %s: '%s' (%s)" tool_name pattern desc)
          | None -> Trajectory.Pass
          end
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
      let open Yojson.Safe.Util in
      (match json |> member "error" with
       | `Null -> false
       | `String "" -> false
       | `String _ -> true
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

  (* Warn if approaching cost limit.
     80%% threshold: standard practice from capacity planning (e.g., disk usage
     alerts at 80%%). Gives ~20%% remaining budget for the agent to wrap up
     gracefully rather than hitting a hard wall mid-operation. *)
  let new_cost = accumulated_cost +. cost in
  let cost_warn_ratio = eval_cost_warn_ratio in
  let approaching_limit = new_cost >= config.max_cost_usd *. cost_warn_ratio in
  let should_warn = approaching_limit in
  let warning =
    if approaching_limit then
      Some (Printf.sprintf "approaching cost limit: $%.4f / $%.4f (%.0f%%)"
        new_cost config.max_cost_usd (new_cost /. config.max_cost_usd *. 100.0))
    else None
  in

  (* Warn on unusually long execution.
     30s threshold: most MASC tool calls complete in <5s (room ops, broadcasts).
     The slowest normal operations (Neo4j queries, cascade LLM calls) take 10-20s.
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

(* [gate_config_to_yojson], [post_eval_result_to_yojson] etc. are
   generated by [ppx_deriving_yojson].  Legacy aliases below. *)

let gate_config_to_json : gate_config -> Yojson.Safe.t =
  gate_config_to_yojson

let post_eval_to_json : post_eval_result -> Yojson.Safe.t =
  post_eval_result_to_yojson

(* ================================================================ *)
(* Convenience: wrap execute with pre+post gate                      *)
(* ================================================================ *)

(** Wrap a tool execution function with pre-check and post-eval.
    Returns (gate_decision, result option, post_eval option, duration_ms).

    If pre-check rejects, the execution function is never called.
    This is the main integration point for tool_keeper.ml. *)
let guarded_execute
    ~(config : gate_config)
    ~(accumulated_cost : float)
    ~(trajectory_acc : Trajectory.accumulator option)
    ~(tool_name : string)
    ~(args_json : string)
    ~(execute : unit -> string)
    : Trajectory.gate_decision * string option * post_eval_result option * int =

  let decision = pre_check ~config ~accumulated_cost ~trajectory_acc
    ~tool_name ~args_json in

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
          Log.info "eval_gate tool %s failed: %s" tool_name msg;
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
