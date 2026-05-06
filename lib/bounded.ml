(** Bounded Autonomy - Constrained multi-agent execution loops

    Provides formal guarantees:
    - Termination: Always terminates via hard_max_iterations
    - Safety: Post-check prevents silent constraint violations
    - Soundness: Typed comparisons with explicit error handling

    Designed based on MAGI review (Gemini + Qwen3 formal verification).
*)

(* Fiber-safe random state for jitter calculation *)
let bounded_rng = Random.State.make_self_init ()

open Spawn

(** Comparison operators for goal conditions *)
type comparison =
  | Eq of Yojson.Safe.t
  | Neq of Yojson.Safe.t
  | Lt of float
  | Lte of float
  | Gt of float
  | Gte of float
  | Between of float * float
  | In of Yojson.Safe.t list

(** Goal condition with JSONPath-like path *)
type goal = {
  path: string;
  condition: comparison;
}

(** Retry configuration *)
type retry_config = {
  max_retries: int;            (** Maximum retry attempts per agent call *)
  base_delay_ms: int;          (** Base delay in milliseconds *)
  max_delay_ms: int;           (** Maximum delay cap *)
  jitter_factor: float;        (** Jitter multiplier (0.0-1.0) *)
}

(** Default retry config - conservative defaults *)
let default_retry_config = {
  max_retries = 3;
  base_delay_ms = 1000;
  max_delay_ms = 30000;
  jitter_factor = 0.2;
}

(** Constraint specification *)
type constraints = {
  max_turns: int option;
  max_tokens: int option;
  max_cost_usd: float option;
  max_time_seconds: float option;
  token_buffer: int;
  (* Deprecated since RFC-0028.  Kept on the record so that JSON
     inputs that still set it parse without raising; no longer
     consulted by the predictive token check, which now reads
     {!Usage_history.predict_p95}. *)
  hard_max_iterations: int;    (** Absolute failsafe limit *)
  retry: retry_config;         (** Retry configuration *)
}

(** Default constraints - safe defaults *)
let default_constraints = {
  max_turns = Some 10;
  max_tokens = Some 100000;
  max_cost_usd = Some 1.0;
  max_time_seconds = Some 300.0;
  (* Was 5000 pre-RFC-0028.  Now 0 — the predictor consults
     [Usage_history.predict_p95] instead of this magic constant. *)
  token_buffer = 0;
  hard_max_iterations = 100;
  retry = default_retry_config;
}

module Usage_history = struct
  (* RFC-0028 — per-agent ring buffer of recent output-token counts.
     The predictive constraint check estimates the next turn's cost
     from the high quantile of these samples instead of the linear
     running average that the prior implementation used. *)

  let max_samples_per_agent = 64
  let min_samples_for_p95 = 10
  let unknown_agent_fallback = 1024
  (* RFC-0028 §4.2.  Conservative upper bound for one cascade turn's
     output tokens against current defaults (gpt-4o-mini / qwen3-9B /
     qwen3-35B-A3B).  No formal heuristic_metrics evidence is
     attached today — this gap is acknowledged in the RFC.  Re-measure
     once distribution data lands. *)

  let store : (string, int Queue.t) Hashtbl.t = Hashtbl.create 8
  let mutex = Mutex.create ()

  let with_lock f =
    Mutex.lock mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock mutex) f

  let record ~agent ~tokens_out =
    if tokens_out <= 0 then ()
    else
      with_lock (fun () ->
        let q =
          match Hashtbl.find_opt store agent with
          | Some existing -> existing
          | None ->
              let fresh = Queue.create () in
              Hashtbl.add store agent fresh;
              fresh
        in
        Queue.add tokens_out q;
        while Queue.length q > max_samples_per_agent do
          ignore (Queue.pop q)
        done)

  let snapshot agent =
    with_lock (fun () ->
      match Hashtbl.find_opt store agent with
      | None -> []
      | Some q -> List.of_seq (Queue.to_seq q))

  let predict_p95 ?agent () =
    match agent with
    | None -> unknown_agent_fallback
    | Some a ->
        let samples = snapshot a in
        let n = List.length samples in
        if n < min_samples_for_p95 then unknown_agent_fallback
        else
          let sorted = List.sort compare samples in
          let raw_idx = int_of_float (ceil (0.95 *. float_of_int n)) - 1 in
          let idx = max 0 (min (n - 1) raw_idx) in
          List.nth sorted idx

  let sample_count ?agent () =
    match agent with
    | None -> 0
    | Some a ->
        with_lock (fun () ->
          match Hashtbl.find_opt store a with
          | None -> 0
          | Some q -> Queue.length q)

  let reset () =
    with_lock (fun () -> Hashtbl.reset store)
