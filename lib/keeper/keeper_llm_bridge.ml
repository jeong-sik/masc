(* lib/keeper/keeper_llm_bridge.ml *)
(* OAS Adapter bridging Eio structured concurrency, multi-turn runtime rollbacks,
   and strict global stop preemptions as formally verified in KeeperOASAdvanced.tla. *)

let json_field name value = Some (name, value)
let json_string_field name value = json_field name (`String value)
let json_float_field name value = json_field name (`Float value)
let surface_keeper_oas_bridge = "keeper_oas_bridge"
let entity_kind_oas_execution = "oas_execution"

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
    surface = surface_keeper_oas_bridge;
    entity_kind = entity_kind_oas_execution;
    entity_id;
    cause_code;
    severity;
    summary;
    recoverability;
    operator_action;
    evidence_ref;
  }
;;

let label_site = "site"
let label_channel = "channel"
let label_bucket = "bucket"
let key_site = "site"
let key_timeout_sec = "timeout_sec"
let key_timeout_enforced = "timeout_enforced"
let key_wall_sec = "wall_sec"
let key_overshoot_sec = "overshoot_sec"
let key_bucket = "bucket"
let key_inner_exception = "inner_exception"
let key_cancel_classification = "cancel_classification"
let key_rollback_scope = "rollback_scope"
let key_external_tool_side_effects_reverted = "external_tool_side_effects_reverted"
let key_error = "error"
let field_event = "event"
let field_site = "site"
let field_timeout_sec = "timeout_sec"
let field_timeout_enforced = "timeout_enforced"
let field_wall_sec = "wall_sec"
let field_bucket = "bucket"
let field_inner_exception = "inner_exception"
let field_log_class = "log_class"
let field_cancel_classification = "cancel_classification"
let field_error = "error"
let field_rollback_scope = "rollback_scope"
let field_external_tool_side_effects_reverted = "external_tool_side_effects_reverted"
let field_overshoot_sec = "overshoot_sec"
let rollback_scope_oas_context_only = "oas_context_only"
let cause_code_eio_clock_unavailable = "eio_clock_unavailable"
let cause_code_oas_execution_cancelled = "oas_execution_cancelled"
let cause_code_oas_execution_error = "oas_execution_error"
let operator_action_check_masc_eio_env = "check_masc_eio_env"
let operator_action_inspect_oas_bridge_error = "inspect_oas_bridge_error"
let site_no_clock = "no_clock"
let site_timeout = "timeout"
let cause_code_provider_timeout = "provider_timeout"
let site_cancelled = "cancelled"
let site_execution_error = "execution_error"
let channel_oas_bridge = "oas_bridge"
(* cancel-bucket labels + of_wall classifier moved to Cancel_wall_bucket
   (SSOT, 2026-06-24): boundaries are shared with masc_oas_bridge so the
   two cancel-metric sources stay unionable (#10942). *)


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

type cancel_classification =
  | Unknown_cancel
  | Inner_timeout_cancel
  | Routine_parent_cancel

let string_of_cancel_classification = function
  | Unknown_cancel -> "unknown_cancel"
  | Inner_timeout_cancel -> "inner_timeout_cancel"
  | Routine_parent_cancel -> "routine_parent_cancel"
;;

let cancel_log_level = function
  | Inner_timeout_cancel | Routine_parent_cancel -> Log.Info
  | Unknown_cancel -> Log.Warn
;;

let log_class_of_cancel_classification = function
  | Inner_timeout_cancel -> "inner_timeout_cancel"
  | Routine_parent_cancel -> "routine_parent_cancel"
  | Unknown_cancel -> "warn_cancel"
;;

let is_eio_time_timeout = function
  | Eio.Time.Timeout -> true
  | _ -> false
;;

let cancelled_timeout_exceeded ~timeout_s ~wall inner_exn =
  is_eio_time_timeout inner_exn && Float.compare wall timeout_s >= 0
;;

let classify_cancel ~cancel_classification inner_exn =
  match cancel_classification with
  | Unknown_cancel when is_eio_time_timeout inner_exn -> Inner_timeout_cancel
  | Unknown_cancel | Inner_timeout_cancel | Routine_parent_cancel ->
    cancel_classification
;;

let run_with_timeout_and_fallback
    ?(cancel_classification = Unknown_cancel)
    ~timeout_s
    fn
  =
  let fail_without_clock ~site =
    let message =
      Printf.sprintf
        "keeper_llm_bridge: Eio clock unavailable (%s); refusing to run OAS execution \
         without enforcing timeout_s=%.0f"
        site
        timeout_s
    in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string LlmBridgeFailures)
      ~labels:[label_site, site_no_clock ]
      ();
    let envelope =
      bridge_failure_envelope
        ~cause_code:cause_code_eio_clock_unavailable
        ~severity:Failure_envelope.Critical
        ~summary:message
        ~recoverability:Failure_envelope.Operator_action_required
        ~operator_action:operator_action_check_masc_eio_env
        ~evidence_ref:
          (`Assoc
            [
              (key_site, `String site);
              (key_timeout_sec, `Float timeout_s);
              (key_timeout_enforced, `Bool false);
            ])
        ()
    in
    Log.Keeper.emit Log.Error
      ~details:
        (bridge_details
           [
             json_string_field field_event "keeper_oas_bridge_no_clock";
             json_string_field field_site site;
             json_float_field field_timeout_sec timeout_s;
             json_field field_timeout_enforced (`Bool false);
           ]
           envelope)
      message;
    Error (Agent_sdk.Error.Internal message)
  in
  match Masc_eio_env.get_opt () with
  | None -> fail_without_clock ~site:"env_not_initialized"
  | Some { Masc_eio_env.clock; _ } ->
    let t0 = Eio.Time.now clock in
    let elapsed () = Eio.Time.now clock -. t0 in
    let timeout_error ~wall =
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
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string LlmBridgeFailures)
        ~labels:[label_site, site_timeout ]
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
          ~cause_code:cause_code_provider_timeout
          ~severity:Failure_envelope.Bad
          ~summary:"Provider execution exceeded its keeper bridge timeout"
          ~recoverability:Failure_envelope.Operator_action_required
          ~operator_action:"inspect_provider_stream"
          ~evidence_ref:
            (`Assoc
              [
                (key_timeout_sec, `Float timeout_s);
                (key_wall_sec, `Float wall);
                (key_overshoot_sec, `Float (Float.max 0.0 (wall -. timeout_s)));
                (key_rollback_scope, `String rollback_scope_oas_context_only);
                (key_external_tool_side_effects_reverted, `Bool false);
              ])
          ()
      in
      Log.Keeper.emit Log.Info
        ~details:
          (bridge_details
             [
               json_string_field field_event "keeper_oas_bridge_timeout";
               json_float_field field_timeout_sec timeout_s;
               json_float_field field_wall_sec wall;
               json_float_field field_overshoot_sec (Float.max 0.0 (wall -. timeout_s));
               json_string_field field_rollback_scope rollback_scope_oas_context_only;
               json_field field_external_tool_side_effects_reverted (`Bool false);
             ]
             envelope)
        message;
      Error
        (Agent_sdk.Error.Api
           (Timeout
              { message =
                  Printf.sprintf "Timeout after %.1fs (budget=%.0fs)" wall timeout_s
              ; phase = None
              }))
    in
    (try Eio.Time.with_timeout_exn clock timeout_s fn with
     | Eio.Time.Timeout ->
       let wall = elapsed () in
       timeout_error ~wall
     | Eio.Cancel.Cancelled inner_exn as exn ->
       (* TLA+: FiberHandlesCancellation -> Rollback context.
          Cancelled means a parent fiber (server shutdown, global stop) requested
          cancellation — NOT a timeout. Re-raise so the keeper exits immediately
          instead of entering the retry loop.

          #10716: bimodal distribution observed in production — 21 events in
          [60, 300)s (short-tail, routine cancel: supervisor pause / runtime
          rotation) plus 8 events ≥1800s (long-tail, LLM provider hung). Same
          opaque message for both made root-cause attribution impossible.
          Categorize wall duration into a discrete bucket and surface the
          inner cancel exception so operators can split short_tail / mid_tail
          / long_tail in metric queries and the inner reason ([Eio.Cancel.Cancel_hook]
          payload, parent-fiber Cancelled, etc.) appears in the log. Severity
          comes from the caller's explicit [cancel_classification], not the
          internal exception name or wall-clock bucket. *)
       let bt = Printexc.get_raw_backtrace () in
       let wall = elapsed () in
       let bucket = Cancel_wall_bucket.of_wall wall in
       let inner_str =
         match inner_exn with
         | Failure msg -> "Failure(" ^ msg ^ ")"
         | _ -> Printexc.to_string inner_exn
       in
       if cancelled_timeout_exceeded ~timeout_s ~wall inner_exn
       then timeout_error ~wall
       else (
         let cancel_classification =
           classify_cancel ~cancel_classification inner_exn
         in
         let log_level = cancel_log_level cancel_classification in
         let cancel_classification_label =
           string_of_cancel_classification cancel_classification
         in
         let log_class = log_class_of_cancel_classification cancel_classification in
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string LlmBridgeFailures)
           ~labels:[label_site, site_cancelled ]
           ();
         let message =
           Printf.sprintf
             "keeper_llm_bridge: OAS execution cancelled after %.1fs bucket=%s inner=%s \
              (re-raising; OAS context rollback only; external tool side effects are \
              not reverted)"
             wall
             bucket
             inner_str
         in
         let envelope =
           bridge_failure_envelope
             ~cause_code:cause_code_oas_execution_cancelled
             ~severity:Failure_envelope.Warn
             ~summary:"OAS execution was cancelled by parent fiber or shutdown"
             ~recoverability:Failure_envelope.Retryable
             ~evidence_ref:
               (`Assoc
                 [
                   (key_wall_sec, `Float wall);
                   (key_bucket, `String bucket);
                   (key_inner_exception, `String inner_str);
                   (key_cancel_classification, `String cancel_classification_label);
                   (key_rollback_scope, `String rollback_scope_oas_context_only);
                   (key_external_tool_side_effects_reverted, `Bool false);
                 ])
             ()
         in
         Log.Keeper.emit log_level
           ~details:
             (bridge_details
                [
                  json_string_field field_event "keeper_oas_bridge_cancelled";
                  json_string_field field_log_class log_class;
                  json_float_field field_wall_sec wall;
                  json_string_field field_bucket bucket;
                  json_string_field field_inner_exception inner_str;
                  json_string_field field_cancel_classification cancel_classification_label;
                  json_string_field field_rollback_scope rollback_scope_oas_context_only;
                  json_field field_external_tool_side_effects_reverted (`Bool false);
                ]
                envelope)
           message;
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string OasCancel)
           ~labels:[label_bucket, bucket ]
           ();
         Printexc.raise_with_backtrace exn bt)
     | exn ->
       (* TLA+: HandleError -> Rollback context *)
       let bt = Printexc.get_backtrace () in
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string OasExecutionErrors)
         ~labels:[label_channel, channel_oas_bridge ]
         ();
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string LlmBridgeFailures)
         ~labels:[label_site, site_execution_error ]
         ();
       let error = Printexc.to_string exn in
       let message =
         Printf.sprintf "keeper_llm_bridge: OAS execution error: %s\n%s" error bt
       in
       let envelope =
         bridge_failure_envelope
           ~cause_code:cause_code_oas_execution_error
           ~severity:Failure_envelope.Bad
           ~summary:"OAS execution raised an unexpected exception"
           ~recoverability:Failure_envelope.Operator_action_required
           ~operator_action:operator_action_inspect_oas_bridge_error
           ~evidence_ref:(`Assoc [ (key_error, `String error) ])
           ()
       in
       Log.Keeper.emit Log.Error
         ~details:
           (bridge_details
              [
                json_string_field field_event "keeper_oas_bridge_execution_error";
                json_string_field field_error error;
              ]
              envelope)
         message;
       Error (Agent_sdk.Error.Internal error))
;;

module For_testing = struct
  let cancelled_timeout_exceeded = cancelled_timeout_exceeded
end
