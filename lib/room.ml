(** MASC Room - Core coordination hub.

    This module ties together all Room sub-modules and provides
    cross-cutting functions that depend on multiple sub-modules. *)

(* Foundation: utilities and state management *)
include Room_utils
include Room_state

(* Agent join/leave lifecycle *)
include Room_lifecycle

(* Room initialization, reset, pause, resume (without auto-join) *)
include Room_init

(** Initialize MASC room with optional auto-join.
    Wraps [Room_init.init] and calls [join] when [agent_name] is provided. *)
let init config ~agent_name =
  let result = Room_init.init config ~agent_name in
  if result = "MASC already initialized." then result
  else
    match agent_name with
    | Some name -> result ^ "\n" ^ (join config ~agent_name:name ~capabilities:[] ())
    | None -> result

(* Room status display *)
include Room_status

(* Task lifecycle: add, claim, transition, complete, cancel *)
include Room_task

(* Task scheduling: claim_next, release_stale_claims *)
include Room_task_schedule

(* Task/agent/message query and listing *)
include Room_query

(* Portal / A2A Protocol *)
include Room_portal

(* Git Worktree *)
include Room_worktree

(* Heartbeat & GC *)
include Room_gc

(* ============================================ *)
(* Wire Room_hooks callbacks                    *)
(* ============================================ *)

let telemetry_enabled () = Env_config_core.telemetry_enabled ()

let merge_detail_fields fields details =
  match details with
  | `Assoc extra -> `Assoc (fields @ extra)
  | `Null -> `Assoc fields
  | other -> `Assoc (fields @ [ ("payload", other) ])

let task_action_of_transition = function
  | "claim" -> Audit_log.ClaimTask
  | "start" -> Audit_log.StartTask
  | "done" -> Audit_log.DoneTask
  | "cancel" -> Audit_log.CancelTask
  | "release" -> Audit_log.ReleaseTask
  | other -> Audit_log.Custom ("task_" ^ other)

let observe_agent_lifecycle config ~agent_id ~event_kind ~details =
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
    match event_kind with
    | "leave" -> Log.Info
    | _ -> Log.Info
  in
  let message =
    match event_kind with
    | "rejoin" -> Printf.sprintf "agent rejoined: %s" agent_id
    | "leave" -> Printf.sprintf "agent left: %s" agent_id
    | _ -> Printf.sprintf "agent joined: %s" agent_id
  in
  Log.emit level ~module_name:"Room" ~details message;
  (match event_kind with
   | "leave" -> Prometheus.dec_gauge "masc_active_agents" ()
   | "join" | "rejoin" -> Prometheus.inc_gauge "masc_active_agents" ()
   | _ -> ());
  let audit_details =
    match event_kind with
    | "rejoin" -> merge_detail_fields [ ("rejoin", `Bool true) ] details
    | _ -> details
  in
  let action =
    match event_kind with
    | "leave" -> Audit_log.Leave
    | _ -> Audit_log.Join
  in
  (* Audit and telemetry require Eio context (Eio.Mutex).
     Silently skip when running in non-Eio test context. *)
  (try
    Audit_log.log_action config ~agent_id ~action
      ~details:audit_details ~outcome:Audit_log.Success ();
    if telemetry_enabled () then
      match event_kind with
      | "leave" -> Telemetry_eio.track_agent_left config ~agent_id ~reason:"leave"
      | "rejoin" ->
          Telemetry_eio.track_agent_joined config ~agent_id ()
      | _ -> Telemetry_eio.track_agent_joined config ~agent_id ()
  with Stdlib.Effect.Unhandled _ -> ())

let observe_task_transition_event config ~agent_name ~task_id
    ~transition ~details =
  let details =
    merge_detail_fields
      [
        ("event_family", `String "task_transition");
        ("transition", `String transition);
        ("task_id", `String task_id);
        ("agent_id", `String agent_name);
      ]
      details
  in
  let level =
    match transition with
    | "cancel" -> Log.Warn
    | _ -> Log.Info
  in
  let message =
    Printf.sprintf "task %s %s by %s" task_id transition agent_name
  in
  Log.emit level ~module_name:"Task" ~details message;
  (try
    Audit_log.log_action config ~agent_id:agent_name
      ~action:(task_action_of_transition transition)
      ~details ~outcome:Audit_log.Success ();
    if telemetry_enabled () then
      match transition with
      | "start" ->
          Telemetry_eio.track_task_started config ~task_id ~agent_id:agent_name
      | "done" | "cancel" ->
          let duration_ms =
            Safe_ops.json_int ~default:0 "duration_ms" details
          in
          Telemetry_eio.track_task_completed config ~task_id ~duration_ms
            ~success:(String.equal transition "done")
      | _ -> ()
  with Stdlib.Effect.Unhandled _ -> ())

(* force_release_task — zombie cleanup needs task management logic *)
let () = Room_hooks.force_release_task_fn :=
  (fun config ~agent_name ~task_id () ->
    force_release_task_r config ~agent_name ~task_id ())

(* Activity graph emit — wraps Activity_graph for room sub-modules *)
let () = Room_hooks.activity_emit_fn :=
  (fun config ~actor ?subject ~kind ~payload ~tags () ->
    (try
      ignore (Activity_graph.emit config
        ~actor:(Activity_graph.entity ~kind:actor.Room_hooks.kind actor.id)
        ?subject:(Option.map (fun (s : Room_hooks.activity_entity) ->
          Activity_graph.entity ~kind:s.kind s.id) subject)
        ~kind ~payload ~tags ())
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn -> Log.Room.warn "activity_graph emit failed: %s" (Printexc.to_string exn)))

(* Agent economy earn — wraps Agent_economy for task completion credits *)
let () = Room_hooks.agent_economy_earn_fn :=
  (fun ~base_path ~agent_name ~reason ->
    match Agent_economy.earn ~base_path ~agent_name
      ~kind:Earn_task_done ~reason () with
    | Ok _bal -> ()
    | Error msg -> Log.Misc.error "task earn failed: %s" msg)

(* Relation materializer — agent leave *)
let () = Room_hooks.relation_on_leave_fn := Relation_materializer.on_agent_leave

(* Relation materializer — task done *)
let () = Room_hooks.relation_on_task_done_fn := Relation_materializer.on_task_done

let () = Room_hooks.observe_agent_lifecycle_fn :=
  (fun config ~agent_id ~event_kind ~details ->
    observe_agent_lifecycle config ~agent_id ~event_kind ~details)

let () = Room_hooks.observe_task_transition_fn :=
  (fun config ~agent_name ~task_id ~transition ~details ->
    !Room_hooks.on_task_mutation_fn ();
    observe_task_transition_event config ~agent_name ~task_id
      ~transition ~details)

(* Board artifact cleanup — wraps Board_dispatch for GC *)
let () = Room_hooks.cleanup_board_artifacts_fn := (fun () ->
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
let () = Room_hooks.subscribe_messages_fn := (fun ~subscriber ->
  let _ = Subscriptions.SubscriptionStore.subscribe
    ~subscriber ~resource:Subscriptions.Messages () in ())

(* Agent status, capability registration, discovery *)
include Room_agent

(* Consensus / Voting *)
include Room_vote

(* Tempo Control (Cluster Pace Management) *)
include Room_tempo

(* Room_multi removed — operational namespace is always "default" *)