end

(** Bounded execution state *)
type bounded_state = {
  mutable turns: int;
  mutable tokens_in: int;
  mutable tokens_out: int;
  mutable cost_usd: float;
  mutable total_retries: int;
  start_time: float;
  constraints: constraints;
}

(** Calculate exponential backoff delay with jitter *)
let calc_backoff_delay retry_config attempt =
  let base = float_of_int retry_config.base_delay_ms in
  let max_delay = float_of_int retry_config.max_delay_ms in
  (* Exponential: base * 2^attempt *)
  let exp_delay = base *. (2.0 ** float_of_int attempt) in
  let capped = min exp_delay max_delay in
  (* Add jitter: delay * (1 - jitter/2 + random * jitter) *)
  let jitter_range = capped *. retry_config.jitter_factor in
  let jitter = (Random.State.float bounded_rng jitter_range) -. (jitter_range /. 2.0) in
  int_of_float (capped +. jitter)

(* Static alternation of retryable-failure markers, hoisted to module
   load.  Old form rebuilt 14 [Re.t] DFAs and 14 lowercase strings on
   every error classification; the patterns are literals and
   case-insensitive matching is delegated to [no_case]. *)
let retryable_error_re =
  let patterns = [
    "timeout";
    "timed out";
    "connection refused";
    "connection reset";
    "network";
    "ECONNREFUSED";
    "ETIMEDOUT";
    "rate limit";
    "429";
    "503";
    "502";
    "504";
    "overloaded";
    "temporarily unavailable";
  ] in
  Re.(compile (no_case (alt (List.map str patterns))))

(** Hard quota/capacity exhaustion is not retryable inside this
    same-agent bounded loop.  Cross-provider fallback and long
    cooldown decisions are owned by keeper/cascade classifiers. *)
let hard_quota_error_indicators = [
  "hard_quota";
  "terminalquotaerror";
  "quota_exhausted";
  "quota exceeded";
  "insufficient_quota";
  "you exceeded your current quota";
  "exhausted your capacity on this model";
  "quota will reset after";
  "you've hit your limit";
  "monthly usage limit";
  "org's monthly usage limit";
  "reached your specified api usage limits";
  "you will regain access on";
]

let message_looks_like_hard_quota_error msg =
  let contains needle = String_util.contains_substring_ci msg needle in
  List.exists contains hard_quota_error_indicators
  || (contains "claude exited with code 1"
      && contains "\"api_error_status\":429"
      && contains "you've hit your limit")

(** Check if error is retryable (transient failures) *)
let is_retryable_error msg =
  (not (message_looks_like_hard_quota_error msg))
  && Re.execp retryable_error_re msg

(** Create new bounded state *)
let create_state constraints =
  {
    turns = 0;
    tokens_in = 0;
    tokens_out = 0;
    cost_usd = 0.0;
    total_retries = 0;
    start_time = Time_compat.now ();
    constraints;
  }

(** Check single constraint *)
let check_single name current limit =
  match limit with
  | None -> None
  | Some max when current >= max ->
      Some (Printf.sprintf "%s exceeded: %d >= %d" name current max)
  | _ -> None

let check_single_float name current limit =
  match limit with
  | None -> None
  | Some max when current >= max ->
      Some (Printf.sprintf "%s exceeded: %.2f >= %.2f" name current max)
  | _ -> None

(** Check all constraints - returns first violation or None *)
let check_constraints state =
  let elapsed = Time_compat.now () -. state.start_time in
  let total_tokens = state.tokens_in + state.tokens_out in
  let checks = [
    check_single "turns" state.turns state.constraints.max_turns;
    check_single "tokens" total_tokens state.constraints.max_tokens;
    check_single_float "cost_usd" state.cost_usd state.constraints.max_cost_usd;
    check_single_float "time_seconds" elapsed state.constraints.max_time_seconds;
  ] in
  List.find_map Fun.id checks

(** Check constraints with buffer (predictive).

    RFC-0028: the prediction now comes from the per-agent empirical
    distribution of recent output-token samples (p95) instead of the
    linear average.  Without [next_agent] or before the agent has
    accumulated [Usage_history.min_samples_for_p95] samples, falls
    back to [Usage_history.unknown_agent_fallback]. *)
