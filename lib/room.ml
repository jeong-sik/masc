(** MASC Room - Core coordination hub.

    This module ties together all Room sub-modules and provides
    cross-cutting functions that depend on multiple sub-modules
    (e.g. room_enter which calls join + leave + init). *)

open Types

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

(* Walph control system: state machine, loop, presets *)
include Room_walph_eio

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

(* force_release_task — zombie cleanup needs task management logic *)
let () = Room_hooks.force_release_task_fn :=
  (fun config ~agent_name ~task_id () ->
    force_release_task_r config ~agent_name ~task_id ())

(* Activity graph emit — wraps Activity_graph for room sub-modules *)
let () = Room_hooks.activity_emit_fn :=
  (fun config ~room_id ~actor ?subject ~kind ~payload ~tags () ->
    (try
      ignore (Activity_graph.emit config ~room_id
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
    || String.starts_with ~prefix:"qwen35-probe" author
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

(* Governance stale case purge — wraps Council.Governance_v2 for GC *)
let () = Room_hooks.governance_purge_fn := (fun base_path ->
  let test = Council.Governance_v2.purge_stale_test_cases base_path in
  let artifact = Council.Governance_v2.purge_stale_artifact_cases base_path in
  (test, artifact))

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

(* Multi-Room Management helpers *)
include Room_multi

(* Multi-Room high-level operations (list, create, ensure) *)
include Room_rooms

(** Enter a room (switch context).
    This function depends on [join], [leave], and [init] from multiple
    sub-modules, so it remains in the hub module. *)
let room_enter config ~room_id ?(agent_name="") ~agent_type () : Yojson.Safe.t =
  if not (root_is_initialized config) then
    `Assoc [("error", `String "MASC not initialized")]
  else begin
    (* Check if room exists *)
    let registry = load_registry config in
    let room_exists =
      room_id = "default" ||
      List.exists (fun (r : Types.room_info) -> r.id = room_id) registry.rooms
    in

    if not room_exists then
      `Assoc [("error", `String (Printf.sprintf "Room '%s' does not exist" room_id))]
    else begin
      let previous_room = read_current_room config in
      let trimmed_agent_name = String.trim agent_name in
      let effective_agent_name =
        if trimmed_agent_name <> "" then trimmed_agent_name else agent_type
      in

      (* If we have a concrete agent name, remove it from the previous room to avoid duplication. *)
      let should_auto_leave =
        trimmed_agent_name <> "" && is_agent_joined config ~agent_name:effective_agent_name
      in
      (match previous_room with
       | Some prev when prev <> room_id && should_auto_leave ->
           (try ignore (leave config ~agent_name:effective_agent_name)
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | e -> Log.Misc.error "room: auto-leave from %s failed: %s" prev (Printexc.to_string e))
       | _ -> ());

      (* Update current room file (for external tools) and create scoped config *)
      write_current_room config room_id;
      let target_scope = if room_id = "default" then Default else Named room_id in
      let scoped = with_scope config target_scope in

      (* Initialize the room on first entry (no auto-join). *)
      if not (is_initialized scoped) then
        (try ignore (Room_init.init scoped ~agent_name:None)
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | e -> Log.Misc.error "room: init failed for %s: %s" room_id (Printexc.to_string e));

      (* Join the new room using scoped config *)
      let join_result = join scoped ~agent_name:effective_agent_name ~capabilities:[] () in

      (* Extract nickname from join result (format: "  Nickname: xxx\n...") *)
      let nickname =
        try
          let prefix = "  Nickname: " in
          let start_idx =
            let idx = ref 0 in
            while !idx < String.length join_result - String.length prefix &&
                  String.sub join_result !idx (String.length prefix) <> prefix do
              incr idx
            done;
            !idx + String.length prefix
          in
          let end_idx = String.index_from join_result start_idx '\n' in
          String.sub join_result start_idx (end_idx - start_idx)
        with Not_found | Invalid_argument _ -> agent_type ^ "-unknown"
      in

      `Assoc [
        ("previous_room", match previous_room with Some r -> `String r | None -> `Null);
        ("current_room", `String room_id);
        ("nickname", `String nickname);
        ("message", `String (Printf.sprintf "✅ Entered room '%s' as %s" room_id nickname));
      ]
    end
  end
