(** Trpg_round_run_process — Extracted process_one logic from handle_round_run.

    Contains the per-actor keeper call, validation, fallback, BDI update,
    harness evaluation, and status recording logic.

    All outer-scope state is passed via {!Trpg_round_run_ctx.round_ctx}. *)

include Trpg_handlers
open Trpg_round_run_ctx

let make_default_sa ~role ~description ~source =
  let sa_type, flag_key, type_str, extra_payload =
    match role with
    | `Player -> (Attack, None, "attack", [])
    | `Dm ->
        ( SetFlag, Some "story.recovered", "set_flag",
          [ ("flag_key", `String "story.recovered") ] )
  in
  {
    sa_type;
    target_id = None;
    description;
    flag_key;
    scene = None;
    quest_info = None;
    memory_hint = None;
    raw_payload =
      `Assoc
        ([ ("type", `String type_str);
           ("description", `String description);
           ("inferred", `Bool true);
           ("source", `String source) ]
        @ extra_payload);
  }

let duplicate_player_reply_actor rctx ~actor_id ~reply =
  let signature = normalize_reply_for_comparison reply in
  if signature = "" then None
  else
    !(rctx.seen_player_reply_signatures)
    |> List.find_map (fun (prev_actor_id, prev_signature) ->
           if prev_signature = signature && prev_actor_id <> actor_id then
             Some prev_actor_id
           else None)

let register_player_reply_signature rctx ~role ~actor_id ~reply =
  match role with
  | `Dm -> ()
  | `Player ->
      let signature = normalize_reply_for_comparison reply in
      if signature <> "" then
        rctx.seen_player_reply_signatures :=
          (actor_id, signature) :: !(rctx.seen_player_reply_signatures)

let process_one rctx ~state_json ~role ~actor_id ~keeper_name =
  let ( let* ) = Result.bind in
  let { store; room_id; phase; turn_before; rule_module; prompt_lang;
        keeper_timeout_sec; local_fallback; strict_agent_driven;
        strict_unique_player_reply; require_claim; dm_persona_override;
        unavailable_sampling; _ } = rctx in
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
          rctx.unavailable_count := !(rctx.unavailable_count) + 1;
          rctx.appended_events := !(rctx.appended_events) @ [ unavailable_event ];
          (false, None)
      | `Sampled reason -> (true, Some reason)
    in
    rctx.statuses :=
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
      :: !(rctx.statuses);
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
          rctx.appended_events := !(rctx.appended_events) @ [ spawn_event ]
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
        make_default_sa ~role ~description:fallback_reply ~source:"round_fallback"
      in
      rctx.fallback_count := !(rctx.fallback_count) + 1;
      (* NOTE: fallback does NOT increment success_count.
         Fallbacks are placeholder responses — counting them as success
         masks stagnation and prevents the game from detecting
         that no meaningful action occurred. *)
      (match role with
      | `Dm ->
          rctx.dm_success := true;
          rctx.dm_reply_ref := Some fallback_reply
      | `Player ->
          rctx.player_fallback_count := !(rctx.player_fallback_count) + 1);
      rctx.appended_events := !(rctx.appended_events) @ [ reply_event ];
      let* action_events =
        let payload =
          `Assoc
            [
              ("phase", `String phase);
              ("turn", `Int turn_before);
              ("role", `String (role_to_string role));
              ("actor_id", `String actor_id);
              ("keeper", `String keeper_name);
              ("narration", `String fallback_reply);
              ("is_fallback", `Bool true);
            ]
        in
        let* event =
          append_event ~store ~room_id
            ~event_type:Trpg.Engine_event.Narration_posted
            ~actor_id ~payload ()
        in
        Ok [ event ]
      in
      rctx.appended_events := !(rctx.appended_events) @ action_events;
      let* observability_events =
        append_round_observability_events ~store ~room_id ~phase
          ~turn:turn_before ~role ~actor_id ~keeper_name ~reply:fallback_reply
          ~sa:fallback_sa ~action_events ~resolution_source:"fallback"
          ~fallback:true
      in
      rctx.appended_events := !(rctx.appended_events) @ observability_events;
      let* pressure_events =
        match role with
        | `Dm ->
            append_npc_counterattack_events ~store ~room_id ~phase
              ~turn:turn_before ~state:state_for_pressure
        | `Player -> Ok []
      in
      rctx.appended_events := !(rctx.appended_events) @ pressure_events;
      rctx.statuses :=
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
        :: !(rctx.statuses);
      Ok ()
  in
  (* Phase 1: BDI state update after successful keeper reply.
     Observation-only — errors are logged but never block the main path. *)
  let update_bdi_after_reply ~reply_text ~sa =
    let room_dir = store.Trpg.Store.room_dir ~room_id in
    let bdi0 = Trpg.Bdi.load ~room_dir ~actor_id in
    let bdi1 = Trpg.Bdi.decay_beliefs ~current_turn:turn_before bdi0 in
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
      Trpg.Bdi.update_belief
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
          Trpg.Bdi.update_desire
            ~goal:"survive combat" ~priority:0.9 ~category:"survival" bdi2
      | Heal ->
          Trpg.Bdi.update_desire
            ~goal:"recover health" ~priority:0.8 ~category:"survival" bdi2
      | Social ->
          Trpg.Bdi.update_desire
            ~goal:"build relationships" ~priority:0.6 ~category:"social" bdi2
      | Investigate | Explore ->
          Trpg.Bdi.update_desire
            ~goal:"discover information" ~priority:0.7 ~category:"quest" bdi2
      | QuestUpdate ->
          Trpg.Bdi.update_desire
            ~goal:"advance quest" ~priority:0.8 ~category:"quest" bdi2
      | Magic | UseItem | SetFlag | SceneTransition -> bdi2
    in
    (* Save BDI state — ignore errors (observation-only) *)
    let _save_result = Trpg.Bdi.save ~room_dir bdi3 in
    (* Emit Bdi_updated event — ignore errors *)
    let _event_result =
      append_event ~store ~room_id
        ~event_type:Trpg.Engine_event.Bdi_updated
        ~actor_id
        ~payload:(Trpg.Bdi.to_yojson bdi3)
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
        match Llm_cascade.model_spec_of_string tier1_str with
        | Ok m -> m
        | Error _ -> (
            match Llm_cascade.default_verifier_model_spec () with
            | Ok model -> model
            | Error _ -> Llm_types.glm_cloud)
      in
      let tier2_model =
        match Sys.getenv_opt "TRPG_HARNESS_TIER2_MODEL" with
        | Some s -> (
            match Llm_cascade.model_spec_of_string s with
            | Ok m -> m
            | Error _ -> Llm_types.glm_cloud)
        | None -> Llm_types.glm_cloud
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
          ~event_type:Trpg.Engine_event.Evaluation_scored
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
        match owner_for_actor state_json actor_id with
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
      (match duplicate_player_reply_actor rctx ~actor_id ~reply:normalized_reply with
      | Some other_actor ->
          if strict_unique_player_reply then
            Error
              (`Rule
                 (Printf.sprintf
                    "reply duplicates another player action this round (%s); choose a distinct move"
                    other_actor))
          else (
            rctx.statuses :=
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
              :: !(rctx.statuses);
            Ok (normalized_reply, normalized_sa))
      | None -> Ok (normalized_reply, normalized_sa))
    else Ok (normalized_reply, normalized_sa)
  in
  let synthetic_action_for_reply reply_text =
    match infer_action_type_from_narrative ~role reply_text with
    | Some sa -> sa
    | None -> make_default_sa ~role ~description:reply_text ~source:"synthetic_fallback"
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
                (duplicate_player_reply_actor rctx ~actor_id
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
        call_keeper rctx.ctx ~name:keeper_name ~message
          ~timeout_sec:keeper_timeout_sec
      with
      | `Timeout when attempt < keeper_call_max_attempts ->
          rctx.statuses :=
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
            :: !(rctx.statuses);
          loop (attempt + 1)
      | `Timeout -> Error (`Timeout stage)
      | `Error err
        when attempt < keeper_call_max_attempts
             && is_retryable_keeper_error err ->
          rctx.statuses :=
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
            :: !(rctx.statuses);
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
            rctx.statuses :=
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
              :: !(rctx.statuses);
            Ok (reply_text, inferred_sa)
        | None ->
            (match validation_error with
            | `Schema _ -> rctx.schema_failures := !(rctx.schema_failures) + 1
            | `Rule _ ->
                rctx.rule_validation_failures := !(rctx.rule_validation_failures) + 1);
            if attempt > max_reprompt_attempts then
              Error (`Validation (failed_stage, validation_error, keeper_json))
            else
              let stage = structured_action_error_kind validation_error in
              let reason = structured_action_error_message validation_error in
              rctx.reprompt_count := !(rctx.reprompt_count) + 1;
              rctx.statuses :=
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
                :: !(rctx.statuses);
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
      rctx.timeout_count := !(rctx.timeout_count) + 1;
      rctx.appended_events := !(rctx.appended_events) @ [ timeout_event ];
      let sampled, sampled_reason =
        match unavailable_result with
        | `Appended unavailable_event ->
            rctx.unavailable_count := !(rctx.unavailable_count) + 1;
            rctx.appended_events := !(rctx.appended_events) @ [ unavailable_event ];
            (false, None)
        | `Sampled reason -> (true, Some reason)
      in
      rctx.statuses :=
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
        :: !(rctx.statuses);
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
      | `Schema _ -> rctx.schema_failures := !(rctx.schema_failures) + 1
      | `Rule _ ->
          rctx.rule_validation_failures := !(rctx.rule_validation_failures) + 1);
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
          rctx.success_count := !(rctx.success_count) + 1;
          (match role with
          | `Dm ->
              rctx.dm_success := true;
              rctx.dm_reply_ref := Some reply_text
          | `Player -> rctx.player_success_count := !(rctx.player_success_count) + 1);
          rctx.appended_events := !(rctx.appended_events) @ [ reply_event ];
          let* action_events =
            apply_structured_action ~store ~room_id
              ~turn:turn_before ~phase ~actor_id ~state:state_json sa
          in
          rctx.appended_events := !(rctx.appended_events) @ action_events;
          let* observability_events =
            append_round_observability_events ~store ~room_id ~phase
              ~turn:turn_before ~role ~actor_id ~keeper_name
              ~reply:reply_text ~sa ~action_events
              ~resolution_source:"inferred" ~fallback:false
          in
          rctx.appended_events := !(rctx.appended_events) @ observability_events;
          (* Phase 1: Update BDI state after inferred reply *)
          update_bdi_after_reply ~reply_text ~sa;
          (* Phase 2: Harness evaluation — observation-only *)
          evaluate_keeper_response ~reply_text;
          register_player_reply_signature rctx ~role ~actor_id ~reply:reply_text;
          rctx.statuses :=
            `Assoc
              [
                ("actor_id", `String actor_id);
                ("role", `String (role_to_string role));
                ("keeper", `String keeper_name);
                ("status", `String "inferred");
                ("reply", `String reply_text);
                ("action_type", `String (string_of_action_type sa.sa_type));
              ]
            :: !(rctx.statuses);
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
      rctx.success_count := !(rctx.success_count) + 1;
      (match role with
      | `Dm ->
          rctx.dm_success := true;
          rctx.dm_reply_ref := Some reply
      | `Player -> rctx.player_success_count := !(rctx.player_success_count) + 1);
      rctx.appended_events := !(rctx.appended_events) @ [ reply_event ];
      let* action_events =
        apply_structured_action ~store ~room_id
          ~turn:turn_before ~phase ~actor_id ~state:state_json sa
      in
      rctx.appended_events := !(rctx.appended_events) @ action_events;
      let* observability_events =
        append_round_observability_events ~store ~room_id ~phase
          ~turn:turn_before ~role ~actor_id ~keeper_name ~reply ~sa
          ~action_events ~resolution_source:"keeper" ~fallback:false
      in
      rctx.appended_events := !(rctx.appended_events) @ observability_events;
      let memory_status_fields =
        memory_status_fields_of_action_events action_events
      in
      (* Phase 1: Update BDI state after successful reply *)
      update_bdi_after_reply ~reply_text:reply ~sa;
      (* Phase 2: Harness evaluation — observation-only *)
      evaluate_keeper_response ~reply_text:reply;
      register_player_reply_signature rctx ~role ~actor_id ~reply;
      rctx.statuses :=
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
        :: !(rctx.statuses);
      Ok ()
