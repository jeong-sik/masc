let state_json = function
  | Keeper_chat_queue.Pending -> `Assoc [ "kind", `String "pending" ]
  | Keeper_chat_queue.Inflight { lease_id; started_at } ->
    `Assoc
      [ "kind", `String "inflight"
      ; "lease_id", `String lease_id
      ; "started_at", `Float started_at
      ]
  | Keeper_chat_queue.Recovery_required { lease_id; started_at } ->
    `Assoc
      [ "kind", `String "recovery_required"
      ; "lease_id", `String lease_id
      ; "started_at", `Float started_at
      ; "dispatchable", `Bool false
      ]
  | Keeper_chat_queue.Delivered completion ->
    `Assoc
      [ "kind", `String "delivered"
      ; "completed_at", `Float completion.completed_at
      ; "outcome_ref", Json_util.string_opt_to_json completion.outcome_ref
      ]
  | Keeper_chat_queue.Failed failure ->
    `Assoc
      [ "kind", `String "failed"
      ; "failure_kind", `String (Keeper_chat_queue.failure_kind_to_string failure.kind)
      ; "detail", `String (Observability_redact.redact_text failure.detail)
      ; "completed_at", `Float failure.completed_at
      ; "outcome_ref", Json_util.string_opt_to_json failure.outcome_ref
      ]
;;
let receipt_json ~keeper_name ~revision
    (receipt : Keeper_chat_queue.receipt_view) =
  `Assoc
    [ "schema", `String "keeper_chat_queue.receipt.v2"
    ; "keeper_name", `String keeper_name
    ; "receipt_id", `String (Keeper_chat_queue.Receipt_id.to_string receipt.receipt_id)
    ; "revision", `String (Int64.to_string revision)
    ; "state", state_json receipt.state
    ]
;;
