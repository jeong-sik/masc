(** Tool_task_payloads — pure JSON payload builders and verifier-name
    guards for task tools.

    No [context], no IO, no broadcast. Extracted from {!Tool_task} so
    the payload contracts (field names, nullability, cross-model
    semantics) can be exercised by unit tests without touching the
    full task dispatch pipeline.

    @since God file decomposition — extracted from tool_task.ml *)

let is_verifier_agent_name agent_name =
  let normalized = String.lowercase_ascii (String.trim agent_name) in
  String.equal normalized "verifier"
  || String.equal normalized "keeper-verifier-agent"

let verifier_transition_action_allowed = function
  | Masc_domain.Approve_verification
  | Masc_domain.Reject_verification ->
    true
  | Masc_domain.Claim
  | Masc_domain.Start
  | Masc_domain.Done_action
  | Masc_domain.Cancel
  | Masc_domain.Release
  | Masc_domain.Submit_for_verification
  | Masc_domain.Submit_pr_evidence ->
    false

let verifier_transition_rejection ~agent_name ~action =
  Printf.sprintf
    "Verifier action guard: agent '%s' may only call masc_transition(action=approve|reject). Got action=%s. Inspect task history/status for completed tasks, and reject insufficient or analysis-only evidence instead of claiming, starting, releasing, submitting, cancelling, or marking tasks done."
    agent_name action

let verifier_terminal_verdict_noop_message ~task_id ~action ~status =
  Printf.sprintf
    "Verifier stale verdict ignored: task %s is already %s, so masc_transition(action=%s) was treated as a no-op. Do not retry this verdict; inspect task history or list awaiting_verification tasks instead."
    task_id status action

let build_claim_observation_payload ~(now : float) ~(agent_name : string)
    ~(task_id : string) : Yojson.Safe.t =
  `Assoc
    [
      ("event_type", `String "collaboration.todo.claim_observed");
      ("observed_at", `Float now);
      ( "substrate",
        `Assoc
          [
            ("kind", `String "todo_claim");
            ("provider", `String "masc.coord");
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
            ("claimed_by", `String agent_name);
            ("winner_actor_id", `String agent_name);
            ("logical_clock", `Null);
            ("convergence_delay_ms", `Null);
          ] );
    ]

let append_claim_observation message ~now ~agent_name ~task_id =
  let payload = build_claim_observation_payload ~now ~agent_name ~task_id in
  message ^ "\nclaim_observation=" ^ Yojson.Safe.to_string payload

let verdict_to_string (result : Anti_rationalization.review_result) =
  match result.verdict with
  | Anti_rationalization.Approve -> "approve"
  | Anti_rationalization.Reject reason -> "reject:" ^ reason

(** True when both cascades are non-empty AND distinct.

    Must match {!Eval_calibration.calibration_stats} inclusion criteria
    exactly (both [not (String.equal evaluator_cascade "")] and [not (String.equal generator_cascade "")])
    so that a real-time SSE event and the aggregated cross_model_rate
    agree on which verdicts count as cross-model. *)
let is_cross_model_verdict (result : Anti_rationalization.review_result) : bool =
  match result.generator_cascade with
  | None -> false
  | Some g ->
    not (String.equal g "")
    && not (String.equal result.evaluator_cascade "")
    && not (String.equal g result.evaluator_cascade)

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
            ("evaluator_cascade", `String result.evaluator_cascade);
            ( "generator_cascade",
              match result.generator_cascade with
              | Some c -> `String c
              | None -> `Null );
            ("cross_model", `Bool (is_cross_model_verdict result));
            ( "fallback_reason",
              match result.fallback_reason with
              | Some reason -> `String reason
              | None -> `Null );
          ] );
    ]

(** Validate task_id is non-empty. Prevents phantom operations on empty IDs. *)
let validate_task_id task_id =
  if String.equal task_id "" then Error (Masc_domain.Task (Masc_domain.Task_error.InvalidId "empty task ID"))
  else Ok task_id
