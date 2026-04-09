(** Keeper_keepalive — keeper heartbeat fiber and board-reactive wakeup.

    Per-keeper lifecycle (start, stop, wakeup) is managed through
    [Keeper_registry] (SSOT).  This module provides the heartbeat loop
    body, board-reactive wakeup filtering, and optional gRPC heartbeat
    fiber. *)

open Keeper_types
open Keeper_memory
open Keeper_execution

let keepalive_interval_sec () =
  Runtime_params.get Governance_registry.keeper_keepalive_interval_sec
;;

(* ── Board-reactive policy constants ── *)

let board_reactive_debounce_sec = Env_config.KeeperKeepalive.board_debounce_sec

(* ── Heartbeat history fallback read limits ── *)
let max_history_read_bytes = 256 * 1024
let max_history_read_lines = 200

(* OAS Event_bus — delegated to Keeper_event_bus to avoid dependency cycles. *)
let set_bus bus = Keeper_event_bus.set bus
let get_bus () = Keeper_event_bus.get ()

(* Global turn slot cap. Safety ceiling for ALL keeper turns (autonomous
   + reactive). Default 12 = headroom for up to 12 keepers. *)
let keeper_turn_throttle_limit =
  Keeper_config.int_of_env_default
    "MASC_KEEPER_AUTOBOOT_MAX" ~default:12 ~min_v:1 ~max_v:20
;;

let turn_semaphore = Eio.Semaphore.make keeper_turn_throttle_limit

(* Autonomous turn concurrency cap. Prevents thundering-herd when all
   keepers fire scheduled turns simultaneously on a shared LLM server.
   Reactive turns (explicit mentions, board events) bypass this gate
   so they are never starved by slow autonomous turns.
   Default 1 = with 1-slot llama-server, only one request can be in-flight
   at a time. Higher values cause queue buildup and TCP keepalive timeouts.
   For 8-slot servers, set MASC_KEEPER_AUTONOMOUS_CONCURRENCY=3-4. *)
let autonomous_turn_limit =
  Keeper_config.int_of_env_default
    "MASC_KEEPER_AUTONOMOUS_CONCURRENCY" ~default:1 ~min_v:1 ~max_v:8
;;

let autonomous_turn_semaphore = Eio.Semaphore.make autonomous_turn_limit

let with_keeper_turn_slot ~channel f =
  let is_autonomous =
    match channel with
    | Keeper_world_observation.Scheduled_autonomous -> true
    | Keeper_world_observation.Reactive -> false
  in
  let t0 = Time_compat.now () in
  if is_autonomous then Eio.Semaphore.acquire autonomous_turn_semaphore;
  Eio.Semaphore.acquire turn_semaphore;
  let semaphore_wait_ms =
    int_of_float ((Time_compat.now () -. t0) *. 1000.0) in
  Fun.protect
    ~finally:(fun () ->
      Eio.Semaphore.release turn_semaphore;
      if is_autonomous then Eio.Semaphore.release autonomous_turn_semaphore)
    (fun () -> f ~semaphore_wait_ms)
;;

(** Optional gRPC client + env — WORM Atomic: set at server bootstrap
    when [MASC_AGENT_TRANSPORT=grpc]. *)
let grpc_client_ref : Masc_grpc_client.t option Atomic.t = Atomic.make None

let grpc_env_ref : Eio_unix.Stdenv.base option Atomic.t = Atomic.make None

let set_grpc_client ?(env : Eio_unix.Stdenv.base option) c =
  Atomic.set grpc_client_ref (Some c);
  Atomic.set grpc_env_ref env
;;

(** Sleep in short chunks so [stop_keepalive] or [wakeup_keeper] takes
    effect within ~chunk_sec instead of waiting for the full interval. *)
let interruptible_sleep ~clock ~stop ~wakeup duration =
  let chunk_sec = Env_config.KeeperKeepalive.sleep_chunk_sec in
  let rec wait remaining =
    if Atomic.get stop
    then ()
    else if Atomic.compare_and_set wakeup true false
    then ()
    else if remaining <= 0.0
    then ()
    else (
      let chunk = Float.min chunk_sec remaining in
      Eio.Time.sleep clock chunk;
      wait (remaining -. chunk))
  in
  wait duration
;;

(** Wake up a specific keeper immediately, causing it to skip the rest of
    its sleep and run the next heartbeat cycle. Used by broadcast notification
    when a @mention targets a running keeper. *)
let wakeup_keeper name =
  Keeper_registry.all ()
  |> List.iter (fun (entry : Keeper_registry.registry_entry) ->
    if String.equal entry.name name && entry.phase = Keeper_state_machine.Running
    then Keeper_registry.wakeup ~base_path:entry.base_path name)
;;

(** Wake up all running keepers — used when a broadcast mentions @@all
    or when a system-wide event requires immediate attention. *)
let wakeup_all_keepers () = Keeper_registry.wakeup_all ()

let board_reactive_wakeup_allowed ~base_path ~keeper_name ~post_id =
  Keeper_registry.board_wakeup_allowed
    ~base_path
    keeper_name
    ~post_id
    ~debounce_sec:board_reactive_debounce_sec
;;

let wakeup_relevant_keeper_for_board_signal
      ~(config : Room.config)
      (signal : Board_dispatch.keeper_board_signal)
  =
  let running_names =
    Keeper_registry.all ()
    |> List.filter_map (fun (e : Keeper_registry.registry_entry) ->
      if e.phase = Keeper_state_machine.Running then Some e.name else None)
  in
  let candidates =
    running_names
    |> List.filter_map (fun name ->
      match read_meta config name with
      | Ok (Some meta) ->
        let matched =
          Keeper_world_observation.board_signal_match
            ~continuity_summary:meta.continuity_summary
            ~meta
            ~signal
        in
        Some (meta, matched)
      | _ -> None)
  in
  let explicit =
    candidates
    |> List.filter
         (fun (_meta, (matched : Keeper_world_observation.board_signal_match)) ->
            matched.explicit_mention)
  in
  let global_scope =
    candidates
    |> List.filter (fun (meta, _matched) ->
         match Keeper_contract.scope_kind_of_string meta.scope_kind with
         | Keeper_contract.Global -> true
         | Keeper_contract.Local -> false)
  in
  let wake_meta (meta : keeper_meta) reason =
    if
      board_reactive_wakeup_allowed
        ~base_path:config.base_path
        ~keeper_name:meta.name
        ~post_id:signal.post_id
    then (
      wakeup_keeper meta.name;
      Log.Keeper.info
        "board signal wakeup: keeper=%s reason=%s post=%s"
        meta.name
        reason
        signal.post_id)
  in
  match explicit with
  | _ :: _ ->
    explicit |> List.iter (fun (meta, _matched) -> wake_meta meta "explicit_mention")
  | [] ->
    global_scope
    |> List.iter (fun (meta, _matched) -> wake_meta meta "global_scope")
;;

let max_consecutive_heartbeat_failures () =
  Runtime_params.get Governance_registry.keeper_max_hb_failures
;;

let max_consecutive_turn_failures () =
  Runtime_params.get Governance_registry.keeper_max_turn_failures
;;

(* Per-stage timing accumulator for Phase 0 profiling.
   In-memory ring of last 100 cycles. Flushed as aggregate at snapshot cadence.
   No additional file I/O — appended to existing snapshot JSON. *)
type stage_timing =
  { presence_ms : float
  ; snapshot_ms : float
  ; board_ms : float
  ; turn_ms : float
  ; recurring_ms : float
  }

