(** MASC Swarm - Level 4 Emergent Collective Intelligence (Eio Native) *)


(** {1 Types} *)

type swarm_behavior =
  | Flocking
  | Foraging
  | Stigmergy
  | Quorum_sensing

type swarm_agent = {
  id: string;
  name: string;
  fitness: Level4_config.Fitness.t;
  generation: int;
  mutations: string list;
  joined_at: float;
  last_active: float;
}

type pheromone = {
  path_id: string;
  strength: Level4_config.Strength.t;
  deposited_by: string;
  deposited_at: float;
  evaporation_rate: Level4_config.Normalized.t;
}

type quorum_proposal = {
  proposal_id: string;
  description: string;
  proposed_by: string;
  proposed_at: float;
  votes_for: string list;
  votes_against: string list;
  threshold: Level4_config.Threshold.t;
  deadline: float option;
  status: [`Pending | `Passed | `Rejected | `Expired];
}

type swarm_config = {
  id: string;
  name: string;
  selection_pressure: Level4_config.Normalized.t;
  mutation_rate: Level4_config.Normalized.t;
  evaporation_rate: Level4_config.Normalized.t;
  quorum_threshold: Level4_config.Normalized.t;
  max_agents: int;
  behavior: swarm_behavior;
}

type swarm = {
  swarm_cfg: swarm_config;
  agents: swarm_agent list;
  pheromones: pheromone list;
  proposals: quorum_proposal list;
  generation: int;
  created_at: float;
  last_evolution: float;
}

type config = Room_utils.config

(** {1 Default Configuration} *)

let default_config ?(id = "") ?(name = "default-swarm") ?(rng = Level4_config.make_rng ()) () = {
  id = if id = "" then Printf.sprintf "swarm-%d" (Random.State.int rng 100000) else id;
  name;
  selection_pressure = Level4_config.Normalized.of_float_clamped 0.3;
  mutation_rate = Level4_config.Normalized.of_float_clamped 0.1;
  evaporation_rate = Level4_config.Normalized.of_float_clamped 0.1;
  quorum_threshold = Level4_config.Normalized.of_float_clamped 0.6;
  max_agents = 50;
  behavior = Flocking;
}

(** {1 Serialization} *)

let behavior_to_string = function
  | Flocking -> "flocking"
  | Foraging -> "foraging"
  | Stigmergy -> "stigmergy"
  | Quorum_sensing -> "quorum_sensing"

let behavior_of_string = function
  | "flocking" -> Flocking
  | "foraging" -> Foraging
  | "stigmergy" -> Stigmergy
  | "quorum_sensing" -> Quorum_sensing
  | _ -> Flocking

let status_to_string = function
  | `Pending -> "pending"
  | `Passed -> "passed"
  | `Rejected -> "rejected"
  | `Expired -> "expired"

