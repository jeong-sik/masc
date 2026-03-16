(** Tool_protocol_game_view_handlers — handler functions for decision,
    experiment, trpg, and client domains. *)

open Tool_args

include Tool_protocol_game_view_utils

let handle_decision_create (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let issue = get_string args "issue" "" in
  let options = get_string_list args "options" in
  if issue = "" then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"issue is required" ())
  else if options = [] then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"options must have at least one entry" ())
  else
    let criteria = get_string_list args "criteria" in
    let weights = get_object_opt args "weights" in
    let decision =
      Game_view_state.create_decision ctx.config ~session_id ~issue ~options
        ~criteria ~weights
    in
    broadcast_decision_create_events ~agent:ctx.agent_name decision;
    Ok (ok_json ~canonical_tool (decision_payload decision))

let handle_decision_finalize (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let decision_id = get_string args "decision_id" "" in
  let selected_option = get_string args "selected_option" "" in
  let rationale = get_string args "rationale" "" in
  let verifier = String.uppercase_ascii (get_string args "verifier" "PASS") in
  let confidence = get_float_opt args "confidence" in
  let risk_ack = get_string_opt args "risk_ack" in
  if decision_id = "" then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"decision_id is required" ())
  else if selected_option = "" then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"selected_option is required" ())
  else if rationale = "" then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"rationale is required" ())
  else if verifier = "WARN" && Option.is_none risk_ack then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"risk_ack is required when verifier is WARN" ())
  else
    match
      Game_view_state.finalize_decision ctx.config ~session_id ~decision_id
        ~selected_option ~rationale ~confidence ~verifier ~risk_ack
    with
    | Ok finalized ->
        broadcast_decision_finalize_events ~agent:ctx.agent_name finalized;
        Ok (ok_json ~canonical_tool (decision_payload finalized))
    | Error msg ->
        let code =
          if String.starts_with ~prefix:"decision not found" msg then "NOT_FOUND"
          else "VALIDATION_ERROR"
        in
        Error (err_json ~canonical_tool ~code ~message:msg ())

let handle_decision_status (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let decision_id = get_string_opt args "decision_id" in
  let selected =
    match decision_id with
    | Some did -> (
        let all = Game_view_state.load_decisions ctx.config in
        List.find_opt
          (fun (d : Game_view_state.decision) ->
            d.session_id = session_id && d.decision_id = did)
          all)
    | None -> latest_decision_for_session ctx.config ~session_id
  in
  match selected with
  | Some d -> Ok (ok_json ~canonical_tool (decision_payload d))
  | None ->
      Error
        (err_json ~canonical_tool ~code:"NOT_FOUND"
           ~message:
             (Printf.sprintf "no decision found for session_id=%s" session_id)
           ())

let delegate_experiment (ctx : context) ~legacy_name ~args =
  let exp_ctx = experiment_context_of ctx in
  Tool_experiment.dispatch exp_ctx ~name:legacy_name ~args

let delegate_trpg (ctx : context) ~legacy_name ~args =
  let trpg_ctx = trpg_context_of ctx in
  Tool_trpg.dispatch trpg_ctx ~name:legacy_name ~args

let handle_experiment_canonical (ctx : context) ~canonical_tool ~legacy_name
    ~require_decision args : (tool_result, tool_result) result =
  let* () =
    if require_decision then
      let* _ = require_finalized_decision ctx ~canonical_tool args in
      Ok ()
    else Ok ()
  in
  let args =
    if legacy_name = "experiment_start" then normalize_experiment_start_args args
    else args
  in
  match delegate_experiment ctx ~legacy_name ~args with
  | Some (true, body) ->
      Ok (ok_json ~canonical_tool (parse_json_or_string body))
  | Some (false, msg) ->
      Error
        (err_json ~canonical_tool ~code:"LEGACY_ERROR" ~message:msg
           ~details:(`Assoc [ ("legacy_tool", `String legacy_name) ])
           ())
  | None ->
      Log.Dispatch.info "NOT_IMPLEMENTED: experiment %s (canonical: %s)"
        legacy_name canonical_tool;
      Error
        (err_json ~canonical_tool ~code:"NOT_IMPLEMENTED"
           ~message:(Printf.sprintf "legacy dispatcher unavailable: %s. Use canonical tool names from dispatch table." legacy_name)
           ())

