open Types

let schemas : tool_schema list = [
  {
    name = "masc_verify_status";
    description = "Check the current status and result of a verification request by its ID. Use when polling for completion after submitting an action for asynchronous verification.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("verification_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Verification request ID");
        ]);
      ]);
      ("required", `List [`String "verification_id"]);
    ];
  };

  (* masc_bounded_run *)
  {
    name = "masc_bounded_run";
    description = "Run a multi-agent round-robin loop with formal termination, token budget, cost, and time constraints. \
Use when orchestrating autonomous agent collaboration that needs guaranteed termination and budget control. \
Pair with command-plane or operator tools when the run needs external supervision.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agents", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of agents to use in round-robin: ['gemini', 'codex', 'claude']");
        ]);
        ("prompt", `Assoc [
          ("type", `String "string");
          ("description", `String "Initial prompt for agents");
        ]);
        ("constraints", `Assoc [
          ("type", `String "object");
          ("description", `String "Execution limits");
          ("properties", `Assoc [
            ("max_turns", `Assoc [
              ("type", `String "integer");
              ("description", `String "Maximum agent turns (default: 10)");
            ]);
            ("max_tokens", `Assoc [
              ("type", `String "integer");
              ("description", `String "Maximum total tokens (default: 100000)");
            ]);
            ("max_cost_usd", `Assoc [
              ("type", `String "number");
              ("description", `String "Maximum cost in USD (default: 1.0)");
            ]);
            ("max_time_seconds", `Assoc [
              ("type", `String "number");
              ("description", `String "Maximum wall-clock time (default: 300)");
            ]);
            ("token_buffer", `Assoc [
              ("type", `String "integer");
              ("description", `String "Buffer for predictive token limit (default: 5000)");
            ]);
            ("hard_max_iterations", `Assoc [
              ("type", `String "integer");
              ("description", `String "Absolute failsafe iteration limit (default: 100)");
            ]);
          ]);
        ]);
        ("goal", `Assoc [
          ("type", `String "object");
          ("description", `String "Termination condition");
          ("properties", `Assoc [
            ("path", `Assoc [
              ("type", `String "string");
              ("description", `String "JSONPath to check in agent output, e.g., '$.status' or '$.result.done'");
            ]);
            ("condition", `Assoc [
              ("type", `String "object");
              ("description", `String "Comparison: {eq: value}, {gte: 0.95}, {lt: 5}, {in: ['done', 'success']}");
            ]);
          ]);
          ("required", `List [`String "path"; `String "condition"]);
        ]);
      ]);
      ("required", `List [`String "agents"; `String "prompt"; `String "goal"]);
    ];
  };

  (* masc_verify_request *)
  {
    name = "masc_verify_request";
    description = "Request peer verification of a task's output against optional criteria. \
Use when a completed task needs quality sign-off from another agent. \
Follow up with masc_verify_submit to provide a verdict or masc_verify_auto for automated checks.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to verify");
        ]);
        ("output", `Assoc [
          ("description", `String "Task output payload to verify");
        ]);
        ("criteria", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [
            ("type", `String "object");
            ("description", `String "Verification criteria definition");
          ]);
          ("description", `String "Optional list of verification criteria");
        ]);
        ("verifier", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional verifier agent");
        ]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };

  (* masc_verify_submit *)
  {
    name = "masc_verify_submit";
    description = "Submit a pass/fail/partial verdict for a pending verification request. \
Use when you have reviewed a task output and are ready to provide your assessment. \
After masc_verify_request creates the verification; pair with masc_verify_status to confirm submission.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("verification_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Verification request ID");
        ]);
        ("verdict", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "pass"; `String "fail"; `String "partial"]);
          ("description", `String "Verification result");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for the verdict");
        ]);
        ("score", `Assoc [
          ("type", `String "number");
          ("description", `String "Score for partial verdict");
        ]);
      ]);
      ("required", `List [`String "verification_id"; `String "verdict"]);
    ];
  };

  (* masc_verify_pending *)
  {
    name = "masc_verify_pending";
    description = "List pending verification requests assigned to the current agent. \
Use when checking your verification inbox for tasks awaiting review. \
Follow up with masc_verify_submit to provide a verdict for each pending request.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* masc_verify_auto *)
  {
    name = "masc_verify_auto";
    description = "Run automated verification checks for a pending verification request. \
Use when a task output can be verified programmatically instead of manual review. \
After masc_verify_request creates the request; alternative to manual masc_verify_submit.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("verification_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Verification request ID");
        ]);
      ]);
      ("required", `List [`String "verification_id"]);
    ];
  };
]