let check_constraints_with_buffer ?next_agent state =
  let predicted_per_turn =
    Usage_history.predict_p95 ?agent:next_agent ()
  in
  let predicted_total =
    state.tokens_in + state.tokens_out + predicted_per_turn
  in
  match state.constraints.max_tokens with
  | Some max when predicted_total > max ->
      Some (Printf.sprintf "Approaching token limit: %d + ~%d > %d"
        (state.tokens_in + state.tokens_out) predicted_per_turn max)
  | _ -> check_constraints state

(** Simple path resolution - supports "$.field" and "$.field.subfield" *)
let resolve_path json path =
  let path =
    if String.starts_with ~prefix:"$." path then
      String.sub path 2 (String.length path - 2)
    else path
  in
  let parts = String.split_on_char '.' path in
  let rec walk json = function
    | [] -> Some json
    | part :: rest ->
        match json with
        | `Assoc fields ->
            (match List.assoc_opt part fields with
             | Some v -> walk v rest
             | None -> None)
        | _ -> None
  in
  walk json parts

(** Extract float from JSON value *)
let json_to_float = function
  | `Int i -> Some (float_of_int i)
  | `Float f -> Some f
  | `String s -> float_of_string_opt s
  | _ -> None

(** Check goal condition against result *)
let check_goal result goal =
  match resolve_path result goal.path with
  | None -> false  (* Path not found = goal not met *)
  | Some value ->
      match goal.condition with
      | Eq expected -> value = expected
      | Neq expected -> value <> expected
      | Lt threshold ->
          (match json_to_float value with
           | Some v -> v < threshold
           | None -> false)
      | Lte threshold ->
          (match json_to_float value with
           | Some v -> v <= threshold
           | None -> false)
      | Gt threshold ->
          (match json_to_float value with
           | Some v -> v > threshold
           | None -> false)
      | Gte threshold ->
          (match json_to_float value with
           | Some v -> v >= threshold
           | None -> false)
      | Between (lo, hi) ->
          (match json_to_float value with
           | Some v -> v >= lo && v <= hi
           | None -> false)
      | In values -> List.mem value values

(** Execution history entry *)
type history_entry = {
  turn: int;
  agent: string;
  tokens_in: int;
  tokens_out: int;
  cost_usd: float;
  elapsed_ms: int;
  retries: int;               (** Number of retries for this turn *)
  goal_met: bool;
}

