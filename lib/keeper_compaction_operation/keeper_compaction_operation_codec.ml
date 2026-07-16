module Operation = Keeper_compaction_operation
module Support = Keeper_compaction_operation_codec_support
include Support

let ( let* ) = Result.bind
let to_json = Keeper_compaction_operation_json.to_json

let field ~path name decode fields =
  let* json = Support.required_field ~path name fields in
  decode ~path name json
;;

let nested ~path name decode fields =
  let* json = Support.required_field ~path name fields in
  decode ~path:(path ^ "." ^ name) json
;;

type candidate =
  { attempt_id : Operation.Attempt_id.t
  ; source_checkpoint : Keeper_checkpoint_ref.t
  ; candidate_checkpoint : Keeper_checkpoint_ref.t
  ; evidence : Keeper_compaction_evidence.t
  }

let candidate ~path ~checkpoint_field fields =
  let* attempt_id = field ~path "attempt_id" Support.attempt_id fields in
  let* source_checkpoint =
    nested ~path "source_checkpoint" Support.checkpoint fields
  in
  let* candidate_checkpoint =
    nested ~path checkpoint_field Support.checkpoint fields
  in
  let* evidence = nested ~path "evidence" Support.evidence fields in
  Ok { attempt_id; source_checkpoint; candidate_checkpoint; evidence }
;;

let candidate_fields checkpoint_field =
  [ "attempt_id"; "source_checkpoint"; checkpoint_field; "evidence" ]
;;

let decode_candidate ~operation_id ~checkpoint_field ~make payload =
  let path = "payload" in
  let fields = candidate_fields checkpoint_field in
  let* values = Support.exact_object ~path ~allowed:fields ~required:fields payload in
  let* value = candidate ~path ~checkpoint_field values in
  Ok (make value ~operation_id)
;;

let decode_requested ~operation_id payload =
  let path = "payload" in
  let fields =
    [ "keeper_name"
    ; "source_checkpoint"
    ; "trigger"
    ; "cause"
    ; "producer_invocation"
    ]
  in
  let* values = Support.exact_object ~path ~allowed:fields ~required:fields payload in
  let* keeper_name = field ~path "keeper_name" Support.keeper_name values in
  let* source_checkpoint =
    nested ~path "source_checkpoint" Support.checkpoint values
  in
  let* trigger = nested ~path "trigger" Support.trigger values in
  let* cause = field ~path "cause" Support.cause values in
  let* producer_json = Support.required_field ~path "producer_invocation" values in
  let* producer_invocation = Support.producer_invocation producer_json in
  Ok
    (Operation.requested
       ~operation_id
       ~keeper_name
       ~source_checkpoint
       ~trigger
       ~cause
       ~producer_invocation)
;;

let decode_attempt_started ~operation_id payload =
  let path = "payload" in
  let fields = [ "attempt_id" ] in
  let* values = Support.exact_object ~path ~allowed:fields ~required:fields payload in
  let* attempt_id = field ~path "attempt_id" Support.attempt_id values in
  Ok (Operation.attempt_started ~operation_id ~attempt_id)
;;

