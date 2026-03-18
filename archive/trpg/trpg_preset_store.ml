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

type end_rules = {
  max_turn : int;
  defeat_if_all_players_dead : bool;
  victory_flags : string list;
  defeat_flags : string list;
  draw_flags : string list;
  allow_dm_end_signal : bool;
}

type world_preset = {
  id : string;
  title : string;
  description : string;
  intro : string;
  initial_flags : string list;
  end_rules : end_rules;
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
  let value =
    match json with
    | `Assoc xs -> Option.value ~default:`Null (List.assoc_opt key xs)
    | _ -> `Null
  in
  (match value with `List xs -> xs | _ -> [])
  |> List.filter_map
       (function `String s when String.trim s <> "" -> Some s | _ -> None)

let assoc_member json key =
  match json with
  | `Assoc xs -> Option.value ~default:`Null (List.assoc_opt key xs)
  | _ -> `Null

let default_end_rules : end_rules =
  {
    max_turn = 40;
    defeat_if_all_players_dead = true;
    victory_flags = [ "outcome.victory"; "quest.main.completed"; "ending.victory" ];
    defeat_flags = [ "outcome.defeat"; "party.wiped"; "ending.defeat" ];
    draw_flags = [ "outcome.draw"; "ending.draw" ];
    allow_dm_end_signal = true;
  }

let positive_or_default value default =
  if value <= 0 then default else value

let parse_end_rules json : end_rules =
  let src = assoc_member json "end_rules" in
  let int_field key default =
    assoc_member src key |> to_int_option |> Option.value ~default
  in
  let bool_field key default =
    assoc_member src key |> to_bool_option |> Option.value ~default
  in
  let list_field key default =
    let xs = string_list_of_member src key in
    if xs = [] then default else xs
  in
  {
    max_turn =
      int_field "max_turn" default_end_rules.max_turn
      |> positive_or_default default_end_rules.max_turn;
    defeat_if_all_players_dead =
      bool_field
        "defeat_if_all_players_dead"
        default_end_rules.defeat_if_all_players_dead;
    victory_flags =
      list_field "victory_flags" default_end_rules.victory_flags;
    defeat_flags =
      list_field "defeat_flags" default_end_rules.defeat_flags;
    draw_flags =
      list_field "draw_flags" default_end_rules.draw_flags;
    allow_dm_end_signal =
      bool_field "allow_dm_end_signal" default_end_rules.allow_dm_end_signal;
  }

let parse_scenario_end_rules json : end_rules =
  let parsed = parse_end_rules json in
  let explicit_max_turn =
    assoc_member (assoc_member json "end_rules") "max_turn"
    |> to_int_option
  in
  match explicit_max_turn with
  | Some n when n > 0 -> parsed
  | _ ->
      (match
         assoc_member (assoc_member json "runtime") "max_rounds"
         |> to_int_option
       with
      | Some n when n > 0 -> { parsed with max_turn = n }
      | _ -> parsed)

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
    end_rules = parse_end_rules json;
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

let end_rules_to_yojson (rules : end_rules) : Yojson.Safe.t =
  `Assoc
    [
      ("max_turn", `Int rules.max_turn);
      ("defeat_if_all_players_dead", `Bool rules.defeat_if_all_players_dead);
      ("victory_flags", `List (List.map (fun s -> `String s) rules.victory_flags));
      ("defeat_flags", `List (List.map (fun s -> `String s) rules.defeat_flags));
      ("draw_flags", `List (List.map (fun s -> `String s) rules.draw_flags));
      ("allow_dm_end_signal", `Bool rules.allow_dm_end_signal);
    ]

let world_preset_to_yojson (p : world_preset) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String p.id);
      ("title", `String p.title);
      ("description", `String p.description);
      ("intro", `String p.intro);
      ("initial_flags", `List (List.map (fun s -> `String s) p.initial_flags));
      ("end_rules", end_rules_to_yojson p.end_rules);
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
          end_rules = default_end_rules;
        };
        {
          id = "emberfall-siege";
          title = "Emberfall Siege";
          description = "Fortress-city under siege with internal factions and limited time.";
          intro =
            "Day 47 of the siege. Food reserves are measured in days, not weeks.";
          initial_flags = [ "siege.active"; "morale.volatile" ];
          end_rules = default_end_rules;
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
          description = "Brace the front and absorb incoming threats aimed at nearby allies.";
          usage_hint = Some "Use before enemy burst turns; pairs with STR(Athletics)-style guard checks.";
        };
        {
          id = "oath_intercept";
          name = "Oath Intercept";
          category = "defense";
          description = "Step into a marked ally's danger lane and intercept the blow.";
          usage_hint = Some "Treat as reaction timing; best right after a high-threat target is identified.";
        };
        {
          id = "morale_anchor";
          name = "Morale Anchor";
          category = "support";
          description = "Stabilize shaken allies and recover formation discipline.";
          usage_hint = Some "Strong after consecutive failures; aligns with CHA(Persuasion/Performance) play.";
        };
        {
          id = "deception_feint";
          name = "Deception Feint";
          category = "social";
          description = "Fake intent to misread enemy priorities and open a tactical gap.";
          usage_hint = Some "Run before flanks or disengage; maps cleanly to CHA(Deception).";
        };
        {
          id = "favor_broker";
          name = "Favor Broker";
          category = "social";
          description = "Trade obligations and leverage to gain cooperation or intel.";
          usage_hint = Some "Use in negotiation scenes with CHA(Persuasion) + WIS(Insight) framing.";
        };
        {
          id = "shadow_entry";
          name = "Shadow Entry";
          category = "stealth";
          description = "Slip through low-visibility routes with minimal exposure.";
          usage_hint = Some "Use for infiltration/opening position; core check is DEX(Stealth).";
        };
        {
          id = "supply_scan";
          name = "Supply Scan";
          category = "resource";
          description = "Forecast burn rate and detect upcoming supply bottlenecks.";
          usage_hint = Some "Run before committing to long routes; resembles INT(Investigation).";
        };
        {
          id = "ration_shift";
          name = "Ration Shift";
          category = "resource";
          description = "Rebalance rations and loads to extend operational endurance.";
          usage_hint = Some "Use when attrition rises; often resolves through WIS(Survival).";
        };
        {
          id = "logistics_patch";
          name = "Logistics Patch";
          category = "resource";
          description = "Apply temporary fixes to disrupted supply chains.";
          usage_hint = Some "Best when events stack penalties; combine INT(Investigation) + WIS(Survival).";
        };
        {
          id = "omen_trace";
          name = "Omen Trace";
          category = "arcane";
          description = "Read symbolic anomalies to anticipate near-future threats.";
          usage_hint = Some "Use before branching decisions; align with INT(Arcana/Religion).";
        };
        {
          id = "arc_flash";
          name = "Arc Flash";
          category = "arcane";
          description = "Release a focused burst of arcane force to disrupt enemy lines.";
          usage_hint = Some "Good as tempo swing; treat as spell attack with Arcana support.";
        };
        {
          id = "ward_bloom";
          name = "Ward Bloom";
          category = "arcane";
          description = "Expand a protective ward that reduces incoming area pressure.";
          usage_hint = Some "Cast before expected AoE windows; supports defensive Abjuration tempo.";
        };
        {
          id = "mark_prey";
          name = "Mark Prey";
          category = "combat";
          description = "Tag a target's weakness for coordinated party focus fire.";
          usage_hint = Some "Open with this on priority enemies; maps to WIS(Perception/Survival).";
        };
        {
          id = "silent_route";
          name = "Silent Route";
          category = "stealth";
          description = "Establish a low-noise approach lane for reposition or ambush.";
          usage_hint = Some "Use pre-engagement to avoid direct trade; DEX(Stealth) focused.";
        };
        {
          id = "finisher_strike";
          name = "Finisher Strike";
          category = "combat";
          description = "Execute weakened enemies with high-conversion closing pressure.";
          usage_hint = Some "Use after ally setup damage; resolves through attack roll timing.";
        };
        {
          id = "field_mend";
          name = "Field Mend";
          category = "support";
          description = "Perform emergency stabilization to prevent ally collapse.";
          usage_hint = Some "Prioritize threatened allies; direct fit for WIS(Medicine).";
        };
        {
          id = "truce_window";
          name = "Truce Window";
          category = "support";
          description = "Open a brief ceasefire window for negotiation or reset.";
          usage_hint = Some "Use when fight EV is poor; CHA(Persuasion) + WIS(Insight) works well.";
        };
        {
          id = "resolve_hymn";
          name = "Resolve Hymn";
          category = "support";
          description = "Reinforce party will and recover momentum under pressure.";
          usage_hint = Some "Great after morale shocks; pairs with CHA(Performance/Persuasion).";
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
      let json = Safe_ops.read_json_eio path in
      let items = json |> to_list |> List.map parse in
      Ok items
    with exn -> Error (Printf.sprintf "failed to parse %s: %s" path (Printexc.to_string exn))
  else Ok fallback

let config_path base_dir rel = Filename.concat base_dir rel

let non_empty_string json key =
  json |> member key |> to_string_option
  |> Option.map String.trim
  |> fun v -> Option.bind v (fun s -> if s = "" then None else Some s)

let first_non_empty_string json keys =
  List.find_map (fun key -> non_empty_string json key) keys

let parse_scenario_world_preset json : world_preset option =
  let id = non_empty_string json "id" in
  match id with
  | None -> None
  | Some id ->
      let title = first_non_empty_string json [ "title"; "name"; "id" ] in
      let description = non_empty_string json "description" in
      let intro =
        match json |> member "acts" with
        | `List (`Assoc _ as first_act :: _) ->
            first_non_empty_string first_act
              [ "intro"; "summary"; "description"; "title" ]
        | _ -> None
      in
      let type_flag =
        non_empty_string json "type"
        |> Option.map (fun t -> "scenario.type." ^ t)
      in
      let weather_flag =
        match json |> member "weather" with
        | `Assoc _ as weather ->
            non_empty_string weather "initial"
            |> Option.map (fun s -> "scenario.weather." ^ s)
        | _ -> None
      in
      let initial_flags =
        [ Some "scenario.source.examples-trpg-mvp"; type_flag; weather_flag ]
        |> List.filter_map (fun x -> x)
      in
      let title = Option.value ~default:id title in
      let description =
        Option.value
          ~default:
            (Printf.sprintf
               "Imported scenario %s from examples/trpg-mvp."
               id)
          description
      in
      let intro = Option.value ~default:description intro in
      Some
        {
          id;
          title;
          description;
          intro;
          initial_flags;
          end_rules = parse_scenario_end_rules json;
        }

let load_scenario_world_presets ~base_dir : world_preset list =
  let scenarios_dir = config_path base_dir "examples/trpg-mvp/scenarios" in
  if Sys.file_exists scenarios_dir && Sys.is_directory scenarios_dir then
    (try
       Sys.readdir scenarios_dir
       |> Array.to_list
       |> List.filter (fun name ->
            Filename.check_suffix (String.lowercase_ascii name) ".json")
       |> List.sort String.compare
       |> List.filter_map (fun file_name ->
            let path = Filename.concat scenarios_dir file_name in
            try
              Safe_ops.read_json_eio path |> parse_scenario_world_preset
            with exn ->
              Log.Trpg.warn "trpg_preset_store: scenario preset parse failed for %s: %s" path (Printexc.to_string exn);
              None)
     with exn ->
       Log.Trpg.error "failed to load scenario presets from %s: %s"
         scenarios_dir (Printexc.to_string exn);
       [])
  else
    []

let merge_world_presets ~(base : world_preset list) ~(extras : world_preset list) :
    world_preset list =
  let existing = Hashtbl.create 32 in
  List.iter (fun (p : world_preset) -> Hashtbl.replace existing p.id ()) base;
  let extras_filtered =
    extras
    |> List.filter (fun (p : world_preset) -> not (Hashtbl.mem existing p.id))
  in
  base @ extras_filtered

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
  let world_presets =
    merge_world_presets
      ~base:world_presets
      ~extras:(load_scenario_world_presets ~base_dir)
  in
  let* character_presets =
    load_json_list character_path parse_character_preset default_catalog.character_presets
  in
  let* skills = load_json_list skill_path parse_skill default_catalog.skills in
  Ok { dm_presets; world_presets; character_presets; skills }