let sanitize_room_id (s : string) =
  let b = Bytes.of_string s in
  for i = 0 to Bytes.length b - 1 do
    let c = Bytes.get b i in
    let valid =
      (c >= 'a' && c <= 'z')
      || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9')
      || c = '.' || c = '_' || c = '-'
    in
    if not valid then Bytes.set b i '-'
  done;
  let out = Bytes.to_string b in
  if out = "" then "session-default" else out

let next_event_seq ~base_dir ~room_id =
  match Trpg_engine_store.read_events ~base_dir ~room_id with
  | Ok [] -> 1
  | Ok events ->
      List.fold_left
        (fun acc (ev : Trpg_engine_event.t) -> max acc ev.seq)
        0 events
      + 1
  | Error _ -> 1

let append_event ~base_dir ~room_id ~seq ~event_type ~payload ?actor_id () =
  let event =
    Trpg_engine_event.make ~seq ~room_id ~ts:(Types.now_iso ()) ~event_type
      ?actor_id ~payload ()
  in
  Trpg_engine_store.append_event ~base_dir ~event

let handle_trpg_action_submit (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id, decision = require_finalized_decision ctx ~canonical_tool args in
  let action = get_string args "action" "" in
  if action = "" then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"action is required" ())
  else
    let intent = get_string args "intent" "unspecified" in
    let stakes = String.lowercase_ascii (get_string args "stakes" "medium") in
    let risk_delta =
      match stakes with
      | "low" -> 0.10
      | "medium" -> 0.25
      | "high" -> 0.50
      | _ -> 0.20
    in
    let room_id =
      get_string_opt args "room_id"
      |> Option.value
           ~default:(sanitize_room_id (Printf.sprintf "session-%s" session_id))
    in
    let base_dir = ctx.config.base_path in
    let story =
      Printf.sprintf
        "%s chose '%s' and performed '%s' with intent '%s' (stakes=%s)."
        session_id
        (Option.value ~default:"n/a" decision.selected_option)
        action intent stakes
    in
    let proposed_payload =
      `Assoc
        [
          ("session_id", `String session_id);
          ("decision_id", `String decision.decision_id);
          ("action", `String action);
          ("intent", `String intent);
          ("stakes", `String stakes);
        ]
    in
    let resolved_payload =
      `Assoc
        [
          ("session_id", `String session_id);
          ("decision_id", `String decision.decision_id);
          ("next_scene_or_state", `String "scene.continue");
          ("resolved_effects", `List [ `String ("action.applied:" ^ action) ]);
          ("risk_delta", `Float risk_delta);
          ("story_log", `List [ `String story ]);
        ]
    in
    let seq = next_event_seq ~base_dir ~room_id in
    (match
       append_event ~base_dir ~room_id ~seq
         ~event_type:Trpg_engine_event.Turn_action_proposed
         ~actor_id:ctx.agent_name ~payload:proposed_payload ()
     with
    | Error e ->
        Error
          (err_json ~canonical_tool ~code:"IO_ERROR"
             ~message:(Printf.sprintf "failed to append TRPG proposed event: %s" e)
             ())
    | Ok () -> (
        match
          append_event ~base_dir ~room_id ~seq:(seq + 1)
            ~event_type:Trpg_engine_event.Turn_action_resolved
            ~actor_id:ctx.agent_name ~payload:resolved_payload ()
        with
        | Error e ->
            Error
              (err_json ~canonical_tool ~code:"IO_ERROR"
                 ~message:
                   (Printf.sprintf "failed to append TRPG resolved event: %s" e)
                 ())
        | Ok () ->
            let payload =
              `Assoc
                [
                  ("session_id", `String session_id);
                  ("room_id", `String room_id);
                  ("decision_id", `String decision.decision_id);
                  ("next_scene_or_state", `String "scene.continue");
                  ("resolved_effects", `List [ `String ("action.applied:" ^ action) ]);
                  ("risk_delta", `Float risk_delta);
                  ("story_log", `List [ `String story ]);
                ]
            in
            Ok (ok_json ~canonical_tool payload)))

let handle_trpg_world_query (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let room_id =
    get_string_opt args "room_id"
    |> Option.value
         ~default:(sanitize_room_id (Printf.sprintf "session-%s" session_id))
  in
  let after_seq = max 0 (get_int args "after_seq" 0) in
  let event_limit = get_int args "event_limit" 20 |> max 1 |> min 100 in
  match Game_view_state.get_client_session ctx.config ~session_id with
  | None ->
      Error
        (err_json ~canonical_tool ~code:"PRECONDITION_REQUIRED"
           ~message:"client.session.open required before trpg.world.query" ())
  | Some session ->
      let viewer_agent =
        get_string_opt args "agent"
        |> Option.value ~default:session.agent_name
        |> String.trim
      in
      let viewer_agent =
        if viewer_agent = "" then session.agent_name else viewer_agent
      in
      let _ =
        Game_view_state.open_client_session ctx.config ~session_id ~trace_id:None
          ~agent_name:ctx.agent_name
      in
      let skills = skills_for_world_query ctx.config ~agent_name:viewer_agent in
      (match Trpg_world_projection.build ~base_dir:ctx.config.base_path ~room_id with
      | Error msg ->
          Error
            (err_json ~canonical_tool ~code:"IO_ERROR"
               ~message:(Printf.sprintf "failed to build world projection: %s" msg)
               ())
      | Ok world ->
          let view =
            Trpg_visibility.filter ~agent_name:viewer_agent ~after_seq
              ~event_limit ~available_skills:skills world
          in
          let payload =
            `Assoc
              [
                ("session_id", `String session_id);
                ("room_id", `String room_id);
                ("agent", `String viewer_agent);
                ("scope", `String "visible");
                ("round", `Int view.round);
                ("phase", `String view.phase);
                ("self", world_agent_payload view.self);
                ("visible_agents", `List (List.map world_agent_payload view.visible_agents));
                ("events_since", `List (List.map Trpg_engine_event.to_yojson view.events_since));
                ("available_skills", json_string_list view.available_skills);
                ( "source_counts",
                  `Assoc
                    [
                      ("jsonl", `Int world.source_counts.jsonl);
                      ("sqlite", `Int world.source_counts.sqlite);
                      ("merged", `Int world.source_counts.merged);
                    ] );
                ("server_time", `Float (Time_compat.now ()));
                ("protocol_version", `String protocol_version);
              ]
          in
          Ok (ok_json ~canonical_tool payload))

let handle_trpg_canonical (ctx : context) ~canonical_tool ~legacy_name args :
    tool_result =
  match delegate_trpg ctx ~legacy_name ~args with
  | Some (true, body) ->
      ok_json ~canonical_tool (parse_json_or_string body)
  | Some (false, msg) ->
      err_json ~canonical_tool ~code:"LEGACY_ERROR" ~message:msg
        ~details:(`Assoc [ ("legacy_tool", `String legacy_name) ])
        ()
  | None ->
      Log.Dispatch.info "NOT_IMPLEMENTED: trpg %s (canonical: %s)"
        legacy_name canonical_tool;
      err_json ~canonical_tool ~code:"NOT_IMPLEMENTED"
        ~message:(Printf.sprintf "legacy dispatcher unavailable: %s. Use canonical tool names from dispatch table." legacy_name)
        ()

