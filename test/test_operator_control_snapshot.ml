open Masc_mcp
open Test_operator_control_support

let test_snapshot_has_expected_sections () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      ignore (Room.add_task config ~title:"operator backlog" ~priority:2 ~description:"");
      ignore (Room.broadcast config ~from_agent:"owner" ~content:"operator snapshot seed");
      let json = Operator_control.snapshot_json (operator_ctx env sw config "owner") in
      let namespace = Yojson.Safe.Util.member "namespace" json in
      Alcotest.(check bool) "namespace present" true
        (Yojson.Safe.Util.member "namespace" json <> `Null);
      Alcotest.(check bool) "namespace initialized" true
        Yojson.Safe.Util.(namespace |> member "initialized" |> to_bool);
      Alcotest.(check bool) "project nonempty" true
        (String.trim Yojson.Safe.Util.(namespace |> member "project" |> to_string) <> "");
      Alcotest.(check string) "namespace field flattened default" "default"
        Yojson.Safe.Util.(namespace |> member "namespace" |> to_string);
      Alcotest.(check string) "namespace_id flattened default" "default"
        Yojson.Safe.Util.(namespace |> member "namespace_id" |> to_string);
      Alcotest.(check string) "namespace exposed" "default"
        Yojson.Safe.Util.(namespace |> member "namespace" |> to_string);
      Alcotest.(check string) "namespace mode flattened" "flattened"
        Yojson.Safe.Util.(namespace |> member "namespace_mode" |> to_string);
      Alcotest.(check bool) "sessions present" true
        (Yojson.Safe.Util.member "sessions" json <> `Null);
      Alcotest.(check bool) "keepers present" true
        (Yojson.Safe.Util.member "keepers" json <> `Null);
      Alcotest.(check bool) "recent_messages present" true
        (Yojson.Safe.Util.member "recent_messages" json <> `Null);
      Alcotest.(check bool) "pending_confirms present" true
        (Yojson.Safe.Util.member "pending_confirms" json <> `Null);
      Alcotest.(check bool) "trace_id present" true
        (json |> Yojson.Safe.Util.member "trace_id" |> Yojson.Safe.Util.to_string
       <> "");
      Alcotest.(check string) "server profile" "operator_remote_v1"
        (json |> Yojson.Safe.Util.member "server_profile"
         |> Yojson.Safe.Util.member "name" |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "attention summary present" true
        (Yojson.Safe.Util.member "attention_summary" json <> `Null);
      Alcotest.(check bool) "recommendation summary present" true
        (Yojson.Safe.Util.member "recommendation_summary" json <> `Null);
      Alcotest.(check bool) "operator judge runtime present" true
        (Yojson.Safe.Util.member "operator_judge_runtime" json <> `Null);
      Alcotest.(check bool) "operator judge enabled by default" true
        Yojson.Safe.Util.
          (json |> member "operator_judge_runtime" |> member "enabled" |> to_bool);
      Alcotest.(check string) "judgment owner" "fallback_read_model"
        Yojson.Safe.Util.(json |> member "judgment_owner" |> to_string);
      Alcotest.(check bool) "no authoritative judgment" false
        Yojson.Safe.Util.(json |> member "authoritative_judgment_available" |> to_bool);
      Alcotest.(check string) "command plane provenance" "truth"
        Yojson.Safe.Util.
          (json |> member "provenance_summary" |> member "command_plane" |> to_string);
      Alcotest.(check bool) "recent_actions list present" true
        (match Yojson.Safe.Util.member "recent_actions" json with
        | `List _ -> true
        | _ -> false);
      Alcotest.(check bool) "swarm_status present" true
        (Yojson.Safe.Util.member "swarm_status" json <> `Null))

