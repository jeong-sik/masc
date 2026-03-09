(** TRPG World Slot Implementation

    World state management for TRPG engine. Tracks scenes, time,
    weather, locations, and world-level events.

    @since 2.68.0
*)

open Yojson.Safe.Util

(** {1 World State Types} *)

type weather_condition =
  | Clear
  | Cloudy
  | Rain
  | Storm
  | Snow
  | Fog

type time_of_day =
  | Dawn
  | Morning
  | Noon
  | Afternoon
  | Dusk
  | Evening
  | Night
  | Midnight

let string_of_weather = function
  | Clear -> "clear"
  | Cloudy -> "cloudy"
  | Rain -> "rain"
  | Storm -> "storm"
  | Snow -> "snow"
  | Fog -> "fog"

let weather_of_string = function
  | "clear" -> Ok Clear
  | "cloudy" -> Ok Cloudy
  | "rain" -> Ok Rain
  | "storm" -> Ok Storm
  | "snow" -> Ok Snow
  | "fog" -> Ok Fog
  | s -> Error (Printf.sprintf "unknown weather: %s" s)

let string_of_time_of_day = function
  | Dawn -> "dawn"
  | Morning -> "morning"
  | Noon -> "noon"
  | Afternoon -> "afternoon"
  | Dusk -> "dusk"
  | Evening -> "evening"
  | Night -> "night"
  | Midnight -> "midnight"

let time_of_day_of_hour hour =
  match hour mod 24 with
  | h when h >= 4 && h < 6 -> Dawn
  | h when h >= 6 && h < 12 -> Morning
  | h when h >= 12 && h < 14 -> Noon
  | h when h >= 14 && h < 17 -> Afternoon
  | h when h >= 17 && h < 19 -> Dusk
  | h when h >= 19 && h < 22 -> Evening
  | h when h >= 22 || h < 2 -> Night
  | _ -> Midnight

(** {1 Helper Functions} *)

let assoc_get key fields = List.assoc_opt key fields

let assoc_put key value fields =
  (key, value) :: List.remove_assoc key fields

let assoc_fields_or_empty = function
  | `Assoc fields -> fields
  | _ -> []

let get_string_opt = Safe_ops.json_string_opt
let get_int_opt = Safe_ops.json_int_opt

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

let update_scene_map scene_id f state =
  match state with
  | `Assoc fields ->
      let scenes_fields =
        match assoc_get "scenes" fields with
        | Some (`Assoc sf) -> sf
        | _ -> []
      in
      let scene_json =
        match List.assoc_opt scene_id scenes_fields with
        | Some s -> s
        | None -> `Assoc []
      in
      let next_scene = f scene_json in
      let next_scenes = `Assoc ((scene_id, next_scene) :: List.remove_assoc scene_id scenes_fields) in
      `Assoc (assoc_put "scenes" next_scenes fields)
  | _ -> state

(** {1 Event Handlers} *)

(* Apply world time update with delta or absolute time *)
let apply_world_time_update state ~payload =
  match state with
  | `Assoc fields ->
      let delta_minutes =
        match get_string_opt "time_delta" payload with
        | Some s ->
            (* Parse "1h 30m" format or just minutes *)
            let parts = String.split_on_char ' ' (String.lowercase_ascii s) in
            List.fold_left
              (fun acc part ->
                if String.ends_with ~suffix:"h" part then
                  try acc + (int_of_string (String.sub part 0 (String.length part - 1))) * 60
                  with _ -> acc
                else if String.ends_with ~suffix:"m" part then
                  try acc + (int_of_string (String.sub part 0 (String.length part - 1)))
                  with _ -> acc
                else acc)
              0 parts
        | None -> 0
      in
      let absolute_minutes =
        get_int_opt "world_time" payload |> Option.value ~default:0
      in
      let current_time =
        match assoc_get "world_time" fields with
        | Some (`Int t) -> t
        | _ -> 480  (* Default: 8:00 AM *)
      in
      let new_time =
        if absolute_minutes > 0 then absolute_minutes
        else current_time + delta_minutes
      in
      let normalized_time = new_time mod 1440 in  (* Wrap at 24 hours *)
      let new_day_count =
        if new_time >= current_time then
          match assoc_get "day_count" fields with
          | Some (`Int d) -> d
          | _ -> 1
        else
          (* Time wrapped past midnight *)
          match assoc_get "day_count" fields with
          | Some (`Int d) -> d + 1
          | _ -> 2
      in
      let hour = normalized_time / 60 in
      let time_of_day = string_of_time_of_day (time_of_day_of_hour hour) in
      `Assoc
        (fields
        |> assoc_put "world_time" (`Int normalized_time)
        |> assoc_put "time_of_day" (`String time_of_day)
        |> assoc_put "day_count" (`Int new_day_count))
  | _ -> state

