(** MASC Coord - Core coordination hub.

    This module ties together all Coord sub-modules and provides
    cross-cutting functions that depend on multiple sub-modules. *)

(* Foundation: utilities and state management *)
include Coord_utils
include Coord_state
include Coord_broadcast

(* Agent join/leave lifecycle *)
include Coord_lifecycle

(* Coord initialization, reset, pause, resume (without auto-join) *)
include Coord_init

(** Initialize MASC room with optional auto-join.
    Wraps [Coord_init.init] and calls [join] when [agent_name] is provided. *)
let init config ~agent_name =
  let result = Coord_init.init config ~agent_name in
  if result = "MASC already initialized." then result
  else
    match agent_name with
    | Some name -> result ^ "\n" ^ (join config ~agent_name:name ~capabilities:[] ())
    | None -> result

(* Coord status display *)
include Coord_status

(* Task lifecycle: add, claim, transition, complete, cancel *)
include Coord_task

(* Task scheduling: claim_next, release_stale_claims *)
include Coord_task_schedule

(* Task/agent/message query and listing *)
include Coord_query

(* Portal / A2A Protocol *)
include Coord_portal

(* Git Worktree *)
include Coord_worktree

(* Heartbeat & GC *)
include Coord_gc

(* ============================================ *)
(* Wire Coord_hooks callbacks                    *)
(* ============================================ *)

let telemetry_enabled () = Env_config_core.telemetry_enabled ()

