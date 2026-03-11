(** Trpg_action — structured action parsing/validation, combat
    semantics, NPC bestiary, and round-level combat event helpers. *)

include Trpg_types
open Yojson.Safe.Util

let action_type_of_string = function
  | "attack" -> Some Attack
  | "defend" | "defense" -> Some Defend
  | "heal" -> Some Heal
  | "investigate" -> Some Investigate
  | "social" | "talk" | "persuade" -> Some Social
  | "explore" | "search" | "look" -> Some Explore
  | "magic" | "spell" | "cast" -> Some Magic
  | "use_item" | "item" -> Some UseItem
  | "set_flag" | "flag" -> Some SetFlag
  | "scene_transition" | "scene" | "move" -> Some SceneTransition
  | "quest_update" | "quest" -> Some QuestUpdate
  | _ -> None

let string_of_action_type = function
  | Attack -> "attack"
  | Defend -> "defend"
  | Heal -> "heal"
  | Investigate -> "investigate"
  | Social -> "social"
  | Explore -> "explore"
  | Magic -> "magic"
  | UseItem -> "use_item"
  | SetFlag -> "set_flag"
  | SceneTransition -> "scene_transition"
  | QuestUpdate -> "quest_update"

let memory_tier_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "short" -> Some Memory_short
  | "mid" | "medium" -> Some Memory_mid
  | "long" -> Some Memory_long
  | _ -> None

let string_of_memory_tier = function
  | Memory_short -> "short"
  | Memory_mid -> "mid"
  | Memory_long -> "long"

let memory_tier_rank = function
  | Memory_short -> 1
  | Memory_mid -> 2
  | Memory_long -> 3

let max_memory_tier a b =
  if memory_tier_rank a >= memory_tier_rank b then a else b

