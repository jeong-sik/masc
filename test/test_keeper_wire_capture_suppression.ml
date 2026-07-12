(** Restores behavioral coverage for the wire-capture response-suppression
    surface that PR #23929 (588-file [STATE]/BDI purge) swept out along with
    test/test_keeper_state_snapshot_json.ml. The production code exercised
    here has nothing to do with [STATE]/BDI and remained live at HEAD with
    zero test consumers after the deletion:
      - Keeper_agent_run_finalize_response: wire_capture_response_suppression_reasons,
        wire_capture_response_suppression_reason_label,
        emit_wire_capture_response_suppressed_metrics, replay_response_text_for_capture
      - Keeper_agent_run_response_text: completion_contract_suppresses_visible_response,
        finalize (budget/control-checkpoint/attention auto-suppress default)

    Excluded from restoration: assertions on the deleted [STATE] snapshot
    fields (state_snapshot_source, state_snapshot.decisions) and
    checkpoint_for_replay_persistence — both were purged along with the
    [STATE]/BDI protocol and have no live equivalent to test against. *)

module Finalize = Masc.Keeper_agent_run_finalize_response.For_testing
module Response_text = Masc.Keeper_agent_run_response_text
module Receipt = Masc.Keeper_execution_receipt
module Keeper_metrics = Keeper_metrics
module Metrics = Masc.Otel_metric_store

let input_required_request () : Agent_sdk.Error.input_required =
  { request_id = "wire-input-1"
  ; participant_name = Some "operator"
  ; question = "Which repository should I inspect?"
  ; schema = None
  ; timeout_s = None
  ; created_at = 1_000.0
  }

(* ── wire_capture_response_suppression_reasons / labels / metrics ───── *)

let test_wire_capture_suppression_reasons_emit_all_cause_metrics () =
  let reasons
        ~budget_exhausted
        ~control_checkpoint
        ~contract_suppresses_visible_response
    =
    Finalize.wire_capture_response_suppression_reasons
      ~budget_exhausted
      ~control_checkpoint
      ~contract_suppresses_visible_response
    |> List.map Finalize.wire_capture_response_suppression_reason_label
  in
  Alcotest.(check (list string))
    "no suppression"
    []
    (reasons
       ~budget_exhausted:false
       ~control_checkpoint:false
       ~contract_suppresses_visible_response:false);
  Alcotest.(check (list string))
    "budget exhausted"
    [ "budget_exhausted" ]
    (reasons
       ~budget_exhausted:true
       ~control_checkpoint:false
       ~contract_suppresses_visible_response:false);
  Alcotest.(check (list string))
    "control checkpoint"
    [ "control_checkpoint" ]
    (reasons
       ~budget_exhausted:false
       ~control_checkpoint:true
       ~contract_suppresses_visible_response:false);
  Alcotest.(check (list string))
    "completion contract"
    [ "completion_contract" ]
    (reasons
       ~budget_exhausted:false
       ~control_checkpoint:false
       ~contract_suppresses_visible_response:true);
  Alcotest.(check (list string))
    "both cause labels preserved"
    [ "budget_exhausted"; "completion_contract" ]
    (reasons
       ~budget_exhausted:true
       ~control_checkpoint:false
       ~contract_suppresses_visible_response:true);
  let keeper_name = "wirecap_suppression_metric" in
  let labels reason = [ ("keeper", keeper_name); ("reason", reason) ] in
  let budget_labels = labels "budget_exhausted" in
  let control_labels = labels "control_checkpoint" in
  let contract_labels = labels "completion_contract" in
  let metric_value ~labels =
    Metrics.metric_value_or_zero
      Keeper_metrics.(to_string WireCaptureResponseSuppressed)
      ~labels
      ()
  in
  let budget_before = metric_value ~labels:budget_labels in
  let control_before = metric_value ~labels:control_labels in
  let contract_before = metric_value ~labels:contract_labels in
  Finalize.emit_wire_capture_response_suppressed_metrics
    ~keeper_name
    (Finalize.wire_capture_response_suppression_reasons
       ~budget_exhausted:true
       ~control_checkpoint:true
       ~contract_suppresses_visible_response:true);
  Alcotest.(check (float 0.0001))
    "budget exhausted metric increments"
    (budget_before +. 1.0)
    (metric_value ~labels:budget_labels);
  Alcotest.(check (float 0.0001))
    "control checkpoint metric increments"
    (control_before +. 1.0)
    (metric_value ~labels:control_labels);
  Alcotest.(check (float 0.0001))
    "completion contract metric increments"
    (contract_before +. 1.0)
    (metric_value ~labels:contract_labels)
