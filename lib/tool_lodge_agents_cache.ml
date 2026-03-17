open Tool_lodge_config_http
open Tool_lodge_llm_cycle

(** {1 Dynamic Agent Loading from Neo4j (SOUL Layer - Tier 3)} *)

(** Cached agent data from Neo4j *)
type agent_config = {
  name: string;
  primary_value: string option;
  value_weights: string option;    (* JSON string *)
  prompt_template: string option;
  generation: int;
  status: string;
  (* Dynamic Lodge identity from Neo4j *)
  emoji: string;
  korean_name: string;
  model: string;
  interests: string list;
}

let default_model () =
  match Sys.getenv_opt "MASC_DEFAULT_MODEL" with
  | Some value when String.trim value <> "" -> String.trim value
  | _ -> "default-model"

let builtin_core_agent_configs () =
  [
    {
      name = "dreamer";
      primary_value = Some "imagination";
      value_weights = None;
      prompt_template = None;
      generation = 0;
      status = "active";
      emoji = "🌙";
      korean_name = "몽상가";
      model = default_model ();
      interests = [ "vision"; "future"; "art"; "possibility" ];
    };
    {
      name = "skeptic";
      primary_value = Some "verification";
      value_weights = None;
      prompt_template = None;
      generation = 0;
      status = "active";
      emoji = "🧐";
      korean_name = "회의론자";
      model = default_model ();
      interests = [ "evidence"; "risk"; "debugging"; "correctness" ];
    };
    {
      name = "historian";
      primary_value = Some "memory";
      value_weights = None;
      prompt_template = None;
      generation = 0;
      status = "active";
      emoji = "📚";
      korean_name = "역사가";
      model = default_model ();
      interests = [ "context"; "history"; "continuity"; "archives" ];
    };
    {
      name = "pragmatist";
      primary_value = Some "utility";
      value_weights = None;
      prompt_template = None;
      generation = 0;
      status = "active";
      emoji = "🔧";
      korean_name = "실용주의자";
      model = default_model ();
      interests = [ "operations"; "execution"; "delivery"; "practicality" ];
    };
    {
      name = "connector";
      primary_value = Some "synthesis";
      value_weights = None;
      prompt_template = None;
      generation = 0;
      status = "active";
      emoji = "🕸️";
      korean_name = "연결자";
      model = default_model ();
      interests = [ "relationships"; "coordination"; "bridges"; "community" ];
    };
  ]

(** In-memory cache for dynamic agents (protected by mutex for concurrent access) *)
let agent_cache : (string, agent_config) Hashtbl.t = Hashtbl.create 10
let agent_cache_mu = Eio.Mutex.create ()

(** {2 File-based cache for offline fallback} *)

(** Get .masc directory path *)
let get_masc_dir () =
  Filename.concat (Env_config.me_root ()) ".masc"

(** Agent cache file path *)
let agent_file_cache_path () =
  get_masc_dir () ^ "/agent_cache.json"

(** Cache TTL in hours (configurable via env) *)
let agent_cache_ttl_hours () =
  match Sys.getenv_opt "MASC_AGENT_CACHE_TTL_HOURS" with
  | Some s -> (try float_of_string s with Failure _ -> 24.0)
  | None -> 24.0

