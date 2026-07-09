(** Server_bootstrap_loops — Keeper loops and background maintenance.

    Extracted from Server_runtime_bootstrap to isolate the large
    subsystem-spawning functions into a focused module. *)

let install_tooling ~governance_level (state : Mcp_server.server_state) =
  Governance_pipeline.install ~config:(Mcp_server.workspace_config state) ~governance_level ()
;;

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
;;

let autoboot_proactive_warmup_sec ~base_warmup ~stagger_window_sec ~keeper_name =
  let base_warmup = max 0 base_warmup in
  let stagger_window_sec = max 0 stagger_window_sec in
  if stagger_window_sec = 0
  then base_warmup
  else base_warmup + (stable_keeper_name_hash keeper_name mod (stagger_window_sec + 1))
;;

let keeper_agent_status_of_phase = function
  | Keeper_state_machine.Running -> Masc_domain.Active
  | Keeper_state_machine.Paused -> Masc_domain.Listening
  | Keeper_state_machine.Failing
  | Keeper_state_machine.Overflowed
  | Keeper_state_machine.Compacting
  | Keeper_state_machine.HandingOff
  | Keeper_state_machine.Draining
  | Keeper_state_machine.Restarting -> Masc_domain.Busy
  | Keeper_state_machine.Offline
  | Keeper_state_machine.Stopped
  | Keeper_state_machine.Crashed
  | Keeper_state_machine.Dead
  | Keeper_state_machine.Zombie -> Masc_domain.Inactive
;;

let keeper_registry_agent ~now (entry : Keeper_registry.registry_entry) : Masc_domain.agent =
  let meta = entry.meta in
  let agent_name =
    match String.trim meta.agent_name with
    | "" -> Keeper_identity.keeper_agent_name entry.name
    | name -> name
  in
  let agent_meta : Masc_domain.agent_meta =
    { session_id = "keeper-registry:" ^ entry.name
    ; agent_type = "keeper"
    ; pid = None
    ; hostname = None
    ; tty = None
    ; parent_task = None
    ; keeper_name = Some entry.name
    ; keeper_id = None
    }
  in
  { Masc_domain.id = None
  ; name = agent_name
  ; agent_type = "keeper"
  ; status = keeper_agent_status_of_phase entry.phase
  ; capabilities = []
  ; current_task = None
  ; session_bound_at = now
  ; last_seen = now
  ; meta = Some agent_meta
  }
;;

let keeper_registry_runtime_agents (config : Workspace_utils_backend_setup.config) =
  let now = Masc_domain.now_iso () in
  Keeper_registry.all ~base_path:config.base_path ()
  |> List.map (keeper_registry_agent ~now)
;;

