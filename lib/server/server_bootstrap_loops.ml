(** Server_bootstrap_loops — Keeper loops and background maintenance.

    Extracted from Server_runtime_bootstrap to isolate the large
    subsystem-spawning functions into a focused module. *)

let install_tooling ~governance_level (state : Mcp_server.server_state) =
  Governance_pipeline.install ~config:state.room_config ~governance_level

(* Stable djb2-style hash for the autoboot warmup jitter.

   Post-#13119 follow-up: the previous implementation used native
   [int] arithmetic with a final [land 0x3FFF_FFFF] mask.  That is
   NOT actually platform-stable: on 31-bit OCaml the intermediate
   [acc lsl 5] overflow wraps differently than on 63-bit OCaml
   before the mask is applied, so the same keeper name can hash to
   different buckets depending on architecture.

   Fix: do all arithmetic in [Int32], whose wrap-around behavior is
   identical on every supported runtime.  Mask to 30 bits and convert
   back to [int].  30 bits ≈ 1G distinct buckets, far more than any
   realistic [stagger_window_sec]. *)
let stable_keeper_name_hash_mask_i32 = 0x3FFF_FFFFl

let stable_keeper_name_hash name =
  let acc = ref 5381l in
  String.iter
    (fun ch ->
      let shifted = Int32.shift_left !acc 5 in
      let summed = Int32.add (Int32.add shifted !acc) (Int32.of_int (Char.code ch)) in
      acc := Int32.logand summed stable_keeper_name_hash_mask_i32)
    name;
  Int32.to_int !acc

let autoboot_proactive_warmup_sec ~base_warmup ~stagger_window_sec ~keeper_name =
  let base_warmup = max 0 base_warmup in
  let stagger_window_sec = max 0 stagger_window_sec in
  if stagger_window_sec = 0 then base_warmup
  else
    base_warmup
    + (stable_keeper_name_hash keeper_name mod (stagger_window_sec + 1))

