(** MASC Institution - Level 5 Persistent Collective Memory (Eio Native) *)

(** {1 Types} *)

type episode = {
  id: string;
  timestamp: float;
  participants: string list;
  event_type: string;
  summary: string;
  outcome: [`Success | `Failure | `Partial];
  learnings: string list;
  context: (string * string) list;
}

type knowledge = {
  id: string;
  topic: string;
  content: string;
  confidence: float;
  source: string;
  created_at: float;
  last_verified: float;
  references: string list;
}

type pattern = {
  id: string;
  name: string;
  description: string;
  trigger: string;
  steps: string list;
  success_rate: float;
  usage_count: int;
  last_used: float;
  evolved_from: string option;
  effectiveness_used: int;
  effectiveness_unused: int;
  effectiveness_last_check: float;
}

type cultural_value = {
  id: string;
  name: string;
  description: string;
  weight: float;
  examples: string list;
  anti_patterns: string list;
  adopted_at: float;
}

type succession_policy = {
  onboarding_steps: string list;
  required_knowledge: string list;
  mentor_assignment: [`Random | `Best_fit | `Round_robin];
  probation_period: float;
  graduation_criteria: string list;
}

type long_term_memory = {
  episodic: episode list;
  semantic: knowledge list;
  procedural: pattern list;
}

type identity = {
  id: string;
  name: string;
  mission: string;
  founded_at: float;
  generation: int;
}

type institution = {
  identity: identity;
  memory: long_term_memory;
  culture: cultural_value list;
  succession: succession_policy;
  current_agents: string list;
  alumni: string list;
}

type config = Room_utils.config

(** {1 Default Values} *)

let default_succession () : succession_policy = {
  onboarding_steps = [
    "Read mission statement";
    "Review recent episodes";
    "Learn top 5 patterns";
    "Shadow mentor for 3 tasks";
  ];
  required_knowledge = [];
  mentor_assignment = `Best_fit;
  probation_period = 24.0;
  graduation_criteria = [
    "Complete 3 tasks successfully";
    "Demonstrate 2 patterns";
    "Receive mentor approval";
  ];
}

let create_institution ~name ~mission () : institution =
  let now = Time_compat.now () in
  {
    identity = {
      id = Printf.sprintf "inst-%d" (Level4_config.random_int 100000);
      name;
      mission;
      founded_at = now;
      generation = 0;
    };
    memory = { episodic = []; semantic = []; procedural = [] };
    culture = [];
    succession = default_succession ();
    current_agents = [];
    alumni = [];
  }

(** {1 Persistence (Eio Native)} *)

(** {1 Serialization (Helpers)} *)

let outcome_to_string = function `Success -> "success" | `Failure -> "failure" | `Partial -> "partial"
let outcome_of_string = function "success" -> `Success | "failure" -> `Failure | _ -> `Partial
let mentor_to_string = function `Random -> "random" | `Best_fit -> "best_fit" | `Round_robin -> "round_robin"
let mentor_of_string = function "random" -> `Random | "best_fit" -> `Best_fit | "round_robin" -> `Round_robin | _ -> `Best_fit

(** JSON number → float (handles both JSON Int and Float) *)
let json_to_float = function
  | `Float f -> f
  | `Int i -> Float.of_int i
  | `Intlit s -> Float.of_string s
  | `Null -> 0.0
  | _ -> 0.0

let rec episode_to_json (e : episode) : Yojson.Safe.t =
  `Assoc [
    ("id", `String e.id);
    ("timestamp", `Float e.timestamp);
    ("participants", `List (List.map (fun p -> `String p) e.participants));
    ("event_type", `String e.event_type);
    ("summary", `String e.summary);
    ("outcome", `String (outcome_to_string e.outcome));
    ("learnings", `List (List.map (fun l -> `String l) e.learnings));
    ("context", `Assoc (List.map (fun (k, v) -> (k, `String v)) e.context));
  ]

and episode_of_json json =
  let open Yojson.Safe.Util in
  {
    id = json |> member "id" |> to_string;
    timestamp = json |> member "timestamp" |> json_to_float;
    participants = json |> member "participants" |> to_list |> List.map to_string;
    event_type = json |> member "event_type" |> to_string;
    summary = json |> member "summary" |> to_string;
    outcome = json |> member "outcome" |> to_string |> outcome_of_string;
    learnings = json |> member "learnings" |> to_list |> List.map to_string;
    context = json |> member "context" |> to_assoc |> List.map (fun (k, v) -> (k, to_string v));
  }