let stage_timing_ring_size () =
  Runtime_params.get Governance_registry.keeper_stage_timing_ring_size
;;

let percentile arr p =
  let n = Array.length arr in
  if n = 0
  then 0.0
  else (
    let sorted = Array.copy arr in
    Array.sort Float.compare sorted;
    let idx = Float.to_int (Float.round (float_of_int (n - 1) *. p)) in
    sorted.(min idx (n - 1)))
;;

let stage_timing_to_json ~ring ~count =
  let n = min count (Array.length ring) in
  if n = 0
  then `Null
  else (
    let extract field =
      let arr = Array.init n (fun i -> field ring.(i)) in
      `Assoc
        [ "p50", `Float (percentile arr 0.5)
        ; "p95", `Float (percentile arr 0.95)
        ; "max", `Float (percentile arr 1.0)
        ; "samples", `Int n
        ]
    in
    `Assoc
      [ "presence", extract (fun t -> t.presence_ms)
      ; "snapshot", extract (fun t -> t.snapshot_ms)
      ; "board", extract (fun t -> t.board_ms)
      ; "turn", extract (fun t -> t.turn_ms)
      ; "recurring", extract (fun t -> t.recurring_ms)
      ])
;;

let write_heartbeat_snapshot
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(now_ts : float)
      ~(timing_ring : stage_timing array)
      ~(timing_filled : int)
  : unit
  =
  let metrics_store = keeper_metrics_store ctx.config meta_current.name in
  let cascade_models =
    Oas_model_resolve.models_of_cascade_name meta_current.cascade_name
  in
  let max_cascade_context =
    let min_keeper_context = Keeper_config.min_keeper_context_tokens in
    let raw = match meta_current.max_context_override with
      | Some v -> v
      | None -> Oas_model_resolve.resolve_max_cascade_context cascade_models
    in
    max min_keeper_context raw
  in
  let base_dir = session_base_dir ctx.config in
  ignore (Keeper_fs.ensure_dir (Filename.concat base_dir meta_current.runtime.trace_id));
  let _session, ctx_opt =
    load_context_from_checkpoint
      ~max_checkpoint_messages:meta_current.compaction.max_checkpoint_messages
      ~trace_id:meta_current.runtime.trace_id
      ~primary_model_max_tokens:max_cascade_context
      ~base_dir
  in
  (* Fallback: when OAS checkpoint is absent (e.g. after server restart
     mid-turn), load messages from history.jsonl to recover continuity.
     This prevents the "orphan user" problem where interrupted turns
     leave user-only entries and continuity_summary stays empty forever.
     Read is bounded to avoid large allocations during heartbeats. *)
  let messages_for_continuity = match ctx_opt with
    | Some c -> c.messages
    | None ->
      let history_path =
        Filename.concat
          (Filename.concat base_dir meta_current.runtime.trace_id)
          "history.jsonl"
      in
      (let parse_errors = ref 0 in
       let messages =
         try
           read_file_tail_lines history_path ~max_bytes:max_history_read_bytes ~max_lines:max_history_read_lines
           |> List.filter_map (fun line ->
             try
               let json = Yojson.Safe.from_string line in
               Some (Keeper_context_core.message_of_json json)
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | _exn ->
               incr parse_errors;
               None)
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Keeper.warn "write_heartbeat_snapshot: history.jsonl load error (%s): %s"
             meta_current.name (Printexc.to_string exn);
           []
       in
       if !parse_errors > 0 then
         Log.Keeper.warn
           "write_heartbeat_snapshot: failed to parse %d message(s) from history.jsonl for keeper=%s trace_id=%s path=%s"
           !parse_errors meta_current.name meta_current.runtime.trace_id history_path;
       messages)
  in
  let c_messages = messages_for_continuity in
  let latest_user_message =
    latest_message_content_by_role ~role:Agent_sdk.Types.User c_messages
  in
  let latest_assistant_message =
    latest_message_content_by_role ~role:Agent_sdk.Types.Assistant c_messages
    in
    let continuity_snapshot = latest_state_snapshot_from_messages c_messages in
    let continuity_summary =
      match continuity_snapshot with
      | Some s -> keeper_state_snapshot_to_summary_text s
      | None ->
        let trimmed = String.trim meta_current.continuity_summary in
        if trimmed = "" then "No continuity snapshot available." else trimmed
    in
    let repetition_risk =
      repetition_risk_score ~messages:c_messages ~candidate_reply:None
    in
    let goal_alignment =
      goal_alignment_score
        ~meta:meta_current
        ~user_message:latest_user_message
        ~assistant_reply:latest_assistant_message
    in
    let response_alignment =
      match latest_user_message, latest_assistant_message with
      | Some user_message, Some assistant_message ->
        jaccard_similarity user_message assistant_message
      | _ -> 0.0
    in
    let context_ratio_v = match ctx_opt with
      | Some c -> Keeper_exec_context.context_ratio c
      | None -> 0.0
    in
    let message_count_v = match ctx_opt with
      | Some c -> Keeper_exec_context.message_count c
      | None -> List.length c_messages
    in
    let token_count_v = match ctx_opt with
      | Some c -> Keeper_exec_context.token_count c
      | None -> 0
    in
    let auto_rules =
      evaluate_keeper_auto_rules
        ~meta:meta_current
        ~context_ratio:context_ratio_v
        ~message_count:message_count_v
        ~token_count:token_count_v
        ~repetition_risk
        ~goal_alignment
        ~response_alignment
        ()
    in
    (* RFC-0002: build measurement_snapshot via pure capture function.
       Timing/failure fields not yet wired from heartbeat loop context
       use defaults; a follow-up PR will thread them through. *)
    let thresholds : Keeper_measurement.threshold_params =
      { compaction_ratio_gate = meta_current.compaction.ratio_gate
      ; compaction_message_gate = meta_current.compaction.message_gate
      ; compaction_token_gate = meta_current.compaction.token_gate
      ; compaction_cooldown_sec = meta_current.compaction.cooldown_sec
      ; handoff_threshold = meta_current.handoff_threshold
      ; handoff_cooldown_sec = meta_current.handoff_cooldown_sec
      ; auto_handoff_enabled = meta_current.auto_handoff
      ; reflect_repetition_threshold =
          Keeper_config.keeper_rule_reflect_repetition_threshold ()
      ; plan_goal_alignment_threshold =
          Keeper_config.keeper_rule_plan_goal_alignment_threshold ()
      ; plan_response_alignment_threshold =
          Keeper_config.keeper_rule_plan_response_alignment_threshold ()
      ; guardrail_repetition_threshold =
          Keeper_config.keeper_rule_guardrail_repetition_threshold ()
      ; guardrail_goal_alignment_threshold =
          Keeper_config.keeper_rule_guardrail_goal_alignment_threshold ()
      ; guardrail_response_alignment_threshold =
          Keeper_config.keeper_rule_guardrail_response_alignment_threshold ()
      ; guardrail_context_threshold =
          Keeper_config.keeper_rule_guardrail_context_threshold ()
      ; max_consecutive_hb_failures = max_consecutive_heartbeat_failures ()
      ; max_consecutive_turn_failures = max_consecutive_turn_failures ()
      ; model_ratio_multiplier = 1.0
      ; model_handoff_multiplier = 1.0
      }
    in
    let _measurement =
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
        ~max_tokens:(match ctx_opt with Some c -> c.max_tokens | None -> max_cascade_context)
        ~repetition_risk
        ~goal_alignment
        ~response_alignment
        ~now_ts
        ~idle_seconds:0
        ~since_last_compaction_sec:0.0
        ~since_last_handoff_sec:0.0
        ~proactive_warmup_elapsed:false
        ~consecutive_hb_failures:0
        ~consecutive_turn_failures:0
        ()
    in
    (* RFC-0002: dispatch Context_measured event through state machine *)
    let _dispatch_result =
      Keeper_registry.dispatch_event
        ~base_path:ctx.config.base_path
        meta_current.name
        (Keeper_state_machine.Context_measured {
          context_ratio = context_ratio_v;
          message_count = message_count_v;
          token_count = token_count_v;
          auto_rules = {
            Keeper_state_machine.reflect = auto_rules.reflect;
            plan = auto_rules.plan;
            compact = auto_rules.compact;
            handoff = auto_rules.handoff;
            guardrail_stop = auto_rules.guardrail_stop;
            guardrail_reason = auto_rules.guardrail_reason;
            goal_drift = auto_rules.goal_drift;
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
        ; "trace_id", `String meta_current.runtime.trace_id
        ; "generation", `Int meta_current.runtime.generation
        ; "model_used", `String meta_current.runtime.usage.last_model_used
        ; ( "usage"
          , `Assoc
              [ "input_tokens", `Int meta_current.runtime.usage.last_input_tokens
              ; "output_tokens", `Int meta_current.runtime.usage.last_output_tokens
              ; "total_tokens", `Int meta_current.runtime.usage.last_total_tokens
              ]
          )
        ; "latency_ms", `Int meta_current.runtime.usage.last_latency_ms
        ; "cost_usd", `Float meta_current.runtime.usage.total_cost_usd
        ; "context_ratio", `Float context_ratio_v
        ; "context_tokens", `Int token_count_v
        ; "context_max", `Int (match ctx_opt with Some c -> c.max_tokens | None -> max_cascade_context)
        ; "message_count", `Int message_count_v
        ; ( "continuity_state"
          , match continuity_snapshot with
            | None -> `Null
            | Some s -> keeper_state_snapshot_to_json s )
        ; "continuity_summary", `String continuity_summary
        ; "compacted", `Bool false
        ; "compaction_before_tokens", `Int token_count_v
        ; "compaction_after_tokens", `Int token_count_v
        ; "work_kind", `String "status_tick"
        ; "tool_call_count", `Int 0
        ; "tools_used", `List []
        ; "snapshot_source", `String "keeper_context_status"
        ; "memory_check", memory_check_default_json ()
        ; "auto_rules", keeper_auto_rule_eval_to_json auto_rules
        ; "reflection", keeper_reflection_payload_of_auto_rules auto_rules
        ; "auto_reflect", `Bool auto_rules.reflect
        ; "auto_plan", `Bool auto_rules.plan
        ; "auto_compact", `Bool auto_rules.compact
        ; "auto_handoff", `Bool auto_rules.handoff
        ; "repetition_risk", `Float repetition_risk
        ; "goal_alignment", `Float goal_alignment
        ; "response_alignment", `Float response_alignment
        ; "goal_drift", `Float auto_rules.goal_drift
        ; "guardrail_stop", `Bool auto_rules.guardrail_stop
        ; ( "guardrail_stop_reason"
          , match auto_rules.guardrail_reason with
            | Some reason -> `String reason
            | None -> `Null )
        ; "handoff", `Assoc [ "performed", `Bool false ]
        ; "stage_timing", stage_timing_to_json ~ring:timing_ring ~count:timing_filled
        ]
    in
    Dated_jsonl.append metrics_store snapshot;
    (try
       Sse.broadcast
         (`Assoc
             [ "type", `String "keeper_heartbeat"
             ; "name", `String meta_current.name
             ; "generation", `Int meta_current.runtime.generation
             ; "context_ratio", `Float context_ratio_v
             ; "ts_unix", `Float now_ts
             ])
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.error "heartbeat SSE broadcast failed: %s" (Printexc.to_string exn));
    (match Keeper_event_bus.get () with
     | Some bus ->
       Oas_events.publish_keeper_snapshot
         bus
         ~keeper_name:meta_current.name
         ~generation:meta_current.runtime.generation
         ~context_ratio:context_ratio_v
         ~message_count:message_count_v
     | None -> ());
    (try
       Keeper_registry.flush_tool_usage ~base_path:ctx.config.base_path meta_current.name
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | _ -> ())
;;