let board_sse_event_params event =
  match event with
  | Board_dispatch.Post_created { post_id; author; title; content; post_kind; hearth } ->
      let preview =
        if String.length content > 200 then String.sub content 0 200
        else content
      in
      let base = [("type", `String "post_created");
                  ("event_type", `String "post.created");
                  ("post_id", `String post_id);
                  ("author", `String author);
                  ("author_identity", Server_utils.board_actor_identity_json author);
                  ("title", `String title);
                  ("content", `String preview);
                  ("post_kind", `String (Board.post_kind_to_string post_kind))] in
      `Assoc (match hearth with
              | Some h -> ("hearth", `String h) :: base
              | None -> base)
  | Board_dispatch.Comment_added { post_id; comment_id; author } ->
      `Assoc [("type", `String "comment_added");
              ("event_type", `String "comment.created");
              ("post_id", `String post_id);
              ("comment_id", `String comment_id);
              ("author", `String author);
              ("author_identity", Server_utils.board_actor_identity_json author)]
  | Board_dispatch.Post_voted { post_id; voter; direction } ->
      let dir = Board_votes.vote_direction_to_string direction in
      `Assoc [("type", `String "post_voted");
              ("event_type", `String "vote.changed");
              ("target_type", `String "post");
              ("post_id", `String post_id);
              ("voter", `String voter);
              ("voter_identity", Server_utils.board_actor_identity_json voter);
              ("direction", `String dir)]
  | Board_dispatch.Comment_voted { comment_id; voter; direction } ->
      let dir = Board_votes.vote_direction_to_string direction in
      `Assoc [("type", `String "comment_voted");
              ("event_type", `String "vote.changed");
              ("target_type", `String "comment");
              ("comment_id", `String comment_id);
              ("voter", `String voter);
              ("voter_identity", Server_utils.board_actor_identity_json voter);
              ("direction", `String dir)]
  | Board_dispatch.Reaction_changed { target_type; target_id; user_id; emoji; reacted } ->
      `Assoc [("type", `String "reaction_changed");
              ("event_type", `String "reaction.changed");
              ("target_type", `String (Board.reaction_target_type_to_string target_type));
              ("target_id", `String target_id);
              ("user_id", `String user_id);
              ("user_identity", Server_utils.board_actor_identity_json user_id);
              ("emoji", `String emoji);
              ("reacted", `Bool reacted)]

module For_testing = struct
  let autoboot_proactive_warmup_sec = autoboot_proactive_warmup_sec
  let board_sse_event_params = board_sse_event_params
end

let filteri_with_fair_yield f xs =
  let meter = Eio_guard.create_yield_meter ~interval:1 () in
  List.filteri
    (fun idx item ->
      let keep = f idx item in
      Eio_guard.yield_step meter;
      keep)
    xs

let iteri_with_fair_yield f xs =
  let meter = Eio_guard.create_yield_meter ~interval:1 () in
  List.iteri
    (fun idx item ->
      f idx item;
      Eio_guard.yield_step meter)
    xs

let start_keeper_loops ~sw ~clock ~net ~domain_mgr ~proc_mgr
    (state : Mcp_server.server_state) =
  Progress.set_sse_callback Sse.broadcast;
  (* Wire stop_keeper hook so zombie GC can terminate keeper fibers *)
  Atomic.set Coord_hooks.stop_keeper_fn Keeper_keepalive.stop_keepalive;
  (* task-103: auto-provision a per-task sandbox worktree on successful
     claim for keepers running with sandbox_profile=Docker. Best-effort —
     failures are logged and the claim succeeds regardless, keeping claim
     semantics decoupled from sandbox state. Local-profile keepers work on
     the project root directly and do not need provisioning. *)
  Atomic.set Coord_hooks.claim_post_provision_fn
    (fun config ~agent_name ~task_id ->
      let outcome =
        match Keeper_identity.keeper_name_from_agent_name agent_name with
        | None -> "skip_not_keeper"
        | Some keeper_name ->
          (match Keeper_meta_store.read_meta config keeper_name with
           | Error _ | Ok None -> "skip_no_meta"
           | Ok (Some meta) ->
             (match meta.Keeper_meta_contract.sandbox_profile with
              | Keeper_types.Local -> "skip_local"
              | Keeper_types.Docker ->
                  (match Task_sandbox.create ~config ~task_id ~agent_name () with
                   | Ok _sandbox ->
                       Log.Misc.info
                         "[claim_auto_provision] keeper=%s task=%s \
                          worktree provisioned"
                         keeper_name task_id;
                       "created"
                   | Error msg ->
                       (* The error string is double-wrapped by the time it
                          reaches us ("worktree creation failed: IO
                          error: <inner>"), so prefix-match by substring on
                          the inner tag rather than expecting an exact
                          match.  ambiguous_task_repo and
                          missing_sandbox_clone are expected
                          "needs-disambiguation" outcomes — log info and
                          report skip_* so they do not inflate the error
                          metric / alerting. *)
                       if String_util.contains_substring msg
                            "ambiguous_task_repo:" then begin
                         Log.Misc.info
                           "[claim_auto_provision] keeper=%s task=%s \
                            worktree provisioning skipped: %s"
                           keeper_name task_id msg;
                         "skip_ambiguous"
                       end else if String_util.contains_substring msg
                                     "missing_sandbox_clone:" then begin
                         Log.Misc.info
                           "[claim_auto_provision] keeper=%s task=%s \
                            worktree provisioning skipped: %s"
                           keeper_name task_id msg;
                         "skip_missing_sandbox_clone"
                       end else begin
                         Log.Misc.warn
                           "[claim_auto_provision] keeper=%s task=%s \
                            worktree provisioning failed: %s"
                           keeper_name task_id msg;
                         "error"
                       end)))
      in
      Prometheus.inc_counter Keeper_metrics.metric_keeper_claim_auto_provision
        ~labels:[ ("outcome", outcome); ("agent_name", agent_name) ]
        ());
  (* Shared Agent_sdk Event_bus used as the runtime transport between subsystems. *)
  let event_bus = Agent_sdk.Event_bus.create () in
  (* Eio fiber isolation: each subsystem runs in its own fiber.
     If one crashes, others keep running — Eio's structured concurrency.
     Subsystem_health tracks liveness at module level (no init timing dependency). *)
  let fork_subsystem name f =
    Subsystem_health.register name;
    Eio.Fiber.fork ~sw (fun () ->
      try f ()
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Subsystem_health.mark_dead name;
        Log.Server.error "subsystem %s crashed: %s" name
          (Printexc.to_string exn))
  in
  let wait_for_lazy_startup () =
    (* Combines #10843 (per-task elapsed diagnostic, merged via #10854) with
       a per-task boot guard.  The diagnostic surface stays as #10854
       intended — running/HUNG tags + INFO→WARN escalation at 60s — and
       the boot guard kicks in at [boot_guard_sec] (default 120s) to
       fail-out tasks that exceed it via [Server_startup_state.fail_lazy_task].
       Without a hard ceiling, a single hung task (e.g. [restore_sessions]
       hanging 17 min, #10843) blocks keeper boot indefinitely; the 240s
       startup watchdog does NOT cover this case because [activate_lazy]
       sets state_ready=true before the lazy fibers finish. *)
    let started_at = Hashtbl.create 16 in
    let hung_threshold_sec = 60.0 in
    let boot_guard_sec =
      match Sys.getenv_opt "MASC_LAZY_TASK_BOOT_GUARD_SEC" with
      | Some v -> (match float_of_string_opt (String.trim v) with
                   | Some f when f > 0.0 -> f
                   | _ -> 120.0)
      | None -> 120.0
    in
    let format_pending now pending =
      pending
      |> List.map (fun task ->
          let elapsed =
            match Hashtbl.find_opt started_at task with
            | Some t -> now -. t
            | None -> 0.0
          in
          let tag =
            if elapsed >= hung_threshold_sec then "HUNG" else "running"
          in
          Printf.sprintf "%s (%s %.1fs)" task tag elapsed)
      |> String.concat ", "
    in
    let rec loop last_log_at =
      let pending = Server_startup_state.pending_lazy_tasks () in
      if pending = [] then ()
      else begin
        let now = Eio.Time.now clock in
        List.iter
          (fun task ->
            if not (Hashtbl.mem started_at task) then
              Hashtbl.add started_at task now)
          pending;
        Hashtbl.filter_map_inplace
          (fun task t -> if List.mem task pending then Some t else None)
          started_at;
        let stuck =
          List.filter (fun task ->
            match Hashtbl.find_opt started_at task with
            | Some seen_at -> now -. seen_at >= boot_guard_sec
            | None -> false)
            pending
        in
        if stuck <> [] then begin
          List.iter (fun task ->
            let elapsed =
              match Hashtbl.find_opt started_at task with
              | Some seen_at -> now -. seen_at
              | None -> 0.0
            in
            Log.Keeper.error
              "autoboot: lazy task %s exceeded boot guard %.0fs (elapsed %.1fs) — failing it so keeper boot can proceed"
              task boot_guard_sec elapsed;
            Prometheus.inc_counter
              "masc_lazy_task_boot_guard_fired_total"
              ~labels:[ ("task", task) ]
              ();
            Server_startup_state.fail_lazy_task
              ~task
              ~error:(Printf.sprintf "lazy_task_boot_guard:%.0fs" boot_guard_sec))
            stuck;
          loop last_log_at
        end else begin
          let last_log_at =
            if now -. last_log_at >= 5.0 then begin
              let max_elapsed =
                List.fold_left
                  (fun m task ->
                    match Hashtbl.find_opt started_at task with
                    | Some s -> Float.max m (now -. s)
                    | None -> m)
                  0.0 pending
              in
              let log_fn =
                if max_elapsed >= hung_threshold_sec then Log.Keeper.warn
                else Log.Keeper.info
              in
              log_fn
                "autoboot: waiting for lazy startup tasks to finish before keeper boot [%s]"
                (format_pending now pending);
              now
            end else
              last_log_at
          in
          Eio.Time.sleep clock
            Env_config_keeper.KeeperBootstrap.lazy_startup_poll_interval_sec;
          loop last_log_at
        end
      end
    in
    loop (Eio.Time.now clock)
  in
  (* Create and install the MASC-owned Event_bus alongside OAS's.
     MASC domain events (masc.broadcast, masc.heartbeat, masc.keeper.*,
     masc.autonomy.*, masc.harness.*, masc.trust_updated, ...) publish
     here per OAS event_bus.mli:103-107 boundary. Dashboard SSE consumers
     see both channels as one stream — the relay translates masc.* →
     masc:* on the wire for backward compatibility. *)
  let masc_event_bus = Agent_sdk.Event_bus.create () in
  Masc_event_bus.set masc_event_bus;
  (* Event_bus → SSE bridge: relay both OAS and MASC buses to dashboard *)
  Cascade_event_bridge.start ~sw ~clock ~config:state.room_config ~bus:event_bus;
  Cascade_event_bridge.start ~sw ~clock ~config:state.room_config ~bus:masc_event_bus;
  (* Compaction audit: subscribe to ContextCompactStarted/ContextCompacted and
     persist paired rows to [base_path/data/harness-compact/YYYY-MM/DD.jsonl]
     with rolling 14-day retention (override via
     MASC_COMPACTION_AUDIT_RETENTION_DAYS). Independent from the SSE bridge —
     each subscriber gets its own bounded stream. *)
  Keeper_compact_audit.spawn_subscriber
    ~sw ~clock
    ~base_path:(Env_config.base_path ())
    ~retention_days:14
    event_bus;
  (* Telemetry feedback loop: consume OAS per-turn signals into
     per-(provider,model) EWMA health state.  See
     lib/keeper/keeper_provider_health.ml for the aggregator and
     lib/keeper/keeper_telemetry_consumer.ml for the subscriber. *)
  Keeper_telemetry_consumer.spawn_subscriber ~sw ~bus:event_bus;
  let keeper_lifecycle_sub =
    Agent_sdk_metrics_bridge.subscribe
      ~purpose:"lifecycle_listener"
      ~filter:(fun (evt : Agent_sdk.Event_bus.event) ->
        match evt.payload with
        | Agent_sdk.Event_bus.Custom ("masc.keeper.lifecycle", _) -> true
        | _ -> false)
      masc_event_bus
  in
  Eio.Switch.on_release sw (fun () ->
    Agent_sdk_metrics_bridge.unsubscribe masc_event_bus keeper_lifecycle_sub);
  (* Spawn the OAS bus depth sampler so warnings surface on stdout
     even when /metrics is not scraped.

     [MASC_OAS_BUS_WARN_DEPTH] lets operators raise the threshold without
     a rebuild — fleet-wide keeper load legitimately pushes depth past
     the 200 default at peak (issue #8517). Invalid values fall back to
     the compile-time default. *)
  let warn_threshold =
    match Sys.getenv_opt "MASC_OAS_BUS_WARN_DEPTH" with
    | Some v -> (match int_of_string_opt (String.trim v) with
                 | Some n when n > 0 -> n
                 | _ -> 200)
    | None -> 200
  in
  Agent_sdk_metrics_bridge.start_sampler ~sw ~clock ~warn_threshold ();
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (try
        let events = Agent_sdk_metrics_bridge.drain keeper_lifecycle_sub in
        List.iter
          (fun (evt : Agent_sdk.Event_bus.event) ->
            match evt.payload with
            | Agent_sdk.Event_bus.Custom ("masc.keeper.lifecycle", payload) ->
                (match
                   ( Safe_ops.json_string_opt "event" payload,
                     Safe_ops.json_string_opt "keeper_name" payload )
                 with
                | Some event, Some keeper_name ->
                    Server_dashboard_http.patch_keeper_dependent_caches
                      ~keeper_name ~event
                | None, _ | Some _, None ->
                    (* P3 cleanup: previously malformed lifecycle events
                       (missing `event` or `keeper_name` field) were
                       silently dropped.  A systematic encoding bug
                       could lose every cache invalidation indefinitely
                       with no signal.  Bumping a Prometheus counter
                       lets `rate(...)` alerts catch the regression
                       even though the dashboard cache continues to
                       degrade gracefully (just stale, not broken). *)
                    Prometheus.inc_counter
                      "masc_keeper_lifecycle_malformed_total" ())
            | _ -> Log.Dashboard.debug "ignored non-lifecycle event")
          events;
        if events <> [] then begin
          Log.Dashboard.info
            "patched keeper-dependent dashboard caches (%d lifecycle event(s))"
            (List.length events);
          Server_dashboard_http.broadcast_namespace_truth_snapshot state
        end
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Dashboard.error "keeper lifecycle listener iteration failed: %s"
          (Printexc.to_string exn));
      Eio.Time.sleep clock
        Env_config_keeper.KeeperBootstrap.keeper_listener_retry_interval_sec;
      loop ()
    in
    loop ());
  (* Inject Event_bus into keeper keepalive runtime for telemetry publishing *)
  Keeper_keepalive.set_bus event_bus;
  Board_dispatch.set_keeper_board_signal_hook (fun signal ->
    Keeper_keepalive.wakeup_relevant_keeper_for_board_signal
      ~config:state.room_config
      signal);
  Board_dispatch.set_board_sse_hook (fun event ->
    let params = board_sse_event_params event in
    Sse.broadcast (`Assoc [
      ("jsonrpc", `String "2.0");
      ("method", `String "notifications/board");
      ("params", params)
    ]);
    (* Emit activity event so Discord/external connectors can detect board posts *)
    let activity_kind, activity_actor, activity_subject, activity_payload = match event with
      | Board_dispatch.Post_created { post_id; author; title; content; post_kind; hearth } ->
          let base = [("post_id", `String post_id); ("title", `String title);
                      ("content", `String content); ("author", `String author);
                      ("author_identity", Server_utils.board_actor_identity_json author);
                      ("post_kind", `String (Board.post_kind_to_string post_kind))] in
          let payload_fields = match hearth with
            | Some h -> ("hearth", `String h) :: base
            | None -> base
          in
          (Event_kind.Board.to_string Event_kind.Board.Posted,
           Server_utils.board_actor_entity author,
           Some (Activity_graph.entity ~kind:"post" post_id),
           `Assoc payload_fields)
      | Board_dispatch.Comment_added { post_id; comment_id; author } ->
          (Event_kind.Board.to_string Event_kind.Board.Commented,
           Server_utils.board_actor_entity author,
           Some (Activity_graph.entity ~kind:"post" post_id),
           `Assoc [("post_id", `String post_id); ("comment_id", `String comment_id);
                   ("author", `String author);
                   ("author_identity", Server_utils.board_actor_identity_json author)])
      | Board_dispatch.Post_voted { post_id; voter; direction } ->
          let dir = Board_votes.vote_direction_to_string direction in
          (Event_kind.Board.to_string Event_kind.Board.Voted,
           Server_utils.board_actor_entity voter,
           Some (Activity_graph.entity ~kind:"post" post_id),
           `Assoc [("post_id", `String post_id); ("voter", `String voter);
                   ("voter_identity", Server_utils.board_actor_identity_json voter);
                   ("direction", `String dir)])
      | Board_dispatch.Comment_voted { comment_id; voter; direction } ->
          let dir = Board_votes.vote_direction_to_string direction in
          (Event_kind.Board.to_string Event_kind.Board.Voted,
           Server_utils.board_actor_entity voter,
           Some (Activity_graph.entity ~kind:"comment" comment_id),
           `Assoc [("comment_id", `String comment_id); ("voter", `String voter);
                   ("voter_identity", Server_utils.board_actor_identity_json voter);
                   ("direction", `String dir)])
      | Board_dispatch.Reaction_changed { target_type; target_id; user_id; emoji; reacted } ->
          (Event_kind.Board.to_string Event_kind.Board.Voted,
           Server_utils.board_actor_entity user_id,
           Some (Activity_graph.entity
                   ~kind:(Board.reaction_target_type_to_string target_type)
                   target_id),
           `Assoc [("target_type", `String (Board.reaction_target_type_to_string target_type));
                   ("target_id", `String target_id);
                   ("user_id", `String user_id);
                   ("user_identity", Server_utils.board_actor_identity_json user_id);
                   ("emoji", `String emoji);
                   ("reacted", `Bool reacted)])
    in
    (* P2 silent-failure fix: Activity_graph.emit failures (Discord
       webhook, audit trail writes, etc.) were previously ignored
       entirely.  An operator seeing board activity on the dashboard
       had no signal that the external systems failed to receive the
       event.  Catch + warn surfaces the failure in operator logs
       without aborting the SSE broadcast that already succeeded. *)
    (try
       ignore (Activity_graph.emit state.room_config
         ~actor:activity_actor ?subject:activity_subject
         ~kind:activity_kind ~payload:activity_payload
         ~tags:["board"; activity_kind] ())
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
         Log.Misc.warn
           "board: Activity_graph.emit kind=%s failed: %s"
           activity_kind (Printexc.to_string exn)));
  (* Wire broadcast → keeper wakeup: any broadcast wakes keepers so they
     can react to new tasks, mentions, or room activity immediately.
     Coord_state.on_broadcast_mention is the active path (Coord.broadcast uses
     Coord_state.broadcast); Coord_eio.on_broadcast_mention is kept in sync as
     a safety net for any legacy callers. *)
  let broadcast_mention_handler = (fun mention ->
    match mention with
    | Some target ->
        Keeper_keepalive.wakeup_keeper
          ~base_path:state.room_config.base_path target;
        Log.Keeper.info "broadcast mention → wakeup keeper %s" target
    | None ->
        Keeper_keepalive.wakeup_all_keepers
          ~base_path:state.room_config.base_path ();
        Log.Keeper.info "broadcast → wakeup all keepers (reactive push)") in
  Coord_broadcast.on_broadcast_mention := broadcast_mention_handler;
  Coord_eio.on_broadcast_mention := broadcast_mention_handler;
  (* Orchestrator needs synchronous registration for shutdown hook *)
  (try
    let cancel_orchestrator =
      Orchestrator.start ~sw ~proc_mgr ~clock ~domain_mgr state.room_config
    in
    Shutdown_hooks.register_cancel_orchestrator cancel_orchestrator
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Server.error "subsystem orchestrator failed to start: %s"
      (Printexc.to_string exn));
  (* RFC-0036 Phase A.3: register default keeper-lifecycle cleanup
     hooks once during bootstrap. Both calls are Atomic-guarded
     idempotent so re-bootstrapping (e.g. tests) is safe. *)
  Keeper_subprocess_registry.register_default_cleanup_hook ();
  Keeper_bg_task_cleanup.register_default_cleanup_hook ();
  (* Build read-only tool surface shared by both judges. *)
  let judge_tool_names =
    List.map Tool_name.Masc.to_string
      Tool_name.Masc.[ Status; Tasks; Agents; Board_list ]
  in
  let judge_masc_tools =
    match
      Agent_tool_surfaces.local_worker_tool_schemas ~names:judge_tool_names ()
    with
    | Ok schemas -> schemas
    | Error e ->
        Log.Server.warn "judge tool schema resolution failed: %s"
          e;
        []
  in
  let make_judge_dispatch ~actor ~(name : string) ~(args : Yojson.Safe.t)
      : Tool_result.t =
    let start_time = Time_compat.now () in
    let config = state.room_config in
    let agent_name = actor in
    let ctx_room : Tool_coord.context = { config; agent_name } in
    let ctx_task : Tool_task.context = { config; agent_name; sw = Some sw } in
    let ctx_agent : Tool_agent.context = { config; agent_name } in
    match name with
    | "masc_status" -> (
        match Tool_coord.dispatch ctx_room ~name ~args with
        | Some { Coord_types.success; message } ->
            Tool_result.wrap ~tool_name:name ~start_time (success, message)
        | None ->
            Tool_result.wrap ~tool_name:name ~start_time
              (false, "masc_status: dispatch failed"))
    | "masc_tasks" -> (
        match Tool_task.dispatch ctx_task ~name ~args with
        | Some result -> result
        | None ->
            Tool_result.wrap ~tool_name:name ~start_time
              (false, "masc_tasks: dispatch failed"))
    | "masc_agents" -> (
        match Tool_agent.dispatch ctx_agent ~name ~args with
        | Some result ->
            Tool_result.wrap ~tool_name:name ~start_time result
        | None ->
            Tool_result.wrap ~tool_name:name ~start_time
              (false, "masc_agents: dispatch failed"))
    | "masc_board_list" ->
        Tool_board.handle_tool name args
    | _ ->
        Tool_result.wrap ~tool_name:name ~start_time
          (false, Printf.sprintf "judge: tool '%s' not allowed" name)
  in
  let governance_judge_dispatch = make_judge_dispatch ~actor:"governance-judge" in
  let operator_judge_dispatch = make_judge_dispatch ~actor:"operator-judge" in
  fork_subsystem "governance_judge" (fun () ->
    Dashboard_governance_judge.start ~sw ~clock ~net
      ~base_path:state.room_config.base_path
      ~masc_tools:judge_masc_tools ~dispatch:governance_judge_dispatch
      ~build_facts:(fun () ->
        let base = `Assoc
          [
            ("generated_at", `String (Masc_domain.now_iso ()));
            ("items", `List []);
            ("activity", `List []);
          ]
        in
        let agents = Coord.get_agents_status state.room_config in
        Operator_control_snapshot.merge_json_objects base
          (`Assoc [("agents", agents)]))
      ());
  fork_subsystem "operator_judge" (fun () ->
    let operator_judge_ctx : _ Operator_control.context =
      {
        config = state.room_config;
        agent_name = "operator-judge";
        sw;
        clock;
        proc_mgr = Some proc_mgr;
        net = state.net;
        mcp_session_id = None;
      }
    in
    Dashboard_operator_judge.start ~sw ~clock ~net ~config:state.room_config
      ~masc_tools:judge_masc_tools ~dispatch:operator_judge_dispatch
      ~build_facts:(fun () ->
        Operator_control.snapshot_json ~actor:"operator-judge" ~view:"summary"
          ~include_messages:false ~include_keepers:false operator_judge_ctx)
      ());
  fork_subsystem "session_cleanup" (fun () ->
    Session.start_mcp_session_cleanup_loop ~sw ~clock ());
  fork_subsystem "verification_timeout" (fun () ->
    let interval = Env_config_runtime.Verification.timeout_check_interval_seconds in
    let rec loop () =
      Eio.Time.sleep clock interval;
      Verification_protocol.check_timeouts ~config:state.room_config;
      loop ()
    in
    loop ());
  (* #10405: Goal_janitor.run was previously only invoked by the
     dashboard DELETE handler, so stagnated [Active] goals never got
     promoted to [Dropped] and [last_review_at] stayed null indefinitely
     (4 goals stale for 4 days observed on 2026-04-25).  Spawn a
     periodic sweep fiber on a 1-hour cadence so the existing
     [stagnant_days] / [dropped_ttl_days] thresholds actually fire.
     [enabled ()] is true by default; flipping it to false leaves the
     dashboard DELETE path as the only caller (pre-fix behaviour). *)
  fork_subsystem "goal_janitor" (fun () ->
    if not (Env_config_runtime.Goal_janitor.enabled ()) then
      Log.Server.info "goal_janitor: disabled via MASC_GOAL_JANITOR_ENABLED=false"
    else begin
      let interval = Env_config_runtime.Goal_janitor.interval_seconds in
      let rec loop () =
        Eio.Time.sleep clock interval;
        (try
           let _result = Goal_janitor.run state.room_config in
           ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Server.warn "goal_janitor: sweep failed: %s"
             (Printexc.to_string exn));
        loop ()
      in
      loop ()
    end);
  (* HITL approval queue death-spiral fix.
     [Keeper_approval_queue.expire_stale] has been a complete
     implementation (queue removal, audit event, promise [Reject]
     resolution, on_resolution callback) with a unit test since
     introduction, but was never invoked by any production caller.
     Result: a HITL approval enqueued by a keeper turn would block
     [keeper_cycle_decision] forever via the
     [has_pending_for_keeper → Skip Approval_pending] branch in
     [keeper_world_observation.ml:928].  At the 300s stale-watchdog
     threshold the supervisor would respawn the fiber, the same
     approval entry would still be in the queue, and the cycle
     would repeat indefinitely.  Pair with #10962
     ([last_skip_observation] surface) so operators can see
     [last_skip=[approval_pending]] alongside the kill warn line.
     [max_wait_s] is a code constant (policy, not calibration);
     [interval_seconds] mirrors [Goal_janitor]'s env exposure so
     ops can tune cadence without changing policy. *)
  fork_subsystem "approval_janitor" (fun () ->
    if not (Env_config_runtime.Approval_janitor.enabled ()) then
      Log.Server.info
        "approval_janitor: disabled via MASC_APPROVAL_JANITOR_ENABLED=false"
    else begin
      let interval = Env_config_runtime.Approval_janitor.interval_seconds in
      (* 30 minutes — long enough that humans actually have time to
         respond on dashboard / Slack / etc., short enough that the
         keeper isn't trapped on the death-spiral kill loop after the
         operator forgets a request.  Code constant: changes need code
         review (policy), not a runtime knob. *)
      let max_wait_s = 1800.0 in
      let rec loop () =
        Eio.Time.sleep clock interval;
        (try
           Keeper_approval_queue.expire_stale ~max_wait_s
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Server.warn "approval_janitor: sweep failed: %s"
             (Printexc.to_string exn));
        loop ()
      in
      loop ()
    end);
  (* Auto-boot keepers from keeper meta and start keepalive loops.
     Retries unbooted keepers up to [max_retries] times so transient
     failures (model resolution, discovery timing) don't permanently
     block keeper startup.  See #5717. *)
  fork_subsystem "keeper_autoboot" (fun () ->
    if not Env_config.KeeperBootstrap.enabled then
      Log.Keeper.info "autoboot: disabled via MASC_KEEPER_BOOTSTRAP_ENABLED=false"
    else begin
      wait_for_lazy_startup ();
      Log.Keeper.info "autoboot: lazy startup complete; keeper bootstrap will start last";
      (* Brief delay so other subsystems (SSE, board, orchestrator) settle first. *)
      Eio.Time.sleep clock
        Env_config_keeper.KeeperBootstrap.post_startup_settle_sec;
      let config = state.room_config in
      let masc_root = Coord.masc_root_dir config in
      let keeper_dir = Keeper_fs.keeper_dir config in
      let all_names = Keeper_types.keeper_names config in
      let all_count = List.length all_names in
      Log.Keeper.info
        "autoboot: base_path=%s masc_root=%s keeper_dir=%s keeper_json_count=%d"
        config.base_path masc_root keeper_dir all_count;
      (* 2026-05-05 — auto-repair active_goal_ids=[] keepers before boot.
         Newer keepers (created via persona autoboot or
         masc_keeper_create_from_persona) start with active_goal_ids=[] and
         have no automatic path to populate it, so they enter a "frozen"
         state where work_discovery runs but no desire fires (no goal →
         keeper_stay_silent → completion contract violation, then
         contract violation was previously class=null per #13055).
         Keeper_goal_repair was previously only invokable via
         masc_keeper_persona_audit(repair=true) MCP tool — manual operator
         action.  Default-on so keepers self-heal on next server restart;
         opt out with MASC_KEEPER_AUTO_GOAL_REPAIR=false.  Idempotent:
         skips keepers that already have non-empty active_goal_ids. *)
      let auto_repair_enabled =
        match Sys.getenv_opt "MASC_KEEPER_AUTO_GOAL_REPAIR" with
        | Some ("0" | "false" | "FALSE" | "off" | "OFF") -> false
        | _ -> true
      in
      (if auto_repair_enabled then
         try
           let result = Keeper_goal_repair.run config in
           let action_count = List.length result.actions in
           let error_count = List.length result.errors in
           let skipped_count = List.length result.skipped in
           if action_count > 0 || error_count > 0 then
             Log.Keeper.info
               "autoboot: goal_repair created=%d errors=%d skipped=%d \
                (set MASC_KEEPER_AUTO_GOAL_REPAIR=false to disable)"
               action_count error_count skipped_count
           else
             Log.Keeper.info
               "autoboot: goal_repair scanned, all keepers have \
                active_goal_ids (skipped=%d)"
               skipped_count
         with exn ->
           Log.Keeper.warn
             "autoboot: goal_repair failed (continuing without repair): %s"
             (Printexc.to_string exn));
      let names = Keeper_runtime.bootable_keeper_names config in
      let keeper_boot_ctx : _ Keeper_types.context = {
        config;
        agent_name = "keeper-autoboot";
        sw;
        clock;
        proc_mgr = Some proc_mgr;
        net = state.net;
      } in
      Log.Keeper.info
        "autoboot: %d keeper(s) to boot; concurrent keeper turns throttled to %d via MASC_KEEPER_AUTOBOOT_MAX"
        (List.length names) Keeper_keepalive.keeper_turn_throttle_limit;
      Log.Keeper.info "autoboot: keeper set [%s]" (String.concat ", " names);
      let base_warmup = Keeper_config.keeper_bootstrap_proactive_warmup_sec () in
      let stagger_window = Keeper_config.keeper_bootstrap_stagger_step_sec () in
      (* Attempt to boot a single keeper. Returns true if started. *)
      let try_boot_one _idx name =
        try
          Log.Keeper.info "autoboot: loading meta for %s" name;
          match Keeper_runtime.load_or_materialize_boot_meta keeper_boot_ctx name with
          | Error e ->
            Log.Keeper.error "autoboot: failed to load meta for %s: %s" name e;
            false
          | Ok { meta = m; materialized } ->
            if Keeper_registry.is_running ~base_path:config.base_path m.name then (
              Log.Keeper.info
                "autoboot: %s already running%s"
                m.name
                (if materialized then " (materialized from TOML)" else "");
              true
            ) else begin
              let warmup =
                autoboot_proactive_warmup_sec ~base_warmup
                  ~stagger_window_sec:stagger_window ~keeper_name:name
              in
              Log.Keeper.info "autoboot: calling start_keepalive for %s (warmup=%ds)"
                name warmup;
              let ctx : _ Keeper_types.context = {
                config;
                agent_name = m.agent_name;
                sw;
                clock;
                proc_mgr = Some proc_mgr;
                net = state.net;
              } in
              Keeper_keepalive.start_keepalive ~proactive_warmup_sec:warmup ctx m;
              (* start_keepalive registers the keeper synchronously via
                 register_offline and then forks the keepalive fiber.  The
                 fiber flips the registry to running asynchronously on the
                 next Eio tick, so querying is_running here is a race that
                 keepers with a larger proactive-warmup idx lose
                 deterministically (verdict=165s / sojin=150s / sangsu=135s
                 produced the bulk of the false-positive "not in registry"
                 WARNs).  Check the synchronous is_registered predicate
                 instead — the running transition is observed later by the
                 retry loop.  See #7889. *)
              let registered =
                Keeper_registry.is_registered ~base_path:config.base_path m.name
              in
              if registered then
                Log.Keeper.info "autoboot: started keepalive for %s" m.name
              else
                Log.Keeper.warn
                  "autoboot: start_keepalive returned but %s not registered"
                  m.name;
              registered
            end
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.error "autoboot: exception for %s: %s" name
            (Printexc.to_string exn);
          false
      in
      (* Initial boot pass *)
      let booted = filteri_with_fair_yield (fun idx name -> try_boot_one idx name) names in
      let booted_count = List.length booted in
      let total = List.length names in
      Log.Keeper.info "autoboot: initial pass %d/%d keepers started" booted_count total;
      (* Retry loop for keepers that failed initial boot *)
      if booted_count < total then begin
        let max_retries = Keeper_config.keeper_bootstrap_retry_max () in
        let retry_interval_s = Float.of_int (Keeper_config.keeper_bootstrap_retry_interval_sec ()) in
        let rec retry_loop round =
          if round > max_retries then
            Log.Keeper.warn
              "autoboot: gave up after %d retries; %d/%d keepers remain unbooted"
              max_retries
              (total - List_util.count_if (fun name ->
                Keeper_registry.is_running ~base_path:config.base_path name) names)
              total
          else begin
            Eio.Time.sleep clock retry_interval_s;
            let unbooted = List.filter (fun name ->
              not (Keeper_registry.is_running ~base_path:config.base_path name)
            ) names in
            if unbooted = [] then
              Log.Keeper.info "autoboot: all %d keepers running after %d retry round(s)" total round
            else begin
              Log.Keeper.info "autoboot: retry round %d/%d — %d unbooted: [%s]"
                round max_retries (List.length unbooted) (String.concat ", " unbooted);
              iteri_with_fair_yield
                (fun idx name -> ignore (try_boot_one idx name))
                unbooted;
              retry_loop (round + 1)
            end
          end
        in
        retry_loop 1
      end;
      (* #10125: start the supervisor sweep here, after autoboot
         completes.  Without this call the sweep would only fire
         on the first [masc_keeper_msg] tool dispatch (the single
         caller of [start_existing_keepalives] in [tool_keeper.ml]
         — see #10125 timeline 2026-04-24, where 14 keepers ran
         under autoboot but the sweep never came up because no
         operator [masc_keeper_msg] arrived after the restart;
         four hours later the entire fleet was dead with no
         supervisor to recover them).

         [start_supervisor_sweep] is idempotent — its internal
         [supervisor_sweep_running] guard makes a second call a
         noop, so this stays correct if [masc_keeper_msg] later
         races into [start_existing_keepalives] anyway. *)
      (try Keeper_runtime.start_supervisor_sweep keeper_boot_ctx
       with Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            Log.Keeper.error
              "autoboot: supervisor sweep failed to start: %s"
              (Printexc.to_string exn))
    end);
  (* Phase 5: unified startup subsystem summary *)
  Log.info ~ctx:"startup" "subsystems: keeper loops started"

let start_background_maintenance ~sw ~clock ~env (state : Mcp_server.server_state) =
  (* Metrics flush fiber: drains write queue every 500ms, batches file appends.
     Replaces the old mutex + synchronous file I/O pattern. *)
  Eio.Fiber.fork ~sw (fun () ->
    try Metrics_store_eio.start_flush_fiber ~clock
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Server.error "metrics_flush fiber crashed: %s"
        (Printexc.to_string exn));
  Shutdown.register ~name:"metrics_flush" ~priority:30 Metrics_store_eio.flush_pending;
  (* Deterministic output budget enforcement: truncate oversized tool outputs
     with structured metadata before metrics/OTEL hooks see them. *)
  Tool_output_validation.install ();
  (* Tool metrics JSONL persistence: flush buffered records to disk periodically.
     The shared post-hook is the canonical write path for persisted tool
     metrics so keeper-internal calls are counted exactly once. *)
  Tool_dispatch.register_post_hook (fun result ->
    Tool_metrics.record result;
    Tool_metrics_persist.enqueue result;
    result);
  Tool_metrics_persist.start_flush_fiber ~sw ~clock
    ~base_path:state.room_config.base_path;
  (* Cascade trust JSONL snapshot fiber (Phase 0b observability).  Polls
     [Cascade_health_tracker.global] every minute and appends one JSON
     object per tick to base_path/cascade_trust/YYYY-MM/DD.jsonl.  Phase 1
     (in-memory trust_score) consumes these snapshots offline to calibrate
     reward / decay defaults instead of magic numbers. *)
  Cascade_trust_persist.start_snapshot_fiber ~sw ~clock
    ~base_path:state.room_config.base_path;
  (* #9876: Hebbian consolidation fiber. Prior to this, the graph was
     write-only — strengthen/weaken populated synapses but decay +
     pruning never ran (zero production callers of [consolidate]).
     last_consolidation=0.0 on live graphs confirmed the gap in
     production. *)
    (* System_internal tool usage log: durable JSONL for pruning evidence (#5120) *)
  Tool_usage_log.init
    ~base_path:state.room_config.base_path
    ~cluster_name:state.room_config.backend_config.Backend_types.cluster_name
    ();
  Tool_usage_log.install ();
  (* Keeper tool call I/O log: full input/output for dashboard inspector *)
  Keeper_tool_call_log.init
    ~base_path:state.room_config.base_path
    ~cluster_name:state.room_config.backend_config.Backend_types.cluster_name
    ();
  Otel_dispatch_hook.install ();
  Otel_spans.setup_exporter ~sw env;
  Shutdown.register ~name:"otel_exporter" ~priority:20 Otel_spans.shutdown;
  (* Board_listener removed: filesystem-first principle.
     JSONL path emits SSE directly via Board_dispatch.emit_board_sse_event.
     PG path also uses Board_dispatch, making the pg_notify relay redundant. *)
  Eio.Fiber.fork ~sw (fun () ->
      let last_prune = ref (Unix.gettimeofday ()) in
      let rec loop () =
        Eio.Time.sleep clock
          Env_config_runtime.InternalTimers.janitor_interval_sec;
        (try
          let stale_sids = Sse.cleanup_stale () in
          List.iter Server_routes_http_common.stop_sse_session stale_sids;
          if stale_sids <> [] then
            Log.Server.info "Reaped %d stale connections (active: %d)"
              (List.length stale_sids) (Sse.client_count ());
          let evicted_events = Sse.cleanup_expired_events () in
          if evicted_events > 0 then
            (* SSE replay-buffer eviction is periodic housekeeping; failed
               sends and stale connection reaping remain visible elsewhere. *)
            Log.Server.routine "Evicted %d expired SSE buffer events" evicted_events;
          let evicted = Cache_eio.evict_expired state.room_config in
          if evicted > 0 then
            Log.Server.info "Cache: evicted %d expired entries" evicted;
          let sse_guards_reaped = Server_mcp_transport_http_sse.reap_stale_guards () in
          let http_guards_reaped = Server_mcp_transport_http.reap_stale_guards () in
          let is_active sid =
            Server_mcp_transport_http_sse.is_active_sse_session sid
            || Server_mcp_transport_http.is_active_sse_session sid
          in
          let sessions_reaped =
            Server_mcp_transport_http_session.reap_stale_sessions
              ~is_active_session:is_active
          in
          if sse_guards_reaped + http_guards_reaped + sessions_reaped > 0 then
            Log.Server.info "reaped %d SSE guards + %d HTTP guards + %d stale sessions"
              sse_guards_reaped http_guards_reaped sessions_reaped;
          let ext_reaped = Sse.reap_dead_external_subscribers () in
          Transport_metrics.set_grpc_subscribers
            (Sse.external_subscriber_count_with_prefix "grpc-subscribe-");
          if ext_reaped > 0 then
            Log.Server.info "reaped %d dead external subscribers" ext_reaped;
          if Server_webrtc_transport.is_enabled () then begin
            let webrtc_expired = Server_webrtc_transport.cleanup_expired_offers () in
            if webrtc_expired > 0 then
              Log.Server.info "WebRTC: cleaned %d expired offers" webrtc_expired
          end;
          (* Rate-limit buckets: evict keys unused for
             [MASC_RATE_LIMIT_BUCKET_TTL_SEC] (default 5 minutes) *)
          let rl = Eio.Lazy.force Rate_limit.global in
          let rl_reaped =
            Rate_limit.cleanup rl
              ~older_than_seconds:
                Env_config_runtime.InternalTimers.rate_limit_bucket_ttl_sec
          in
          if rl_reaped > 0 then
            Log.Server.info "Reaped %d stale rate-limit buckets" rl_reaped;
          (* Agent registry: remove resolved-name cache for dead sessions *)
          let ar_reaped = Agent_registry_eio.cleanup_stale_sessions () in
          if ar_reaped > 0 then
            Log.Server.info "Reaped %d stale agent registry sessions" ar_reaped;
          (* Keeper sandbox: remove stale Docker containers when owner_pid is
             dead, container age exceeds MASC_KEEPER_SANDBOX_CLEANUP_STALE_AFTER_SEC
             (default 6h), or container is stopped. Internally throttled by
             MASC_KEEPER_SANDBOX_CLEANUP_INTERVAL_SEC (default 5min); janitor
             ticks faster but the helper short-circuits when called too soon. *)
          (match
             Keeper_sandbox_runtime.maybe_cleanup_stale_containers
               ~base_path:state.room_config.base_path
               ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Startup ()) ()
           with
           | None -> ()
           | Some result ->
               if result.removed > 0 || result.errors <> [] then begin
                 Log.Server.info
                   "Sandbox cleanup: scanned=%d removed=%d errors=%d"
                   result.scanned result.removed
                   (List.length result.errors);
                 List.iter
                   (fun err ->
                     Log.Server.warn "Sandbox cleanup error: %s" err)
                   result.errors
               end);
          (* Periodic JSONL prune: every 24h, clean dated JSONL files *)
          let now = Unix.gettimeofday () in
          if now -. !last_prune >= Masc_time_constants.day then begin
            last_prune := now;
            (try
               let days =
                 Safe_ops.get_env_int_logged "MASC_JSONL_RETENTION_DAYS" ~default:30
               in
               let masc = Coord.masc_dir state.room_config in
               let prune_dir dir =
                 if Sys.file_exists dir then
                   Dated_jsonl.prune (Dated_jsonl.create ~base_dir:dir ()) ~days
                 else 0
               in
               let total =
                 prune_dir (Filename.concat masc "audit")
                 + prune_dir (Filename.concat masc "telemetry")
                 + prune_dir (Filename.concat (Filename.concat masc "governance") "judgments")
                 + prune_dir (Filename.concat masc "messages")
                 + prune_dir (Filename.concat masc "events")
                 + prune_dir (Filename.concat masc "activity-events")
                 + prune_dir (Filename.concat masc "voice_sessions")
                 + prune_dir (Filename.concat masc "tool_calls")
               in
               if total > 0 then
                 Log.Server.info "periodic JSONL prune: deleted %d day-files (retention=%dd)"
                   total days
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               Log.Server.error "periodic JSONL prune failed: %s"
                 (Printexc.to_string exn))
          end
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Server.error "cleanup loop iteration failed: %s"
            (Printexc.to_string exn));
        loop ()
      in
      loop ());
      (* Periodic repository sync: fetch repositories with auto_sync enabled. *)
      Eio.Fiber.fork ~sw (fun () ->
        let repo_sync_interval_sec =
          Env_config_runtime.InternalTimers.repo_sync_interval_sec
        in
        let sync_once () =
          try
            let now = Int64.of_float (Eio.Time.now clock) in
            match Repo_sync.sync_all ~base_path:state.room_config.base_path ~now with
            | Ok repos ->
              if repos <> [] then
                Log.Server.info "repo_sync: synced %d repositories"
                  (List.length repos)
            | Error msg ->
              Log.Server.warn "repo_sync: sync_all failed: %s" msg
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            Log.Server.error "repo_sync: iteration failed: %s"
              (Printexc.to_string exn)
        in
        let rec sync_loop () =
          (try
             Eio.Time.sleep clock repo_sync_interval_sec
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             Log.Server.error "repo_sync: sleep failed: %s"
               (Printexc.to_string exn));
          sync_once ();
          sync_loop ()
        in
        sync_once ();
        sync_loop ());
  let resolved_base = state.room_config.base_path in
  let masc_dir = Coord.masc_root_dir state.room_config in
  (resolved_base, masc_dir)
