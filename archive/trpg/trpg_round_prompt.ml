(** Trpg_round_prompt — DM persona, prompt context extraction, prompt building *)

include Trpg_round_keeper_parse
open Yojson.Safe.Util

type prompt_language = [ `Ko | `En ]

let prompt_language_of_string_opt = function
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "ko" | "kr" | "korean" -> `Ko
      | "en" | "english" -> `En
      | _ -> `Ko)
  | None -> `Ko

let take_last n xs =
  if n <= 0 then []
  else
    let len = List.length xs in
    let drop = max 0 (len - n) in
    let rec skip k ys =
      if k <= 0 then ys
      else
        match ys with
        | [] -> []
        | _ :: tl -> skip (k - 1) tl
    in
    skip drop xs

let compact_text ?(max_len = 320) s =
  let chunks =
    s |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun line -> line <> "")
  in
  let flat = String.concat " " chunks in
  if String.length flat <= max_len then flat
  else String.sub flat 0 max_len ^ "..."

let compact_narration_entry (entry : Yojson.Safe.t) : Yojson.Safe.t =
  match entry with
  | `Assoc fields ->
      let keep_key key =
        match List.assoc_opt key fields with Some v -> Some (key, v) | None -> None
      in
      let core =
        [ "phase"; "turn"; "role"; "actor_id"; "keeper" ]
        |> List.filter_map keep_key
      in
      let reply =
        match List.assoc_opt "reply" fields with
        | Some (`String s) when String.trim s <> "" ->
            [ ("reply", `String (compact_text ~max_len:360 s)) ]
        | _ -> []
      in
      `Assoc (core @ reply)
  | _ -> entry

let compact_state_for_prompt (state : Yojson.Safe.t) : Yojson.Safe.t =
  match state with
  | `Assoc fields ->
      let get key = List.assoc_opt key fields in
      let pick keys =
        keys |> List.filter_map (fun key ->
            match get key with Some v -> Some (key, v) | None -> None)
      in
      let narration_log =
        match get "narration_log" with
        | Some (`List xs) ->
            `List (xs |> take_last 8 |> List.map compact_narration_entry)
        | _ -> `List []
      in
      let dice_log =
        match get "dice_log" with
        | Some (`List xs) -> `List (take_last 8 xs)
        | _ -> `List []
      in
      `Assoc
        (pick
           [
             "turn";
             "phase";
             "status";
             "current_node";
             "world";
             "config";
             "party";
             "actor_control";
             "interventions";
           ]
        @ [ ("narration_log", narration_log); ("dice_log", dice_log) ])
  | _ -> state

type dm_persona_id =
  | Dm_grim_gothic
  | Dm_tactical_irony
  | Dm_heroic_epic

let dm_persona_id_of_string = function
  | "grim_gothic" | "grim-gothic" | "grim" -> Some Dm_grim_gothic
  | "tactical_irony" | "tactical-irony" | "tactical" -> Some Dm_tactical_irony
  | "heroic_epic" | "heroic-epic" | "heroic" -> Some Dm_heroic_epic
  | _ -> None

let string_of_dm_persona_id = function
  | Dm_grim_gothic -> "grim_gothic"
  | Dm_tactical_irony -> "tactical_irony"
  | Dm_heroic_epic -> "heroic_epic"

let infer_dm_persona_id ~explicit ~dm_style =
  match explicit with
  | Some id -> id
  | None ->
      let lowered = String.lowercase_ascii (String.trim dm_style) in
      if
        contains_substring lowered "grim"
        || contains_substring lowered "gothic"
        || contains_substring lowered "horror"
      then Dm_grim_gothic
      else if
        contains_substring lowered "tactic"
        || contains_substring lowered "irony"
        || contains_substring lowered "wry"
      then Dm_tactical_irony
      else Dm_heroic_epic

let dm_persona_directive_ko = function
  | Dm_grim_gothic ->
      "페르소나: Grim Gothic. 분위기는 음울하고 냉혹하게, 대가와 상흔을 분명히 제시하세요."
  | Dm_tactical_irony ->
      "페르소나: Tactical Irony. 전술적 긴장과 건조한 아이러니를 유지하고 선택의 비용을 숫자처럼 명확히 보여주세요."
  | Dm_heroic_epic ->
      "페르소나: Heroic Epic. 영웅 서사의 고조를 유지하되 승리도 희생과 위험을 통과해야 얻어지게 만드세요."

let dm_persona_directive_en = function
  | Dm_grim_gothic ->
      "Persona: Grim Gothic. Keep the tone bleak and costly; make scars and consequences explicit."
  | Dm_tactical_irony ->
      "Persona: Tactical Irony. Keep tactical pressure with dry irony; make costs and trade-offs explicit."
  | Dm_heroic_epic ->
      "Persona: Heroic Epic. Build heroic momentum, but every win must pass through risk and sacrifice."

type prompt_context = {
  actor_name : string;
  actor_persona : string;
  actor_archetype : string;
  actor_traits : string list;
  actor_skills : string list;
  actor_inventory : string list;
  actor_equipment : (string * string) list;
  scene_description : string;
  scene_mood : string;
  narrative_recent : string list;
  party_summary : string;
  relationships : (string * string) list;
  world_weather : string;
  world_time : string;
  dm_style : string;
  dm_opening_prompt : string;
  dm_persona_id : dm_persona_id;
  dm_persona_override : bool;
  (* Phase 1-3: Keeper Intelligence Harness fields *)
  bdi_fragment : string;
  dm_intent_hint : string;
  narrative_arc_phase : string;
  character_memory_notes : string;
}

let empty_prompt_context =
  {
    actor_name = "";
    actor_persona = "";
    actor_archetype = "";
    actor_traits = [];
    actor_skills = [];
    actor_inventory = [];
    actor_equipment = [];
    scene_description = "";
    scene_mood = "";
    narrative_recent = [];
    party_summary = "";
    relationships = [];
    world_weather = "";
    world_time = "";
    dm_style = "";
    dm_opening_prompt = "";
    dm_persona_id = Dm_heroic_epic;
    dm_persona_override = false;
    bdi_fragment = "";
    dm_intent_hint = "";
    narrative_arc_phase = "";
    character_memory_notes = "";
  }

let get_string_field json key =
  match json with
  | `Null -> ""
  | _ -> ( match json |> member key with `String s -> s | _ -> "")

let get_string_list_field json key =
  match json with
  | `Null -> []
  | _ -> (
      match json |> member key with
      | `List xs ->
          xs
          |> List.filter_map (function
               | `String s when String.trim s <> "" -> Some s
               | _ -> None)
      | _ -> [])

let extract_narrative_recent (state : Yojson.Safe.t) : string list =
  match state |> member "narration_log" with
  | `List xs ->
      xs |> take_last 5
      |> List.filter_map (fun entry ->
             match entry |> member "reply" with
             | `String s when String.trim s <> "" ->
                 let actor =
                   match entry |> member "actor_id" with
                   | `String a -> a
                   | _ -> "?"
                 in
                 Some (Printf.sprintf "[%s] %s" actor (compact_text ~max_len:200 s))
             | _ -> None)
  | _ -> []

let extract_party_summary ~exclude_actor_id (state : Yojson.Safe.t) : string =
  match state |> member "party" with
  | `Assoc members ->
      members
      |> List.filter_map (fun (aid, actor_json) ->
             if aid = exclude_actor_id then None
             else
               let name = get_string_field actor_json "name" in
               let arch = get_string_field actor_json "archetype" in
               let alive =
                 match actor_json |> member "alive" with
                 | `Bool b -> b
                 | _ -> true
               in
               if name = "" then None
               else
                 let status = if alive then "" else " [dead]" in
                 Some (Printf.sprintf "%s (%s)%s" name arch status))
      |> String.concat ", "
  | _ -> ""

let extract_equipment_fields (actor_json : Yojson.Safe.t) :
    (string * string) list =
  match actor_json with
  | `Null -> []
  | _ -> (
      match actor_json |> member "equipment" with
      | `Assoc pairs ->
          pairs
          |> List.filter_map (fun (slot, v) ->
                 match v with
                 | `String name when String.trim name <> "" ->
                     Some (slot, String.trim name)
                 | _ -> None)
      | `List items ->
          items
          |> List.filter_map (fun item ->
                 let slot = get_string_field item "slot" in
                 let name = get_string_field item "name" in
                 if slot <> "" && name <> "" then Some (slot, name) else None)
      | _ -> [])

(** Jaccard similarity between two word sets: |A inter B| / |A union B|. *)
let jaccard_similarity a b =
  let module SSet = Set.Make (String) in
  let set_a = SSet.of_list a in
  let set_b = SSet.of_list b in
  let inter = SSet.cardinal (SSet.inter set_a set_b) in
  let union = SSet.cardinal (SSet.union set_a set_b) in
  if union = 0 then 0.0 else Float.of_int inter /. Float.of_int union

let tokenize_words s =
  s |> normalize_reply_for_comparison |> String.split_on_char ' '
  |> List.filter (fun w -> String.length w > 0)

(** Check if a new narration entry is too similar to recent entries.
    Returns true if the entry should be skipped (>60% Jaccard overlap with
    any of the last 3 entries). *)
let is_narration_duplicate ~recent_replies (new_reply : string) : bool =
  let new_tokens = tokenize_words new_reply in
  recent_replies
  |> List.exists (fun prev ->
         let prev_tokens = tokenize_words prev in
         jaccard_similarity new_tokens prev_tokens > 0.6)

(** Extract last N reply strings from narration_log. *)
let extract_recent_replies ?(n = 3) (state : Yojson.Safe.t) : string list =
  match state |> member "narration_log" with
  | `List xs ->
      xs |> take_last n
      |> List.filter_map (fun entry ->
             match entry |> member "reply" with
             | `String s when String.trim s <> "" -> Some (String.trim s)
             | _ -> None)
  | _ -> []