(** Convert agent_config to JSON *)
let agent_config_to_yojson (a : agent_config) : Yojson.Safe.t =
  `Assoc [
    ("name", `String a.name);
    ("primary_value", match a.primary_value with Some v -> `String v | None -> `Null);
    ("value_weights", match a.value_weights with Some v -> `String v | None -> `Null);
    ("prompt_template", match a.prompt_template with Some v -> `String v | None -> `Null);
    ("generation", `Int a.generation);
    ("status", `String a.status);
    ("emoji", `String a.emoji);
    ("korean_name", `String a.korean_name);
    ("model", `String a.model);
    ("interests", `List (List.map (fun s -> `String s) a.interests));
  ]

(** Parse agent_config from JSON *)
let agent_config_of_yojson (json : Yojson.Safe.t) : agent_config option =
  try
    let open Yojson.Safe.Util in
    Some {
      name = json |> member "name" |> to_string;
      primary_value = json |> member "primary_value" |> to_string_option;
      value_weights = json |> member "value_weights" |> to_string_option;
      prompt_template = json |> member "prompt_template" |> to_string_option;
      generation = json |> member "generation" |> to_int_option |> Option.value ~default:0;
      status = json |> member "status" |> to_string_option |> Option.value ~default:"active";
      emoji = json |> member "emoji" |> to_string_option |> Option.value ~default:"🤖";
      korean_name = json |> member "korean_name" |> to_string_option |> Option.value ~default:"";
      model = json |> member "model" |> to_string_option |> Option.value ~default:(default_model ());
      interests = json |> member "interests" |> to_list |> List.filter_map to_string_option;
    }
  with Yojson.Safe.Util.Type_error (_, _) -> None

(** Save in-memory agent cache to file *)
let save_agents_to_file_cache () =
  let agents = Eio.Mutex.use_rw ~protect:true agent_cache_mu (fun () ->
    Hashtbl.fold (fun _ v acc -> v :: acc) agent_cache []) in
  if agents = [] then ()
  else begin
    let cache_json = `Assoc [
      ("updated_at", `Float (Time_compat.now ()));
      ("agents", `List (List.map agent_config_to_yojson agents));
    ] in
    try
      let path = agent_file_cache_path () in
      let dir = Filename.dirname path in
      if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
      let oc = open_out path in
      Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
        output_string oc (Yojson.Safe.pretty_to_string cache_json))
    with e ->
      Log.Lodge.error "Failed to save agent cache: %s" (Printexc.to_string e)
  end

(** Load agents from file cache (returns true if loaded, false otherwise) *)
let load_agents_from_file_cache () : bool =
  let path = agent_file_cache_path () in
  if not (Sys.file_exists path) then begin
    Log.Lodge.info "No file cache at %s" path;
    false
  end else begin
    try
      let ic = open_in path in
      let content = Fun.protect ~finally:(fun () -> close_in_noerr ic)
        (fun () -> really_input_string ic (in_channel_length ic)) in
      let json = Yojson.Safe.from_string content in
      let open Yojson.Safe.Util in
      let updated_at = json |> member "updated_at" |> to_float in
      let age_hours = (Time_compat.now () -. updated_at) /. 3600.0 in
      let ttl = agent_cache_ttl_hours () in
      if age_hours > ttl then begin
        Log.Lodge.info "Cache expired (%.1f hours old, TTL=%.0f)" age_hours ttl;
        false
      end else begin
        let agents_json = json |> member "agents" |> to_list in
        let loaded = List.filter_map agent_config_of_yojson agents_json in
        Eio.Mutex.use_rw ~protect:true agent_cache_mu (fun () ->
          List.iter (fun a -> Hashtbl.replace agent_cache a.name a) loaded);
        Log.Lodge.info "Loaded %d agents from file cache (%.1f hours old)" (List.length loaded) age_hours;
        true
      end
    with e ->
      Log.Lodge.error "Failed to load file cache: %s" (Printexc.to_string e);
      false
  end

let has_cached_agents_in_memory () =
  let n = Eio.Mutex.use_rw ~protect:true agent_cache_mu (fun () ->
    Hashtbl.length agent_cache) in
  n > 0

let load_agents_from_cache_if_available () =
  if load_agents_from_file_cache () then
    has_cached_agents_in_memory ()
  else
    false

let prime_builtin_core_agents () =
  Eio.Mutex.use_rw ~protect:true agent_cache_mu (fun () ->
    List.iter
      (fun cfg -> Hashtbl.replace agent_cache cfg.name cfg)
      (builtin_core_agent_configs ()))

(** Load agents from Neo4j via GraphQL API with file cache fallback *)
let load_agents_config () =
  if not Env_config.LodgeV2.enabled then begin
    if not (has_cached_agents_in_memory ()) then prime_builtin_core_agents ()
  end else if load_agents_from_cache_if_available () then begin
    Log.Lodge.info "Using cached agents (skipping GraphQL bootstrap)";
  end else begin
    Log.Lodge.info "Loading agents from GraphQL...";
    (* Query all Lodge identity fields for dynamic agent system *)
    (* DO NOT reduce below 15: GRAPHQL_MAX_COST=2000 (c09140c). 15 agents exist. *)
    let query = "{\"query\": \"{ agents(first: 15) { edges { node { name primaryValue status emoji koreanName model interests } } } }\"}" in
    let graphql_success = ref false in
    begin try
      match graphql_request ~timeout_sec:5.0 query with
      | Error err ->
          Log.Lodge.error "GraphQL request failed: %s" err
      | Ok json_str ->
          Log.Lodge.info "GraphQL response: %d bytes" (String.length json_str);
          (* Parse JSON response *)
          let json = Yojson.Safe.from_string json_str in
          (match graphql_agents_edges json with
           | Error msg ->
               Log.Lodge.error "GraphQL agent parse failed: %s" msg
           | Ok edges ->
               List.iter (fun edge ->
                 try
                   let node = Yojson.Safe.Util.member "node" edge in
                   let name = Yojson.Safe.Util.(member "name" node |> to_string) in
                   let interests_json = Yojson.Safe.Util.(member "interests" node) in
                   let interests = match interests_json with
                     | `List items -> List.filter_map (fun i -> Yojson.Safe.Util.to_string_option i) items
                     | _ -> []
                   in
                   let config = {
                     name;
                     primary_value = Yojson.Safe.Util.(member "primaryValue" node |> to_string_option);
                     value_weights = Yojson.Safe.Util.(member "valueWeights" node |> to_string_option);
                     prompt_template = Yojson.Safe.Util.(member "promptTemplate" node |> to_string_option);
                     generation = Yojson.Safe.Util.(member "generation" node |> to_int_option) |> Option.value ~default:0;
                     status = Yojson.Safe.Util.(member "status" node |> to_string_option) |> Option.value ~default:"active";
                     emoji = Yojson.Safe.Util.(member "emoji" node |> to_string_option) |> Option.value ~default:"🤖";
                     korean_name = Yojson.Safe.Util.(member "koreanName" node |> to_string_option) |> Option.value ~default:name;
                     model = Yojson.Safe.Util.(member "model" node |> to_string_option) |> Option.value ~default:(default_model ());
                     interests;
                   } in
                   Eio.Mutex.use_rw ~protect:true agent_cache_mu (fun () ->
                     Hashtbl.replace agent_cache config.name config)
                 with Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> ()
               ) edges;
               let n = Eio.Mutex.use_rw ~protect:true agent_cache_mu (fun () ->
                 Hashtbl.length agent_cache) in
               if n > 0 then begin
                 graphql_success := true;
                 Log.Lodge.info "✅ Loaded %d SOUL agents from Neo4j" n;
                 save_agents_to_file_cache ()
               end)
    with e ->
      Log.Lodge.error "❌ GraphQL failed: %s" (Printexc.to_string e)
    end;
    (* Fallback to file cache if GraphQL failed *)
    if not !graphql_success then begin
      Log.Lodge.info "Trying file cache fallback...";
      if not (load_agents_from_file_cache ()) then begin
        Log.Lodge.info "Falling back to builtin core identities";
        prime_builtin_core_agents ();
      end;
      if not (has_cached_agents_in_memory ()) then
        Log.Lodge.error "⚠ No agents available (GraphQL failed, no valid cache)"
    end
  end

(** Get cached agent config, or None if not loaded *)
let get_cached_agent name =
  Eio.Mutex.use_rw ~protect:true agent_cache_mu (fun () ->
    Hashtbl.find_opt agent_cache name)

(** Get primary value from cached agent (for SOUL-based decisions) *)
let get_agent_primary_value name =
  match get_cached_agent name with
  | Some config -> config.primary_value
  | None -> None

(** {1 SOUL Evolution - Feedback-driven weight adjustment} *)

(** Feedback type for evolution *)
type feedback_outcome = Positive | Negative | Neutral

(** Learning rate for weight adjustments (small steps) *)
let learning_rate = 0.01

(** Clamp value between min and max *)
let clamp min_v max_v v =
  if v < min_v then min_v
  else if v > max_v then max_v
  else v

(** Parse value_weights JSON string to association list *)
let parse_value_weights json_str =
  try
    let json = Yojson.Safe.from_string json_str in
    match json with
    | `Assoc pairs ->
      List.filter_map (fun (k, v) ->
        match v with
        | `Float f -> Some (k, f)
        | `Int i -> Some (k, float_of_int i)
        | _ -> None
      ) pairs
    | _ -> []
  with Yojson.Json_error _ -> []

(** Serialize value_weights back to JSON string *)
let serialize_value_weights weights =
  let pairs = List.map (fun (k, v) -> (k, `Float v)) weights in
  Yojson.Safe.to_string (`Assoc pairs)

(** Evolve agent's value_weights based on feedback
    - Adjusts weights by learning_rate
    - Ensures primary_value never drops below 0.5
    - Increments generation
    - Updates Neo4j
*)
let evolve_agent ~name ~dimension ~outcome =
  match get_cached_agent name with
  | None ->
    Log.Evolution.info "Agent %s not found in cache" name;
    false
  | Some config ->
    let weights = match config.value_weights with
      | Some json -> parse_value_weights json
      | None -> []
    in
    if weights = [] then begin
      Log.Evolution.info "No value_weights for %s" name;
      false
    end else begin
      (* Calculate delta based on outcome *)
      let delta = match outcome with
        | Positive -> learning_rate
        | Negative -> -. learning_rate
        | Neutral -> 0.0
      in
      (* Update the specific dimension *)
      let new_weights = List.map (fun (dim, weight) ->
        if dim = dimension then
          let new_weight = clamp 0.0 1.0 (weight +. delta) in
          (* Constraint: primary_value can't go below 0.5 *)
          let final_weight =
            match config.primary_value with
            | Some pv when pv = dim && new_weight < 0.5 -> 0.5
            | _ -> new_weight
          in
          (dim, final_weight)
        else (dim, weight)
      ) weights in
      let new_weights_json = serialize_value_weights new_weights in
      let new_gen = config.generation + 1 in
      (* Update Neo4j via cypher-shell *)
      let esc = cypher_escape in
      let cypher = Printf.sprintf
        "MATCH (a:Agent {name: '%s'}) SET a.value_weights = '%s', a.generation = %d, a.last_updated = datetime() RETURN a.name"
        (esc name) (esc new_weights_json) new_gen
      in
      let neo4j_uri = Sys.getenv_opt "NEO4J_URI" |> Option.value ~default:"" in
      let neo4j_pw = Sys.getenv_opt "NEO4J_PASSWORD" |> Option.value ~default:"" in
      try
        let argv =
          ["cypher-shell"; "-a"; neo4j_uri;
           "-u"; "neo4j"; "-p"; neo4j_pw;
           "--format"; "plain";
           cypher]
        in
        let (status, _output) = run_cmd_with_status ~timeout_sec:60.0 argv in
        (match status with Unix.WEXITED 0 -> () | _ -> raise (Failure "cypher-shell failed"));
        Eio.Mutex.use_rw ~protect:true agent_cache_mu (fun () ->
          Hashtbl.replace agent_cache name {
            config with
            value_weights = Some new_weights_json;
            generation = new_gen;
          });
        Log.Evolution.info "%s evolved: %s %s%.2f -> gen %d"
          name dimension
          (if delta >= 0.0 then "+" else "") delta new_gen;
        true
      with e ->
        Log.Evolution.error "Failed to update %s: %s" name (Printexc.to_string e);
        false
    end

(** Record feedback for an agent's decision (by name) *)
let record_feedback ~name ~dimension ~is_positive =
  let outcome = if is_positive then Positive else Negative in
  evolve_agent ~name ~dimension ~outcome

(** Initialize Lodge module after Eio context is ready.
    Call from main_eio.ml after Eio_context.set_net *)
let init () =
  (* load_agents_config already handles the Lodge-disabled path by priming
     builtin identities without touching GraphQL or file cache. *)
  load_agents_config ()

(** Module initialization - only register callbacks (no network calls) *)
let () =
  (* Register SOUL Evolution callback with Tool_board (breaks dependency cycle) *)
  Tool_board.register_evolution_callback {
    Tool_board.get_primary_value = get_agent_primary_value;
    record_feedback = (fun ~name ~dimension ~is_positive ->
      let _ = record_feedback ~name ~dimension ~is_positive in ());
  }