let handle_client_session_open (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let trace_id = get_string_opt args "trace_id" in
  let session =
    Game_view_state.open_client_session ctx.config ~session_id ~trace_id
      ~agent_name:ctx.agent_name
  in
  let payload =
    `Assoc
      [
        ("session_id", `String session.session_id);
        ("trace_id", Option.fold ~none:`Null ~some:(fun v -> `String v) session.trace_id);
        ("status", `String "opened");
        ("opened_at", `Float session.created_at);
        ("last_seen", `Float session.last_seen);
        ("protocol_version", `String protocol_version);
      ]
  in
  Ok (ok_json ~canonical_tool payload)

let handle_client_state_subscribe (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let requested_topics =
    get_string_list args "topics"
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
    |> dedupe_keep_order
  in
  if requested_topics = [] then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"topics must include at least one entry" ())
  else
    match Game_view_state.get_client_session ctx.config ~session_id with
    | None ->
        Error
          (err_json ~canonical_tool ~code:"PRECONDITION_REQUIRED"
             ~message:
               "client.session.open required before client.state.subscribe"
             ())
    | Some _ ->
        let _ =
          Game_view_state.open_client_session ctx.config ~session_id
            ~trace_id:None ~agent_name:ctx.agent_name
        in
        let accepted_topics, rejected_topics = split_topics requested_topics in
        let sub =
          Game_view_state.create_client_subscription ctx.config ~session_id
            ~topics:requested_topics ~accepted_topics ~rejected_topics
        in
        let payload =
          `Assoc
            [
              ("subscription_id", `String sub.subscription_id);
              ("session_id", `String sub.session_id);
              ("accepted_topics", json_string_list accepted_topics);
              ("rejected_topics", json_string_list rejected_topics);
              ( "transport",
                `Assoc
                  [
                    ("primary", `String "sse");
                    ("sse_endpoints", `List (sse_endpoints_for_topics accepted_topics));
                    ("pull_fallback", pull_fallback_for_topics accepted_topics);
                  ] );
            ]
        in
        Ok (ok_json ~canonical_tool payload)