let keeper_agent_status (meta : keeper_meta) =
  if meta.paused
  then Types.Inactive
  else (
    match meta.current_task_id with
    | Some _ -> Types.Busy
    | None -> Types.Active)
;;

(** Reset stale turn failures so the keeper can exit Failing phase.
    Called unconditionally after presence sync (whether I/O was skipped or not).
    If the underlying issue persists, the next turn will re-fail. *)
let maybe_recover_from_failing ~(ctx : _ context) ~(meta : keeper_meta) =
  let stale_turn_failures =
    Keeper_registry.get_turn_failures
      ~base_path:ctx.config.base_path meta.name
  in
  if stale_turn_failures > 0 then begin
    let sticky_manual_reconcile =
      match Keeper_registry.get ~base_path:ctx.config.base_path meta.name with
      | Some entry ->
          (match entry.last_failure_reason with
           | Some reason ->
               Keeper_registry.failure_reason_requires_manual_reconcile reason
           | None -> false)
      | None -> false
    in
    if sticky_manual_reconcile then
      Log.Keeper.warn
        "heartbeat recovery: preserving %d turn failures for %s because manual reconcile is still required"
        stale_turn_failures meta.name
    else begin
      Keeper_registry.reset_turn_failures
        ~base_path:ctx.config.base_path meta.name;
      ignore (Keeper_registry.dispatch_event
        ~base_path:ctx.config.base_path meta.name
        Keeper_state_machine.Heartbeat_ok);
      ignore (Keeper_registry.dispatch_event
        ~base_path:ctx.config.base_path meta.name
        Keeper_state_machine.Turn_succeeded);
      Log.Keeper.info
        "heartbeat recovery: reset %d stale turn failures for %s"
        stale_turn_failures meta.name
    end
  end

