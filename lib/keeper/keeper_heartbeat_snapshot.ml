(* keeper_heartbeat_snapshot — heartbeat snapshot write, event dispatch,
   stage timing metrics.

   Extracted from keeper_keepalive.ml. The [write_heartbeat_snapshot]
   function is the primary heartbeat status persistence path, reading
   context from checkpoint, computing continuity/guard metrics, and
   appending to the metrics ledger. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_memory
open Keeper_execution

let keepalive_interval_sec () =
  Runtime_params.get Runtime_settings.keeper_keepalive_interval_sec
;;

(* ── Heartbeat history fallback read limits ── *)
let max_history_read_bytes = 256 * 1024
let max_history_read_lines = 200
let heartbeat_history_persistence_surface = "keeper_heartbeat_history"

let report_heartbeat_history_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter Otel_metric_store.metric_persistence_read_drops
        ~labels:[("surface", heartbeat_history_persistence_surface); ("reason", reason)]
        ())
    ~surface:heartbeat_history_persistence_surface
    ~reason
    ~path
    ~detail
;;

let read_tail_lines_or_empty ~site path ~max_bytes ~max_lines =
  match read_file_tail_lines_result path ~max_bytes ~max_lines with
  | Ok lines -> lines
  | Error exn_class ->
      record_memory_recall_read_error ~site path exn_class;
      []
;;

let status_tick_usage_json () =
  `Assoc
    [
      ("input_tokens", `Int 0);
      ("output_tokens", `Int 0);
      ("cache_creation_tokens", `Int 0);
      ("cache_read_tokens", `Int 0);
      ("total_tokens", `Int 0);
    ]

