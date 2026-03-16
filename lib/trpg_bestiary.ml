(** Trpg_bestiary — NPC templates, difficulty tiers, combat resolution,
    memory signals, and round-level combat event helpers.

    Extracted from trpg_action.ml to reduce file size. *)

open Trpg_action

(* --- NPC Bestiary -------------------------------------------------------- *)

type npc_template = {
  npc_name : string;
  archetype : string;
  persona : string;
  traits : string list;
  skills : string list;
  base_hp : int;
  damage_min : int;
  damage_max : int;
  attack_narrations : string list;
}

let npc_bestiary : npc_template array =
  [|
    (* -- Skirmishers: low-mid HP, fast, flanking damage -- *)
    {
      npc_name = "Hollow Stalker";
      archetype = "predator-skirmisher";
      persona = "A relentless shadow prowling the frontline.";
      traits = [ "aggressive"; "opportunistic" ];
      skills = [ "shadow_claw"; "lunge" ];
      base_hp = 12;
      damage_min = 2;
      damage_max = 5;
      attack_narrations =
        [
          "그림자 발톱이 허공을 갈랐다.";
          "어둠 속에서 빠르게 돌진하며 할퀸다.";
          "소리 없이 측면에서 습격한다.";
        ];
    };
    {
      npc_name = "Flickering Imp";
      archetype = "trickster-skirmisher";
      persona = "A small fiend that darts unpredictably.";
      traits = [ "evasive"; "annoying" ];
      skills = [ "fire_spit"; "blink" ];
      base_hp = 8;
      damage_min = 1;
      damage_max = 4;
      attack_narrations =
        [
          "작은 화염 구슬이 날아온다.";
          "깜빡이며 사라졌다가 뒤에서 나타난다.";
          "킬킬대며 독침을 던진다.";
        ];
    };
    {
      npc_name = "Thornback Scurrier";
      archetype = "beast-skirmisher";
      persona = "A spiny rodent that charges in packs.";
      traits = [ "swarming"; "quick" ];
      skills = [ "spine_throw"; "burrow" ];
      base_hp = 10;
      damage_min = 2;
      damage_max = 4;
      attack_narrations =
        [
          "가시 달린 등을 세우며 돌진한다.";
          "땅속에서 불쑥 튀어나온다.";
          "날카로운 이빨로 물어뜯는다.";
        ];
    };
    (* -- Brutes: high HP, slow, heavy single-target damage -- *)
    {
      npc_name = "Ironhide Ogre";
      archetype = "warrior-brute";
      persona = "A towering mass of muscle and crude armor.";
      traits = [ "relentless"; "slow" ];
      skills = [ "heavy_swing"; "ground_pound" ];
      base_hp = 30;
      damage_min = 4;
      damage_max = 8;
      attack_narrations =
        [
          "거대한 곤봉이 땅을 가른다.";
          "우렁찬 함성과 함께 내리친다.";
          "묵직한 주먹이 허공을 가른다.";
        ];
    };
    {
      npc_name = "Petrified Guardian";
      archetype = "defender-construct";
      persona = "A stone sentinel awakened from ancient slumber.";
      traits = [ "stoic"; "immovable" ];
      skills = [ "stone_slam"; "petrifying_gaze" ];
      base_hp = 35;
      damage_min = 3;
      damage_max = 7;
      attack_narrations =
        [
          "돌 주먹이 천천히, 그러나 피할 수 없이 내려온다.";
          "석화의 눈빛이 스쳐 지나간다.";
          "균열이 간 팔로 후려친다.";
        ];
    };
    {
      npc_name = "Blighted Troll";
      archetype = "berserker-brute";
      persona = "A corrupted troll driven mad by dark spores.";
      traits = [ "regenerating"; "berserk" ];
      skills = [ "frenzy_claw"; "toxic_bite" ];
      base_hp = 28;
      damage_min = 3;
      damage_max = 7;
      attack_narrations =
        [
          "오염된 발톱이 맹렬하게 휘둘러진다.";
          "독이 묻은 이빨로 물어뜯는다.";
          "포효하며 주변을 난타한다.";
        ];
    };
    (* -- Casters: low HP, high area/debuff damage -- *)
    {
      npc_name = "Ashen Warlock";
      archetype = "arcane-caster";
      persona = "A hooded figure crackling with dark energy.";
      traits = [ "calculating"; "fragile" ];
      skills = [ "shadow_bolt"; "curse_of_ash" ];
      base_hp = 14;
      damage_min = 3;
      damage_max = 6;
      attack_narrations =
        [
          "검은 에너지가 손끝에서 폭발한다.";
          "재의 저주가 공기를 물들인다.";
          "어둠의 화살이 일직선으로 날아온다.";
        ];
    };
    {
      npc_name = "Fungal Shaman";
      archetype = "nature-caster";
      persona = "A mushroom-crowned druid spreading spores.";
      traits = [ "supportive"; "area_denial" ];
      skills = [ "spore_cloud"; "root_bind" ];
      base_hp = 16;
      damage_min = 2;
      damage_max = 5;
      attack_narrations =
        [
          "독 포자 구름이 퍼져 나간다.";
          "땅에서 뿌리가 솟아올라 발을 감싼다.";
          "균사체가 빠르게 번져 온다.";
        ];
    };
    {
      npc_name = "Storm Wisp";
      archetype = "elemental-caster";
      persona = "A crackling sphere of lightning.";
      traits = [ "erratic"; "chain_damage" ];
      skills = [ "chain_lightning"; "static_field" ];
      base_hp = 10;
      damage_min = 3;
      damage_max = 6;
      attack_narrations =
        [
          "번개가 연쇄적으로 튀어 나간다.";
          "정전기장이 몸을 마비시킨다.";
          "눈부신 섬광이 시야를 가린다.";
        ];
    };
    (* -- Elites: high HP, mixed offense, phase triggers -- *)
    {
      npc_name = "Dread Knight";
      archetype = "champion-elite";
      persona = "An undead commander radiating malice.";
      traits = [ "tactical"; "fearsome"; "phased" ];
      skills = [ "dark_cleave"; "war_cry"; "undying_will" ];
      base_hp = 40;
      damage_min = 4;
      damage_max = 8;
      attack_narrations =
        [
          "검은 대검이 넓은 호를 그린다.";
          "공포의 함성이 전장을 울린다.";
          "파멸의 기운이 무기에 깃든다.";
        ];
    };
    {
      npc_name = "Ancient Wyrm";
      archetype = "dragon-elite";
      persona = "A venerable dragon guarding forgotten treasure.";
      traits = [ "proud"; "devastating"; "phased" ];
      skills = [ "flame_breath"; "tail_sweep"; "dragon_fear" ];
      base_hp = 50;
      damage_min = 5;
      damage_max = 10;
      attack_narrations =
        [
          "불꽃 숨결이 대지를 태운다.";
          "거대한 꼬리가 전장을 휩쓴다.";
          "용의 위엄이 모든 것을 압도한다.";
        ];
    };
    {
      npc_name = "Abyssal Harbinger";
      archetype = "fiend-elite";
      persona = "A towering demon heralding destruction.";
      traits = [ "cruel"; "summoner"; "phased" ];
      skills = [ "hellfire_lance"; "summon_lesser"; "abyssal_roar" ];
      base_hp = 45;
      damage_min = 4;
      damage_max = 9;
      attack_narrations =
        [
          "지옥 불꽃 창이 허공을 가른다.";
          "하급 악마를 소환하며 웃는다.";
          "심연의 포효가 영혼을 흔든다.";
        ];
    };
  |]