(* Apply weather change *)
let apply_weather_change state ~payload =
  match state with
  | `Assoc fields ->
      let new_weather =
        match get_string_opt "weather" payload with
        | Some s ->
            (match weather_of_string s with
            | Ok w -> w
            | _ -> Clear)
        | None -> Clear
      in
      `Assoc (assoc_put "weather" (`String (string_of_weather new_weather)) fields)
  | _ -> state

(* Handle scene transition *)
let apply_scene_transition ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  let to_scene =
    get_string_opt "to_scene" payload
    |> Option.value ~default:""
  in
  let _from_scene =
    get_string_opt "from_scene" payload
  in
  if to_scene = "" then state
  else
    (* Update active_scene *)
    let state' =
      match state with
      | `Assoc fields -> `Assoc (assoc_put "active_scene" (`String to_scene) fields)
      | _ -> state
    in
    (* Update scene with entry timestamp *)
    update_scene_map to_scene (fun scene_json ->
        let scene_fields = assoc_fields_or_empty scene_json in
        let updated =
          scene_fields
          |> assoc_put "scene_id" (`String to_scene)
          |> assoc_put "last_visited" (`String event.Trpg_engine_event.ts)
          |> (fun fields ->
              match get_string_opt "scene_name" payload with
              | Some name -> assoc_put "name" (`String name) fields
              | None -> fields)
          |> (fun fields ->
              match get_string_opt "description" payload with
              | Some desc -> assoc_put "description" (`String desc) fields
              | None -> fields)
          |> (fun fields ->
              match get_string_opt "location" payload with
              | Some loc -> assoc_put "location" (`String loc) fields
              | None -> fields)
        in
        `Assoc updated
      ) state'

(* Track actor spawned in world *)
let apply_actor_spawned state ~payload =
  let actor_id =
    get_string_opt "actor_id" payload
    |> Option.value ~default:""
  in
  if actor_id = "" then state
  else
    match state with
    | `Assoc fields ->
        let actors =
          match assoc_get "actors" fields with
          | Some (`Assoc a) -> a
          | _ -> []
        in
        let actor_json =
          match payload |> member "actor" with
          | `Assoc _ as actor -> actor
          | _ -> `Assoc []
        in
        let updated_actors = (actor_id, actor_json) :: actors in
        `Assoc (assoc_put "actors" (`Assoc updated_actors) fields)
    | _ -> state