let write_heartbeat_snapshot
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(now_ts : float)
      ~(consecutive_hb_failures : int)
      ~(timing_ring : Keeper_keepalive_signal.stage_timing array)
      ~(timing_filled : int)
  : unit
  =
  let metrics_store =
    Keeper_types_support.keeper_metrics_store ctx.config meta_current.name
  in
  let runtime_models =
    Provider_runtime_projection.default_execution_model_strings
      ((Keeper_meta_contract.runtime_id_of_meta meta_current))
  in
  let max_runtime_context =
    let resolution =
      Keeper_context_runtime.resolve_max_context_resolution
        ~requested_override:meta_current.max_context_override
        runtime_models
    in
    resolution.effective_budget
  in
  let base_dir = session_base_dir ctx.config in
  ignore (Keeper_fs.ensure_dir (Filename.concat base_dir (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)));
  let _session, ctx_opt =
    load_context_from_checkpoint
      ~trace_id:(Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
      ~primary_model_max_tokens:max_runtime_context
      ~base_dir
  in
  (* When the OAS checkpoint is absent (for example after a restart during a
     turn), load bounded message history for diagnostic metrics only. *)
  let messages_for_continuity = match ctx_opt with
    | Some c -> Keeper_context_runtime.messages_of_context c
    | None ->
      let history_path =
        Keeper_types_support.keeper_history_path ctx.config
          (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
      in
      let internal_history_path =
        Keeper_types_support.keeper_internal_history_path ctx.config
          (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
      in
      (let parse_errors = ref 0 in
       let messages =
         try
           [ history_path; internal_history_path ]
           |> List.concat_map (fun path ->
                read_tail_lines_or_empty ~site:"keeper_heartbeat_history" path
                  ~max_bytes:max_history_read_bytes
                  ~max_lines:max_history_read_lines
                |> List.filter_map (fun line ->
             try
               let json =
                 match Yojson.Safe.from_string line with
                 | `Assoc _ as json -> json
                 | _ ->
                   report_heartbeat_history_drop
                     ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                     ~path
                     ~detail:"history row is not a JSON object";
                   raise Exit
               in
               let source =
                 Safe_ops.json_string ~default:"" "source" json |> String.trim
               in
               let content =
                 Safe_ops.json_string ~default:"" "content" json |> String.trim
               in
               ignore content;
               if Keeper_types_support.is_prompt_history_source source then None
               else Some (Keeper_context_core.message_of_json json)
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | Exit ->
               incr parse_errors;
               None
             | Yojson.Json_error detail ->
               incr parse_errors;
               report_heartbeat_history_drop
                 ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
                 ~path
                 ~detail;
               None
             | Yojson.Safe.Util.Type_error (detail, _) ->
               incr parse_errors;
               report_heartbeat_history_drop
                 ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                 ~path
                 ~detail;
               None
             | exn ->
               incr parse_errors;
               report_heartbeat_history_drop
                 ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                 ~path
                 ~detail:(Printexc.to_string exn);
               None))
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string HeartbeatFailures)
             ~labels:[("keeper", meta_current.name); ("site", "history_load")]
             ();
           Log.Keeper.warn "write_heartbeat_snapshot: history.jsonl load error (%s): %s"
             meta_current.name (Printexc.to_string exn);
           []
       in
       if !parse_errors > 0 then begin
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string HeartbeatFailures)
           ~labels:[("keeper", meta_current.name); ("site", "history_parse")]
           ();
         Log.Keeper.warn
           "write_heartbeat_snapshot: failed to parse %d message(s) from history logs for keeper=%s trace_id=%s path=%s"
           !parse_errors meta_current.name
           (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
           history_path
       end;
       messages)
  in
  let c_messages = messages_for_continuity in
  let context_ratio_v = match ctx_opt with
      | Some c -> Keeper_context_runtime.context_ratio c
      | None -> 0.0
  in
  let message_count_v = match ctx_opt with
      | Some c -> Keeper_context_runtime.message_count c
      | None -> List.length c_messages
  in
  let token_count_v = match ctx_opt with
      | Some c -> Keeper_context_runtime.token_count c
      | None -> 0
  in
  let turn_fail_count =
      Keeper_registry.get_turn_failures
        ~base_path:ctx.config.base_path
        meta_current.name
  in
  let since_last_compaction_sec =
      if meta_current.runtime.compaction_rt.last_ts <= 0.0
      then now_ts
      else max 0.0 (now_ts -. meta_current.runtime.compaction_rt.last_ts)
  in
  let since_last_handoff_sec =
      if meta_current.runtime.last_handoff_ts <= 0.0
      then now_ts
      else max 0.0 (now_ts -. meta_current.runtime.last_handoff_ts)
  in
    (* RFC-0002: build measurement_snapshot via pure capture function.
       Timing/failure inputs now come from the live keepalive loop and
       registry so audit reflects the real runtime decision surface. *)
    let thresholds : Keeper_measurement.threshold_params =
      { compaction_ratio_gate = meta_current.compaction.ratio_gate
      ; compaction_message_gate = meta_current.compaction.message_gate
      ; compaction_token_gate = meta_current.compaction.token_gate
      ; compaction_cooldown_sec = meta_current.compaction.cooldown_sec
      ; handoff_threshold = meta_current.handoff_threshold
      ; handoff_cooldown_sec = meta_current.handoff_cooldown_sec
      ; auto_handoff_enabled = meta_current.auto_handoff
      ; model_ratio_multiplier = 1.0
      ; model_handoff_multiplier = 1.0
      }
    in
    let measurement =
      Keeper_measurement.capture
        ~snapshot_id:
          (Printf.sprintf "msnap-%s-%Ld"
             meta_current.name
             (Int64.of_float (now_ts *. 1000.0)))
        ~keeper_name:meta_current.name
        ~generation:meta_current.runtime.generation
        ~timestamp:now_ts
        ~thresholds
        ~context_ratio:context_ratio_v
        ~message_count:message_count_v
        ~token_count:token_count_v
        ~max_tokens:
          (match ctx_opt with
           | Some c -> Keeper_context_core.max_tokens_of_context c
           | None -> max_runtime_context)
        ~now_ts
        ~idle_seconds:0
        ~since_last_compaction_sec
        ~since_last_handoff_sec
        ~proactive_warmup_elapsed:false
        ~consecutive_hb_failures
        ~consecutive_turn_failures:turn_fail_count
        ()
    in
    let guard_events = Keeper_guard.evaluate measurement in
    let context_actions = Keeper_guard.context_actions measurement in
    let selected_guard_event = Keeper_guard.prioritized_event guard_events in
    (* RFC-0002: dispatch Context_measured event through state machine *)
    let () =
      Keeper_keepalive_signal.dispatch_keepalive_event_with_audit
        ~ctx
        ~keeper_name:meta_current.name
        ~snapshot:measurement
        ~events_fired:guard_events
        ~selected_event:selected_guard_event
        (Keeper_state_machine.Context_measured {
          context_ratio = context_ratio_v;
          message_count = message_count_v;
          token_count = token_count_v;
          context_actions = {
            Keeper_state_machine.compact = context_actions.compact;
            handoff = context_actions.handoff;
          };
        })
    in
    let snapshot =
      `Assoc
        [ "ts", `String (now_iso ())
        ; "ts_unix", `Float now_ts
        ; "channel", `String "heartbeat"
        ; "name", `String meta_current.name
        ; "agent_name", `String meta_current.agent_name
        ; "trace_id", `String (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
        ; "generation", `Int meta_current.runtime.generation
        ; (* #10018 follow-up: [model_used] is also snapshot-stale.
             last_model_used is the *previous turn's* provider label;
             emitting it on every heartbeat made
             per-provider latency histograms and dashboards show
             ghost provider names long after the binary that wrote
             them was rebuilt (observed stale synthetic provider
             labels across post-#9967 rebuild).  Emit empty string here so
             downstream per-provider aggregation ignores heartbeat
             records.  `last_model_used_label` on the keeper state
             JSON still reflects the last real turn for dashboard
             snapshot panels. *)
          "model_used", `String ""
        ; (* #10018: status_tick is a snapshot, not an LLM-call event.
             Emitting [runtime.usage.last_*_tokens] and [last_latency_ms]
             caused the last turn's per-turn values to be repeat-emitted
             on every heartbeat — observed analyst heartbeats 5 min
             apart both reported [input=273325, output=8067,
             total=281392, latency_ms=191894] while no LLM call ran.
             Downstream daily token aggregates and p50 latency were
             inflated by ~heartbeat-count per turn. Same "snapshot vs
             event" boundary fix as #9950 for compaction fields.
             [total_cost_usd] is a running total and remains emitted. *)
          "usage", status_tick_usage_json ()
        ; "latency_ms", `Int 0
        ; "cost_usd", `Float meta_current.runtime.usage.total_cost_usd
        ; "context_ratio", `Float context_ratio_v
        ; "context_tokens", `Int token_count_v
        ; "context_max",
          `Int
            (match ctx_opt with
             | Some c -> Keeper_context_core.max_tokens_of_context c
             | None -> max_runtime_context)
        ; "message_count", `Int message_count_v
        ; "compacted", `Bool false
        ; (* #9943: status_tick is a snapshot, not a compaction
             event. Emitting [before = after = token_count_v]
             caused 956/972 (98.4%) of daily metric entries to
             look like compaction attempts with zero savings —
             a false signal that drowned actual compactions.
             Zero marks the record as "not a compaction event";
             the dashboard already skips records with
             compacted=false, but analysts running ad-hoc jq over
             the ledger no longer mistake status_tick for a
             failed compaction. *)
          "compaction_before_tokens", `Int 0
        ; "compaction_after_tokens", `Int 0
        ; "work_kind", `String "status_tick"
        ; "snapshot_source", `String "keeper_context_status"
        ; "memory_check", memory_check_default_json ()
        ; ( "context_actions"
          , `Assoc
              [ "compact", `Bool context_actions.compact
              ; "handoff", `Bool context_actions.handoff
              ] )
        ; "handoff", `Assoc [ "performed", `Bool false ]
        ; "stage_timing", Keeper_keepalive_signal.stage_timing_to_json ~ring:timing_ring ~count:timing_filled
        ]
    in
    Dated_jsonl.append metrics_store snapshot;
    (try
       let json =
         `Assoc
           [ "type", `String "keeper_heartbeat"
           ; "name", `String meta_current.name
           ; "generation", `Int meta_current.runtime.generation
           ; "context_ratio", `Float context_ratio_v
           ; "ts_unix", `Float now_ts
           ]
       in
       Sse.broadcast json;
       Sse.broadcast_presence json
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string SseBroadcastFailures)
         ~labels:[("keeper", meta_current.name)]
         ();
       Log.Keeper.error "heartbeat SSE broadcast failed: %s" (Printexc.to_string exn));
    Keeper_event_publisher.publish_keeper_snapshot
      ~keeper_name:meta_current.name
      ~generation:meta_current.runtime.generation
      ~context_ratio:context_ratio_v
      ~message_count:message_count_v;
    (try
       Keeper_registry_tool_usage_persistence.flush ~base_path:ctx.config.base_path meta_current.name
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string HeartbeatFailures)
         ~labels:[("keeper", meta_current.name); ("site", "flush_tool_usage")]
         ();
       Log.Keeper.warn ~keeper_name:meta_current.name "flush_tool_usage failed: %s"
         (Printexc.to_string exn))
;;
