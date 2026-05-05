(** Tests for [Cascade_attempt_liveness_driver] (RFC-0022 PR-3/4). *)

open Masc_mcp
module D = Cascade_attempt_liveness_driver
module L = Cascade_attempt_liveness
module Mode = Env_config_keeper.CascadeAttemptLiveness
module T = Agent_sdk.Types

(* ─────────────────────── helpers ─────────────────────── *)

(* Tight budget so tests can drive the FSM into kills with small float
   deltas without sleeping. *)
let test_budget : L.budget = {
  ttft_max = 1.0;
  inter_chunk_max = 1.0;
  attempt_wall_max = 5.0;
}

let make ?(mode = Mode.Observe) ?(provider = "test_provider") () =
  D.create ~budget:test_budget ~mode ~provider_label:provider ~started_at:0.0

let text_delta_evt = T.ContentBlockDelta {
  index = 0;
  delta = T.TextDelta "x"
}

let counter_value () =
  Prometheus.get_metric_value Prometheus.metric_cascade_attempt_liveness_kill
    ~labels:[] () |> Option.value ~default:0.0

let kill_counter ~kind ~mode ~provider =
  Prometheus.get_metric_value Prometheus.metric_cascade_attempt_liveness_kill
    ~labels:[ "kind", kind; "mode", mode; "provider", provider ] ()
  |> Option.value ~default:0.0

(* ─────────────────────── decision-table behaviours ─────────────────────── *)

let test_observe_text_delta_keeps_continue () =
  let h = make () in
  let v = D.observe_sse h text_delta_evt 0.1 in
  Alcotest.(check bool) "observe_sse continues on text delta"
    true (v = D.Continue);
  match D.current_state h with
  | L.Streaming _ -> ()
  | _ -> Alcotest.fail "expected Streaming after answer_delta"

let test_observe_message_stop_marks_completed () =
  let h = make () in
  let _ = D.observe_sse h text_delta_evt 0.1 in
  let v = D.observe_sse h T.MessageStop 0.2 in
  Alcotest.(check bool) "MessageStop continues" true (v = D.Continue);
  match D.current_state h with
  | L.Success -> ()
  | _ -> Alcotest.fail "expected Success after MessageStop"

let test_observe_sse_error_is_inert () =
  let h = make () in
  let v = D.observe_sse h (T.SSEError "boom") 0.1 in
  Alcotest.(check bool) "SSEError is ignored" true (v = D.Continue);
  match D.current_state h with
  | L.Awaiting _ -> ()
  | _ -> Alcotest.fail "expected Awaiting unchanged after SSEError"

let test_tick_below_ttft_continues () =
  let h = make () in
  let v = D.on_tick h 0.5 in
  Alcotest.(check bool) "tick below TTFT" true (v = D.Continue)

let test_observe_tick_past_ttft_observe_logs_no_abort () =
  let provider = "obs_no_first" in
  let h = make ~provider () in
  (* Advance past ttft_max=1.0 with no chunk; FSM should report
     No_first_token, but observe-mode keeps the attempt alive. *)
  let before = kill_counter ~kind:"no_first_token" ~mode:"observe" ~provider in
  let v = D.on_tick h 1.5 in
  Alcotest.(check bool) "observe never aborts" true (v = D.Continue);
  let after = kill_counter ~kind:"no_first_token" ~mode:"observe" ~provider in
  Alcotest.(check bool) "observe records kill counter" true (after >= before +. 1.0)

let test_tick_past_ttft_enforce_aborts () =
  let provider = "enf_first" in
  let h = make ~mode:Mode.Enforce ~provider () in
  let before = kill_counter ~kind:"no_first_token" ~mode:"enforce" ~provider in
  let v = D.on_tick h 1.5 in
  Alcotest.(check bool) "enforce aborts" true (v = D.Abort);
  let after = kill_counter ~kind:"no_first_token" ~mode:"enforce" ~provider in
  Alcotest.(check bool) "enforce records kill counter" true (after >= before +. 1.0);
  match D.current_state h with
  | L.Failed L.No_first_token -> ()
  | _ -> Alcotest.fail "expected Failed No_first_token after enforce kill"

let test_tick_off_does_not_record () =
  let provider = "off_provider" in
  let h = make ~mode:Mode.Off ~provider () in
  let before = kill_counter ~kind:"no_first_token" ~mode:"off" ~provider in
  let v = D.on_tick h 1.5 in
  Alcotest.(check bool) "off never aborts" true (v = D.Continue);
  let after = kill_counter ~kind:"no_first_token" ~mode:"off" ~provider in
  Alcotest.(check (float 0.0)) "off does not record" before after

let test_inter_chunk_idle_observe_records () =
  let provider = "inter_obs" in
  let h = make ~provider () in
  (* Receive a chunk at 0.1, then wait past inter_chunk_max=1.0. *)
  let _ = D.observe_sse h text_delta_evt 0.1 in
  let before = kill_counter ~kind:"inter_chunk_idle" ~mode:"observe" ~provider in
  let v = D.on_tick h 1.5 in
  Alcotest.(check bool) "observe inter-chunk continues" true (v = D.Continue);
  let after = kill_counter ~kind:"inter_chunk_idle" ~mode:"observe" ~provider in
  Alcotest.(check bool) "observe records inter-chunk kill"
    true (after >= before +. 1.0)

let test_tick_period_is_at_most_quarter_of_min_budget () =
  let h = make () in
  let p = D.tick_period h in
  Alcotest.(check bool) "tick_period <= min(ttft, inter)/4"
    true (p <= 0.25 +. 1e-9);
  Alcotest.(check bool) "tick_period >= floor 0.05"
    true (p >= 0.05 -. 1e-9)

(* ─────────────────────── runner ─────────────────────── *)

let () =
  ignore (counter_value () : float);  (* warm up the lazy registration path *)
  let case name f = Alcotest.test_case name `Quick f in
  Alcotest.run "Cascade_attempt_liveness_driver"
    [
      ( "happy path",
        [
          case "text_delta → Continue + Streaming"
            test_observe_text_delta_keeps_continue;
          case "MessageStop → Continue + Success"
            test_observe_message_stop_marks_completed;
          case "SSEError is inert"
            test_observe_sse_error_is_inert;
          case "tick below TTFT continues"
            test_tick_below_ttft_continues;
        ] );
      ( "kills",
        [
          case "TTFT × Observe → Continue + counter incremented"
            test_observe_tick_past_ttft_observe_logs_no_abort;
          case "TTFT × Enforce → Abort + Failed + counter"
            test_tick_past_ttft_enforce_aborts;
          case "TTFT × Off → no counter"
            test_tick_off_does_not_record;
          case "Inter-chunk × Observe → counter incremented"
            test_inter_chunk_idle_observe_records;
        ] );
      ( "tick cadence",
        [
          case "tick_period bounded"
            test_tick_period_is_at_most_quarter_of_min_budget;
        ] );
    ]
