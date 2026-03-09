(** TRPG Narrative Slot Implementation

    Narrative flow management for TRPG engine. Tracks story progression,
    quest states, and intervention history.

    @since 2.68.0
*)

open Yojson.Safe.Util

(** {1 Narrative State Types} *)

type quest_status =
  | Not_started
  | In_progress
  | Completed
  | Failed
  | Abandoned

let string_of_quest_status = function
  | Not_started -> "not_started"
  | In_progress -> "in_progress"
  | Completed -> "completed"
  | Failed -> "failed"
  | Abandoned -> "abandoned"

let quest_status_of_string = function
  | "not_started" -> Ok Not_started
  | "in_progress" -> Ok In_progress
  | "completed" -> Ok Completed
  | "failed" -> Ok Failed
  | "abandoned" -> Ok Abandoned
  | s -> Error ("Unknown quest_status: " ^ s)

type intervention_status =
  | Pending
  | Approved
  | Rejected
  | Applied

let string_of_intervention_status = function
  | Pending -> "pending"
  | Approved -> "approved"
  | Rejected -> "rejected"
  | Applied -> "applied"

let intervention_status_of_string = function
  | "pending" -> Ok Pending
  | "approved" -> Ok Approved
  | "rejected" -> Ok Rejected
  | "applied" -> Ok Applied
  | s -> Error ("Unknown intervention_status: " ^ s)

(** {1 Helper Functions} *)

let assoc_get key fields = List.assoc_opt key fields

let assoc_put key value fields =
  (key, value) :: List.remove_assoc key fields