let merge_detail_fields fields details =
  match details with
  | `Assoc extra -> `Assoc (fields @ extra)
  | `Null -> `Assoc fields
  | other -> `Assoc (fields @ [ ("payload", other) ])

(* Exhaustive on [Types.task_action]: a new variant becomes a compile
   error here so the audit-log mapping cannot silently fall into the
   [Custom "task_<other>"] catch-all that the prior string-typed
   classifier produced. (#8605 family -- exhaustive-match template) *)
let task_action_of_transition : Types.task_action -> Audit_log.action = function
  | Types.Claim -> Audit_log.ClaimTask
  | Types.Start -> Audit_log.StartTask
  | Types.Done_action -> Audit_log.DoneTask
  | Types.Cancel -> Audit_log.CancelTask
  | Types.Release -> Audit_log.ReleaseTask
  | (Types.Submit_for_verification
    | Types.Approve_verification
    | Types.Reject_verification) as action ->
      Audit_log.Custom ("task_" ^ Types.task_action_to_string action)

(* #8605 family: replaced four parallel string switches on [event_kind]
   with a single [agent_lifecycle_event] variant. The compiler now
   forces every dispatch to cover Lifecycle_join / Lifecycle_rejoin /
   Lifecycle_leave explicitly, so a future event variant cannot silently
   coalesce into the catch-all "join" branch. JSON wire format is
   preserved via [agent_lifecycle_event_to_string]. *)
let observe_agent_lifecycle config ~agent_id ~(event : Coord_hooks.agent_lifecycle_event) ~details =
  let event_kind = Coord_hooks.agent_lifecycle_event_to_string event in
  let details =
    merge_detail_fields
      [
        ("event_family", `String "agent_lifecycle");
        ("event_kind", `String event_kind);
        ("agent_id", `String agent_id);
      ]
      details
  in
  let level =
    match event with
    | Lifecycle_join | Lifecycle_rejoin | Lifecycle_leave -> Log.Info
  in
  let message =
    match event with
    | Lifecycle_join -> Printf.sprintf "agent joined: %s" agent_id
    | Lifecycle_rejoin -> Printf.sprintf "agent rejoined: %s" agent_id
    | Lifecycle_leave -> Printf.sprintf "agent left: %s" agent_id
  in
  Log.emit level ~module_name:"Coord" ~details message;
  (match event with
   | Lifecycle_leave -> Prometheus.dec_gauge Prometheus.metric_active_agents ()
   | Lifecycle_join | Lifecycle_rejoin -> Prometheus.inc_gauge Prometheus.metric_active_agents ());
  let audit_details =
    match event with
    | Lifecycle_rejoin -> merge_detail_fields [ ("rejoin", `Bool true) ] details
    | Lifecycle_join | Lifecycle_leave -> details
  in
  let action =
    match event with
    | Lifecycle_leave -> Audit_log.Leave
    | Lifecycle_join | Lifecycle_rejoin -> Audit_log.Join
  in
  (* Audit and telemetry require Eio context (Eio.Mutex).
     Silently skip when running in non-Eio test context. *)
  (try
    Audit_log.log_action config ~agent_id ~action
      ~details:audit_details ~outcome:Audit_log.Success ();
    if telemetry_enabled () then
      match event with
      | Lifecycle_leave ->
          Telemetry_eio.track_agent_left config ~agent_id ~reason:"leave"
      | Lifecycle_join | Lifecycle_rejoin ->
          Telemetry_eio.track_agent_joined config ~agent_id ()
  with Stdlib.Effect.Unhandled _ -> ())

(* #8605 family: replaced four parallel string switches on [transition]
   with [Types.task_action] variant matches. The compiler now forces
   every dispatch to cover all 8 task_action constructors, so a future
   action variant cannot silently coalesce into the catch-all "no-op"
   branch. JSON wire format ("claim" / "start" / "done" / ...) is
   preserved via [Types.task_action_to_string]. *)
let observe_task_transition_event config ~agent_name ~task_id
    ~(transition : Types.task_action) ~details =
  let transition_s = Types.task_action_to_string transition in
  let details =
    merge_detail_fields
      [
        ("event_family", `String "task_transition");
        ("transition", `String transition_s);
        ("task_id", `String task_id);
        ("agent_id", `String agent_name);
      ]
      details
  in
  let level =
    match transition with
    | Types.Cancel -> Log.Warn
    | (Types.Claim | Types.Start | Types.Done_action | Types.Release
      | Types.Submit_for_verification | Types.Approve_verification
      | Types.Reject_verification) -> Log.Info
  in
  let message =
    Printf.sprintf "task %s %s by %s" task_id transition_s agent_name
  in
  Log.emit level ~module_name:"Task" ~details message;
  (try
    Audit_log.log_action config ~agent_id:agent_name
      ~action:(task_action_of_transition transition)
      ~details ~outcome:Audit_log.Success ();
    if telemetry_enabled () then
      match transition with
      | Types.Start ->
          Telemetry_eio.track_task_started config ~task_id ~agent_id:agent_name
      | Types.Done_action | Types.Cancel ->
          let duration_ms =
            Safe_ops.json_int ~default:0 "duration_ms" details
          in
          Telemetry_eio.track_task_completed config ~task_id ~duration_ms
            ~success:(transition = Types.Done_action)
      | (Types.Claim | Types.Release
        | Types.Submit_for_verification | Types.Approve_verification
        | Types.Reject_verification) -> ()
  with Stdlib.Effect.Unhandled _ -> ());
  (try
     Keeper_accountability.record_task_transition config ~agent_name ~task_id
       ~transition ~details
  with Stdlib.Effect.Unhandled _ -> ())

(* force_release_task — zombie cleanup needs task management logic *)
let () = Atomic.set Coord_hooks.force_release_task_fn (fun config ~agent_name ~task_id () ->
    force_release_task_r config ~agent_name ~task_id ())

(* #9795: wire the FSM drift hook to a Prometheus counter emit.
   [Coord_task.transition] calls the hook whenever
   [Coord_task_lifecycle.decide] returns a [drift]; this side
   puts the signal on
   [masc_task_fsm_drift_total{variant, force}] so Grafana /
   ratchet-readiness dashboards can see it.  The emit lives at
   [masc_mcp] layer because [masc_coord] sits below [Prometheus]
   in the library dep graph. *)
let fsm_drift_metric = "masc_task_fsm_drift_total"

let record_fsm_drift ~variant ~force =
  Prometheus.inc_counter fsm_drift_metric
    ~labels:[ ("variant", variant);
              ("force", if force then "true" else "false") ]
    ()

(* #9795 follow-up: per-agent breakout so operators can identify
   which keepers most often skip [in_progress] before [done].
   Cardinality is bounded by fleet size (~10 keepers in masc-mcp),
   keeping the additional series count safe for Prometheus.  Emit
   the variant-only counter alongside so existing dashboards keep
   working — the new metric is purely additive. *)
let fsm_drift_per_agent_metric = "masc_task_fsm_drift_per_agent_total"

let record_fsm_drift_with_agent ~variant ~force ~agent_name =
  record_fsm_drift ~variant ~force;
  Prometheus.inc_counter fsm_drift_per_agent_metric
    ~labels:[ ("variant", variant);
              ("agent_name", agent_name);
              ("force", if force then "true" else "false") ]
    ()

let () = Atomic.set Coord_hooks.fsm_drift_observer_fn record_fsm_drift_with_agent

(* #9632: Process_eio timeout observability.
   Fleet-wide rate of subprocess timeouts, broken down by program
   (argv[0] basename) and configured budget.  Lets operators answer
   "which command is timing out, and is 15s/60s the right budget?"
   without log-scraping the WARN line.  Cardinality is bounded by
   the small set of commands MASC actually invokes (~10-20 series). *)
let process_timeout_metric = Prometheus.metric_process_timeout

let record_process_timeout ~program ~timeout_sec =
  Prometheus.inc_counter process_timeout_metric
    ~labels:[ ("program", program);
              ("timeout_sec", Printf.sprintf "%.0f" timeout_sec) ]
    ()

let () =
  Atomic.set Process_eio.process_timeout_observer_fn record_process_timeout

(* #9645: distributed lock acquire exhaustion observability.

   [Coord_utils_ops.with_distributed_lock]/[..._r] now signal
   exhaustion via [Coord_hooks.distributed_lock_acquire_failed_fn].
   Wire that hook to a Prometheus counter so operators can rate-
   alert on chronic lock contention (production observed
   tasks:.backlog starvation under 16-keeper fleet load). *)
let distributed_lock_acquire_failed_metric =
  Prometheus.metric_distributed_lock_acquire_failed

let record_distributed_lock_acquire_failed ~key ~attempts =
  Prometheus.inc_counter distributed_lock_acquire_failed_metric
    ~labels:[ ("key", key); ("attempts", string_of_int attempts) ]
    ()

let () =
  Atomic.set Coord_hooks.distributed_lock_acquire_failed_fn
    record_distributed_lock_acquire_failed

(* Activity graph emit — wraps Activity_graph for room sub-modules *)
let () = Atomic.set Coord_hooks.activity_emit_fn (fun config ~actor ?subject ~kind ~payload ~tags () ->
    (try
      ignore (Activity_graph.emit config
        ~actor:(Activity_graph.entity ~kind:actor.Coord_hooks.kind actor.id)
        ?subject:(Option.map (fun (s : Coord_hooks.activity_entity) ->
          Activity_graph.entity ~kind:s.kind s.id) subject)
        ~kind ~payload ~tags ())
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn -> Log.Coord.warn "activity_graph emit failed: %s" (Printexc.to_string exn)))

(* Agent economy earn — wraps Agent_economy for task completion credits *)
let () = Atomic.set Coord_hooks.agent_economy_earn_fn (fun ~base_path ~agent_name ~reason ->
    match Agent_economy.earn ~base_path ~agent_name
      ~kind:Earn_task_done ~reason () with
    | Ok _bal -> ()
    | Error msg -> Log.Misc.error "task earn failed: %s" msg)

(* Relation materializer — agent leave *)
let () = Atomic.set Coord_hooks.relation_on_leave_fn Relation_materializer.on_agent_leave

(* Relation materializer — task done *)
let () = Atomic.set Coord_hooks.relation_on_task_done_fn Relation_materializer.on_task_done

(* Hebbian learning — strengthen on task completion.
   Also emits activity events so strengthens appear in the
   activity graph / telemetry surface alongside task events. *)
let () = Atomic.set Coord_hooks.hebbian_on_task_done_fn (fun config ~assignee ~active_agents ->
    List.iter (fun peer ->
      if peer <> assignee then begin
        (try Hebbian_eio.strengthen config ~from_agent:assignee ~to_agent:peer ()
         with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
           Log.Coord.warn "hebbian strengthen failed: %s" (Printexc.to_string exn));
        Safe_ops.protect ~default:() (fun () ->
          (Atomic.get Coord_hooks.activity_emit_fn) config
            ~actor:Coord_hooks.{ kind = "agent"; id = assignee }
            ~subject:Coord_hooks.{ kind = "agent"; id = peer }
            ~kind:"hebbian.strengthen"
            ~payload:(`Assoc [
              ("from_agent", `String assignee);
              ("to_agent", `String peer);
            ])
            ~tags:[ "hebbian"; "strengthen"; "memory" ]
            ())
      end
    ) active_agents)

