(** Response suppression is restricted to typed control checkpoints. Runtime
    budget and completion-contract observations preserve model output. *)

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

let test_wire_capture_suppression_reasons_emit_control_metric () =
  let reasons ~control_checkpoint =
    Finalize.wire_capture_response_suppression_reasons
      ~control_checkpoint
    |> List.map Finalize.wire_capture_response_suppression_reason_label
  in
  Alcotest.(check (list string))
    "no suppression"
    []
    (reasons ~control_checkpoint:false);
  Alcotest.(check (list string))
    "control checkpoint"
    [ "control_checkpoint" ]
    (reasons ~control_checkpoint:true);
  let keeper_name = "wirecap_suppression_metric" in
  let labels reason = [ ("keeper", keeper_name); ("reason", reason) ] in
  let control_labels = labels "control_checkpoint" in
  let metric_value ~labels =
    Metrics.metric_value_or_zero
      Keeper_metrics.(to_string WireCaptureResponseSuppressed)
      ~labels
      ()
  in
  let control_before = metric_value ~labels:control_labels in
  Finalize.emit_wire_capture_response_suppressed_metrics
    ~keeper_name
    (Finalize.wire_capture_response_suppression_reasons ~control_checkpoint:true);
  Alcotest.(check (float 0.0001))
    "control checkpoint metric increments"
    (control_before +. 1.0)
    (metric_value ~labels:control_labels)
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

let test_replay_capture_preserves_model_reply_before_visible_capture () =
  let finalized =
    Response_text.finalize
      ~completion_contract_result:Receipt.Completion_response_observed
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text:"First line from model\nVisible reply"
      ()
  in
  Alcotest.(check string)
    "model reply preserved before capture decision"
    "First line from model\nVisible reply"
    finalized.response_text;
  Alcotest.(check (option string))
    "visible finalized response is captured"
    (Some "First line from model\nVisible reply")
    (Finalize.replay_response_text_for_capture
       ~suppress_visible_response:false
       ~response_text:finalized.response_text)
;;

let test_input_required_question_is_not_suppressed_for_internal_source () =
  let request = input_required_request () in
  let stop_reason = Runtime_agent.InputRequired { turns_used = 2; request } in
  let finalized =
    Response_text.finalize
      ~completion_contract_result:Receipt.Completion_observation_unknown
      ~stop_reason
      ~raw_response_text:request.question
      ()
  in
  Alcotest.(check string)
    "typed input question remains visible"
    request.question
    finalized.response_text
;;

(* ── Keeper_agent_run_response_text.finalize ── *)

let test_direct_response_observation_preserves_raw_response_text () =
  let raw_response_text =
    "I cannot act on that from the current keeper state, but I am still here."
  in
  let finalized =
    Response_text.finalize
      ~completion_contract_result:Receipt.Completion_response_observed
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text
      ()
  in
  Alcotest.(check string)
    "direct response observation keeps visible response"
    raw_response_text
    finalized.response_text
;;

let test_internal_response_observation_preserves_raw_response_text () =
  let raw_response_text =
    "No actionable signal. I will wait for a future autonomous cycle."
  in
  let finalized =
    Response_text.finalize
      ~completion_contract_result:Receipt.Completion_response_observed
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text
      ()
  in
  Alcotest.(check string)
    "response observation preserves visible response"
    raw_response_text
    finalized.response_text
;;

let test_turn_limit_observation_preserves_response_text_by_default () =
  let raw_response_text = "Continuation checkpoint saved; keeper remains scheduled" in
  let finalized =
    Response_text.finalize
      ~completion_contract_result:Receipt.Completion_response_observed
      ~stop_reason:(Runtime_agent.TurnLimitObserved { turns_used = 3; limit = 3 })
      ~raw_response_text
      ()
  in
  Alcotest.(check string)
    "turn-limit observation preserves response text"
    raw_response_text
    finalized.response_text
;;

let test_contract_observation_finalizer_preserves_response_text_by_default () =
  let raw_response_text = "Attempted work but produced no tool call." in
  let finalized =
    Response_text.finalize
      ~completion_contract_result:Receipt.Completion_no_visible_output
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text
      ()
  in
  Alcotest.(check string)
    "completion-contract observation preserves response text"
    raw_response_text
    finalized.response_text
;;

let test_recovery_defer_finalizer_drops_response_text_by_default () =
  let finalized =
    Response_text.finalize
      ~completion_contract_result:Receipt.Completion_observation_unknown
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
            test_wire_capture_suppression_reasons_emit_control_metric
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
            test_replay_capture_preserves_model_reply_before_visible_capture
        ] )
    ; ( "typed_control_response"
      , [ Alcotest.test_case
            "InputRequired remains visible"
            `Quick
            test_input_required_question_is_not_suppressed_for_internal_source
        ] )
    ; ( "keeper_agent_run_response_text.finalize"
      , [ Alcotest.test_case
            "direct response observation preserves raw response text"
            `Quick
            test_direct_response_observation_preserves_raw_response_text
        ; Alcotest.test_case
            "response observation preserves raw response text"
            `Quick
            test_internal_response_observation_preserves_raw_response_text
        ; Alcotest.test_case
            "turn-limit observation preserves by default"
            `Quick
            test_turn_limit_observation_preserves_response_text_by_default
        ; Alcotest.test_case
            "contract observation preserves by default"
            `Quick
            test_contract_observation_finalizer_preserves_response_text_by_default
        ; Alcotest.test_case
            "typed recovery checkpoint auto-suppresses by default"
            `Quick
            test_recovery_defer_finalizer_drops_response_text_by_default
        ] )
    ]
;;