let assoc_fields_or_empty = function
  | `Assoc fields -> fields
  | _ -> []

let get_string_opt = Safe_ops.json_string_opt
let get_int_opt = Safe_ops.json_int_opt
let get_bool_opt = Safe_ops.json_bool_opt

let append_to_list key value state =
  match state with
  | `Assoc fields ->
      let prev =
        match assoc_get key fields with
        | Some (`List xs) -> xs
        | _ -> []
      in
      `Assoc (assoc_put key (`List (prev @ [ value ])) fields)
  | _ -> state

let update_quest_map quest_id f state =
  match state with
  | `Assoc fields ->
      let quests_fields =
        match assoc_get "quests" fields with
        | Some (`Assoc qf) -> qf
        | _ -> []
      in
      let quest_json =
        match List.assoc_opt quest_id quests_fields with
        | Some q -> q
        | None -> `Assoc [ ("status", `String (string_of_quest_status Not_started)) ]
      in
      let next_quest = f quest_json in
      let next_quests = `Assoc ((quest_id, next_quest) :: List.remove_assoc quest_id quests_fields) in
      `Assoc (assoc_put "quests" next_quests fields)
  | _ -> state

(** {1 Event Handlers} *)

let apply_narration_posted ~state ~event =
  append_to_list "narrative_log" event.Trpg_engine_event.payload state

let apply_node_advanced ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  match state with
  | `Assoc fields ->
      let to_node = get_string_opt "to_node" payload |> Option.value ~default:"" in
      let from_node = get_string_opt "from_node" payload in
      let updated_fields =
        if to_node = "" then fields
        else assoc_put "current_node" (`String to_node) fields
      in
      let updated_fields =
        match from_node with
        | Some node -> assoc_put "previous_node" (`String node) updated_fields
        | None -> updated_fields
      in
      `Assoc updated_fields
  | _ -> state

let apply_quest_update ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  let quest_id = get_string_opt "quest_id" payload |> Option.value ~default:"" in
  if quest_id = "" then state
  else
    let status_str = get_string_opt "status" payload |> Option.value ~default:"not_started" in
    let status = quest_status_of_string status_str in
    match status with
    | Error _ -> state
    | Ok quest_status ->
        update_quest_map quest_id (fun quest_json ->
            let quest_fields = assoc_fields_or_empty quest_json in
            let updated = assoc_put "status" (`String (string_of_quest_status quest_status)) quest_fields in
            let updated =
              match get_string_opt "title" payload with
              | Some title -> assoc_put "title" (`String title) updated
              | None -> updated
            in
            let updated =
              match get_string_opt "description" payload with
              | Some desc -> assoc_put "description" (`String desc) updated
              | None -> updated
            in
            let updated =
              match get_int_opt "progress" payload with
              | Some progress -> assoc_put "progress" (`Int progress) updated
              | None -> updated
            in
            `Assoc updated
          ) state

let apply_intervention_submitted ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  let intervention_id =
    match payload |> member "intervention_id" with
    | `String id -> id
    | _ ->
        (* Generate simple ID from timestamp *)
        Printf.sprintf "intv-%s-%d"
          event.Trpg_engine_event.ts
          event.Trpg_engine_event.seq
  in
  let intervention_json =
    `Assoc
      ([
        ("id", `String intervention_id);
        ("status", `String (string_of_intervention_status Pending));
        ("submitted_at", `String event.Trpg_engine_event.ts);
        ("seq", `Int event.Trpg_engine_event.seq);
      ]
      |> (fun fields ->
          match get_string_opt "proposer" payload with
          | Some proposer -> ("proposer", `String proposer) :: fields
          | None -> fields
        )
      |> (fun fields ->
          match get_string_opt "type" payload with
          | Some type_ -> ("type", `String type_) :: fields
          | None -> fields
        )
      |> (fun fields ->
          match get_string_opt "description" payload with
          | Some desc -> ("description", `String desc) :: fields
          | None -> fields
        )
      |> (fun fields ->
          match payload |> member "changes" with
          | `Assoc _ as changes -> ("changes", changes) :: fields
          | _ -> fields
        ))
  in
  append_to_list "interventions" intervention_json state

let apply_intervention_applied ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  let intervention_id = get_string_opt "intervention_id" payload in
  match intervention_id with
  | None -> state
  | Some id ->
      match state with
      | `Assoc fields ->
          let interventions =
            match assoc_get "interventions" fields with
            | Some (`List xs) -> xs
            | _ -> []
          in
          let updated_interventions =
            interventions
            |> List.map (fun iv_json ->
                match iv_json with
                | `Assoc iv_fields ->
                    (match List.assoc_opt "id" iv_fields with
                     | Some (`String existing_id) when String.equal existing_id id ->
                         let updated =
                           assoc_put "status" (`String (string_of_intervention_status Applied)) iv_fields in
                         let updated =
                           assoc_put "applied_at" (`String event.Trpg_engine_event.ts) updated
                         in
                         `Assoc updated
                     | _ -> iv_json)
                | _ -> iv_json
              )
          in
          `Assoc (assoc_put "interventions" (`List updated_interventions) fields)
      | _ -> state

(** {1 Slot Implementation} *)

module Narrative_slot : Trpg_slot.TRPG_SLOT = struct
  let slot_info = {
    Trpg_slot.slot_id = "narrative";
    category = Trpg_slot.Narrative;
    version = "1.0.0";
    description = "Narrative flow management: scenes, quests, story state";
  }

  let init_state ~config:_ =
    `Assoc
      [
        ("current_node", `Null);
        ("previous_node", `Null);
        ("narrative_log", `List []);
        ("quests", `Assoc []);
        ("interventions", `List []);
        ("scene_history", `List []);
      ]

  let apply_event ~state ~event =
    match event.Trpg_engine_event.event_type with
    | Trpg_engine_event.Narration_posted -> apply_narration_posted ~state ~event
    | Trpg_engine_event.Node_advanced -> apply_node_advanced ~state ~event
    | Trpg_engine_event.Quest_update -> apply_quest_update ~state ~event
    | Trpg_engine_event.Intervention_submitted -> apply_intervention_submitted ~state ~event
    | Trpg_engine_event.Intervention_applied -> apply_intervention_applied ~state ~event
    | Trpg_engine_event.Scene_transition ->
        (* Track scene transitions in history *)
        let scene_entry =
          `Assoc
            [
              ("from_scene", event.Trpg_engine_event.payload |> member "from_scene");
              ("to_scene", event.Trpg_engine_event.payload |> member "to_scene");
              ("ts", `String event.Trpg_engine_event.ts);
            ]
        in
        append_to_list "scene_history" scene_entry state
    | _ -> state

  let derive_state ~state =
    (* Derived state includes only active quests and recent narrative *)
    match state with
    | `Assoc fields ->
        let quests =
          match assoc_get "quests" fields with
          | Some (`Assoc quest_map) ->
              let active_quests =
                quest_map
                |> List.filter (fun (_id, quest_json) ->
                    match quest_json with
                    | `Assoc qf ->
                        (match List.assoc_opt "status" qf with
                         | Some (`String status) ->
                             not (String.equal status "completed" || String.equal status "abandoned")
                         | _ -> false)
                    | _ -> false
                  )
              in
              `Assoc active_quests
          | _ -> `Assoc []
        in
        let narrative_log =
          match assoc_get "narrative_log" fields with
          | Some (`List xs) ->
              (* Return last 50 entries *)
              let len = List.length xs in
              if len > 50 then
                `List (List.drop (len - 50) xs)
              else `List xs
          | _ -> `List []
        in
        `Assoc
          ([
            ("current_node", match assoc_get "current_node" fields with Some x -> x | None -> `Null);
            ("quests", quests);
            ("narrative_log", narrative_log);
            ("scene_count",
              `Int
                (match assoc_get "scene_history" fields with
                | Some (`List scenes) -> List.length scenes
                | _ -> 0));
          ])
    | _ -> state
end

(** {1 Self-registration} *)

let () =
  Trpg_slot.Registry.register (module Narrative_slot : Trpg_slot.TRPG_SLOT)
