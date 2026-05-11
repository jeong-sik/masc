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
  if result = "MASC already initialized."
  then result
  else (
    match agent_name with
    | Some name -> result ^ "\n" ^ join config ~agent_name:name ~capabilities:[] ()
    | None -> result)
;;

(* Coord status display *)
include Coord_status

(* Task lifecycle: add, claim, transition, complete, cancel *)
include Coord_task

(* Task scheduling: claim_next, release_stale_claims *)
include Coord_task_schedule

(* Task/agent/message query and listing *)
include Coord_query

(* Portal / A2A Protocol *)

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
  | other -> `Assoc (fields @ [ "payload", other ])
;;

(* #10358 (c1): make non-Eio-context drops observable.

   The three try/with sites below catch [Stdlib.Effect.Unhandled] so the
   lifecycle hook does not crash when invoked outside an Eio scheduler
   (test path / bootstrap / non-Eio handler). Before this helper the
   handler body was [-> ()] which silently dropped the entire Audit_log
   + Telemetry pair — exactly matching the [#10358] 5-tag → 2-tag
   attrition pattern observed in the durable ledger. We still swallow
   the exception (the lifecycle hook must not propagate failures into
   the caller's control flow), but we now emit a Warn log line and
   bump [masc_coord_telemetry_drop_total{event_family,event_kind}] so
   operators can see in Grafana / log aggregation when production
   paths are dispatching lifecycle outside an Eio fiber. *)
let warn_telemetry_drop ~event_family ~event_kind exn =
  let exn_str = Printexc.to_string exn in
  let details =
    `Assoc
      [ "event_family", `String event_family
      ; "event_kind", `String event_kind
      ; "exception", `String exn_str
      ]
  in
  (* Isolated silent side effects: the call sites that invoke this helper rely
     on the "[Effect.Unhandled] is fully absorbed" contract. Each observability
     side effect is wrapped separately so a failure in one (e.g. [Log.emit]
     hitting a sink failure) does not skip the other. This path intentionally
     uses [observe_silent] instead of [observe_or_default] because warning about
     a failed warning can re-enter the same failing log backend and break the
     caller contract. [Eio.Cancel.Cancelled] is still preserved. (#13096 review,
     copilot P1; supersedes the single-try wrapping noted in codex P2.) *)
  Telemetry_observe.observe_silent ~kind:"coord_telemetry_drop_log" (fun () ->
    Log.emit
      Log.Warn
      ~module_name:"Coord"
      ~details
      (Printf.sprintf
         "telemetry/audit dropped (non-Eio context): %s/%s"
         event_family
         event_kind));
  Telemetry_observe.observe_silent ~kind:"coord_telemetry_drop_metric" (fun () ->
    Prometheus.inc_counter
      Prometheus.metric_coord_telemetry_drop
      ~labels:[ "event_family", event_family; "event_kind", event_kind ]
      ())
;;

module For_testing = struct
  let warn_telemetry_drop = warn_telemetry_drop
end

(* Exhaustive on [Masc_domain.task_action]: a new variant becomes a compile
   error here so the audit-log mapping cannot silently fall into the
   [Custom "task_<other>"] catch-all that the prior string-typed
   classifier produced. (#8605 family -- exhaustive-match template) *)
let task_action_of_transition : Masc_domain.task_action -> Audit_log.action = function
  | Masc_domain.Claim -> Audit_log.ClaimTask
  | Masc_domain.Start -> Audit_log.StartTask
  | Masc_domain.Done_action -> Audit_log.DoneTask
  | Masc_domain.Cancel -> Audit_log.CancelTask
  | Masc_domain.Release -> Audit_log.ReleaseTask
  | ( Masc_domain.Submit_for_verification
    | Masc_domain.Submit_pr_evidence
    | Masc_domain.Approve_verification
    | Masc_domain.Reject_verification ) as action ->
    Audit_log.Custom ("task_" ^ Masc_domain.task_action_to_string action)
;;

(* #8605 family: replaced four parallel string switches on [event_kind]
   with a single [agent_lifecycle_event] variant. The compiler now
   forces every dispatch to cover Lifecycle_join / Lifecycle_rejoin /
   Lifecycle_leave explicitly, so a future event variant cannot silently
   coalesce into the catch-all "join" branch. JSON wire format is
   preserved via [agent_lifecycle_event_to_string]. *)
let observe_agent_lifecycle
      config
      ~agent_id
      ~(event : Coord_hooks.agent_lifecycle_event)
      ~details
  =
  let event_kind = Coord_hooks.agent_lifecycle_event_to_string event in
  let details =
    merge_detail_fields
      [ "event_family", `String "agent_lifecycle"
      ; "event_kind", `String event_kind
      ; "agent_id", `String agent_id
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
   | Lifecycle_join | Lifecycle_rejoin ->
     Prometheus.inc_gauge Prometheus.metric_active_agents ());
  let audit_details =
    match event with
    | Lifecycle_rejoin -> merge_detail_fields [ "rejoin", `Bool true ] details
    | Lifecycle_join | Lifecycle_leave -> details
  in
  let action =
    match event with
    | Lifecycle_leave -> Audit_log.Leave
    | Lifecycle_join | Lifecycle_rejoin -> Audit_log.Join
  in
  (* Audit and telemetry require Eio context (Eio.Mutex).
     Skip when running outside an Eio scheduler, but emit a warn log
     line + Prometheus counter so the drop is observable (#10358 c1). *)
  try
    Audit_log.log_action
      config
      ~agent_id
      ~action
      ~details:audit_details
      ~outcome:Audit_log.Success
      ();
    if telemetry_enabled ()
    then (
      match event with
      | Lifecycle_leave -> Telemetry_eio.track_agent_left config ~agent_id ~reason:"leave"
      | Lifecycle_join | Lifecycle_rejoin ->
        Telemetry_eio.track_agent_joined config ~agent_id ())
  with
  | Stdlib.Effect.Unhandled _ as exn ->
    warn_telemetry_drop ~event_family:"agent_lifecycle" ~event_kind exn
;;

(* #8605 family: replaced four parallel string switches on [transition]
   with [Masc_domain.task_action] variant matches. The compiler now forces
   every dispatch to cover all 8 task_action constructors, so a future
   action variant cannot silently coalesce into the catch-all "no-op"
   branch. JSON wire format ("claim" / "start" / "done" / ...) is
   preserved via [Masc_domain.task_action_to_string]. *)
let observe_task_transition_event
      config
      ~agent_name
      ~task_id
      ~(transition : Masc_domain.task_action)
      ~details
  =
  let transition_s = Masc_domain.task_action_to_string transition in
  let details =
    merge_detail_fields
      [ "event_family", `String "task_transition"
      ; "transition", `String transition_s
      ; "task_id", `String task_id
      ; "agent_id", `String agent_name
      ]
      details
  in
  let level =
    match transition with
    | Masc_domain.Cancel -> Log.Warn
    | Masc_domain.Claim
    | Masc_domain.Start
    | Masc_domain.Done_action
    | Masc_domain.Release
    | Masc_domain.Submit_for_verification
    | Masc_domain.Submit_pr_evidence
    | Masc_domain.Approve_verification
    | Masc_domain.Reject_verification -> Log.Info
  in
  let message = Printf.sprintf "task %s %s by %s" task_id transition_s agent_name in
  Log.emit level ~module_name:"Task" ~details message;
  (try
     Audit_log.log_action
       config
       ~agent_id:agent_name
       ~action:(task_action_of_transition transition)
       ~details
       ~outcome:Audit_log.Success
       ();
     if telemetry_enabled ()
     then (
       match transition with
       | Masc_domain.Claim | Masc_domain.Start ->
         Telemetry_eio.track_task_started config ~task_id ~agent_id:agent_name
       | Masc_domain.Done_action | Masc_domain.Approve_verification ->
         let duration_ms = Safe_ops.json_int ~default:0 "duration_ms" details in
         Telemetry_eio.track_task_completed config ~task_id ~duration_ms ~success:true
       | Masc_domain.Cancel ->
         let duration_ms = Safe_ops.json_int ~default:0 "duration_ms" details in
         Telemetry_eio.track_task_completed config ~task_id ~duration_ms ~success:false
       | Masc_domain.Release
       | Masc_domain.Submit_for_verification
       | Masc_domain.Submit_pr_evidence
       | Masc_domain.Reject_verification -> ())
   with
   | Stdlib.Effect.Unhandled _ as exn ->
     warn_telemetry_drop ~event_family:"task_transition" ~event_kind:transition_s exn);
  try
    Keeper_accountability.record_task_transition
      config
      ~agent_name
      ~task_id
      ~transition
      ~details
  with
  | Stdlib.Effect.Unhandled _ as exn ->
    warn_telemetry_drop ~event_family:"accountability" ~event_kind:transition_s exn
;;

(* force_release_task — zombie cleanup needs task management logic *)
let () =
  Atomic.set Coord_hooks.force_release_task_fn (fun config ~agent_name ~task_id () ->
    force_release_task_r config ~agent_name ~task_id ())
;;

(* #9795: wire the FSM drift hook to a Prometheus counter emit.
   [Coord_task.transition] calls the hook whenever
   [Coord_task_lifecycle.decide] returns a [drift]; this side
   puts the signal on
   [masc_task_fsm_drift_total{variant, force}] so Grafana /
   ratchet-readiness dashboards can see it.  The emit lives at
   [masc_mcp] layer because [masc_coord] sits below [Prometheus]
   in the library dep graph. *)
let fsm_drift_metric = "masc_task_fsm_drift_total"

let () =
  Prometheus.register_counter
    ~name:fsm_drift_metric
    ~help:
      "Total task FSM drift transitions observed by Coord_task_lifecycle.decide (e.g. \
       InProgress -> Done skipping the verifier path). Labels: variant (drift variant \
       tag from Coord_task_lifecycle), force (true | false — was the transition forced \
       past the soft gate). #9795 fleet-wide ratchet-readiness signal."
    ()
;;

let record_fsm_drift ~variant ~force =
  Prometheus.inc_counter
    fsm_drift_metric
    ~labels:[ "variant", variant; ("force", if force then "true" else "false") ]
    ()
;;

(* #9795 follow-up: per-agent breakout so operators can identify
   which keepers most often skip [in_progress] before [done].
   Cardinality is bounded by fleet size (~10 keepers in masc-mcp),
   keeping the additional series count safe for Prometheus.  Emit
   the variant-only counter alongside so existing dashboards keep
   working — the new metric is purely additive. *)
let fsm_drift_per_agent_metric = "masc_task_fsm_drift_per_agent_total"

let () =
  Prometheus.register_counter
    ~name:fsm_drift_per_agent_metric
    ~help:
      "Per-agent breakout of task FSM drift transitions (companion to \
       masc_task_fsm_drift_total — purely additive). Lets operators identify which \
       keepers most often skip [in_progress] before [done]. Labels: variant, agent_name, \
       force. Cardinality bounded by fleet size."
    ()
;;

let record_fsm_drift_with_agent ~variant ~force ~agent_name =
  record_fsm_drift ~variant ~force;
  Prometheus.inc_counter
    fsm_drift_per_agent_metric
    ~labels:
      [ "variant", variant
      ; "agent_name", agent_name
      ; ("force", if force then "true" else "false")
      ]
    ()
;;

let () = Atomic.set Coord_hooks.fsm_drift_observer_fn record_fsm_drift_with_agent

(* #10449: Task completion path + contract-presence observability.
   Splits the per-Done emit by [path] (claimed_to_done_skip /
   in_progress_to_done / via_verification / forced_done) and
   [contract_state] (no_contract / empty_contract / with_contract)
   so operators can attribute bypass-rate to the creation-side
   (missing contracts) vs. the gate-side (verifier-redirect not
   firing). Cardinality bounded at ~4 × 3 × fleet_size. *)
let task_completion_path_metric = "masc_task_completion_path_total"

let () =
  Prometheus.register_counter
    ~name:task_completion_path_metric
    ~help:
      "Total task Done emits classified by completion path and contract presence. Lets \
       operators attribute bypass-rate to creation-side (missing contracts) vs. \
       gate-side (verifier-redirect not firing). Labels: path (claimed_to_done_skip | \
       in_progress_to_done | via_verification | forced_done), contract_state \
       (no_contract | empty_contract | with_contract), agent_name. Cardinality bounded \
       at ~4 x 3 x fleet_size (#10449)."
    ()
;;

let record_task_completion_path ~path ~contract_state ~agent_name =
  Prometheus.inc_counter
    task_completion_path_metric
    ~labels:[ "path", path; "contract_state", contract_state; "agent_name", agent_name ]
    ()
;;

let () =
  Atomic.set Coord_hooks.task_completion_path_observed_fn record_task_completion_path
;;

(* #10421: implicit auto-release rate from [task_claim_next].
   Field log showed 43 claimed→todo vs 24 todo→claimed in one
   day (179% release/claim ratio) with only 1/71 transitions
   reaching done — same task hot-potatoed up to 5x.  Counter
   gives operators a fleet-wide rate, broken down by keeper
   and by [from_status] so [InProgress → Todo] (mid-work
   churn) is separable from [Claimed → Todo] (just-claimed
   churn).  Cardinality bounded at ~fleet × 2. *)
let task_auto_release_metric = "masc_task_auto_release_total"

let () =
  Prometheus.register_counter
    ~name:task_auto_release_metric
    ~help:
      "Total implicit task auto-releases triggered by [task_claim_next] (mid-work churn \
       or just-claimed churn). Labels: agent_name, from_status (separates [InProgress -> \
       Todo] from [Claimed -> Todo]). Field log motivation: observed 179% release/claim \
       ratio with task hot-potatoed up to 5x in one day (#10421). Cardinality bounded at \
       ~fleet x 2."
    ()
;;

let record_task_auto_release ~agent_name ~from_status =
  Prometheus.inc_counter
    task_auto_release_metric
    ~labels:[ "agent_name", agent_name; "from_status", from_status ]
    ()
;;

let () = Atomic.set Coord_hooks.task_auto_release_observed_fn record_task_auto_release

(* Coord broadcast latency histogram and file lock retry/duration metrics.

   At 64+ keepers the broadcast hot path serialises against [state.json]
   (next_seq) and writes msg.json + activity events under file locks.
   Without these series operators see only the SSE-side latency
   ([masc_sse_broadcast_duration_seconds]); the publisher-side cost
   (state lock + read/write + activity emit) was invisible.

   File-lock metrics are wired here rather than in [masc_process]
   because that sub-library does not depend on [Prometheus]; the hook
   in [File_lock_eio.on_lock_attempt_fn] forwards each attempt outcome
   to this site. *)
let record_coord_broadcast ~msg_type ~elapsed_s =
  Prometheus.observe_histogram
    Prometheus.metric_coord_broadcast_duration
    ~labels:[ "msg_type", msg_type ]
    elapsed_s
;;

let () = Atomic.set Coord_hooks.coord_broadcast_observed_fn record_coord_broadcast

(* RFC-0040: route Mention_dedup decision counts to Prometheus.
   Default no-op in [Coord_hooks] is replaced at startup so the
   coord layer keeps zero static dep on Prometheus. *)
let record_mention_dedup_decision ~outcome =
  Prometheus.inc_counter
    Prometheus.metric_mention_dedup_decisions_total
    ~labels:[ "outcome", outcome ]
    ()
;;

let () = Atomic.set Coord_hooks.mention_dedup_decision_fn record_mention_dedup_decision

let record_file_lock_attempt ~caller ~retries ~elapsed_s ~outcome =
  if retries > 0
  then
    Prometheus.inc_counter
      Prometheus.metric_file_lock_retries
      ~labels:[ "caller", caller ]
      ~delta:(float_of_int retries)
      ();
  Prometheus.observe_histogram
    Prometheus.metric_file_lock_acquire_seconds
    ~labels:[ "caller", caller; "outcome", outcome ]
    elapsed_s
;;

let () = Atomic.set File_lock_eio.on_lock_attempt_fn record_file_lock_attempt

let clear_agent_current_task_cache config ~task_id =
  let agents_path = agents_dir config in
  if path_exists config agents_path
  then (
    let agent_files =
      try Sys.readdir agents_path with
      | Sys_error msg ->
        Log.Misc.warn "cache desync agent scan failed: %s" msg;
        [||]
    in
    Array.iter
      (fun name ->
         if Filename.check_suffix name ".json"
         then (
           let path = Filename.concat agents_path name in
           if path_exists config path
           then
             with_file_lock config path (fun () ->
               match read_agent_with_repair config path with
               | Ok agent when agent.current_task = Some task_id ->
                 let status =
                   match agent.status with
                   | Masc_domain.Inactive -> Masc_domain.Inactive
                   | Masc_domain.Active | Masc_domain.Busy | Masc_domain.Listening ->
                     Masc_domain.Active
                 in
                 let updated =
                   { agent with
                     status
                   ; current_task = None
                   ; last_seen = Masc_domain.now_iso ()
                   }
                 in
                 write_json config path (Masc_domain.agent_to_yojson updated);
                 log_event
                   config
                   (`Assoc
                       [ "type", `String "agent_current_task_cache_cleared"
                       ; "agent", `String agent.name
                       ; "stale_task", `String task_id
                       ; "ts", `String (Masc_domain.now_iso ())
                       ])
               | Ok _ -> ()
               | Error msg ->
                 Log.Misc.warn "cache desync agent read failed for %s: %s" name msg)))
      agent_files)
