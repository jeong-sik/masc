(** Trpg_round_run_handler — The core round execution handler (handle_round_run).

    This function orchestrates a complete TRPG round: keeper calls,
    action validation, NPC responses, outcome detection, and state updates.

    All types, utilities, and prior handlers are provided via
    the include chain: Trpg_types -> Trpg_action -> Trpg_round
    -> Trpg_handlers -> Trpg_round_run_handler. *)

include Trpg_handlers
open Yojson.Safe.Util

let handle_round_run ctx args : result =
  let ( let* ) = Result.bind in
  let store = ctx.store in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* dm_keeper_raw = get_required_string args "dm_keeper" in
    let dm_keeper = String.trim dm_keeper_raw in
    let* player_keepers = parse_player_keepers args in
    let* timeout_sec = get_optional_float args "timeout_sec" ~default:90.0 in
    let* keeper_timeout_sec_raw =
      get_optional_float args "keeper_timeout_sec" ~default:0.0
    in
    let* outcome_max_turn_opt = get_optional_int args "outcome_max_turn" in
    let keeper_timeout_override_sec =
      if keeper_timeout_sec_raw > 0.0 then Some keeper_timeout_sec_raw else None
    in
    let outcome_max_turn_override =
      match outcome_max_turn_opt with
      | Some n when n > 0 -> Some n
      | _ -> None
    in
    if timeout_sec <= 0.0 then Error "timeout_sec must be > 0"
    else if
      match keeper_timeout_override_sec with
      | Some override_sec -> override_sec > timeout_sec
      | None -> false
    then Error "keeper_timeout_sec must be <= timeout_sec"
    else if Option.is_some outcome_max_turn_opt
            && Option.is_none outcome_max_turn_override
    then Error "outcome_max_turn must be >= 1"
    else if dm_keeper = "" then Error "dm_keeper cannot be empty"
    else
      let* rule_opt = get_optional_string args "rule_module" in
      let* phase_opt = get_optional_string args "phase" in
      let* lang_opt = get_optional_string args "lang" in
      let* dm_persona_opt = get_optional_string args "dm_persona" in
      let* require_claim = get_optional_bool args "require_claim" ~default:false in
      let* strict_agent_driven =
        get_optional_bool args "strict_agent_driven" ~default:false
      in
      let* strict_unique_player_reply =
        get_optional_bool args "strict_unique_player_reply"
          ~default:(trpg_strict_unique_player_reply ())
      in
      let* local_fallback_requested =
        get_optional_bool args "local_fallback" ~default:false
      in
      let local_fallback = local_fallback_requested && not strict_agent_driven in
      let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
      let phase_input = Option.value ~default:"round" phase_opt in
      let prompt_lang = prompt_language_of_string_opt lang_opt in
      let* dm_persona_override =
        match dm_persona_opt with
        | None -> Ok None
        | Some raw -> (
            let normalized = String.lowercase_ascii (String.trim raw) in
            match dm_persona_id_of_string normalized with
            | Some persona -> Ok (Some (string_of_dm_persona_id persona))
            | None ->
                Error
                  "dm_persona must be one of: grim_gothic, tactical_irony, heroic_epic")
      in
      let* () =
        match ctx.keeper_call with
        | Some _ -> Ok ()
        | None -> Error "keeper_call is not available in this runtime"
      in
      let* () = validate_rule_module rule_module in
      let* phase =
        match Trpg_engine_types.phase_of_string phase_input with
        | Ok phase -> Ok (Trpg_engine_types.string_of_phase phase)
        | Error e -> Error e
      in
      let* () = validate_unique_keeper_assignments ~dm_keeper ~player_keepers in
      let assigned_keepers = dm_keeper :: List.map snd player_keepers in
      let preflight_warning =
        match keeper_preflight ctx ~keepers:assigned_keepers with
        | Ok () -> None
        | Error e ->
            Some
              (Printf.sprintf
                 "non-blocking preflight warning (snapshot): %s"
                 e)
      in
      with_keeper_reservation
        ~keepers:assigned_keepers
        (fun () ->
      let* derived = derive_state ~store ~room_id ~rule_module in
      let* existing_events_before =
        store.read_events ~room_id
      in
      let session_events_before =
        events_since_last_session_marker existing_events_before
      in
      let state = state_of_derived derived in
      let room_already_ended =
        has_event_type session_events_before Trpg_engine_event.Room_ended
      in
      let outcome_already_emitted =
        has_event_type session_events_before Trpg_engine_event.Session_outcome
      in
      let end_rules =
        resolve_end_rules_for_room ~store ~events:existing_events_before
      in
      let latest_outcome_payload =
        ref (latest_session_outcome_payload session_events_before)
      in
      let response_outcome_source =
        ref
          (match !latest_outcome_payload with
          | Some payload -> outcome_source_from_payload payload
          | None -> "none")
      in
      let response_stagnation_level =
        ref
          (match !latest_outcome_payload with
          | Some payload -> stagnation_level_from_payload payload
          | None -> 0)
      in
      let* turn_before = read_state_turn derived in
      let unavailable_sampling =
        make_unavailable_sampling_state ~events:existing_events_before
          ~turn:turn_before
      in
      let next_turn = max 1 (turn_before + 1) in
      let* () =
        if player_keepers = [] then
          Error "player_keepers must include at least one player actor assignment"
        else Ok ()
      in
      let existing_player_keepers, missing_player_keepers =
        List.partition
          (fun (actor_id, _) ->
            actor_id <> "dm" && actor_exists_in_state state actor_id)
          player_keepers
      in
      let* () =
        if existing_player_keepers = [] then
          Error
            "invalid player assignment: no playable party actor found in player_keepers"
        else Ok ()
      in
      let live_player_keepers, dead_player_keepers =
        List.partition
          (fun (actor_id, _) -> actor_alive_in_state state actor_id)
          existing_player_keepers
      in
      let terminal_session = room_already_ended || outcome_already_emitted in
      if terminal_session then
        let active_player_count = List.length live_player_keepers in
        let participant_count = max 1 (1 + active_player_count) in
        let keeper_timeout_sec =
          resolve_keeper_timeout_sec ~keeper_timeout_override_sec ~timeout_sec
            ~participant_count
        in
        let player_required_successes =
          let total = active_player_count in
          if total <= 0 then 0 else max 1 ((total + 1) / 2)
        in
        let terminal_reason =
          if room_already_ended && outcome_already_emitted then
            "room already ended and session outcome already emitted"
          else if room_already_ended then
            "room already ended"
          else "session outcome already emitted"
        in
        let missing_statuses =
          missing_player_keepers
          |> List.map (fun (actor_id, keeper_name) ->
                 let reason =
                   if actor_id = "dm" then
                     "actor_id 'dm' is reserved for the DM and cannot be used in player_keepers"
                   else
                     "actor is not part of active party in state snapshot"
                 in
                 `Assoc
                   [
                     ("actor_id", `String actor_id);
                     ("role", `String "player");
                     ("keeper", `String keeper_name);
                     ("status", `String "skipped_missing");
                     ("reason", `String reason);
                     ("stage", `String "preflight");
                   ])
        in
        let dead_statuses =
          dead_player_keepers
          |> List.map (fun (actor_id, keeper_name) ->
                 `Assoc
                   [
                     ("actor_id", `String actor_id);
                     ("role", `String "player");
                     ("keeper", `String keeper_name);
                     ("status", `String "skipped_dead");
                     ("reason", `String "actor is not alive at round start");
                     ("stage", `String "preflight");
                   ])
        in
        let live_statuses =
          live_player_keepers
          |> List.map (fun (actor_id, keeper_name) ->
                 `Assoc
                   [
                     ("actor_id", `String actor_id);
                     ("role", `String "player");
                     ("keeper", `String keeper_name);
                     ("status", `String "skipped_session_ended");
                     ("reason", `String terminal_reason);
                     ("stage", `String "session_guard");
                   ])
        in
        let dm_status =
          `Assoc
            [
              ("actor_id", `String "dm");
              ("role", `String "dm");
              ("keeper", `String dm_keeper);
              ("status", `String "skipped_session_ended");
              ("reason", `String terminal_reason);
              ("stage", `String "session_guard");
            ]
        in
        let statuses = missing_statuses @ dead_statuses @ live_statuses @ [ dm_status ] in
        let canon_check =
          evaluate_canon_check ~store ~state ~events:existing_events_before
            ~dm_reply:None
        in
        let dm_style =
          match state |> member "config" with
          | `Assoc fields -> (
              match List.assoc_opt "dm" fields with
              | Some dm_json -> get_string_field dm_json "style"
              | None -> "")
          | _ -> ""
        in
        let dm_persona_used =
          infer_dm_persona_id
            ~explicit:(Option.bind dm_persona_override dm_persona_id_of_string)
            ~dm_style
        in
        let room_status =
          match state |> member "status" with
          | `String status when String.trim status <> "" -> status
          | _ -> "ended"
        in
        Ok
          (`Assoc
            [
              ("ok", `Bool true);
              ("room_id", `String room_id);
              ("phase", `String phase);
              ("turn_before", `Int turn_before);
              ("turn_after", `Int turn_before);
              ("timeout_sec", `Float timeout_sec);
              ( "preflight_warning",
                match preflight_warning with
                | Some warning -> `String warning
                | None -> `Null );
              ("statuses", `List statuses);
              ("interventions_applied", `List []);
              ( "summary",
                `Assoc
                  [
                    ("participants", `Int participant_count);
                    ("successes", `Int 0);
                    ("fallbacks", `Int 0);
                    ("player_successes", `Int 0);
                    ("player_fallbacks", `Int 0);
                    ("player_required_successes", `Int player_required_successes);
                    ("player_quorum_met", `Bool false);
                    ("dm_success", `Bool false);
                    ("advanced", `Bool false);
                    ("progress_reason", `String "session_ended");
                    ("progress_detail", `String terminal_reason);
                    ("recovery_applied", `Bool false);
                    ( "recovery_mode",
                      if local_fallback then
                        `String "local_fallback_enabled"
                      else `String "none" );
                    ("effective_timeout_sec", `Float timeout_sec);
                    ("requested_timeout_sec", `Float timeout_sec);
                    ("keeper_timeout_sec", `Float keeper_timeout_sec);
                    ("timeouts", `Int 0);
                    ("unavailable", `Int 0);
                    ("schema_failures", `Int 0);
                    ("rule_validation_failures", `Int 0);
                    ("reprompts", `Int 0);
                    ("dm_persona", `String (string_of_dm_persona_id dm_persona_used));
                    ("dm_persona_overridden", `Bool (Option.is_some dm_persona_override));
                    ("npc_spawned", `Int 0);
                    ("npc_attacks", `Int 0);
                    ("interventions", `Int 0);
                    ("canon_status", `String canon_check.status);
                    ("canon_violation_count", `Int (List.length canon_check.violations));
                    ("canon_warning_count", `Int (List.length canon_check.warnings));
                    ("memory_signals", `Int 0);
                    ("memory_guardrail_escalations", `Int 0);
                    ("stagnation_level", `Int !response_stagnation_level);
                    ("stagnation_turn_threshold", `Int stagnation_detection_turn_threshold);
                    ( "stagnation_escalation_threshold",
                      `Int stagnation_escalation_threshold );
                    ("outcome_source", `String !response_outcome_source);
                    ("roll_audit_count", `Int 0);
                    ("roll_audit", `List []);
                  ] );
              ("canon_check", canon_check_to_yojson canon_check);
              ( "outcome",
                match !latest_outcome_payload with
                | Some payload -> payload
                | None -> `Null );
              ("outcome_source", `String !response_outcome_source);
              ("stagnation_level", `Int !response_stagnation_level);
              ("events", `List []);
              ("room_status", `String room_status);
              ("state", state);
            ])
      else
      let* join_window_closed_event =
        append_event
          ~store
          ~room_id
          ~event_type:Trpg_engine_event.Join_window_closed
          ~payload:
            (`Assoc
              [
                ("turn", `Int turn_before);
                ("window", `String "round_boundary_only");
                ("reason", `String "round_run_started");
              ])
          ()
      in

      let* phase_event =
        append_event
          ~store
          ~room_id
          ~event_type:Trpg_engine_event.Phase_changed
          ~payload:(`Assoc [ ("phase", `String phase) ])
          ()
      in
      let* interventions_applied, intervention_events =
        append_pending_interventions ~store ~room_id ~phase ~turn:turn_before
      in
      let base_state_for_prompt =
        inject_interventions_into_state state interventions_applied
        |> compact_state_for_prompt
      in

      let appended_events =
        ref (join_window_closed_event :: phase_event :: intervention_events)
      in
      let statuses = ref [] in
      let outcome_source_ref = ref "none" in
      let stagnation_level_ref = ref 0 in
      let stagnation_pressure_emitted = ref false in
      let success_count = ref 0 in
      let fallback_count = ref 0 in
      let schema_failures = ref 0 in
      let rule_validation_failures = ref 0 in
      let reprompt_count = ref 0 in
      let player_success_count = ref 0 in
      let player_fallback_count = ref 0 in
      let dm_success = ref false in
      let unavailable_count = ref 0 in
      let timeout_count = ref 0 in
      let dm_reply_ref : string option ref = ref None in
      let state_for_players_ref = ref base_state_for_prompt in
      let seen_player_reply_signatures : (string * string) list ref = ref [] in
      let active_player_count = List.length live_player_keepers in
      let participant_count = max 1 (1 + active_player_count) in
      let keeper_timeout_sec =
        resolve_keeper_timeout_sec ~keeper_timeout_override_sec ~timeout_sec
          ~participant_count
      in
      let* () =
        if phase = "round" then
          let* spawn_event_opt =
            ensure_round_npc_spawn_event ~store ~room_id ~turn:turn_before
              ~state:base_state_for_prompt
          in
          (match spawn_event_opt with
          | Some spawn_event ->
              appended_events := !appended_events @ [ spawn_event ];
              (match derive_state ~store ~room_id ~rule_module with
              | Ok derived_after_spawn ->
                  state_for_players_ref :=
                    inject_interventions_into_state
                      (state_of_derived derived_after_spawn)
                      interventions_applied
                    |> compact_state_for_prompt
              | Error _ -> ())
          | None -> ());
          Ok ()
        else Ok ()
      in

      List.iter
        (fun (actor_id, keeper_name) ->
          let reason =
            if actor_id = "dm" then
              "actor_id 'dm' is reserved for the DM and cannot be used in player_keepers"
            else "actor is not part of active party in state snapshot"
          in
          statuses :=
            `Assoc
              [
                ("actor_id", `String actor_id);
                ("role", `String "player");
                ("keeper", `String keeper_name);
                ("status", `String "skipped_missing");
                ("reason", `String reason);
                ("stage", `String "preflight");
              ]
            :: !statuses)
        missing_player_keepers;

      List.iter
        (fun (actor_id, keeper_name) ->
          statuses :=
            `Assoc
              [
                ("actor_id", `String actor_id);
                ("role", `String "player");
                ("keeper", `String keeper_name);
                ("status", `String "skipped_dead");
                ("reason", `String "actor is not alive at round start");
                ("stage", `String "preflight");
              ]
            :: !statuses)
        dead_player_keepers;

      let duplicate_player_reply_actor ~actor_id ~reply =
        let signature = normalize_reply_for_comparison reply in
        if signature = "" then None
        else
          !seen_player_reply_signatures
          |> List.find_map (fun (prev_actor_id, prev_signature) ->
                 if prev_signature = signature && prev_actor_id <> actor_id then
                   Some prev_actor_id
                 else None)
      in
      let register_player_reply_signature ~role ~actor_id ~reply =
        match role with
        | `Dm -> ()
        | `Player ->
            let signature = normalize_reply_for_comparison reply in
            if signature <> "" then
              seen_player_reply_signatures :=
                (actor_id, signature) :: !seen_player_reply_signatures
      in

      let process_one ~state_json ~role ~actor_id ~keeper_name =
        let record_unavailable_status ~reply_excerpt ~status ~error ~stage =
          let* unavailable_result =
            append_unavailable_event
              ~store
              ~room_id
              ~phase
              ~turn:turn_before
              ~role
              ~actor_id
              ~keeper_name
              ~reason:error
              ~stage
              ~sampling_state:unavailable_sampling
              ()
          in
          let sampled, sampled_reason =
            match unavailable_result with
            | `Appended unavailable_event ->
                unavailable_count := !unavailable_count + 1;
                appended_events := !appended_events @ [ unavailable_event ];
                (false, None)
            | `Sampled reason -> (true, Some reason)
          in
          statuses :=
            `Assoc
              [
                ("actor_id", `String actor_id);
                ("role", `String (role_to_string role));
                ("keeper", `String keeper_name);
                ("status", `String status);
                ("reason", `String error);
                ("stage", `String stage);
                ("error", `String error);
                ( "reply_excerpt",
                  Option.fold ~none:`Null ~some:(fun v -> `String v)
                    reply_excerpt );
                ("sampled", `Bool sampled);
                ( "sampled_reason",
                  Option.fold ~none:`Null ~some:(fun v -> `String v)
                    sampled_reason );
              ]
            :: !statuses;
          Ok ()
        in
        let apply_local_fallback ~stage ~reason =
          if not local_fallback then Ok ()
          else
            let fallback_reply =
              match role with
              | `Player -> fallback_player_reply ~state:state_json ~actor_id
              | `Dm -> fallback_dm_reply ~state:state_json
            in
            let* spawn_event_opt =
              match role with
              | `Player -> Ok None
              | `Dm ->
                  ensure_round_npc_spawn_event ~store ~room_id ~turn:turn_before
                    ~state:state_json
            in
            (match spawn_event_opt with
            | Some spawn_event ->
                appended_events := !appended_events @ [ spawn_event ]
            | None -> ());
            let state_for_pressure =
              match role with
              | `Player -> state_json
              | `Dm -> (
                  match spawn_event_opt with
                  | Some _ -> (
                      match derive_state ~store ~room_id ~rule_module with
                      | Ok derived_after_spawn -> state_of_derived derived_after_spawn
                      | Error _ -> state_json )
                  | None -> state_json )
            in
            let* reply_event =
              append_keeper_reply_event ~store ~room_id ~phase ~turn:turn_before
                ~role ~actor_id ~keeper_name ~reply:fallback_reply
            in
            let fallback_sa =
              match role with
              | `Player ->
                  {
                    sa_type = Attack;
                    target_id = None;
                    description = fallback_reply;
                    flag_key = None;
                    scene = None;
                    quest_info = None;
                    memory_hint = None;
                    raw_payload =
                      `Assoc
                        [
                          ("type", `String "attack");
                          ("description", `String fallback_reply);
                          ("inferred", `Bool true);
                          ("source", `String "round_fallback");
                        ];
                  }
              | `Dm ->
                  {
                    sa_type = SetFlag;
                    target_id = None;
                    description = fallback_reply;
                    flag_key = Some "story.recovered";
                    scene = None;
                    quest_info = None;
                    memory_hint = None;
                    raw_payload =
                      `Assoc
                        [
                          ("type", `String "set_flag");
                          ("description", `String fallback_reply);
                          ("flag_key", `String "story.recovered");
                          ("inferred", `Bool true);
                          ("source", `String "round_fallback");
                        ];
                  }
            in
            fallback_count := !fallback_count + 1;
            (* NOTE: fallback does NOT increment success_count.
               Fallbacks are placeholder responses — counting them as success
               masks stagnation and prevents the game from detecting
               that no meaningful action occurred. *)
            (match role with
            | `Dm ->
                dm_success := true;
                dm_reply_ref := Some fallback_reply
            | `Player ->
                player_fallback_count := !player_fallback_count + 1);
            appended_events := !appended_events @ [ reply_event ];
            let* action_events =
              match role with
              | `Dm ->
                  let payload =
                    `Assoc
                      [
                        ("phase", `String phase);
                        ("turn", `Int turn_before);
                        ("role", `String "dm");
                        ("actor_id", `String actor_id);
                        ("keeper", `String keeper_name);
                        ("narration", `String fallback_reply);
                        ("is_fallback", `Bool true);
                      ]
                  in
                  let* event =
                    append_event ~store ~room_id
                      ~event_type:Trpg_engine_event.Narration_posted
                      ~actor_id ~payload ()
                  in
                  Ok [ event ]
              | `Player ->
                  let payload =
                    `Assoc
                      [
                        ("phase", `String phase);
                        ("turn", `Int turn_before);
                        ("role", `String "player");
                        ("actor_id", `String actor_id);
                        ("keeper", `String keeper_name);
                        ("narration", `String fallback_reply);
                        ("is_fallback", `Bool true);
                      ]
                  in
                  let* event =
                    append_event ~store ~room_id
                      ~event_type:Trpg_engine_event.Narration_posted
                      ~actor_id ~payload ()
                  in
                  Ok [ event ]
            in
            appended_events := !appended_events @ action_events;
            let* observability_events =
              append_round_observability_events ~store ~room_id ~phase
                ~turn:turn_before ~role ~actor_id ~keeper_name ~reply:fallback_reply
                ~sa:fallback_sa ~action_events ~resolution_source:"fallback"
                ~fallback:true
            in
            appended_events := !appended_events @ observability_events;
            let* pressure_events =
              match role with
              | `Dm ->
                  append_npc_counterattack_events ~store ~room_id ~phase
                    ~turn:turn_before ~state:state_for_pressure
              | `Player -> Ok []
            in
            appended_events := !appended_events @ pressure_events;
            statuses :=
              `Assoc
                [
                  ("actor_id", `String actor_id);
                  ("role", `String (role_to_string role));
                  ("keeper", `String keeper_name);
                  ("status", `String "fallback");
                  ("stage", `String stage);
                  ("reason", `String reason);
                  ("reply", `String fallback_reply);
                ]
              :: !statuses;
            Ok ()
        in
        (* Phase 1: BDI state update after successful keeper reply.
           Observation-only — errors are logged but never block the main path. *)
        let update_bdi_after_reply ~reply_text ~sa =
          let room_dir = store.Trpg_store.room_dir ~room_id in
          let bdi0 = Trpg_bdi.load ~room_dir ~actor_id in
          let bdi1 = Trpg_bdi.decay_beliefs ~current_turn:turn_before bdi0 in
          (* Update belief: the keeper's reply reflects what the character now knows *)
          let belief_subject =
            Printf.sprintf "turn_%d_action" turn_before
          in
          let belief_content =
            let max_len = 120 in
            if String.length reply_text <= max_len then reply_text
            else String.sub reply_text 0 max_len ^ "..."
          in
          let bdi2 =
            Trpg_bdi.update_belief
              ~subject:belief_subject
              ~content:belief_content
              ~confidence:0.9
              ~turn:turn_before
              bdi1
          in
          (* Update desire based on action type *)
          let bdi3 =
            match sa.sa_type with
            | Attack | Defend ->
                Trpg_bdi.update_desire
                  ~goal:"survive combat" ~priority:0.9 ~category:"survival" bdi2
            | Heal ->
                Trpg_bdi.update_desire
                  ~goal:"recover health" ~priority:0.8 ~category:"survival" bdi2
            | Social ->
                Trpg_bdi.update_desire
                  ~goal:"build relationships" ~priority:0.6 ~category:"social" bdi2
            | Investigate | Explore ->
                Trpg_bdi.update_desire
                  ~goal:"discover information" ~priority:0.7 ~category:"quest" bdi2
            | QuestUpdate ->
                Trpg_bdi.update_desire
                  ~goal:"advance quest" ~priority:0.8 ~category:"quest" bdi2
            | Magic | UseItem | SetFlag | SceneTransition -> bdi2
          in
          (* Save BDI state — ignore errors (observation-only) *)
          let _save_result = Trpg_bdi.save ~room_dir bdi3 in
          (* Emit Bdi_updated event — ignore errors *)
          let _event_result =
            append_event ~store ~room_id
              ~event_type:Trpg_engine_event.Bdi_updated
              ~actor_id
              ~payload:(Trpg_bdi.to_yojson bdi3)
              ()
          in
          ()
        in
        (* Phase 2: Harness evaluation after successful keeper reply.
           Observation-only — errors are logged but never block the main path.
           Tier 1 (structural gate): cheap model, ~50 tokens.
           Tier 2 (quality scoring): capable model, ~200 tokens. *)
        let evaluate_keeper_response ~reply_text =
          (* Opt-in only: skip evaluation when no model is configured.
             Prevents CI hang — LLM HTTP calls block indefinitely
             when the endpoint (e.g. Ollama) is unreachable. *)
          match Sys.getenv_opt "TRPG_HARNESS_TIER1_MODEL" with
          | None -> ()
          | Some tier1_str ->
          try
            let tier1_model =
              match Llm_client.model_spec_of_string tier1_str with
              | Ok m -> m
              | Error _ -> (
                  match Llm_client.default_verifier_model_spec () with
                  | Ok model -> model
                  | Error _ -> Llm_client.glm_cloud)
            in
            let tier2_model =
              match Sys.getenv_opt "TRPG_HARNESS_TIER2_MODEL" with
              | Some s -> (
                  match Llm_client.model_spec_of_string s with
                  | Ok m -> m
                  | Error _ -> Llm_client.glm_cloud)
              | None -> Llm_client.glm_cloud
            in
            let pctx =
              extract_prompt_context ~actor_id ~dm_persona_override state_json
            in
            let actor_persona =
              match role with
              | `Dm -> "Dungeon Master"
              | `Player -> pctx.actor_persona
            in
            let scene_context =
              let recent = String.concat "\n" pctx.narrative_recent in
              Printf.sprintf "Scene: %s (%s)\n%s"
                pctx.scene_description pctx.scene_mood recent
            in
            let result =
              Trpg_harness.evaluate
                ~tier1_model ~tier2_model
                ~actor_name:pctx.actor_name
                ~actor_persona
                ~actor_traits:pctx.actor_traits
                ~scene_context
                ~response_text:reply_text
            in
            let _event_result =
              append_event ~store ~room_id
                ~event_type:Trpg_engine_event.Evaluation_scored
                ~actor_id
                ~payload:(Trpg_harness.result_to_yojson result)
                ()
            in
            ()
          with exn ->
            let _ignore =
              Printf.eprintf
                "[harness] evaluate_keeper_response failed for %s: %s\n%!"
                actor_id (Printexc.to_string exn)
            in
            ()
        in
        let lease_check =
          match role with
          | `Dm -> Ok ()
          | `Player -> (
              match owner_for_actor state actor_id with
              | Some owner when normalize_keeper_name owner <> "auto-pilot"
                            && normalize_keeper_name owner <> normalize_keeper_name keeper_name ->
                  Error
                    (Printf.sprintf
                       "actor lease mismatch: actor_id=%s owner=%s requested=%s"
                       actor_id owner keeper_name)
              | None when require_claim ->
                  Error
                    (Printf.sprintf
                       "actor must be claimed before round_run: actor_id=%s"
                       actor_id)
              | _ -> Ok () )
        in
        match lease_check with
        | Error lease_error ->
            record_unavailable_status
              ~reply_excerpt:None
              ~status:"lease_denied"
              ~error:lease_error
              ~stage:"lease_check"
        | Ok () ->
        let base_prompt =
          build_keeper_prompt
            ~store
            ~dm_persona_override
            ~room_id
            ~phase
            ~turn:turn_before
            ~role
            ~actor_id
            ~state_json
            ~lang:prompt_lang
        in
        let synthesized_roleplay_reply () =
          match role with
          | `Player -> fallback_player_reply ~state:state_json ~actor_id
          | `Dm -> fallback_dm_reply ~state:state_json
        in
        let normalize_reply_with_action reply sa =
          let trimmed_reply = String.trim reply in
          let candidate_reply =
            if trimmed_reply = "" || is_placeholder_reply trimmed_reply then
              String.trim sa.description
            else trimmed_reply
          in
          let normalized_reply0 =
            if candidate_reply = "" || is_placeholder_reply candidate_reply then
              String.trim (synthesized_roleplay_reply ())
            else candidate_reply
          in
          let recent_replies =
            recent_actor_replies ~state:state_json ~actor_id ~limit:3
          in
          let normalized_reply =
            let normalized_current =
              normalize_reply_for_comparison normalized_reply0
            in
            let is_repeated =
              normalized_current <> ""
              && List.exists
                   (fun recent ->
                     normalize_reply_for_comparison recent = normalized_current)
                   recent_replies
            in
            if not is_repeated then normalized_reply0
            else
              let alternate = String.trim (synthesized_roleplay_reply ()) in
              if alternate = "" then normalized_reply0
              else
                let normalized_alt = normalize_reply_for_comparison alternate in
                let alt_repeated =
                  normalized_alt <> ""
                  && List.exists
                       (fun recent ->
                         normalize_reply_for_comparison recent = normalized_alt)
                       recent_replies
                in
                if alt_repeated then normalized_reply0 else alternate
          in
          let normalized_description =
            let desc = String.trim sa.description in
            if desc = "" || is_placeholder_reply desc then normalized_reply else desc
          in
          (normalized_reply, { sa with description = normalized_description })
        in
        let validate_keeper_payload keeper_json =
          let ( let* ) = Result.bind in
          let* reply =
            match parse_keeper_reply keeper_json with
            | Ok value -> Ok value
            | Error e -> Error (`Schema e)
          in
          let* sa = parse_and_validate_structured_action ~role keeper_json in
          let normalized_reply, normalized_sa =
            normalize_reply_with_action reply sa
          in
          if normalized_reply = "" then
            Error (`Schema "reply is empty after cleanup")
          else if
            is_low_signal_structured_description normalized_reply
            || contains_low_signal_structured_fragment normalized_reply
          then
            Error
              (`Rule
                 "reply is too generic; include concrete target/threat/intent")
          else if is_repetitive_reply ~state:state_json ~actor_id ~reply:normalized_reply then
            Error
              (`Rule
                 "reply repeats recent narration; advance scene with a new concrete move")
          else if role = `Player then
            (match duplicate_player_reply_actor ~actor_id ~reply:normalized_reply with
            | Some other_actor ->
                if strict_unique_player_reply then
                  Error
                    (`Rule
                       (Printf.sprintf
                          "reply duplicates another player action this round (%s); choose a distinct move"
                          other_actor))
                else (
                  statuses :=
                    `Assoc
                      [
                        ("actor_id", `String actor_id);
                        ("role", `String (role_to_string role));
                        ("keeper", `String keeper_name);
                        ("status", `String "duplicate_reply_warning");
                        ("reason", `String "duplicate player reply accepted");
                        ("duplicate_of_actor_id", `String other_actor);
                        ("reply", `String normalized_reply);
                      ]
                    :: !statuses;
                  Ok (normalized_reply, normalized_sa))
            | None -> Ok (normalized_reply, normalized_sa))
          else Ok (normalized_reply, normalized_sa)
        in
        let synthetic_action_for_reply reply_text =
          match infer_action_type_from_narrative ~role reply_text with
          | Some sa -> sa
          | None -> (
              match role with
              | `Player ->
                  {
                    sa_type = Attack;
                    target_id = None;
                    description = reply_text;
                    flag_key = None;
                    scene = None;
                    quest_info = None;
                    memory_hint = None;
                    raw_payload =
                      `Assoc
                        [
                          ("type", `String "attack");
                          ("description", `String reply_text);
                          ("inferred", `Bool true);
                          ("source", `String "synthetic_fallback");
                        ];
                  }
              | `Dm ->
                  {
                    sa_type = SetFlag;
                    target_id = None;
                    description = reply_text;
                    flag_key = Some "story.recovered";
                    scene = None;
                    quest_info = None;
                    memory_hint = None;
                    raw_payload =
                      `Assoc
                        [
                          ("type", `String "set_flag");
                          ("description", `String reply_text);
                          ("flag_key", `String "story.recovered");
                          ("inferred", `Bool true);
                          ("source", `String "synthetic_fallback");
                        ];
                  })
        in
        let infer_action_from_keeper_json keeper_json =
          if strict_agent_driven then None
          else
            let mk_result ~reason reply_text =
              let seed_reply =
                let trimmed = String.trim reply_text in
                if trimmed = "" || is_reply_noise_text trimmed then
                  String.trim (synthesized_roleplay_reply ())
                else trimmed
              in
              let synthetic_action = synthetic_action_for_reply seed_reply in
              let normalized_reply, normalized_sa =
                normalize_reply_with_action seed_reply synthetic_action
              in
              if
                normalized_reply = ""
                || is_low_signal_structured_description normalized_reply
                || contains_low_signal_structured_fragment normalized_reply
                || is_repetitive_reply ~state:state_json ~actor_id ~reply:normalized_reply
                ||
                (match role with
                | `Dm -> false
                | `Player ->
                    Option.is_some
                      (duplicate_player_reply_actor ~actor_id
                         ~reply:normalized_reply))
              then None
              else Some (normalized_reply, normalized_sa, reason)
            in
            match parse_keeper_reply keeper_json with
            | Ok reply_text -> mk_result ~reason:"keeper_reply_inferred" reply_text
            | Error _ ->
                mk_result
                  ~reason:"keeper_reply_synthesized"
                  (synthesized_roleplay_reply ())
        in
        let max_reprompt_attempts =
          let base = trpg_keeper_reprompt_retries () in
          if strict_agent_driven then
            match role with `Dm -> max base 3 | `Player -> base
          else base
        in
        let keeper_call_max_attempts =
          let configured_retries = max 0 (trpg_keeper_call_retries ()) in
          let strict_min_retries =
            if strict_agent_driven then
              match role with
              | `Player -> 2
              | `Dm -> 1
            else configured_retries
          in
          1 + max configured_retries strict_min_retries
        in
        let is_retryable_keeper_error err =
          let lowered = String.lowercase_ascii (String.trim err) in
          lowered <> ""
          && (contains_substring lowered "empty response"
             || contains_substring lowered "temporarily unavailable"
             || contains_substring lowered "connection reset"
             || contains_substring lowered "network is unreachable"
             || contains_substring lowered "read timed out"
             || contains_substring lowered "timeout")
        in
        let re_prompt_message ~stage ~reason ~attempt =
          let role_contract =
            match role with
            | `Dm ->
                "Role contract (DM):\n\
                 - Exactly 2 lines only\n\
                 - Line1: one Korean in-world narrative sentence\n\
                 - Line2: structured_action: {\"type\":\"set_flag|world_event|quest_update|transition|talk\",\"description\":\"non-empty concrete intent\"}\n\
                 - Never output empty structured_action payload/object"
            | `Player ->
                "Role contract (Player):\n\
                 - Exactly 2 lines only\n\
                 - Line1: one Korean in-world narrative sentence\n\
                 - Line2: structured_action: {\"type\":\"attack|move|skill|defend|talk|item|cast\",\"description\":\"non-empty concrete intent\"}\n\
                 - Never output empty structured_action payload/object"
          in
          Printf.sprintf
            "%s\n\n[RETRY REQUIRED %d/%d]\n\
             Your previous response was rejected at stage=%s (%s).\n\
             %s\n\
             Return concise in-world narrative plus exactly one valid structured_action JSON line.\n\
             Do NOT emit SKILL/SKILL_REASON/[STATE] headers. Output only narrative + structured_action."
            base_prompt attempt max_reprompt_attempts stage
            (compact_summary_text ~max_len:180 reason) role_contract
        in
        let run_keeper_once ~stage ~message =
          let rec loop attempt =
            match
              call_keeper ctx ~name:keeper_name ~message
                ~timeout_sec:keeper_timeout_sec
            with
            | `Timeout when attempt < keeper_call_max_attempts ->
                statuses :=
                  `Assoc
                    [
                      ("actor_id", `String actor_id);
                      ("role", `String (role_to_string role));
                      ("keeper", `String keeper_name);
                      ("status", `String "keeper_call_retry");
                      ("stage", `String stage);
                      ("reason", `String "timeout");
                      ("attempt", `Int attempt);
                      ("max_attempts", `Int keeper_call_max_attempts);
                    ]
                  :: !statuses;
                loop (attempt + 1)
            | `Timeout -> Error (`Timeout stage)
            | `Error err
              when attempt < keeper_call_max_attempts
                   && is_retryable_keeper_error err ->
                statuses :=
                  `Assoc
                    [
                      ("actor_id", `String actor_id);
                      ("role", `String (role_to_string role));
                      ("keeper", `String keeper_name);
                      ("status", `String "keeper_call_retry");
                      ("stage", `String stage);
                      ("reason", `String (compact_summary_text ~max_len:180 err));
                      ("attempt", `Int attempt);
                      ("max_attempts", `Int keeper_call_max_attempts);
                    ]
                  :: !statuses;
                loop (attempt + 1)
            | `Error err -> Error (`Unavailable (stage, err))
            | `Ok keeper_json -> (
                match validate_keeper_payload keeper_json with
                | Ok (reply, sa) -> Ok (reply, sa)
                | Error validation_error ->
                    Error (`Validation (stage, validation_error, keeper_json))
              )
          in
          loop 1
        in
        let rec recover_validation_with_reprompt ~attempt keeper_result =
          match keeper_result with
          | Error (`Validation (failed_stage, validation_error, keeper_json)) -> (
              match infer_action_from_keeper_json keeper_json with
              | Some (reply_text, inferred_sa, inferred_reason) ->
                  statuses :=
                    `Assoc
                      [
                        ("actor_id", `String actor_id);
                        ("role", `String (role_to_string role));
                        ("keeper", `String keeper_name);
                        ("status", `String "inferred_pre_reprompt");
                        ("reason", `String inferred_reason);
                        ( "validation_error",
                          `String
                            (string_of_structured_action_validation_error
                               validation_error) );
                        ("action_type", `String (string_of_action_type inferred_sa.sa_type));
                        ("reply", `String reply_text);
                      ]
                    :: !statuses;
                  Ok (reply_text, inferred_sa)
              | None ->
                  (match validation_error with
                  | `Schema _ -> schema_failures := !schema_failures + 1
                  | `Rule _ ->
                      rule_validation_failures := !rule_validation_failures + 1);
                  if attempt > max_reprompt_attempts then
                    Error (`Validation (failed_stage, validation_error, keeper_json))
                  else
                    let stage = structured_action_error_kind validation_error in
                    let reason = structured_action_error_message validation_error in
                    reprompt_count := !reprompt_count + 1;
                    statuses :=
                      `Assoc
                        [
                          ("actor_id", `String actor_id);
                          ("role", `String (role_to_string role));
                          ("keeper", `String keeper_name);
                          ("status", `String "re_prompt");
                          ("stage", `String stage);
                          ("reason", `String reason);
                          ("attempt", `Int attempt);
                          ("max_attempts", `Int max_reprompt_attempts);
                        ]
                      :: !statuses;
                    let retry_prompt = re_prompt_message ~stage ~reason ~attempt in
                    let retry_stage = Printf.sprintf "re_prompt_%d" attempt in
                    let retry_result =
                      run_keeper_once ~stage:retry_stage ~message:retry_prompt
                    in
                    recover_validation_with_reprompt ~attempt:(attempt + 1)
                      retry_result)
          | other -> other
        in
        let keeper_result =
          run_keeper_once ~stage:"masc_keeper_msg" ~message:base_prompt
          |> recover_validation_with_reprompt ~attempt:1
        in
        match keeper_result with
        | Error (`Timeout stage) ->
            let* timeout_event, unavailable_result =
              append_timeout_and_unavailable_events
                ~store
                ~room_id
              ~phase
              ~turn:turn_before
              ~role
              ~actor_id
              ~keeper_name
              ~timeout_sec:keeper_timeout_sec
              ~sampling_state:unavailable_sampling
            in
            timeout_count := !timeout_count + 1;
            appended_events := !appended_events @ [ timeout_event ];
            let sampled, sampled_reason =
              match unavailable_result with
              | `Appended unavailable_event ->
                  unavailable_count := !unavailable_count + 1;
                  appended_events := !appended_events @ [ unavailable_event ];
                  (false, None)
              | `Sampled reason -> (true, Some reason)
            in
            statuses :=
              `Assoc
                [
                  ("actor_id", `String actor_id);
                  ("role", `String (role_to_string role));
                  ("keeper", `String keeper_name);
                  ("status", `String "timeout");
                  ("reason", `String "timeout");
                  ("stage", `String stage);
                  ("timeout_sec", `Float keeper_timeout_sec);
                  ("sampled", `Bool sampled);
                  ( "sampled_reason",
                    Option.fold ~none:`Null ~some:(fun v -> `String v)
                      sampled_reason );
                ]
              :: !statuses;
            if local_fallback then
              let* () =
                apply_local_fallback ~stage:"timeout_fallback" ~reason:"timeout"
              in
              Ok ()
            else Ok ()
        | Error (`Unavailable (stage, keeper_error)) ->
            let* () =
              record_unavailable_status
                ~reply_excerpt:None
                ~status:"unavailable"
                ~error:keeper_error
                ~stage
            in
            if local_fallback then
              apply_local_fallback ~stage:"keeper_call_fallback"
                ~reason:keeper_error
            else Ok ()
        | Error (`Validation (stage, validation_error, keeper_json)) ->
            (match validation_error with
            | `Schema _ -> schema_failures := !schema_failures + 1
            | `Rule _ ->
                rule_validation_failures := !rule_validation_failures + 1);
            let validation_error_msg =
              string_of_structured_action_validation_error validation_error
            in
            (* Server-side narrative inference: extract action from free-form text *)
            let inferred =
              if strict_agent_driven then None
              else
                match parse_keeper_reply keeper_json with
                | Ok reply_text
                  when not (is_low_signal_structured_description reply_text) ->
                    (match infer_action_type_from_narrative ~role reply_text with
                    | Some sa -> Some (reply_text, sa)
                    | None -> None)
                | Ok _ | Error _ -> None
            in
            (match inferred with
            | Some (reply_text, sa) ->
                let* reply_event =
                  append_keeper_reply_event
                    ~store ~room_id ~phase ~turn:turn_before
                    ~role ~actor_id ~keeper_name ~reply:reply_text
                in
                success_count := !success_count + 1;
                (match role with
                | `Dm ->
                    dm_success := true;
                    dm_reply_ref := Some reply_text
                | `Player -> player_success_count := !player_success_count + 1);
                appended_events := !appended_events @ [ reply_event ];
                let* action_events =
                  apply_structured_action ~store ~room_id
                    ~turn:turn_before ~phase ~actor_id ~state:state_json sa
                in
                appended_events := !appended_events @ action_events;
                let* observability_events =
                  append_round_observability_events ~store ~room_id ~phase
                    ~turn:turn_before ~role ~actor_id ~keeper_name
                    ~reply:reply_text ~sa ~action_events
                    ~resolution_source:"inferred" ~fallback:false
                in
                appended_events := !appended_events @ observability_events;
                (* Phase 1: Update BDI state after inferred reply *)
                update_bdi_after_reply ~reply_text ~sa;
                (* Phase 2: Harness evaluation — observation-only *)
                evaluate_keeper_response ~reply_text;
                register_player_reply_signature ~role ~actor_id ~reply:reply_text;
                statuses :=
                  `Assoc
                    [
                      ("actor_id", `String actor_id);
                      ("role", `String (role_to_string role));
                      ("keeper", `String keeper_name);
                      ("status", `String "inferred");
                      ("reply", `String reply_text);
                      ("action_type", `String (string_of_action_type sa.sa_type));
                    ]
                  :: !statuses;
                Ok ()
            | None ->
                let status_name =
                  match validation_error with
                  | `Schema _ -> "schema_invalid"
                  | `Rule _ -> "rule_invalid"
                in
                let reply_excerpt_opt =
                  match parse_keeper_reply keeper_json with
                  | Ok reply_text ->
                      let snippet = String.trim reply_text in
                      if snippet = "" then None
                      else Some (compact_summary_text ~max_len:240 snippet)
                  | Error _ -> None
                in
                let* () =
                  record_unavailable_status
                    ~reply_excerpt:reply_excerpt_opt
                    ~status:status_name
                    ~error:validation_error_msg
                    ~stage
                in
                if local_fallback then
                  apply_local_fallback ~stage:"validation_fallback"
                    ~reason:validation_error_msg
                else Ok ())
        | Ok (reply, sa) ->
            let* reply_event =
              append_keeper_reply_event
                ~store
                ~room_id
                ~phase
                ~turn:turn_before
                ~role
                ~actor_id
                ~keeper_name
                ~reply
            in
            success_count := !success_count + 1;
            (match role with
            | `Dm ->
                dm_success := true;
                dm_reply_ref := Some reply
            | `Player -> player_success_count := !player_success_count + 1);
            appended_events := !appended_events @ [ reply_event ];
            let* action_events =
              apply_structured_action ~store ~room_id
                ~turn:turn_before ~phase ~actor_id ~state:state_json sa
            in
            appended_events := !appended_events @ action_events;
            let* observability_events =
              append_round_observability_events ~store ~room_id ~phase
                ~turn:turn_before ~role ~actor_id ~keeper_name ~reply ~sa
                ~action_events ~resolution_source:"keeper" ~fallback:false
            in
            appended_events := !appended_events @ observability_events;
            let memory_status_fields =
              memory_status_fields_of_action_events action_events
            in
            (* Phase 1: Update BDI state after successful reply *)
            update_bdi_after_reply ~reply_text:reply ~sa;
            (* Phase 2: Harness evaluation — observation-only *)
            evaluate_keeper_response ~reply_text:reply;
            register_player_reply_signature ~role ~actor_id ~reply;
            statuses :=
              `Assoc
                ([
                   ("actor_id", `String actor_id);
                   ("role", `String (role_to_string role));
                   ("keeper", `String keeper_name);
                   ("status", `String "ok");
                   ("reply", `String reply);
                   ("action_type", `String (string_of_action_type sa.sa_type));
                 ]
                @ memory_status_fields)
              :: !statuses;
            Ok ()
      in

      let* () =
        List.fold_left
          (fun acc (actor_id, keeper_name) ->
            let* () = acc in
            process_one
              ~state_json:!state_for_players_ref
              ~role:`Player ~actor_id ~keeper_name)
          (Ok ())
          live_player_keepers
      in
      let player_required_successes =
        let total = active_player_count in
        if total <= 0 then 0 else max 1 ((total + 1) / 2)
      in
      let player_quorum_met =
        active_player_count > 0
        && !player_success_count + !player_fallback_count >= player_required_successes
      in
      let state_for_dm_prompt =
        if player_quorum_met then
          match derive_state ~store ~room_id ~rule_module with
          | Ok derived_after_players ->
              inject_interventions_into_state
                (state_of_derived derived_after_players)
                interventions_applied
              |> compact_state_for_prompt
          | Error _ -> !state_for_players_ref
        else !state_for_players_ref
      in
      let* () =
        if player_quorum_met then
          process_one
            ~state_json:state_for_dm_prompt
            ~role:`Dm ~actor_id:"dm" ~keeper_name:dm_keeper
        else (
          statuses :=
            `Assoc
              [
                ("actor_id", `String "dm");
                ("role", `String "dm");
                ("keeper", `String dm_keeper);
                ("status", `String "skipped");
                ( "reason",
                  `String
                    (Printf.sprintf
                       "player quorum not met: success=%d fallback=%d required=%d; dm execution skipped"
                       !player_success_count !player_fallback_count
                       player_required_successes) );
                ("stage", `String "player_quorum");
              ]
            :: !statuses;
          Ok () )
      in
      let* () =
        if phase = "round" && player_quorum_met && !dm_success then
          let existing_npc_attacks = count_npc_attacks_in_list !appended_events in
          if existing_npc_attacks > 0 then Ok ()
          else
            let state_for_pressure =
              match derive_state ~store ~room_id ~rule_module with
              | Ok derived_after_dm ->
                  inject_interventions_into_state
                    (state_of_derived derived_after_dm)
                    interventions_applied
              | Error _ -> state_for_dm_prompt
            in
            let* pressure_events =
              append_npc_counterattack_events ~store ~room_id ~phase
                ~turn:turn_before ~state:state_for_pressure
            in
            appended_events := !appended_events @ pressure_events;
            Ok ()
        else Ok ()
      in
      let advanced = player_quorum_met && !dm_success in
      let turn_after = if advanced then next_turn else turn_before in
      let* () =
        if advanced then
          let* turn_event =
            append_event
              ~store
              ~room_id
              ~event_type:Trpg_engine_event.Turn_started
              ~payload:(`Assoc [ ("turn", `Int next_turn) ])
              ()
          in
          appended_events := !appended_events @ [ turn_event ];
          Ok ()
        else Ok ()
      in
      let* next_derived = derive_state ~store ~room_id ~rule_module in
      let next_state = state_of_derived next_derived in
      let* computed_outcome =
        if outcome_already_emitted then (
          outcome_source_ref := !response_outcome_source;
          stagnation_level_ref := !response_stagnation_level;
          Ok None )
        else
          match
            evaluate_session_outcome ~end_rules
              ~max_turn_override:outcome_max_turn_override ~state:next_state
              ~dm_reply:!dm_reply_ref
          with
          | Some ((_, reason) as outcome) ->
              outcome_source_ref :=
                string_of_outcome_source (outcome_source_of_reason reason);
              stagnation_level_ref := 0;
              Ok (Some outcome)
          | None ->
              let all_events =
                match
                  store.read_events ~room_id
                with
                | Ok evs -> evs
                | Error _ -> []
              in
              let all_events = all_events @ !appended_events in
              if
                detect_stagnation ~events:all_events
                  ~threshold:stagnation_detection_turn_threshold
              then
                let prior_level =
                  latest_stagnation_pressure_level ~events:all_events
                in
                let next_level = prior_level + 1 in
                stagnation_level_ref := next_level;
                if next_level >= stagnation_escalation_threshold then (
                  outcome_source_ref := "stagnation";
                  Ok (Some (Draw, "stagnation")) )
                else
                  let pressure_payload =
                    `Assoc
                      [
                        ("event_type", `String "stagnation_pressure");
                        ("severity", `String "major");
                        ( "description",
                          `String
                            (Printf.sprintf
                               "Stagnation guard triggered (%d/%d): forcing higher stakes choices."
                               next_level stagnation_escalation_threshold) );
                        ("phase", `String phase);
                        ("turn", `Int turn_after);
                        ("stagnation_level", `Int next_level);
                        ( "stagnation_turn_threshold",
                          `Int stagnation_detection_turn_threshold );
                        ( "stagnation_escalation_threshold",
                          `Int stagnation_escalation_threshold );
                      ]
                  in
                  let* pressure_event =
                    append_event ~store ~room_id
                      ~event_type:Trpg_engine_event.World_event
                      ~payload:pressure_payload ()
                  in
                  stagnation_pressure_emitted := true;
                  appended_events := !appended_events @ [ pressure_event ];
                  statuses :=
                    `Assoc
                      [
                        ("actor_id", `String "system");
                        ("role", `String "system");
                        ("keeper", `String "system");
                        ("status", `String "stagnation_pressure");
                        ("reason", `String "stagnation_guard");
                        ("stage", `String "stagnation_guard");
                        ("stagnation_level", `Int next_level);
                      ]
                    :: !statuses;
                  Ok None
              else (
                stagnation_level_ref := 0;
                Ok None )
      in
      let* final_derived =
        match computed_outcome with
        | None ->
            if !stagnation_pressure_emitted then
              derive_state ~store ~room_id ~rule_module
            else Ok next_derived
        | Some (outcome, reason) ->
            let outcome_str = string_of_session_outcome outcome in
            let summary = summary_of_session_outcome outcome in
            let outcome_source =
              if !outcome_source_ref = "none" then
                string_of_outcome_source (outcome_source_of_reason reason)
              else !outcome_source_ref
            in
            let room_end_payload =
              `Assoc
                [
                  ("room_id", `String room_id);
                  ("reason", `String reason);
                  ("outcome", `String outcome_str);
                  ("outcome_source", `String outcome_source);
                ]
            in
            let outcome_payload =
              `Assoc
                [
                  ("outcome", `String outcome_str);
                  ("reason", `String reason);
                  ("summary", `String summary);
                  ("turn", `Int turn_after);
                  ("phase", `String phase);
                  ("outcome_source", `String outcome_source);
                  ("stagnation_level", `Int !stagnation_level_ref);
                ]
            in
            let* room_end_event_opt =
              if room_already_ended then Ok None
              else
                let* room_end_event =
                  append_event ~store ~room_id
                    ~event_type:Trpg_engine_event.Room_ended
                    ~payload:room_end_payload ()
                in
                Ok (Some room_end_event)
            in
            let* outcome_event =
              append_event ~store ~room_id
                ~event_type:Trpg_engine_event.Session_outcome
                ~payload:outcome_payload ()
            in
            (match room_end_event_opt with
            | Some room_end_event ->
                appended_events := !appended_events @ [ room_end_event ]
            | None -> ());
            appended_events := !appended_events @ [ outcome_event ];
            let importance_score =
              match outcome with
              | Victory -> 92
              | Defeat -> 88
              | Draw -> 72
            in
            let* memory_event =
              append_memory_signal_event ~store ~room_id ~event_tier:"long"
                ~importance_score
                ~summary_ko:(Printf.sprintf "세션 결과 확정: %s (%s)" outcome_str reason)
                ~summary_en:(Printf.sprintf "Session outcome finalized: %s (%s)" outcome_str reason)
                ~entity_refs:
                  [
                    ("outcome", `String outcome_str);
                    ("reason", `String reason);
                    ("turn", `Int turn_after);
                  ]
            in
            appended_events := !appended_events @ [ memory_event ];
            response_outcome_source := outcome_source;
            response_stagnation_level := !stagnation_level_ref;
            latest_outcome_payload := Some (ensure_outcome_payload_source outcome_payload);
            derive_state ~store ~room_id ~rule_module
      in
      let* _final_derived, final_state =
        let state_after_outcome = state_of_derived final_derived in
        let room_status =
          match state_after_outcome |> member "status" with
          | `String status -> String.lowercase_ascii status
          | _ -> "active"
        in
        if room_status = "ended" then Ok (final_derived, state_after_outcome)
        else
          let* join_window_opened_event =
            append_event
              ~store
              ~room_id
              ~event_type:Trpg_engine_event.Join_window_opened
              ~payload:
                (`Assoc
                  [
                    ("turn", `Int turn_after);
                    ("window", `String "round_boundary_only");
                    ("reason", `String "round_run_completed");
                  ])
              ()
          in
          appended_events := !appended_events @ [ join_window_opened_event ];
          let* reopened_derived = derive_state ~store ~room_id ~rule_module in
          Ok (reopened_derived, state_of_derived reopened_derived)
      in
      let canon_check =
        let session_events_after = existing_events_before @ !appended_events in
        evaluate_canon_check ~store ~state:final_state
          ~events:session_events_after ~dm_reply:!dm_reply_ref
      in
      let* canon_events =
        append_canon_check_observability_events ~store ~room_id
          ~turn:turn_after ~phase ~check:canon_check
      in
      appended_events := !appended_events @ canon_events;
      let statuses = List.rev !statuses in
      let progress_detail = status_first_non_ok_detail statuses in
      let dm_progress_detail =
        status_first_non_ok_detail_for_role ~role:"dm" statuses
      in
      let dm_non_ok_statuses =
        status_non_ok_detail_list_for_role ~role:"dm" ~max_items:5 statuses
      in
      let progress_reason =
        if advanced then "advanced"
        else if !timeout_count > 0 then "timeout"
        else if !schema_failures > 0 || !rule_validation_failures > 0 then
          "structured_action_invalid"
        else if !unavailable_count > 0 then "keeper_unavailable"
        else if not player_quorum_met then "player_quorum_not_met"
        else if not !dm_success then "dm_not_resolved"
        else if !fallback_count > 0 then "fallback_applied_no_progress"
        else "stalled"
      in
      let recovery_applied = !fallback_count > 0 in
      let recovery_mode =
        if recovery_applied then "local_fallback_applied"
        else if local_fallback then "local_fallback_enabled"
        else "none"
      in
      let roll_audit_all = build_round_roll_audit !appended_events in
      let roll_audit_count = List.length roll_audit_all in
      let roll_audit = take_first_n 8 roll_audit_all in
      let memory_signal_count, memory_guardrail_escalations =
        memory_observability_from_events !appended_events
      in
      let npc_spawned =
        count_event_type_in_list Trpg_engine_event.Actor_spawned !appended_events
      in
      let npc_attacks = count_npc_attacks_in_list !appended_events in
      let dm_style =
        match base_state_for_prompt |> member "config" with
        | `Assoc fields -> (
            match List.assoc_opt "dm" fields with
            | Some dm_json -> get_string_field dm_json "style"
            | None -> "")
        | _ -> ""
      in
      let dm_persona_used =
        infer_dm_persona_id
          ~explicit:(Option.bind dm_persona_override dm_persona_id_of_string)
          ~dm_style
      in
      let resolved_outcome_source =
        match !latest_outcome_payload with
        | Some payload -> outcome_source_from_payload payload
        | None ->
            if !outcome_source_ref <> "none" then !outcome_source_ref
            else !response_outcome_source
      in
      let resolved_stagnation_level =
        match !latest_outcome_payload with
        | Some payload -> stagnation_level_from_payload payload
        | None -> !stagnation_level_ref
      in
      response_outcome_source := resolved_outcome_source;
      response_stagnation_level := resolved_stagnation_level;
      let events_json = List.map Trpg_engine_event.to_yojson !appended_events in
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("phase", `String phase);
            ("turn_before", `Int turn_before);
            ("turn_after", `Int turn_after);
            ("timeout_sec", `Float timeout_sec);
            ( "preflight_warning",
              match preflight_warning with
              | Some warning -> `String warning
              | None -> `Null );
            ("statuses", `List statuses);
            ("interventions_applied", `List interventions_applied);
            ( "summary",
              `Assoc
                [
                  ("participants", `Int (1 + active_player_count));
                  ("successes", `Int !success_count);
                  ("fallbacks", `Int !fallback_count);
                  ("player_successes", `Int !player_success_count);
                  ("player_fallbacks", `Int !player_fallback_count);
                  ("player_required_successes", `Int player_required_successes);
                  ("player_quorum_met", `Bool player_quorum_met);
                  ("dm_success", `Bool !dm_success);
                  ("advanced", `Bool advanced);
                  ("progress_reason", `String progress_reason);
                  ( "progress_detail",
                    match progress_detail with
                    | Some detail -> `String detail
                    | None -> `Null );
                  ( "dm_progress_detail",
                    match dm_progress_detail with
                    | Some detail -> `String detail
                    | None -> `Null );
                  ( "dm_non_ok_statuses",
                    `List (List.map (fun detail -> `String detail) dm_non_ok_statuses) );
                  ("recovery_applied", `Bool recovery_applied);
                  ("recovery_mode", `String recovery_mode);
                    ("effective_timeout_sec", `Float timeout_sec);
                    ("requested_timeout_sec", `Float timeout_sec);
                    ("keeper_timeout_sec", `Float keeper_timeout_sec);
                  ("timeouts", `Int !timeout_count);
                  ("unavailable", `Int !unavailable_count);
                  ("schema_failures", `Int !schema_failures);
                  ("rule_validation_failures", `Int !rule_validation_failures);
                  ("reprompts", `Int !reprompt_count);
                  ("dm_persona", `String (string_of_dm_persona_id dm_persona_used));
                  ("dm_persona_overridden", `Bool (Option.is_some dm_persona_override));
                  ("npc_spawned", `Int npc_spawned);
                  ("npc_attacks", `Int npc_attacks);
                  ("interventions", `Int (List.length interventions_applied));
                  ("canon_status", `String canon_check.status);
                  ("canon_violation_count", `Int (List.length canon_check.violations));
                  ("canon_warning_count", `Int (List.length canon_check.warnings));
                  ("memory_signals", `Int memory_signal_count);
                  ("memory_guardrail_escalations", `Int memory_guardrail_escalations);
                  ("stagnation_level", `Int resolved_stagnation_level);
                  ("stagnation_turn_threshold", `Int stagnation_detection_turn_threshold);
                  ( "stagnation_escalation_threshold",
                    `Int stagnation_escalation_threshold );
                  ("outcome_source", `String resolved_outcome_source);
                  ("roll_audit_count", `Int roll_audit_count);
                  ("roll_audit", `List roll_audit);
                ] );
            ("canon_check", canon_check_to_yojson canon_check);
            ( "outcome",
              match !latest_outcome_payload with
              | Some payload -> payload
              | None -> `Null );
            ("outcome_source", `String resolved_outcome_source);
            ("stagnation_level", `Int resolved_stagnation_level);
            ("events", `List events_json);
            ( "room_status",
              match final_state |> member "status" with
              | `String status -> `String status
              | _ -> `String "active" );
            ("state", final_state);
          ]))
  in
  match result_json with Ok j -> ok_json j | Error e -> err e