(** Deduplicate a narration log list. For each entry, check if its reply
    is >60% Jaccard-similar to any of the preceding 3 entries. If so, skip. *)
let deduplicate_narration (entries : Yojson.Safe.t list) :
    Yojson.Safe.t list =
  let _recent, kept =
    List.fold_left
      (fun (recent, acc) entry ->
        let reply =
          match entry |> member "reply" with
          | `String s -> String.trim s
          | _ -> ""
        in
        if reply = "" then (recent, entry :: acc)
        else if is_narration_duplicate ~recent_replies:recent reply then
          (recent, acc)
        else
          let recent' = (reply :: recent) |> take_last 3 in
          (recent', entry :: acc))
      ([], []) entries
  in
  List.rev kept

(** Classify the relationship between actor_id and another actor based on
    keyword occurrence in narration log entries where both appear.
    Returns (other_actor_name, relation_type) pairs. *)
let extract_relationships ~actor_id (state : Yojson.Safe.t) :
    (string * string) list =
  let ally_keywords =
    [ "heal"; "help"; "protect"; "치유"; "도움"; "보호"; "회복" ]
  in
  let rival_keywords =
    [ "attack"; "hit"; "slash"; "strike"; "공격"; "타격"; "베" ]
  in
  let party_members =
    match state |> member "party" with
    | `Assoc members ->
        members
        |> List.filter_map (fun (aid, aj) ->
               if aid = actor_id then None
               else
                 let name = get_string_field aj "name" in
                 if name = "" then None else Some (aid, name))
    | _ -> []
  in
  let actor_name =
    match state |> member "party" with
    | `Assoc members -> (
        match List.assoc_opt actor_id members with
        | Some actor_json -> get_string_field actor_json "name"
        | None -> "")
    | _ -> ""
  in
  let actor_name_l = String.lowercase_ascii actor_name in
  let entries =
    match state |> member "narration_log" with
    | `List xs -> xs
    | _ -> []
  in
  party_members
  |> List.filter_map (fun (other_id, other_name) ->
         let ally_score = ref 0 in
         let rival_score = ref 0 in
         let co_count = ref 0 in
         entries
         |> List.iter (fun entry ->
                let reply =
                  match entry |> member "reply" with
                  | `String s -> String.lowercase_ascii s
                  | _ -> ""
                in
                let entry_actor =
                  match entry |> member "actor_id" with
                  | `String a -> a
                  | _ -> ""
                in
                let other_name_l = String.lowercase_ascii other_name in
                let involves_both =
                  (entry_actor = actor_id
                  && find_substring reply other_name_l <> None)
                  || (entry_actor = other_id && find_substring reply actor_name_l <> None)
                in
                if involves_both then begin
                  incr co_count;
                  if
                    List.exists
                      (fun kw -> find_substring reply kw <> None)
                      ally_keywords
                  then incr ally_score;
                  if
                    List.exists
                      (fun kw -> find_substring reply kw <> None)
                      rival_keywords
                  then incr rival_score
                end);
         if !co_count = 0 then None
         else
           let relation =
             if !ally_score > !rival_score then "ally"
             else if !rival_score > !ally_score then "rival"
             else "neutral"
           in
           Some (other_name, relation))

let extract_prompt_context ~actor_id ?(dm_persona_override = None)
    (state : Yojson.Safe.t) : prompt_context =
  let actor_json =
    match state |> member "party" with
    | `Assoc members -> (
        match List.assoc_opt actor_id members with
        | Some j -> j
        | None -> `Null)
    | _ -> `Null
  in
  let world_json = state |> member "world" in
  let dm_json =
    match state |> member "config" with
    | `Assoc fields -> (
        match List.assoc_opt "dm" fields with
        | Some value -> value
        | None -> `Null)
    | _ -> `Null
  in
  let dm_style = get_string_field dm_json "style" in
  let inferred_dm_persona =
    infer_dm_persona_id
      ~explicit:
        (Option.bind dm_persona_override (fun raw ->
             dm_persona_id_of_string
               (String.lowercase_ascii (String.trim raw))))
      ~dm_style
  in
  {
    actor_name = get_string_field actor_json "name";
    actor_persona = get_string_field actor_json "persona";
    actor_archetype = get_string_field actor_json "archetype";
    actor_traits = get_string_list_field actor_json "traits";
    actor_skills = get_string_list_field actor_json "skills";
    actor_inventory = get_string_list_field actor_json "inventory";
    actor_equipment = extract_equipment_fields actor_json;
    scene_description = get_string_field world_json "description";
    scene_mood = get_string_field world_json "intro";
    narrative_recent = extract_narrative_recent state;
    party_summary = extract_party_summary ~exclude_actor_id:actor_id state;
    relationships = extract_relationships ~actor_id state;
    world_weather =
      (let flags = get_string_list_field world_json "story_flags" in
       flags
       |> List.filter (fun f ->
              String.length f > 8
              && String.sub f 0 8 = "weather.")
       |> (function x :: _ -> x | [] -> ""));
    world_time =
      (let flags = get_string_list_field world_json "story_flags" in
       flags
       |> List.filter (fun f ->
              String.length f > 5
              && String.sub f 0 5 = "time.")
       |> (function x :: _ -> x | [] -> ""));
    dm_style;
    dm_opening_prompt = get_string_field dm_json "opening_prompt";
    dm_persona_id = inferred_dm_persona;
    dm_persona_override = Option.is_some dm_persona_override;
    bdi_fragment = "";
    dm_intent_hint = "";
    narrative_arc_phase = "";
    character_memory_notes = "";
  }

let join_nonempty sep items =
  items |> List.filter (fun s -> String.trim s <> "") |> String.concat sep

let format_traits traits =
  match traits with [] -> "" | ts -> String.concat ", " ts

let trpg_structured_action_system_instructions =
  "CRITICAL: Your response MUST contain a JSON object called structured_action.\n\
   Place it on its own line in your reply, exactly like this:\n\n\
   structured_action: {\"type\":\"<ACTION_TYPE>\",\"description\":\"<what you do>\"}\n\n\
   Optional memory hint (engine may up-tier via guardrail floor):\n\
   \"memory_hint\":{\"tier\":\"short|mid|long\",\"importance_score\":0-100,\"reason\":\"why this memory matters\"}\n\n\
   Available ACTION_TYPE values:\n\
   - Player actions: attack, defend, heal, investigate, social, explore, magic, use_item\n\
   - DM actions: set_flag, scene_transition, quest_update\n\n\
   Examples:\n\
   structured_action: {\"type\":\"attack\",\"target_id\":\"goblin-1\",\"description\":\"Slide under the shield wall and slash the goblin captain's knee\"}\n\
   structured_action: {\"type\":\"set_flag\",\"flag_key\":\"quest.hideout.found\",\"description\":\"A blood-stained map shard confirms the hideout entrance behind the chapel\"}\n\
   structured_action: {\"type\":\"scene_transition\",\"scene\":\"Deep cave\",\"description\":\"A cave-in seals the rear tunnel as the party dives into the crystal chamber\",\"memory_hint\":{\"tier\":\"mid\",\"reason\":\"scene pivot\"}}\n\
   structured_action: {\"type\":\"quest_update\",\"quest_info\":\"Boss ritual begins at moonrise\",\"description\":\"The captured scout reveals the ritual starts before moonrise\"}\n\n\
   Rules:\n\
   1. EVERY response must have exactly one structured_action line.\n\
   2. The JSON must be valid (use double quotes for keys and string values).\n\
   3. Do NOT wrap it in markdown code blocks.\n\
   4. Place it at the END of your narrative reply.\n\
   5. description must include concrete target/objective and immediate intent."

let build_player_section_ko (ctx : prompt_context) =
  let parts =
    [
      Printf.sprintf "당신은 '%s'입니다." ctx.actor_name;
      "당신은 보조자나 해설자가 아니라, 이 캐릭터의 의사결정을 직접 수행하는 플레이어입니다.";
      "메타 설명(시스템/프롬프트/모델/정책 언급)은 금지됩니다. 캐릭터의 관점으로만 응답하세요.";
      (if ctx.actor_archetype <> "" then
         Printf.sprintf "직업/역할: %s." ctx.actor_archetype
       else "");
      (if ctx.actor_persona <> "" then
         Printf.sprintf "성격: %s" ctx.actor_persona
       else "");
      (if ctx.actor_traits <> [] then
         Printf.sprintf "특성: %s." (format_traits ctx.actor_traits)
       else "");
      (if ctx.actor_skills <> [] then
         Printf.sprintf "보유 기술: %s." (format_traits ctx.actor_skills)
       else "");
      (match ctx.actor_equipment with
      | [] -> ""
      | eq ->
          Printf.sprintf "장착 중: %s."
            (eq
            |> List.map (fun (slot, name) ->
                   Printf.sprintf "%s(%s)" name slot)
            |> String.concat ", "));
      (if ctx.actor_inventory <> [] then
         Printf.sprintf "소지품: %s." (String.concat ", " ctx.actor_inventory)
       else "");
      (if ctx.scene_description <> "" then
         Printf.sprintf "현재 장소: %s" ctx.scene_description
       else "");
      (if ctx.scene_mood <> "" then
         Printf.sprintf "분위기: %s" ctx.scene_mood
       else "");
      (if ctx.world_weather <> "" then
         Printf.sprintf "날씨: %s." ctx.world_weather
       else "");
      (if ctx.world_time <> "" then
         Printf.sprintf "시간: %s." ctx.world_time
       else "");
      (if ctx.party_summary <> "" then
         Printf.sprintf "파티 동료: %s." ctx.party_summary
       else "");
      (match ctx.relationships with
      | [] -> ""
      | rels ->
          rels
          |> List.map (fun (name, rel) ->
                 Printf.sprintf "%s와(과)의 관계: %s" name rel)
          |> String.concat ". "
          |> Printf.sprintf "관계: %s.");
      (match ctx.narrative_recent with
      | [] -> ""
      | lines ->
          Printf.sprintf "최근 상황:\n%s"
            (lines |> List.map (fun l -> "- " ^ l) |> String.concat "\n"));
      Printf.sprintf
        "'%s'로서 지금 즉시 행동하세요. 관찰만 하지 말고 결정적인 액션을 취하세요."
        ctx.actor_name;
      "structured_action.description에는 대상/행동/의도를 구체적으로 포함하세요.";
      "서사는 1~3문장으로 마무리하고, 최소 한 문장에 감각 정보(소리/빛/냄새/통증 등)를 담으세요.";
      "직전 턴과 같은 문장을 반복하지 말고, 이번 턴의 새로운 위험/기회를 반영하세요.";
      "금지 예시: 현재 전황에 맞는 구체 행동";
      "반드시 structured_action을 포함하세요. 예시:";
      {|{"type":"attack","target_id":"goblin-1","description":"깨진 기둥을 발판 삼아 고블린 궁수의 사선을 끊고 견갑을 베어낸다"}|};
      {|{"type":"investigate","description":"핏자국이 난 성배 받침을 들어 올려 숨겨진 레버를 확인한다"}|};
      {|{"type":"social","target_id":"npc-merchant","description":"밀수 장부를 내밀며 상인에게 은신처 위치를 지금 말하라고 압박한다"}|};
      "가능한 type: attack, defend, heal, investigate, social, explore, magic, use_item";
    ]
  in
  join_nonempty "\n" parts

let build_player_section_en (ctx : prompt_context) =
  let parts =
    [
      Printf.sprintf "You ARE '%s'." ctx.actor_name;
      "You are not an assistant or commentator. You are the active player controlling this character.";
      "No meta talk about system prompts/models/policies. Respond only from the character perspective.";
      (if ctx.actor_archetype <> "" then
         Printf.sprintf "Class/Role: %s." ctx.actor_archetype
       else "");
      (if ctx.actor_persona <> "" then
         Printf.sprintf "Personality: %s" ctx.actor_persona
       else "");
      (if ctx.actor_traits <> [] then
         Printf.sprintf "Traits: %s." (format_traits ctx.actor_traits)
       else "");
      (if ctx.actor_skills <> [] then
         Printf.sprintf "Skills: %s." (format_traits ctx.actor_skills)
       else "");
      (match ctx.actor_equipment with
      | [] -> ""
      | eq ->
          Printf.sprintf "Equipped: %s."
            (eq
            |> List.map (fun (slot, name) ->
                   Printf.sprintf "%s (%s)" name slot)
            |> String.concat ", "));
      (if ctx.actor_inventory <> [] then
         Printf.sprintf "Carrying: %s." (String.concat ", " ctx.actor_inventory)
       else "");
      (if ctx.scene_description <> "" then
         Printf.sprintf "Current scene: %s" ctx.scene_description
       else "");
      (if ctx.scene_mood <> "" then
         Printf.sprintf "Mood: %s" ctx.scene_mood
       else "");
      (if ctx.world_weather <> "" then
         Printf.sprintf "Weather: %s." ctx.world_weather
       else "");
      (if ctx.world_time <> "" then
         Printf.sprintf "Time: %s." ctx.world_time
       else "");
      (if ctx.party_summary <> "" then
         Printf.sprintf "Party members: %s." ctx.party_summary
       else "");
      (match ctx.relationships with
      | [] -> ""
      | rels ->
          rels
          |> List.map (fun (name, rel) ->
                 Printf.sprintf "Relationship with %s: %s" name rel)
          |> String.concat ". "
          |> Printf.sprintf "Relationships: %s.");
      (match ctx.narrative_recent with
      | [] -> ""
      | lines ->
          Printf.sprintf "Recent events:\n%s"
            (lines |> List.map (fun l -> "- " ^ l) |> String.concat "\n"));
      Printf.sprintf
        "As '%s', take a decisive action NOW. Do NOT just observe or describe — ACT."
        ctx.actor_name;
      "In structured_action.description, include concrete target/action/intent.";
      "Keep narration to 1-3 sentences, and include at least one sensory detail.";
      "Do not repeat your previous line; reflect a new threat or opportunity this turn.";
      "Forbidden example: current situation appropriate concrete action";
      "You MUST include a structured_action. Examples:";
      {|{"type":"attack","target_id":"goblin-1","description":"Kick over the brazier to blind the goblin archer, then cut across his bow arm"}|};
      {|{"type":"investigate","description":"Lift the cracked altar tile and inspect the mechanism hidden under dried blood"}|};
      {|{"type":"social","target_id":"npc-merchant","description":"Threaten to expose the smuggling ledger unless the merchant reveals the hideout route"}|};
      "Available types: attack, defend, heal, investigate, social, explore, magic, use_item";
    ]
  in
  join_nonempty "\n" parts

let build_dm_section_ko (ctx : prompt_context) =
  let parts =
    [
      "당신은 던전 마스터(DM)입니다.";
      dm_persona_directive_ko ctx.dm_persona_id;
      (if ctx.dm_style <> "" then
         Printf.sprintf "DM 스타일 레퍼런스: %s" ctx.dm_style
       else "");
      (if ctx.dm_opening_prompt <> "" then
         Printf.sprintf "세션 테마: %s" (compact_text ~max_len:180 ctx.dm_opening_prompt)
       else "");
      (if ctx.scene_description <> "" then
         Printf.sprintf "현재 장면: %s" ctx.scene_description
       else "");
      (if ctx.scene_mood <> "" then
         Printf.sprintf "분위기: %s" ctx.scene_mood
       else "");
      (if ctx.world_weather <> "" then
         Printf.sprintf "날씨: %s." ctx.world_weather
       else "");
      (if ctx.world_time <> "" then
         Printf.sprintf "시간: %s." ctx.world_time
       else "");
      (if ctx.party_summary <> "" then
         Printf.sprintf "파티 구성: %s." ctx.party_summary
       else "");
      (match ctx.narrative_recent with
      | [] -> ""
      | lines ->
          Printf.sprintf "최근 서사:\n%s"
            (lines |> List.map (fun l -> "- " ^ l) |> String.concat "\n"));
      "다음에 일어날 일을 결정하세요. 서사를 진행하고, 환경과 NPC의 반응을 묘사하세요.";
      "structured_action.description에는 원인/장면 변화/즉각 위협 또는 기회를 포함하세요.";
      "서사는 1~3문장으로 유지하고, 매 턴 최소 하나의 새로운 위험/기회를 제시하세요.";
      "같은 DM 문장을 반복하지 말고, 장면의 감각 디테일(소리/온도/조명 등)을 추가하세요.";
      "금지 예시: 일행이 은신처를 발견했다";
      "반드시 structured_action을 포함하세요. DM용 예시:";
      {|{"type":"set_flag","flag_key":"quest.hideout.found","description":"핏자국이 묻은 지도 조각이 비밀 통로를 가리켜 은신처 좌표가 확정된다"}|};
      {|{"type":"scene_transition","scene":"동굴 깊은 곳","description":"매복병의 화살 세례를 피해 일행이 무너진 제단 아래 통로로 뛰어든다"}|};
      {|{"type":"quest_update","quest_info":"보스 의식 시간 자정으로 특정","description":"사로잡은 정찰병의 증언으로 보스가 자정에 의식을 시작한다는 사실이 드러난다"}|};
      "DM은 set_flag, scene_transition, quest_update만 사용하세요.";
      "스토리 목표 달성 시 [WIN], 전멸 시 [LOSE]를 reply에 포함하세요.";
      "매 턴마다 이야기를 진전시키세요. 같은 상황을 반복하지 마세요.";
    ]
  in
  join_nonempty "\n" parts

let build_dm_section_en (ctx : prompt_context) =
  let parts =
    [
      "You are the Dungeon Master (DM).";
      dm_persona_directive_en ctx.dm_persona_id;
      (if ctx.dm_style <> "" then
         Printf.sprintf "DM style reference: %s" ctx.dm_style
       else "");
      (if ctx.dm_opening_prompt <> "" then
         Printf.sprintf "Session theme: %s" (compact_text ~max_len:180 ctx.dm_opening_prompt)
       else "");
      (if ctx.scene_description <> "" then
         Printf.sprintf "Current scene: %s" ctx.scene_description
       else "");
      (if ctx.scene_mood <> "" then
         Printf.sprintf "Mood: %s" ctx.scene_mood
       else "");
      (if ctx.world_weather <> "" then
         Printf.sprintf "Weather: %s." ctx.world_weather
       else "");
      (if ctx.world_time <> "" then
         Printf.sprintf "Time: %s." ctx.world_time
       else "");
      (if ctx.party_summary <> "" then
         Printf.sprintf "Party composition: %s." ctx.party_summary
       else "");
      (match ctx.narrative_recent with
      | [] -> ""
      | lines ->
          Printf.sprintf "Recent narrative:\n%s"
            (lines |> List.map (fun l -> "- " ^ l) |> String.concat "\n"));
      "Determine what happens next. Advance the narrative, describe the environment and NPC reactions.";
      "structured_action.description must include trigger, scene change, and immediate threat or opportunity.";
      "Keep narration to 1-3 sentences and introduce at least one new threat or opportunity each turn.";
      "Do not repeat prior DM phrasing; add sensory details (sound, temperature, light, impact).";
      "Forbidden example: The party discovered the hideout";
      "You MUST include a structured_action. DM examples:";
      {|{"type":"set_flag","flag_key":"quest.hideout.found","description":"A blood-smeared map shard points to the chapel crypt and confirms the hideout entrance"}|};
      {|{"type":"scene_transition","scene":"Deep cave","description":"Arrow volleys force the party through a collapsing stair into the deep crystal cave"}|};
      {|{"type":"quest_update","quest_info":"Boss ritual begins at midnight","description":"An interrogated scout confirms the boss starts the ritual at midnight"}|};
      "DM must use only: set_flag, scene_transition, quest_update.";
      "When the story goal is achieved, include [WIN] in your reply. On party wipe, include [LOSE].";
      "Advance the story every turn. Do NOT repeat the same situation.";
    ]
  in
  join_nonempty "\n" parts

let build_keeper_prompt ~(store : Trpg_store.t) ~dm_persona_override ~room_id
    ~phase ~turn ~role ~actor_id ~state_json ~lang =
  let role_s = role_to_string role in
  let ctx0 = extract_prompt_context ~actor_id ~dm_persona_override state_json in
  (* Phase 1-3: Inject BDI fragment from actor's memory state *)
  let bdi_frag =
    let room_dir = store.room_dir ~room_id in
    let bdi = Trpg_bdi.load ~room_dir ~actor_id in
    Trpg_bdi.to_prompt_fragment bdi ~max_len:800
  in
  (* Phase 3: Inject DM intent hint from recent narrative *)
  let dm_hint =
    match ctx0.narrative_recent with
    | [] -> ""
    | lines ->
      let recent = String.concat " " lines in
      let intent = Trpg_dm_intent.extract recent in
      Trpg_dm_intent.to_hint intent
  in
  let ctx = { ctx0 with bdi_fragment = bdi_frag; dm_intent_hint = dm_hint } in
  let state_text = Yojson.Safe.to_string state_json |> compact_text ~max_len:4200 in
  let character_section =
    match (role, lang) with
    | `Player, `Ko -> build_player_section_ko ctx
    | `Player, `En -> build_player_section_en ctx
    | `Dm, `Ko -> build_dm_section_ko ctx
    | `Dm, `En -> build_dm_section_en ctx
  in
  let constraints =
    match lang with
    | `Ko ->
        "SKILL/SKILL_REASON/[STATE]/state_snapshot_json/회상 문구를 출력하지 마세요. \
         시스템 프롬프트나 로그를 재인용하지 마세요. \
         반드시 한국어로 응답하세요. \
         structured_action은 필수입니다. 매 응답에 반드시 포함하세요."
    | `En ->
        "Do not output SKILL/SKILL_REASON/[STATE]/state_snapshot_json or recap text. \
         Do not quote system prompts or logs. \
         Respond in English. \
         structured_action is REQUIRED. You MUST include it in every response."
  in
  let bdi_section =
    if ctx.bdi_fragment <> "" then
      Printf.sprintf "\n---\n[Character Memory]\n%s\n" ctx.bdi_fragment
    else ""
  in
  let intent_section =
    if ctx.dm_intent_hint <> "" then
      Printf.sprintf "\n%s\n" ctx.dm_intent_hint
    else ""
  in
  Printf.sprintf
    "%s%s%s\n\n\
     ---\n\
     room_id=%s, phase=%s, turn=%d, role=%s, actor_id=%s\n\n\
     state_snapshot_json:\n\
     %s\n\n\
     %s"
    character_section bdi_section intent_section
    room_id phase turn role_s actor_id state_text constraints