(* Hebbian learning — weaken on task cancellation. *)
let () = Atomic.set Coord_hooks.hebbian_on_task_cancelled_fn (fun config ~agent_name ~active_agents ->
    List.iter (fun peer ->
      if peer <> agent_name then begin
        (try Hebbian_eio.weaken config ~from_agent:agent_name ~to_agent:peer ()
         with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
           Log.Coord.warn "hebbian weaken failed: %s" (Printexc.to_string exn));
        Safe_ops.protect ~default:() (fun () ->
          (Atomic.get Coord_hooks.activity_emit_fn) config
            ~actor:Coord_hooks.{ kind = "agent"; id = agent_name }
            ~subject:Coord_hooks.{ kind = "agent"; id = peer }
            ~kind:"hebbian.weaken"
            ~payload:(`Assoc [
              ("from_agent", `String agent_name);
              ("to_agent", `String peer);
            ])
            ~tags:[ "hebbian"; "weaken"; "memory" ]
            ())
      end
    ) active_agents)

let () = Atomic.set Coord_hooks.observe_agent_lifecycle_fn (fun config ~agent_id ~event ~details ->
    observe_agent_lifecycle config ~agent_id ~event ~details)

let () = Atomic.set Coord_hooks.observe_task_transition_fn (fun config ~agent_name ~task_id ~transition ~details ->
    (Atomic.get Coord_hooks.on_task_mutation_fn) ();
    observe_task_transition_event config ~agent_name ~task_id
      ~transition ~details)

(* Board artifact cleanup — wraps Board_dispatch for GC *)
let () = Atomic.set Coord_hooks.cleanup_board_artifacts_fn (fun () ->
  let stale_system_daily_sec = 12.0 *. 3600.0 in
  let board_artifact_title title =
    let title = String.lowercase_ascii (String.trim title) in
    String.starts_with ~prefix:"[keeper daily]" title
  in
  let board_artifact_author author =
    let author = String.lowercase_ascii (String.trim author) in
    author = "auto-researcher"
    || String.starts_with ~prefix:"qa-" author
    || ((not (String.contains author ' '))
        && String.ends_with ~suffix:"-probe" author)
  in
  let now = Time_compat.now () in
  Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent ~limit:5200 ()
  |> List.fold_left
       (fun removed (post : Board.post) ->
         let author = Board.Agent_id.to_string post.author in
         if board_artifact_author author
            || (String.equal (String.lowercase_ascii author) "keeper"
                && board_artifact_title post.title
                && now -. post.updated_at >= stale_system_daily_sec) then
           match Board_dispatch.delete_post
                   ~post_id:(Board.Post_id.to_string post.id) with
           | Ok () -> removed + 1
           | Error _ -> removed
         else removed)
       0)

(* Subscription auto-subscribe on join — wraps Subscriptions for room_eio *)
let () = Atomic.set Coord_hooks.subscribe_messages_fn (fun ~subscriber ->
  let _ = Subscriptions.SubscriptionStore.subscribe
    ~subscriber ~resource:Subscriptions.Messages () in ())

(* Tool assignment telemetry — record tool provision events *)
let () = Atomic.set Coord_hooks.tool_assigned_fn Tool_assignment_telemetry.emit_assigned

(* Agent status, capability registration, discovery *)
include Coord_agent

(* Coord_multi removed — operational namespace is always "default" *)
(* Coord_vote, Coord_tempo removed — dead prod code (Epic #7261 Step 5 audit). *)