;;

(* ── replay_response_text_for_capture ────────────────────────────────── *)

let test_replay_capture_keeps_visible_response_text () =
  Alcotest.(check (option string))
    "visible response is captured verbatim"
    (Some "Visible reply")
    (Finalize.replay_response_text_for_capture
       ~suppress_visible_response:false
       ~response_text:"Visible reply")
;;

let test_replay_capture_omits_suppressed_response_text () =
  Alcotest.(check (option string))
    "suppressed response is not captured even when response_text is non-empty"
    None
    (Finalize.replay_response_text_for_capture
       ~suppress_visible_response:true
       ~response_text:"leftover text")
;;

let test_replay_capture_omits_blank_response_text () =
  Alcotest.(check (option string))
    "blank replay response is not captured"
    None
    (Finalize.replay_response_text_for_capture
       ~suppress_visible_response:false
       ~response_text:"   ")
;;

let test_replay_capture_strips_internal_markup_before_visible_capture () =
  let finalized =
    Response_text.finalize
      ~completion_contract_result:Receipt.Contract_satisfied_completion
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text:"SKILL: routing metadata\nVisible reply"
      ()
  in
  Alcotest.(check string)
    "internal reply markup stripped before capture decision"
    "Visible reply"
    finalized.response_text;
  Alcotest.(check (option string))
    "visible finalized response is captured"
    (Some "Visible reply")
    (Finalize.replay_response_text_for_capture
       ~suppress_visible_response:false
       ~response_text:finalized.response_text)
;;

(* ── completion_contract_suppresses_visible_response (passive-only) ─── *)

let passive_suppresses_for_source source =
  Response_text.completion_contract_suppresses_visible_response
    ~history_assistant_source:source
    Receipt.Contract_passive_only
;;

let test_direct_passive_only_is_not_suppressed () =
  Alcotest.(check bool)
    "direct-channel passive-only reply stays visible"
    false
    (passive_suppresses_for_source "direct_assistant")
;;

let test_internal_passive_only_is_suppressed () =
  Alcotest.(check bool)
    "internal-channel passive-only reply is suppressed"
    true
    (passive_suppresses_for_source "internal_assistant")
;;

let test_input_required_question_is_not_suppressed_for_internal_source () =
  let request = input_required_request () in
  let stop_reason = Runtime_agent.InputRequired { turns_used = 2; request } in
  let suppressed =
    Response_text.completion_contract_suppresses_visible_response_for_stop_reason
      ~history_assistant_source:"internal_assistant"
      ~stop_reason
      Receipt.Contract_passive_only
  in
  Alcotest.(check bool)
    "typed input question overrides passive internal suppression"
    false
    suppressed;
  let finalized =
    Response_text.finalize
      ~completion_contract_result:Receipt.Contract_passive_only
      ~stop_reason
      ~raw_response_text:request.question
      ~suppress_response_text:suppressed
      ()
  in
  Alcotest.(check string)
    "typed input question remains visible"
    request.question
    finalized.response_text
;;

(* ── Keeper_agent_run_response_text.finalize: passive-only + auto-suppress ── *)

let test_direct_passive_only_finalizer_preserves_raw_response_text () =
  let raw_response_text =
    "I cannot act on that from the current keeper state, but I am still here."
  in
  let finalized =
    Response_text.finalize
      ~completion_contract_result:Receipt.Contract_passive_only
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text
      ~suppress_response_text:(passive_suppresses_for_source "direct_assistant")
      ()
  in
  Alcotest.(check string)
    "direct passive-only keeps visible response"
    raw_response_text
    finalized.response_text
;;

