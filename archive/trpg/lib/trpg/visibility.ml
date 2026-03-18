let public_event_types =
  [
    Engine_event.Turn_started;
    Engine_event.Phase_changed;
    Engine_event.Turn_action_resolved;
    Engine_event.Combat_attack;
    Engine_event.Combat_defense;
    Engine_event.Scene_transition;
    Engine_event.Quest_update;
    Engine_event.World_event;
    Engine_event.Session_outcome;
    Engine_event.Dice_rolled;
    Engine_event.Session_started;
    Engine_event.Party_selected;
    Engine_event.Actor_spawned;
    Engine_event.Actor_updated;
    Engine_event.Actor_deleted;
    Engine_event.Actor_claimed;
    Engine_event.Actor_released;
    Engine_event.Intervention_submitted;
    Engine_event.Intervention_applied;
  ]

let is_public_event (ev : Engine_event.t) =
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

let redact_event (ev : Engine_event.t) : Engine_event.t =
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
  self : World_projection.agent_state;
  visible_agents : World_projection.agent_state list;
  events_since : Engine_event.t list;
  round : int;
  phase : string;
  available_skills : string list;
}

let unknown_self name : World_projection.agent_state =
  { name; status = `Unknown; last_action = None }

let filter ~agent_name ~after_seq ~event_limit ~available_skills
    (world : World_projection.world_state) : agent_view =
  let self =
    world.agents
    |> List.find_opt
         (fun (a : World_projection.agent_state) -> a.name = agent_name)
    |> Option.value ~default:(unknown_self agent_name)
  in
  let visible_agents =
    world.agents
    |> List.filter
         (fun (a : World_projection.agent_state) -> a.name <> agent_name)
  in
  let events_since =
    world.recent_events
    |> List.filter (fun (ev : Engine_event.t) -> ev.seq > max 0 after_seq)
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
