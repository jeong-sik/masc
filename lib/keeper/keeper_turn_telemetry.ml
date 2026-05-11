(** Keeper_turn_telemetry — post-turn observability logging.

    Extracted from keeper_agent_run.ml as part of #5732 god-module split.
    Contains logging helpers for CDAL proofs, contract verdicts, friction
    projections, and memory-bank writes. *)

let string_list_json (items : string list) : Yojson.Safe.t =
  `List (List.map (fun item -> `String item) items)
;;

let blocking_gap_artifacts (verdict : Cdal_types.contract_verdict) : string list =
  verdict.completeness_gaps
  |> List.filter_map (fun (gap : Cdal_types.completeness_gap) ->
    if gap.impact = Cdal_types.Blocks_verdict then Some gap.artifact else None)
  |> List.sort_uniq String.compare
;;

let friction_gap_artifacts (fp : Cdal_friction_projection.friction_projection)
  : string list
  =
  fp.evidence_gap_groups
  |> List.map (fun (group : Cdal_friction_projection.evidence_gap_group) ->
    group.artifact)
  |> List.sort_uniq String.compare
;;

let contract_verdict_activity_payload
      ~(keeper_name : string)
      (verdict : Cdal_types.contract_verdict)
  : Yojson.Safe.t
  =
  `Assoc
    [ "keeper_name", `String keeper_name
    ; "run_id", `String verdict.run_id
    ; "contract_id", `String verdict.contract_id
    ; "status", `String (Cdal_types.contract_status_to_string verdict.status)
    ; "claim_scope", `String verdict.claim_scope
    ; "judgment_hash", `String verdict.judgment_hash
    ; "finding_count", `Int (List.length verdict.findings)
    ; "blocking_gap_artifacts", string_list_json (blocking_gap_artifacts verdict)
    ]
;;

let friction_activity_payload
      ~(keeper_name : string)
      (fp : Cdal_friction_projection.friction_projection)
  : Yojson.Safe.t
  =
  `Assoc
    [ "keeper_name", `String keeper_name
    ; "window", `String fp.window
    ; "based_on_run_ids", string_list_json fp.based_on_run_ids
    ; "blocked_attempt_count", `Int fp.blocked_attempt_count
    ; "blocked_group_count", `Int (List.length fp.blocked_attempt_groups)
    ; "review_tripwires", string_list_json fp.review_tripwires
    ; "evidence_gap_artifacts", string_list_json (friction_gap_artifacts fp)
    ]
;;

let log_keeper_proof ~(keeper_name : string) (proof : Masc_mcp_cdal_runtime.Cdal_proof.t) =
  (* Closed-set wire label.  Previously this called [show_result_status]
     ([@@deriving show] artifact, "Cdal_proof.Completed") and stripped
     the module prefix by [String.rindex_opt raw '.'].  That pattern is
     fragile because [@@deriving show] is not a stable wire format —
     adding a payload to any constructor would yield "Completed { … }"
     after the strip, breaking downstream label parsers.
     [result_status_to_string] returns one of five snake_case tokens
     (Cdal_proof.completed / errored / timed_out / cancelled /
     context_overflow) regardless of show-template changes.

     Casing change: prior logs printed "Completed" (capitalised
     constructor name); these now print "completed".  No alerting
     parses these debug/warn keeper-proof log lines (the metric label
     side already uses the same snake_case tokens). *)
  let status_string =
    Masc_mcp_cdal_runtime.Cdal_proof.result_status_to_string proof.result_status
  in
  match proof.result_status with
  | Masc_mcp_cdal_runtime.Cdal_proof.Completed ->
    if Keeper_types_profile.keeper_debug
    then
      Log.Keeper.debug
        "keeper:%s proof: run_id=%s mode=%s status=%s evidence_refs=%d"
        keeper_name
        proof.run_id
        (Masc_mcp_cdal_runtime.Execution_mode.to_string proof.effective_execution_mode)
        status_string
        (List.length proof.raw_evidence_refs)
  | _ ->
    Log.Keeper.warn
      "keeper:%s proof: run_id=%s mode=%s status=%s evidence_refs=%d"
      keeper_name
      proof.run_id
      (Masc_mcp_cdal_runtime.Execution_mode.to_string proof.effective_execution_mode)
      status_string
      (List.length proof.raw_evidence_refs)
;;

let log_keeper_contract_verdict
      ~(keeper_name : string)
      (verdict : Cdal_types.contract_verdict)
  =
  let blocking_gaps = blocking_gap_artifacts verdict in
  match verdict.status with
  | Cdal_types.Satisfied ->
    if Keeper_types_profile.keeper_debug
    then
      Log.Keeper.debug
        "keeper:%s contract_verdict: status=%s scope=%s hash=%s findings=%d \
         blocking_gaps=[%s]"
        keeper_name
        (Cdal_types.contract_status_to_string verdict.status)
        verdict.claim_scope
        verdict.judgment_hash
        (List.length verdict.findings)
        (String.concat "," blocking_gaps)
  | Cdal_types.Violated | Cdal_types.Inconclusive ->
    Log.Keeper.warn
      "keeper:%s contract_verdict: status=%s scope=%s hash=%s findings=%d \
       blocking_gaps=[%s]"
      keeper_name
      (Cdal_types.contract_status_to_string verdict.status)
      verdict.claim_scope
      verdict.judgment_hash
      (List.length verdict.findings)
      (String.concat "," blocking_gaps)
;;

let log_keeper_friction
      ~(keeper_name : string)
      (fp : Cdal_friction_projection.friction_projection)
  =
  let blocked = fp.blocked_attempt_count in
  let groups = List.length fp.blocked_attempt_groups in
  let tripwires = List.length fp.review_tripwires in
  let gap_artifacts = friction_gap_artifacts fp in
  if tripwires > 0
  then
    Log.Keeper.warn
      "keeper:%s friction: blocked=%d groups=%d tripwires=%d names=[%s] gaps=[%s]"
      keeper_name
      blocked
      groups
      tripwires
      (String.concat "," fp.review_tripwires)
      (String.concat "," gap_artifacts)
  else if blocked > 0 || groups > 0
  then
    Log.Keeper.debug
      "keeper:%s friction: blocked=%d groups=%d tripwires=%d gaps=[%s]"
      keeper_name
      blocked
      groups
      tripwires
      (String.concat "," gap_artifacts)
  else if Keeper_types_profile.keeper_debug
  then
    Log.Keeper.debug
      "keeper:%s friction: blocked=%d groups=%d tripwires=%d gaps=[%s]"
      keeper_name
      blocked
      groups
      tripwires
      (String.concat "," gap_artifacts)
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
