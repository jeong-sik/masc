
let keeper_trust_json ?(include_receipt = false)
    (config : Workspace.config) (meta : Keeper_meta_contract.keeper_meta) =
  let latest_receipt = Keeper_execution_receipt.latest_json config meta.name in
  let runtime_trust =
    if include_receipt
    then Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta
    else Keeper_runtime_trust_snapshot.summary_json ~config ~meta
  in
  let sandbox_json =
    match latest_receipt with
    | Some receipt -> Option.value ~default:`Null (Json_util.assoc_member_opt "sandbox" receipt)
    | None ->
        `Assoc
          [
            ("kind", `String (Keeper_types_profile_sandbox.sandbox_profile_to_string meta.sandbox_profile));
            ("sandbox_root", `String config.base_path);
            ("network_mode", `String (Keeper_types_profile_sandbox.network_mode_to_string meta.network_mode));
          ]
  in
  let approval_json =
    match latest_receipt with
    | Some receipt -> Option.value ~default:`Null (Json_util.assoc_member_opt "approval" receipt)
    | None -> `Assoc [ ("profile", `Null); ("derived", `Bool false) ]
  in
  let runtime_json =
    match latest_receipt with
    | Some receipt -> (
        match Json_util.assoc_member_opt "runtime" receipt with
        | Some json -> json
        | None -> `Null)
    | None ->
        `Assoc
          [
            ("name", `String (Keeper_meta_contract.runtime_id_of_meta meta));
            ("selected_model", `Null);
            ("attempt_count", `Int 0);
            ("fallback_applied", `Bool false);
            ("outcome", `String "not_observed");
          ]
  in
  `Assoc
    [
      ( "last_outcome",
        match latest_receipt with
        | Some receipt -> Option.value ~default:(`String "not_run") (Json_util.assoc_member_opt "outcome" receipt)
        | None -> `String "not_run" );
      ( "terminal_reason_code",
        match latest_receipt with
        | Some receipt -> Option.value ~default:(`String "no_receipt") (Json_util.assoc_member_opt "terminal_reason_code" receipt)
        | None -> `String "no_receipt" );
      (* The receipt's disposition as the trust snapshot parsed it: [null]
         when there is no receipt, or when the receipt's kind is not one the
         receipt module writes. The compact trust projections copy the same
         two fields from the same snapshot. *)
      ( "operator_disposition",
        Option.value ~default:`Null (Json_util.assoc_member_opt "operator_disposition" runtime_trust) );
      ( "operator_disposition_reason",
        Option.value ~default:`Null (Json_util.assoc_member_opt "operator_disposition_reason" runtime_trust) );
      ( "completion_contract_result",
        match latest_receipt with
        (* Missing receipt field stays a UI marker; this is not a runtime
           contract decision. *)
        (* sound-partial: allow *)
        | Some receipt -> Option.value ~default:(`String "unknown") (Json_util.assoc_member_opt "completion_contract_result" receipt)
        | None -> `String "unknown" );
      ("sandbox", sandbox_json);
      ("approval", approval_json);
      ("runtime", runtime_json);
      ("disposition", Option.value ~default:`Null (Json_util.assoc_member_opt "disposition" runtime_trust));
      ("disposition_reason", Option.value ~default:`Null (Json_util.assoc_member_opt "disposition_reason" runtime_trust));
      ("needs_attention", Option.value ~default:`Null (Json_util.assoc_member_opt "needs_attention" runtime_trust));
      ("attention_reason", Option.value ~default:`Null (Json_util.assoc_member_opt "attention_reason" runtime_trust));
      ("next_human_action", Option.value ~default:`Null (Json_util.assoc_member_opt "next_human_action" runtime_trust));
      ("approval_state", Option.value ~default:`Null (Json_util.assoc_member_opt "approval" runtime_trust));
      ("execution_summary", Option.value ~default:`Null (Json_util.assoc_member_opt "execution" runtime_trust));
      ( "latest_terminal_reason",
        Option.value ~default:`Null (Json_util.assoc_member_opt "latest_terminal_reason" runtime_trust) );
      ("latest_next_action", Option.value ~default:`Null (Json_util.assoc_member_opt "latest_next_action" runtime_trust));
      ("latest_causal_event", Option.value ~default:`Null (Json_util.assoc_member_opt "latest_causal_event" runtime_trust));
      ( "last_receipt_at",
        match latest_receipt with
        | Some receipt -> Option.value ~default:`Null (Json_util.assoc_member_opt "ended_at" receipt)
        | None -> `Null );
      ( "last_error",
        match latest_receipt with
        | Some receipt -> Option.value ~default:`Null (Json_util.assoc_member_opt "error" receipt)
        | None -> `Null );
      ( "last_receipt",
        if include_receipt then
          match latest_receipt with
          | Some receipt -> receipt
          | None -> `Null
        else
          `Null );
    ]

(* The trust fields of the row shown for a Keeper whose dashboard row could
   not be built. No receipt was read for it, so it reports no operator
   disposition: the snapshot's serializer writes [null] for both fields. *)
let degraded_keeper_trust_json ~site ~attention_reason =
  `Assoc
    (Keeper_runtime_trust_snapshot.trust_model_json_fields
       { Keeper_runtime_trust_snapshot_core.disposition = "Degraded"
       ; disposition_reason = site
       ; receipt_operator_disposition = None
       ; needs_attention = true
       ; attention_reason = Some attention_reason
       ; next_human_action = Some "inspect_keeper_dashboard_worker"
       })
;;