(** Bounded run result *)
type bounded_result = {
  status: [ `Goal_reached | `Constraint_exceeded | `Error ];
  reason: string;
  final_output: string option;
  stats: bounded_state;
  history: history_entry list;
  warning: string option;
}

(** Update state from spawn result *)
let update_state state result =
  state.turns <- state.turns + 1;
  state.tokens_in <- state.tokens_in +
    (Option.value result.input_tokens ~default:0);
  state.tokens_out <- state.tokens_out +
    (Option.value result.output_tokens ~default:0);
  state.cost_usd <- state.cost_usd +.
    (Option.value result.cost_usd ~default:0.0)

let format_agent_failure ~agent ~turn ~attempts ~msg =
  let attempt_word = if attempts = 1 then "attempt" else "attempts" in
  Printf.sprintf
    "Agent '%s' failed before completing turn %d after %d %s: %s"
    agent turn attempts attempt_word msg

let format_agent_execution_failure ~agent ~turn ~attempts ~msg =
  let attempt_word = if attempts = 1 then "attempt" else "attempts" in
  Printf.sprintf
    "Agent '%s' execution failed before completing turn %d after %d %s: %s"
    agent turn attempts attempt_word msg

(** Main bounded execution loop *)
let bounded_run ~constraints ~goal ~agents ~prompt ~spawn_fn =
  (* Pre-check: empty agents *)
  match agents with
  | [] ->
      {
        status = `Error;
        reason = "No agents available";
        final_output = None;
        stats = create_state constraints;
        history = [];
        warning = None;
      }
  | fallback_agent :: _ ->
      let state = create_state constraints in
      let history = ref [] in
      let sleep_s = Time_compat.sleep in

      let rec loop () =
        (* 1. Hard limit check (failsafe) *)
        if state.turns >= constraints.hard_max_iterations then
          {
            status = `Constraint_exceeded;
            reason = Printf.sprintf "Hard iteration limit reached (%d)"
              constraints.hard_max_iterations;
            final_output = None;
            stats = state;
            history = List.rev !history;
            warning = None;
          }
        else
          (* 3. Select next agent (round-robin) ahead of the predictive
             check — RFC-0028 needs the agent key for the per-agent
             distribution lookup. *)
          let agent_idx = state.turns mod (List.length agents) in
          let agent =
            Option.value ~default:fallback_agent
              (List.nth_opt agents agent_idx)
          in
          (* 2. Predictive constraint check *)
          match check_constraints_with_buffer ~next_agent:agent state with
          | Some reason ->
              {
                status = `Constraint_exceeded;
                reason;
                final_output = None;
                stats = state;
                history = List.rev !history;
                warning = None;
              }
          | None ->
              (* 4. Execute agent with retry logic *)
            let rec try_spawn attempt =
              let result =
                try Ok (spawn_fn agent prompt)
                with
                | Eio.Cancel.Cancelled _ as e -> raise e
                | e -> Error (Printexc.to_string e)
              in
              match result with
              | Ok spawn_result when spawn_result.success ->
                  (* Success - return result with retry count *)
                  Ok (spawn_result, attempt)
              | Ok spawn_result ->
                  (* Agent returned failure (non-zero exit) *)
                  let err_msg = spawn_result.output in
                  if attempt < constraints.retry.max_retries
                     && is_retryable_error err_msg
                  then begin
                    let delay_ms = calc_backoff_delay constraints.retry attempt in
                    sleep_s (float_of_int delay_ms /. 1000.0);
                    state.total_retries <- state.total_retries + 1;
                    try_spawn (attempt + 1)
                  end else
                    Error (format_agent_failure
                      ~agent
                      ~turn:(state.turns + 1)
                      ~attempts:(attempt + 1)
                      ~msg:err_msg)
              | Error msg ->
                  (* Exception during spawn *)
                  if attempt < constraints.retry.max_retries
                     && is_retryable_error msg
                  then begin
                    let delay_ms = calc_backoff_delay constraints.retry attempt in
                    sleep_s (float_of_int delay_ms /. 1000.0);
                    state.total_retries <- state.total_retries + 1;
                    try_spawn (attempt + 1)
                  end else
                    Error (format_agent_execution_failure
                      ~agent
                      ~turn:(state.turns + 1)
                      ~attempts:(attempt + 1)
                      ~msg)
            in

            match try_spawn 0 with
            | Error msg ->
                {
                  status = `Error;
                  reason = msg;
                  final_output = None;
                  stats = state;
                  history = List.rev !history;
                  warning = None;
                }
            | Ok (spawn_result, retries_used) ->
                (* 5. Update state AFTER execution *)
                update_state state spawn_result;
                (* RFC-0028: feed the per-agent distribution so future
                   predictive checks can read this agent's tail.  The
                   recorder drops zero/negative samples internally. *)
                (match spawn_result.output_tokens with
                 | Some tokens ->
                     Usage_history.record ~agent ~tokens_out:tokens
                 | None -> ());

                (* 6. Parse output as JSON for goal check *)
                let output_json =
                  try Yojson.Safe.from_string spawn_result.output
                  with Yojson.Json_error _ ->
                    `Assoc [ ("raw", `String spawn_result.output) ]
                in

                let goal_met = check_goal output_json goal in

                (* 7. Record history *)
                let entry = {
                  turn = state.turns;
                  agent;
                  retries = retries_used;
                  tokens_in = Option.value spawn_result.input_tokens ~default:0;
                  tokens_out = Option.value spawn_result.output_tokens ~default:0;
                  cost_usd = Option.value spawn_result.cost_usd ~default:0.0;
                  elapsed_ms = spawn_result.elapsed_ms;
                  goal_met;
                } in
                history := entry :: !history;

                (* 8. Post-check: did we exceed constraints? *)
                let warning = check_constraints state in

                if goal_met then
                  {
                    status = `Goal_reached;
                    reason = Printf.sprintf "Goal met: %s" goal.path;
                    final_output = Some spawn_result.output;
                    stats = state;
                    history = List.rev !history;
                    warning;
                  }
                else
                  match warning with
                  | Some warn_msg ->
                      (* Exceeded but return partial result *)
                      {
                        status = `Constraint_exceeded;
                        reason = warn_msg;
                        final_output = Some spawn_result.output;
                        stats = state;
                        history = List.rev !history;
                        warning;
                      }
                  | None -> loop ()
      in
      loop ()

(** Convert bounded_result to JSON *)
let result_to_json result =
  let status_str = match result.status with
    | `Goal_reached -> "goal_reached"
    | `Constraint_exceeded -> "constraint_exceeded"
    | `Error -> "error"
  in
  let history_json = List.map (fun e ->
    `Assoc [
      ("turn", `Int e.turn);
      ("agent", `String e.agent);
      ("tokens_in", `Int e.tokens_in);
      ("tokens_out", `Int e.tokens_out);
      ("cost_usd", `Float e.cost_usd);
      ("elapsed_ms", `Int e.elapsed_ms);
      ("retries", `Int e.retries);
      ("goal_met", `Bool e.goal_met);
    ]
  ) result.history in
  `Assoc [
    ("status", `String status_str);
    ("reason", `String result.reason);
    ("final_output", match result.final_output with
      | Some s -> `String s
      | None -> `Null);
    ("stats", `Assoc [
      ("turns", `Int result.stats.turns);
      ("tokens_in", `Int result.stats.tokens_in);
      ("tokens_out", `Int result.stats.tokens_out);
      ("tokens_total", `Int (result.stats.tokens_in + result.stats.tokens_out));
      ("cost_usd", `Float result.stats.cost_usd);
      ("total_retries", `Int result.stats.total_retries);
      ("elapsed_seconds", `Float (Time_compat.now () -. result.stats.start_time));
    ]);
    ("history", `List history_json);
    ("warning", match result.warning with
      | Some w -> `String w
      | None -> `Null);
  ]

(** Parse retry config from JSON *)
let retry_config_of_json json =
  let open Yojson.Safe.Util in
  let retry = json |> member "retry" in
  if retry = `Null then
    default_retry_config
  else
    {
      max_retries =
        Safe_ops.json_int ~default:default_retry_config.max_retries "max_retries" retry;
      base_delay_ms =
        Safe_ops.json_int ~default:default_retry_config.base_delay_ms "base_delay_ms" retry;
      max_delay_ms =
        Safe_ops.json_int ~default:default_retry_config.max_delay_ms "max_delay_ms" retry;
      jitter_factor =
        Safe_ops.json_float ~default:default_retry_config.jitter_factor "jitter_factor" retry;
    }

(** Parse constraints from JSON *)
let constraints_of_json json =
  if json = `Null then
    default_constraints
  else
    let open Yojson.Safe.Util in
    let get_int_opt key = Safe_ops.json_int_opt key json in
    let get_float_opt key =
      try Some (json |> member key |> to_float)
      with Yojson.Safe.Util.Type_error _ -> None
    in
    {
      max_turns = get_int_opt "max_turns";
      max_tokens = get_int_opt "max_tokens";
      max_cost_usd = get_float_opt "max_cost_usd";
      max_time_seconds = get_float_opt "max_time_seconds";
      token_buffer =
        Safe_ops.json_int ~default:default_constraints.token_buffer "token_buffer" json;
      hard_max_iterations =
        Safe_ops.json_int ~default:default_constraints.hard_max_iterations "hard_max_iterations" json;
      retry = retry_config_of_json json;
    }

(** Parse goal from JSON *)
let goal_of_json json =
  let open Yojson.Safe.Util in
  let path = json |> member "path" |> to_string in
  let cond = json |> member "condition" in
  let condition =
    if member "eq" cond <> `Null then
      Eq (member "eq" cond)
    else if member "neq" cond <> `Null then
      Neq (member "neq" cond)
    else if member "lt" cond <> `Null then
      Lt (member "lt" cond |> to_float)
    else if member "lte" cond <> `Null then
      Lte (member "lte" cond |> to_float)
    else if member "gt" cond <> `Null then
      Gt (member "gt" cond |> to_float)
    else if member "gte" cond <> `Null then
      Gte (member "gte" cond |> to_float)
    else if member "between" cond <> `Null then
      match member "between" cond |> to_list with
      | low :: high :: _ -> Between (low |> to_float, high |> to_float)
      | _ -> invalid_arg "Bounded.rule_of_yojson: 'between' array must have at least 2 elements"
    else if member "in" cond <> `Null then
      In (member "in" cond |> to_list)
    else
      Eq (`Bool true)  (* Default: look for truthy value *)
  in
  { path; condition }