let parse_structured_memory_hint (sa_json : Yojson.Safe.t) :
    structured_memory_hint option =
  match sa_json |> member "memory_hint" with
  | `Assoc _ as hint_json ->
      let tier_opt =
        match hint_json |> member "tier" with
        | `String raw -> memory_tier_of_string raw
        | _ -> None
      in
      tier_opt
      |> Option.map (fun requested_tier ->
             let importance_score =
               match hint_json |> member "importance_score" with
               | `Int n -> Some (clamp_int 0 100 n)
               | `Float n -> Some (clamp_int 0 100 (int_of_float n))
               | _ -> None
             in
             let reason =
               match hint_json |> member "reason" with
               | `String raw ->
                   let value = String.trim raw in
                   if value = "" then None else Some value
               | _ -> None
             in
             { requested_tier; importance_score; reason })
  | _ -> None

let extract_structured_action_json_from_reply_line line :
    (Yojson.Safe.t option, string) Stdlib.result =
  let trimmed = String.trim line in
  if trimmed = "" then Ok None
  else
    let lowered = String.lowercase_ascii trimmed in
    let prefix = "structured_action:" in
    if not (starts_with lowered prefix) then Ok None
    else
      let payload =
        String.sub trimmed (String.length prefix)
          (String.length trimmed - String.length prefix)
        |> String.trim
      in
      if payload = "" then Error "structured_action payload is empty"
      else
        match Yojson.Safe.from_string payload with
        | `Assoc fields when fields <> [] -> Ok (Some (`Assoc fields))
        | `Assoc _ -> Error "structured_action object is empty"
        | _ -> Error "structured_action payload must be JSON object"
        | exception Yojson.Json_error e ->
            Error (Printf.sprintf "invalid structured_action json: %s" e)

let extract_first_json_object_fragment (text : string) ~(from_idx : int) :
    string option =
  let len = String.length text in
  let rec find_open i =
    if i >= len then None
    else if text.[i] = '{' then Some i
    else find_open (i + 1)
  in
  match find_open (max 0 from_idx) with
  | None -> None
  | Some open_idx ->
      let rec scan i depth in_string escaped =
        if i >= len then None
        else
          let ch = text.[i] in
          if in_string then
            if escaped then scan (i + 1) depth true false
            else if ch = '\\' then scan (i + 1) depth true true
            else if ch = '"' then scan (i + 1) depth false false
            else scan (i + 1) depth true false
          else if ch = '"' then scan (i + 1) depth true false
          else if ch = '{' then scan (i + 1) (depth + 1) false false
          else if ch = '}' then
            if depth = 1 then Some (String.sub text open_idx (i - open_idx + 1))
            else scan (i + 1) (depth - 1) false false
          else scan (i + 1) depth false false
      in
      scan (open_idx + 1) 1 false false

let extract_structured_action_json_inline (reply : string) :
    Yojson.Safe.t option =
  let key = "structured_action" in
  let key_len = String.length key in
  let lowered = String.lowercase_ascii reply in
  let len = String.length lowered in
  let rec loop from_idx =
    if from_idx >= len then None
    else
      let slice = String.sub lowered from_idx (len - from_idx) in
      match find_substring slice key with
      | None -> None
      | Some rel_idx ->
          let key_idx = from_idx + rel_idx in
          let search_idx = key_idx + key_len in
          let candidate =
            extract_first_json_object_fragment reply ~from_idx:search_idx
          in
          (match candidate with
          | None -> loop search_idx
          | Some raw_json -> (
              match Yojson.Safe.from_string raw_json with
              | `Assoc fields when fields <> [] -> Some (`Assoc fields)
              | _ -> loop search_idx
              | exception Yojson.Json_error _ -> loop search_idx))
  in
  loop 0

let extract_structured_action_json_from_whole_reply (reply : string) :
    Yojson.Safe.t option =
  let strip_code_fence text =
    let trimmed = String.trim text in
    if not (starts_with trimmed "```") then trimmed
    else
      let lines = String.split_on_char '\n' trimmed in
      let lines =
        match lines with
        | [] -> []
        | _first :: tl -> tl
      in
      let lines =
        match List.rev lines with
        | last :: tl when starts_with (String.trim last) "```" -> List.rev tl
        | _ -> lines
      in
      String.concat "\n" lines |> String.trim
  in
  let try_extract text =
    match Yojson.Safe.from_string text with
    | `Assoc fields -> (
        match List.assoc_opt "structured_action" fields with
        | Some (`Assoc sa_fields) when sa_fields <> [] -> Some (`Assoc sa_fields)
        | _ -> None)
    | _ -> None
    | exception Yojson.Json_error _ -> None
  in
  let trimmed = String.trim reply in
  match try_extract trimmed with
  | Some json -> Some json
  | None ->
      let unfenced = strip_code_fence trimmed in
      if unfenced = trimmed then None else try_extract unfenced

let extract_structured_action_json_from_reply (reply : string) :
    (Yojson.Safe.t option, string) Stdlib.result =
  let rec loop = function
    | [] -> Ok None
    | line :: tl -> (
        match extract_structured_action_json_from_reply_line line with
        | Ok None -> loop tl
        | Ok (Some _ as found) -> Ok found
        | Error e -> Error e)
  in
  match loop (String.split_on_char '\n' reply) with
  | Ok None -> (
      match extract_structured_action_json_inline reply with
      | Some json -> Ok (Some json)
      | None -> (
          match extract_structured_action_json_from_whole_reply reply with
          | Some json -> Ok (Some json)
          | None -> Ok None))
  | other -> other

let extract_structured_action_json (keeper_json : Yojson.Safe.t) :
    (Yojson.Safe.t option, string) Stdlib.result =
  match keeper_json |> member "structured_action" with
  | `Assoc fields when fields <> [] -> Ok (Some (`Assoc fields))
  | `Assoc _ -> Error "structured_action object is empty"
  | `Null -> (
      match first_nonempty_string_field [ "reply"; "content"; "text"; "message" ] keeper_json with
      | Some reply -> extract_structured_action_json_from_reply reply
      | None -> Ok None)
  | _ -> Error "structured_action must be an object"

let extract_structured_action (keeper_json : Yojson.Safe.t) :
    structured_action option =
  match extract_structured_action_json keeper_json with
  | Error _ -> None
  | Ok None -> None
  | Ok (Some sa) ->
      let type_str =
        match sa |> member "type" with
        | `String s -> String.lowercase_ascii (String.trim s)
        | _ -> ""
      in
      (match action_type_of_string type_str with
      | None -> None
      | Some sa_type ->
          let get_string key =
            match sa |> member key with
            | `String s when String.trim s <> "" -> Some (String.trim s)
            | _ -> None
          in
          Some
            {
              sa_type;
              target_id = get_string "target_id";
              description =
                (match get_string "description" with Some d -> d | None -> "");
              flag_key = get_string "flag_key";
              scene = get_string "scene";
              quest_info = get_string "quest_info";
              memory_hint = parse_structured_memory_hint sa;
              raw_payload = sa;
            })

let is_player_action_type = function
  | Attack | Defend | Heal | Investigate | Social | Explore | Magic | UseItem ->
      true
  | SetFlag | SceneTransition | QuestUpdate -> false

let is_dm_action_type = function
  | SetFlag | SceneTransition | QuestUpdate -> true
  | Attack | Defend | Heal | Investigate | Social | Explore | Magic | UseItem ->
      false

type structured_action_validation_error =
  [ `Schema of string | `Rule of string ]

let normalize_structured_description_for_quality_gate (raw : string) : string =
  raw
  |> String.trim
  |> String.lowercase_ascii
  |> String.map (function
       | '.' | ',' | '!' | '?' | ':' | ';' | '"' | '\'' | '(' | ')' -> ' '
       | ch -> ch)
  |> String.split_on_char ' '
  |> List.filter (fun token -> token <> "")
  |> String.concat " "

let low_signal_structured_descriptions =
  [
    "현재 전황에 맞는 구체 행동";
    "전황에 맞는 구체 행동";
    "일행이 은신처를 발견했다";
    "검으로 고블린을 공격한다";
    "상황을 살피며 다음 행동을 준비합니다.";
    "다음 행동을 준비한다";
    "내 기록 기준으로는 직전에 이런 질문을 했어";
    "swing sword at the goblin";
    "the party discovered the hideout";
    "the party enters the cave";
    "assess the situation and prepare the next move.";
    "prepare the next move";
    "the previous prompt was";
  ]
  |> List.map normalize_structured_description_for_quality_gate

let low_signal_structured_fragments =
  [
    "현재 전황에 맞는 구체 행동";
    "전황에 맞는 구체 행동";
    "상황을 살피며 다음 행동을 준비";
    "다음 행동을 준비";
    "내 기록 기준으로는 직전에 이런 질문을 했어";
    "일행이 은신처를 발견";
    "검으로 고블린을 공격";
    "swing sword at the goblin";
    "the party discovered the hideout";
    "the party enters the cave";
    "assess the situation and prepare the next move";
    "prepare the next move";
    "the previous prompt was";
  ]
  |> List.map normalize_structured_description_for_quality_gate

let contains_low_signal_structured_fragment (text : string) : bool =
  let normalized = normalize_structured_description_for_quality_gate text in
  normalized <> ""
  && List.exists
       (fun fragment ->
         fragment <> "" && contains_substring normalized fragment)
       low_signal_structured_fragments

let is_low_signal_structured_description (text : string) : bool =
  let normalized = normalize_structured_description_for_quality_gate text in
  normalized <> "" && List.mem normalized low_signal_structured_descriptions

let validate_structured_action_for_role ~role (sa : structured_action) :
    (structured_action, structured_action_validation_error) Stdlib.result =
  let ( let* ) = Result.bind in
  let actor_role = role_to_string role in
  let action_name = string_of_action_type sa.sa_type in
  let require_nonempty name = function
    | Some v when String.trim v <> "" -> Ok (String.trim v)
    | _ -> Error (`Schema (Printf.sprintf "%s is required for %s" name action_name))
  in
  let* () =
    match role with
    | `Player ->
        if is_player_action_type sa.sa_type then Ok ()
        else
          Error
            (`Rule
               (Printf.sprintf
                  "action_type=%s is not allowed for role=%s"
                  action_name actor_role))
    | `Dm ->
        if is_dm_action_type sa.sa_type then Ok ()
        else
          Error
            (`Rule
               (Printf.sprintf
                  "action_type=%s is not allowed for role=%s"
                  action_name actor_role))
  in
  let* description =
    let text = String.trim sa.description in
    if text = "" then
      Error (`Schema "description is required for structured_action")
    else if
      is_low_signal_structured_description text
      || contains_low_signal_structured_fragment text
    then
      Error
        (`Rule
           "description is too generic; include concrete target/threat/intent")
    else Ok text
  in
  let* flag_key =
    match sa.sa_type with
    | SetFlag -> require_nonempty "flag_key" sa.flag_key |> Result.map (fun v -> Some v)
    | _ -> Ok sa.flag_key
  in
  let* scene =
    match sa.sa_type with
    | SceneTransition ->
        require_nonempty "scene" sa.scene |> Result.map (fun v -> Some v)
    | _ -> Ok sa.scene
  in
  let* quest_info =
    match sa.sa_type with
    | QuestUpdate ->
        require_nonempty "quest_info" sa.quest_info
        |> Result.map (fun v -> Some v)
    | _ -> Ok sa.quest_info
  in
  Ok { sa with description; flag_key; scene; quest_info }

let parse_and_validate_structured_action ~role (keeper_json : Yojson.Safe.t) :
    (structured_action, structured_action_validation_error) Stdlib.result =
  let ( let* ) = Result.bind in
  let* sa_json_opt =
    match extract_structured_action_json keeper_json with
    | Ok v -> Ok v
    | Error e -> Error (`Schema e)
  in
  let* sa =
    match sa_json_opt with
    | None -> Error (`Schema "structured_action is missing")
    | Some _ -> (
        match extract_structured_action keeper_json with
        | Some parsed -> Ok parsed
        | None ->
            Error (`Schema "structured_action type is unknown or malformed"))
  in
  validate_structured_action_for_role ~role sa

let string_of_structured_action_validation_error = function
  | `Schema msg -> msg
  | `Rule msg -> msg

let structured_action_error_kind = function
  | `Schema _ -> "schema"
  | `Rule _ -> "rule"

let structured_action_error_message = function
  | `Schema msg -> msg
  | `Rule msg -> msg

let detect_combat_semantic (text : string) : combat_semantic option =
  let lowered = String.lowercase_ascii text in
  let has_any keywords =
    List.exists (fun keyword -> contains_substring lowered keyword) keywords
  in
  if
    has_any
      [
        "attack";
        "strike";
        "slash";
        "stab";
        "shoot";
        "assault";
        "공격";
        "타격";
        "베기";
        "사격";
        "돌격";
      ]
  then Some Combat_attack_intent
  else if
    has_any
      [
        "defend";
        "defensive";
        "guard";
        "block";
        "parry";
        "shield";
        "dodge";
        "evade";
        "방어";
        "엄폐";
        "회피";
        "가드";
      ]
  then Some Combat_defense_intent
  else None

(* Server-side narrative inference: extract action type from LLM narrative
   when the explicit structured_action JSON format is missing.
   Ordered by specificity — more specific matches first to avoid
   "heal" matching before "attack" in "heals after the attack". *)
let infer_action_type_from_narrative ~(role : [ `Player | `Dm ])
    (text : string) : structured_action option =
  let lowered = String.lowercase_ascii text in
  let has_any keywords =
    List.exists (fun keyword -> contains_substring lowered keyword) keywords
  in
  let make_sa sa_type ?(flag_key : string option) ?(scene : string option)
      ?(quest_info : string option) desc =
    {
      sa_type;
      target_id = None;
      description = desc;
      flag_key;
      scene;
      quest_info;
      memory_hint = None;
      raw_payload =
        `Assoc
          [
            ("type", `String (string_of_action_type sa_type));
            ("description", `String desc);
            ("inferred", `Bool true);
          ];
    }
  in
  let truncate_desc s =
    let max_len = 120 in
    if String.length s <= max_len then s
    else String.sub s 0 max_len ^ "..."
  in
  let desc = truncate_desc (String.trim text) in
  match role with
  | `Player ->
      (* Ordered: specific first, generic last *)
      if has_any [ "cast"; "spell"; "magic"; "incantation"; "주문"; "마법"; "시전" ]
      then Some (make_sa Magic desc)
      else if
        has_any [ "heal"; "cure"; "bandage"; "potion"; "치료"; "회복"; "붕대"; "포션" ]
      then Some (make_sa Heal desc)
      else if
        has_any
          [
            "examine"; "inspect"; "investigate"; "search"; "look for"; "조사";
            "살펴"; "탐색"; "확인";
          ]
      then Some (make_sa Investigate desc)
      else if
        has_any
          [
            "talk"; "persuade"; "negotiate"; "diplomacy"; "convince"; "대화";
            "설득"; "협상"; "말을 건";
          ]
      then Some (make_sa Social desc)
      else if
        has_any
          [ "use"; "drink"; "equip"; "consume"; "activate"; "사용"; "마시"; "장착" ]
      then Some (make_sa UseItem desc)
      else if
        has_any [ "explore"; "wander"; "travel"; "move to"; "탐험"; "이동"; "걸어" ]
      then Some (make_sa Explore desc)
      else if
        has_any
          [
            "attack"; "strike"; "slash"; "stab"; "shoot"; "hit"; "swing";
            "공격"; "타격"; "베기"; "사격"; "돌격"; "찌르";
          ]
      then Some (make_sa Attack desc)
      else if
        has_any
          [
            "defend"; "block"; "parry"; "shield"; "dodge"; "evade"; "방어";
            "막기"; "회피"; "가드";
          ]
      then Some (make_sa Defend desc)
      else if desc <> "" then
        (* Keep round progression when keeper narration is skill-name-heavy
           but still semantically actionable. *)
        Some (make_sa Attack desc)
      else None
  | `Dm ->
      if
        has_any
          [
            "discover"; "found"; "reveal"; "unlock"; "milestone"; "발견";
            "드러나"; "밝혀"; "획득";
          ]
      then Some (make_sa SetFlag ~flag_key:"story.inferred" desc)
      else if
        has_any
          [
            "enter"; "arrive"; "move to"; "travel to"; "new area"; "들어서";
            "도착"; "이동하"; "새로운 장소"; "방으로";
          ]
      then Some (make_sa SceneTransition ~scene:desc desc)
      else if
        has_any
          [
            "quest"; "mission"; "objective"; "task"; "의뢰"; "임무"; "퀘스트";
            "목표";
          ]
      then Some (make_sa QuestUpdate ~quest_info:desc desc)
      else if desc <> "" then
        Some (make_sa SetFlag ~flag_key:"story.inferred" desc)
      else None

let role_from_actor_json actor_json =
  match actor_json |> member "role" with
  | `String s ->
      let normalized = String.lowercase_ascii (String.trim s) in
      if normalized = "" then "player" else normalized
  | _ -> "player"

let is_actor_alive actor_json =
  match actor_json |> member "alive" with
  | `Bool b -> b
  | _ -> (
      match actor_json |> member "hp" with
      | `Int hp -> hp > 0
      | _ -> true)

let party_fields_of_state state =
  match state |> member "party" with
  | `Assoc fields -> fields
  | _ -> []

let actor_json_of_state state actor_id =
  party_fields_of_state state |> List.assoc_opt actor_id

let choose_attack_target_id ~state ~actor_id =
  let attacker_role =
    match actor_json_of_state state actor_id with
    | Some actor_json -> role_from_actor_json actor_json
    | None -> "player"
  in
  let turn =
    match state |> member "turn" with
    | `Int n when n > 0 -> n
    | _ -> 1
  in
  let live_actors =
    party_fields_of_state state
    |> List.filter (fun (aid, actor_json) ->
           aid <> actor_id && is_actor_alive actor_json)
  in
  let choose_from_candidates salt candidates =
    match candidates with
    | [] -> None
    | _ ->
        let len = List.length candidates in
        let seed = Hashtbl.hash (actor_id ^ ":" ^ salt) in
        let offset = (if seed < 0 then -seed else seed) mod len in
        let idx = ((turn - 1) + offset) mod len in
        Some (fst (List.nth candidates idx))
  in
  let pick pred salt =
    let candidates =
      live_actors
      |> List.filter (fun (_, actor_json) -> pred (role_from_actor_json actor_json))
    in
    choose_from_candidates salt candidates
  in
  if attacker_role = "npc" then
    match pick (fun role -> role <> "npc" && role <> "dm") "npc-primary" with
    | Some actor -> Some actor
    | None -> (
        match pick (fun role -> role <> "npc") "npc-fallback" with
        | Some actor -> Some actor
        | None -> choose_from_candidates "npc-any" live_actors)
  else
    match pick (fun role -> role = "npc") "player-primary" with
    | Some actor -> Some actor
    | None -> choose_from_candidates "player-any" live_actors

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
          "잔영만 남기며 옆구리를 노린다.";
        ];
    };
    {
      npc_name = "Feral Wraith";
      archetype = "phantom-skirmisher";
      persona = "A tormented spirit lashing out at the living.";
      traits = [ "ethereal"; "relentless" ];
      skills = [ "spectral_rend"; "phase_strike" ];
      base_hp = 10;
      damage_min = 3;
      damage_max = 5;
      attack_narrations =
        [
          "원혼의 손길이 살갗을 파고든다.";
          "차가운 기운이 뼈를 스친다.";
          "실체 없는 팔이 허공에서 뻗어 나온다.";
        ];
    };
    {
      npc_name = "Thorn Crawler";
      archetype = "plant-skirmisher";
      persona = "A twisted vine creature creeping along the walls.";
      traits = [ "patient"; "ensnaring" ];
      skills = [ "vine_lash"; "thorn_spray" ];
      base_hp = 14;
      damage_min = 2;
      damage_max = 4;
      attack_narrations =
        [
          "가시 덩굴이 발목을 감아 조인다.";
          "날카로운 가시가 사방으로 흩뿌려진다.";
          "땅 아래에서 뿌리가 솟아올라 찌른다.";
        ];
    };
    (* -- Brutes: high HP, heavy damage, slow -- *)
    {
      npc_name = "Ironclad Golem";
      archetype = "construct-brute";
      persona = "An ancient automaton animated by forgotten runes.";
      traits = [ "armored"; "relentless" ];
      skills = [ "slam"; "iron_fist" ];
      base_hp = 22;
      damage_min = 4;
      damage_max = 7;
      attack_narrations =
        [
          "강철 주먹이 대지를 울리며 내려찍는다.";
          "묵직한 팔이 바람을 가르며 휘둘러진다.";
          "녹슨 관절이 삐걱대며 돌진한다.";
        ];
    };
    {
      npc_name = "Savage Ogre";
      archetype = "beast-brute";
      persona = "A towering mass of muscle and rage.";
      traits = [ "brutal"; "dim-witted" ];
      skills = [ "crush"; "roar" ];
      base_hp = 20;
      damage_min = 4;
      damage_max = 8;
      attack_narrations =
        [
          "거대한 곤봉이 머리 위에서 내리꽂힌다.";
          "분노에 찬 포효와 함께 돌진한다.";
          "땅을 흔드는 발걸음으로 짓밟으려 한다.";
        ];
    };
    {
      npc_name = "Plague Bearer";
      archetype = "toxic-brute";
      persona = "A bloated horror oozing contagion.";
      traits = [ "toxic"; "resilient" ];
      skills = [ "noxious_slam"; "bile_burst" ];
      base_hp = 18;
      damage_min = 3;
      damage_max = 6;
      attack_narrations =
        [
          "부패한 손아귀로 움켜쥐며 독을 퍼뜨린다.";
          "역겨운 담즙이 터져 나와 사방을 적신다.";
          "오염된 팔이 느릿하지만 정확하게 내려친다.";
        ];
    };
    (* -- Casters: low HP, high variance damage, magic -- *)
    {
      npc_name = "Void Weaver";
      archetype = "dark-caster";
      persona = "A hooded figure channeling abyssal energy.";
      traits = [ "cunning"; "fragile" ];
      skills = [ "void_bolt"; "shadow_bind" ];
      base_hp = 8;
      damage_min = 3;
      damage_max = 8;
      attack_narrations =
        [
          "허공에서 검은 빛줄기가 쏟아진다.";
          "어둠의 파동이 영혼을 잠식한다.";
          "심연의 에너지가 손끝에서 폭발한다.";
        ];
    };
    {
      npc_name = "Flame Disciple";
      archetype = "fire-caster";
      persona = "A zealot wreathed in living fire.";
      traits = [ "fanatical"; "volatile" ];
      skills = [ "fireball"; "ignite" ];
      base_hp = 9;
      damage_min = 3;
      damage_max = 7;
      attack_narrations =
        [
          "불꽃이 손바닥에서 소용돌이치며 발사된다.";
          "뜨거운 화염이 대지를 태우며 번져간다.";
          "작열하는 불덩이가 포물선을 그리며 날아온다.";
        ];
    };
    {
      npc_name = "Frost Warden";
      archetype = "ice-caster";
      persona = "A sentinel of eternal winter.";
      traits = [ "methodical"; "cold" ];
      skills = [ "frost_spike"; "frozen_grasp" ];
      base_hp = 10;
      damage_min = 2;
      damage_max = 7;
      attack_narrations =
        [
          "서릿발이 땅을 타고 발밑을 얼린다.";
          "얼음 창이 허공에서 결정화되어 꽂힌다.";
          "차가운 손길이 사지를 마비시킨다.";
        ];
    };
    (* -- Elites: balanced, multiple skills, mid-late game -- *)
    {
      npc_name = "Shadow Knight";
      archetype = "dark-elite";
      persona = "A fallen warrior wielding cursed steel.";
      traits = [ "disciplined"; "relentless"; "armored" ];
      skills = [ "cursed_slash"; "dark_shield"; "riposte" ];
      base_hp = 18;
      damage_min = 3;
      damage_max = 6;
      attack_narrations =
        [
          "저주받은 검날이 암흑빛을 뿜으며 베어낸다.";
          "묵직한 반격이 방패 너머로 날아온다.";
          "어둠의 기사가 냉정하게 칼을 내리친다.";
        ];
    };
    {
      npc_name = "Chimera Hound";
      archetype = "beast-elite";
      persona = "A multi-headed beast fused by dark alchemy.";
      traits = [ "ferocious"; "unpredictable" ];
      skills = [ "triple_bite"; "acid_spit"; "pounce" ];
      base_hp = 16;
      damage_min = 3;
      damage_max = 7;
      attack_narrations =
        [
          "세 개의 머리가 동시에 이빨을 드러낸다.";
          "산성 침이 갑옷을 녹이며 튀어 오른다.";
          "거대한 몸이 도약하며 짓누른다.";
        ];
    };
    {
      npc_name = "Bone Colossus";
      archetype = "undead-elite";
      persona = "A towering skeleton assembled from a hundred corpses.";
      traits = [ "imposing"; "resilient"; "slow" ];
      skills = [ "bone_crush"; "skeletal_rain"; "reassemble" ];
      base_hp = 24;
      damage_min = 4;
      damage_max = 7;
      attack_narrations =
        [
          "거대한 뼈 주먹이 천천히, 그러나 확실하게 내려온다.";
          "부러진 뼈 파편이 쏟아져 내린다.";
          "해골 거인이 한 발 내딛으며 대지가 울린다.";
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
  let min_d, max_d = damage_range in
  let hash = Hashtbl.hash (actor_id ^ ":" ^ string_of_int turn) in
  let span = max_d - min_d + 1 in
  let bucket = (if hash < 0 then -hash else hash) mod span in
  min_d + bucket

(** Pick a counterattack narration for an NPC based on its template and turn. *)
let npc_attack_narration ~turn ~npc_template =
  let narrations = npc_template.attack_narrations in
  let len = List.length narrations in
  if len = 0 then "잔존한 적이 반격해 전열을 흔든다."
  else
    let idx = (if turn < 0 then -turn else turn) mod len in
    List.nth narrations idx

(** Find a bestiary template by NPC name.  Falls back to the turn-based
    selection if no exact match is found (e.g. legacy data). *)
let find_npc_template_by_name name =
  Array.to_seq npc_bestiary
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
      Ok
        (match hp_event_opt with
        | Some hp_event -> [ combat_event; hp_event ]
        | None -> [ combat_event ])
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
      actor_json |> member "hp" |> to_int_option
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