let sync_keeper_presence
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(t_presence_start : float)
      ~(consecutive_failures : int ref)
      ~(last_successful_heartbeat_ts : float ref)
      ~(work_as_hb : unit -> bool)
      ~(max_silence : unit -> float)
  : keeper_meta
  =
  let presence_fresh =
    work_as_hb () && t_presence_start -. !last_successful_heartbeat_ts < max_silence ()
  in
  if presence_fresh
  then (
    Log.Keeper.debug
      "presence sync skipped: fresh heartbeat %.0fs ago"
      (t_presence_start -. !last_successful_heartbeat_ts);
    maybe_recover_from_failing ~ctx ~meta:meta_current;
    meta_current)
  else (
    try
      let synced = ensure_keeper_room_presence ctx.config meta_current in
      if synced.joined_room_ids = []
      then (
        incr consecutive_failures;
        (* RFC-0001 Gate A: record failure streak *)
        Agent_stress.record {
          agent_name = meta_current.name;
          room_id = (match meta_current.joined_room_ids with r :: _ -> r | [] -> "");
          kind = Failure_streak !consecutive_failures;
          timestamp = Unix.gettimeofday ();
        };
        Log.Keeper.warn
          "room presence returned empty rooms (%d/%d)"
          !consecutive_failures
          (max_consecutive_heartbeat_failures ());
        (* RFC-0002: dispatch heartbeat failure *)
        Prometheus.inc_counter "masc_keeper_heartbeat_failures_total"
          ~labels:[("keeper", meta_current.name)] ();
        ignore (Keeper_registry.dispatch_event
          ~base_path:ctx.config.base_path meta_current.name
          (Keeper_state_machine.Heartbeat_failed {
            consecutive = !consecutive_failures;
            max_allowed = max_consecutive_heartbeat_failures ();
          })))
      else (
        consecutive_failures := 0;
        last_successful_heartbeat_ts := Time_compat.now ();
        (* RFC-0002: dispatch heartbeat success *)
        ignore (Keeper_registry.dispatch_event
          ~base_path:ctx.config.base_path meta_current.name
          Keeper_state_machine.Heartbeat_ok);
        Prometheus.inc_counter "masc_keeper_heartbeat_successes_total"
          ~labels:[("keeper", meta_current.name)] ();
        maybe_recover_from_failing ~ctx ~meta:meta_current);
      match write_meta ctx.config synced with
      | Ok () -> synced
      | Error e ->
        Log.Keeper.warn "write_meta failed (heartbeat): %s" e;
        synced
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      incr consecutive_failures;
      Log.Keeper.error
        "room heartbeat failed (%d/%d): %s"
        !consecutive_failures
        (max_consecutive_heartbeat_failures ())
        (Printexc.to_string exn);
      (* RFC-0002: dispatch heartbeat failure *)
      ignore (Keeper_registry.dispatch_event
        ~base_path:ctx.config.base_path meta_current.name
        (Keeper_state_machine.Heartbeat_failed {
          consecutive = !consecutive_failures;
          max_allowed = max_consecutive_heartbeat_failures ();
        }));
      meta_current)
;;

let collect_keepalive_board_events
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(proactive_warmup_elapsed : bool)
  =
  if not proactive_warmup_elapsed
  then [], meta_current
  else (
    let pending_board_events =
      try
        let events, _new_count, _mention_count =
          Keeper_world_observation.collect_board_events
            ~base_path:ctx.config.base_path
            ~meta:meta_current
            ~continuity_summary:meta_current.continuity_summary
        in
        events
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Keeper.warn "keepalive: board count query failed: %s" (Printexc.to_string exn);
        []
    in
    pending_board_events, meta_current)
;;

let run_keepalive_unified_turn
      ~(ctx : _ context)
      ~(meta_after_triage : keeper_meta)
      ~pending_board_events
      ~(stop : bool Atomic.t)
      ~(proactive_warmup_elapsed : bool)
      ~(shared_context : Agent_sdk.Context.t)
      ~(boring_consecutive_turns_ref : int ref)
  : keeper_meta
  =
  if not proactive_warmup_elapsed
  then meta_after_triage
  else (
    try
      let obs =
        Keeper_world_observation.observe
          ~pending_board_events:(Some pending_board_events)
          ~config:ctx.config
          ~meta:meta_after_triage
      in
      let has_message_signal =
        obs.pending_mentions <> [] || obs.pending_scope_messages <> []
      in
      let turn_decision =
        Keeper_world_observation.unified_turn_decision
          ~meta:meta_after_triage
          obs
      in
      (* Boring-turn gate: once the non-reactive idle streak reaches the
         configured threshold, skip the turn entirely. Reactive turns
         (mentions, board events) always run — new stimulus resets the boring
         counter. Lower streaks are handled inside before_turn_params
         (graduated prompt escalation + tool_choice=None_ at >=3) to let the
         LLM judge whether new work appeared. Crossing the configured threshold
         is the deterministic hard exit — no LLM call, no token spend. *)
      let boring_skip =
        let streak = !boring_consecutive_turns_ref in
        let is_reactive =
          turn_decision.channel = Keeper_world_observation.Reactive
        in
        let boring_threshold = Keeper_config.keeper_boring_exit_threshold () in
        if streak >= boring_threshold && not is_reactive then begin
          Log.Keeper.info
            "keeper:%s boring_consecutive=%d >= %d, skipping proactive turn (hard gate)"
            meta_after_triage.name streak boring_threshold;
          true
        end else false
      in
      let should_run_turn =
        (not (Atomic.get stop))
        && turn_decision.should_run
        && (not boring_skip)
      in
      let meta_after_observe =
        Keeper_world_observation.apply_message_cursor_updates
          meta_after_triage
          obs.message_cursor_updates
      in
      if should_run_turn then
        Log.Keeper.info
          "keepalive turn scheduled for %s: channel=%s reasons=%s"
          meta_after_triage.name
          (match turn_decision.channel with
           | Keeper_world_observation.Reactive -> "reactive"
           | Keeper_world_observation.Scheduled_autonomous -> "scheduled_autonomous")
          (String.concat "," turn_decision.reasons);
      if (not should_run_turn)
         && (not has_message_signal)
         && obs.message_cursor_updates <> []
      then (
        match write_meta ctx.config meta_after_observe with
        | Ok () -> ()
        | Error e ->
            Log.Keeper.warn "write_meta failed (message cursor update): %s" e);
      if Atomic.get stop
      then meta_after_triage
      else if should_run_turn
      then (
        with_keeper_turn_slot ~channel:turn_decision.channel (fun ~semaphore_wait_ms ->
          match
            Keeper_unified_turn.run_unified_turn
              ~config:ctx.config
              ~meta:meta_after_observe
              ~observation:obs
              ~generation:meta_after_observe.runtime.generation
              ~channel:turn_decision.channel
              ~semaphore_wait_ms:semaphore_wait_ms
              ~shared_context
              ~boring_consecutive_turns_ref
              ()
          with
          | Error err ->
            let e_str = Oas.Error.to_string err in
            Log.Keeper.error "%s: unified turn failed: %s"
              meta_after_observe.name e_str;
            if String_util.contains_substring e_str "Eio switch not available"
               || String_util.contains_substring e_str "Eio net not available"
            then begin
              Keeper_registry.set_failure_reason
                ~base_path:ctx.config.base_path meta_after_observe.name
                (Some (Keeper_registry.Exception
                  (Printf.sprintf "fatal environment error: %s" e_str)));
              raise Keeper_registry.Keeper_fiber_crash
            end;
            (match read_meta ctx.config meta_after_observe.name with
             | Ok (Some latest) -> latest
             | _ -> meta_after_observe)
          | Ok updated -> updated))
      else if (not has_message_signal) && obs.message_cursor_updates <> [] then
        meta_after_observe
      else
        meta_after_triage
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Keeper_registry.Keeper_fiber_crash as e -> raise e
    | exn ->
      Log.Keeper.error "%s: unified turn exception: %s"
        meta_after_triage.name (Printexc.to_string exn);
      meta_after_triage)
;;

let refresh_work_as_heartbeat
      ~(ctx : _ context)
      ~(meta_after_proactive : keeper_meta)
      ~(proactive_warmup_elapsed : bool)
      ~(work_as_hb : unit -> bool)
      ~(last_successful_heartbeat_ts : float ref)
      ~(consecutive_failures : int ref)
  : unit
  =
  if work_as_hb () && proactive_warmup_elapsed
  then (
    let hb_ok =
      List.exists
        (fun _room_id ->
           try
             ignore
               (Room.heartbeat
                  ctx.config
                  ~agent_name:meta_after_proactive.agent_name);
             true
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             Log.Keeper.debug
               "heartbeat failed for %s: %s"
               meta_after_proactive.name
               (Printexc.to_string exn);
             false)
        meta_after_proactive.joined_room_ids
    in
    if hb_ok
    then (
      last_successful_heartbeat_ts := Time_compat.now ();
      consecutive_failures := 0))
