(** Eval_gate — Pre/Post execution gates for Keeper tool calls.

    Multi-layer defense (Swiss Cheese Model):
    1. Cost budget check — reject if accumulated cost exceeds limit
    2. Destructive operation detection — reject bash commands with rm/drop/etc.
    3. Tool allowlist — reject tools not in keeper's permitted set
    4. Entropy check — reject if same tool called N+ times consecutively

    Each gate check is independent: any single rejection blocks execution.
    This prevents a failure in one layer from being masked by another.

    @since 2.73.0 *)

(* ================================================================ *)
(* Configuration                                                     *)
(* ================================================================ *)

type gate_config = {
  max_cost_usd : float;             (** Per-session cost limit (default: 0.50) *)
  max_tool_calls_per_turn : int;    (** Max tool calls in a single turn (default: 10) *)
  entropy_threshold : int;          (** Consecutive same-tool calls to trigger (default: 3) *)
  destructive_check_enabled : bool; (** Check bash commands for destructive patterns *)
  allowlist_enabled : bool;         (** Enforce tool allowlist *)
  allowed_tools : string list;      (** Empty = all tools allowed *)
  denied_tools : string list;       (** Explicit deny list (overrides allow) *)
}

let default_config : gate_config = {
  max_cost_usd = 0.50;
  max_tool_calls_per_turn = 10;
  entropy_threshold = 3;
  destructive_check_enabled = true;
  allowlist_enabled = false;
  allowed_tools = [];
  denied_tools = [];
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

(** Check if a bash command contains destructive patterns.
    Returns None if safe, Some(pattern, description) if dangerous. *)
let detect_destructive (command : string) : (string * string) option =
  let cmd_lower = String.lowercase_ascii command in
  List.find_opt (fun (pattern, _desc) ->
    (* Use simple substring matching — sufficient for safety gate.
       More sophisticated parsing (AST-level) would be needed for
       evasion-resistant detection, but this catches common patterns. *)
    let pat_lower = String.lowercase_ascii pattern in
    let rec find_at i =
      if i + String.length pat_lower > String.length cmd_lower then false
      else if String.sub cmd_lower i (String.length pat_lower) = pat_lower then true
      else find_at (i + 1)
    in
    find_at 0
  ) destructive_patterns

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
let pre_check
    ~(config : gate_config)
    ~(accumulated_cost : float)
    ~(trajectory_acc : Trajectory.accumulator option)
    ~(tool_name : string)
    ~(args_json : string)
    : Trajectory.gate_decision =

  (* 1. Deny list *)
  if List.mem tool_name config.denied_tools then
    Trajectory.Reject (Printf.sprintf "tool '%s' is in deny list" tool_name)

  (* 2. Allowlist *)
  else if config.allowlist_enabled
          && config.allowed_tools <> []
          && not (List.mem tool_name config.allowed_tools) then
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
          let entropy = Trajectory.detect_entropy ~threshold:config.entropy_threshold acc tool_name in
          begin match entropy with
          | Some (_name, count) ->
              Trajectory.Reject (Printf.sprintf
                "entropy detected: '%s' called %d consecutive times (threshold: %d)"
                tool_name count config.entropy_threshold)
          | None ->
              (* 6. Destructive pattern check (bash tools only) *)
              if config.destructive_check_enabled
                 && (tool_name = "keeper_bash"
                     || tool_name = "keeper_fs_edit"
                     || tool_name = "keeper_edit") then
                let cmd_str =
                  try
                    let json = Yojson.Safe.from_string args_json in
                    let open Yojson.Safe.Util in
                    (* keeper_bash uses "command", keeper_fs_edit/edit uses "content" *)
                    let cmd = json |> member "command" in
                    (match cmd with
                     | `String s -> s
                     | `Null ->
                         let c = json |> member "content" in
                         (match c with `String s -> s | _ -> "")
                     | _ -> "")
                  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error (_, _) -> ""
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
           && (tool_name = "keeper_bash"
               || tool_name = "keeper_fs_edit"
               || tool_name = "keeper_edit") then
          let cmd_str =
            try
              let json = Yojson.Safe.from_string args_json in
              let open Yojson.Safe.Util in
              let cmd = json |> member "command" in
              (match cmd with
               | `String s -> s
               | `Null ->
                   let c = json |> member "content" in
                   (match c with `String s -> s | _ -> "")
               | _ -> "")
            with Yojson.Json_error _ | Yojson.Safe.Util.Type_error (_, _) -> ""
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
}

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
        let open Yojson.Safe.Util in
        Some (json |> member "error" |> to_string)
      with Yojson.Json_error _ | Yojson.Safe.Util.Type_error (_, _) -> Some "unknown error in result"
    else None
  in

  (* Warn if approaching cost limit (80% threshold) *)
  let new_cost = accumulated_cost +. cost in
  let approaching_limit = new_cost >= config.max_cost_usd *. 0.8 in
  let should_warn = approaching_limit in
  let warning =
    if approaching_limit then
      Some (Printf.sprintf "approaching cost limit: $%.4f / $%.4f (%.0f%%)"
        new_cost config.max_cost_usd (new_cost /. config.max_cost_usd *. 100.0))
    else None
  in

  (* Warn on unusually long execution *)
  let slow_warn =
    if duration_ms > 30000 then  (* 30 seconds *)
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
    should_warn = should_warn || (duration_ms > 30000);
    warning = combined_warning;
  }

(* ================================================================ *)
(* JSON serialization                                                *)
(* ================================================================ *)

let gate_config_to_json (c : gate_config) : Yojson.Safe.t =
  `Assoc [
    ("max_cost_usd", `Float c.max_cost_usd);
    ("max_tool_calls_per_turn", `Int c.max_tool_calls_per_turn);
    ("entropy_threshold", `Int c.entropy_threshold);
    ("destructive_check_enabled", `Bool c.destructive_check_enabled);
    ("allowlist_enabled", `Bool c.allowlist_enabled);
    ("allowed_tools", `List (List.map (fun s -> `String s) c.allowed_tools));
    ("denied_tools", `List (List.map (fun s -> `String s) c.denied_tools));
  ]

let post_eval_to_json (r : post_eval_result) : Yojson.Safe.t =
  `Assoc [
    ("has_error", `Bool r.has_error);
    ("error_message",
      (match r.error_message with None -> `Null | Some s -> `String s));
    ("cost_usd", `Float r.cost_usd);
    ("should_warn", `Bool r.should_warn);
    ("warning",
      (match r.warning with None -> `Null | Some s -> `String s));
  ]

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

  match decision with
  | Trajectory.Reject _reason ->
      (decision, None, None, 0)
  | Trajectory.Pass ->
      let t0 = Time_compat.now () in
      let result =
        try execute ()
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Log.info "eval_gate tool %s failed: %s" tool_name (Printexc.to_string exn);
          Yojson.Safe.to_string (`Assoc [
            ("error", `String "Tool execution failed (internal error)");
            ("tool", `String tool_name);
          ])
      in
      let t1 = Time_compat.now () in
      let duration_ms = int_of_float ((t1 -. t0) *. 1000.0) in

      let eval = post_eval ~config ~tool_name ~result ~duration_ms
        ~accumulated_cost in

      (decision, Some result, Some eval, duration_ms)
