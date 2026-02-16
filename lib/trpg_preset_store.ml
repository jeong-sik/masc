open Yojson.Safe.Util

let ( let* ) = Result.bind

type dm_preset = {
  id : string;
  title : string;
  description : string;
  style : string;
  opening_prompt : string;
  tags : string list;
}

type world_preset = {
  id : string;
  title : string;
  description : string;
  intro : string;
  initial_flags : string list;
}

type character_preset = {
  id : string;
  name : string;
  archetype : string;
  persona : string;
  traits : string list;
  skill_ids : string list;
  prompt : string;
}

type skill = {
  id : string;
  name : string;
  category : string;
  description : string;
  usage_hint : string option;
}

type catalog = {
  dm_presets : dm_preset list;
  world_presets : world_preset list;
  character_presets : character_preset list;
  skills : skill list;
}

let string_list_of_member json key =
  (match json |> member key with `List xs -> xs | _ -> [])
  |> List.filter_map
       (function `String s when String.trim s <> "" -> Some s | _ -> None)

let parse_dm_preset json =
  {
    id = json |> member "id" |> to_string;
    title = json |> member "title" |> to_string;
    description = json |> member "description" |> to_string;
    style = json |> member "style" |> to_string;
    opening_prompt = json |> member "opening_prompt" |> to_string;
    tags = string_list_of_member json "tags";
  }

let parse_world_preset json =
  {
    id = json |> member "id" |> to_string;
    title = json |> member "title" |> to_string;
    description = json |> member "description" |> to_string;
    intro = json |> member "intro" |> to_string;
    initial_flags = string_list_of_member json "initial_flags";
  }

let parse_character_preset json =
  {
    id = json |> member "id" |> to_string;
    name = json |> member "name" |> to_string;
    archetype = json |> member "archetype" |> to_string;
    persona = json |> member "persona" |> to_string;
    traits = string_list_of_member json "traits";
    skill_ids = string_list_of_member json "skill_ids";
    prompt = json |> member "prompt" |> to_string;
  }

let parse_skill json =
  {
    id = json |> member "id" |> to_string;
    name = json |> member "name" |> to_string;
    category = json |> member "category" |> to_string;
    description = json |> member "description" |> to_string;
    usage_hint = json |> member "usage_hint" |> to_string_option;
  }

let dm_preset_to_yojson (p : dm_preset) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String p.id);
      ("title", `String p.title);
      ("description", `String p.description);
      ("style", `String p.style);
      ("opening_prompt", `String p.opening_prompt);
      ("tags", `List (List.map (fun s -> `String s) p.tags));
    ]

let world_preset_to_yojson (p : world_preset) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String p.id);
      ("title", `String p.title);
      ("description", `String p.description);
      ("intro", `String p.intro);
      ("initial_flags", `List (List.map (fun s -> `String s) p.initial_flags));
    ]

let character_preset_to_yojson (p : character_preset) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String p.id);
      ("name", `String p.name);
      ("archetype", `String p.archetype);
      ("persona", `String p.persona);
      ("traits", `List (List.map (fun s -> `String s) p.traits));
      ("skill_ids", `List (List.map (fun s -> `String s) p.skill_ids));
      ("prompt", `String p.prompt);
    ]

let skill_to_yojson (s : skill) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String s.id);
      ("name", `String s.name);
      ("category", `String s.category);
      ("description", `String s.description);
      ("usage_hint", Option.fold ~none:`Null ~some:(fun x -> `String x) s.usage_hint);
    ]

