(** Unified protocol gateway for GAME-VIEW domains.

    Canonical API (dot namespace):
    - decision.*
    - trpg.*
    - client.*

    Legacy compatibility:
    - masc_trpg_* are kept as aliases for a deprecation window.
*)

include Tool_protocol_game_view_handlers

let legacy_alias_to_canonical = function
  | "masc_trpg_dice_roll" -> Some "trpg.dice.roll"
  | "masc_trpg_turn_advance" -> Some "trpg.turn.advance"
  | "masc_trpg_stream" -> Some "trpg.stream.read"
  | "masc_trpg_round_run" -> Some "trpg.round.run"
  | "masc_trpg_preset_list" -> Some "trpg.preset.list"
  | "masc_trpg_pool_generate" -> Some "trpg.pool.generate"
  | "masc_trpg_party_select" -> Some "trpg.party.select"
  | "masc_trpg_session_start" -> Some "trpg.session.start"
  | "masc_trpg_actor_spawn" -> Some "trpg.actor.spawn"
  | "masc_trpg_actor_update" -> Some "trpg.actor.update"
  | "masc_trpg_actor_delete" -> Some "trpg.actor.delete"
  | "masc_trpg_actor_claim" -> Some "trpg.actor.claim"
  | "masc_trpg_actor_release" -> Some "trpg.actor.release"
  | "masc_trpg_join_eligibility" -> Some "trpg.join.eligibility"
  | "masc_trpg_mid_join_request" -> Some "trpg.mid_join.request"
  | "masc_trpg_intervention_submit" -> Some "trpg.intervention.submit"
  | "masc_trpg_scene_transition" -> Some "trpg.scene.transition"
  | "masc_trpg_quest_update" -> Some "trpg.quest.update"
  | "masc_trpg_world_event" -> Some "trpg.world.event"
  | _ -> None

let handle_legacy_alias (ctx : context) ~legacy_name ~canonical_tool args :
    tool_result =
  broadcast_deprecated_alias ~agent_name:ctx.agent_name ~legacy_tool:legacy_name
    ~canonical_tool;
  match legacy_name with
  | name when String.starts_with ~prefix:"masc_trpg_" name -> (
      match delegate_trpg ctx ~legacy_name:name ~args with
      | Some r -> r
      | None ->
          (false, Printf.sprintf "legacy trpg dispatcher unavailable for %s" name))
  | _ ->
      Log.Dispatch.info "NOT_IMPLEMENTED: legacy alias %s -> %s"
        legacy_name canonical_tool;
      err_json ~canonical_tool ~legacy_alias:legacy_name ~code:"NOT_IMPLEMENTED"
        ~message:
          (Printf.sprintf "legacy alias not supported: %s -> %s. Use canonical tool names from dispatch table." legacy_name canonical_tool)
        ()