(** Difficulty tier for NPC selection based on game progression. *)
type difficulty_tier = Early | Mid | Late

(** Tier pools: which bestiary indices are available at each game stage. *)
let early_pool = [| 0; 1; 2 |]
let mid_pool = [| 0; 1; 2; 3; 4; 5; 6; 7; 8 |]
let late_pool = [| 0; 1; 2; 3; 4; 5; 6; 7; 8; 9; 10; 11 |]

(** Determine difficulty tier from turn number. *)
let tier_of_turn turn =
  let t = if turn < 0 then -turn else turn in
  if t <= 5 then Early
  else if t <= 15 then Mid
  else Late

(** Select an NPC template deterministically based on turn number.
    Restricts the pool based on game progression:
    - Early (turns 1-5): skirmishers only (indices 0-2)
    - Mid (turns 6-15): +brutes, +casters (indices 0-8)
    - Late (turns 16+): all including elites (indices 0-11) *)
let select_npc_template ~turn =
  let abs_turn = if turn < 0 then -turn else turn in
  let pool =
    match tier_of_turn turn with
    | Early -> early_pool
    | Mid -> mid_pool
    | Late -> late_pool
  in
  let idx = abs_turn mod Array.length pool in
  npc_bestiary.(pool.(idx))

(** Select an NPC template with explicit tier override.
    Allows callers to force a specific difficulty tier regardless of turn. *)