let test_snapshot_pending_confirm_summary_tracks_actor_scope () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      let ctx = operator_ctx env sw config "owner" in
      let request_namespace_pause actor =
        match
          Operator_control.action_json ctx
            (`Assoc
              [
                ("actor", `String actor);
                ("action_type", `String "namespace_pause");
                ("target_type", `String "namespace");
              ])
        with
        | Ok _ -> ()
        | Error err -> Alcotest.fail err
      in
      request_namespace_pause "operator-a";
      request_namespace_pause "operator-b";
      let snapshot = Operator_control.snapshot_json ~actor:"operator-a" ctx in
      let summary = Yojson.Safe.Util.(snapshot |> member "pending_confirm_summary") in
      Alcotest.(check string) "actor filter" "operator-a"
        Yojson.Safe.Util.(summary |> member "actor_filter" |> to_string);
      Alcotest.(check bool) "filter active" true
        Yojson.Safe.Util.(summary |> member "filter_active" |> to_bool);
      Alcotest.(check int) "visible count" 1
        Yojson.Safe.Util.(summary |> member "visible_count" |> to_int);
      Alcotest.(check int) "total count" 2
        Yojson.Safe.Util.(summary |> member "total_count" |> to_int);
      Alcotest.(check int) "hidden count" 1
        Yojson.Safe.Util.(summary |> member "hidden_count" |> to_int);
      Alcotest.(check bool) "hidden actor listed" true
        (List.mem (`String "operator-b")
           Yojson.Safe.Util.(summary |> member "hidden_actors" |> to_list));
      let confirm_required_actions =
        Yojson.Safe.Util.(summary |> member "confirm_required_actions" |> to_list)
      in
      Alcotest.(check bool) "namespace pause listed" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "action_type" |> to_string) = "namespace_pause")
           confirm_required_actions);
      Alcotest.(check bool) "team stop listed" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "action_type" |> to_string) = "team_stop")
           confirm_required_actions);
      Alcotest.(check bool) "task inject not listed" false
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "action_type" |> to_string) = "task_inject")
           confirm_required_actions))

let test_snapshot_caps_session_recent_events () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let session_id = start_session_exn (team_ctx env sw config "owner") in
      for seq = 1 to 5 do
        Team_session_store.append_event config session_id ~event_type:"team_turn"
          ~detail:(`Assoc [ ("seq", `Int seq) ])
      done;
      let snapshot = Operator_control.snapshot_json (operator_ctx env sw config "owner") in
      let sessions =
        Yojson.Safe.Util.(snapshot |> member "sessions" |> member "items" |> to_list)
      in
      let session_json =
        match
          List.find_opt
            (fun row ->
              Yojson.Safe.Util.(row |> member "session_id" |> to_string) = session_id)
            sessions
        with
        | Some row -> row
        | None -> Alcotest.fail "expected session in operator snapshot"
      in
      let recent_events =
        Yojson.Safe.Util.(session_json |> member "recent_events" |> to_list)
      in
      Alcotest.(check int) "recent events capped at 3" 3 (List.length recent_events);
      let seqs =
        List.map
          (fun row ->
            Yojson.Safe.Util.(row |> member "detail" |> member "seq" |> to_int))
          recent_events
      in
      Alcotest.(check (list int)) "recent events keep tail" [ 3; 4; 5 ] seqs)

let test_snapshot_summary_view_can_omit_command_plane () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let json =
        Operator_control.snapshot_json ~view:"summary"
          ~include_messages:false ~include_command_plane:false
          (operator_ctx env sw config "owner")
      in
      Alcotest.(check bool) "command_plane omitted" true
        (Yojson.Safe.Util.member "command_plane" json = `Null);
      Alcotest.(check bool) "swarm_status omitted" true
        (Yojson.Safe.Util.member "swarm_status" json = `Null);
      Alcotest.(check bool) "attention summary still present" true
        (Yojson.Safe.Util.member "attention_summary" json <> `Null);
      Alcotest.(check bool) "recommendation summary still present" true
        (Yojson.Safe.Util.member "recommendation_summary" json <> `Null))

let test_snapshot_lightweight_summary_omits_heavy_activity () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let json =
        Operator_control.snapshot_json ~view:"summary"
          ~include_keepers:true ~include_messages:true ~include_command_plane:false
          ~lightweight_summary:true
          (operator_ctx env sw config "owner")
      in
      let keepers =
        Yojson.Safe.Util.(json |> member "keepers" |> member "items" |> to_list)
      in
      List.iter
        (fun keeper ->
          Alcotest.(check int) "lightweight recent_activity omitted" 0
            Yojson.Safe.Util.(keeper |> member "recent_activity" |> to_list |> List.length))
        keepers;
      Alcotest.(check int) "lightweight recent_messages omitted" 0
        Yojson.Safe.Util.(json |> member "recent_messages" |> to_list |> List.length);
      Alcotest.(check int) "lightweight recent_actions omitted" 0
        Yojson.Safe.Util.(json |> member "recent_actions" |> to_list |> List.length))

let test_digest_team_session_tolerates_null_nested_status () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let session_id = start_session_exn (team_ctx env sw config "owner") in
      let session =
        match Team_session_store.load_session config session_id with
        | Some session -> session
        | None -> Alcotest.fail "expected persisted team session"
      in
      let digest =
        Operator_digest.build_session_digest
          ~status_json:
            (`Assoc
              [
                ("session", `Null);
                ("summary", `Null);
                ("team_health", `Null);
                ("local_runtime", `Null);
              ])
          config session ~now:(Time_compat.now ())
      in
      Alcotest.(check string) "session status falls back to persisted session state"
        (Team_session_types.status_to_string session.status)
        digest.status;
      Alcotest.(check string) "health falls back to neutral" "ok" digest.health)

let test_snapshot_lightweight_summary_caps_completed_sessions_by_recency () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let team = team_ctx env sw config "owner" in
      let now = Time_compat.now () in
      let update_session_exn session_id f =
        match Team_session_store.update_session config session_id f with
        | Ok _ -> ()
        | Error err -> Alcotest.fail err
      in
      let running_session_id = start_session_exn team in
      let paused_session_id = start_session_exn team in
      update_session_exn paused_session_id (fun session ->
          {
            session with
            status = Team_session_types.Paused;
            updated_at_iso = iso_of_unix (now -. 2.0);
          });
      let completed_session started_at updated_at =
        let session_id = start_session_exn team in
        update_session_exn session_id (fun session ->
            {
              session with
              status = Team_session_types.Completed;
              started_at;
              planned_end_at = started_at +. 120.0;
              stopped_at = Some updated_at;
              last_event_at = Some updated_at;
              updated_at_iso = iso_of_unix updated_at;
            });
        session_id
      in
      let recent_long_session_id =
        completed_session (now -. 10_000.0) (now -. 1.0)
      in
      let _recent_completed_a = completed_session (now -. 10.0) (now -. 10.0) in
      let _recent_completed_b = completed_session (now -. 20.0) (now -. 20.0) in
      let _recent_completed_c = completed_session (now -. 30.0) (now -. 30.0) in
      let _recent_completed_d = completed_session (now -. 40.0) (now -. 40.0) in
      let oldest_completed_session_id =
        completed_session (now -. 50.0) (now -. 50.0)
      in
      let json =
        Operator_control.snapshot_json ~view:"summary"
          ~include_keepers:false ~include_messages:false ~include_command_plane:false
          ~lightweight_summary:true
          (operator_ctx env sw config "owner")
      in
      let session_ids =
        Yojson.Safe.Util.(json |> member "sessions" |> member "items" |> to_list)
        |> List.map (fun row -> Yojson.Safe.Util.(row |> member "session_id" |> to_string))
      in
      Alcotest.(check int) "lightweight summary keeps active plus 5 recent completed" 7
        (List.length session_ids);
      Alcotest.(check bool) "running session preserved" true
        (List.mem running_session_id session_ids);
      Alcotest.(check bool) "paused session preserved" true
        (List.mem paused_session_id session_ids);
      Alcotest.(check bool) "recency beats early start time" true
        (List.mem recent_long_session_id session_ids);
      Alcotest.(check bool) "oldest completed session capped out" false
        (List.mem oldest_completed_session_id session_ids))

let test_snapshot_waiters_share_inflight_result () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio_guard.enable ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      Operator_control.invalidate_snapshot_cache ();
      let ctx = operator_ctx env sw config "owner" in
      ignore (Operator_control.snapshot_json ctx);
      let cache_key =
        Eio.Mutex.use_rw ~protect:true Operator_control_snapshot._snapshot_mu
          (fun () ->
            match
              Hashtbl.to_seq_keys Operator_control_snapshot._snapshot_table
              |> List.of_seq
            with
            | key :: _ -> key
            | [] -> Alcotest.fail "expected primed snapshot cache key")
      in
      Operator_control.invalidate_snapshot_cache ();
      let cond = Eio.Condition.create () in
      Eio.Mutex.use_rw ~protect:true Operator_control_snapshot._snapshot_mu
        (fun () ->
          Hashtbl.replace Operator_control_snapshot._snapshot_table cache_key
            (Operator_control_snapshot.Computing { cond }));
      let waiter_a, resolve_waiter_a = Eio.Promise.create () in
      let waiter_b, resolve_waiter_b = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.resolve resolve_waiter_a (Operator_control.snapshot_json ctx));
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.resolve resolve_waiter_b (Operator_control.snapshot_json ctx));
      Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
      let shared =
        `Assoc
          [
            ("trace_id", `String "shared-trace");
            ("status", `String "ok");
          ]
      in
      Eio.Mutex.use_rw ~protect:true Operator_control_snapshot._snapshot_mu
        (fun () ->
          Hashtbl.replace Operator_control_snapshot._snapshot_table cache_key
            (Operator_control_snapshot.Cached
               {
                 value = shared;
                 expires_at =
                   Time_compat.now () +. Operator_control_snapshot._snapshot_ttl_s;
               }));
      Eio.Condition.broadcast cond;
      let first = Eio.Promise.await waiter_a in
      let second = Eio.Promise.await waiter_b in
      Alcotest.(check string) "waiter a shared trace" "shared-trace"
        Yojson.Safe.Util.(first |> member "trace_id" |> to_string);
      Alcotest.(check string) "waiter b shared trace" "shared-trace"
        Yojson.Safe.Util.(second |> member "trace_id" |> to_string);
      let cached_retained =
        Eio.Mutex.use_rw ~protect:true Operator_control_snapshot._snapshot_mu
          (fun () ->
            match
              Hashtbl.find_opt Operator_control_snapshot._snapshot_table cache_key
            with
            | Some (Operator_control_snapshot.Cached _) -> true
            | _ -> false)
      in
      Alcotest.(check bool) "healthy inflight slot not evicted" true cached_retained)

let test_orchestra_room_core_shape () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      ignore (Room.add_task config ~title:"orchestra backlog" ~priority:2 ~description:"");
      ignore (Room.broadcast config ~from_agent:"owner" ~content:"orchestra seed");
      let json = Command_plane_orchestra.json (operator_ctx env sw config "owner") in
      let nodes = Yojson.Safe.Util.(json |> member "nodes" |> to_list) in
      Alcotest.(check bool) "namespace node exists" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "kind" |> to_string) = "namespace")
           nodes);
      Alcotest.(check bool) "namespace block present" true
        (Yojson.Safe.Util.member "namespace" json <> `Null);
      Alcotest.(check int) "session count" 0
        Yojson.Safe.Util.(json |> member "summary" |> member "session_count" |> to_int);
      Alcotest.(check string) "focus kind" "node"
        Yojson.Safe.Util.(json |> member "focus" |> member "target_kind" |> to_string))

