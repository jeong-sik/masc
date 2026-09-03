(** Response suppression is restricted to typed control checkpoints. Runtime
    budget and completion-contract observations preserve model output. *)

module Finalize = Masc.Keeper_replay_checkpoint
module Response_text = Masc.Keeper_agent_run_response_text
module Keeper_metrics = Keeper_metrics
module Metrics = Masc.Otel_metric_store

let input_required_request () : Agent_core.Error.input_required =
  { request_id = "wire-input-1"
  ; participant_name = Some "operator"
  ; question = "Which repository should I inspect?"
  ; schema = None
  ; timeout_s = None
  ; created_at = 1_000.0
  }

(* ── wire_capture_response_suppression_reasons / labels / metrics ───── *)

let test_wire_capture_suppression_reasons_emit_control_metric () =
  let reasons ~control_checkpoint ~terminal_effect_settled =
    Finalize.wire_capture_response_suppression_reasons
      ~control_checkpoint
      ~terminal_effect_settled
    |> List.map Finalize.wire_capture_response_suppression_reason_label
  in
  Alcotest.(check (list string))
    "no suppression"
    []
    (reasons ~control_checkpoint:false ~terminal_effect_settled:false);
  Alcotest.(check (list string))
    "control checkpoint"
    [ "control_checkpoint" ]
    (reasons ~control_checkpoint:true ~terminal_effect_settled:false);
  (* A Gate replay settles the post before the model speaks. If the model then
     answers in plain text without calling a tool, the run stops at [Completed]
     like any other, so [control_checkpoint] is false — only the outcome knows
     the reader already got the message. *)
  Alcotest.(check (list string))
    "terminal effect already settled"
    [ "terminal_effect_settled" ]
    (reasons ~control_checkpoint:false ~terminal_effect_settled:true);
  Alcotest.(check (list string))
    "both reasons are reported, not collapsed"
    [ "control_checkpoint"; "terminal_effect_settled" ]
    (reasons ~control_checkpoint:true ~terminal_effect_settled:true);
  let keeper_name = "wirecap_suppression_metric" in
  let labels reason = [ "keeper", keeper_name; "reason", reason ] in
  let control_labels = labels "control_checkpoint" in
  let terminal_labels = labels "terminal_effect_settled" in
  let metric_value ~labels =
    Metrics.metric_value_or_zero
      Keeper_metrics.(to_string WireCaptureResponseSuppressed)
      ~labels
      ()
  in
  let control_before = metric_value ~labels:control_labels in
  let terminal_before = metric_value ~labels:terminal_labels in
  Finalize.emit_wire_capture_response_suppressed_metrics
    ~keeper_name
    (Finalize.wire_capture_response_suppression_reasons
       ~control_checkpoint:true
       ~terminal_effect_settled:true);
  Alcotest.(check (float 0.0001))
    "control checkpoint metric increments"
    (control_before +. 1.0)
    (metric_value ~labels:control_labels);
  Alcotest.(check (float 0.0001))
    "terminal effect metric increments"
    (terminal_before +. 1.0)
    (metric_value ~labels:terminal_labels)
;;

(* ── consume_replay_response ────────────────────────────────── *)

let consume_response ~suppress_visible_response ~response_text =
  Finalize.consume_replay_response
    ~suppress_visible_response
    ~response_text
    ~consume:(fun ~response_text -> response_text)
;;

let test_replay_capture_keeps_visible_response_text () =
  Alcotest.(check (option string))
    "visible response is captured verbatim"
    (Some "Visible reply")
    (consume_response
       ~suppress_visible_response:false
       ~response_text:"Visible reply")
;;

let test_replay_capture_omits_suppressed_response_text () =
  Alcotest.(check (option string))
    "suppressed response is not captured even when response_text is non-empty"
    None
    (consume_response
       ~suppress_visible_response:true
       ~response_text:"leftover text")
;;

let test_replay_capture_omits_blank_response_text () =
  Alcotest.(check (option string))
    "blank replay response is not captured"
    None
    (consume_response
       ~suppress_visible_response:false
       ~response_text:"   ")
;;

let test_replay_capture_preserves_model_reply_before_visible_capture () =
  let finalized =
    Response_text.finalize
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
    (consume_response
       ~suppress_visible_response:false
       ~response_text:finalized.response_text)
;;

let test_input_required_question_is_not_suppressed_for_internal_source () =
  let request = input_required_request () in
  let stop_reason = Runtime_agent.InputRequired { turns_used = 2; request } in
  let finalized =
    Response_text.finalize
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
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text
      ()
  in
  Alcotest.(check string)
    "direct response observation keeps visible response"
    raw_response_text
    finalized.response_text
;;

let test_terminal_effect_completion_withholds_plain_provider_text_from_replay () =
  let suppress_response_text =
    Finalize.wire_capture_response_suppression_reasons
      ~control_checkpoint:false
      ~terminal_effect_settled:true
    <> []
  in
  let finalized =
    Response_text.finalize
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text:"The approved connector post already went out."
      ~suppress_response_text
      ()
  in
  Alcotest.(check bool)
    "plain provider text after a terminal replay stays out of replay"
    true
    finalized.withheld_from_replay;
  (* The words survive finalization. Keeping them out of replay and hiding them
     from the operator were one decision until #32727/#32660; only the first is
     this flag's business. *)
  Alcotest.(check string)
    "the keeper's words are not erased by the replay decision"
    "The approved connector post already went out."
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
    ; ( "consume_replay_response"
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
            "terminal replay suppresses plain provider text"
            `Quick
            test_terminal_effect_completion_withholds_plain_provider_text_from_replay
        ] )
    ]
;;