(* Track actor updated *)
let apply_actor_updated state ~payload =
  let actor_id =
    get_string_opt "actor_id" payload
    |> Option.value ~default:""
  in
  if actor_id = "" then state
  else
    match state with
    | `Assoc fields ->
        let actors =
          match assoc_get "actors" fields with
          | Some (`Assoc a) -> a
          | _ -> []
        in
        let existing =
          match List.assoc_opt actor_id actors with
          | Some json -> json
          | None -> `Assoc []
        in
        let patch =
          match payload |> member "actor_patch" with
          | `Assoc p -> p
          | _ -> []
        in
        let existing_fields = assoc_fields_or_empty existing in
        let merged_fields =
          List.fold_left
            (fun acc (k, v) -> assoc_put k v acc)
            existing_fields patch
        in
        let updated_actors = (actor_id, `Assoc merged_fields) :: List.remove_assoc actor_id actors in
        `Assoc (assoc_put "actors" (`Assoc updated_actors) fields)
    | _ -> state

(* Track actor deleted *)
let apply_actor_deleted state ~payload =
  let actor_id =
    get_string_opt "actor_id" payload
    |> Option.value ~default:""
  in
  if actor_id = "" then state
  else
    match state with
    | `Assoc fields ->
        let actors =
          match assoc_get "actors" fields with
          | Some (`Assoc a) -> a
          | _ -> []
        in
        let updated_actors = List.remove_assoc actor_id actors in
        `Assoc (assoc_put "actors" (`Assoc updated_actors) fields)
    | _ -> state

(* Record world event *)
let apply_world_event ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  let event_type =
    get_string_opt "event_type" payload
    |> Option.value ~default:""
  in
  let description =
    get_string_opt "description" payload
    |> Option.value ~default:""
  in
  if event_type = "" then state
  else
    let event_json = `Assoc [
      ("seq", `Int event.Trpg_engine_event.seq);
      ("event_type", `String event_type);
      ("description", `String description);
      ("timestamp", `String event.Trpg_engine_event.ts);
      ("payload", payload);
    ] in
    append_to_list "world_events" event_json state

(* Handle party selection - track which actors are active *)
let apply_party_selected state ~payload =
  let party_ids =
    match payload |> member "party" with
    | `List ids -> `List ids
    | _ -> `List []
  in
  match state with
  | `Assoc fields ->
      let updated = assoc_put "active_party" party_ids fields in
      `Assoc updated
  | _ -> state

(** {1 Slot Implementation} *)

module World_slot : Trpg_slot.TRPG_SLOT = struct
  let slot_info = {
    Trpg_slot.slot_id = "world";
    category = Trpg_slot.World;
    version = "1.0.0";
    description = "World state management: scenes, time, weather, locations, world events";
  }

  let init_state ~config =
    let world_time =
      match config |> member "world_time" with
      | `Int t -> t
      | _ -> 480  (* Default: 8:00 AM in minutes *)
    in
    let weather =
      match config |> member "weather" with
      | `String w ->
          (match weather_of_string w with
          | Ok w -> string_of_weather w
          | _ -> "clear")
      | _ -> "clear"
    in
    let current_scene =
      match config |> member "current_scene" with
      | `String s when String.trim s <> "" -> `String s
      | _ -> `Null
    in
    `Assoc
      [
        ("world_time", `Int world_time);
        ("weather", `String weather);
        ("time_of_day", `String (string_of_time_of_day (time_of_day_of_hour (world_time / 60))));
        ("day_count", `Int 1);
        ("scenes", `Assoc []);
        ("active_scene", current_scene);
        ("world_events", `List []);
        ("global_flags", `List []);
        ("actors", `Assoc []);
        ("active_party", `List []);
      ]

  let apply_event ~state ~event =
    match event.Trpg_engine_event.event_type with
    | Trpg_engine_event.World_event -> apply_world_event ~state ~event
    | Trpg_engine_event.Scene_transition -> apply_scene_transition ~state ~event
    | Trpg_engine_event.Actor_spawned -> apply_actor_spawned state ~payload:event.Trpg_engine_event.payload
    | Trpg_engine_event.Actor_updated -> apply_actor_updated state ~payload:event.Trpg_engine_event.payload
    | Trpg_engine_event.Actor_deleted -> apply_actor_deleted state ~payload:event.Trpg_engine_event.payload
    | Trpg_engine_event.Party_selected -> apply_party_selected state ~payload:event.Trpg_engine_event.payload
    (* Time/weather changes from Phase_changed or Turn_started *)
    | Trpg_engine_event.Turn_started ->
        (* Advance time by 15 minutes per turn *)
        apply_world_time_update state ~payload:(`Assoc ["time_delta", `String "15m"])
    | Trpg_engine_event.Phase_changed ->
        (match event.Trpg_engine_event.payload |> member "time_delta" with
        | `String _ | `Int _ -> apply_world_time_update state ~payload:event.Trpg_engine_event.payload
        | _ -> state)
    | _ -> state

  let derive_state ~state =
    (* Compute derived state for client consumption *)
    match state with
    | `Assoc fields ->
        (* Remove internal fields, keep public-facing ones *)
        let public_fields = List.filter (fun (k, _) ->
          not (List.mem k ["actors"; "global_flags"])
        ) fields in

        (* Add computed summary *)
        let time_of_day =
          match assoc_get "time_of_day" fields with
          | Some (`String s) -> s
          | _ -> "morning"
        in

        let weather =
          match assoc_get "weather" fields with
          | Some (`String s) -> s
          | _ -> "clear"
        in

        let active_scene =
          match assoc_get "active_scene" fields with
          | Some (`String s) when String.trim s <> "" -> `String s
          | _ -> `Null
        in

        let day_count =
          match assoc_get "day_count" fields with
          | Some (`Int d) -> d
          | _ -> 1
        in

        let world_time =
          match assoc_get "world_time" fields with
          | Some (`Int t) -> t
          | _ -> 480
        in

        let hour = world_time / 60 in
        let minute = world_time mod 60 in
        let time_string = Printf.sprintf "%02d:%02d" hour minute in

        let summary = `Assoc [
          ("time_of_day", `String time_of_day);
          ("time_string", `String time_string);
          ("weather", `String weather);
          ("active_scene", active_scene);
          ("day_count", `Int day_count);
        ] in

        (* Recent world events only *)
        let world_events =
          match assoc_get "world_events" fields with
          | Some (`List xs) ->
              let len = List.length xs in
              if len > 20 then `List (List.take 20 xs)
              else `List xs
          | _ -> `List []
        in

        `Assoc
          (assoc_put "world_events" world_events
             (assoc_put "summary" summary public_fields))
    | _ -> state
end

(** {1 Self-registration} *)

let () =
  Trpg_slot.Registry.register (module World_slot : Trpg_slot.TRPG_SLOT)
