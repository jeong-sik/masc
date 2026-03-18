(** Tool_trpg — TRPG MCP dispatch entry point.

    Round execution (handle_round_run) is in Trpg_round_run_handler.
    Scene, quest, and world event handlers plus the dispatch table
    are defined here.

    Include chain: Trpg.Types -> Trpg.Action -> Trpg_round
    -> Trpg_handlers -> Trpg_round_run_handler -> Tool_trpg. *)

include Trpg_round_run_handler
open Yojson.Safe.Util

let schemas = Trpg_schema.schemas

let handle_scene_transition ctx args : result =
  let ( let* ) = Result.bind in
  let store = ctx.store in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* from_scene = get_required_string args "from_scene" in
    let* to_scene = get_required_string args "to_scene" in
    let* trigger = get_optional_string args "trigger" in
    let* narrative_hook = get_optional_string args "narrative_hook" in
    let payload =
      `Assoc
        [
          ("from_scene", `String from_scene);
          ("to_scene", `String to_scene);
          ( "trigger",
            match trigger with Some t -> `String t | None -> `Null );
          ( "narrative_hook",
            match narrative_hook with Some h -> `String h | None -> `Null );
        ]
    in
    let* event =
      append_event ~store ~room_id
        ~event_type:Trpg.Engine_event.Scene_transition ~payload ()
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("event", Trpg.Engine_event.to_yojson event);
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_quest_update ctx args : result =
  let ( let* ) = Result.bind in
  let store = ctx.store in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* quest_id = get_required_string args "quest_id" in
    let* title = get_required_string args "title" in
    let* status = get_required_string args "status" in
    let* () =
      match status with
      | "active" | "completed" | "failed" -> Ok ()
      | _ -> Error "status must be one of: active, completed, failed"
    in
    let objectives =
      match args |> member "objectives" with
      | `List xs -> `List xs
      | _ -> `List []
    in
    let payload =
      `Assoc
        [
          ("quest_id", `String quest_id);
          ("title", `String title);
          ("status", `String status);
          ("objectives", objectives);
        ]
    in
    let* event =
      append_event ~store ~room_id
        ~event_type:Trpg.Engine_event.Quest_update ~payload ()
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("event", Trpg.Engine_event.to_yojson event);
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_world_event ctx args : result =
  let ( let* ) = Result.bind in
  let store = ctx.store in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* evt_type = get_required_string args "event_type" in
    let* description = get_required_string args "description" in
    let* severity_opt = get_optional_string args "severity" in
    let severity = Option.value ~default:"minor" severity_opt in
    let* () =
      match severity with
      | "minor" | "major" | "catastrophic" -> Ok ()
      | _ -> Error "severity must be one of: minor, major, catastrophic"
    in
    let affected_areas =
      match args |> member "affected_areas" with
      | `List xs -> `List xs
      | _ -> `List []
    in
    let payload =
      `Assoc
        [
          ("event_type", `String evt_type);
          ("description", `String description);
          ("affected_areas", affected_areas);
          ("severity", `String severity);
        ]
    in
    let* event =
      append_event ~store ~room_id
        ~event_type:Trpg.Engine_event.World_event ~payload ()
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("event", Trpg.Engine_event.to_yojson event);
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_trpg_dice_roll" -> Some (handle_dice_roll ctx args)
  | "masc_trpg_turn_advance" -> Some (handle_turn_advance ctx args)
  | "masc_trpg_stream" -> Some (handle_stream ctx args)
  | "masc_trpg_preset_list" -> Some (handle_preset_list ctx args)
  | "masc_trpg_pool_generate" -> Some (handle_pool_generate ctx args)
  | "masc_trpg_party_select" -> Some (handle_party_select ctx args)
  | "masc_trpg_session_start" -> Some (handle_session_start ctx args)
  | "masc_trpg_actor_spawn" -> Some (handle_actor_spawn ctx args)
  | "masc_trpg_actor_update" -> Some (handle_actor_update ctx args)
  | "masc_trpg_actor_delete" -> Some (handle_actor_delete ctx args)
  | "masc_trpg_actor_match" -> Some (handle_actor_match ctx args)
  | "masc_trpg_actor_claim" -> Some (handle_actor_claim ctx args)
  | "masc_trpg_actor_release" -> Some (handle_actor_release ctx args)
  | "masc_trpg_join_eligibility" -> Some (handle_join_eligibility ctx args)
  | "masc_trpg_mid_join_request" -> Some (handle_mid_join_request ctx args)
  | "masc_trpg_intervention_submit" -> Some (handle_intervention_submit ctx args)
  | "masc_trpg_round_run" -> Some (handle_round_run ctx args)
  | "masc_trpg_scene_transition" -> Some (handle_scene_transition ctx args)
  | "masc_trpg_quest_update" -> Some (handle_quest_update ctx args)
  | "masc_trpg_world_event" -> Some (handle_world_event ctx args)
  | _ -> None