let select_npc_template_with_tier ~turn ~tier =
  let abs_turn = if turn < 0 then -turn else turn in
  let pool =
    match tier with
    | Early -> early_pool
    | Mid -> mid_pool
    | Late -> late_pool
  in
  let idx = abs_turn mod Array.length pool in
  npc_bestiary.(pool.(idx))

(** Scale NPC HP based on game progression.
    Early (turn 1-5): base_hp,
    Mid (turn 6-15): base_hp * 1.5,
    Late (turn 16+): base_hp * 2.0 *)
let scale_hp ~turn ~base_hp =
  if turn <= 5 then base_hp
  else if turn <= 15 then base_hp + (base_hp / 2)
  else base_hp * 2

(** Archetype-aware deterministic damage.
    When ~damage_range is provided, uses that range instead of flat 2-4.
    Range is (min, max) inclusive. *)
let deterministic_damage ~turn ~actor_id ?(damage_range = (2, 4)) () =
  let actor_hash = Hashtbl.hash actor_id in
  let seed = abs (turn * 31 + actor_hash) in
  let min_d, max_d = damage_range in
  let range = max_d - min_d + 1 in
  min_d + (seed mod range)

let npc_attack_narration ~turn ~npc_template =
  let narrations = npc_template.attack_narrations in
  match narrations with
  | [] -> "적이 공격한다."
  | _ ->
      let index = abs turn mod List.length narrations in
      List.nth narrations index

let find_npc_template_by_name name =
  npc_bestiary |> Array.to_seq
  |> Seq.find (fun t -> t.npc_name = name)

(** Skill effect variants for NPC archetype abilities. *)
type skill_effect =
  | BonusDamage of int
  | DoubleDamage
  | MultiTarget
  | SelfHeal of int
  | NoSkill

(** Check if a string contains a given substring. *)
let string_contains ~haystack ~needle =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len > haystack_len then false
  else
    let found = ref false in
    let i = ref 0 in
    while !i <= haystack_len - needle_len && not !found do
      if String.sub haystack !i needle_len = needle then found := true;
      incr i
    done;
    !found

(** Resolve which skill effect an NPC triggers on a given turn.
    Deterministic: based on archetype category and turn number.
    - Skirmishers: "Quick Strike" on even turns (BonusDamage 1)
    - Brutes: "Crushing Blow" on turns divisible by 3 (DoubleDamage)
    - Casters: "Spell Surge" on turns divisible by 4 (MultiTarget)
    - Elites: "War Cry" on turn 1 (SelfHeal of 25% max HP) *)
let resolve_npc_skill ~turn ~npc_template =
  let arch = npc_template.archetype in
  if string_contains ~haystack:arch ~needle:"skirmisher" then
    if turn mod 2 = 0 then BonusDamage 1 else NoSkill
  else if
    string_contains ~haystack:arch ~needle:"brute"
    || string_contains ~haystack:arch ~needle:"construct"
  then if turn mod 3 = 0 then DoubleDamage else NoSkill
  else if string_contains ~haystack:arch ~needle:"caster" then
    if turn mod 4 = 0 then MultiTarget else NoSkill
  else if string_contains ~haystack:arch ~needle:"elite" then
    if turn = 1 then SelfHeal (npc_template.base_hp / 4) else NoSkill
  else NoSkill

