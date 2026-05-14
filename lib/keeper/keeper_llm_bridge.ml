(* lib/keeper/keeper_llm_bridge.ml *)
(* OAS Adapter bridging Eio structured concurrency, multi-turn cascade rollbacks,
   and strict global stop preemptions as formally verified in KeeperOASAdvanced.tla. *)

let json_field name value = Some (name, value)
let json_string_field name value = json_field name (`String value)
let json_float_field name value = json_field name (`Float value)

let bridge_failure_envelope
    ?entity_id
    ?operator_action
    ~cause_code
    ~severity
    ~summary
    ~recoverability
    ~evidence_ref
    ()
  : Failure_envelope.t =
  {
    surface = "keeper_oas_bridge";
    entity_kind = "oas_execution";
    entity_id;
    cause_code;
    severity;
    summary;
    recoverability;
    operator_action;
    evidence_ref;
  }
;;

let bridge_details fields envelope =
  let fields = List.filter_map Fun.id fields in
  Failure_envelope.attach_to_details (`Assoc fields) envelope
;;

(** Runs a generic Eio execution (usually an OAS Agent.run or Model.call) with a strict
    structural timeout. If the execution is cancelled by a timeout or global stop,
    the exception is caught, OAS-local context mutations are discarded
    (functional rollback), external tool side effects are not reverted.

    Timeout returns [Agent_sdk.Error.Api (Timeout ...)].
    Missing Eio clock returns [Agent_sdk.Error.Internal] without running the
    function because the bridge cannot enforce the advertised structural
    timeout.
    Cancellation (server shutdown / parent fiber cancel) re-raises so the caller
    exits immediately instead of retrying. *)
let run_with_timeout_and_fallback ~timeout_s fn =
  let fail_without_clock ~site =
    let message =
      Printf.sprintf
        "keeper_llm_bridge: Eio clock unavailable (%s); refusing to run OAS execution \
         without enforcing timeout_s=%.0f"
        site
        timeout_s
    in
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_llm_bridge_failures
      ~labels:[ "site", "no_clock" ]
      ();
    let envelope =
      bridge_failure_envelope
        ~cause_code:"eio_clock_unavailable"
        ~severity:Failure_envelope.Critical
        ~summary:message
        ~recoverability:Failure_envelope.Operator_action_required
        ~operator_action:"check_masc_eio_env"
        ~evidence_ref:
          (`Assoc
            [
              ("site", `String site);
              ("timeout_sec", `Float timeout_s);
              ("timeout_enforced", `Bool false);
            ])
        ()
    in
    Log.Keeper.emit Log.Error
      ~details:
        (bridge_details
           [
             json_string_field "event" "keeper_oas_bridge_no_clock";
             json_string_field "site" site;
             json_float_field "timeout_sec" timeout_s;
             json_field "timeout_enforced" (`Bool false);
           ]
           envelope)
      message;
    Error (Agent_sdk.Error.Internal message)
  in
  match Masc_eio_env.get_opt () with
  | None -> fail_without_clock ~site:"env_not_initialized"
  | Some { Masc_eio_env.clock = None; _ } ->
    fail_without_clock ~site:"clock_not_initialized"
  | Some { Masc_eio_env.clock = Some clock; _ } ->
    let t0 = Eio.Time.now clock in
    let elapsed () = Eio.Time.now clock -. t0 in
    (try Eio.Time.with_timeout_exn clock timeout_s fn with
     | Eio.Time.Timeout ->
       let wall = elapsed () in
       (* #9639/#9662: Eio cancel is cooperative — [with_timeout_exn] fires
       but the fiber must reach a cancel point (single_read, yield, etc.)
       to actually interrupt. Surface overshoot as a structured warn so
       stalls remain observable instead of silently inflating wall time.

       2026-04-27 correction: the original "uncancellable region (native
       HTTP bulk read, syscall, non-yielding loop)" diagnosis was a
       guess and has been *falsified* by four raw-TCP reproducers ported
       to the OAS regression guard (jeong-sik/oas#1210,
       test/test_eio_cancellability.ml).  Buf_read.line + slow drip and
       read_sse + fast stream with trivial / sleeping / CPU-bound on_data
       callbacks all exit Eio.Time.with_timeout_exn within 1-2ms.  The
       layer producing prod hangs (>=1170s) is *not* yet identified;
       remaining suspects are caller on_event handlers, post_sync
       take_all + connection-not-closed, Switch cleanup, or TLS.

       Action: do NOT add yield points to OAS read_sse / Buf_read based
       on the original guess — that wrong-layer fix was almost shipped.
       During the next overshoot, run
       ~/me/scripts/oas-hung-keeper-dump.sh to capture the fiber stack
       and identify the real layer.  Cross-ref:
       jeong-sik/me planning/claude-plans/oas-execution-cancellability.md *)
       let deadline =
         Timeout_policy.Deadline.make
           ~layer:Timeout_policy.Layer.Oas_bridge
           ~origin:"keeper_llm_bridge"
           ~wall_cap_s:timeout_s
           ~now:t0
       in
       let _ : bool = Timeout_policy.overshoot_warn ~deadline ~actual_wall_s:wall () in
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_llm_bridge_failures
         ~labels:[ "site", "timeout" ]
         ();
       let message =
         Printf.sprintf
           "keeper_llm_bridge: OAS execution timed out after %.1fs (budget=%.0fs; OAS \
            context rollback only; external tool side effects are not reverted)"
           wall
           timeout_s
       in
       let envelope =
         bridge_failure_envelope
           ~cause_code:"oas_timeout_budget"
           ~severity:Failure_envelope.Bad
           ~summary:"OAS execution exceeded its keeper bridge timeout budget"
           ~recoverability:Failure_envelope.Operator_action_required
           ~operator_action:"inspect_timeout_budget"
           ~evidence_ref:
             (`Assoc
               [
                 ("timeout_sec", `Float timeout_s);
                 ("wall_sec", `Float wall);
                 ("overshoot_sec", `Float (Float.max 0.0 (wall -. timeout_s)));
                 ("rollback_scope", `String "oas_context_only");
                 ("external_tool_side_effects_reverted", `Bool false);
               ])
           ()
       in
       Log.Keeper.emit Log.Info
         ~details:
           (bridge_details
              [
                json_string_field "event" "keeper_oas_bridge_timeout";
                json_float_field "timeout_sec" timeout_s;
                json_float_field "wall_sec" wall;
                json_float_field "overshoot_sec" (Float.max 0.0 (wall -. timeout_s));
                json_string_field "rollback_scope" "oas_context_only";
                json_field "external_tool_side_effects_reverted" (`Bool false);
              ]
              envelope)
         message;
       Error
         (Agent_sdk.Error.Api
            (Timeout
               { message =
                   Printf.sprintf "Timeout after %.1fs (budget=%.0fs)" wall timeout_s
               }))
     | Eio.Cancel.Cancelled inner_exn as exn ->
       (* TLA+: FiberHandlesCancellation -> Rollback context.
          Cancelled means a parent fiber (server shutdown, global stop) requested
          cancellation — NOT a timeout. Re-raise so the keeper exits immediately
          instead of entering the retry loop.

          #10716: bimodal distribution observed in production — 21 events in
          [60, 300)s (short-tail, routine cancel: supervisor pause / cascade
          rotation) plus 8 events ≥1800s (long-tail, LLM provider hung). Same
          opaque message for both made root-cause attribution impossible.
          Categorize wall duration into a discrete bucket and surface the
          inner cancel exception so operators can split short_tail / mid_tail
          / long_tail in PromQL and the inner reason ([Eio.Cancel.Cancel_hook]
          payload, parent-fiber Cancelled, etc.) appears in the log. *)
       let bt = Printexc.get_raw_backtrace () in
       let wall = elapsed () in
       let bucket =
         if wall < 60.0
         then "fast"
         else if wall < 300.0
         then "short_tail"
         else if wall < 600.0
         then "mid_tail"
         else if wall < 1800.0
         then "long_mid"
         else "long_tail"
       in
       let inner_str =
         match inner_exn with
         | Failure msg -> "Failure(" ^ msg ^ ")"
         | _ -> Printexc.to_string inner_exn
       in
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_llm_bridge_failures
         ~labels:[ "site", "cancelled" ]
         ();
       let message =
         Printf.sprintf
           "keeper_llm_bridge: OAS execution cancelled after %.1fs bucket=%s inner=%s \
            (re-raising; OAS context rollback only; external tool side effects are not \
            reverted)"
           wall
           bucket
           inner_str
       in
       let envelope =
         bridge_failure_envelope
           ~cause_code:"oas_execution_cancelled"
           ~severity:Failure_envelope.Warn
           ~summary:"OAS execution was cancelled by parent fiber or shutdown"
           ~recoverability:Failure_envelope.Retryable
           ~evidence_ref:
             (`Assoc
               [
                 ("wall_sec", `Float wall);
                 ("bucket", `String bucket);
                 ("inner_exception", `String inner_str);
                 ("rollback_scope", `String "oas_context_only");
                 ("external_tool_side_effects_reverted", `Bool false);
               ])
           ()
       in
       Log.Keeper.emit Log.Warn
         ~details:
           (bridge_details
              [
                json_string_field "event" "keeper_oas_bridge_cancelled";
                json_float_field "wall_sec" wall;
                json_string_field "bucket" bucket;
                json_string_field "inner_exception" inner_str;
                json_string_field "rollback_scope" "oas_context_only";
                json_field "external_tool_side_effects_reverted" (`Bool false);
              ]
              envelope)
         message;
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_oas_cancel
         ~labels:[ "bucket", bucket ]
         ();
       Printexc.raise_with_backtrace exn bt
     | exn ->
       (* TLA+: HandleError -> Rollback context *)
       let bt = Printexc.get_backtrace () in
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_oas_execution_errors
         ~labels:[ "channel", "oas_bridge" ]
         ();
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_llm_bridge_failures
         ~labels:[ "site", "execution_error" ]
         ();
       let error = Printexc.to_string exn in
       let message =
         Printf.sprintf "keeper_llm_bridge: OAS execution error: %s\n%s" error bt
       in
       let envelope =
         bridge_failure_envelope
           ~cause_code:"oas_execution_error"
           ~severity:Failure_envelope.Bad
           ~summary:"OAS execution raised an unexpected exception"
           ~recoverability:Failure_envelope.Operator_action_required
           ~operator_action:"inspect_oas_bridge_error"
           ~evidence_ref:(`Assoc [ ("error", `String error) ])
           ()
       in
       Log.Keeper.emit Log.Error
         ~details:
           (bridge_details
              [
                json_string_field "event" "keeper_oas_bridge_execution_error";
                json_string_field "error" error;
              ]
              envelope)
         message;
       Error (Agent_sdk.Error.Internal error))
;;