let test_internal_passive_only_finalizer_drops_raw_response_text () =
  let finalized =
    Response_text.finalize
      ~completion_contract_result:Receipt.Contract_passive_only
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text:
        "No actionable signal. I will wait for a future autonomous cycle."
      ~suppress_response_text:(passive_suppresses_for_source "internal_assistant")
      ()
  in
  Alcotest.(check string)
    "internal passive-only drops visible response"
    ""
    finalized.response_text
;;

let test_budget_exhausted_finalizer_drops_response_text_by_default () =
  let finalized =
    Response_text.finalize
      ~completion_contract_result:Receipt.Contract_satisfied_completion
      ~stop_reason:(Runtime_agent.TurnBudgetExhausted { turns_used = 3; limit = 3 })
      ~raw_response_text:"Continuation checkpoint saved; keeper remains scheduled"
      ()
  in
  Alcotest.(check string)
    "turn-budget exhaustion auto-suppresses response text with no explicit override"
    ""
    finalized.response_text
;;

let test_contract_requires_attention_finalizer_drops_response_text_by_default () =
  let finalized =
    Response_text.finalize
      ~completion_contract_result:Receipt.Contract_violated
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text:"Attempted work but violated the tool contract."
      ()
  in
  Alcotest.(check string)
    "contract-requires-attention auto-suppresses response text with no explicit override"
    ""
    finalized.response_text
;;

let test_recovery_defer_finalizer_drops_response_text_by_default () =
  let finalized =
    Response_text.finalize
      ~completion_contract_result:Receipt.Contract_passive_only
      ~stop_reason:
        (Runtime_agent.ToolFailureRecoveryDeferred
           { turns_used = 2
           ; reason = "wait for repository state"
           ; tool_names = [ "Execute" ]
           })
      ~raw_response_text:"No textual reply was produced. Tools invoked: Execute."
      ()
  in
  Alcotest.(check string)
    "typed recovery checkpoint never becomes a chat reply"
    ""
    finalized.response_text
;;

let () =
  Alcotest.run
    "keeper_wire_capture_suppression"
    [ ( "wire_capture_response_suppression_reasons"
      , [ Alcotest.test_case
            "reason combinations + labels + metric emission"
            `Quick
            test_wire_capture_suppression_reasons_emit_all_cause_metrics
        ] )
    ; ( "replay_response_text_for_capture"
      , [ Alcotest.test_case
            "keeps visible response text"
            `Quick
            test_replay_capture_keeps_visible_response_text
        ; Alcotest.test_case
            "omits suppressed response text"
            `Quick
            test_replay_capture_omits_suppressed_response_text
        ; Alcotest.test_case
            "omits blank response text"
            `Quick
            test_replay_capture_omits_blank_response_text
        ; Alcotest.test_case
            "strips internal markup before visible capture"
            `Quick
            test_replay_capture_strips_internal_markup_before_visible_capture
        ] )
    ; ( "completion_contract_suppresses_visible_response"
      , [ Alcotest.test_case
            "direct-channel passive-only is not suppressed"
            `Quick
            test_direct_passive_only_is_not_suppressed
        ; Alcotest.test_case
            "internal-channel passive-only is suppressed"
            `Quick
            test_internal_passive_only_is_suppressed
        ; Alcotest.test_case
            "InputRequired remains visible on internal source"
            `Quick
            test_input_required_question_is_not_suppressed_for_internal_source
        ] )
    ; ( "keeper_agent_run_response_text.finalize"
      , [ Alcotest.test_case
            "direct passive-only finalizer preserves raw response text"
            `Quick
            test_direct_passive_only_finalizer_preserves_raw_response_text
        ; Alcotest.test_case
            "internal passive-only finalizer drops raw response text"
            `Quick
            test_internal_passive_only_finalizer_drops_raw_response_text
        ; Alcotest.test_case
            "turn-budget exhaustion auto-suppresses by default"
            `Quick
            test_budget_exhausted_finalizer_drops_response_text_by_default
        ; Alcotest.test_case
            "contract-requires-attention auto-suppresses by default"
            `Quick
            test_contract_requires_attention_finalizer_drops_response_text_by_default
        ; Alcotest.test_case
            "typed recovery checkpoint auto-suppresses by default"
            `Quick
            test_recovery_defer_finalizer_drops_response_text_by_default
        ] )
    ]
;;
