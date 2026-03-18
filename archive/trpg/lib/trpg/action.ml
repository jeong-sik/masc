(** Action — structured action parsing/validation, combat
    semantics, NPC bestiary, and round-level combat event helpers. *)

include Types
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