(** Human-readable name for a skill effect. *)
let skill_effect_name = function
  | BonusDamage _ -> "Quick Strike"
  | DoubleDamage -> "Crushing Blow"
  | MultiTarget -> "Spell Surge"
  | SelfHeal _ -> "War Cry"
  | NoSkill -> ""

let append_combat_semantic_event ~store ~room_id ~phase ~turn ~actor_id ~reply
    ~state =
  let ( let* ) = Result.bind in
  match detect_combat_semantic reply with
  | None -> Ok []
  | Some Combat_attack_intent ->
      let target_id = choose_attack_target_id ~state ~actor_id in
      let damage = deterministic_damage ~turn ~actor_id () in
      let payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String actor_id);
            ("action", `String reply);
            ( "target_id",
              match target_id with Some target -> `String target | None -> `Null );
            ("skill", `Null);
            ("damage", match target_id with Some _ -> `Int damage | None -> `Null);
          ]
      in
      let* event =
        append_event ~store ~room_id
          ~event_type:Trpg_engine_event.Combat_attack ~actor_id ~payload ()
      in
      let* hp_event_opt =
        match target_id with
        | None -> Ok None
        | Some target_actor_id ->
            let hp_payload =
              `Assoc
                [
                  ("turn", `Int turn);
                  ("phase", `String phase);
                  ("actor_id", `String target_actor_id);
                  ("delta", `Int (-damage));
                  ("source_actor_id", `String actor_id);
                  ("reason", `String "combat.attack");
                ]
            in
            let* hp_event =
              append_event ~store ~room_id
                ~event_type:Trpg_engine_event.Hp_changed
                ~actor_id:target_actor_id ~payload:hp_payload ()
            in
            Ok (Some hp_event)
      in
      Ok
        (match hp_event_opt with
        | Some hp_event -> [ event; hp_event ]
        | None -> [ event ])
  | Some Combat_defense_intent ->
      let payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String actor_id);
            ("method", `String reply);
            ("source_actor_id", `Null);
            ("mitigated", `Null);
          ]
      in
      let* event =
        append_event ~store ~room_id
          ~event_type:Trpg_engine_event.Combat_defense ~actor_id ~payload ()
      in
      Ok [ event ]

let actor_hp_from_state state actor_id =
  match actor_json_of_state state actor_id with
  | Some actor_json ->
      actor_json |> Yojson.Safe.Util.member "hp" |> Yojson.Safe.Util.to_int_option
      |> Option.value ~default:0
  | None -> 0

let memory_floor_for_structured_action ~state ~(sa : structured_action) ~target_id
    ~damage_opt : memory_tier * string list =
  match sa.sa_type with
  | SetFlag ->
      let key =
        sa.flag_key |> Option.value ~default:"" |> String.trim
        |> String.lowercase_ascii
      in
      if starts_with key "outcome." || starts_with key "ending." then
        (Memory_long, [ "set_flag_outcome" ])
      else (Memory_mid, [ "set_flag" ])
  | SceneTransition -> (Memory_mid, [ "scene_transition" ])
  | QuestUpdate -> (Memory_mid, [ "quest_update" ])
  | Attack -> (
      match target_id, damage_opt with
      | Some target_actor_id, Some damage ->
          let hp_before = actor_hp_from_state state target_actor_id in
          if hp_before > 0 && hp_before - damage <= 0 then
            (Memory_long, [ "attack_lethal" ])
          else (Memory_short, [])
      | _ -> (Memory_short, []))
  | Defend | Heal | Investigate | Social | Explore | Magic | UseItem ->
      (Memory_short, [])

let default_importance_for_memory_tier = function
  | Memory_short -> 44
  | Memory_mid -> 62
  | Memory_long -> 82