;;

(* #13460: cache desync invalidation counter. Coord_broadcast emits this when
   it replaces an active-claim/release message for a terminal backlog task with
   a cache_invalidated broadcast.  Clear coord-owned current_task caches so the
   same stale claim does not re-emit every taskmaster cycle.  Keep labels
   fleet-bounded; the task id stays in the replacement message/event, not the
   Prometheus series key. *)
let record_cache_desync_cleared config ~module_name ~task_id ~status =
  if not (String.equal status "backlog_unavailable")
  then clear_agent_current_task_cache config ~task_id;
  Prometheus.inc_counter
    Prometheus.metric_cache_desync_cleared
    ~labels:[ "module", module_name; "status", status ]
    ()
;;

let () = Atomic.set Coord_hooks.cache_desync_cleared_fn record_cache_desync_cleared

(* #9632: Process_eio timeout observability.
   Fleet-wide rate of subprocess timeouts, broken down by program
   (argv[0] basename) and configured budget.  Lets operators answer
   "which command is timing out, and is 15s/60s the right budget?"
   without log-scraping the WARN line.  Cardinality is bounded by
   the small set of commands MASC actually invokes (~10-20 series). *)
let process_timeout_metric = Prometheus.metric_process_timeout

let record_process_timeout ~program ~timeout_sec =
  (* Bucket the raw float to keep Prometheus cardinality bounded — a
     [Printf.sprintf "%.0f"] of caller-supplied seconds would mint a
     new series per distinct value.  Five closed buckets preserve the
     operator question "is 15s/60s the right budget?" while
     guaranteeing the label set never grows beyond
     [Timeout_bucket]'s variant arity. *)
  Prometheus.inc_counter
    process_timeout_metric
    ~labels:
      [ "program", program
      ; "timeout_bucket", Timeout_bucket.(to_label (of_seconds timeout_sec))
      ]
    ()
;;

let () = Atomic.set Process_eio.process_timeout_observer_fn record_process_timeout

(* #9645: distributed lock acquire exhaustion observability.

   [Coord_utils_ops.with_distributed_lock]/[..._r] now signal
   exhaustion via [Coord_hooks.distributed_lock_acquire_failed_fn].
   Wire that hook to a Prometheus counter so operators can rate-
   alert on chronic lock contention (production observed
   tasks:.backlog starvation under 16-keeper fleet load). *)
let distributed_lock_acquire_failed_metric =
  Prometheus.metric_distributed_lock_acquire_failed
;;

let record_distributed_lock_acquire_failed ~key ~attempts =
  Prometheus.inc_counter
    distributed_lock_acquire_failed_metric
    ~labels:[ "key", key; "attempts", string_of_int attempts ]
    ()
;;

let () =
  Atomic.set
    Coord_hooks.distributed_lock_acquire_failed_fn
    record_distributed_lock_acquire_failed
;;

let record_claim_post_provision_failed ~site ~agent_name ~task_id:_ ~error:_ =
  Prometheus.inc_counter
    Prometheus.metric_coord_claim_post_provision_failures
    ~labels:[ "site", site; "agent_name", agent_name ]
    ()
;;

let () =
  Atomic.set Coord_hooks.claim_post_provision_failed_fn record_claim_post_provision_failed
;;

(* Activity graph emit — wraps Activity_graph for room sub-modules *)
let () =
  Atomic.set
    Coord_hooks.activity_emit_fn
    (fun config ~actor ?subject ~kind ~payload ~tags () ->
       try
         ignore
           (Activity_graph.emit
              config
              ~actor:(Activity_graph.entity ~kind:actor.Coord_hooks.kind actor.id)
              ?subject:
                (Option.map
                   (fun (s : Coord_hooks.activity_entity) ->
                      Activity_graph.entity ~kind:s.kind s.id)
                   subject)
              ~kind
              ~payload
              ~tags
              ())
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn -> Log.Coord.warn "activity_graph emit failed: %s" (Printexc.to_string exn))
;;

(* Agent economy earn — wraps Agent_economy for task completion credits *)
let () =
  Atomic.set Coord_hooks.agent_economy_earn_fn (fun ~base_path ~agent_name ~reason ->
    match Agent_economy.earn ~base_path ~agent_name ~kind:Earn_task_done ~reason () with
    | Ok _bal -> ()
    | Error msg -> Log.Misc.error "task earn failed: %s" msg)
;;

(* Relation materializer — agent leave *)
let () = Atomic.set Coord_hooks.relation_on_leave_fn Relation_materializer.on_agent_leave

(* Relation materializer — task done *)
let () =
  Atomic.set Coord_hooks.relation_on_task_done_fn Relation_materializer.on_task_done
;;

(* Hebbian learning — strengthen on task completion.
   Also emits activity events so strengthens appear in the
   activity graph / telemetry surface alongside task events. *)
let () =
  Atomic.set Coord_hooks.hebbian_on_task_done_fn (fun config ~assignee ~active_agents ->
    List.iter
      (fun peer ->
         if peer <> assignee
         then
           Safe_ops.protect ~default:() (fun () ->
             (Atomic.get Coord_hooks.activity_emit_fn)
               config
               ~actor:Coord_hooks.{ kind = "agent"; id = assignee }
               ~subject:Coord_hooks.{ kind = "agent"; id = peer }
               ~kind:"hebbian.strengthen"
               ~payload:
                 (`Assoc [ "from_agent", `String assignee; "to_agent", `String peer ])
               ~tags:[ "hebbian"; "strengthen"; "memory" ]
               ()))
      active_agents)
;;

(* Hebbian learning — weaken on task cancellation. *)
let () =
  Atomic.set
    Coord_hooks.hebbian_on_task_cancelled_fn
    (fun config ~agent_name ~active_agents ->
       List.iter
         (fun peer ->
            if peer <> agent_name
            then
              Safe_ops.protect ~default:() (fun () ->
                (Atomic.get Coord_hooks.activity_emit_fn)
                  config
                  ~actor:Coord_hooks.{ kind = "agent"; id = agent_name }
                  ~subject:Coord_hooks.{ kind = "agent"; id = peer }
                  ~kind:"hebbian.weaken"
                  ~payload:
                    (`Assoc [ "from_agent", `String agent_name; "to_agent", `String peer ])
                  ~tags:[ "hebbian"; "weaken"; "memory" ]
                  ()))
         active_agents)
;;

let () =
  Atomic.set
    Coord_hooks.observe_agent_lifecycle_fn
    (fun config ~agent_id ~event ~details ->
       observe_agent_lifecycle config ~agent_id ~event ~details)
;;

let () =
  Atomic.set
    Coord_hooks.observe_task_transition_fn
    (fun config ~agent_name ~task_id ~transition ~details ->
       (Atomic.get Coord_hooks.on_task_mutation_fn) ();
       observe_task_transition_event config ~agent_name ~task_id ~transition ~details)
;;

(* Board artifact cleanup — wraps Board_dispatch for GC *)
let () =
  Atomic.set Coord_hooks.cleanup_board_artifacts_fn (fun () ->
    let stale_system_daily_sec = 12.0 *. 3600.0 in
    let board_artifact_title title =
      let title = String.lowercase_ascii (String.trim title) in
      String.starts_with ~prefix:"[keeper daily]" title
    in
    let board_artifact_author author =
      let author = String.lowercase_ascii (String.trim author) in
      author = "auto-researcher"
      || String.starts_with ~prefix:"qa-" author
      || ((not (String.contains author ' ')) && String.ends_with ~suffix:"-probe" author)
    in
    let now = Time_compat.now () in
    Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent ~limit:5200 ()
    |> List.fold_left
         (fun removed (post : Board.post) ->
            let author = Board.Agent_id.to_string post.author in
            if
              board_artifact_author author
              || (String.equal (String.lowercase_ascii author) "keeper"
                  && board_artifact_title post.title
                  && now -. post.updated_at >= stale_system_daily_sec)
            then (
              match
                Board_dispatch.delete_post ~post_id:(Board.Post_id.to_string post.id)
              with
              | Ok () -> removed + 1
              | Error _ -> removed)
            else removed)
         0)
;;

(* Subscription auto-subscribe on join — wraps Subscriptions for room_eio *)
let () =
  Atomic.set Coord_hooks.subscribe_messages_fn (fun ~subscriber ->
    let _ =
      Subscriptions.SubscriptionStore.subscribe
        ~subscriber
        ~resource:Subscriptions.Messages
        ()
    in
    ())
;;

(* Tool assignment telemetry — record tool provision events *)
let () = Atomic.set Coord_hooks.tool_assigned_fn Tool_assignment_telemetry.emit_assigned

(* Agent status, capability registration, discovery *)
include Coord_agent

(* Coord_multi removed — operational namespace is always "default" *)
(* Coord_vote, Coord_tempo removed — dead prod code (Epic #7261 Step 5 audit). *)