let decode_attempt_failed ~operation_id payload =
  let path = "payload" in
  let fields = [ "attempt_id"; "failure_kind"; "cause"; "observed_checkpoint" ] in
  let* values = Support.exact_object ~path ~allowed:fields ~required:fields payload in
  let* attempt_id = field ~path "attempt_id" Support.attempt_id values in
  let* failure_kind = field ~path "failure_kind" Support.string_field values in
  let* cause = field ~path "cause" Support.cause values in
  let* observed = Support.required_field ~path "observed_checkpoint" values in
  let* failure =
    match failure_kind, observed with
    | "pre_commit", `Null -> Ok (Operation.Pre_commit_failure cause)
    | "pre_commit", _ ->
      Error
        (Support.Invalid_field
           (Support.Wrong_type
              { path; field = "observed_checkpoint"; expected = "null" }))
    | "candidate_not_installed", json ->
      let* observed_checkpoint =
        Support.checkpoint ~path:"payload.observed_checkpoint" json
      in
      Ok (Operation.Candidate_not_installed { cause; observed_checkpoint })
    | unknown, _ -> Error (Support.Unknown_failure_kind unknown)
  in
  Ok (Operation.attempt_failed ~operation_id ~attempt_id ~failure)
;;

let decode_reconciliation ~operation_id payload =
  let path = "payload" in
  let fields = candidate_fields "candidate_checkpoint" @ [ "reason" ] in
  let* values = Support.exact_object ~path ~allowed:fields ~required:fields payload in
  let* value = candidate ~path ~checkpoint_field:"candidate_checkpoint" values in
  let* reason = field ~path "reason" Support.string_field values in
  let* reason =
    match reason with
    | "commit_durability_unknown" -> Ok Operation.Commit_durability_unknown
    | "transaction_outcome_unknown" -> Ok Operation.Transaction_outcome_unknown
    | unknown -> Error (Support.Unknown_reconciliation_reason unknown)
  in
  Ok
    (Operation.commit_reconciliation_required
       ~operation_id
       ~attempt_id:value.attempt_id
       ~source_checkpoint:value.source_checkpoint
       ~candidate_checkpoint:value.candidate_checkpoint
       ~evidence:value.evidence
       ~reason)
;;

let decode_reinjected ~operation_id payload =
  let path = "payload" in
  let fields = [ "adopted_checkpoint"; "adopting_turn" ] in
  let* values = Support.exact_object ~path ~allowed:fields ~required:fields payload in
  let* adopted_checkpoint =
    nested ~path "adopted_checkpoint" Support.checkpoint values
  in
  let* turn_json = Support.required_field ~path "adopting_turn" values in
  let* adopting_turn = Support.turn_ref turn_json in
  Ok (Operation.reinjected ~operation_id ~adopted_checkpoint ~adopting_turn)
;;

let decode_source_superseded ~operation_id payload =
  let path = "payload" in
  let fields = [ "attempt_id"; "observed_checkpoint" ] in
  let* values = Support.exact_object ~path ~allowed:fields ~required:fields payload in
  let* attempt_id = field ~path "attempt_id" Support.attempt_id values in
  let* observed_json = Support.required_field ~path "observed_checkpoint" values in
  let* observed_checkpoint =
    match observed_json with
    | `Null -> Ok None
    | json ->
      Support.checkpoint ~path:"payload.observed_checkpoint" json
      |> Result.map Option.some
  in
  Ok
    (Operation.source_superseded
       ~operation_id
       ~attempt_id
       ~observed_checkpoint)
;;

let of_json json =
  let path = "$" in
  let fields = [ "kind"; "operation_id"; "payload" ] in
  let* values = Support.exact_object ~path ~allowed:fields ~required:fields json in
  let* kind = field ~path "kind" Support.string_field values in
  let* operation_id = field ~path "operation_id" Support.operation_id values in
  let* payload = Support.required_field ~path "payload" values in
  match kind with
  | "requested" -> decode_requested ~operation_id payload
  | "attempt_started" -> decode_attempt_started ~operation_id payload
  | "candidate_prepared" ->
    decode_candidate
      ~operation_id
      ~checkpoint_field:"candidate_checkpoint"
      ~make:(fun value ~operation_id ->
        Operation.candidate_prepared
          ~operation_id
          ~attempt_id:value.attempt_id
          ~source_checkpoint:value.source_checkpoint
          ~candidate_checkpoint:value.candidate_checkpoint
          ~evidence:value.evidence)
      payload
  | "attempt_failed" -> decode_attempt_failed ~operation_id payload
  | "commit_reconciliation_required" ->
    decode_reconciliation ~operation_id payload
  | "source_superseded" -> decode_source_superseded ~operation_id payload
  | "compacted" ->
    decode_candidate
      ~operation_id
      ~checkpoint_field:"committed_checkpoint"
      ~make:(fun value ~operation_id ->
        Operation.compacted
          ~operation_id
          ~attempt_id:value.attempt_id
          ~source_checkpoint:value.source_checkpoint
          ~committed_checkpoint:value.candidate_checkpoint
          ~evidence:value.evidence)
      payload
  | "reinjected" -> decode_reinjected ~operation_id payload
  | unknown -> Error (Support.Unknown_event_kind unknown)
;;
