let public_event_types =
  [
    Trpg_engine_event.Turn_started;
    Trpg_engine_event.Phase_changed;
    Trpg_engine_event.Turn_action_resolved;
    Trpg_engine_event.Combat_attack;
    Trpg_engine_event.Combat_defense;
    Trpg_engine_event.Scene_transition;
    Trpg_engine_event.Quest_update;
    Trpg_engine_event.World_event;
    Trpg_engine_event.Session_outcome;
    Trpg_engine_event.Dice_rolled;
    Trpg_engine_event.Session_started;
    Trpg_engine_event.Party_selected;
    Trpg_engine_event.Actor_spawned;
    Trpg_engine_event.Actor_updated;
    Trpg_engine_event.Actor_deleted;
    Trpg_engine_event.Actor_claimed;
    Trpg_engine_event.Actor_released;
    Trpg_engine_event.Intervention_submitted;
    Trpg_engine_event.Intervention_applied;
  ]

let is_public_event (ev : Trpg_engine_event.t) =
  List.mem ev.event_type public_event_types

let is_sensitive_key (k : string) =
  let lower = String.lowercase_ascii k in
  String.starts_with ~prefix:"secret" lower
  || String.starts_with ~prefix:"private" lower
  || lower = "rationale"
  || lower = "risk_ack"

let rec redact_json (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
      fields
      |> List.filter (fun (k, _) -> not (is_sensitive_key k))
      |> List.map (fun (k, v) -> (k, redact_json v))
      |> fun xs -> `Assoc xs
  | `List xs -> `List (List.map redact_json xs)
  | x -> x

let redact_event (ev : Trpg_engine_event.t) : Trpg_engine_event.t =
  { ev with payload = redact_json ev.payload }

let rec take n xs =
  if n <= 0 then []
  else
    match xs with
    | [] -> []
    | x :: rest -> x :: take (n - 1) rest

let take_last n xs =
  xs |> List.rev |> take n |> List.rev

type agent_view = {
  self : Trpg_world_projection.agent_state;
  visible_agents : Trpg_world_projection.agent_state list;
  events_since : Trpg_engine_event.t list;
  round : int;
  phase : string;
  available_skills : string list;
}

let unknown_self name : Trpg_world_projection.agent_state =
  { name; status = `Unknown; last_action = None }

let filter ~agent_name ~after_seq ~event_limit ~available_skills
    (world : Trpg_world_projection.world_state) : agent_view =
  let self =
    world.agents
    |> List.find_opt
         (fun (a : Trpg_world_projection.agent_state) -> a.name = agent_name)
    |> Option.value ~default:(unknown_self agent_name)
  in
  let visible_agents =
    world.agents
    |> List.filter
         (fun (a : Trpg_world_projection.agent_state) -> a.name <> agent_name)
  in
  let events_since =
    world.recent_events
    |> List.filter (fun (ev : Trpg_engine_event.t) -> ev.seq > max 0 after_seq)
    |> List.filter is_public_event
    |> List.map redact_event
    |> take_last (max 1 event_limit)
  in
  {
    self;
    visible_agents;
    events_since;
    round = world.round;
    phase = world.phase;
    available_skills;
  }