;;

let dispatch_recurring_keepalive
      ~(ctx : _ context)
      ~(meta_after_proactive : keeper_meta)
      ~(now_ts : float)
  : int
  =
  try
    Keeper_recurring.dispatch_due
      ~keeper_name:meta_after_proactive.name
      ~now_ts
      ~dispatch:(fun task action ->
        match action with
        | Keeper_recurring.Broadcast msg ->
          (try
             let _ =
               Room.broadcast
                 ctx.config
                 ~from_agent:meta_after_proactive.agent_name
                 ~content:(Printf.sprintf "[loop:%s] %s" task.label msg)
             in
             Log.Keeper.info "[recurring] %s dispatched: %s" task.id task.label;
             Ok ()
           with
           | exn ->
             Log.Keeper.warn "[recurring] %s failed: %s" task.id (Printexc.to_string exn);
             Error (Printexc.to_string exn)))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn "[recurring] dispatch error: %s" (Printexc.to_string exn);
    0
;;

let run_smart_heartbeat_gate
      ~(clock : _ Eio.Time.clock)
      ~(stop : bool Atomic.t)
      ~(wakeup : bool Atomic.t)
      ~(meta_current : keeper_meta)
      ~(smart_hb_enabled : unit -> bool)
      ~(smart_hb_config : Heartbeat_smart.config)
      ~(last_successful_heartbeat_ts : float ref)
      ~(last_heartbeat_cycle_ts : float ref)
  : bool
  =
  let smart_hb_decision =
    if smart_hb_enabled ()
    then (
      let agent_status = keeper_agent_status meta_current in
      Heartbeat_smart.should_emit
        ~config:smart_hb_config
        ~agent_status
        ~last_activity:!last_successful_heartbeat_ts
        ~last_heartbeat:!last_heartbeat_cycle_ts)
    else Heartbeat_smart.Emit
  in
  match smart_hb_decision with
  | Heartbeat_smart.Skip_busy ->
    Log.Keeper.debug
      "smart heartbeat: skip (busy, task=%s)"
      (Option.value ~default:"?" meta_current.current_task_id);
    let base =
      Heartbeat_smart.effective_interval
        ~config:smart_hb_config
        ~last_activity:!last_successful_heartbeat_ts
    in
    let jitter = base *. 0.2 *. Random.float 1.0 in
    interruptible_sleep ~clock ~stop ~wakeup (base +. jitter);
    false
  | Heartbeat_smart.Skip_idle next_time ->
    let wait = Float.max 1.0 (next_time -. Time_compat.now ()) in
    Log.Keeper.debug "smart heartbeat: skip (idle, next in %.1fs)" wait;
    let jitter = wait *. 0.1 *. Random.float 1.0 in
    interruptible_sleep ~clock ~stop ~wakeup (wait +. jitter);
    false
  | Heartbeat_smart.Emit ->
    last_heartbeat_cycle_ts := Time_compat.now ();
    true
;;

let maybe_write_heartbeat_snapshot
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(now_ts : float)
      ~(last_snapshot_ts : float ref)
      ~(snapshot_interval_sec : int)
      ~(timing_ring : stage_timing array)
      ~(timing_filled : int)
  : unit
  =
  if now_ts -. !last_snapshot_ts >= float_of_int snapshot_interval_sec
  then (
    (try
       write_heartbeat_snapshot ~ctx ~meta_current ~now_ts ~timing_ring ~timing_filled
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.error "heartbeat snapshot write failed: %s" (Printexc.to_string exn));
    last_snapshot_ts := now_ts)
;;

let record_keepalive_stage_timing
      ~(timing_ring : stage_timing array)
      ~(timing_cursor : int ref)
      ~(timing_filled : int ref)
      ~(ring_sz : int)
      ~(t_presence_start : float)
      ~(t_presence_end : float)
      ~(t_snapshot_start : float)
      ~(t_snapshot_end : float)
      ~(t_board_start : float)
      ~(t_board_end : float)
      ~(t_turn_start : float)
      ~(t_turn_end : float)
      ~(t_recurring_start : float)
      ~(t_recurring_end : float)
  : unit
  =
  let timing =
    { presence_ms = (t_presence_end -. t_presence_start) *. 1000.0
    ; snapshot_ms = (t_snapshot_end -. t_snapshot_start) *. 1000.0
    ; board_ms = (t_board_end -. t_board_start) *. 1000.0
    ; turn_ms = (t_turn_end -. t_turn_start) *. 1000.0
    ; recurring_ms = (t_recurring_end -. t_recurring_start) *. 1000.0
    }
  in
  timing_ring.(!timing_cursor) <- timing;
  timing_cursor := (!timing_cursor + 1) mod ring_sz;
  if !timing_filled < ring_sz then incr timing_filled
;;

