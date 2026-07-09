(** Tool_task_payloads — pure JSON payload builders and task-policy
    helpers for task tools.

    No [context], no IO, no broadcast. Extracted from {!Tool_task} so
    the payload contracts (field names, nullability, cross-runtime
    semantics) can be exercised by unit tests without touching the
    full task dispatch pipeline.

    @since God file decomposition — extracted from tool_task.ml *)

let transition_action_denylist_prefix = "masc_transition:"

let normalize_transition_action raw =
  String.trim raw |> String.lowercase_ascii

let transition_action_denylist_entry action =
  transition_action_denylist_prefix ^ normalize_transition_action action

let is_transition_action_denylist_entry raw =
  let normalized = normalize_transition_action raw in
  String.length normalized > String.length transition_action_denylist_prefix
  && String.sub normalized 0 (String.length transition_action_denylist_prefix)
     = transition_action_denylist_prefix

let transition_action_denied_by_denylist ~tool_denylist ~action =
  let expected = transition_action_denylist_entry action in
  List.exists
    (fun entry -> String.equal (normalize_transition_action entry) expected)
    tool_denylist

let transition_action_policy_applies tool_denylist =
  List.exists is_transition_action_denylist_entry tool_denylist

let transition_action_allowed_actions ~tool_denylist =
  Masc_domain.valid_task_action_strings
  |> List.filter (fun action ->
    not (transition_action_denied_by_denylist ~tool_denylist ~action))

let is_verdict_transition_action = function
  | Masc_domain.Approve_verification
  | Masc_domain.Reject_verification ->
    true
  | Masc_domain.Claim
  | Masc_domain.Start
  | Masc_domain.Done_action
  | Masc_domain.Cancel
  | Masc_domain.Release
  | Masc_domain.Submit_for_verification
  | Masc_domain.Mark_operator_blocked
  | Masc_domain.Unblock ->
    false

let transition_action_policy_rejection ~agent_name ~action ~allowed_actions =
  let allowed =
    match allowed_actions with
    | [] -> "(none)"
    | xs -> String.concat "|" xs
  in
  Printf.sprintf
    "Transition action policy guard: agent '%s' may only call masc_transition(action=%s). Got action=%s. Inspect task history/status before claiming, starting, releasing, submitting, cancelling, marking tasks done, or making a verification verdict."
    agent_name allowed action

let terminal_verdict_noop_message ~task_id ~action ~status =
  Printf.sprintf
    "Stale verification verdict ignored: task %s is already %s, so masc_transition(action=%s) was treated as a no-op. Do not retry this verdict; inspect task history or list awaiting_verification tasks instead."
    task_id status action

let workflow_rejection_payload_json
      ?rule_id
      ?tool_suggestion
      ?hint
      ?scope_policy
      ?recoverable
      ?(alternatives = [])
      ?extra_fields
      message
  =
  Workflow_rejection_payload.payload_json
    ?rule_id
    ?tool_suggestion
    ?hint
    ?scope_policy
    ?recoverable
    ~alternatives
    ?extra_fields
    message

let build_claim_observation_payload ~(now : float) ~(agent_name : string)
    ~(task_id : string) ~(scope_widened : bool) : Yojson.Safe.t =
  `Assoc
    [
      ("event_type", `String "collaboration.todo.claim_observed");
      ("observed_at", `Float now);
      ( "substrate",
        `Assoc
          [
            ("kind", `String "todo_claim");
            ("source", `String "masc.workspace");
            ("workspace_id", `Null);
          ] );
      ( "actor",
        `Assoc
          [
            ("id", `String agent_name);
            ("role", `Null);
            ("display_name", `Null);
          ] );
      ( "todo_claim",
        `Assoc
          [
            ("todo_id", `String task_id);
            ("state", `String "claim_verified");
            ("scope_widened", `Bool scope_widened);
            ("claimed_by", `String agent_name);
            ("winner_actor_id", `String agent_name);
            ("logical_clock", `Null);
            ("convergence_delay_ms", `Null);
          ] );
    ]

let append_claim_observation message ~now ~agent_name ~task_id ~scope_widened =
  let payload = build_claim_observation_payload ~now ~agent_name ~task_id ~scope_widened in
  message ^ "\nclaim_observation=" ^ Yojson.Safe.to_string payload

let verdict_to_string (result : Anti_rationalization.review_result) =
  match result.verdict with
  | Anti_rationalization.Approve -> "approve"
  | Anti_rationalization.Reject reason -> "reject:" ^ reason

(** True when both runtimes are non-empty AND distinct.

    Must match {!Eval_calibration.calibration_stats} inclusion criteria
    exactly (both [not (String.equal evaluator_runtime "")] and [not (String.equal generator_runtime "")])
    so that a real-time SSE event and the aggregated cross_runtime_rate
    agree on which verdicts count as cross-runtime. *)
let is_cross_runtime_verdict (result : Anti_rationalization.review_result) : bool =
  match result.generator_runtime with
  | None -> false
  | Some g ->
    not (String.equal g "")
    && not (String.equal result.evaluator_runtime "")
    && not (String.equal g result.evaluator_runtime)

(** Build the [verdict_recorded] SSE payload for a finished review.

    Pure function: no IO, no broadcast, no logging. Extracted so the
    payload contract can be exercised by unit tests. *)
let build_verdict_sse_payload
    ~(now : float)
    ~(task_id : string)
    ~(req : Anti_rationalization.review_request)
    ~(result : Anti_rationalization.review_result) : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "oas:masc:harness:verdict_recorded");
      ( "payload",
        `Assoc
          [
            ("timestamp", `Float now);
            ("task_id", `String task_id);
            ("task_title", `String req.task_title);
            ("agent_name", `String req.agent_name);
            ("gate", `String (Anti_rationalization.gate_to_string result.gate));
            ("verdict", `String (verdict_to_string result));
            ("evaluator_runtime", `String result.evaluator_runtime);
            ( "generator_runtime", Json_util.string_opt_to_json result.generator_runtime );
            ("cross_runtime", `Bool (is_cross_runtime_verdict result));
            ( "fallback_reason", Json_util.string_opt_to_json result.fallback_reason );
          ] );
    ]

(** Validate task_id is non-empty. Prevents phantom operations on empty IDs. *)
let validate_task_id task_id =
  if String.equal task_id "" then Error (Masc_domain.Task (Masc_domain.Task_error.InvalidId "empty task ID"))
  else Ok task_id