let dispatch (ctx : context) ~name ~args : tool_result option =
  match name with
  | "decision.create" ->
      Some
        (match handle_decision_create ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "decision.finalize" ->
      Some
        (match handle_decision_finalize ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "decision.status" ->
      Some
        (match handle_decision_status ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "trpg.action.submit" ->
      Some
        (match handle_trpg_action_submit ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "trpg.world.query" ->
      Some
        (match handle_trpg_world_query ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "trpg.preset.list" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_preset_list" args)
  | "trpg.pool.generate" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_pool_generate" args)
  | "trpg.party.select" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_party_select" args)
  | "trpg.session.start" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_session_start" args)
  | "trpg.actor.spawn" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_actor_spawn" args)
  | "trpg.actor.update" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_actor_update" args)
  | "trpg.actor.delete" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_actor_delete" args)
  | "trpg.actor.claim" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_actor_claim" args)
  | "trpg.actor.release" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_actor_release" args)
  | "trpg.join.eligibility" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_join_eligibility" args)
  | "trpg.mid_join.request" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_mid_join_request" args)
  | "trpg.intervention.submit" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_intervention_submit" args)
  | "trpg.dice.roll" ->
      Some (handle_trpg_canonical ctx ~canonical_tool:name ~legacy_name:"masc_trpg_dice_roll" args)
  | "trpg.turn.advance" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_turn_advance" args)
  | "trpg.stream.read" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_stream" args)
  | "trpg.round.run" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_round_run" args)
  | "trpg.scene.transition" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_scene_transition" args)
  | "trpg.quest.update" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_quest_update" args)
  | "trpg.world.event" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_world_event" args)
  | "client.session.open" ->
      Some
        (match handle_client_session_open ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "client.state.subscribe" ->
      Some
        (match handle_client_state_subscribe ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "client.input.submit" ->
      Some
        (match handle_client_input_submit ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "client.input.approve" ->
      Some
        (match
           handle_client_input_transition ctx ~canonical_tool:name
             ~status:Game_view_state.Approved
             ~default_reason:""
             args
         with
        | Ok r -> r
        | Error e -> e)
  | "client.input.reject" ->
      Some
        (match
           handle_client_input_transition ctx ~canonical_tool:name
             ~status:Game_view_state.Rejected
             ~default_reason:"rejected"
             args
         with
        | Ok r -> r
        | Error e -> e)
  | "client.snapshot.get" ->
      Some
        (match handle_client_snapshot_get ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | legacy -> (
      match legacy_alias_to_canonical legacy with
      | Some canonical_tool ->
          Some (handle_legacy_alias ctx ~legacy_name:legacy ~canonical_tool args)
      | None -> None)

let string_schema = `Assoc [ ("type", `String "string") ]
let number_schema = `Assoc [ ("type", `String "number") ]
let int_schema = `Assoc [ ("type", `String "integer") ]
let bool_schema = `Assoc [ ("type", `String "boolean") ]

let array_of schema =
  `Assoc [ ("type", `String "array"); ("items", schema) ]

let object_schema ?(required = []) properties =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc properties);
      ("required", `List (List.map (fun k -> `String k) required));
    ]

let schema name description input_schema : Types.tool_schema =
  { name; description; input_schema }

