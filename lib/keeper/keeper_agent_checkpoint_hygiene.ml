(** Keeper_agent_checkpoint_hygiene — Pre-dispatch checkpoint hygiene.

    Compaction and checkpoint persistence logic that runs before
    dispatching to OAS Agent.run(). Extracted from keeper_agent_run.ml
    to isolate the compaction policy evaluation from the turn pipeline. *)

type pre_dispatch_checkpoint_hygiene_result =
  { context : Keeper_types.working_context
  ; resume_checkpoint : Agent_sdk.Checkpoint.t option
  ; compacted : bool
  ; applied : bool
  ; meaningful_reduction : bool
  ; before_tokens : int
  ; after_tokens : int
  ; trigger : Compaction_trigger.t option
  ; decision : Keeper_compact_policy.compaction_decision
  ; save_error : string option
  }

let prepare_resume_checkpoint_for_dispatch
      ~(meta : Keeper_types.keeper_meta)
      ~(now_ts : float)
      ~(loaded_checkpoint_present : bool)
      ~(save_checkpoint :
         Keeper_types.working_context -> (Agent_sdk.Checkpoint.t, string) result)
      (ctx_work : Keeper_types.working_context)
  : pre_dispatch_checkpoint_hygiene_result
  =
  let before_tokens = Keeper_exec_context.token_count ctx_work in
  let pre_dispatch_meta =
    { meta with compaction = { meta.compaction with cooldown_sec = 0 } }
  in
  let compacted_ctx, trigger, decision =
    Keeper_compact_policy.compact_if_needed_typed ~meta:pre_dispatch_meta ~now_ts ctx_work
  in
  let after_tokens = Keeper_exec_context.token_count compacted_ctx in
  let applied = Option.is_some trigger in
  let meaningful_reduction = after_tokens < before_tokens in
  let checkpoint_opt, save_error =
    if not loaded_checkpoint_present
    then None, None
    else if not applied
    then Some (Keeper_exec_context.checkpoint_of_context compacted_ctx), None
    else (
      match save_checkpoint compacted_ctx with
      | Ok checkpoint -> Some checkpoint, None
      | Error detail -> None, Some detail)
  in
  let context =
    match checkpoint_opt with
    | Some checkpoint -> { compacted_ctx with checkpoint }
    | None -> compacted_ctx
  in
  { context
  ; resume_checkpoint = checkpoint_opt
  ; compacted = applied
  ; applied
  ; meaningful_reduction
  ; before_tokens
  ; after_tokens
  ; trigger
  ; decision
  ; save_error
  }
;;
