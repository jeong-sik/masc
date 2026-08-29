(** Tool_task_payloads — pure JSON payload builders and task-policy
    helpers for task tools.

    No [context], no IO, no broadcast. Extracted from {!Tool_task} so
    the payload contracts (field names, nullability, cross-runtime
    semantics) can be exercised by unit tests without touching the
    full task dispatch pipeline.

    @since God file decomposition — extracted from tool_task.ml *)


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
          ] );
    ]

let append_claim_observation message ~now ~agent_name ~task_id ~scope_widened =
  let payload = build_claim_observation_payload ~now ~agent_name ~task_id ~scope_widened in
  message ^ "\nclaim_observation=" ^ Yojson.Safe.to_string payload

(** Validate task_id is non-empty. Prevents phantom operations on empty IDs. *)
let validate_task_id task_id =
  if String.equal task_id "" then Error (Masc_domain.Task (Masc_domain.Task_error.InvalidId "empty task ID"))
  else Ok task_id
