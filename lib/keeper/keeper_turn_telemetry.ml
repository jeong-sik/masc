(** Keeper_turn_telemetry — post-turn observability logging.

    Extracted from keeper_agent_run.ml as part of #5732 god-module split.
    Contains logging helpers for CDAL proofs, contract verdicts, friction
    projections, and memory-bank writes. *)

let log_keeper_proof ~(keeper_name : string) (proof : Agent_sdk.Cdal_proof.t) =
  let status_string =
    Agent_sdk.Cdal_proof.show_result_status proof.result_status
    |> fun raw ->
    match String.rindex_opt raw '.' with
    | Some idx when idx + 1 < String.length raw ->
      String.sub raw (idx + 1) (String.length raw - idx - 1)
    | _ -> raw |> String.lowercase_ascii
  in
  match proof.result_status with
  | Agent_sdk.Cdal_proof.Completed ->
    if Keeper_types_profile.keeper_debug
    then
      Log.Keeper.debug
        "keeper:%s proof: run_id=%s mode=%s status=%s evidence_refs=%d"
        keeper_name
        proof.run_id
        (Agent_sdk.Execution_mode.to_string proof.effective_execution_mode)
        status_string
        (List.length proof.raw_evidence_refs)
  | _ ->
    Log.Keeper.warn
      "keeper:%s proof: run_id=%s mode=%s status=%s evidence_refs=%d"
      keeper_name
      proof.run_id
      (Agent_sdk.Execution_mode.to_string proof.effective_execution_mode)
      status_string
      (List.length proof.raw_evidence_refs)
;;

let log_keeper_contract_verdict
      ~(keeper_name : string)
      (verdict : Cdal_types.contract_verdict)
  =
  match verdict.status with
  | Cdal_types.Satisfied ->
    if Keeper_types_profile.keeper_debug
    then
      Log.Keeper.debug
        "keeper:%s contract_verdict: status=%s scope=%s hash=%s"
        keeper_name
        (Cdal_types.contract_status_to_string verdict.status)
        verdict.claim_scope
        verdict.judgment_hash
  | Cdal_types.Violated | Cdal_types.Inconclusive ->
    Log.Keeper.warn
      "keeper:%s contract_verdict: status=%s scope=%s hash=%s"
      keeper_name
      (Cdal_types.contract_status_to_string verdict.status)
      verdict.claim_scope
      verdict.judgment_hash
;;

let log_keeper_friction
      ~(keeper_name : string)
      (fp : Cdal_friction_projection.friction_projection)
  =
  let blocked = fp.blocked_attempt_count in
  let groups = List.length fp.blocked_attempt_groups in
  let tripwires = List.length fp.review_tripwires in
  if tripwires > 0
  then
    Log.Keeper.warn
      "keeper:%s friction: blocked=%d groups=%d tripwires=%d"
      keeper_name
      blocked
      groups
      tripwires
  else if blocked > 0 || groups > 0
  then
    Log.Keeper.debug
      "keeper:%s friction: blocked=%d groups=%d tripwires=%d"
      keeper_name
      blocked
      groups
      tripwires
  else if Keeper_types_profile.keeper_debug
  then
    Log.Keeper.debug
      "keeper:%s friction: blocked=%d groups=%d tripwires=%d"
      keeper_name
      blocked
      groups
      tripwires
;;

let log_keeper_memory_write
      ~(keeper_name : string)
      ~(notes_written : int)
      ~(kinds_written : string list)
  =
  if notes_written >= 10
  then
    Log.Keeper.info
      "keeper:%s memory_write: %d notes, kinds=[%s]"
      keeper_name
      notes_written
      (String.concat "," kinds_written)
  else if Keeper_types_profile.keeper_debug
  then
    Log.Keeper.debug
      "keeper:%s memory_write: %d notes, kinds=[%s]"
      keeper_name
      notes_written
      (String.concat "," kinds_written)
;;