let append_structured_action_memory_signal ~store ~room_id ~turn ~phase
    ~actor_id ~(sa : structured_action) ~floor_tier ~floor_reasons =
  let ( let* ) = Result.bind in
  let requested_tier, importance_score, hint_reason =
    match sa.memory_hint with
    | Some hint ->
        ( hint.requested_tier,
          hint.importance_score
          |> Option.map (clamp_int 0 100)
          |> Option.value ~default:(default_importance_for_memory_tier hint.requested_tier),
          hint.reason )
    | None ->
        ( floor_tier,
          default_importance_for_memory_tier floor_tier,
          None )
  in
  let effective_tier = max_memory_tier requested_tier floor_tier in
  let guardrail_applied =
    memory_tier_rank effective_tier > memory_tier_rank requested_tier
  in
  if sa.memory_hint = None && effective_tier = Memory_short then Ok None
  else
    let floor_reasons = dedupe_keep_order floor_reasons in
    let summary_seed =
      let compact = String.trim sa.description in
      if compact <> "" then compact
      else
        Printf.sprintf "%s action by %s"
          (string_of_action_type sa.sa_type)
          actor_id
    in
    let summary_en =
      Printf.sprintf
        "Structured action memory decision (%s): %s"
        (string_of_action_type sa.sa_type)
        summary_seed
    in
    let summary_ko =
      Printf.sprintf
        "구조화 액션 메모리 판정 (%s): %s"
        (string_of_action_type sa.sa_type)
        summary_seed
    in
    let* event =
      append_memory_signal_event ~store ~room_id
        ~event_tier:(string_of_memory_tier effective_tier)
        ~importance_score
        ~summary_ko
        ~summary_en
        ~entity_refs:
          [
            ("source", `String "structured_action");
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String actor_id);
            ("action_type", `String (string_of_action_type sa.sa_type));
            ("requested_tier", `String (string_of_memory_tier requested_tier));
            ("floor_tier", `String (string_of_memory_tier floor_tier));
            ("effective_tier", `String (string_of_memory_tier effective_tier));
            ("guardrail_applied", `Bool guardrail_applied);
            ( "floor_reasons",
              `List (List.map (fun reason -> `String reason) floor_reasons) );
            ( "hint_reason",
              match hint_reason with Some reason -> `String reason | None -> `Null );
          ]
    in
    Ok (Some event)

