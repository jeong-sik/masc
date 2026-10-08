(** The domain request and response of one HITL judgment. Exact-output candidate
    admission, execution and approval durability belong to [Hitl_summary_worker]. *)

val capture_context_bundle
  : entry:Keeper_approval_queue_rules_types.pending_approval
  -> Yojson.Safe.t
(** Acquire the host-observed task/repository/execution facts, then the configured
    thinking retention when request context is present, and project the judgment
    bundle without further effects. Missing outer-turn context stays explicit as
    [partial_context]; the exact request input and any observed refusal survive.

    The worker captures this once before admitting a flow and retains the result
    for both HTTP candidates and CLI fallback. This function does not mutate the
    approval or authorize its effect. *)

val parse_summary
  : generated_at:float
  -> model_run_id:string
  -> Yojson.Safe.t
  -> (Keeper_approval_queue_rules_types.hitl_context_summary, string) result
(** Pure domain decoding with the current summary version and caller-owned
    generation time and exact run identity. Invalid judgment data remains an
    explicit error; it is never coerced into a default judgment. *)