let board_sse_event_params event =
  match event with
  | Board_dispatch.Post_created { post_id; author; title; content; post_kind; hearth } ->
    let preview =
      if String.length content > 200 then String.sub content 0 200 else content
    in
    let base =
      [ "type", `String "post_created"
      ; "event_type", `String "post.created"
      ; "post_id", `String post_id
      ; "author", `String author
      ; "author_identity", Server_utils.board_actor_identity_json author
      ; "title", `String title
      ; "content", `String preview
      ; "post_kind", `String (Board.post_kind_to_string post_kind)
      ]
    in
    `Assoc
      (match hearth with
       | Some h -> ("hearth", `String h) :: base
       | None -> base)
  | Board_dispatch.Comment_added { post_id; comment_id; author } ->
    `Assoc
      [ "type", `String "comment_added"
      ; "event_type", `String "comment.created"
      ; "post_id", `String post_id
      ; "comment_id", `String comment_id
      ; "author", `String author
      ; "author_identity", Server_utils.board_actor_identity_json author
      ]
  | Board_dispatch.Post_voted { post_id; voter; direction } ->
    let dir = Board_votes.vote_direction_to_string direction in
    `Assoc
      [ "type", `String "post_voted"
      ; "event_type", `String "vote.changed"
      ; "target_type", `String "post"
      ; "post_id", `String post_id
      ; "voter", `String voter
      ; "voter_identity", Server_utils.board_actor_identity_json voter
      ; "direction", `String dir
      ]
  | Board_dispatch.Comment_voted { comment_id; voter; direction } ->
    let dir = Board_votes.vote_direction_to_string direction in
    `Assoc
      [ "type", `String "comment_voted"
      ; "event_type", `String "vote.changed"
      ; "target_type", `String "comment"
      ; "comment_id", `String comment_id
      ; "voter", `String voter
      ; "voter_identity", Server_utils.board_actor_identity_json voter
      ; "direction", `String dir
      ]
  | Board_dispatch.Reaction_changed { target_type; target_id; user_id; emoji; reacted } ->
    `Assoc
      [ "type", `String "reaction_changed"
      ; "event_type", `String "reaction.changed"
      ; "target_type", `String (Board.reaction_target_type_to_string target_type)
      ; "target_id", `String target_id
      ; "user_id", `String user_id
      ; "user_identity", Server_utils.board_actor_identity_json user_id
      ; "emoji", `String emoji
      ; "reacted", `Bool reacted
      ]
;;

type queued_chat_projection = {
  payload_channel : string;
  payload_channel_user_id : string;
  payload_channel_user_name : string;
  payload_channel_workspace_id : string;
  agent_name : string;
}

let discord_channel_label = "discord"

let queued_chat_projection (queued_message : Keeper_chat_queue.queued_message) =
  match queued_message.source with
  | Keeper_chat_queue.Dashboard ->
    {
      payload_channel = "";
      payload_channel_user_id = "";
      payload_channel_user_name = "";
      payload_channel_workspace_id = "";
      agent_name = "dashboard";
    }
  | Keeper_chat_queue.Discord { channel_id; user_id } ->
    {
      payload_channel = discord_channel_label;
      payload_channel_user_id = user_id;
      payload_channel_user_name = "";
      payload_channel_workspace_id = channel_id;
      agent_name =
        Gate_keeper_backend.agent_name_for_channel_actor
          ~channel:discord_channel_label
          ~channel_workspace_id:channel_id
          ~channel_user_id:user_id;
    }
  | Keeper_chat_queue.Slack { channel; user_id } ->
    {
      payload_channel = channel;
      payload_channel_user_id = user_id;
      payload_channel_user_name = "";
      payload_channel_workspace_id = "";
      agent_name =
        Gate_keeper_backend.agent_name_for_channel_actor
          ~channel
          ~channel_workspace_id:""
          ~channel_user_id:user_id;
    }

let trimmed_env_opt name =
  match Sys.getenv_opt name with
  | None -> None
  | Some raw ->
    let trimmed = String.trim raw in
    if String.equal trimmed "" then None else Some trimmed

let discord_bot_token_opt () = trimmed_env_opt "DISCORD_BOT_TOKEN"

let broadcast_mention_wakeup_action = function
  | Some target when String.trim target <> "" -> `Wake_keeper target
  | Some _ | None -> `Suppress_no_target

module For_testing = struct
  type queued_chat_projection = {
    payload_channel : string;
    payload_channel_user_id : string;
    payload_channel_user_name : string;
    payload_channel_workspace_id : string;
    agent_name : string;
  }

  let autoboot_proactive_warmup_sec = autoboot_proactive_warmup_sec
  let board_sse_event_params = board_sse_event_params
  let broadcast_mention_wakeup_action = broadcast_mention_wakeup_action

  let queued_chat_projection queued_message : queued_chat_projection =
    let projection = queued_chat_projection queued_message in
    {
      payload_channel = projection.payload_channel;
      payload_channel_user_id = projection.payload_channel_user_id;
      payload_channel_user_name = projection.payload_channel_user_name;
      payload_channel_workspace_id = projection.payload_channel_workspace_id;
      agent_name = projection.agent_name;
    }
end

let fork_logged_fiber = Server_bootstrap_loops_fiber.fork_logged_fiber
let log_server_fiber_crash =
  Server_bootstrap_loops_fiber.log_server_fiber_crash
let log_dashboard_fiber_crash =
  Server_bootstrap_loops_fiber.log_dashboard_fiber_crash
let filteri_with_fair_yield =
  Server_bootstrap_loops_fiber.filteri_with_fair_yield
let iteri_with_fair_yield = Server_bootstrap_loops_fiber.iteri_with_fair_yield

let start_keeper_loops
      ~sw
      ~clock
      ~net
      ~domain_mgr
      ~proc_mgr
      (state : Mcp_server.server_state)
  =
  Progress.set_sse_callback Sse.broadcast;
  (* Wire stop_keeper hook so zombie GC can terminate keeper fibers *)
  Atomic.set Workspace_hooks.stop_keeper_fn Keeper_keepalive.stop_keepalive;
  Atomic.set Workspace_hooks.runtime_agents_fn keeper_registry_runtime_agents;
  let base_path = (Mcp_server.workspace_config state).base_path in
  let recovered_keeper_msg_requests =
    Keeper_msg_async.recover_lost_disk_records ~base_path
  in
  if recovered_keeper_msg_requests > 0
  then
    Log.Keeper.warn
      "keeper_msg_async: recovered %d disk-only non-terminal request record(s) as lost"
      recovered_keeper_msg_requests;
  (* Shared Agent_sdk Event_bus used as the runtime transport between subsystems.
     Configuration is sourced from [Masc_event_bus_policy.oas_runtime] so the
     buffer-size/policy choice is auditable in source rather than implicit in
     OAS defaults, and the chosen capacity is published through OTel. *)
  let event_bus =
    Masc_event_bus_policy.create_bus Masc_event_bus_policy.oas_runtime
  in
  (* Eio fiber isolation: each subsystem runs in its own fiber.
     If one crashes, others keep running — Eio's structured concurrency.
     Subsystem_health tracks liveness at module level (no init timing dependency). *)
  let fork_subsystem name f =
    Subsystem_health.register name;
    fork_logged_fiber
      ~sw
      ~on_error:(fun exn ->
        Subsystem_health.mark_dead name;
        Log.Server.error "subsystem %s crashed: %s" name (Printexc.to_string exn))
      f
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
      | Some v ->
        (match float_of_string_opt (String.trim v) with
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
        let tag = if elapsed >= hung_threshold_sec then "HUNG" else "running" in
        Printf.sprintf "%s (%s %.1fs)" task tag elapsed)
      |> String.concat ", "
    in
    let rec loop last_log_at =
      let pending = Server_startup_state.pending_lazy_tasks () in
      if pending = []
      then ()
      else (
        let now = Eio.Time.now clock in
        List.iter
          (fun task ->
             if not (Hashtbl.mem started_at task) then Hashtbl.add started_at task now)
          pending;
        Hashtbl.filter_map_inplace
          (fun task t -> if List.mem task pending then Some t else None)
          started_at;
        let stuck =
          List.filter
            (fun task ->
               match Hashtbl.find_opt started_at task with
               | Some seen_at -> now -. seen_at >= boot_guard_sec
               | None -> false)
            pending
        in
        if stuck <> []
        then (
          List.iter
            (fun task ->
               let elapsed =
                 match Hashtbl.find_opt started_at task with
                 | Some seen_at -> now -. seen_at
                 | None -> 0.0
               in
               Log.Keeper.error
                 "autoboot: lazy task %s exceeded boot guard %.0fs (elapsed %.1fs) — \
                  failing it so keeper boot can proceed"
                 task
                 boot_guard_sec
                 elapsed;
               Otel_metric_store.inc_counter
                 "masc_lazy_task_boot_guard_fired_total"
                 ~labels:[ "task", task ]
                 ();
               Server_startup_state.fail_lazy_task
                 ~task
                 ~error:(Printf.sprintf "lazy_task_boot_guard:%.0fs" boot_guard_sec))
            stuck;
          loop last_log_at)
        else (
          let last_log_at =
            if now -. last_log_at >= 5.0
            then (
              let max_elapsed =
                List.fold_left
                  (fun m task ->
                     match Hashtbl.find_opt started_at task with
                     | Some s -> Float.max m (now -. s)
                     | None -> m)
                  0.0
                  pending
              in
              let log_fn =
                if max_elapsed >= hung_threshold_sec
                then Log.Keeper.warn
                else Log.Keeper.info
              in
              log_fn
                "autoboot: waiting for lazy startup tasks to finish before keeper boot \
                 [%s]"
                (format_pending now pending);
              now)
            else last_log_at
          in
          Eio.Time.sleep
            clock
            Env_config_keeper.KeeperBootstrap.lazy_startup_poll_interval_sec;
          loop last_log_at))
    in
    loop (Eio.Time.now clock)
  in
  (* Create and install the MASC-owned Event_bus alongside OAS's.
     MASC domain events (masc.broadcast, masc.heartbeat, masc.keeper.*,
     masc.harness.*, ...) publish here per OAS event_bus.mli:103-107
     boundary. Dashboard SSE consumers see both channels as one stream
     — the relay translates masc.* →
     masc:* on the wire for backward compatibility. *)
  let masc_event_bus =
    Masc_event_bus_policy.create_bus Masc_event_bus_policy.masc_domain
  in
  Masc_event_bus.set masc_event_bus;
  (* Event_bus → SSE bridge: relay both OAS and MASC buses to dashboard *)
  Keeper_event_bridge.start ~sw ~clock ~config:(Mcp_server.workspace_config state) ~bus:event_bus;
  Keeper_event_bridge.start ~sw ~clock ~config:(Mcp_server.workspace_config state) ~bus:masc_event_bus;
  (* Compaction audit: subscribe to ContextCompactStarted/ContextCompacted and
     persist paired rows to [base_path/data/harness-compact/YYYY-MM/DD.jsonl]
     with rolling 14-day retention (override via
     MASC_COMPACTION_AUDIT_RETENTION_DAYS). Independent from the SSE bridge —
     each subscriber gets its own bounded stream. *)
  Keeper_compact_audit.spawn_subscriber
    ~sw
    ~clock
    ~base_path:(Env_config.base_path ())
    ~retention_days:14
    event_bus;
  (* Telemetry feedback loop: observe OAS per-turn signals without
     deserializing provider/model-bearing payloads. *)
  Keeper_telemetry_consumer.spawn_subscriber
    ~sw ~clock ~base_path:(Env_config.base_path ()) ~bus:event_bus;
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
     even when no external telemetry backend is attached.

     [MASC_OAS_BUS_WARN_DEPTH] lets operators raise the threshold without
     a rebuild — fleet-wide keeper load legitimately pushes depth past
     the 200 default at peak (issue #8517). Invalid values fall back to
     the compile-time default. *)
  let warn_threshold =
    match Sys.getenv_opt "MASC_OAS_BUS_WARN_DEPTH" with
    | Some v ->
      (match int_of_string_opt (String.trim v) with
       | Some n when n > 0 -> n
       | _ -> 200)
    | None -> 200
  in
  Agent_sdk_metrics_bridge.start_sampler ~sw ~clock ~warn_threshold ();
  fork_logged_fiber
    ~sw
    ~on_error:(log_dashboard_fiber_crash "keeper lifecycle listener")
    (fun () ->
    let rec loop () =
      (try
         let events = Agent_sdk_metrics_bridge.drain keeper_lifecycle_sub in
         List.iter
           (fun (evt : Agent_sdk.Event_bus.event) ->
              match evt.payload with
              | Agent_sdk.Event_bus.Custom ("masc.keeper.lifecycle", payload) ->
                (match
                   ( Safe_ops.json_string_opt "event" payload
                   , Safe_ops.json_string_opt "keeper_name" payload )
                 with
                 | Some event, Some keeper_name ->
                   Server_dashboard_http.patch_keeper_dependent_caches ~keeper_name ~event
                 | None, _ | Some _, None ->
                   (* P3 cleanup: previously malformed lifecycle events
                       (missing `event` or `keeper_name` field) were
                       silently dropped.  A systematic encoding bug
                       could lose every cache invalidation indefinitely
                       with no signal.  Bumping a Otel_metric_store counter
                       lets `rate(...)` alerts catch the regression
                       even though the dashboard cache continues to
                       degrade gracefully (just stale, not broken). *)
                   Otel_metric_store.inc_counter "masc_keeper_lifecycle_malformed_total" ())
              | _ -> Log.Dashboard.debug "ignored non-lifecycle event")
           events;
         if events <> []
         then (
           Log.Dashboard.info
             "patched keeper-dependent dashboard caches (%d lifecycle event(s))"
             (List.length events);
           Server_dashboard_http.broadcast_namespace_truth_snapshot state)
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Dashboard.error
           "keeper lifecycle listener iteration failed: %s"
           (Printexc.to_string exn));
      Eio.Time.sleep
        clock
        Env_config_keeper.KeeperBootstrap.keeper_listener_retry_interval_sec;
      loop ()
    in
    loop ());
  (* Inject Event_bus into keeper keepalive runtime for telemetry publishing *)
  Keeper_keepalive.set_bus event_bus;
  Board_dispatch.set_board_signal_hook (fun signal ->
    Keeper_keepalive.wakeup_relevant_keeper_for_board_signal
      ~config:(Mcp_server.workspace_config state)
      signal);
  (* Wake a keeper when one of its pending HITL approvals resolves/expires.
     Registered here (composition root) rather than in Keeper_approval_queue to
     break the Keeper_approval_queue -> Keeper_keepalive_signal ->
     Keeper_world_observation -> Keeper_approval_queue dependency cycle. Mirrors
     the Fusion_completed/Bg_completed async-completion wakes. *)
  Keeper_approval_queue.set_approval_resolution_wake_hook
    (fun
      ~base_path
      ~keeper_name
      ~approval_id
      ~decision
      ?(channel : Keeper_continuation_channel.t option) ->
       let resolution =
         Keeper_event_queue.
           {
             approval_id;
             decision;
             channel =
               Option.value
                 channel
                 ~default:
                   (Keeper_continuation_channel.unrouted
                      "legacy: no approval continuation channel");
           }
       in
       let decision_label = Keeper_event_queue.hitl_resolution_decision_to_string decision in
       let stimulus : Keeper_event_queue.stimulus =
         { Keeper_event_queue.post_id = Keeper_event_queue.hitl_resolution_post_id resolution
         ; urgency = Keeper_event_queue.Immediate
         ; arrived_at = Time_compat.now ()
         ; payload = Keeper_event_queue.Hitl_resolved resolution
         }
       in
       Log.Keeper.info
         "hitl resolution wake: keeper=%s approval=%s decision=%s"
         keeper_name
         approval_id
         decision_label;
       Keeper_keepalive_signal.wakeup_keeper ~base_path ~stimulus keeper_name);
  Board_dispatch.set_board_sse_hook (fun event ->
    let params = board_sse_event_params event in
    Sse.broadcast
      (`Assoc
          [ "jsonrpc", `String "2.0"
          ; "method", `String "notifications/board"
          ; "params", params
          ]);
    (* Emit activity event so Discord/external connectors can detect board posts *)
    let activity_kind, activity_actor, activity_subject, activity_payload =
      match event with
      | Board_dispatch.Post_created { post_id; author; title; content; post_kind; hearth }
        ->
        let base =
          [ "post_id", `String post_id
          ; "title", `String title
          ; "content", `String content
          ; "author", `String author
          ; "author_identity", Server_utils.board_actor_identity_json author
          ; "post_kind", `String (Board.post_kind_to_string post_kind)
          ]
        in
        let payload_fields =
          match hearth with
          | Some h -> ("hearth", `String h) :: base
          | None -> base
        in
        ( Event_kind.Board.to_string Event_kind.Board.Posted
        , Server_utils.board_actor_entity author
        , Some (Activity_graph.entity ~kind:"post" post_id)
        , `Assoc payload_fields )
      | Board_dispatch.Comment_added { post_id; comment_id; author } ->
        ( Event_kind.Board.to_string Event_kind.Board.Commented
        , Server_utils.board_actor_entity author
        , Some (Activity_graph.entity ~kind:"post" post_id)
        , `Assoc
            [ "post_id", `String post_id
            ; "comment_id", `String comment_id
            ; "author", `String author
            ; "author_identity", Server_utils.board_actor_identity_json author
            ] )
      | Board_dispatch.Post_voted { post_id; voter; direction } ->
        let dir = Board_votes.vote_direction_to_string direction in
        ( Event_kind.Board.to_string Event_kind.Board.Voted
        , Server_utils.board_actor_entity voter
        , Some (Activity_graph.entity ~kind:"post" post_id)
        , `Assoc
            [ "post_id", `String post_id
            ; "voter", `String voter
            ; "voter_identity", Server_utils.board_actor_identity_json voter
            ; "direction", `String dir
            ] )
      | Board_dispatch.Comment_voted { comment_id; voter; direction } ->
        let dir = Board_votes.vote_direction_to_string direction in
        ( Event_kind.Board.to_string Event_kind.Board.Voted
        , Server_utils.board_actor_entity voter
        , Some (Activity_graph.entity ~kind:"comment" comment_id)
        , `Assoc
            [ "comment_id", `String comment_id
            ; "voter", `String voter
            ; "voter_identity", Server_utils.board_actor_identity_json voter
            ; "direction", `String dir
            ] )
      | Board_dispatch.Reaction_changed
          { target_type; target_id; user_id; emoji; reacted } ->
        ( Event_kind.Board.to_string Event_kind.Board.Voted
        , Server_utils.board_actor_entity user_id
        , Some
            (Activity_graph.entity
               ~kind:(Board.reaction_target_type_to_string target_type)
               target_id)
        , `Assoc
            [ "target_type", `String (Board.reaction_target_type_to_string target_type)
            ; "target_id", `String target_id
            ; "user_id", `String user_id
            ; "user_identity", Server_utils.board_actor_identity_json user_id
            ; "emoji", `String emoji
            ; "reacted", `Bool reacted
            ] )
    in
    (* P2 silent-failure fix: Activity_graph.emit failures (Discord
       webhook, audit trail writes, etc.) were previously ignored
       entirely.  An operator seeing board activity on the dashboard
       had no signal that the external systems failed to receive the
       event.  Catch + warn surfaces the failure in operator logs
       without aborting the SSE broadcast that already succeeded. *)
    try
      ignore
        (Activity_graph.emit
           (Mcp_server.workspace_config state)
           ~actor:activity_actor
           ?subject:activity_subject
           ~kind:activity_kind
           ~payload:activity_payload
           ~tags:[ "board"; activity_kind ]
           ())
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Misc.warn
        "board: Activity_graph.emit kind=%s failed: %s"
        activity_kind
        (Printexc.to_string exn));
  (* Wire broadcast -> keeper wakeup. Explicit mentions wake the target
     keeper immediately; unmentioned broadcasts remain passive SSE/message
     fanout so one broad announcement cannot create a fleet-wide turn storm.
     Board signals have their own capped keeper wake path above. *)
  let broadcast_mention_handler =
    fun mention ->
    match broadcast_mention_wakeup_action mention with
    | `Wake_keeper target ->
      Keeper_keepalive.wakeup_keeper ~base_path:(Mcp_server.workspace_config state).base_path target;
      Log.Keeper.info "broadcast mention → wakeup keeper %s" target
    | `Suppress_no_target ->
      Log.Keeper.info
        "broadcast without mention -> keeper wakeup suppressed (passive fanout)"
  in
  Workspace_broadcast.on_broadcast_mention := broadcast_mention_handler;
  (* Orchestrator needs synchronous registration for shutdown hook *)
  (try
     let cancel_orchestrator =
       Orchestrator.start ~sw ~proc_mgr ~clock ~domain_mgr (Mcp_server.workspace_config state)
     in
     Shutdown_hooks.register_cancel_orchestrator cancel_orchestrator
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Server.error
       "subsystem orchestrator failed to start: %s"
       (Printexc.to_string exn));
  (* RFC-0036 Phase A.3: register default keeper-lifecycle cleanup hooks
     once during bootstrap. The call is Atomic-guarded and idempotent so
     re-bootstrapping (e.g. tests) is safe. *)
  Keeper_subprocess_registry.register_default_cleanup_hook ();
  (* Build read-only tool surface shared by both judges. *)
  let judge_tool_names =
    [ "masc_status"
    ; Tool_name.Task_name.to_string Tool_name.Task_name.Tasks
    ; Tool_name.Board_name.to_string Tool_name.Board_name.Board_list
    ]
  in
  let judge_masc_tools =
    match Keeper_tool_surfaces.local_worker_tool_schemas ~names:judge_tool_names () with
    | Ok schemas -> schemas
    | Error e ->
      Log.Server.warn "judge tool schema resolution failed: %s" e;
      []
  in
  let make_judge_dispatch ~actor ~(name : string) ~(args : Yojson.Safe.t) : Tool_result.result =
    let start_time = Time_compat.now () in
    let config = (Mcp_server.workspace_config state) in
    let agent_name = actor in
    let ctx_workspace : Tool_workspace.context = { config; agent_name } in
    let ctx_task : Task.Tool.context = { config; agent_name; sw = Some sw } in
    (* ctx_agent removed with the masc_agents judge dispatch case (2026-06-09). *)
    match name with
    | "masc_status" ->
      (match Tool_workspace.dispatch ctx_workspace ~name ~args with
       | Some result -> result
       | None ->
         (* RFC-0189: [Tool_*.dispatch] returning [None] when the
            name is hard-coded here is a server-side invariant
            violation (registry says the name routes here).
            [Runtime_failure] — not caller-actionable. *)
         Tool_result.error
           ~failure_class:(Some Tool_result.Runtime_failure)
           ~tool_name:name ~start_time "masc_status: dispatch failed")
    | "masc_tasks" ->
      (match Task.Tool.dispatch ctx_task ~name ~args with
       | Some result -> result
       | None ->
         Tool_result.error
           ~failure_class:(Some Tool_result.Runtime_failure)
           ~tool_name:name ~start_time "masc_tasks: dispatch failed")
    | "masc_board_list" ->
      Board_tool.handle_tool name args
    | _ ->
      (* RFC-0189: judge dispatch caller (governance / operator
         judge runner) requested a tool outside the allow-list.
         Caller-misuse = [Workflow_rejection]. *)
      Tool_result.error
        ~failure_class:(Some Tool_result.Workflow_rejection)
        ~tool_name:name
        ~start_time
        (Printf.sprintf "judge: tool '%s' not allowed" name)
  in
  (* governance_judge subsystem removed (2026-06-09): its only factual input
     was [Workspace.get_agents_status], which read the disk-backed
     [.masc/agents/] registry whose producer ([Workspace_eio.register_agent])
     had zero call sites. items/activity were already hardcoded []. So the
     judge ran ~100 empty LLM cycles/day producing 0 judgments for ~12 days.
     Removing the daemon rather than leaving a permanently-empty input. *)
  let operator_judge_dispatch = make_judge_dispatch ~actor:"operator-judge" in
  fork_subsystem "operator_judge" (fun () ->
    let operator_judge_ctx : _ Operator_control.context =
      { config = (Mcp_server.workspace_config state)
      ; agent_name = "operator-judge"
      ; sw
      ; clock
      ; proc_mgr = Some proc_mgr
      ; net = state.net
      ; mcp_session_id = None
      }
    in
    Dashboard_operator_judge.start
      ~sw
      ~clock
      ~net
      ~config:(Mcp_server.workspace_config state)
      ~masc_tools:judge_masc_tools
      ~dispatch:operator_judge_dispatch
      ~build_facts:(fun () ->
        Operator_control.snapshot_json
          ~actor:"operator-judge"
          ~view:"summary"
          ~include_messages:false
          ~include_keepers:true
          operator_judge_ctx)
      ());
  fork_subsystem "interaction_judge" (fun () ->
    let interaction_judge_ctx : _ Operator_control.context =
      { config = (Mcp_server.workspace_config state)
      ; agent_name = "interaction-judge"
      ; sw
      ; clock
      ; proc_mgr = Some proc_mgr
      ; net = state.net
      ; mcp_session_id = None
      }
    in
    Dashboard_interaction_judge.start
      ~sw
      ~clock
      ~base_path:(Mcp_server.workspace_config state).workspace_path
      ~build_facts:(fun () ->
        Operator_control.snapshot_json
          ~actor:"interaction-judge"
          ~view:"summary"
          ~include_messages:false
          ~include_keepers:true
          interaction_judge_ctx));
  fork_subsystem "session_cleanup" (fun () ->
    Session.start_mcp_session_cleanup_loop ~sw ~clock ());
  (* No verification_timeout fork: RFC-0220 §11 PR-3 deleted the sweep —
     the wall-clock deadline rescue was removed in §5 and the fork had been
     spinning on a no-op since PR-1. *)
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
     [interval_seconds] remains an ops knob for cadence tuning. *)
  fork_subsystem "approval_janitor" (fun () ->
    if not (Env_config_runtime.Approval_janitor.enabled ())
    then
      Log.Server.info "approval_janitor: disabled via MASC_APPROVAL_JANITOR_ENABLED=false"
    else (
      let interval = Env_config_runtime.Approval_janitor.interval_seconds in
      (* 30 minutes — long enough that humans actually have time to
         respond on dashboard / Slack / etc., short enough that the
         keeper isn't trapped on the death-spiral kill loop after the
         operator forgets a request.  Code constant: changes need code
         review (policy), not a runtime knob. *)
      let max_wait_s = 1800.0 in
      let rec loop () =
        Eio.Time.sleep clock interval;
        (try Keeper_approval_queue.expire_stale ~max_wait_s with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Server.warn "approval_janitor: sweep failed: %s" (Printexc.to_string exn));
        loop ()
      in
      loop ()));
  (* Auto-boot keepers from keeper meta and start keepalive loops.
     Retries unbooted keepers up to [max_retries] times so transient
     failures (model resolution, discovery timing) don't permanently
     block keeper startup.  See #5717. *)
  fork_subsystem "keeper_autoboot" (fun () ->
    if not Env_config.KeeperBootstrap.enabled
    then Log.Keeper.info "autoboot: disabled via MASC_KEEPER_BOOTSTRAP_ENABLED=false"
    else (
      wait_for_lazy_startup ();
      Log.Keeper.info "autoboot: lazy startup complete; keeper bootstrap will start last";
      (* Brief delay so other subsystems (SSE, board, orchestrator) settle first. *)
      Eio.Time.sleep clock Env_config_keeper.KeeperBootstrap.post_startup_settle_sec;
      let config = (Mcp_server.workspace_config state) in
      let masc_root = Workspace.masc_root_dir config in
      let keeper_dir = Keeper_fs.keeper_dir config in
      let all_names = Keeper_meta_store.keeper_names config in
      let all_count = List.length all_names in
      Log.Keeper.info
        "autoboot: base_path=%s masc_root=%s keeper_dir=%s keeper_json_count=%d"
        config.base_path
        masc_root
        keeper_dir
        all_count;
      let names = Keeper_runtime.bootable_keeper_names config in
      let exclusions = Keeper_runtime.autoboot_excluded_keeper_reasons config in
      let keeper_boot_ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = "keeper-autoboot"
        ; sw
        ; clock
        ; proc_mgr = Some proc_mgr
        ; net = state.net
        }
      in
      Log.Keeper.info "autoboot: %d keeper(s) to boot" (List.length names);
      Log.Keeper.info "autoboot: keeper set [%s]" (String.concat ", " names);
      if exclusions <> []
      then (
        let rendered =
          exclusions
          |> List.map (fun Keeper_runtime.{ keeper_name; reason } ->
            Printf.sprintf
              "%s=%s"
              keeper_name
              (Keeper_runtime.autoboot_exclusion_reason_to_string reason))
          |> String.concat ", "
        in
        Log.Keeper.info
          "autoboot: excluded %d configured keeper(s): [%s]"
          (List.length exclusions)
          rendered);
      let base_warmup = Keeper_config.keeper_bootstrap_proactive_warmup_sec () in
      let stagger_window = Keeper_config.keeper_bootstrap_stagger_step_sec () in
      (* Attempt to boot a single keeper. Returns true if started. *)
      let try_boot_one ?(log_prefix = "autoboot") _idx name =
        try
          Log.Keeper.info "%s: loading meta for %s" log_prefix name;
          match Keeper_runtime.load_or_materialize_boot_meta keeper_boot_ctx name with
          | Error e ->
            Log.Keeper.error "%s: failed to load meta for %s: %s" log_prefix name e;
            false
          | Ok { meta = m; materialized } ->
            if Keeper_registry.is_running ~base_path:config.base_path m.name
            then (
              Log.Keeper.info
                "%s: %s already running%s"
                log_prefix
                m.name
                (if materialized then " (materialized from TOML)" else "");
              true)
            else (
              let warmup =
                autoboot_proactive_warmup_sec
                  ~base_warmup
                  ~stagger_window_sec:stagger_window
                  ~keeper_name:name
              in
              Log.Keeper.info
                "%s: calling start_keepalive for %s (warmup=%ds)"
                log_prefix
                name
                warmup;
              let ctx : _ Keeper_types_profile.context =
                { config
                ; agent_name = m.agent_name
                ; sw
                ; clock
                ; proc_mgr = Some proc_mgr
                ; net = state.net
                }
              in
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
              if registered
              then Log.Keeper.info "%s: started keepalive for %s" log_prefix m.name
              else
                Log.Keeper.warn
                  "%s: start_keepalive returned but %s not registered"
                  log_prefix
                  m.name;
              registered)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.error
            "%s: exception for %s: %s"
            log_prefix
            name
            (Printexc.to_string exn);
          false
      in
      (* Initial boot pass *)
      let booted =
        filteri_with_fair_yield (fun idx name -> try_boot_one idx name) names
      in
      let booted_count = List.length booted in
      let total = List.length names in
      Log.Keeper.info "autoboot: initial pass %d/%d keepers started" booted_count total;
      (* Retry loop for keepers that failed initial boot *)
      if booted_count < total
      then (
        let max_retries = Keeper_config.keeper_bootstrap_retry_max () in
        let retry_interval_s =
          Float.of_int (Keeper_config.keeper_bootstrap_retry_interval_sec ())
        in
        let rec retry_loop round =
          if round > max_retries
          then
            Log.Keeper.warn
              "autoboot: gave up after %d retries; %d/%d keepers remain unbooted"
              max_retries
              (total
               - List_util.count_if
                   (fun name ->
                      Keeper_registry.is_running ~base_path:config.base_path name)
                   names)
              total
          else (
            Eio.Time.sleep clock retry_interval_s;
            let unbooted =
              List.filter
                (fun name ->
                   not (Keeper_registry.is_running ~base_path:config.base_path name))
                names
            in
            if unbooted = []
            then
              Log.Keeper.info
                "autoboot: all %d keepers running after %d retry round(s)"
                total
                round
            else (
              Log.Keeper.info
                "autoboot: retry round %d/%d — %d unbooted: [%s]"
                round
                max_retries
                (List.length unbooted)
                (String.concat ", " unbooted);
              iteri_with_fair_yield
                (fun idx name -> ignore (try_boot_one idx name))
                unbooted;
              retry_loop (round + 1)))
        in
        retry_loop 1);
      (* #10125: start the supervisor sweep here, after autoboot
         completes.  Without this call the sweep would only fire
         on the first [masc_keeper_msg] tool dispatch (the single
         caller of [start_existing_keepalives] in [keeper_tool_surface.ml]
         — see #10125 timeline 2026-04-24, where 14 keepers ran
         under autoboot but the sweep never came up because no
         operator [masc_keeper_msg] arrived after the restart;
         four hours later the entire fleet was dead with no
         supervisor to recover them).

         [start_supervisor_sweep] is idempotent — its internal
         [supervisor_sweep_running] guard makes a second call a
         noop, so this stays correct if [masc_keeper_msg] later
         races into [start_existing_keepalives] anyway. *)
      (try Keeper_runtime.start_supervisor_sweep keeper_boot_ctx with
       | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Keeper.error
          "autoboot: supervisor sweep failed to start: %s"
          (Printexc.to_string exn)));
      (* Start queue consumer fiber for async queue drain.
         handle_turn wires process_single_turn for actual turn execution. *)
      (try
         let base_path = (Mcp_server.workspace_config state).base_path in
         Keeper_chat_queue.configure_persistence ~base_path;
         Keeper_chat_consumer.start ~sw ~clock
           ~base_path
           ~handle_turn:(fun ~sw ~keeper_name ~queued_message ->
             let open Server_routes_http_keeper_stream in
             let now = Time_compat.now () in
             let run_id =
               Printf.sprintf "keeper-consumer-run-%d"
                 (int_of_float (now *. 1000.0))
             in
             let message_id =
               Printf.sprintf "keeper-consumer-msg-%d"
                 (int_of_float ((now +. 0.001) *. 1000.0))
             in
             let projection = queued_chat_projection queued_message in
             let payload =
               {
                 name = keeper_name;
                 message = queued_message.content;
                 timeout_sec = None;
                 turn_instructions = None;
                 surface_context = None;
                 channel = projection.payload_channel;
                 channel_user_id = projection.payload_channel_user_id;
                 channel_user_name = projection.payload_channel_user_name;
                 channel_workspace_id = projection.payload_channel_workspace_id;
                 user_blocks = queued_message.user_blocks;
                 attachments = queued_message.attachments;
               }
             in
             let agent_name = projection.agent_name in
             let events = Keeper_chat_events.create () in
             let closed = ref false in
             let thread_id = "keeper-consumer:" ^ keeper_name in
             (match queued_message.source with
              | Keeper_chat_queue.Dashboard ->
                  Log.Keeper.info
                    "keeper_chat_consumer: processing dashboard queue \
                     message for keeper=%s"
                    keeper_name
              | Keeper_chat_queue.Discord { channel_id; _ } ->
                  Log.Keeper.info
                    "keeper_chat_consumer: forking Discord adapter \
                     for keeper=%s"
                    keeper_name;
                  (match discord_bot_token_opt () with
                   | Some token ->
                       (* fork_logged_fiber, not bare Eio.Fiber.fork: the
                          adapter body runs after this synchronous frame
                          returns, so the enclosing try/with cannot catch an
                          exception it raises later. A bare fork would fail
                          the shared [sw] and cancel every sibling fiber under
                          it. [on_error] contains non-Cancelled exceptions;
                          [fork_logged_fiber] re-raises Cancelled to preserve
                          structured teardown. *)
                       fork_logged_fiber ~sw
                         ~on_error:(fun exn ->
                           Log.Keeper.error
                             "keeper_chat_consumer: Discord adapter fiber \
                              crashed for keeper=%s: %s"
                             keeper_name (Printexc.to_string exn))
                         (fun () ->
                           Keeper_chat_discord.adapter_loop ~token
                             ~channel_id ~events ())
                   | None ->
                       Log.Keeper.warn
                         "keeper_chat_consumer: \
                          DISCORD_BOT_TOKEN not set, \
                          skipping Discord delivery for keeper=%s"
                         keeper_name)
              | Keeper_chat_queue.Slack { channel; _ } ->
                  Log.Keeper.info
                    "keeper_chat_consumer: forking Slack adapter \
                     for keeper=%s"
                    keeper_name;
                  (match Env_config_slack.bot_token_opt () with
                   | Some token ->
                       (* Isolate from the shared [sw] like the Discord arm
                          above; a bare fork would cancel sibling fibers if
                          the adapter raises a non-Cancelled exception. *)
                       fork_logged_fiber ~sw
                         ~on_error:(fun exn ->
                           Log.Keeper.error
                             "keeper_chat_consumer: Slack adapter fiber \
                              crashed for keeper=%s: %s"
                             keeper_name (Printexc.to_string exn))
                         (fun () ->
                           Keeper_chat_slack.adapter_loop ~token
                             ~channel ~events
                             ~on_send_result:(fun result ->
                               Slack_observability.record_reply
                                 (match result with
                                  | Ok () -> Slack_observability.Reply_send_ok
                                  | Error _ ->
                                      Slack_observability.Reply_send_failed))
                             ())
                   | None ->
                       Log.Keeper.error
                         "keeper_chat_consumer: \
                          SLACK_BOT_TOKEN not set; \
                          Slack delivery skipped for keeper=%s \
                          (queued reply will not be delivered)"
                         keeper_name));
             (* RFC-connector-deferred-reply-via-chat-queue §3.4: connector sources (Discord/Slack) had their user
                line recorded at the gate inbound boundary before the message was
                enqueued, so the turn records the assistant reply only and does
                not re-write the user line. Dashboard-source queue messages have
                no upstream recorder, so the turn records both sides. *)
             let connector_user_line_recorded_upstream =
               match queued_message.source with
               | Keeper_chat_queue.Discord _ | Keeper_chat_queue.Slack _ -> true
               | Keeper_chat_queue.Dashboard -> false
             in
               process_single_turn ~connector_user_line_recorded_upstream
                 ~state ~clock ~sw ~auth_token:None
                 ~thread_id
                 ~continuation_channel:
                   (Keeper_chat_queue.continuation_channel_of_message_source
                      ~dashboard_thread_id:thread_id
                      queued_message.source)
                 ~closed ~client_disconnects:None ~payload ~run_id ~message_id
                 ~agent_name ~events)
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Keeper.warn
             "keeper_chat_consumer: failed to start: %s"
             (Printexc.to_string exn)));
  (* Discord presence bridge — syncs keeper liveness to bot status. *)
  fork_subsystem "discord_presence" (fun () ->
    Discord_presence_bridge.start
      ~sw ~clock ~workspace_config:(Mcp_server.workspace_config state) ());
  (* Phase 5: unified startup subsystem summary *)
  Log.Startup.info "subsystems: keeper loops started"
;;


(* Background maintenance loops
   extracted to [Server_bootstrap_maintenance] (godfile decomp). *)
include Server_bootstrap_maintenance