let test_orchestra_includes_session_edge_and_pending_signal () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let session_id = start_session_exn (team_ctx env sw config "owner") in
      let ctx = operator_ctx env sw config "dashboard" in
      (match
         Operator_control.action_json ctx
           (`Assoc
             [
               ("actor", `String "dashboard");
               ("action_type", `String "namespace_pause");
               ("target_type", `String "namespace");
             ])
       with
      | Ok _ -> ()
      | Error err -> Alcotest.fail err);
      let json = Command_plane_orchestra.json ctx in
      let nodes = Yojson.Safe.Util.(json |> member "nodes" |> to_list) in
      let edges = Yojson.Safe.Util.(json |> member "edges" |> to_list) in
      let signals = Yojson.Safe.Util.(json |> member "signals" |> to_list) in
      Alcotest.(check bool) "session node exists" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "id" |> to_string) = "session:" ^ session_id)
           nodes);
      Alcotest.(check bool) "room-session edge exists" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "source" |> to_string) = "namespace:default"
             && Yojson.Safe.Util.(row |> member "target" |> to_string)
                = "session:" ^ session_id)
           edges);
      Alcotest.(check bool) "pending confirm signal exists" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "kind" |> to_string) = "pending_confirm")
           signals))

let test_digest_room_exposes_pending_confirm_attention () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let ctx = operator_ctx env sw config "operator" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "operator");
               ("action_type", `String "namespace_pause");
               ("target_type", `String "namespace");
            ])
      in
      (match action_json with Ok _ -> () | Error err -> Alcotest.fail err);
      let digest =
        match Operator_control.digest_json ~actor:"operator" ctx with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "target_type" "namespace"
        Yojson.Safe.Util.(digest |> member "target_type" |> to_string);
      Alcotest.(check string) "health" "warn"
        Yojson.Safe.Util.(digest |> member "health" |> to_string);
      Alcotest.(check bool) "command_plane present" true
        (Yojson.Safe.Util.member "command_plane" digest <> `Null);
      Alcotest.(check bool) "operator judge runtime present" true
        (Yojson.Safe.Util.member "operator_judge_runtime" digest <> `Null);
      Alcotest.(check bool) "command_plane microarch present" true
        (Yojson.Safe.Util.
           (digest |> member "command_plane" |> member "operations"
          |> member "microarch")
         <> `Null);
      Alcotest.(check bool) "swarm_status present" true
        (Yojson.Safe.Util.member "swarm_status" digest <> `Null);
      let attention_items = Yojson.Safe.Util.(digest |> member "attention_items" |> to_list) in
      let review_queue = Yojson.Safe.Util.(digest |> member "review_queue" |> to_list) in
      Alcotest.(check bool) "pending confirm attention present" true
        (List.exists
           (fun item ->
             Yojson.Safe.Util.(item |> member "kind" |> to_string)
             = "pending_confirm_waiting")
           attention_items);
      Alcotest.(check bool) "review queue has pending confirm" true
        (List.exists
           (fun item ->
             Yojson.Safe.Util.(item |> member "kind" |> to_string)
             = "pending_confirm")
           review_queue);
      Alcotest.(check int) "review summary active count" 1
        Yojson.Safe.Util.(digest |> member "review_summary" |> member "active_count" |> to_int);
      Alcotest.(check bool) "attention provenance present" true
        (List.for_all
           (fun item ->
             String.equal "derived"
               Yojson.Safe.Util.(item |> member "provenance" |> to_string))
           attention_items);
      (* command_* attention items only appear when microarch signals
         are warn/bad; in a fresh room they are absent *)
      Alcotest.(check bool) "no command attention in fresh room" true
        (not
           (List.exists
              (fun item ->
                String.starts_with
                  ~prefix:"command_"
                  Yojson.Safe.Util.(item |> member "kind" |> to_string))
              attention_items)))

