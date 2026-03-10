(** TRPG tool schemas — MCP tool definitions for TRPG sessions. *)

open Types

let schemas : tool_schema list =
  [
    {
      name = "masc_trpg_dice_roll";
      description =
        "Roll D20 for an actor and append dice.rolled event. \
         Required: room_id, actor_id, action, stat_value, dc. \
         Optional: raw_d20 (1-20), rule_module (default: dnd5e-lite).";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("actor_id", `Assoc [ ("type", `String "string") ]);
                  ("action", `Assoc [ ("type", `String "string") ]);
                  ("stat_value", `Assoc [ ("type", `String "integer") ]);
                  ("dc", `Assoc [ ("type", `String "integer") ]);
                  ("raw_d20", `Assoc [ ("type", `String "integer") ]);
                  ("rule_module", `Assoc [ ("type", `String "string") ]);
                ] );
            ( "required",
              `List
                [
                  `String "room_id";
                  `String "actor_id";
                  `String "action";
                  `String "stat_value";
                  `String "dc";
                ] );
          ];
    };
    {
      name = "masc_trpg_turn_advance";
      description =
        "Advance turn by appending turn.started and optional phase.changed event. \
         Required: room_id. Optional: phase, rule_module.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("phase", `Assoc [ ("type", `String "string") ]);
                  ("rule_module", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "room_id" ]);
          ];
    };
    {
      name = "masc_trpg_stream";
      description =
        "Read TRPG event stream window from storage. \
         Required: room_id. Optional: after_seq, event_type.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("after_seq", `Assoc [ ("type", `String "integer") ]);
                  ("event_type", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "room_id" ]);
          ];
    };
    {
      name = "masc_trpg_round_run";
      description =
        "Run one TRPG round by messaging DM keeper then player keepers. \
         Records strict timeout/unavailable events. \
         Required: room_id, dm_keeper, player_keepers(object actor_id->keeper_name). \
         Optional: phase(default round), rule_module(default dnd5e-lite), timeout_sec(default 90), keeper_timeout_sec(per-keeper override, must be <= timeout_sec), outcome_max_turn(integer: tighten session end turn cap for deterministic outcome), strict_agent_driven(boolean: disables inferred fallback and forces keeper-authored actions), strict_unique_player_reply(boolean: reject duplicated player narrative within a round), lang(ko|en), dm_persona(grim_gothic|tactical_irony|heroic_epic), require_claim(boolean), local_fallback(boolean).";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("dm_keeper", `Assoc [ ("type", `String "string") ]);
                  ( "player_keepers",
                    `Assoc
                      [
                        ("type", `String "object");
                        ("additionalProperties", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ("phase", `Assoc [ ("type", `String "string") ]);
                  ("rule_module", `Assoc [ ("type", `String "string") ]);
                  ("timeout_sec", `Assoc [ ("type", `String "number") ]);
                  ("keeper_timeout_sec", `Assoc [ ("type", `String "number") ]);
                  ("outcome_max_turn", `Assoc [ ("type", `String "integer") ]);
                  ("dm_persona", `Assoc [ ("type", `String "string") ]);
                  ("require_claim", `Assoc [ ("type", `String "boolean") ]);
                  ("lang", `Assoc [ ("type", `String "string") ]);
                  ( "strict_agent_driven",
                    `Assoc [ ("type", `String "boolean") ] );
                  ( "strict_unique_player_reply",
                    `Assoc [ ("type", `String "boolean") ] );
                  ( "local_fallback",
                    `Assoc [ ("type", `String "boolean") ] );
                ] );
            ( "required",
              `List
                [ `String "room_id"; `String "dm_keeper"; `String "player_keepers" ] );
          ];
    };
    {
      name = "masc_trpg_scene_transition";
      description =
        "Record a scene transition event. Tracks quest progression and narrative flow. \
         Required: room_id, from_scene, to_scene. \
         Optional: trigger, narrative_hook.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("from_scene", `Assoc [ ("type", `String "string") ]);
                  ("to_scene", `Assoc [ ("type", `String "string") ]);
                  ("trigger", `Assoc [ ("type", `String "string") ]);
                  ("narrative_hook", `Assoc [ ("type", `String "string") ]);
                ] );
            ( "required",
              `List [ `String "room_id"; `String "from_scene"; `String "to_scene" ] );
          ];
    };
    {
      name = "masc_trpg_quest_update";
      description =
        "Record a quest state change. Tracks quest progression (active/completed/failed) \
         and objective completion. \
         Required: room_id, quest_id, title, status. \
         Optional: objectives (array of {desc, done}).";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("quest_id", `Assoc [ ("type", `String "string") ]);
                  ("title", `Assoc [ ("type", `String "string") ]);
                  ( "status",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "active"; `String "completed"; `String "failed";
                            ] );
                      ] );
                  ( "objectives",
                    `Assoc
                      [
                        ("type", `String "array");
                        ( "items",
                          `Assoc
                            [
                              ("type", `String "object");
                              ( "properties",
                                `Assoc
                                  [
                                    ("desc", `Assoc [ ("type", `String "string") ]);
                                    ("done", `Assoc [ ("type", `String "boolean") ]);
                                  ] );
                            ] );
                      ] );
                ] );
            ( "required",
              `List
                [
                  `String "room_id";
                  `String "quest_id";
                  `String "title";
                  `String "status";
                ] );
          ];
    };
    {
      name = "masc_trpg_world_event";
      description =
        "Record a global world state change (weather, political shift, catastrophe, etc.). \
         Required: room_id, event_type, description. \
         Optional: affected_areas (string array), severity (minor/major/catastrophic).";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ( "event_type",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "description",
                          `String
                            "Type of world event (e.g. weather, political, disaster)" );
                      ] );
                  ("description", `Assoc [ ("type", `String "string") ]);
                  ( "affected_areas",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ( "severity",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "minor"; `String "major"; `String "catastrophic";
                            ] );
                      ] );
                ] );
            ( "required",
              `List
                [ `String "room_id"; `String "event_type"; `String "description" ] );
          ];
    };
    {
      name = "masc_trpg_preset_list";
      description =
        "List TRPG DM/world/character presets and game-usable agent skills from repo JSON SSOT.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("include_characters", `Assoc [ ("type", `String "boolean") ]);
                  ("include_skills", `Assoc [ ("type", `String "boolean") ]);
                ] );
          ];
    };
    {
      name = "masc_trpg_pool_generate";
      description =
        "Generate a playable character pool from presets. \
         Required: session_id. Optional: world_preset_id, dm_preset_id, pool_size, party_size, seed.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("world_preset_id", `Assoc [ ("type", `String "string") ]);
                  ("dm_preset_id", `Assoc [ ("type", `String "string") ]);
                  ("pool_size", `Assoc [ ("type", `String "integer") ]);
                  ("party_size", `Assoc [ ("type", `String "integer") ]);
                  ("seed", `Assoc [ ("type", `String "integer") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_trpg_party_select";
      description =
        "Select a party from generated pool and persist party.selected event. \
         Required: session_id, pool, selected_player_ids.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ( "pool",
                    `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "object") ]) ] );
                  ("selected_player_ids", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                ] );
            ( "required",
              `List [ `String "session_id"; `String "pool"; `String "selected_player_ids" ] );
          ];
    };
    {
      name = "masc_trpg_session_start";
      description =
        "Start a TRPG session from DM/world presets and selected party. \
         Required: session_id. Optional: room_id, dm/world preset ids, world_contract_id, canon_strict, dm_keeper, party, phase.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("dm_preset_id", `Assoc [ ("type", `String "string") ]);
                  ("world_preset_id", `Assoc [ ("type", `String "string") ]);
                  ("world_contract_id", `Assoc [ ("type", `String "string") ]);
                  ("canon_strict", `Assoc [ ("type", `String "boolean") ]);
                  ("dm_keeper", `Assoc [ ("type", `String "string") ]);
                  ("party", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "object") ]) ]);
                  ("phase", `Assoc [ ("type", `String "string") ]);
                  ("rule_module", `Assoc [ ("type", `String "string") ]);
                  ("force", `Assoc [ ("type", `String "boolean") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_trpg_actor_spawn";
      description =
        "Spawn an actor entity in room state. \
         Required: room_id. \
         Optional: actor_id (auto-generated when omitted), role(dm|player|npc), name, archetype, persona, portrait, background, stats(object), hp, max_hp, alive, traits, skills, inventory.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("actor_id", `Assoc [ ("type", `String "string") ]);
                  ("role", `Assoc [ ("type", `String "string") ]);
                  ("name", `Assoc [ ("type", `String "string") ]);
                  ("archetype", `Assoc [ ("type", `String "string") ]);
                  ("persona", `Assoc [ ("type", `String "string") ]);
                  ("portrait", `Assoc [ ("type", `String "string") ]);
                  ("background", `Assoc [ ("type", `String "string") ]);
                  ("stats", `Assoc [ ("type", `String "object") ]);
                  ("hp", `Assoc [ ("type", `String "integer") ]);
                  ("max_hp", `Assoc [ ("type", `String "integer") ]);
                  ("alive", `Assoc [ ("type", `String "boolean") ]);
                  ("traits", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("skills", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("inventory", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                ] );
            ("required", `List [ `String "room_id" ]);
          ];
    };
    {
      name = "masc_trpg_actor_update";
      description =
        "Update an existing actor entity in room state. \
         Required: room_id, actor_id. \
         Optional: role(dm|player|npc), name, archetype, persona, portrait, background, stats(object), hp, max_hp, alive, traits, skills, inventory.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("actor_id", `Assoc [ ("type", `String "string") ]);
                  ("role", `Assoc [ ("type", `String "string") ]);
                  ("name", `Assoc [ ("type", `String "string") ]);
                  ("archetype", `Assoc [ ("type", `String "string") ]);
                  ("persona", `Assoc [ ("type", `String "string") ]);
                  ("portrait", `Assoc [ ("type", `String "string") ]);
                  ("background", `Assoc [ ("type", `String "string") ]);
                  ("stats", `Assoc [ ("type", `String "object") ]);
                  ("hp", `Assoc [ ("type", `String "integer") ]);
                  ("max_hp", `Assoc [ ("type", `String "integer") ]);
                  ("alive", `Assoc [ ("type", `String "boolean") ]);
                  ("traits", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("skills", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("inventory", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                ] );
            ("required", `List [ `String "room_id"; `String "actor_id" ]);
          ];
    };
    {
      name = "masc_trpg_actor_delete";
      description =
        "Delete an actor entity from room state and release its lease. \
         Required: room_id, actor_id. Optional: reason.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("actor_id", `Assoc [ ("type", `String "string") ]);
                  ("reason", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "room_id"; `String "actor_id" ]);
          ];
    };
    {
      name = "masc_trpg_actor_claim";
      description =
        "Claim an actor lease for a keeper. \
         Required: room_id, actor_id, keeper_name. \
         Optional: keeper_style, keeper_description (when provided, response includes match_score). \
         Enforces one keeper -> one actor and denies claim when actor is dead.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("actor_id", `Assoc [ ("type", `String "string") ]);
                  ("keeper_name", `Assoc [ ("type", `String "string") ]);
                  ("keeper_style", `Assoc [ ("type", `String "string") ]);
                  ("keeper_description", `Assoc [ ("type", `String "string") ]);
                ] );
            ( "required",
              `List [ `String "room_id"; `String "actor_id"; `String "keeper_name" ] );
          ];
    };
    {
      name = "masc_trpg_actor_release";
      description =
        "Release an actor lease held by a keeper. \
         Required: room_id, actor_id, keeper_name. Optional: reason.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("actor_id", `Assoc [ ("type", `String "string") ]);
                  ("keeper_name", `Assoc [ ("type", `String "string") ]);
                  ("reason", `Assoc [ ("type", `String "string") ]);
                ] );
            ( "required",
              `List [ `String "room_id"; `String "actor_id"; `String "keeper_name" ] );
          ];
    };
    {
      name = "masc_trpg_join_eligibility";
      description =
        "Check whether an actor is eligible for mid-session join under hard gate policy. \
         Required: room_id, actor_id. Optional: keeper_name, rule_module.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("actor_id", `Assoc [ ("type", `String "string") ]);
                  ("keeper_name", `Assoc [ ("type", `String "string") ]);
                  ("rule_module", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "room_id"; `String "actor_id" ]);
          ];
    };
    {
      name = "masc_trpg_mid_join_request";
      description =
        "Request a hard-gated mid-session join (round-boundary only + contribution threshold). \
         Required: room_id, actor_id, keeper_name. \
         Optional: role, name, archetype, persona, hp, max_hp, traits, skills, inventory, rule_module.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("actor_id", `Assoc [ ("type", `String "string") ]);
                  ("keeper_name", `Assoc [ ("type", `String "string") ]);
                  ("role", `Assoc [ ("type", `String "string") ]);
                  ("name", `Assoc [ ("type", `String "string") ]);
                  ("archetype", `Assoc [ ("type", `String "string") ]);
                  ("persona", `Assoc [ ("type", `String "string") ]);
                  ("hp", `Assoc [ ("type", `String "integer") ]);
                  ("max_hp", `Assoc [ ("type", `String "integer") ]);
                  ("traits", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("skills", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("inventory", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("rule_module", `Assoc [ ("type", `String "string") ]);
                ] );
            ( "required",
              `List [ `String "room_id"; `String "actor_id"; `String "keeper_name" ] );
          ];
    };
    {
      name = "masc_trpg_actor_match";
      description =
        "Rank keepers by compatibility with actors using trait overlap, archetype affinity, \
         and semantic alignment. Returns scored rankings per actor. \
         Required: room_id, keepers (array of {name, style, description}). \
         Optional: actor_id (single actor), rule_module.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ( "keepers",
                    `Assoc
                      [
                        ("type", `String "array");
                        ( "items",
                          `Assoc
                            [
                              ("type", `String "object");
                              ( "properties",
                                `Assoc
                                  [
                                    ("name", `Assoc [ ("type", `String "string") ]);
                                    ("style", `Assoc [ ("type", `String "string") ]);
                                    ("description", `Assoc [ ("type", `String "string") ]);
                                  ] );
                              ("required", `List [ `String "name"; `String "style"; `String "description" ]);
                            ] );
                      ] );
                  ("actor_id", `Assoc [ ("type", `String "string") ]);
                  ("rule_module", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "room_id"; `String "keepers" ]);
          ];
    };
    {
      name = "masc_trpg_intervention_submit";
      description =
        "Submit a human intervention to apply before next AI round run. \
         Required: room_id, intervention_type. Optional: scope, target_actor, expected_turn, payload.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("intervention_type", `Assoc [ ("type", `String "string") ]);
                  ("scope", `Assoc [ ("type", `String "string") ]);
                  ("target_actor", `Assoc [ ("type", `String "string") ]);
                  ("expected_turn", `Assoc [ ("type", `String "integer") ]);
                  ("reason", `Assoc [ ("type", `String "string") ]);
                  ("payload", `Assoc [ ("type", `String "object") ]);
                ] );
            ("required", `List [ `String "room_id"; `String "intervention_type" ]);
          ];
    };
  ]