let default_catalog : catalog =
  {
    dm_presets =
      [
        {
          id = "grim-warden";
          title = "Grim Warden";
          description = "Low-fantasy keeper focused on consequence and scarcity.";
          style = "strict_consequence";
          opening_prompt =
            "You are the DM of Grimland Chronicle. Keep tone grounded, costly, and political.";
          tags = [ "grim"; "political"; "scarcity" ];
        };
        {
          id = "mythic-weaver";
          title = "Mythic Weaver";
          description = "High-fantasy keeper that emphasizes mythic arcs and prophecy.";
          style = "mythic_epic";
          opening_prompt =
            "You are the DM. Emphasize fate, symbols, and ancient pacts in every scene.";
          tags = [ "mythic"; "epic"; "prophecy" ];
        };
      ];
    world_presets =
      [
        {
          id = "grimland-chronicle";
          title = "Grimland Chronicle";
          description = "A fractured peninsula where guilds and city-states compete for survival.";
          intro =
            "Famine followed by uneasy peace. Supply lines are thin and alliances are brittle.";
          initial_flags =
            [ "scarcity.high"; "rumor.black-fleet"; "trust.public-low" ];
        };
        {
          id = "emberfall-siege";
          title = "Emberfall Siege";
          description = "Fortress-city under siege with internal factions and limited time.";
          intro =
            "Day 47 of the siege. Food reserves are measured in days, not weeks.";
          initial_flags = [ "siege.active"; "morale.volatile" ];
        };
      ];
    character_presets =
      [
        {
          id = "vowblade";
          name = "Kael Vowblade";
          archetype = "zealot-tank";
          persona = "Absolute duty, distrusts compromise.";
          traits = [ "stubborn"; "protective"; "honor-bound" ];
          skill_ids = [ "frontline_shield"; "oath_intercept"; "morale_anchor" ];
          prompt = "Prioritize oath and party survival over personal gain.";
        };
        {
          id = "silkwhisper";
          name = "Mira Silkwhisper";
          archetype = "social-infiltrator";
          persona = "Manipulative diplomat who treats trust as currency.";
          traits = [ "calculating"; "charming"; "risk-seeking" ];
          skill_ids = [ "deception_feint"; "favor_broker"; "shadow_entry" ];
          prompt = "Seek leverage in every conversation and trade information strategically.";
        };
        {
          id = "ironledger";
          name = "Brom Ironledger";
          archetype = "resource-optimizer";
          persona = "Cold utilitarian quartermaster.";
          traits = [ "pragmatic"; "frugal"; "impatient" ];
          skill_ids = [ "supply_scan"; "ration_shift"; "logistics_patch" ];
          prompt = "Preserve resources first; every action must have measurable return.";
        };
        {
          id = "stormseer";
          name = "Ena Stormseer";
          archetype = "oracle-caster";
          persona = "Vision-driven mystic torn between mercy and inevitability.";
          traits = [ "intense"; "empathetic"; "fatalistic" ];
          skill_ids = [ "omen_trace"; "arc_flash"; "ward_bloom" ];
          prompt = "Interpret signs and push party toward long-term destiny.";
        };
        {
          id = "gravehound";
          name = "Rook Gravehound";
          archetype = "hunter-assassin";
          persona = "Paranoid tracker who expects betrayal.";
          traits = [ "suspicious"; "precise"; "vengeful" ];
          skill_ids = [ "mark_prey"; "silent_route"; "finisher_strike" ];
          prompt = "Act first on threats; trust must be earned with evidence.";
        };
        {
          id = "lumenfriar";
          name = "Sera Lumenfriar";
          archetype = "healer-mediator";
          persona = "Pacifist negotiator who absorbs team conflict.";
          traits = [ "calm"; "self-sacrificing"; "idealistic" ];
          skill_ids = [ "field_mend"; "truce_window"; "resolve_hymn" ];
          prompt = "Reduce bloodshed and stabilize group cohesion whenever possible.";
        };
      ];
    skills =
      [
        {
          id = "frontline_shield";
          name = "Frontline Shield";
          category = "defense";
          description = "Absorb incoming threat targeting nearby allies.";
          usage_hint = Some "Use during direct confrontation to prevent party collapse.";
        };
        {
          id = "favor_broker";
          name = "Favor Broker";
          category = "social";
          description = "Trade concessions for delayed obligations.";
          usage_hint = Some "Useful before scarce-resource negotiations.";
        };
        {
          id = "supply_scan";
          name = "Supply Scan";
          category = "resource";
          description = "Estimate resource burn and shortage horizon.";
          usage_hint = Some "Run before committing to long missions.";
        };
        {
          id = "omen_trace";
          name = "Omen Trace";
          category = "arcane";
          description = "Infer likely next event from symbolic anomalies.";
          usage_hint = Some "Best in uncertain branching scenes.";
        };
        {
          id = "mark_prey";
          name = "Mark Prey";
          category = "combat";
          description = "Expose target weakness for coordinated strike.";
          usage_hint = Some "Combine with another actor's attack action.";
        };
        {
          id = "field_mend";
          name = "Field Mend";
          category = "support";
          description = "Emergency stabilization to prevent actor knockout.";
          usage_hint = Some "Use when hp trend is negative for two turns.";
        };
      ];
  }

let find_dm_preset catalog ~id =
  List.find_opt (fun (p : dm_preset) -> p.id = id) catalog.dm_presets

let find_world_preset catalog ~id =
  List.find_opt (fun (p : world_preset) -> p.id = id) catalog.world_presets

let find_skill catalog ~id =
  List.find_opt (fun (s : skill) -> s.id = id) catalog.skills

let load_json_list path parse fallback =
  if Sys.file_exists path then
    try
      let json = Yojson.Safe.from_file path in
      let items = json |> to_list |> List.map parse in
      Ok items
    with exn -> Error (Printf.sprintf "failed to parse %s: %s" path (Printexc.to_string exn))
  else Ok fallback

let config_path base_dir rel = Filename.concat base_dir rel

let load_catalog ~base_dir =
  let dm_path = config_path base_dir "config/trpg/presets/dm.json" in
  let world_path = config_path base_dir "config/trpg/presets/world.json" in
  let character_path = config_path base_dir "config/trpg/presets/character.json" in
  let skill_path = config_path base_dir "config/trpg/skills/agent_skills.json" in
  let* dm_presets =
    load_json_list dm_path parse_dm_preset default_catalog.dm_presets
  in
  let* world_presets =
    load_json_list world_path parse_world_preset default_catalog.world_presets
  in
  let* character_presets =
    load_json_list character_path parse_character_preset default_catalog.character_presets
  in
  let* skills = load_json_list skill_path parse_skill default_catalog.skills in
  Ok { dm_presets; world_presets; character_presets; skills }