and knowledge_to_json (k : knowledge) : Yojson.Safe.t =
  `Assoc [
    ("id", `String k.id);
    ("topic", `String k.topic);
    ("content", `String k.content);
    ("confidence", `Float k.confidence);
    ("source", `String k.source);
    ("created_at", `Float k.created_at);
    ("last_verified", `Float k.last_verified);
    ("references", `List (List.map (fun r -> `String r) k.references));
  ]

and knowledge_of_json json =
  let open Yojson.Safe.Util in
  {
    id = json |> member "id" |> to_string;
    topic = json |> member "topic" |> to_string;
    content = json |> member "content" |> to_string;
    confidence = json |> member "confidence" |> json_to_float;
    source = json |> member "source" |> to_string;
    created_at = json |> member "created_at" |> json_to_float;
    last_verified = json |> member "last_verified" |> json_to_float;
    references = json |> member "references" |> to_list |> List.map to_string;
  }

and pattern_to_json (p : pattern) : Yojson.Safe.t =
  `Assoc [
    ("id", `String p.id);
    ("name", `String p.name);
    ("description", `String p.description);
    ("trigger", `String p.trigger);
    ("steps", `List (List.map (fun s -> `String s) p.steps));
    ("success_rate", `Float p.success_rate);
    ("usage_count", `Int p.usage_count);
    ("last_used", `Float p.last_used);
    ("evolved_from", Json_util.string_opt_to_json p.evolved_from);
    ("effectiveness_used", `Int p.effectiveness_used);
    ("effectiveness_unused", `Int p.effectiveness_unused);
    ("effectiveness_last_check", `Float p.effectiveness_last_check);
  ]

and pattern_of_json json =
  let open Yojson.Safe.Util in
  {
    id = json |> member "id" |> to_string;
    name = json |> member "name" |> to_string;
    description = json |> member "description" |> to_string;
    trigger = json |> member "trigger" |> to_string;
    steps = json |> member "steps" |> to_list |> List.map to_string;
    success_rate = json |> member "success_rate" |> json_to_float;
    usage_count = json |> member "usage_count" |> to_int;
    last_used = json |> member "last_used" |> json_to_float;
    evolved_from = json |> member "evolved_from" |> to_string_option;
    effectiveness_used =
      (match json |> member "effectiveness_used" with
       | `Int n -> n | _ -> 0);
    effectiveness_unused =
      (match json |> member "effectiveness_unused" with
       | `Int n -> n | _ -> 0);
    effectiveness_last_check =
      (match json |> member "effectiveness_last_check" with
       | `Null -> 0.0 | other -> json_to_float other);
  }

and cultural_value_to_json (c : cultural_value) : Yojson.Safe.t =
  `Assoc [
    ("id", `String c.id);
    ("name", `String c.name);
    ("description", `String c.description);
    ("weight", `Float c.weight);
    ("examples", `List (List.map (fun e -> `String e) c.examples));
    ("anti_patterns", `List (List.map (fun a -> `String a) c.anti_patterns));
    ("adopted_at", `Float c.adopted_at);
  ]

and cultural_value_of_json json =
  let open Yojson.Safe.Util in
  {
    id = json |> member "id" |> to_string;
    name = json |> member "name" |> to_string;
    description = json |> member "description" |> to_string;
    weight = json |> member "weight" |> json_to_float;
    examples = json |> member "examples" |> to_list |> List.map to_string;
    anti_patterns = json |> member "anti_patterns" |> to_list |> List.map to_string;
    adopted_at = json |> member "adopted_at" |> json_to_float;
  }

and succession_to_json (s : succession_policy) : Yojson.Safe.t =
  `Assoc [
    ("onboarding_steps", `List (List.map (fun s -> `String s) s.onboarding_steps));
    ("required_knowledge", `List (List.map (fun k -> `String k) s.required_knowledge));
    ("mentor_assignment", `String (mentor_to_string s.mentor_assignment));
    ("probation_period", `Float s.probation_period);
    ("graduation_criteria", `List (List.map (fun c -> `String c) s.graduation_criteria));
  ]

and succession_of_json json =
  let open Yojson.Safe.Util in
  {
    onboarding_steps = json |> member "onboarding_steps" |> to_list |> List.map to_string;
    required_knowledge = json |> member "required_knowledge" |> to_list |> List.map to_string;
    mentor_assignment = json |> member "mentor_assignment" |> to_string |> mentor_of_string;
    probation_period = json |> member "probation_period" |> json_to_float;
    graduation_criteria = json |> member "graduation_criteria" |> to_list |> List.map to_string;
  }

and identity_to_json (i : identity) : Yojson.Safe.t =
  `Assoc [
    ("id", `String i.id);
    ("name", `String i.name);
    ("mission", `String i.mission);
    ("founded_at", `Float i.founded_at);
    ("generation", `Int i.generation);
  ]

and identity_of_json json =
  let open Yojson.Safe.Util in
  {
    id = json |> member "id" |> to_string;
    name = json |> member "name" |> to_string;
    mission = json |> member "mission" |> to_string;
    founded_at = json |> member "founded_at" |> json_to_float;
    generation = json |> member "generation" |> to_int;
  }

and memory_to_json (m : long_term_memory) : Yojson.Safe.t =
  `Assoc [
    ("episodic", `List (List.map episode_to_json m.episodic));
    ("semantic", `List (List.map knowledge_to_json m.semantic));
    ("procedural", `List (List.map pattern_to_json m.procedural));
  ]

and memory_of_json json =
  let open Yojson.Safe.Util in
  {
    episodic = json |> member "episodic" |> to_list |> List.map episode_of_json;
    semantic = json |> member "semantic" |> to_list |> List.map knowledge_of_json;
    procedural = json |> member "procedural" |> to_list |> List.map pattern_of_json;
  }

and institution_to_json (inst : institution) : Yojson.Safe.t =
  `Assoc [
    ("identity", identity_to_json inst.identity);
    ("memory", memory_to_json inst.memory);
    ("culture", `List (List.map cultural_value_to_json inst.culture));
    ("succession", succession_to_json inst.succession);
    ("current_agents", `List (List.map (fun a -> `String a) inst.current_agents));
    ("alumni", `List (List.map (fun a -> `String a) inst.alumni));
  ]

and institution_of_json json =
  let open Yojson.Safe.Util in
  {
    identity = json |> member "identity" |> identity_of_json;
    memory = json |> member "memory" |> memory_of_json;
    culture = json |> member "culture" |> to_list |> List.map cultural_value_of_json;
    succession = json |> member "succession" |> succession_of_json;
    current_agents = json |> member "current_agents" |> to_list |> List.map to_string;
    alumni = json |> member "alumni" |> to_list |> List.map to_string;
  }

(** {1 Persistence (Eio Native)} *)

let institution_file (config : config) =
  Filename.concat config.base_path ".masc/institution.json"

let load_institution ~fs (config : config) : institution option =
  let file = institution_file config in
  let path = Eio.Path.(fs / file) in
  try
    let content = Eio.Path.load path in
    let json = Yojson.Safe.from_string content in
    Some (institution_of_json json)
  with Eio.Io _ | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None

let save_institution ~fs (config : config) (inst : institution) =
  let file = institution_file config in
  let path = Eio.Path.(fs / file) in
  let dir = Filename.dirname file in
  let dir_path = Eio.Path.(fs / dir) in
  (try Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 dir_path
   with Eio.Io _ as e -> Log.Institution.warn "mkdirs %s: %s" dir (Printexc.to_string e));
  let json = institution_to_json inst in
  let content = Yojson.Safe.pretty_to_string json in
  Eio.Path.save ~create:(`Or_truncate 0o644) path content

(** {1 Pure Transformations} *)

module Pure = struct
  let record_episode inst ~episode =
    let memory = { inst.memory with episodic = episode :: inst.memory.episodic } in
    { inst with memory }

  let add_knowledge inst ~knowledge =
    let memory = { inst.memory with semantic = knowledge :: inst.memory.semantic } in
    { inst with memory }

  let add_pattern inst ~pattern =
    let memory = { inst.memory with procedural = pattern :: inst.memory.procedural } in
    { inst with memory }

  let update_pattern_stats (inst : institution) ~pattern_id ~success ~now =
    let procedural = List.map (fun (p : pattern) ->
      if p.id = pattern_id then
        let new_count = p.usage_count + 1 in
        let new_rate =
          if success then (p.success_rate *. float_of_int p.usage_count +. 1.0) /. float_of_int new_count
          else (p.success_rate *. float_of_int p.usage_count) /. float_of_int new_count
        in
        { p with usage_count = new_count; success_rate = new_rate; last_used = now }
      else p
    ) inst.memory.procedural in
    { inst with memory = { inst.memory with procedural } }

  let agent_join inst ~agent_id =
    if List.mem agent_id inst.current_agents then inst
    else { inst with current_agents = agent_id :: inst.current_agents }

  let agent_leave inst ~agent_id =
    if List.mem agent_id inst.current_agents then
      { inst with
        current_agents = List.filter ((<>) agent_id) inst.current_agents;
        alumni = agent_id :: inst.alumni;
      }
    else inst

  (** Record whether a pattern was used after injection.
      Increments effectiveness_used or effectiveness_unused accordingly. *)
  let record_effectiveness inst ~pattern_id ~used ~now =
    let procedural = List.map (fun (p : pattern) ->
      if p.id = pattern_id then
        if used then
          { p with effectiveness_used = p.effectiveness_used + 1;
                   effectiveness_last_check = now }
        else
          { p with effectiveness_unused = p.effectiveness_unused + 1;
                   effectiveness_last_check = now }
      else p
    ) inst.memory.procedural in
    { inst with memory = { inst.memory with procedural } }

  (** Compute effectiveness score with 30-day time decay.
      Formula: (used / (used + unused)) * e^(-(now - last_used) / (30 * 86400))
      Returns 0.0 if no effectiveness data has been recorded. *)
  let effectiveness_score (p : pattern) ~now =
    let total = p.effectiveness_used + p.effectiveness_unused in
    if total = 0 then 0.0
    else
      let ratio = float_of_int p.effectiveness_used /. float_of_int total in
      let decay_constant = Masc_time_constants.days_to_seconds 30 in
      let elapsed = now -. p.last_used in
      let decay = exp (-. elapsed /. decay_constant) in
      ratio *. decay

  (** Remove patterns whose effectiveness_score falls below threshold.
      Patterns with no effectiveness data (score = 0.0) are kept
      to avoid pruning newly created patterns. *)
  let prune_ineffective inst ~threshold ~now =
    let procedural = List.filter (fun (p : pattern) ->
      let total = p.effectiveness_used + p.effectiveness_unused in
      if total = 0 then true  (* keep patterns with no effectiveness data *)
      else effectiveness_score p ~now >= threshold
    ) inst.memory.procedural in
    { inst with memory = { inst.memory with procedural } }
end

(** {1 Effectful Operations (Eio)} *)

let get_or_create ~fs (config : config) ~name ~mission =
  match load_institution ~fs config with
  | Some inst -> inst
  | None ->
    let inst = create_institution ~name ~mission () in
    save_institution ~fs config inst;
    inst

let record_episode ~fs config inst ~event_type ~summary ~participants ~outcome ~learnings =
  let episode : episode = {
    id = Printf.sprintf "ep-%d" (Level4_config.random_int 100000);
    timestamp = Time_compat.now ();
    participants; event_type; summary; outcome; learnings; context = [];
  } in
  let inst' = Pure.record_episode inst ~episode in
  save_institution ~fs config inst';
  inst'

let learn_knowledge ~fs config inst ~topic ~content ~source =
  let now = Time_compat.now (); in
  let knowledge : knowledge = {
    id = Printf.sprintf "know-%d" (Level4_config.random_int 100000);
    topic; content; confidence = 0.5; source; created_at = now; last_verified = now; references = [];
  } in
  let inst' = Pure.add_knowledge inst ~knowledge in
  save_institution ~fs config inst';
  inst'

let codify_pattern ~fs config inst ~name ~description ~trigger ~steps =
  let pattern : pattern = {
    id = Printf.sprintf "pat-%d" (Level4_config.random_int 100000);
    name; description; trigger; steps; success_rate = 0.5; usage_count = 0;
    last_used = Time_compat.now (); evolved_from = None;
    effectiveness_used = 0; effectiveness_unused = 0;
    effectiveness_last_check = 0.0;
  } in
  let inst' = Pure.add_pattern inst ~pattern in
  save_institution ~fs config inst';
  inst'

let join ~fs config inst ~agent_id =
  let inst' = Pure.agent_join inst ~agent_id in
  save_institution ~fs config inst';
  inst'

let leave ~fs config inst ~agent_id =
  let inst' = Pure.agent_leave inst ~agent_id in
  save_institution ~fs config inst';
  inst'

(** {1 Cultural Inheritance - Agent Being Protocol} *)

(** Format institution memory for injection into agent prompts.
    This is the core of Cultural Inheritance - passing collective wisdom to new agents.

    Inspired by:
    - Stanford Generative Agents: Memory stream → Reflection → Behavior
    - Institutional Theory: Values, norms, and procedures shape behavior

    @param inst The institution to format
    @param include_patterns Whether to include procedural patterns (default: true)
    @param max_patterns Maximum patterns to include (default: 5)
    @return Formatted string for prompt injection
*)
let format_for_injection ?(include_patterns=true) ?(max_patterns=5) (inst : institution) : string =
  let buf = Buffer.create 1024 in

  (* Mission Statement *)
  Buffer.add_string buf "---\n[INSTITUTIONAL MEMORY - Cultural Inheritance]\n\n";
  Buffer.add_string buf (Printf.sprintf "🏛️ **Mission**: %s\n" inst.identity.mission);
  Buffer.add_string buf (Printf.sprintf "📅 Generation: %d | Founded: %s\n\n"
    inst.identity.generation
    (let t = Unix.gmtime inst.identity.founded_at in
     Printf.sprintf "%04d-%02d-%02d" (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday));

  (* Cultural Values *)
  if inst.culture <> [] then begin
    Buffer.add_string buf "**Core Values** (inherited from predecessors):\n";
    List.iter (fun (v : cultural_value) ->
      Buffer.add_string buf (Printf.sprintf "  • %s (%.0f%% weight): %s\n"
        v.name (v.weight *. 100.0) v.description);
      if v.anti_patterns <> [] then
        Buffer.add_string buf (Printf.sprintf "    ⚠️ Avoid: %s\n" (String.concat ", " v.anti_patterns))
    ) (List.sort (fun a b -> compare b.weight a.weight) inst.culture |> List.filteri (fun i _ -> i < 3))
  end;

  (* Procedural Patterns - Top N by success rate, filtered by effectiveness *)
  if include_patterns && inst.memory.procedural <> [] then begin
    Buffer.add_string buf "\n**Learned Patterns** (collective wisdom):\n";
    let now = Time_compat.now () in
    let sorted_patterns =
      inst.memory.procedural
      |> List.filter (fun (p : pattern) ->
           (* Keep patterns with no effectiveness data or score >= 0.2 *)
           let total = p.effectiveness_used + p.effectiveness_unused in
           total = 0 || Pure.effectiveness_score p ~now >= 0.2)
      |> List.sort (fun a b -> compare b.success_rate a.success_rate)
      |> List.filteri (fun i _ -> i < max_patterns)
    in
    List.iter (fun (p : pattern) ->
      Buffer.add_string buf (Printf.sprintf "  📋 %s (%.0f%% success, %d uses)\n"
        p.name (p.success_rate *. 100.0) p.usage_count);
      Buffer.add_string buf (Printf.sprintf "     Trigger: %s\n" p.trigger);
      if List.length p.steps <= 3 then
        List.iter (fun step ->
          Buffer.add_string buf (Printf.sprintf "     → %s\n" step)
        ) p.steps
    ) sorted_patterns
  end;

  (* Onboarding Steps *)
  Buffer.add_string buf "\n**Onboarding** (your first steps):\n";
  List.iteri (fun i step ->
    Buffer.add_string buf (Printf.sprintf "  %d. %s\n" (i + 1) step)
  ) inst.succession.onboarding_steps;

  (* Alumni Network *)
  if List.length inst.alumni > 0 then begin
    let recent_alumni = List.filteri (fun i _ -> i < 3) inst.alumni in
    Buffer.add_string buf (Printf.sprintf "\n👥 Recent predecessors: %s\n"
      (String.concat ", " recent_alumni))
  end;

  Buffer.add_string buf "---\n";
  Buffer.contents buf

(** Load institution and format for spawn injection.
    Returns empty string if no institution exists.
*)
let load_and_format_for_spawn ~fs (config : config) : string =
  match load_institution ~fs config with
  | Some inst -> format_for_injection inst
  | None -> ""

(** Short welcome format for masc_join response.
    Concise cultural inheritance - mission + values + one tip.
    @param inst The institution to format
    @return Formatted string for join welcome
*)
let format_for_welcome (inst : institution) : string =
  let buf = Buffer.create 512 in

  Buffer.add_string buf "\n📜 **Cultural Inheritance** (from your predecessors)\n";
  Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";

  (* Mission - one line, validated *)
  let mission = String.trim inst.identity.mission in
  let mission_short =
    if mission = "" then "(not defined)"
    else if String.length mission > 80 then String.sub mission 0 77 ^ "..."
    else mission
  in
  Buffer.add_string buf ("🏛️ Mission: " ^ mission_short ^ "\n");

  (* Top 3 values - compact *)
  if inst.culture <> [] then begin
    let top_values =
      List.sort (fun a b -> compare b.weight a.weight) inst.culture
      |> List.filteri (fun i _ -> i < 3)
    in
    let value_names = List.map (fun (v : cultural_value) -> v.name) top_values in
    Buffer.add_string buf ("💎 Values: " ^ String.concat ", " value_names ^ "\n")
  end;

  (* One procedural tip - pattern match for safety *)
  (match List.sort (fun a b -> compare b.success_rate a.success_rate) inst.memory.procedural with
   | best :: _ ->
       Buffer.add_string buf ("💡 Tip: " ^ best.name ^ " → " ^ best.trigger ^ "\n")
   | [] -> ());

  Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
  Buffer.add_string buf "📚 Full: resources/read → masc://institution\n";

  Buffer.contents buf

(** Load institution and format for join welcome.
    Returns empty string if no institution exists.
*)
let load_and_format_for_welcome ~fs:_ (config : config) : string =
  let file = institution_file config in
  if Fs_compat.file_exists file then
    try
      let content = Fs_compat.load_file file in
      let json = Yojson.Safe.from_string content in
      let inst = institution_of_json json in
      format_for_welcome inst
    with
    | Sys_error _ | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ""
    | exn ->
        Log.Misc.error "Unexpected institution load error: %s" (Printexc.to_string exn); ""
  else ""

(** {1 Lightweight JSONL Episode Recording (No Eio Required)}

    Append-only episode log for contexts that don't have Eio fs.
    Used by Keeper heartbeat, keeper decisions, etc.
    Storage: .masc/institution_episodes.jsonl *)

let episodes_jsonl_path () =
  Filename.concat (Env_config.base_path ()) ".masc/institution_episodes.jsonl"

(** Record an episode to JSONL without Eio context.
    This is the primary entry point for Keeper autonomy integration. *)
let record_episode_jsonl ~event_type ~summary ~participants ~outcome ~learnings =
  let episode : episode = {
    id = Printf.sprintf "ep-%d-%06d"
      (int_of_float (Time_compat.now ())) (Level4_config.random_int 999999);
    timestamp = Time_compat.now ();
    participants;
    event_type;
    summary;
    outcome;
    learnings;
    context = [];
  } in
  let path = episodes_jsonl_path () in
  (try
    Fs_compat.append_jsonl path (episode_to_json episode)
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Institution.error "JSONL episode write failed: %s"
      (Printexc.to_string exn));
  episode

(** Load recent episodes from JSONL (last N entries). *)
let load_recent_episodes_jsonl ~limit : episode list =
  let path = episodes_jsonl_path () in
  let jsons = Fs_compat.load_jsonl path in
  let all = List.filter_map (fun json ->
    try Some (episode_of_json json)
    with
    | Yojson.Safe.Util.Type_error _ -> None
    | exn ->
        Log.Institution.warn "episode parse failed: %s" (Printexc.to_string exn);
        None
  ) jsons in
  let total = List.length all in
  if total <= limit then all
  else
    let rec drop n = function
      | [] -> []
      | remaining when n <= 0 -> remaining
      | _ :: rest -> drop (n - 1) rest
    in
    drop (total - limit) all