let run_heartbeat_loop
      ~proactive_warmup_sec
      (ctx : _ context)
      (m : keeper_meta)
      (stop : bool Atomic.t)
      ~(wakeup : bool Atomic.t)
  : unit
  =
  let keepalive_started_ts = Time_compat.now () in
  let snapshot_interval_sec () =
    Runtime_params.get Governance_registry.keeper_snapshot_sec
  in
  let last_snapshot_ts = ref 0.0 in
  let consecutive_failures = ref 0 in
  (* Phase 0: per-stage timing ring buffer.
     ring_size is read once at fiber start — mid-flight resize requires
     ring buffer reallocation, so new values apply on next fiber restart. *)
  let ring_sz = stage_timing_ring_size () in
  let timing_ring =
    Array.make
      ring_sz
      { presence_ms = 0.0
      ; snapshot_ms = 0.0
      ; board_ms = 0.0
      ; turn_ms = 0.0
      ; recurring_ms = 0.0
      }
  in
  let timing_cursor = ref 0 in
  let timing_filled = ref 0 in
  (* Phase 1: work-as-heartbeat freshness tracking.
     Updated ONLY on Room.heartbeat success after turn. *)
  let last_successful_heartbeat_ts = ref (Time_compat.now ()) in
  let work_as_hb () = Runtime_params.get Governance_registry.keeper_work_as_hb_enabled in
  let max_silence () =
    Runtime_params.get Governance_registry.keeper_work_as_hb_max_silence_sec
  in
  (* Phase 2: smart heartbeat — adaptive scheduling via Heartbeat_smart *)
  let smart_hb_enabled () =
    Runtime_params.get Governance_registry.keeper_smart_hb_enabled
  in
  let smart_hb_config = Heartbeat_smart.default_config in
  let last_heartbeat_cycle_ts = ref 0.0 in
  (* Persistent OAS Context.t — created once per keeper lifecycle.
     OAS Context.t is a mutable cross-turn state container for values
     written directly into the shared context. This preserves shared
     metadata across turns, but per-turn context_injector-local timing
     and tool-call counters are recreated inside run_turn and therefore
     do not accumulate for the full keeper lifecycle. *)
  let shared_context = Agent_sdk.Context.create () in
  (* Inter-run boring-tool gate: persists across run_turn calls so
     the anti-polling gate can detect heartbeat-level polling loops
     (e.g., every heartbeat calls only masc_status then exits).
     Intra-run counters reset on each run_turn; this ref does not. *)
  let boring_consecutive_turns_ref = ref 0 in
  (* Mtime-based change detection for keeper meta disk reads.
     Avoids re-parsing the JSON file on every heartbeat cycle when
     no operator has modified it.  Initialized to 0.0 so the first
     cycle always reads. *)
  let last_meta_mtime = ref 0.0 in
  let rec loop () =
    if Atomic.get stop
    then ()
    else (
      (* Yield before each heartbeat cycle to prevent N keeper fibers
               from monopolizing the Eio scheduler during CPU-bound phases
               (tool filtering, snapshot construction, prompt building). *)
      Eio.Fiber.yield ();
      (* Phase 0: timing markers *)
      let t_presence_start = Time_compat.now () in
      let meta_current =
        match read_meta_if_changed ctx.config m.name ~last_mtime:!last_meta_mtime with
        | Some (latest, new_mtime) ->
          last_meta_mtime := new_mtime;
          latest
        | None -> m
      in
      (* Sync disk meta to registry so dashboard reads live values.  #5364.
         Physical inequality: read_meta returns a fresh record when the JSON
         file changed; same pointer means no disk change occurred. *)
      if meta_current != m then
        Keeper_registry.update_meta
          ~base_path:ctx.config.base_path meta_current.name meta_current;
      if
        run_smart_heartbeat_gate
          ~clock:ctx.clock
          ~stop
          ~wakeup
          ~meta_current
          ~smart_hb_enabled
          ~smart_hb_config
          ~last_successful_heartbeat_ts
          ~last_heartbeat_cycle_ts
      then (
        (* Phase 1: skip presence sync when recent room heartbeat proves freshness *)
        let meta_current =
          sync_keeper_presence
            ~ctx
            ~meta_current
            ~t_presence_start
            ~consecutive_failures
            ~last_successful_heartbeat_ts
            ~work_as_hb
            ~max_silence
        in
        (* RFC-0002: fiber crash on heartbeat threshold breach *)
        if !consecutive_failures >= max_consecutive_heartbeat_failures ()
        then begin
          Keeper_registry.set_failure_reason
            ~base_path:ctx.config.base_path m.name
            (Some (Keeper_registry.Heartbeat_consecutive_failures
                     !consecutive_failures));
          raise Keeper_registry.Keeper_fiber_crash
        end;
        let t_presence_end = Time_compat.now () in
        let now_ts = t_presence_end in
        let t_snapshot_start = now_ts in
        maybe_write_heartbeat_snapshot
          ~ctx
          ~meta_current
          ~now_ts
          ~last_snapshot_ts
          ~snapshot_interval_sec:(snapshot_interval_sec ())
          ~timing_ring
          ~timing_filled:!timing_filled;
        let t_snapshot_end = Time_compat.now () in
        let t_board_start = t_snapshot_end in
        (* Compute warmup state BEFORE board collection so cursor
                 is not advanced while keeper cannot act on events. *)
        let proactive_warmup_elapsed =
          proactive_warmup_sec <= 0
          || now_ts -. keepalive_started_ts >= float_of_int proactive_warmup_sec
        in
        let pending_board_events, meta_after_triage =
          collect_keepalive_board_events ~ctx ~meta_current ~proactive_warmup_elapsed
        in
        let t_board_end = Time_compat.now () in
        let t_turn_start = t_board_end in
        let meta_after_proactive =
          run_keepalive_unified_turn
            ~ctx
            ~meta_after_triage
            ~pending_board_events
            ~stop
            ~proactive_warmup_elapsed
            ~shared_context
            ~boring_consecutive_turns_ref
        in
        (* Turn failure threshold: registry tracks count (via unified_turn),
                 keepalive raises to terminate the fiber for supervisor restart. *)
        let turn_fail_count =
          Keeper_registry.get_turn_failures ~base_path:ctx.config.base_path m.name
        in
        (* RFC-0002: dispatch turn status event *)
        if turn_fail_count > 0 then
          ignore (Keeper_registry.dispatch_event
            ~base_path:ctx.config.base_path m.name
            (Keeper_state_machine.Turn_failed {
              consecutive = turn_fail_count;
              max_allowed = max_consecutive_turn_failures ();
            }))
        else
          ignore (Keeper_registry.dispatch_event
            ~base_path:ctx.config.base_path m.name
            Keeper_state_machine.Turn_succeeded);
        if turn_fail_count >= max_consecutive_turn_failures ()
        then begin
          Keeper_registry.set_failure_reason
            ~base_path:ctx.config.base_path m.name
            (Some (Keeper_registry.Turn_consecutive_failures turn_fail_count));
          raise Keeper_registry.Keeper_fiber_crash
        end;
        (* Phase 1: work-as-heartbeat — renew point (b).
                 After turn, call Room.heartbeat to prove room I/O health.
                 On success: refresh freshness lease + reset consecutive_failures.
                 On failure: leave timestamp unchanged → presence sync resumes next cycle. *)
        refresh_work_as_heartbeat
          ~ctx
          ~meta_after_proactive
          ~proactive_warmup_elapsed
          ~work_as_hb
          ~last_successful_heartbeat_ts
          ~consecutive_failures;
        let t_turn_end = Time_compat.now () in
        let t_recurring_start = t_turn_end in
        (* Recurring task dispatch (#3190) *)
        let _recurring_dispatched =
          dispatch_recurring_keepalive ~ctx ~meta_after_proactive ~now_ts
        in
        let t_recurring_end = Time_compat.now () in
        let base =
          if smart_hb_enabled ()
          then
            Heartbeat_smart.effective_interval
              ~config:smart_hb_config
              ~last_activity:!last_successful_heartbeat_ts
          else float_of_int (keepalive_interval_sec ())
        in
        (* Phase 0: push stage timing to ring buffer *)
        record_keepalive_stage_timing
          ~timing_ring
          ~timing_cursor
          ~timing_filled
          ~ring_sz
          ~t_presence_start
          ~t_presence_end
          ~t_snapshot_start
          ~t_snapshot_end
          ~t_board_start
          ~t_board_end
          ~t_turn_start
          ~t_turn_end
          ~t_recurring_start
          ~t_recurring_end;
        let jitter =
          base *. Env_config.KeeperKeepalive.jitter_factor *. Random.float 1.0
        in
        interruptible_sleep ~clock:ctx.clock ~stop ~wakeup (base +. jitter));
      if Atomic.get stop then () else loop ())
  in
  loop ()
;;

let with_keeper_entry_by_agent_name ~agent_name ~on_missing f =
  match Keeper_registry.find_by_agent_name agent_name with
  | Some entry -> f entry
  | None -> on_missing ()
;;

let set_keeper_paused_state ~agent_name paused =
  with_keeper_entry_by_agent_name
    ~agent_name
    ~on_missing:(fun () ->
      let action = if paused then "pause" else "resume" in
      Log.Keeper.warn "directive %s: agent %s not in registry" action agent_name)
    (fun entry ->
       Keeper_registry.update_meta
         ~base_path:entry.base_path
         entry.name
         { entry.meta with paused };
       (* RFC-0002: dispatch resume event through state machine *)
       if not paused then
         ignore (Keeper_registry.dispatch_event
           ~base_path:entry.base_path entry.name
           Keeper_state_machine.Operator_resume))
;;

let wakeup_keeper_by_agent_name ~agent_name =
  with_keeper_entry_by_agent_name
    ~agent_name
    ~on_missing:(fun () ->
      Log.Keeper.warn "directive wakeup: agent %s not in registry" agent_name)
    (fun entry -> wakeup_keeper entry.name)
;;

let assign_keeper_task_from_directive ~agent_name ~task_id =
  with_keeper_entry_by_agent_name
    ~agent_name
    ~on_missing:(fun () ->
      Log.Keeper.warn "directive claim: agent %s not in registry" agent_name)
    (fun entry ->
       Keeper_registry.update_meta
         ~base_path:entry.base_path
         entry.name
         { entry.meta with current_task_id = Some task_id };
       wakeup_keeper entry.name)
;;

(** Process a single directive received from a gRPC HeartbeatAck.
    Directives are string commands: "pause", "resume", "wakeup",
    "claim:<task_id>". Unknown directives are logged and ignored. *)
let process_directive ~agent_name directive =
  match directive with
  | "pause" ->
    Log.Keeper.info "directive: pausing keeper %s" agent_name;
    set_keeper_paused_state ~agent_name true
  | "resume" ->
    Log.Keeper.info "directive: resuming keeper %s" agent_name;
    set_keeper_paused_state ~agent_name false
  | "wakeup" ->
    Log.Keeper.debug "directive: waking up %s" agent_name;
    wakeup_keeper_by_agent_name ~agent_name
  | s when String.length s > 6 && String.sub s 0 6 = "claim:" ->
    let task_id = String.sub s 6 (String.length s - 6) in
    Log.Keeper.info "directive: server assigned task %s to %s" task_id agent_name;
    assign_keeper_task_from_directive ~agent_name ~task_id
  | unknown -> Log.Keeper.warn "unknown gRPC directive for %s: %s" agent_name unknown
;;

let current_task_id_for_agent agent_name =
  match Keeper_registry.find_by_agent_name agent_name with
  | Some e -> Option.value ~default:"" e.meta.current_task_id
  | None -> ""
;;

let make_grpc_heartbeat_ping ~agent_name ~session_id =
  Masc_grpc_types.HeartbeatPing.
    { agent_name
    ; session_id
    ; timestamp_ms = Int64.of_float (Time_compat.now () *. 1000.0)
    ; current_task_id = current_task_id_for_agent agent_name
    }
;;

let handle_grpc_heartbeat_ack ~agent_name (ack : Masc_grpc_types.HeartbeatAck.t) =
  Log.Keeper.debug
    "gRPC bidi heartbeat: agent=%s agents=%d tasks=%d directives=%d"
    agent_name
    ack.active_agent_count
    ack.pending_task_count
    (List.length ack.directives);
  List.iter (process_directive ~agent_name) ack.directives
;;

let run_grpc_heartbeat_stream
      ~stop
      ~close_ref
      ~clock
      ~interval_sec
      ~agent_name
      ~session_id
      send
      recv
  =
  let rec tick () =
    if Atomic.get stop || !close_ref
    then ()
    else (
      (try
         send (make_grpc_heartbeat_ping ~agent_name ~session_id);
         match recv () with
         | Ok ack -> handle_grpc_heartbeat_ack ~agent_name ack
         | Error err -> Log.Keeper.warn "gRPC heartbeat recv: %s" err
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | End_of_file -> raise End_of_file
       | exn -> Log.Keeper.error "gRPC heartbeat tick error: %s" (Printexc.to_string exn));
      if not (Atomic.get stop || !close_ref)
      then (
        let no_wakeup = Atomic.make false in
        interruptible_sleep ~clock ~stop ~wakeup:no_wakeup interval_sec;
        tick ()))
  in
  tick ()
;;

let log_grpc_heartbeat_stream_failure ~agent_name ~attempts = function
  | `Closed ->
    Log.Keeper.warn
      "gRPC heartbeat stream closed for %s (attempt %d/%d)"
      agent_name
      (attempts + 1)
      Env_config.KeeperGrpc.max_reconnect_attempts
  | `Error exn ->
    Log.Keeper.warn
      "gRPC heartbeat stream error for %s: %s (attempt %d/%d)"
      agent_name
      (Printexc.to_string exn)
      (attempts + 1)
      Env_config.KeeperGrpc.max_reconnect_attempts
;;

(** Run a gRPC heartbeat sender in a background fiber.
    Opens a bidirectional [Heartbeat] stream and sends [HeartbeatPing]
    messages at the configured interval. Reads [HeartbeatAck] responses,
    logs agent/task counts, and dispatches directives. Reconnects on
    stream failure up to 5 times. Stops when [stop] is set.

    Requires [grpc_client_ref] to be set (via [set_grpc_client])
    and Eio switch/env to be available in [Eio_context]. *)
let max_reconnect_attempts = Env_config.KeeperGrpc.max_reconnect_attempts

let reconnect_backoff_sec = Env_config.KeeperGrpc.reconnect_backoff_sec

let run_grpc_heartbeat_fiber
      ~sw
      ~stop
      ~(grpc_client : Masc_grpc_client.t)
      ~(agent_name : string)
      ~(session_id : string)
      ~(interval_sec : float)
      ~(clock : _ Eio.Time.clock)
  =
  match Eio_context.get_switch_opt (), Atomic.get grpc_env_ref with
  | None, _ | _, None ->
    Log.Keeper.warn "gRPC heartbeat: Eio context or env not available";
    None
  | Some grpc_sw, Some env ->
    let close_ref = ref false in
    Eio.Fiber.fork ~sw (fun () ->
      (* Outer loop: reconnect on stream failure *)
      let rec connect_loop attempts =
        if Atomic.get stop || !close_ref
        then ()
        else if attempts >= max_reconnect_attempts
        then
          Log.Keeper.error
            "gRPC heartbeat: exceeded %d reconnect attempts for %s, stopping"
            max_reconnect_attempts
            agent_name
        else (
          let send, recv, close_stream =
            Masc_grpc_client.heartbeat_stream grpc_client ~sw:grpc_sw ~env
          in
          (try
             run_grpc_heartbeat_stream
               ~stop
               ~close_ref
               ~clock
               ~interval_sec
               ~agent_name
               ~session_id
               send
               recv
           with
           | Eio.Cancel.Cancelled _ as e ->
             close_stream ();
             raise e
           | End_of_file ->
             log_grpc_heartbeat_stream_failure ~agent_name ~attempts `Closed;
             close_stream ()
           | exn ->
             log_grpc_heartbeat_stream_failure ~agent_name ~attempts (`Error exn);
             close_stream ());
          if not (Atomic.get stop || !close_ref)
          then (
            Eio.Time.sleep clock reconnect_backoff_sec;
            connect_loop (attempts + 1)))
      in
      connect_loop 0);
    Some (fun () -> close_ref := true)
;;

let start_keeper_grpc_heartbeat
      ~(ctx : _ context)
      ~(m : keeper_meta)
      ~(stop : bool Atomic.t)
  : (unit -> unit) option
  =
  match Masc_grpc_transport.from_env (), Atomic.get grpc_client_ref with
  | Masc_grpc_transport.Grpc, Some client ->
    Log.Keeper.info "keeper %s: starting gRPC heartbeat fiber" m.name;
    let interval = float_of_int (keepalive_interval_sec ()) in
    let session_id =
      Printf.sprintf
        "keeper-%s-%Ld"
        m.name
        (Int64.of_float (Time_compat.now () *. 1000.0))
    in
    run_grpc_heartbeat_fiber
      ~sw:ctx.sw
      ~stop
      ~grpc_client:client
      ~agent_name:m.agent_name
      ~session_id
      ~interval_sec:interval
      ~clock:ctx.clock
  | Masc_grpc_transport.Grpc, None ->
    Log.Keeper.warn "keeper %s: gRPC transport requested but no client configured" m.name;
    None
  | _ -> None
;;

let bootstrap_live_keeper_meta ~(ctx : _ context) (m : keeper_meta) : keeper_meta =
  try
    if not (Room_utils.is_initialized ctx.config)
    then (
      let (_init_msg : string) = Room.init ctx.config ~agent_name:None in
      ());
    let synced = ensure_keeper_room_presence ctx.config m in
    (match write_meta ctx.config synced with
     | Ok () -> ()
     | Error e -> Log.Keeper.warn "write_meta failed (bootstrap): %s" e);
    synced
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.error "room presence bootstrap failed: %s" (Printexc.to_string exn);
    m
;;

let publish_keeper_lifecycle ~event ~keeper_name ~detail : unit =
  match get_bus () with
  | Some bus ->
    Oas_events.publish_keeper_lifecycle
      bus
      ~event
      ~keeper_name
      ~detail
  | None -> ()
;;

let publish_keeper_started ~(live_meta : keeper_meta) : unit =
  publish_keeper_lifecycle
    ~event:"started"
    ~keeper_name:live_meta.name
    ~detail:"keepalive"
;;

let resolve_registry_done
      (entry : Keeper_registry.registry_entry)
      (value : [ `Stopped | `Crashed of string ])
  : bool
  =
  if Option.is_none (Eio.Promise.peek entry.done_p)
  then (
    Eio.Promise.resolve entry.done_r value;
    true)
  else false
;;

let record_keeper_stopped
      (entry : Keeper_registry.registry_entry)
      ~base_path
      ~keeper_name
      ~detail
  : bool
  =
  if resolve_registry_done entry `Stopped
  then (
    ignore (Keeper_registry.dispatch_event ~base_path keeper_name
      Keeper_state_machine.Stop_requested);
    ignore (Keeper_registry.dispatch_event ~base_path keeper_name
      Keeper_state_machine.Drain_complete);
    ignore (Keeper_registry.dispatch_event ~base_path keeper_name
      (Keeper_state_machine.Fiber_terminated { outcome = "stopped" }));
    publish_keeper_lifecycle ~event:"stopped" ~keeper_name ~detail;
    true)
  else
    false
;;

let record_keeper_crashed
      (entry : Keeper_registry.registry_entry)
      ~base_path
      ~keeper_name
      ~failure_reason
  : unit
  =
  let reason = Keeper_registry.failure_reason_to_string failure_reason in
  if resolve_registry_done entry (`Crashed reason)
  then (
    Keeper_registry.set_failure_reason ~base_path keeper_name (Some failure_reason);
    ignore (Keeper_registry.dispatch_event ~base_path keeper_name
      (Keeper_state_machine.Fiber_terminated { outcome = reason }));
    Keeper_registry.record_crash ~base_path keeper_name (Time_compat.now ()) reason;
    Keeper_registry.record_error ~base_path keeper_name reason;
    publish_keeper_lifecycle ~event:"crashed" ~keeper_name ~detail:reason)