let handle_client_input_submit (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let input = get_string args "input" "" |> String.trim in
  if input = "" then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"input is required" ())
  else
    match Game_view_state.get_client_session ctx.config ~session_id with
    | None ->
        Error
          (err_json ~canonical_tool ~code:"PRECONDITION_REQUIRED"
             ~message:"client.session.open required before client.input.submit"
             ())
    | Some _ ->
        let _ =
          Game_view_state.open_client_session ctx.config ~session_id
            ~trace_id:None ~agent_name:ctx.agent_name
        in
        let item =
          Game_view_state.create_client_input ctx.config ~session_id ~input
            ~submitted_by:ctx.agent_name
        in
        Ok (ok_json ~canonical_tool (client_input_payload item))

let handle_client_input_transition (ctx : context) ~canonical_tool ~status
    ~default_reason args : (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let* input_id = require_input_id args ~canonical_tool in
  let reject_reason =
    match status with
    | Game_view_state.Rejected ->
        Some
          (get_string_opt args "reason"
           |> Option.value ~default:default_reason
           |> String.trim)
    | _ -> None
  in
  match Game_view_state.get_client_session ctx.config ~session_id with
  | None ->
      Error
        (err_json ~canonical_tool ~code:"PRECONDITION_REQUIRED"
           ~message:
             (Printf.sprintf
                "client.session.open required before %s"
                canonical_tool)
           ())
  | Some _ -> (
      let _ =
        Game_view_state.open_client_session ctx.config ~session_id
          ~trace_id:None ~agent_name:ctx.agent_name
      in
      match
        Game_view_state.transition_client_input ctx.config ~session_id ~input_id
          ~status ~handled_by:ctx.agent_name ~reject_reason
      with
      | Ok item ->
          let event_type = match status with
            | Game_view_state.Approved -> "client_input_approved"
            | Game_view_state.Rejected -> "client_input_rejected"
            | Game_view_state.Pending  -> "client_input_updated"
          in
          (try
            broadcast_masc_event ~event_type ~agent:ctx.agent_name
              ~data:(client_input_payload item) ()
          with exn ->
            Log.Protocol.error "SSE %s broadcast failed: %s"
              event_type (Printexc.to_string exn));
          Ok (ok_json ~canonical_tool (client_input_payload item))
      | Error msg ->
          let code =
            if String.starts_with ~prefix:"input not found" msg then "NOT_FOUND"
            else if String.starts_with ~prefix:"input already handled" msg then
              "CONFLICT"
            else "VALIDATION_ERROR"
          in
          Error (err_json ~canonical_tool ~code ~message:msg ()))

let handle_client_snapshot_get (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let requested_room_id =
    get_string_opt args "room_id"
    |> Option.value
         ~default:(sanitize_room_id (Printf.sprintf "session-%s" session_id))
  in
  let max_events = get_int args "max_events" 20 |> min 100 |> max 1 in
  match Game_view_state.get_client_session ctx.config ~session_id with
  | None ->
      Error
        (err_json ~canonical_tool ~code:"PRECONDITION_REQUIRED"
           ~message:"client.session.open required before client.snapshot.get" ())
  | Some _ ->
      let session =
        Game_view_state.open_client_session ctx.config ~session_id ~trace_id:None
          ~agent_name:ctx.agent_name
      in
      let subscriptions =
        Game_view_state.get_client_subscriptions ctx.config ~session_id
      in
      let inputs =
        Game_view_state.get_client_inputs ctx.config ~session_id
      in
      let pending_inputs =
        List.filter
          (fun (i : Game_view_state.client_input) ->
            i.status = Game_view_state.Pending)
          inputs
      in
      let latest_decision =
        latest_decision_for_session ctx.config ~session_id
      in
      let finalized_decision =
        Game_view_state.latest_finalized_decision ctx.config ~session_id
      in
      let trpg_events =
        match
          Trpg_engine_store.read_events ~base_dir:ctx.config.base_path
            ~room_id:requested_room_id
        with
        | Ok events -> events
        | Error _ -> []
      in
      let recent_events = take_last max_events trpg_events in
      let last_seq =
        match List.rev recent_events with
        | (ev : Trpg_engine_event.t) :: _ -> ev.seq
        | [] -> 0
      in
      let all_experiments = Tool_experiment.list_experiments ctx.config in
      let running_experiments =
        List.filter
          (fun (e : Tool_experiment.experiment) ->
            e.status = Tool_experiment.Running)
          all_experiments
      in
      let payload =
        `Assoc
          [
            ("snapshot_version", `String "masc.game-view.snapshot/0.1");
            ("session", Game_view_state.client_session_to_json session);
            ( "latest_decision",
              Option.fold ~none:`Null ~some:decision_payload latest_decision );
            ( "finalized_decision",
              Option.fold ~none:`Null ~some:decision_payload finalized_decision );
            ( "subscriptions",
              `List
                (List.map
                   Game_view_state.client_subscription_to_json
                   subscriptions) );
            ( "input_queue",
              `Assoc
                [
                  ("pending_count", `Int (List.length pending_inputs));
                  ("recent", `List (List.map client_input_payload (take_last 20 inputs)));
                ] );
            ( "trpg",
              `Assoc
                [
                  ("room_id", `String requested_room_id);
                  ("event_count", `Int (List.length trpg_events));
                  ("last_seq", `Int last_seq);
                  ( "recent_events",
                    `List
                      (List.map
                         (fun (ev : Trpg_engine_event.t) ->
                           Trpg_engine_event.to_yojson ev)
                         recent_events) );
                ] );
            ( "experiments",
              `Assoc
                [
                  ("running_count", `Int (List.length running_experiments));
                  ( "recent",
                    `List
                      (List.map
                         experiment_summary_payload
                         (take 5 all_experiments)) );
                ] );
            ("server_time", `Float (Time_compat.now ()));
            ("protocol_version", `String protocol_version);
          ]
      in
      Ok (ok_json ~canonical_tool payload)

