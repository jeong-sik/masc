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

val default_catalog : catalog

val load_catalog : base_dir:string -> (catalog, string) result

val find_dm_preset : catalog -> id:string -> dm_preset option
val find_world_preset : catalog -> id:string -> world_preset option
val find_skill : catalog -> id:string -> skill option

val dm_preset_to_yojson : dm_preset -> Yojson.Safe.t
val end_rules_to_yojson : end_rules -> Yojson.Safe.t
val world_preset_to_yojson : world_preset -> Yojson.Safe.t
val character_preset_to_yojson : character_preset -> Yojson.Safe.t
val skill_to_yojson : skill -> Yojson.Safe.t