let status_of_string = function
  | "pending" -> `Pending
  | "passed" -> `Passed
  | "rejected" -> `Rejected
  | "expired" -> `Expired
  | _ -> `Pending

let agent_to_json (a : swarm_agent) : Yojson.Safe.t =
  `Assoc [
    ("id", `String a.id);
    ("name", `String a.name);
    ("fitness", Level4_config.Fitness.to_json a.fitness);
    ("generation", `Int a.generation);
    ("mutations", `List (List.map (fun m -> `String m) a.mutations));
    ("joined_at", `Float a.joined_at);
    ("last_active", `Float a.last_active);
  ]

let agent_of_json json : (swarm_agent, string) result =
  try
    let open Yojson.Safe.Util in
    Ok {
      id = json |> member "id" |> to_string;
      name = json |> member "name" |> to_string;
      fitness = json |> member "fitness" |> to_float |> Level4_config.Fitness.of_float_clamped;
      generation = json |> member "generation" |> to_int;
      mutations = json |> member "mutations" |> to_list |> List.map to_string;
      joined_at = json |> member "joined_at" |> to_float;
      last_active = json |> member "last_active" |> to_float;
    }
  with
  | Yojson.Safe.Util.Type_error (msg, _) -> Error ("agent_of_json: " ^ msg)
  | Yojson.Json_error msg -> Error ("agent_of_json: " ^ msg)

let pheromone_to_json (p : pheromone) : Yojson.Safe.t =
  `Assoc [
    ("path_id", `String p.path_id);
    ("strength", Level4_config.Strength.to_json p.strength);
    ("deposited_by", `String p.deposited_by);
    ("deposited_at", `Float p.deposited_at);
    ("evaporation_rate", Level4_config.Normalized.to_json p.evaporation_rate);
  ]

let pheromone_of_json json : (pheromone, string) result =
  try
    let open Yojson.Safe.Util in
    let nc = Level4_config.Normalized.of_float_clamped in
    Ok {
      path_id = json |> member "path_id" |> to_string;
      strength = json |> member "strength" |> to_float |> nc;
      deposited_by = json |> member "deposited_by" |> to_string;
      deposited_at = json |> member "deposited_at" |> to_float;
      evaporation_rate = json |> member "evaporation_rate" |> to_float |> nc;
    }
  with
  | Yojson.Safe.Util.Type_error (msg, _) -> Error ("pheromone_of_json: " ^ msg)
  | Yojson.Json_error msg -> Error ("pheromone_of_json: " ^ msg)

let proposal_to_json (p : quorum_proposal) : Yojson.Safe.t =
  `Assoc [
    ("proposal_id", `String p.proposal_id);
    ("description", `String p.description);
    ("proposed_by", `String p.proposed_by);
    ("proposed_at", `Float p.proposed_at);
    ("votes_for", `List (List.map (fun v -> `String v) p.votes_for));
    ("votes_against", `List (List.map (fun v -> `String v) p.votes_against));
    ("threshold", Level4_config.Threshold.to_json p.threshold);
    ("deadline", match p.deadline with Some d -> `Float d | None -> `Null);
    ("status", `String (status_to_string p.status));
  ]

let proposal_of_json json : (quorum_proposal, string) result =
  try
    let open Yojson.Safe.Util in
    Ok {
      proposal_id = json |> member "proposal_id" |> to_string;
      description = json |> member "description" |> to_string;
      proposed_by = json |> member "proposed_by" |> to_string;
      proposed_at = json |> member "proposed_at" |> to_float;
      votes_for = json |> member "votes_for" |> to_list |> List.map to_string;
      votes_against = json |> member "votes_against" |> to_list |> List.map to_string;
      threshold = json |> member "threshold" |> to_float |> Level4_config.Threshold.of_float_clamped;
      deadline = json |> member "deadline" |> to_float_option;
      status = json |> member "status" |> to_string |> status_of_string;
    }
  with
  | Yojson.Safe.Util.Type_error (msg, _) -> Error ("proposal_of_json: " ^ msg)
  | Yojson.Json_error msg -> Error ("proposal_of_json: " ^ msg)

let config_to_json (c : swarm_config) : Yojson.Safe.t =
  `Assoc [
    ("id", `String c.id);
    ("name", `String c.name);
    ("selection_pressure", Level4_config.Normalized.to_json c.selection_pressure);
    ("mutation_rate", Level4_config.Normalized.to_json c.mutation_rate);
    ("evaporation_rate", Level4_config.Normalized.to_json c.evaporation_rate);
    ("quorum_threshold", Level4_config.Normalized.to_json c.quorum_threshold);
    ("max_agents", `Int c.max_agents);
    ("behavior", `String (behavior_to_string c.behavior));
  ]

let config_of_json json : (swarm_config, string) result =
  try
    let open Yojson.Safe.Util in
    let n f = Level4_config.Normalized.of_float_clamped f in
    Ok {
      id = json |> member "id" |> to_string;
      name = json |> member "name" |> to_string;
      selection_pressure = json |> member "selection_pressure" |> to_float |> n;
      mutation_rate = json |> member "mutation_rate" |> to_float |> n;
      evaporation_rate = json |> member "evaporation_rate" |> to_float |> n;
      quorum_threshold = json |> member "quorum_threshold" |> to_float |> n;
      max_agents = json |> member "max_agents" |> to_int;
      behavior = json |> member "behavior" |> to_string |> behavior_of_string;
    }
  with
  | Yojson.Safe.Util.Type_error (msg, _) -> Error ("config_of_json: " ^ msg)
  | Yojson.Json_error msg -> Error ("config_of_json: " ^ msg)

let swarm_to_json (s : swarm) : Yojson.Safe.t =
  `Assoc [
    ("config", config_to_json s.swarm_cfg);
    ("agents", `List (List.map agent_to_json s.agents));
    ("pheromones", `List (List.map pheromone_to_json s.pheromones));
    ("proposals", `List (List.map proposal_to_json s.proposals));
    ("generation", `Int s.generation);
    ("created_at", `Float s.created_at);
    ("last_evolution", `Float s.last_evolution);
  ]

let result_map_list f xs =
  List.fold_left (fun acc x ->
    match acc with
    | Error _ as e -> e
    | Ok lst ->
      match f x with
      | Ok v -> Ok (v :: lst)
      | Error _ as e -> e
  ) (Ok []) xs
  |> Result.map List.rev

let swarm_of_json json : (swarm, string) result =
  try
    let open Yojson.Safe.Util in
    Result.bind (json |> member "config" |> config_of_json) (fun swarm_cfg ->
    Result.bind (json |> member "agents" |> to_list |> result_map_list agent_of_json) (fun agents ->
    Result.bind (json |> member "pheromones" |> to_list |> result_map_list pheromone_of_json) (fun pheromones ->
    Result.bind (json |> member "proposals" |> to_list |> result_map_list proposal_of_json) (fun proposals ->
    Ok {
      swarm_cfg;
      agents;
      pheromones;
      proposals;
      generation = json |> member "generation" |> to_int;
      created_at = json |> member "created_at" |> to_float;
      last_evolution = json |> member "last_evolution" |> to_float;
    }))))
  with
  | Yojson.Safe.Util.Type_error (msg, _) -> Error ("swarm_of_json: " ^ msg)
  | Yojson.Json_error msg -> Error ("swarm_of_json: " ^ msg)

(** {1 Persistence (Eio Native)} *)

let swarm_file (config : config) =
  Filename.concat config.base_path ".masc/swarm.json"

let load_swarm ~fs (config : config) : (swarm, string) result =
  let file = swarm_file config in
  let path = Eio.Path.(fs / file) in
  try
    let content = Eio.Path.load path in
    let json = Yojson.Safe.from_string content in
    swarm_of_json json
  with
  | Eio.Io _ as exn -> Error ("load_swarm IO: " ^ Printexc.to_string exn)
  | Yojson.Json_error msg -> Error ("load_swarm JSON: " ^ msg)
  | Yojson.Safe.Util.Type_error (msg, _) -> Error ("load_swarm: " ^ msg)

let save_swarm ~fs (config : config) (swarm : swarm) : unit =
  let file = swarm_file config in
  let dir = Filename.dirname file in
  let dir_path = Eio.Path.(fs / dir) in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 dir_path;
  let json = swarm_to_json swarm in
  let path = Eio.Path.(fs / file) in
  Eio.Path.save ~create:(`Or_truncate 0o600) path (Yojson.Safe.pretty_to_string json)

(** {1 Pure Transformations} *)

module Pure = struct
  (** Shorthand for unwrapping Normalized to float for arithmetic *)
  let nf = Level4_config.Normalized.to_float
  let nc = Level4_config.Normalized.of_float_clamped

  type join_result =
    | Joined of swarm
    | Already_member of swarm
    | Swarm_full

  let join_agent swarm ~agent_id ~agent_name ~now =
    if List.length swarm.agents >= swarm.swarm_cfg.max_agents then
      Swarm_full
    else if List.exists (fun (a : swarm_agent) -> a.id = agent_id) swarm.agents then
      Already_member swarm
    else
      let agent = {
        id = agent_id;
        name = agent_name;
        fitness = Level4_config.Fitness.initial ();
        generation = swarm.generation;
        mutations = [];
        joined_at = now;
        last_active = now;
      } in
      Joined { swarm with agents = agent :: swarm.agents }

  let leave_agent swarm ~agent_id =
    let agents = List.filter (fun (a : swarm_agent) -> a.id <> agent_id) swarm.agents in
    { swarm with agents }

  let update_agent_fitness swarm ~agent_id ~fitness ~now =
    if not (List.exists (fun (a : swarm_agent) -> a.id = agent_id) swarm.agents) then
      None
    else
      match Level4_config.Fitness.of_float fitness with
      | None -> None
      | Some validated_fitness ->
        let agents = List.map (fun (a : swarm_agent) ->
          if a.id = agent_id then
            { a with fitness = validated_fitness; last_active = now }
          else a
        ) swarm.agents in
        Some { swarm with agents }

  let fitness_rankings swarm =
    let rankings = List.map (fun (a : swarm_agent) -> (a.id, nf a.fitness)) swarm.agents in
    List.sort (fun (_, f1) (_, f2) -> compare f2 f1) rankings

  let select_elite_agents swarm =
    let sorted = List.sort (fun a b -> compare (nf b.fitness) (nf a.fitness)) swarm.agents in
    let elite_count = max 1 (int_of_float (
      float_of_int (List.length sorted) *. nf swarm.swarm_cfg.selection_pressure
    )) in
    List.filteri (fun i _ -> i < elite_count) sorted

  let evolve_agents swarm ~rng ~now =
    let agents = List.map (fun (a : swarm_agent) ->
      if Random.State.float rng 1.0 < nf swarm.swarm_cfg.mutation_rate then
        let mutation = Printf.sprintf "gen%d-mut%d" (swarm.generation + 1) (Random.State.int rng 1000) in
        { a with
          mutations = mutation :: a.mutations;
          generation = swarm.generation + 1;
        }
      else
        { a with generation = swarm.generation + 1 }
    ) swarm.agents in
    { swarm with
      agents;
      generation = swarm.generation + 1;
      last_evolution = now;
    }

  let deposit_pheromone swarm ~path_id ~agent_id ~(strength : Level4_config.Strength.t) ~now =
    let evap_rate = swarm.swarm_cfg.evaporation_rate in
    let existing = List.find_opt (fun p -> p.path_id = path_id) swarm.pheromones in
    let pheromones = match existing with
      | Some p ->
        let updated = { p with
          strength = nc (nf p.strength +. nf strength);
          deposited_by = agent_id;
          deposited_at = now;
        } in
        updated :: List.filter (fun x -> x.path_id <> path_id) swarm.pheromones
      | None ->
        let new_pheromone = {
          path_id;
          strength;
          deposited_by = agent_id;
          deposited_at = now;
          evaporation_rate = evap_rate;
        } in
        new_pheromone :: swarm.pheromones
    in
    { swarm with pheromones }

  let evaporate_pheromones swarm ~now =
    let pheromones = List.filter_map (fun p ->
      let elapsed_hours = (now -. p.deposited_at) /. 3600.0 in
      let decay = nf p.evaporation_rate *. elapsed_hours in
      let new_strength = nf p.strength -. decay in
      if new_strength <= 0.0 then None
      else Some { p with strength = nc new_strength }
    ) swarm.pheromones in
    { swarm with pheromones }

  let strongest_trails swarm ~limit =
    let sorted = List.sort (fun a b ->
      compare (nf b.strength) (nf a.strength)
    ) swarm.pheromones in
    List.filteri (fun i _ -> i < limit) sorted

  let add_proposal swarm ~proposal =
    { swarm with proposals = proposal :: swarm.proposals }

  let record_vote swarm ~proposal_id ~agent_id ~vote_for =
    let proposals = List.map (fun p ->
      if p.proposal_id = proposal_id then
        let votes_for = List.filter ((<>) agent_id) p.votes_for in
        let votes_against = List.filter ((<>) agent_id) p.votes_against in
        if vote_for then
          { p with votes_for = agent_id :: votes_for; votes_against }
        else
          { p with votes_for; votes_against = agent_id :: votes_against }
      else p
    ) swarm.proposals in
    { swarm with proposals }

  let update_proposal_status swarm ~proposal_id ~now =
    let total_agents = List.length swarm.agents in
    if total_agents = 0 then swarm
    else
      let proposals = List.map (fun p ->
        if p.proposal_id = proposal_id && p.status = `Pending then
          let for_ratio = float_of_int (List.length p.votes_for) /. float_of_int total_agents in
          let against_ratio = float_of_int (List.length p.votes_against) /. float_of_int total_agents in
          let threshold_f = nf p.threshold in
          let expired = match p.deadline with
            | Some d -> now > d
            | None -> false
          in
          let status =
            if for_ratio >= threshold_f then `Passed
            else if against_ratio > (1.0 -. threshold_f) then `Rejected
            else if expired then `Expired
            else `Pending
          in
          { p with status }
        else p
      ) swarm.proposals in
      { swarm with proposals }
end

(** {1 Lifecycle (Eio)} *)

let create ~fs (config : config) ?(swarm_config = default_config ()) () : swarm =
  let now = Time_compat.now () in
  let swarm = {
    swarm_cfg = swarm_config;
    agents = [];
    pheromones = [];
    proposals = [];
    generation = 0;
    created_at = now;
    last_evolution = now;
  } in
  save_swarm ~fs config swarm;
  swarm

let join ~fs (config : config) ~agent_id ~agent_name : (swarm, string) result =
  match load_swarm ~fs config with
  | Error e -> Error ("join: " ^ e)
  | Ok swarm ->
    let now = Time_compat.now () in
    match Pure.join_agent swarm ~agent_id ~agent_name ~now with
    | Pure.Joined updated ->
      save_swarm ~fs config updated;
      Ok updated
    | Pure.Already_member s -> Ok s
    | Pure.Swarm_full -> Error "join: swarm is full"

let leave ~fs (config : config) ~agent_id : (swarm, string) result =
  match load_swarm ~fs config with
  | Error e -> Error ("leave: " ^ e)
  | Ok swarm ->
    let updated = Pure.leave_agent swarm ~agent_id in
    save_swarm ~fs config updated;
    Ok updated

let dissolve ~fs (config : config) : unit =
  let file = swarm_file config in
  let path = Eio.Path.(fs / file) in
  try Eio.Path.unlink path with Eio.Io _ -> ()

let update_fitness ~fs (config : config) ~agent_id ~fitness : (swarm, string) result =
  match load_swarm ~fs config with
  | Error e -> Error ("update_fitness: " ^ e)
  | Ok swarm ->
    let now = Time_compat.now () in
    match Pure.update_agent_fitness swarm ~agent_id ~fitness ~now with
    | None -> Error (Printf.sprintf "update_fitness: agent %s not found" agent_id)
    | Some updated ->
      save_swarm ~fs config updated;
      Ok updated

let get_fitness_rankings ~fs (config : config) : (string * float) list =
  match load_swarm ~fs config with
  | Error _ -> []
  | Ok swarm -> Pure.fitness_rankings swarm

let select_elite ~fs (config : config) : swarm_agent list =
  match load_swarm ~fs config with
  | Error _ -> []
  | Ok swarm -> Pure.select_elite_agents swarm

let evolve ~fs (config : config) ?(rng = Level4_config.make_rng ()) () : (swarm, string) result =
  match load_swarm ~fs config with
  | Error e -> Error ("evolve: " ^ e)
  | Ok swarm ->
    let now = Time_compat.now () in
    let updated = Pure.evolve_agents swarm ~rng ~now in
    save_swarm ~fs config updated;
    Ok updated

let deposit_pheromone ~fs (config : config) ~path_id ~agent_id ~(strength : Level4_config.Strength.t) : (swarm, string) result =
  match load_swarm ~fs config with
  | Error e -> Error ("deposit_pheromone: " ^ e)
  | Ok swarm ->
    let now = Time_compat.now () in
    let updated = Pure.deposit_pheromone swarm ~path_id ~agent_id ~strength ~now in
    save_swarm ~fs config updated;
    Ok updated

let read_pheromone ~fs (config : config) ~path_id : float =
  match load_swarm ~fs config with
  | Error _ -> 0.0
  | Ok swarm ->
    let now = Time_compat.now () in
    match List.find_opt (fun p -> p.path_id = path_id) swarm.pheromones with
    | None -> 0.0
    | Some p ->
      let nf = Level4_config.Normalized.to_float in
      let hours_elapsed = (now -. p.deposited_at) /. 3600.0 in
      let decayed = nf p.strength *. exp (-. nf p.evaporation_rate *. hours_elapsed) in
      max 0.0 decayed

let evaporate_pheromones ~fs (config : config) : (swarm, string) result =
  match load_swarm ~fs config with
  | Error e -> Error ("evaporate_pheromones: " ^ e)
  | Ok swarm ->
    let now = Time_compat.now () in
    let updated = Pure.evaporate_pheromones swarm ~now in
    save_swarm ~fs config updated;
    Ok updated

let get_strongest_trails ~fs (config : config) ~limit : pheromone list =
  match load_swarm ~fs config with
  | Error _ -> []
  | Ok swarm -> Pure.strongest_trails swarm ~limit

let propose ~fs (config : config) ~description ~proposed_by ?threshold ?deadline
    ?(rng = Level4_config.make_rng ()) ()
    : (quorum_proposal, string) result =
  match load_swarm ~fs config with
  | Error e -> Error ("propose: " ^ e)
  | Ok swarm ->
    let now = Time_compat.now () in
    let proposal = {
      proposal_id = Printf.sprintf "prop-%d-%d" (int_of_float (now *. 1000.0)) (Random.State.int rng 10000);
      description;
      proposed_by;
      proposed_at = now;
      votes_for = [proposed_by];
      votes_against = [];
      threshold = (match threshold with
        | Some t -> Level4_config.Threshold.of_float_clamped t
        | None -> swarm.swarm_cfg.quorum_threshold);
      deadline;
      status = `Pending;
    } in
    let updated = Pure.add_proposal swarm ~proposal in
    save_swarm ~fs config updated;
    Ok proposal

let vote ~fs (config : config) ~proposal_id ~agent_id ~vote_for : (quorum_proposal, string) result =
  match load_swarm ~fs config with
  | Error e -> Error ("vote: " ^ e)
  | Ok swarm ->
    let now = Time_compat.now () in
    let with_vote = Pure.record_vote swarm ~proposal_id ~agent_id ~vote_for in
    let updated = Pure.update_proposal_status with_vote ~proposal_id ~now in
    save_swarm ~fs config updated;
    match List.find_opt (fun p -> p.proposal_id = proposal_id) updated.proposals with
    | Some p -> Ok p
    | None -> Error (Printf.sprintf "vote: proposal %s not found after update" proposal_id)

let get_pending_proposals ~fs (config : config) : quorum_proposal list =
  match load_swarm ~fs config with
  | Error _ -> []
  | Ok swarm -> List.filter (fun p -> p.status = `Pending) swarm.proposals

let set_behavior ~fs (config : config) ~behavior : (swarm, string) result =
  match load_swarm ~fs config with
  | Error e -> Error ("set_behavior: " ^ e)
  | Ok swarm ->
    let updated = { swarm with swarm_cfg = { swarm.swarm_cfg with behavior } } in
    save_swarm ~fs config updated;
    Ok updated

let status ~fs (config : config) : Yojson.Safe.t =
  match load_swarm ~fs config with
  | Error _ -> `Assoc [("exists", `Bool false); ("message", `String "No swarm exists")]
  | Ok swarm ->
    let elite = select_elite ~fs config in
    `Assoc [
      ("exists", `Bool true);
      ("id", `String swarm.swarm_cfg.id);
      ("name", `String swarm.swarm_cfg.name);
      ("behavior", `String (behavior_to_string swarm.swarm_cfg.behavior));
      ("generation", `Int swarm.generation);
      ("agent_count", `Int (List.length swarm.agents));
      ("max_agents", `Int swarm.swarm_cfg.max_agents);
      ("pheromone_count", `Int (List.length swarm.pheromones));
      ("pending_proposals", `Int (List.length (List.filter (fun p -> p.status = `Pending) swarm.proposals)));
      ("selection_pressure", Level4_config.Normalized.to_json swarm.swarm_cfg.selection_pressure);
      ("mutation_rate", Level4_config.Normalized.to_json swarm.swarm_cfg.mutation_rate);
      ("elite_agents", `List (List.map (fun (a : swarm_agent) -> `String a.id) elite));
      ("created_at", `Float swarm.created_at);
      ("last_evolution", `Float swarm.last_evolution);
    ]
