(** MASC Workspace - Core workspace hub.

    This module ties together all Workspace sub-modules and provides
    cross-cutting functions that depend on multiple sub-modules. *)

(* Foundation: utilities and state management *)
include Workspace_utils
include Workspace_backlog
include Workspace_bootstrap
include Workspace_identity
include Workspace_task_id
include Workspace_state
include Workspace_bootstrap
include Workspace_identity
include Workspace_task_id
include Workspace_backlog
include Workspace_broadcast

(* Agent session binding lifecycle *)
include Workspace_lifecycle

(* Workspace initialization, reset, pause, resume *)
include Workspace_init

(** Initialize MASC workspace with optional session binding.
    Wraps [Workspace_init.init] and calls [bind_session] when [agent_name] is provided. *)
let init config ~agent_name =
  let result = Workspace_init.init config ~agent_name in
  if result = "MASC already initialized."
  then result
  else (
    match agent_name with
    | Some name -> result ^ "\n" ^ bind_session config ~agent_name:name ~capabilities:[] ()
    | None -> result)
;;

(* Workspace status display *)
include Workspace_status

(* Task lifecycle: add, claim, transition, complete, cancel *)
include Workspace_task

(* Task scheduling: claim_next *)
include Workspace_task_schedule

(* Task/agent/message query and listing *)
include Workspace_query
include Workspace_agent

(* Heartbeat & GC *)
include Workspace_gc

(* ============================================ *)
(* Wire Workspace_hooks callbacks                    *)
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
   bump [masc_workspace_telemetry_drop_total{event_family,event_kind}] so
   operators can see in Grafana / log aggregation when production
   paths are dispatching lifecycle outside an Eio fiber.

   RFC-0088 §4 Option A (2026-05-15): [event_family] / [event_kind]
   were previously two free strings. They are now derived from a closed
   sum [Workspace_telemetry_drop_event.t] mirroring the [Read_drop_reason.t]
   pattern of RFC-0044. The counter itself is retained — per RFC-0088
   §4.1 the "event itself is the telemetry payload" and the caller is a
   fire-and-forget lifecycle hook with no [Result.t] chain to propagate
   to. But the label cardinality is now compiler-bounded so a new emit
   site cannot silently widen it. *)
let warn_telemetry_drop ~(event : Workspace_telemetry_drop_event.t) exn =
  let exn_str = Printexc.to_string exn in
  let event_family = Workspace_telemetry_drop_event.family_to_wire event in
  let event_kind = Workspace_telemetry_drop_event.kind_to_wire event in
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
  Telemetry_observe.observe_silent ~kind:"workspace_telemetry_drop_log" (fun () ->
    Log.Workspace.emit
      Log.Warn
      ~details
      (Printf.sprintf
         "telemetry/audit dropped (non-Eio context): %s/%s"
         event_family
         event_kind));
  Telemetry_observe.observe_silent ~kind:"workspace_telemetry_drop_metric" (fun () ->
    (Atomic.get Workspace_hooks.workspace_telemetry_drop_fn) event)
;;

module For_testing = struct
  let warn_telemetry_drop = warn_telemetry_drop
end

(* Exhaustive on [Masc_domain.task_action]: a new variant becomes a compile
   error here so the audit-log mapping cannot silently fall into the
   [Custom "task_<other>"] catch-all that the prior string-typed
   classifier produced. (#8605 family -- exhaustive-match template) *)


(* Orphan reconciliation — zombie cleanup needs Task storage mutation without
   a privileged synthetic actor. *)
let () =
  Atomic.set
    Workspace_hooks.reconcile_orphaned_task_fn
    (fun config ~task_id ~expected_assignee ~signal () ->
       let signal =
         match signal with
         | `Absent -> Workspace_task.Assignee_absent
         | `Inactive -> Workspace_task.Assignee_inactive
       in
       reconcile_orphaned_task_r config ~task_id ~expected_assignee ~signal ())
;;



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

(* #13460: cache desync invalidation counter. Workspace_broadcast emits this when
   it replaces an active-claim/release message for a terminal backlog task with
   a cache_invalidated broadcast.  Clear workspace-owned current_task caches so the
   same stale claim does not re-emit every taskmaster cycle.  Keep labels
   fleet-bounded; the task id stays in the replacement message/event, not the
   Otel_metric_store series key. *)
let record_cache_desync_cleared config ~module_name:_ ~task_id ~status =
  if not (String.equal status "backlog_unavailable")
  then clear_agent_current_task_cache config ~task_id
;;

let () = Atomic.set Workspace_hooks.cache_desync_cleared_fn record_cache_desync_cleared




(* Hebbian learning — strengthen on task completion.
   Also emits activity events so strengthens appear in the
   activity graph / telemetry surface alongside task events. *)
let () =
  Atomic.set Workspace_hooks.hebbian_on_task_done_fn (fun config ~assignee ~active_agents ->
    List.iter
      (fun peer ->
         if peer <> assignee
         then
           Safe_ops.protect ~default:() (fun () ->
             (Atomic.get Workspace_hooks.activity_emit_fn)
               config
               ~actor:Workspace_hooks.{ kind = "agent"; id = assignee }
               ~subject:Workspace_hooks.{ kind = "agent"; id = peer }
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
    Workspace_hooks.hebbian_on_task_cancelled_fn
    (fun config ~agent_name ~active_agents ->
       List.iter
         (fun peer ->
            if peer <> agent_name
            then
              Safe_ops.protect ~default:() (fun () ->
                (Atomic.get Workspace_hooks.activity_emit_fn)
                  config
                  ~actor:Workspace_hooks.{ kind = "agent"; id = agent_name }
                  ~subject:Workspace_hooks.{ kind = "agent"; id = peer }
                  ~kind:"hebbian.weaken"
                  ~payload:
                    (`Assoc [ "from_agent", `String agent_name; "to_agent", `String peer ])
                  ~tags:[ "hebbian"; "weaken"; "memory" ]
                  ()))
         active_agents)
;;




(* Agent status, capability registration, discovery *)
include Workspace_agent

(* Workspace_multi removed — operational namespace is always "default" *)
(* Workspace_vote, Workspace_tempo removed — dead prod code (Epic #7261 Step 5 audit). *)