let test_digest_team_session_shape () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let session_id = start_session_exn (team_ctx env sw config "owner") in
      let ctx = operator_ctx env sw config "dashboard" in
      let digest =
        match
          Operator_control.digest_json ~actor:"dashboard"
            ~target_type:"team_session" ~target_id:session_id ctx
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "target_type" "team_session"
        Yojson.Safe.Util.(digest |> member "target_type" |> to_string);
      Alcotest.(check string) "target_id" session_id
        Yojson.Safe.Util.(digest |> member "target_id" |> to_string);
      Alcotest.(check string) "recommendation provenance summary" "fallback"
        Yojson.Safe.Util.
          (digest |> member "provenance_summary" |> member "recommended_actions"
         |> to_string);
      Alcotest.(check bool) "swarm_status present" true
        (Yojson.Safe.Util.member "swarm_status" digest <> `Null);
      Alcotest.(check bool) "command_plane present" true
        (Yojson.Safe.Util.member "command_plane" digest <> `Null);
      Alcotest.(check int) "single session card" 1
        Yojson.Safe.Util.(digest |> member "session_cards" |> to_list |> List.length);
      Alcotest.(check bool) "worker_cards list" true
        (match Yojson.Safe.Util.member "worker_cards" digest with
        | `List _ -> true
        | _ -> false))

let test_digest_room_includes_tool_host_failure_attention () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      Dashboard_tool_host_events.record ~fs:() config
        {
          Dashboard_tool_host_events.agent_name = "codex";
          client_name = "codex";
          tool_name = "masc_keeper_msg";
          transport = "mcp_http";
          phase = Some "tools/call";
          message = "timed out awaiting tools/call after 90s";
          request_id = Some "opsd-toolhost-1";
          session_id = Some "sess-toolhost-1";
          trace_id = Some "trace-toolhost-1";
          timeout_ms = Some 90000;
        };
      let digest =
        match Operator_control.digest_json ~actor:"dashboard"
                (operator_ctx env sw config "dashboard")
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      let attention_items =
        Yojson.Safe.Util.(digest |> member "attention_items" |> to_list)
      in
      let tool_host_attention =
        List.find_opt
          (fun item ->
            Yojson.Safe.Util.(item |> member "kind" |> to_string)
            = "tool_host_timeout"
            && Yojson.Safe.Util.
                 (item |> member "evidence" |> member "failure_envelope"
                |> member "evidence_ref" |> member "request_id" |> to_string)
               = "opsd-toolhost-1")
          attention_items
      in
      let item =
        match tool_host_attention with
        | Some item -> item
        | None -> Alcotest.fail "expected tool host attention item"
      in
      Alcotest.(check string) "tool host severity" "bad"
        Yojson.Safe.Util.(item |> member "severity" |> to_string);
      Alcotest.(check string) "tool host operator action" "masc_operator_digest"
        Yojson.Safe.Util.
          (item |> member "evidence" |> member "failure_envelope"
         |> member "operator_action" |> to_string))

let test_operator_digest_severity_rank_supports_critical () =
  Alcotest.(check int) "critical rank" 3
    (Operator_digest.severity_rank "critical");
  Alcotest.(check bool) "critical outranks bad" true
    (Operator_digest.severity_rank "critical"
    > Operator_digest.severity_rank "bad")

let test_digest_team_session_can_skip_workers () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let session_id = start_session_exn (team_ctx env sw config "owner") in
      let ctx = operator_ctx env sw config "dashboard" in
      let digest =
        match
          Operator_control.digest_json ~actor:"dashboard"
            ~target_type:"team_session" ~target_id:session_id ~include_workers:false
            ctx
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check int) "worker_cards skipped" 0
        Yojson.Safe.Util.(digest |> member "worker_cards" |> to_list |> List.length))

let test_snapshot_and_digest_expose_role_runtime_census () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let session_id = start_session_exn (team_ctx env sw config "owner") in
      let update_result =
        Team_session_store.update_session config session_id (fun session ->
            {
              session with
              planned_workers =
                [
                  {
                    Team_session_types.spawn_agent = "llama";
                    runtime_actor = Some "llama-local-manager";
                    spawn_role = Some "middle-manager";
                    spawn_model = Some "qwen3.5";
                    execution_scope = Some Team_session_types.Observe_only;
                    worker_class = Some Team_session_types.Worker_manager;
                    parent_actor = None;
                    capsule_mode = Some Team_session_types.Capsule_capsule;
                    runtime_pool = Some "local64";
                    lane_id = Some "lane-a";
                    controller_level = Some Team_session_types.Controller_lane;
                    control_domain = Some Team_session_types.Domain_execution;
                    supervisor_actor = Some "ctrl-root";
                    task_profile = Some Team_session_types.Profile_decide;
                    risk_level = Some Team_session_types.Risk_high;
                    routing_confidence = Some 0.94;
                    routing_reason = Some "explicit:lead_manager";
                    thinking_enabled = None;
                    thinking_budget = None;
                    max_turns = None;
                    timeout_seconds = None;
                    routing_escalated = false;
                  };
                  {
                    Team_session_types.spawn_agent = "llama";
                    runtime_actor = Some "llama-local-metacog";
                    spawn_role = Some "metacog-observer";
                    spawn_model = Some "qwen3.5";
                    execution_scope = Some Team_session_types.Observe_only;
                    worker_class = Some Team_session_types.Worker_metacog;
                    parent_actor = Some "llama-local-manager";
                    capsule_mode = Some Team_session_types.Capsule_capsule;
                    runtime_pool = Some "local64";
                    lane_id = Some "global";
                    controller_level = Some Team_session_types.Controller_submanager;
                    control_domain = Some Team_session_types.Domain_meta;
                    supervisor_actor = Some "ctrl-global-metacog";
                    task_profile = Some Team_session_types.Profile_verify;
                    risk_level = Some Team_session_types.Risk_high;
                    routing_confidence = Some 0.88;
                    routing_reason = Some "policy:metacog_guard";
                    thinking_enabled = None;
                    thinking_budget = None;
                    max_turns = None;
                    timeout_seconds = None;
                    routing_escalated = true;
                  };
                  {
                    Team_session_types.spawn_agent = "llama";
                    runtime_actor = Some "llama-local-executor";
                    spawn_role = Some "executor-1";
                    spawn_model = Some "qwen3.5";
                    execution_scope = Some Team_session_types.Limited_code_change;
                    worker_class = Some Team_session_types.Worker_executor;
                    parent_actor = Some "llama-local-manager";
                    capsule_mode = Some Team_session_types.Capsule_inherit;
                    runtime_pool = Some "local64";
                    lane_id = Some "lane-a";
                    controller_level = Some Team_session_types.Controller_worker;
                    control_domain = Some Team_session_types.Domain_execution;
                    supervisor_actor = Some "ctrl-lane-a";
                    task_profile = Some Team_session_types.Profile_normalize;
                    risk_level = Some Team_session_types.Risk_low;
                    routing_confidence = Some 0.83;
                    routing_reason = Some "rule:machine_checkable";
                    thinking_enabled = None;
                    thinking_budget = None;
                    max_turns = None;
                    timeout_seconds = None;
                    routing_escalated = false;
                  };
                ];
              updated_at_iso = Types.now_iso ();
            })
      in
      (match update_result with Ok _ -> () | Error err -> Alcotest.fail err);
      let ctx = operator_ctx env sw config "dashboard" in
      let snapshot = Operator_control.snapshot_json ctx in
      Alcotest.(check int) "room role census manager" 1
        Yojson.Safe.Util.(snapshot |> member "role_census" |> member "manager" |> to_int);
      Alcotest.(check int) "room role census metacog" 1
        Yojson.Safe.Util.(snapshot |> member "role_census" |> member "metacog" |> to_int);
      Alcotest.(check int) "room runtime pool local64" 3
        Yojson.Safe.Util.(snapshot |> member "runtime_pools" |> member "local64" |> to_int);
      Alcotest.(check int) "room task profile normalize" 1
        Yojson.Safe.Util.(snapshot |> member "task_profiles" |> member "normalize" |> to_int);
      Alcotest.(check int) "room escalation count" 1
        Yojson.Safe.Util.(snapshot |> member "escalation_count" |> to_int);
      let digest =
        match
          Operator_control.digest_json ~actor:"dashboard"
            ~target_type:"team_session" ~target_id:session_id ctx
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      let session_card = Yojson.Safe.Util.(digest |> member "session_cards" |> index 0) in
      Alcotest.(check string) "scale_profile" "standard"
        Yojson.Safe.Util.(session_card |> member "scale_profile" |> to_string);
      Alcotest.(check int) "session card manager count" 1
        Yojson.Safe.Util.
          (session_card |> member "worker_class_counts" |> member "manager" |> to_int);
      Alcotest.(check int) "session card metacog count" 1
        Yojson.Safe.Util.
          (session_card |> member "worker_class_counts" |> member "metacog" |> to_int);
      Alcotest.(check int) "session card runtime pool local64" 3
        Yojson.Safe.Util.
          (session_card |> member "runtime_pool_counts" |> member "local64" |> to_int);
      Alcotest.(check int) "session card profile decide count" 1
        Yojson.Safe.Util.
          (session_card |> member "task_profile_counts" |> member "decide" |> to_int);
      Alcotest.(check int) "session card escalation count" 1
        Yojson.Safe.Util.(session_card |> member "escalation_count" |> to_int);
      let worker_cards = Yojson.Safe.Util.(digest |> member "worker_cards" |> to_list) in
      let manager_card =
        match
          List.find_opt
            (fun card ->
              Yojson.Safe.Util.(card |> member "actor" |> to_string)
              = "llama-local-manager")
            worker_cards
        with
        | Some card -> card
        | None -> Alcotest.fail "expected manager worker card"
      in
      Alcotest.(check string) "manager card task profile" "decide"
        Yojson.Safe.Util.(manager_card |> member "task_profile" |> to_string);
      Alcotest.(check string) "manager card risk level" "high"
        Yojson.Safe.Util.(manager_card |> member "risk_level" |> to_string))