;;

let start_keepalive ?(proactive_warmup_sec = 0) (ctx : _ context) (m : keeper_meta) : unit
  =
  if Keeper_registry.is_running ~base_path:ctx.config.base_path m.name
  then Log.Keeper.info "start_keepalive: skipped %s (already running)" m.name
  else if not (Keeper_registry.spawn_slots_available ())
  then Log.Keeper.info "start_keepalive: skipped %s (no spawn slots)" m.name
  else (
    (* Register in Keeper_registry first — single source of truth. *)
    let reg = Keeper_registry.register ~base_path:ctx.config.base_path m.name m in
    (* Restore persisted tool usage stats from previous session *)
    Keeper_registry.restore_tool_usage ~base_path:ctx.config.base_path m.name;
    let stop = reg.fiber_stop in
    let wakeup = reg.fiber_wakeup in
    (* Start optional gRPC heartbeat fiber *)
    let grpc_close = start_keeper_grpc_heartbeat ~ctx ~m ~stop in
    (match grpc_close with
     | Some _ ->
       Keeper_registry.set_grpc_close ~base_path:ctx.config.base_path m.name grpc_close
     | None -> ());
    let live_meta = bootstrap_live_keeper_meta ~ctx m in
    Keeper_registry.update_meta ~base_path:ctx.config.base_path m.name live_meta;
    publish_keeper_started ~live_meta;
    (* Start telemetry feedback proactive cache refresh loop *)
    (match live_meta.telemetry_feedback_enabled with
     | Some true ->
       let window =
         Option.value ~default:24 live_meta.telemetry_feedback_window_hours
       in
       let decision_log_path =
         Keeper_types_support.keeper_decision_log_path ctx.config live_meta.name
       in
       Keeper_telemetry_feedback.start_refresh_loop
         ~sw:ctx.sw ~clock:ctx.clock
         ~keeper_name:live_meta.name
         ~decision_log_path
         ~window_hours:window
         ~interval_sec:60
         ~stop
     | _ -> ());
    Eio.Fiber.fork ~sw:ctx.sw (fun () ->
      let record_crash failure_reason =
        record_keeper_crashed
          reg
          ~base_path:ctx.config.base_path
          ~keeper_name:live_meta.name
          ~failure_reason
      in
      let record_stopped detail =
        ignore
          (record_keeper_stopped
             reg
             ~base_path:ctx.config.base_path
             ~keeper_name:live_meta.name
             ~detail)
      in
      Fun.protect
        (fun () ->
          try
            run_heartbeat_loop ~proactive_warmup_sec ctx live_meta stop ~wakeup;
            record_stopped "normal exit"
          with
          | Keeper_registry.Keeper_fiber_crash ->
            if Atomic.get stop then
              record_stopped "manual stop"
            else
              let reason =
                match Keeper_registry.get
                        ~base_path:ctx.config.base_path live_meta.name with
                | Some e ->
                  Option.value
                    ~default:(Keeper_registry.Exception "fiber_crash")
                    e.last_failure_reason
                | None -> Keeper_registry.Exception "fiber_crash"
              in
              record_crash reason
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            if Atomic.get stop then
              record_stopped "manual stop"
            else begin
              Log.Keeper.error
                "heartbeat loop for %s crashed: %s"
                live_meta.name
                (Printexc.to_string exn);
              record_crash (Keeper_registry.Exception (Printexc.to_string exn))
            end)
        ~finally:(fun () ->
          Keeper_registry.cleanup_tracking ~base_path:ctx.config.base_path live_meta.name)))
;;

let stop_keepalive ?base_path name =
  let entries =
    Keeper_registry.all ?base_path ()
    |> List.filter (fun (e : Keeper_registry.registry_entry) ->
         String.equal e.name name)
  in
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       Atomic.set entry.fiber_stop true;
       Atomic.set entry.fiber_wakeup true;
       (match Atomic.get entry.grpc_close with
       | Some close_fn ->
          (try close_fn () with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | _exn -> ())
        | None -> ());
       (match entry.phase with
        | Keeper_state_machine.Crashed | Keeper_state_machine.Dead -> ()
        | _ ->
          if
            record_keeper_stopped
              entry
              ~base_path:entry.base_path
              ~keeper_name:entry.name
              ~detail:"manual stop"
          then
            Keeper_registry.cleanup_tracking ~base_path:entry.base_path entry.name))
    entries
;;

(** Stop all running keepers. Used in test cleanup to prevent orphaned
    keepalive loops from blocking process exit. *)
let stop_all_keepalives () =
  Keeper_registry.all ()
  |> List.iter (fun (entry : Keeper_registry.registry_entry) ->
       stop_keepalive entry.name)
;;