let apply_structured_action ~store ~room_id ~turn ~phase ~actor_id ~state
    (sa : structured_action) =
  let ( let* ) = Result.bind in
  let finalize ~events ~target_id ~damage_opt =
    let floor_tier, floor_reasons =
      memory_floor_for_structured_action ~state ~sa ~target_id ~damage_opt
    in
    let* memory_event_opt =
      append_structured_action_memory_signal ~store ~room_id ~turn ~phase
        ~actor_id ~sa ~floor_tier ~floor_reasons
    in
    Ok
      (match memory_event_opt with
      | Some memory_event -> events @ [ memory_event ]
      | None -> events)
  in
  match sa.sa_type with
  | Attack ->
      let target_id = choose_attack_target_id ~state ~actor_id in
      let damage = deterministic_damage ~turn ~actor_id () in
      let payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String actor_id);
            ("action", `String sa.description);
            ( "target_id",
              match target_id with Some t -> `String t | None -> `Null );
            ("skill", `Null);
            ( "damage",
              match target_id with Some _ -> `Int damage | None -> `Null );
          ]
      in
      let* combat_event =
        append_event ~store ~room_id
          ~event_type:Trpg_engine_event.Combat_attack ~actor_id ~payload ()
      in
      let* hp_event_opt =
        match target_id with
        | None -> Ok None
        | Some target_actor_id ->
            let hp_payload =
              `Assoc
                [
                  ("turn", `Int turn);
                  ("phase", `String phase);
                  ("actor_id", `String target_actor_id);
                  ("delta", `Int (-damage));
                  ("source_actor_id", `String actor_id);
                  ("reason", `String "combat.attack");
                ]
            in
            let* hp_event =
              append_event ~store ~room_id
                ~event_type:Trpg_engine_event.Hp_changed
                ~actor_id:target_actor_id ~payload:hp_payload ()
            in
            Ok (Some hp_event)
      in
      let events =
        match hp_event_opt with
        | Some hp_event -> [ combat_event; hp_event ]
        | None -> [ combat_event ]
      in
      finalize ~events ~target_id ~damage_opt:(Some damage)
  | Defend ->
      let payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String actor_id);
            ("method", `String sa.description);
            ("source_actor_id", `Null);
            ("mitigated", `Null);
          ]
      in
      let* event =
        append_event ~store ~room_id
          ~event_type:Trpg_engine_event.Combat_defense ~actor_id ~payload ()
      in
      finalize ~events:[ event ] ~target_id:None ~damage_opt:None
  | SetFlag ->
      let key = match sa.flag_key with Some k -> k | None -> "" in
      if key = "" then Ok []
      else
        let payload =
          `Assoc
            [
              ("turn", `Int turn);
              ("phase", `String phase);
              ("key", `String key);
              ("value", `String "true");
              ("description", `String sa.description);
            ]
        in
        let* event =
          append_event ~store ~room_id
            ~event_type:Trpg_engine_event.Flag_set ~actor_id ~payload ()
        in
        finalize ~events:[ event ] ~target_id:None ~damage_opt:None
  | SceneTransition ->
      let scene =
        match sa.scene with Some s -> s | None -> sa.description
      in
      let payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("scene", `String scene);
            ("description", `String sa.description);
          ]
      in
      let* event =
        append_event ~store ~room_id
          ~event_type:Trpg_engine_event.Scene_transition ~actor_id ~payload ()
      in
      finalize ~events:[ event ] ~target_id:None ~damage_opt:None
  | QuestUpdate ->
      let quest_info =
        match sa.quest_info with Some q -> q | None -> sa.description
      in
      let payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("quest", `String quest_info);
            ("description", `String sa.description);
          ]
      in
      let* event =
        append_event ~store ~room_id
          ~event_type:Trpg_engine_event.Quest_update ~actor_id ~payload ()
      in
      finalize ~events:[ event ] ~target_id:None ~damage_opt:None
  | Heal | Investigate | Social | Explore | Magic | UseItem ->
      let type_label = string_of_action_type sa.sa_type in
      let payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String actor_id);
            ("action_type", `String type_label);
            ( "target_id",
              match sa.target_id with Some t -> `String t | None -> `Null );
            ("narration", `String sa.description);
          ]
      in
      let* event =
        append_event ~store ~room_id
          ~event_type:Trpg_engine_event.Narration_posted ~actor_id ~payload ()
      in
      finalize ~events:[ event ] ~target_id:sa.target_id ~damage_opt:None

let ensure_round_npc_spawn_event ~store ~room_id ~turn ~state =
  let has_live_npc =
    party_fields_of_state state
    |> List.exists (fun (_, actor_json) ->
           is_actor_alive actor_json && role_from_actor_json actor_json = "npc")
  in
  if has_live_npc then Ok None
  else
    let existing = party_fields_of_state state in
    let rec pick_id idx =
      let candidate = Printf.sprintf "npc-t%d-%02d" turn idx in
      if List.mem_assoc candidate existing then pick_id (idx + 1) else candidate
    in
    let npc_id = pick_id 1 in
    let tmpl = select_npc_template ~turn in
    let hp = scale_hp ~turn ~base_hp:tmpl.base_hp in
    let payload =
      `Assoc
        [
          ("turn", `Int turn);
          ("phase", `String "round");
          ("actor_id", `String npc_id);
          ( "actor",
            `Assoc
              [
                ("name", `String tmpl.npc_name);
                ("role", `String "npc");
                ("archetype", `String tmpl.archetype);
                ("persona", `String tmpl.persona);
                ( "traits",
                  `List (List.map (fun t -> `String t) tmpl.traits) );
                ( "skills",
                  `List (List.map (fun s -> `String s) tmpl.skills) );
                ("hp", `Int hp);
                ("max_hp", `Int hp);
                ("alive", `Bool true);
                ("inventory", `List []);
              ] );
        ]
    in
    let ( let* ) = Result.bind in
    let* event =
      append_event ~store ~room_id
        ~event_type:Trpg_engine_event.Actor_spawned
        ~actor_id:npc_id ~payload ()
    in
    Ok (Some event)
