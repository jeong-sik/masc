open Masc_mcp
open Test_operator_control_support

let test_align_keeper_runtime_status_promotes_fresh_runtime_signal () =
  let status =
    Operator_control_snapshot.align_keeper_runtime_status
      ~surface_status:"inactive"
      ~diagnostic:(`Assoc [ ("health_state", `String "offline") ])
      ~agent_status_json:
        (`Assoc
          [
            ("status", `String "busy");
            ("last_seen_ago_s", `Float 5.0);
            ("is_zombie", `Bool false);
          ])
      ~keepalive_running:true
  in
  Alcotest.(check string) "fresh runtime signal promotes keeper status" "busy"
    status

let test_align_keeper_runtime_status_preserves_attention_health () =
  let status =
    Operator_control_snapshot.align_keeper_runtime_status
      ~surface_status:"inactive"
      ~diagnostic:(`Assoc [ ("health_state", `String "degraded") ])
      ~agent_status_json:
        (`Assoc
          [
            ("status", `String "active");
            ("last_seen_ago_s", `Float 5.0);
            ("is_zombie", `Bool false);
          ])
      ~keepalive_running:true
  in
  Alcotest.(check string) "degraded health remains inactive" "inactive" status

let test_align_keeper_runtime_status_ignores_zombie_runtime_signal () =
  let status =
    Operator_control_snapshot.align_keeper_runtime_status
      ~surface_status:"inactive"
      ~diagnostic:(`Assoc [ ("health_state", `String "offline") ])
      ~agent_status_json:
        (`Assoc
          [
            ("status", `String "active");
            ("last_seen_ago_s", `Float 5.0);
            ("is_zombie", `Bool true);
          ])
      ~keepalive_running:true
  in
  Alcotest.(check string) "zombie runtime does not override inactive" "inactive"
    status

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
      Alcotest.(check bool) "team stop still confirm required" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "action_type" |> to_string) = "team_stop")
           confirm_required_actions);
      Alcotest.(check bool) "task inject not listed" false
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "action_type" |> to_string) = "task_inject")
           confirm_required_actions))

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
    (Operator_digest.severity_rank Operator_digest.Sev_critical);
  Alcotest.(check bool) "critical outranks bad" true
    (Operator_digest.severity_rank Sev_critical
    > Operator_digest.severity_rank Sev_bad)

(* test_snapshot_and_digest_expose_role_runtime_census removed:
   depended on team session start/update which is no longer available. *)
