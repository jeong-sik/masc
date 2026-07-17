module Operation = Keeper_compaction_operation
open Operation

let checkpoint (checkpoint : Keeper_checkpoint_ref.t) =
  `Assoc
    [ "trace_id", `String (Keeper_id.Trace_id.to_string checkpoint.trace_id)
    ; "generation", `Int checkpoint.generation
    ; "turn_count", `Int checkpoint.turn_count
    ; "sha256", `String checkpoint.sha256
    ]
;;

let evidence (evidence : Keeper_compaction_evidence.t) =
  `Assoc
    [ ( "selected_runtime_id"
      , match evidence.Keeper_compaction_evidence.selected_runtime_id with
        | Some value -> `String value
        | None -> `Null )
    ; "counts", Keeper_compaction_evidence.to_json evidence
    ]
;;

let preserved_evidence
      (evidence : Keeper_compaction_evidence.preserved)
  =
  `Assoc
    [ ( "selected_runtime_id"
      , `String evidence.Keeper_compaction_evidence.selected_runtime_id )
    ; "counts", Keeper_compaction_evidence.preserved_to_json evidence
    ]
;;

let candidate ~checkpoint_field (candidate : Operation.candidate) =
  [ "attempt_id", `String (Operation.Attempt_id.to_string candidate.attempt_id)
  ; "source_checkpoint", checkpoint candidate.source_checkpoint
  ; checkpoint_field, checkpoint candidate.candidate_checkpoint
  ; "evidence", evidence candidate.evidence
  ]
;;

let envelope event kind payload =
  `Assoc
    [ "kind", `String kind
    ; "operation_id", `String (Operation.Operation_id.to_string (Operation.operation_id event))
    ; "payload", `Assoc payload
    ]
;;

let to_json event =
  match Operation.view event with
  | Requested request ->
    envelope
      event
      "requested"
      [ "keeper_name", `String (Keeper_id.Keeper_name.to_string request.keeper_name)
      ; "source_checkpoint", checkpoint request.source_checkpoint
      ; "trigger", Compaction_trigger.to_detail_json request.trigger
      ; "cause", `String (Operation.Cause.to_string request.cause)
      ; ( "producer_invocation"
        , match request.producer_invocation with
          | Some producer -> Tool_invocation_ref.to_yojson producer
          | None -> `Null )
      ]
  | Attempt_started attempt_id ->
    envelope
      event
      "attempt_started"
      [ "attempt_id", `String (Operation.Attempt_id.to_string attempt_id) ]
  | Candidate_prepared value ->
    envelope
      event
      "candidate_prepared"
      (candidate ~checkpoint_field:"candidate_checkpoint" value)
  | Attempt_failed (attempt_id, failure) ->
    let failure_kind, cause, observed_checkpoint =
      match failure with
      | Pre_commit_failure cause -> "pre_commit", cause, `Null
      | Candidate_not_installed { cause; observed_checkpoint } ->
        "candidate_not_installed", cause, checkpoint observed_checkpoint
    in
    envelope
      event
      "attempt_failed"
      [ "attempt_id", `String (Operation.Attempt_id.to_string attempt_id)
      ; "failure_kind", `String failure_kind
      ; "cause", `String (Operation.Cause.to_string cause)
      ; "observed_checkpoint", observed_checkpoint
      ]
  | Commit_reconciliation_required (value, reason) ->
    let reason =
      match reason with
      | Commit_durability_unknown -> "commit_durability_unknown"
      | Transaction_outcome_unknown -> "transaction_outcome_unknown"
    in
    envelope
      event
      "commit_reconciliation_required"
      (candidate ~checkpoint_field:"candidate_checkpoint" value
       @ [ "reason", `String reason ])
  | Source_superseded supersession ->
    envelope
      event
      "source_superseded"
      [ ( "attempt_id"
        , `String (Operation.Attempt_id.to_string supersession.attempt_id) )
      ; ( "observed_checkpoint"
        , match supersession.observed_checkpoint with
          | Some value -> checkpoint value
          | None -> `Null )
      ]
  | Compacted value ->
    envelope
      event
      "compacted"
      (candidate ~checkpoint_field:"committed_checkpoint" value)
  | No_compaction value ->
    envelope
      event
      "no_compaction"
      [ "attempt_id", `String (Operation.Attempt_id.to_string value.attempt_id)
      ; "source_checkpoint", checkpoint value.source_checkpoint
      ; "evidence", preserved_evidence value.evidence
      ]
  | Reinjected (adopted_checkpoint, adopting_turn) ->
    envelope
      event
      "reinjected"
      [ "adopted_checkpoint", checkpoint adopted_checkpoint
      ; "adopting_turn", Ids.Turn_ref.to_yojson adopting_turn
      ]
;;