let schemas : Types.tool_schema list =
  [
    schema "decision.create"
      "Create a decision record for a session."
      (object_schema
         ~required:[ "session_id"; "issue"; "options" ]
         [
           ("session_id", string_schema);
           ("issue", string_schema);
           ("options", array_of string_schema);
           ("criteria", array_of string_schema);
           ("weights", object_schema []);
         ]);
    schema "decision.finalize"
      "Finalize a decision. If verifier=WARN, risk_ack is required."
      (object_schema
         ~required:[ "session_id"; "decision_id"; "selected_option"; "rationale" ]
         [
           ("session_id", string_schema);
           ("decision_id", string_schema);
           ("selected_option", string_schema);
           ("rationale", string_schema);
           ("confidence", number_schema);
           ("verifier", string_schema);
           ("risk_ack", string_schema);
         ]);
    schema "decision.status"
      "Get latest decision status for a session or a specific decision_id."
      (object_schema
         ~required:[ "session_id" ]
         [ ("session_id", string_schema); ("decision_id", string_schema) ]);
    schema "trpg.action.submit"
      "Submit TRPG action under decision gate and persist to TRPG event stream."
      (object_schema
         ~required:[ "session_id"; "action" ]
         [
           ("session_id", string_schema);
           ("decision_id", string_schema);
           ("room_id", string_schema);
           ("action", string_schema);
           ("intent", string_schema);
           ("stakes", string_schema);
         ]);
    schema "trpg.world.query"
      "Query agent-visible world projection for TRPG room."
      (object_schema
         ~required:[ "session_id" ]
         [
           ("session_id", string_schema);
           ("agent", string_schema);
           ("room_id", string_schema);
           ("after_seq", int_schema);
           ("event_limit", int_schema);
         ]);
    schema "trpg.preset.list"
      "Canonical alias of masc_trpg_preset_list."
      (object_schema
         [
           ("include_characters", bool_schema);
           ("include_skills", bool_schema);
         ]);
    schema "trpg.pool.generate"
      "Canonical alias of masc_trpg_pool_generate."
      (object_schema
         ~required:[ "session_id" ]
         [
           ("session_id", string_schema);
           ("world_preset_id", string_schema);
           ("dm_preset_id", string_schema);
           ("pool_size", int_schema);
           ("party_size", int_schema);
           ("seed", int_schema);
         ]);
    schema "trpg.party.select"
      "Canonical alias of masc_trpg_party_select."
      (object_schema
         ~required:[ "session_id"; "pool"; "selected_player_ids" ]
         [
           ("session_id", string_schema);
           ("room_id", string_schema);
           ("pool", array_of (object_schema []));
           ("selected_player_ids", array_of string_schema);
         ]);
    schema "trpg.session.start"
      "Canonical alias of masc_trpg_session_start."
      (object_schema
         ~required:[ "session_id" ]
         [
           ("session_id", string_schema);
           ("room_id", string_schema);
           ("dm_preset_id", string_schema);
           ("world_preset_id", string_schema);
           ("dm_keeper", string_schema);
           ("party", array_of (object_schema []));
           ("phase", string_schema);
           ("rule_module", string_schema);
           ("force", bool_schema);
         ]);
    schema "trpg.actor.spawn"
      "Canonical alias of masc_trpg_actor_spawn."
      (object_schema
         ~required:[ "room_id" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("role", string_schema);
           ("name", string_schema);
           ("archetype", string_schema);
           ("persona", string_schema);
           ("portrait", string_schema);
           ("background", string_schema);
           ("stats", object_schema []);
           ("hp", int_schema);
           ("max_hp", int_schema);
           ("alive", bool_schema);
           ("traits", array_of string_schema);
           ("skills", array_of string_schema);
           ("inventory", array_of string_schema);
         ]);
    schema "trpg.actor.update"
      "Canonical alias of masc_trpg_actor_update."
      (object_schema
         ~required:[ "room_id"; "actor_id" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("role", string_schema);
           ("name", string_schema);
           ("archetype", string_schema);
           ("persona", string_schema);
           ("portrait", string_schema);
           ("background", string_schema);
           ("stats", object_schema []);
           ("hp", int_schema);
           ("max_hp", int_schema);
           ("alive", bool_schema);
           ("traits", array_of string_schema);
           ("skills", array_of string_schema);
           ("inventory", array_of string_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.actor.delete"
      "Canonical alias of masc_trpg_actor_delete."
      (object_schema
         ~required:[ "room_id"; "actor_id" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("reason", string_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.actor.claim"
      "Canonical alias of masc_trpg_actor_claim."
      (object_schema
         ~required:[ "room_id"; "actor_id"; "keeper_name" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("keeper_name", string_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.actor.release"
      "Canonical alias of masc_trpg_actor_release."
      (object_schema
         ~required:[ "room_id"; "actor_id"; "keeper_name" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("keeper_name", string_schema);
           ("reason", string_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.join.eligibility"
      "Canonical alias of masc_trpg_join_eligibility."
      (object_schema
         ~required:[ "room_id"; "actor_id" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("keeper_name", string_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.mid_join.request"
      "Canonical alias of masc_trpg_mid_join_request."
      (object_schema
         ~required:[ "room_id"; "actor_id"; "keeper_name" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("keeper_name", string_schema);
           ("role", string_schema);
           ("name", string_schema);
           ("archetype", string_schema);
           ("persona", string_schema);
           ("hp", int_schema);
           ("max_hp", int_schema);
           ("traits", array_of string_schema);
           ("skills", array_of string_schema);
           ("inventory", array_of string_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.intervention.submit"
      "Canonical alias of masc_trpg_intervention_submit."
      (object_schema
         ~required:[ "room_id"; "intervention_type" ]
         [
           ("room_id", string_schema);
           ("session_id", string_schema);
           ("intervention_type", string_schema);
           ("scope", string_schema);
           ("target_actor", string_schema);
           ("expected_turn", int_schema);
           ("reason", string_schema);
           ("payload", object_schema []);
         ]);
    schema "trpg.dice.roll"
      "Canonical alias of masc_trpg_dice_roll."
      (object_schema
         ~required:[ "room_id"; "actor_id"; "action"; "stat_value"; "dc" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("action", string_schema);
           ("stat_value", int_schema);
           ("dc", int_schema);
           ("raw_d20", int_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.turn.advance"
      "Canonical alias of masc_trpg_turn_advance."
      (object_schema
         ~required:[ "room_id" ]
         [
           ("room_id", string_schema);
           ("phase", string_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.stream.read"
      "Canonical alias of masc_trpg_stream."
      (object_schema
         ~required:[ "room_id" ]
         [
           ("room_id", string_schema);
           ("after_seq", int_schema);
           ("event_type", string_schema);
         ]);
    schema "trpg.round.run"
      "Canonical alias of masc_trpg_round_run."
      (object_schema
         ~required:[ "room_id"; "dm_keeper"; "player_keepers" ]
         [
           ("room_id", string_schema);
           ("dm_keeper", string_schema);
           ("player_keepers", object_schema []);
           ("phase", string_schema);
           ("rule_module", string_schema);
           ("timeout_sec", number_schema);
           ("dm_persona", string_schema);
           ("require_claim", bool_schema);
           ("local_fallback", bool_schema);
         ]);
    schema "trpg.scene.transition"
      "Canonical alias of masc_trpg_scene_transition."
      (object_schema
         ~required:[ "room_id"; "from_scene"; "to_scene" ]
         [
           ("room_id", string_schema);
           ("from_scene", string_schema);
           ("to_scene", string_schema);
           ("trigger", string_schema);
           ("narrative_hook", string_schema);
         ]);
    schema "trpg.quest.update"
      "Canonical alias of masc_trpg_quest_update."
      (object_schema
         ~required:[ "room_id"; "quest_id"; "title"; "status" ]
         [
           ("room_id", string_schema);
           ("quest_id", string_schema);
           ("title", string_schema);
           ("status", string_schema);
           ("objectives", array_of (object_schema [ ("desc", string_schema); ("done", bool_schema) ]));
         ]);
    schema "trpg.world.event"
      "Canonical alias of masc_trpg_world_event."
      (object_schema
         ~required:[ "room_id"; "event_type"; "description" ]
         [
           ("room_id", string_schema);
           ("event_type", string_schema);
           ("description", string_schema);
           ("affected_areas", array_of string_schema);
           ("severity", string_schema);
         ]);
    schema "client.session.open"
      "Open (or refresh) a client session for engine/viewer integration."
      (object_schema
         ~required:[ "session_id" ]
         [ ("session_id", string_schema); ("trace_id", string_schema) ]);
    schema "client.state.subscribe"
      "Subscribe client session to state/event topics (SSE primary, TRPG pull fallback)."
      (object_schema
         ~required:[ "session_id"; "topics" ]
         [ ("session_id", string_schema); ("topics", array_of string_schema) ]);
    schema "client.input.submit"
      "Submit human input into session queue (pending approval state)."
      (object_schema
         ~required:[ "session_id"; "input" ]
         [ ("session_id", string_schema); ("input", string_schema) ]);
    schema "client.input.approve"
      "Approve a queued human input."
      (object_schema
         ~required:[ "session_id"; "input_id" ]
         [ ("session_id", string_schema); ("input_id", string_schema) ]);
    schema "client.input.reject"
      "Reject a queued human input."
      (object_schema
         ~required:[ "session_id"; "input_id" ]
         [ ("session_id", string_schema); ("input_id", string_schema); ("reason", string_schema) ]);
    schema "client.snapshot.get"
      "Get a replay-friendly state snapshot for engine/viewer sync."
      (object_schema
         ~required:[ "session_id" ]
         [
           ("session_id", string_schema);
           ("room_id", string_schema);
           ("max_events", int_schema);
         ]);
  ]
