(** Trpg_round — fallback replies, keeper reply parsing, DM prompt
    construction, session setup, keeper integration, observability. *)

include Trpg_action
open Yojson.Safe.Util

let default_placeholder_reply = "상황을 살피며 다음 행동을 준비합니다."

let state_turn state =
  match state |> member "turn" with
  | `Int n when n > 0 -> n
  | _ -> 1

let non_empty_string_list_field json key =
  match json |> member key with
  | `List xs ->
      xs
      |> List.filter_map (function
           | `String s when String.trim s <> "" -> Some (String.trim s)
           | `Assoc fields -> (
               match List.assoc_opt "name" fields with
               | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
               | _ -> (
                   match List.assoc_opt "id" fields with
                   | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
                   | _ -> None ) )
           | _ -> None)
  | _ -> []

let last_actor_reply ~state ~actor_id =
  match state |> member "narration_log" with
  | `List entries ->
      entries
      |> List.rev
      |> List.find_map (fun entry ->
             match entry with
             | `Assoc fields -> (
                 match List.assoc_opt "actor_id" fields with
                 | Some (`String aid) when aid = actor_id -> (
                     match List.assoc_opt "reply" fields with
                     | Some (`String reply) when String.trim reply <> "" ->
                         Some (String.trim reply)
                     | _ -> (
                         match List.assoc_opt "proposed_action" fields with
                         | Some (`String reply) when String.trim reply <> "" ->
                             Some (String.trim reply)
                         | _ -> None ) )
                 | _ -> None )
              | _ -> None)
  | _ -> None

let is_ascii_digit_string (s : string) : bool =
  let trimmed = String.trim s in
  trimmed <> ""
  && String.for_all
       (function
         | '0' .. '9' -> true
         | _ -> false)
       trimmed

let normalize_reply_for_comparison (raw : string) : string =
  let normalized =
    raw
    |> String.trim
    |> String.lowercase_ascii
    |> String.map (function
         | '\n' | '\r' | '\t' -> ' '
         | '.'
         | ','
         | '!'
         | '?'
         | ':'
         | ';'
         | '"'
         | '\''
         | '('
         | ')'
         | '['
         | ']'
         | '{'
         | '}'
         | '/'
         | '\\'
         | '|'
         | '-'
         | '_'
         | '+'
         | '='
         | '*'
         | '&'
         | '^'
         | '%'
         | '$'
         | '#'
         | '@'
         | '~'
         | '`' ->
             ' '
         | ch -> ch)
  in
  let tokens =
    normalized |> String.split_on_char ' ' |> List.filter (fun s -> s <> "")
  in
  let tokens =
    match tokens with
    | "turn" :: n :: rest when is_ascii_digit_string n -> rest
    | "턴" :: n :: rest when is_ascii_digit_string n -> rest
    | _ -> tokens
  in
  String.concat " " tokens

let recent_actor_replies ~state ~actor_id ~limit =
  if limit <= 0 then []
  else
    match state |> member "narration_log" with
    | `List entries ->
        let rec collect acc = function
          | [] -> List.rev acc
          | _ when List.length acc >= limit -> List.rev acc
          | entry :: tl -> (
              match entry with
              | `Assoc fields -> (
                  match List.assoc_opt "actor_id" fields with
                  | Some (`String aid) when aid = actor_id -> (
                      match
                        List.assoc_opt "reply" fields
                        |> Option.value
                             ~default:(Option.value ~default:`Null
                                         (List.assoc_opt "proposed_action" fields))
                      with
                      | `String reply when String.trim reply <> "" ->
                          collect (String.trim reply :: acc) tl
                      | _ -> collect acc tl )
                  | _ -> collect acc tl )
              | _ -> collect acc tl)
        in
        collect [] (List.rev entries)
    | _ -> []

let is_repetitive_reply ~state ~actor_id ~(reply : string) : bool =
  let normalized_reply = normalize_reply_for_comparison reply in
  if normalized_reply = "" then false
  else
    recent_actor_replies ~state ~actor_id ~limit:3
    |> List.map normalize_reply_for_comparison
    |> List.exists (fun recent ->
           recent <> ""
           &&
           (recent = normalized_reply
           || (String.length recent >= 24
              && contains_substring recent normalized_reply)
           || (String.length normalized_reply >= 24
              && contains_substring normalized_reply recent)))

let pick_deterministic_text ~actor_id ~turn ~salt xs =
  match xs with
  | [] -> None
  | _ ->
      let hash = Hashtbl.hash (actor_id ^ ":" ^ string_of_int turn ^ ":" ^ salt) in
      let idx = (if hash < 0 then -hash else hash) mod List.length xs in
      Some (List.nth xs idx)

let contains_any_substring text keywords =
  List.exists (fun keyword -> contains_substring text keyword) keywords

let pick_deterministic_text_excluding_many ~actor_id ~turn ~salt ~excludes xs =
  let normalized_excludes =
    excludes
    |> List.map normalize_reply_for_comparison
    |> List.filter (fun s -> s <> "")
  in
  let rec loop attempt fallback =
    if attempt > 10 then fallback
    else
      let salt' =
        if attempt = 0 then salt else Printf.sprintf "%s:alt:%d" salt attempt
      in
      match pick_deterministic_text ~actor_id ~turn ~salt:salt' xs with
      | Some candidate ->
          let normalized_candidate = normalize_reply_for_comparison candidate in
          if List.mem normalized_candidate normalized_excludes then
            let next_fallback = if fallback = None then Some candidate else fallback in
            loop (attempt + 1) next_fallback
          else Some candidate
      | None -> fallback
  in
  loop 0 None

let pick_deterministic_text_excluding ~actor_id ~turn ~salt ~exclude xs =
  let normalized_exclude = String.trim exclude in
  let rec loop attempt fallback =
    if attempt > 4 then fallback
    else
      let salt' =
        if attempt = 0 then salt else Printf.sprintf "%s:alt:%d" salt attempt
      in
      match pick_deterministic_text ~actor_id ~turn ~salt:salt' xs with
      | Some candidate when String.trim candidate <> normalized_exclude ->
          Some candidate
      | Some candidate ->
          let next_fallback = if fallback = None then Some candidate else fallback in
          loop (attempt + 1) next_fallback
      | None -> fallback
  in
  loop 0 None

let fallback_dm_reply ~state =
  let turn = state_turn state in
  let recent_replies = recent_actor_replies ~state ~actor_id:"dm" ~limit:3 in
  let live_npcs =
    party_fields_of_state state
    |> List.fold_left
         (fun acc (_, actor_json) ->
           if is_actor_alive actor_json && role_from_actor_json actor_json = "npc" then acc + 1
           else acc)
         0
  in
  let live_pcs =
    party_fields_of_state state
    |> List.fold_left
         (fun acc (_, actor_json) ->
           if is_actor_alive actor_json && role_from_actor_json actor_json <> "npc" then acc + 1
           else acc)
         0
  in
  let templates =
    if live_npcs > 0 then
      [
        (fun t n _p ->
          Printf.sprintf "턴 %d, 남은 %d명의 적이 대열을 고쳐 잡고 다음 공격을 준비한다." t n);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 적의 지휘관이 짧은 구호를 외치자 잔존 병력이 밀집 대형으로 전환한다." t);
        (fun t n _p ->
          Printf.sprintf "턴 %d, 흙먼지 사이로 %d개의 그림자가 천천히 위치를 바꾸며 측면을 노린다." t n);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 전장에 잠시 정적이 흐르지만 적의 눈빛은 여전히 전의를 품고 있다." t);
        (fun t _n p ->
          Printf.sprintf "턴 %d, 적이 아군 %d명의 배치를 살피며 약점을 탐색하는 기색이다." t p);
        (fun t n _p ->
          Printf.sprintf "턴 %d, %d명의 적이 짧게 숨을 고른 뒤 동시에 무기를 들어올린다." t n);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 바닥에 떨어진 무기가 달그락거리고 적 진영에서 다시 움직임이 감지된다." t);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 적의 후열에서 무언가를 준비하는 소리가 들려온다." t);
      ]
    else
      [
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 전장에 고요가 내려앉지만 어딘가에서 발소리가 가까워지고 있다." t);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 쓰러진 적들 사이로 찬 바람이 불어오고 새로운 위협의 기척이 느껴진다." t);
        (fun t _n p ->
          Printf.sprintf "턴 %d, 일행 %d명이 잠시 숨을 돌리지만 주변의 어둠이 점점 짙어지고 있다." t p);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 멀리서 낮은 포효 소리가 울려오고 대지가 미세하게 진동한다." t);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 전투의 잔향이 가시기도 전에 새로운 그림자가 시야 끝에 나타난다." t);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 바닥의 핏자국이 어딘가로 이어지고 있다. 아직 끝나지 않았다." t);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 지하에서 무언가가 움직이는 둔탁한 소리가 일행의 긴장을 다시 끌어올린다." t);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 고요한 순간도 잠시, 벽 너머에서 금속이 부딪히는 소리가 들린다." t);
      ]
  in
  let dm_actor_id = "__dm__" in
  let candidates = List.map (fun template -> template turn live_npcs live_pcs) templates in
  let selected =
    match recent_replies with
    | [] ->
        pick_deterministic_text ~actor_id:dm_actor_id ~turn ~salt:"dm-fallback" candidates
    | replies ->
        pick_deterministic_text_excluding_many ~actor_id:dm_actor_id ~turn
          ~salt:"dm-fallback" ~excludes:replies candidates
  in
  match selected with
  | Some reply -> reply
  | None -> Printf.sprintf "턴 %d, 전장의 상황이 다시 요동치기 시작한다." turn

let fallback_player_reply ~state ~actor_id =
  let turn = state_turn state in
  let recent_replies = recent_actor_replies ~state ~actor_id ~limit:3 in
  let skills, traits =
    match actor_json_of_state state actor_id with
    | Some actor_json ->
        ( non_empty_string_list_field actor_json "skills",
          non_empty_string_list_field actor_json "traits" )
    | None -> ([], [])
  in
  let trait_hint =
    pick_deterministic_text ~actor_id ~turn ~salt:"trait" traits
    |> Option.map (fun trait -> Printf.sprintf " (%s 성향)" trait)
    |> Option.value ~default:""
  in
  match pick_deterministic_text ~actor_id ~turn ~salt:"skill" skills with
  | Some skill ->
      let key = String.lowercase_ascii (String.trim skill) in
      let templates =
        if
          contains_any_substring key
            [ "mend"; "heal"; "truce"; "resolve"; "ward"; "anchor" ]
        then
          [
            Printf.sprintf
              "%s%s로 동료의 호흡을 정비해 붕괴 직전 전열을 안정시킨다."
              skill trait_hint;
            Printf.sprintf
              "%s%s를 사용해 위험한 아군을 먼저 보호하고 회복 시간을 확보한다."
              skill trait_hint;
            Printf.sprintf
              "%s%s로 일행의 흔들린 페이스를 되찾아 다음 턴의 성공 확률을 끌어올린다."
              skill trait_hint;
          ]
        else if
          contains_any_substring key
            [ "deception"; "favor"; "broker"; "shadow"; "charm" ]
        then
          [
            Printf.sprintf
              "%s%s를 활용해 상대의 판단을 흔들고 유리한 협상 구도를 만든다."
              skill trait_hint;
            Printf.sprintf
              "%s%s로 주의를 다른 곳으로 돌린 뒤 핵심 목표에 접근한다."
              skill trait_hint;
            Printf.sprintf
              "%s%s를 통해 정보 우위를 확보하고 다음 행동 선택지를 늘린다."
              skill trait_hint;
          ]
        else if
          contains_any_substring key
            [ "supply"; "ration"; "logistics"; "scan"; "omen"; "trace" ]
        then
          [
            Printf.sprintf
              "%s%s로 변수와 자원 손실을 먼저 점검해 무리한 돌입을 막는다."
              skill trait_hint;
            Printf.sprintf
              "%s%s를 사용해 위험 구간을 표시하고 안전한 진행 루트를 제시한다."
              skill trait_hint;
            Printf.sprintf
              "%s%s로 전장의 흐름을 재평가해 파티 운영 효율을 끌어올린다."
              skill trait_hint;
          ]
        else if
          contains_any_substring key [ "shield"; "intercept"; "guard"; "defense" ]
        then
          [
            Printf.sprintf
              "%s%s로 아군 전면을 받치며 적의 강공 타이밍을 흘려낸다."
              skill trait_hint;
            Printf.sprintf
              "%s%s를 통해 적의 집중 화력을 분산시키고 진형 붕괴를 막는다."
              skill trait_hint;
            Printf.sprintf
              "%s%s로 반격 각도를 만들기 전까지 버티는 시간을 번다."
              skill trait_hint;
          ]
        else
          [
            Printf.sprintf "%s%s로 적 전열의 약한 지점을 파고들어 공격한다." skill
              trait_hint;
            Printf.sprintf "%s%s를 활용해 측면을 압박하며 핵심 목표를 공격한다." skill
              trait_hint;
            Printf.sprintf "%s%s로 빈틈을 열고 전선을 밀어붙인다." skill trait_hint;
            Printf.sprintf "%s%s를 연계해 적의 대응 전에 먼저 주도권을 잡는다." skill
              trait_hint;
          ]
      in
      let selected =
        match recent_replies with
        | [] -> pick_deterministic_text ~actor_id ~turn ~salt:"skill-template" templates
        | replies ->
            pick_deterministic_text_excluding_many ~actor_id ~turn
              ~salt:"skill-template" ~excludes:replies templates
      in
      (match selected with
      | Some reply -> reply
      | None -> Printf.sprintf "%s%s로 적을 공격해 전선을 밀어붙인다." skill trait_hint)
  | None ->
      let templates =
        [
          Printf.sprintf "지형을 이용해%s 적의 허점을 노려 공격한다." trait_hint;
          Printf.sprintf "호흡을 고르고%s 적의 빈틈을 확인한 뒤 공격한다." trait_hint;
          Printf.sprintf "전열을 정비하고%s 확실한 타이밍에 공격한다." trait_hint;
          Printf.sprintf "교전을 길게 끌지 않기 위해%s 짧고 강한 일격을 노린다." trait_hint;
        ]
      in
      let selected =
        match recent_replies with
        | [] -> pick_deterministic_text ~actor_id ~turn ~salt:"plain-template" templates
        | replies ->
            pick_deterministic_text_excluding_many ~actor_id ~turn
              ~salt:"plain-template" ~excludes:replies templates
      in
      (match selected with
      | Some reply -> reply
      | None -> Printf.sprintf "적의 빈틈을 노려%s 공격한다." trait_hint)

let choose_live_npc_actor_id state =
  party_fields_of_state state
  |> List.find_map (fun (actor_id, actor_json) ->
         if is_actor_alive actor_json && role_from_actor_json actor_json = "npc" then
           Some actor_id
         else None)

(** Find a second live player target (excluding the primary target and NPC).
    Deterministic selection based on turn and actor_id hash. *)
let choose_second_player_target ~state ~npc_actor_id ~exclude_actor_id ~turn =
  let live_players =
    party_fields_of_state state
    |> List.filter (fun (aid, actor_json) ->
           aid <> npc_actor_id
           && aid <> exclude_actor_id
           && is_actor_alive actor_json
           && role_from_actor_json actor_json <> "npc"
           && role_from_actor_json actor_json <> "dm")
  in
  match live_players with
  | [] -> None
  | _ ->
      let len = List.length live_players in
      let hash = Hashtbl.hash (npc_actor_id ^ ":multi:" ^ string_of_int turn) in
      let idx = (if hash < 0 then -hash else hash) mod len in
      Some (fst (List.nth live_players idx))

let append_npc_counterattack_events ~store ~room_id ~phase ~turn ~state =
  let ( let* ) = Result.bind in
  let spawn_npc_for_pressure state =
    let existing = party_fields_of_state state in
    let rec pick_id idx =
      let candidate = Printf.sprintf "npc-t%d-%02d" turn idx in
      if List.mem_assoc candidate existing then pick_id (idx + 1) else candidate
    in
    let npc_id = pick_id 1 in
    let tmpl = select_npc_template ~turn in
    let hp = scale_hp ~turn ~base_hp:tmpl.base_hp in
    let npc_actor_json =
      `Assoc
        [
          ("name", `String tmpl.npc_name);
          ("role", `String "npc");
          ("archetype", `String tmpl.archetype);
          ("persona", `String tmpl.persona);
          ("traits", `List (List.map (fun t -> `String t) tmpl.traits));
          ("skills", `List (List.map (fun s -> `String s) tmpl.skills));
          ("hp", `Int hp);
          ("max_hp", `Int hp);
          ("alive", `Bool true);
          ("inventory", `List []);
        ]
    in
    let spawn_payload =
      `Assoc
        [
          ("turn", `Int turn);
          ("phase", `String phase);
          ("actor_id", `String npc_id);
          ("actor", npc_actor_json);
        ]
    in
    let* spawn_event =
      append_event ~store ~room_id
        ~event_type:Trpg_engine_event.Actor_spawned ~actor_id:npc_id
        ~payload:spawn_payload ()
    in
    let state_with_spawn =
      match state with
      | `Assoc fields ->
          let party_fields = party_fields_of_state state in
          let next_party =
            `Assoc ((npc_id, npc_actor_json) :: List.remove_assoc npc_id party_fields)
          in
          `Assoc (("party", next_party) :: List.remove_assoc "party" fields)
      | _ -> state
    in
    Ok (state_with_spawn, [ spawn_event ], npc_id)
  in
  let* state_for_attack, bootstrap_events, npc_actor_id =
    match choose_live_npc_actor_id state with
    | Some npc_id -> Ok (state, [], npc_id)
    | None -> spawn_npc_for_pressure state
  in
  match choose_attack_target_id ~state:state_for_attack ~actor_id:npc_actor_id with
  | None -> Ok bootstrap_events
  | Some target_actor_id ->
      (* Look up NPC name from state -> find bestiary template *)
      let npc_tmpl =
        match actor_json_of_state state_for_attack npc_actor_id with
        | Some actor_json -> (
            match actor_json |> member "name" with
            | `String name -> find_npc_template_by_name name
            | _ -> None)
        | None -> None
      in
      let damage_range =
        match npc_tmpl with
        | Some t -> (t.damage_min, t.damage_max)
        | None -> (2, 4)
      in
      let narration =
        match npc_tmpl with
        | Some t -> npc_attack_narration ~turn ~npc_template:t
        | None -> "잔존한 적이 반격해 전열을 흔든다."
      in
      let base_damage =
        deterministic_damage ~turn ~actor_id:npc_actor_id ~damage_range ()
      in
      (* Resolve archetype skill effect *)
      let skill =
        match npc_tmpl with
        | Some t -> resolve_npc_skill ~turn ~npc_template:t
        | None -> NoSkill
      in
      let skill_name_str = skill_effect_name skill in
      let skill_json =
        if skill_name_str = "" then `Null else `String skill_name_str
      in
      (* Apply skill effects *)
      let pre_attack_events = ref [] in
      let damage =
        match skill with
        | BonusDamage n -> base_damage + n
        | DoubleDamage -> base_damage * 2
        | _ -> base_damage
      in
      (* SelfHeal: emit hp.changed event with positive delta before attack *)
      (match skill with
      | SelfHeal heal_amount when heal_amount > 0 ->
          let heal_payload =
            `Assoc
              [
                ("turn", `Int turn);
                ("phase", `String phase);
                ("actor_id", `String npc_actor_id);
                ("delta", `Int heal_amount);
                ("source_actor_id", `String npc_actor_id);
                ("reason", `String "skill.war_cry");
              ]
          in
          (match
             append_event ~store ~room_id
               ~event_type:Trpg_engine_event.Hp_changed
               ~actor_id:npc_actor_id ~payload:heal_payload ()
           with
          | Ok ev -> pre_attack_events := [ ev ]
          | Error msg -> Printf.eprintf "[trpg] npc heal: %s\n%!" msg)
      | _ -> ());
      let narration_with_skill =
        if skill_name_str = "" then narration
        else Printf.sprintf "[%s] %s" skill_name_str narration
      in
      let attack_payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String npc_actor_id);
            ("action", `String narration_with_skill);
            ("target_id", `String target_actor_id);
            ("skill", skill_json);
            ("damage", `Int damage);
          ]
      in
      let* attack_event =
        append_event ~store ~room_id
          ~event_type:Trpg_engine_event.Combat_attack ~actor_id:npc_actor_id
          ~payload:attack_payload ()
      in
      let hp_payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String target_actor_id);
            ("delta", `Int (-damage));
            ("source_actor_id", `String npc_actor_id);
            ("reason", `String "combat.attack");
          ]
      in
      let* hp_event =
        append_event ~store ~room_id
          ~event_type:Trpg_engine_event.Hp_changed ~actor_id:target_actor_id
          ~payload:hp_payload ()
      in
      (* MultiTarget: attack a second player target if available *)
      let* extra_events =
        match skill with
        | MultiTarget -> (
            match
              choose_second_player_target ~state:state_for_attack ~npc_actor_id
                ~exclude_actor_id:target_actor_id ~turn
            with
            | None -> Ok []
            | Some second_target_id ->
                let second_damage =
                  deterministic_damage ~turn
                    ~actor_id:(npc_actor_id ^ "-multi") ~damage_range ()
                in
                let second_narration =
                  Printf.sprintf "[Spell Surge] 주문의 여파가 %s에게도 번진다."
                    second_target_id
                in
                let second_attack_payload =
                  `Assoc
                    [
                      ("turn", `Int turn);
                      ("phase", `String phase);
                      ("actor_id", `String npc_actor_id);
                      ("action", `String second_narration);
                      ("target_id", `String second_target_id);
                      ("skill", `String "Spell Surge");
                      ("damage", `Int second_damage);
                    ]
                in
                let* second_attack_ev =
                  append_event ~store ~room_id
                    ~event_type:Trpg_engine_event.Combat_attack
                    ~actor_id:npc_actor_id ~payload:second_attack_payload ()
                in
                let second_hp_payload =
                  `Assoc
                    [
                      ("turn", `Int turn);
                      ("phase", `String phase);
                      ("actor_id", `String second_target_id);
                      ("delta", `Int (-second_damage));
                      ("source_actor_id", `String npc_actor_id);
                      ("reason", `String "combat.attack");
                    ]
                in
                let* second_hp_ev =
                  append_event ~store ~room_id
                    ~event_type:Trpg_engine_event.Hp_changed
                    ~actor_id:second_target_id ~payload:second_hp_payload ()
                in
                Ok [ second_attack_ev; second_hp_ev ])
        | _ -> Ok []
      in
      Ok (bootstrap_events @ !pre_attack_events @ [ attack_event; hp_event ] @ extra_events)

let is_placeholder_reply (raw : string) : bool =
  let normalized = String.lowercase_ascii (String.trim raw) in
  normalized = String.lowercase_ascii default_placeholder_reply
  || normalized = "assess the situation and prepare the next move."

let truncate_before_marker s marker =
  match find_substring s marker with
  | Some idx -> String.sub s 0 idx
  | None -> s

let sanitize_keeper_reply (raw : string) : string =
  let text =
    raw
    |> truncate_before_marker "\"visible_state_json\":"
    |> truncate_before_marker "visible_state_json:"
    |> truncate_before_marker "\"state_snapshot_json\":"
    |> truncate_before_marker "state_snapshot_json:"
    |> truncate_before_marker "\"[STATE]\""
    |> truncate_before_marker "[STATE]"
    |> truncate_before_marker "[/STATE]"
  in
  let rec strip_state_block in_state acc = function
    | [] -> List.rev acc
    | line :: tl ->
        let t = String.trim line in
        if in_state then
          if starts_with t "[/STATE]" then strip_state_block false acc tl
          else strip_state_block true acc tl
        else if starts_with t "[STATE]" then strip_state_block true acc tl
        else strip_state_block false (line :: acc) tl
  in
  let lines = strip_state_block false [] (String.split_on_char '\n' text) in
  let is_noise_line line =
    let t = String.trim line in
    let lowered = String.lowercase_ascii t in
    t = ""
    || starts_with lowered "structured_action:"
    || starts_with t "\"reply\":"
    || starts_with t "SKILL:"
    || starts_with t "SKILL_REASON:"
    || starts_with t "room_id="
    || starts_with t "phase="
    || starts_with t "turn="
    || starts_with t "role="
    || starts_with t "actor_id="
    || starts_with t "\"TRPG 실행 요청"
    || starts_with t "TRPG 실행 요청입니다."
    || starts_with t "TRPG execution request."
    || starts_with t "state_snapshot_json:"
    || starts_with t "내 기록상 가장 처음 물어본 건 이거야"
    || contains_substring t "visible_state_json:"
    || contains_substring t "state_snapshot_json:"
  in
  let rec drop_leading_noise = function
    | [] -> []
    | line :: tl when is_noise_line line -> drop_leading_noise tl
    | xs -> xs
  in
  let cleaned_lines =
    lines
    |> List.filter (fun line ->
           let t = String.trim line in
           let lowered = String.lowercase_ascii t in
           not
             (starts_with t "```json"
             || t = "```"
             || starts_with lowered "structured_action:"
             || starts_with t "[STATE]"
             || starts_with t "[/STATE]"
             || starts_with t "visible_state_json:"
             || starts_with t "state_snapshot_json:"))
    |> drop_leading_noise
  in
  String.concat "\n" cleaned_lines |> String.trim

let is_reply_noise_text (raw : string) : bool =
  let t = String.trim raw in
  let lowered = String.lowercase_ascii t in
  t = ""
  || starts_with t "```"
  || starts_with lowered "structured_action:"
  || starts_with t "[STATE]"
  || starts_with t "[/STATE]"
  || starts_with t "\"reply\":"
  || starts_with t "SKILL:"
  || starts_with t "SKILL_REASON:"
  || starts_with t "room_id="
  || starts_with t "phase="
  || starts_with t "turn="
  || starts_with t "role="
  || starts_with t "actor_id="
  || starts_with t "\"TRPG 실행 요청"
  || starts_with t "TRPG 실행 요청입니다."
  || starts_with t "TRPG execution request."
  || starts_with t "state_snapshot_json:"
  || starts_with t "내 기록상 가장 처음 물어본 건 이거야"
  || starts_with t "반드시 한국어로 응답하세요."
  || contains_substring t "visible_state_json:"
  || contains_substring t "state_snapshot_json:"

let extract_skill_hint_from_text (raw : string) : string option =
  let lines =
    raw |> String.split_on_char '\n' |> List.map String.trim
    |> List.filter (fun line -> line <> "")
  in
  let extract_skill line =
    let t = String.trim line in
    if starts_with t "SKILL:" then
      let payload =
        String.sub t (String.length "SKILL:") (String.length t - String.length "SKILL:")
        |> String.trim
      in
      if payload = "" then None else Some payload
    else None
  in
  List.find_map extract_skill lines

let fallback_reply_from_keeper_json keeper_json =
  let is_meta_skill_hint skill =
    let lowered = String.lowercase_ascii (String.trim skill) in
    (* TRPG skills are never meta-skills — they produce in-game content *)
    if starts_with lowered "trpg-" then false
    else
      starts_with lowered "masc-"
      || starts_with lowered "lodge-"
      || starts_with lowered "heartbeat"
      || contains_substring lowered "keeper"
      || contains_substring lowered "autonomy"
  in
  let skill_from_meta =
    match keeper_json |> member "skill_primary" with
    | `String s when String.trim s <> "" -> Some (String.trim s)
    | _ -> None
  in
  let skill_hint =
    match skill_from_meta with
    | Some skill -> Some skill
    | None -> (
        match keeper_json |> member "reply" with
        | `String s -> extract_skill_hint_from_text s
        | _ -> None )
  in
  match skill_hint with
  | Some skill when skill <> "" ->
      if is_meta_skill_hint skill then Some "상황을 살피며 다음 행동을 준비합니다."
      else Some (Printf.sprintf "%s 스킬을 활용해 행동을 이어갑니다." skill)
  | _ -> None

let parse_keeper_reply keeper_json =
  let default_fallback_reply = default_placeholder_reply in
  let raw_reply =
    match first_nonempty_string_field [ "reply"; "content"; "text"; "message" ] keeper_json with
    | Some raw -> Some raw
    | None -> (
        match keeper_json |> member "structured_action" with
        | `Assoc fields when fields <> [] ->
            Some (Yojson.Safe.to_string (`Assoc [ ("structured_action", `Assoc fields) ]))
        | _ -> None )
  in
  match raw_reply with
  | None -> (
      match fallback_reply_from_keeper_json keeper_json with
      | Some reply when String.trim reply <> "" -> Ok reply
      | _ -> Ok default_fallback_reply)
  | Some s ->
      let cleaned = sanitize_keeper_reply s in
      let fallback = String.trim s in
      let prompt_echo =
        (contains_substring s "visible_state_json:"
        || contains_substring s "state_snapshot_json:")
        && (contains_substring s "TRPG 실행 요청입니다."
           || contains_substring s "TRPG execution request."
           || contains_substring s "내 기록상 가장 처음 물어본 건 이거야"
           || contains_substring s "내 기록 기준으로는, 직전에 이런 질문을 했어"
           || contains_substring s "당신은 던전 마스터"
           || contains_substring s "You are the Dungeon Master"
           || contains_substring s "캐릭터에 맞게 행동하고"
           || contains_substring s "Respond in-character as")
      in
      let fallback_reply = fallback_reply_from_keeper_json keeper_json in
      let structured_action_description =
        match extract_structured_action keeper_json with
        | Some sa ->
            let desc = String.trim sa.description in
            if desc <> "" && not (is_low_signal_structured_description desc) then
              Some desc
            else None
        | _ -> None
      in
      let reply =
        if cleaned <> "" then Some cleaned
        else if structured_action_description <> None then structured_action_description
        else if prompt_echo || is_reply_noise_text fallback then fallback_reply
        else Some fallback
      in
      (match reply with
      | Some reply when String.trim reply <> "" -> Ok reply
      | _ -> (
          match fallback_reply with
          | Some reply when String.trim reply <> "" -> Ok reply
          | _ ->
              if is_reply_noise_text fallback then
                Error
                  "meta-only reply: response contained only state/noise \
                   markers"
              else Ok default_fallback_reply))

(** Attempt to recover truncated JSON by closing unclosed braces/brackets.
    Returns None if the input cannot be recovered. *)
let recover_truncated_json (raw : string) : Yojson.Safe.t option =
  let trimmed = String.trim raw in
  if String.length trimmed = 0 then None
  else
    let open_braces = ref 0 in
    let open_brackets = ref 0 in
    let in_string = ref false in
    let escaped = ref false in
    String.iter
      (fun c ->
        if !escaped then escaped := false
        else
          match c with
          | '\\' when !in_string -> escaped := true
          | '"' -> in_string := not !in_string
          | '{' when not !in_string -> incr open_braces
          | '}' when not !in_string -> decr open_braces
          | '[' when not !in_string -> incr open_brackets
          | ']' when not !in_string -> decr open_brackets
          | _ -> ())
      trimmed;
    if !in_string then begin
      (* Close unclosed string *)
      let buf = Buffer.create (String.length trimmed + 16) in
      Buffer.add_string buf trimmed;
      Buffer.add_char buf '"';
      for _ = 1 to !open_brackets do
        Buffer.add_char buf ']'
      done;
      for _ = 1 to !open_braces do
        Buffer.add_char buf '}'
      done;
      (try Some (Yojson.Safe.from_string (Buffer.contents buf))
       with Yojson.Json_error _ -> None)
    end
    else if !open_braces > 0 || !open_brackets > 0 then begin
      let buf = Buffer.create (String.length trimmed + 16) in
      Buffer.add_string buf trimmed;
      for _ = 1 to !open_brackets do
        Buffer.add_char buf ']'
      done;
      for _ = 1 to !open_braces do
        Buffer.add_char buf '}'
      done;
      (try Some (Yojson.Safe.from_string (Buffer.contents buf))
       with Yojson.Json_error _ -> None)
    end
    else None

(** Parse a raw string as keeper JSON, with truncated JSON recovery.
    Tries normal Yojson parse first. On failure, attempts to close unclosed
    braces/brackets and re-parse. Returns the parsed reply or an error. *)
let parse_keeper_reply_raw (raw : string) =
  let try_parse s =
    try Some (Yojson.Safe.from_string s) with Yojson.Json_error _ -> None
  in
  match try_parse raw with
  | Some json -> parse_keeper_reply json
  | None -> (
      match recover_truncated_json raw with
      | Some json ->
          Printf.eprintf
            "[WARN] parse_keeper_reply_raw: recovered truncated JSON\n%!";
          parse_keeper_reply json
      | None ->
          (* Not JSON at all — treat the raw text as the reply *)
          let trimmed = String.trim raw in
          if trimmed <> "" then Ok trimmed
          else Error "empty raw keeper response")

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

let room_id_for_session session_id =
  sanitize_room_id (Printf.sprintf "session-%s" session_id)

let json_of_strings xs = `List (List.map (fun s -> `String s) xs)

let pool_member_of_json (json : Yojson.Safe.t) :
    (pool_member, string) Stdlib.result =
  let ( let* ) = Result.bind in
  let string_list_field json key =
    match json |> member key with
    | `List _ as value -> get_string_list_from_json value
    | `Null -> Ok []
    | _ -> Error (Printf.sprintf "pool item.%s must be string array" key)
  in
  let as_assoc =
    match json with
    | `Assoc _ -> Ok json
    | _ -> Error "pool item must be object"
  in
  let* json = as_assoc in
  let* actor_id =
    match json |> member "actor_id" with
    | `String s when String.trim s <> "" -> Ok (String.trim s)
    | _ -> Error "pool item.actor_id is required"
  in
  let* name =
    match json |> member "name" with
    | `String s when String.trim s <> "" -> Ok (String.trim s)
    | _ -> Error (Printf.sprintf "pool item.name is required for actor_id=%s" actor_id)
  in
  let archetype =
    match json |> member "archetype" with
    | `String s when String.trim s <> "" -> String.trim s
    | _ -> "unknown"
  in
  let persona =
    match json |> member "persona" with
    | `String s -> s
    | _ -> ""
  in
  let* traits = string_list_field json "traits" in
  let* skill_ids = string_list_field json "skill_ids" in
  let keeper_name = json |> member "keeper_name" |> to_string_option in
  let source_preset_id =
    match json |> member "source_preset_id" with
    | `String s when String.trim s <> "" -> String.trim s
    | _ -> actor_id
  in
  Ok
    {
      actor_id;
      name;
      archetype;
      persona;
      traits;
      skill_ids;
      keeper_name;
      source_preset_id;
    }

let pool_members_of_json_list xs =
  let ( let* ) = Result.bind in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | x :: tl ->
        let* m = pool_member_of_json x in
        loop (m :: acc) tl
  in
  let* members = loop [] xs in
  Ok
    (members
    |> List.sort (fun a b -> String.compare a.actor_id b.actor_id))

let party_member_config (m : pool_member) : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String m.name);
      ("archetype", `String m.archetype);
      ("persona", `String m.persona);
      ("traits", json_of_strings m.traits);
      ("skills", json_of_strings m.skill_ids);
      ("hp", `Int 10);
      ("max_hp", `Int 10);
      ("alive", `Bool true);
      ("inventory", `List []);
    ]

let party_config (members : pool_member list) : Yojson.Safe.t =
  `Assoc
    (List.map
       (fun (m : pool_member) -> (m.actor_id, party_member_config m))
       members)

let world_config ~(preset : Trpg_preset_store.world_preset) : Yojson.Safe.t =
  `Assoc
    [
      ("preset_id", `String preset.id);
      ("title", `String preset.title);
      ("description", `String preset.description);
      ("intro", `String preset.intro);
      ("story_flags", json_of_strings preset.initial_flags);
      ("end_rules", Trpg_preset_store.end_rules_to_yojson preset.end_rules);
    ]

let dm_config ~(preset : Trpg_preset_store.dm_preset) ~dm_keeper : Yojson.Safe.t =
  `Assoc
    [
      ("preset_id", `String preset.id);
      ("title", `String preset.title);
      ("style", `String preset.style);
      ("opening_prompt", `String preset.opening_prompt);
      ("tags", json_of_strings preset.tags);
      ("keeper_name", `String dm_keeper);
    ]

let derive_pending_interventions (events : Trpg_engine_event.t list) :
    (int * string * Yojson.Safe.t) list =
  let submitted = ref [] in
  let applied = Hashtbl.create 16 in
  List.iter
    (fun (ev : Trpg_engine_event.t) ->
      match ev.event_type with
      | Trpg_engine_event.Intervention_submitted -> (
          match ev.payload |> member "intervention_id" with
          | `String intervention_id when String.trim intervention_id <> "" ->
              submitted := (ev.seq, intervention_id, ev.payload) :: !submitted
          | _ -> ())
      | Trpg_engine_event.Intervention_applied -> (
          match ev.payload |> member "intervention_id" with
          | `String intervention_id when String.trim intervention_id <> "" ->
              Hashtbl.replace applied intervention_id true
          | _ -> ())
      | _ -> ())
    events;
  !submitted
  |> List.filter (fun (_, intervention_id, _) ->
         not (Hashtbl.mem applied intervention_id))
  |> List.sort (fun (a, _, _) (b, _, _) -> Int.compare a b)

let inject_interventions_into_state state interventions =
  match state with
  | `Assoc fields ->
      `Assoc
        (("interventions", `List interventions)
        :: List.filter (fun (k, _) -> k <> "interventions") fields)
  | _ -> state

let call_keeper ctx ~name ~message ~timeout_sec =
  match ctx.keeper_call with
  | None -> `Error "keeper_call is not available in this runtime"
  | Some f -> f ~name ~message ~timeout_sec

let keeper_unavailable_max_per_turn_default = 8

let keeper_unavailable_max_per_turn_env =
  "MASC_TRPG_KEEPER_UNAVAILABLE_MAX_PER_TURN"

let keeper_unavailable_max_per_turn () =
  match Sys.getenv_opt keeper_unavailable_max_per_turn_env with
  | None -> keeper_unavailable_max_per_turn_default
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some value when value >= 0 -> value
      | _ -> keeper_unavailable_max_per_turn_default)

type unavailable_sampling_state = {
  max_per_turn : int;
  mutable count_in_turn : int;
  seen_keys : (string, unit) Hashtbl.t;
}

type unavailable_append_result =
  [ `Appended of Trpg_engine_event.t | `Sampled of string ]

let unavailable_sampling_key ~turn ~actor_id ~keeper_name ~stage ~reason =
  Printf.sprintf "%d|%s|%s|%s|%s" turn actor_id
    (normalize_keeper_name keeper_name)
    (String.lowercase_ascii (String.trim stage))
    (String.lowercase_ascii (String.trim reason))

let make_unavailable_sampling_state ~(events : Trpg_engine_event.t list) ~turn :
    unavailable_sampling_state =
  let seen_keys = Hashtbl.create 64 in
  let count_in_turn = ref 0 in
  List.iter
    (fun (event : Trpg_engine_event.t) ->
      if event.event_type = Trpg_engine_event.Keeper_unavailable then
        let payload_turn =
          match event.payload |> member "turn" with
          | `Int i -> Some i
          | _ -> None
        in
        match payload_turn with
        | Some payload_turn when payload_turn = turn ->
            count_in_turn := !count_in_turn + 1;
            let actor_id =
              match event.payload |> member "actor_id" with
              | `String v -> v
              | _ ->
                  Option.value ~default:"" event.actor_id |> String.trim
            in
            let keeper_name =
              match event.payload |> member "keeper" with
              | `String v -> v
              | _ -> ""
            in
            let stage =
              match event.payload |> member "stage" with
              | `String v -> v
              | _ -> ""
            in
            let reason =
              match event.payload |> member "reason" with
              | `String v -> v
              | _ -> ""
            in
            if actor_id <> "" && keeper_name <> "" && stage <> "" then
              let key =
                unavailable_sampling_key ~turn ~actor_id ~keeper_name ~stage
                  ~reason
              in
              Hashtbl.replace seen_keys key ()
        | _ -> ())
    events;
  {
    max_per_turn = keeper_unavailable_max_per_turn ();
    count_in_turn = !count_in_turn;
    seen_keys;
  }

let decide_unavailable_append ~sampling_state ~turn ~actor_id ~keeper_name ~stage
    ~reason : [ `Append | `Sampled of string ] =
  let key = unavailable_sampling_key ~turn ~actor_id ~keeper_name ~stage ~reason in
  if Hashtbl.mem sampling_state.seen_keys key then `Sampled "duplicate"
  else if sampling_state.count_in_turn >= sampling_state.max_per_turn then
    `Sampled
      (Printf.sprintf "cap:%d" (max 0 sampling_state.max_per_turn))
  else (
    Hashtbl.replace sampling_state.seen_keys key ();
    sampling_state.count_in_turn <- sampling_state.count_in_turn + 1;
    `Append)

let rec append_timeout_and_unavailable_events
    ~store
    ~room_id
    ~phase
    ~turn
    ~role
    ~actor_id
    ~keeper_name
    ~timeout_sec
    ~sampling_state
    =
  let ( let* ) = Result.bind in
  let timeout_reason = "timeout" in
  let timeout_stage = "masc_keeper_msg" in
  let timeout_payload =
    `Assoc
      [
        ("phase", `String phase);
        ("turn", `Int turn);
        ("role", `String (role_to_string role));
        ("actor_id", `String actor_id);
        ("keeper", `String keeper_name);
        ("reason", `String timeout_reason);
        ("timeout_sec", `Float timeout_sec);
        ("stage", `String timeout_stage);
      ]
  in
  let* timeout_event =
    append_event
      ~store
      ~room_id
      ~event_type:Trpg_engine_event.Turn_timeout
      ~actor_id
      ~payload:timeout_payload
      ()
  in
  let* unavailable_result =
    append_unavailable_event
      ~store
      ~room_id
      ~phase
      ~turn
      ~role
      ~actor_id
      ~keeper_name
      ~reason:timeout_reason
      ~stage:timeout_stage
      ~sampling_state
      ~extra_payload_fields:[ ("timeout_sec", `Float timeout_sec) ]
      ()
  in
  Ok (timeout_event, unavailable_result)

and append_unavailable_event
    ~store
    ~room_id
    ~phase
    ~turn
    ~role
    ~actor_id
    ~keeper_name
    ~reason
    ~stage
    ~sampling_state
    ?(extra_payload_fields = [])
    ()
    =
  match
    decide_unavailable_append ~sampling_state ~turn ~actor_id ~keeper_name
      ~stage ~reason
  with
  | `Sampled sampled_reason -> Ok (`Sampled sampled_reason)
  | `Append ->
      let payload =
        `Assoc
          ([
             ("phase", `String phase);
             ("turn", `Int turn);
             ("role", `String (role_to_string role));
             ("actor_id", `String actor_id);
             ("keeper", `String keeper_name);
             ("reason", `String reason);
             ("stage", `String stage);
           ]
          @ extra_payload_fields)
      in
      append_event
        ~store
        ~room_id
        ~event_type:Trpg_engine_event.Keeper_unavailable
        ~actor_id
        ~payload
        ()
      |> Result.map (fun event -> `Appended event)

let append_keeper_reply_event
    ~store
    ~room_id
    ~phase
    ~turn
    ~role
    ~actor_id
    ~keeper_name
    ~reply
    =
  let (event_type, payload) =
    match role with
    | `Dm ->
        ( Trpg_engine_event.Narration_posted,
          `Assoc
            [
              ("phase", `String phase);
              ("turn", `Int turn);
              ("role", `String "dm");
              ("actor_id", `String actor_id);
              ("keeper", `String keeper_name);
              ("reply", `String reply);
            ] )
    | `Player ->
        ( Trpg_engine_event.Turn_action_proposed,
          `Assoc
            [
              ("phase", `String phase);
              ("turn", `Int turn);
              ("role", `String "player");
              ("actor_id", `String actor_id);
              ("keeper", `String keeper_name);
              ("proposed_action", `String reply);
            ] )
  in
  append_event
    ~store
    ~room_id
    ~event_type
    ~actor_id
    ~payload
    ()

let deterministic_raw_d20 ~turn ~actor_id ~salt =
  let hash = Hashtbl.hash (actor_id ^ ":" ^ string_of_int turn ^ ":" ^ salt) in
  1 + ((if hash < 0 then -hash else hash) mod 20)

let action_type_requires_round_dice = function
  | Attack | Defend -> true
  | Heal | Investigate | Social | Explore | Magic | UseItem | SetFlag
  | SceneTransition | QuestUpdate ->
      false

let resolved_effects_of_events (events : Trpg_engine_event.t list) : Yojson.Safe.t list =
  let rec collect seen acc = function
    | [] -> List.rev acc
    | (event : Trpg_engine_event.t) :: tl ->
        let event_name = Trpg_engine_event.string_of_event_type event.event_type in
        if List.mem event_name seen then collect seen acc tl
        else collect (event_name :: seen) (`String ("event:" ^ event_name) :: acc) tl
  in
  collect [] [] events

let append_round_observability_events
    ~store
    ~room_id
    ~phase
    ~turn
    ~role
    ~actor_id
    ~keeper_name
    ~reply
    ~(sa : structured_action)
    ~action_events
    ~resolution_source
    ~fallback
    =
  let ( let* ) = Result.bind in
  let* dice_event_opt =
    if
      role = `Player
      && action_type_requires_round_dice sa.sa_type
      && not
           (List.exists
              (fun (event : Trpg_engine_event.t) ->
                event.event_type = Trpg_engine_event.Dice_rolled)
              action_events)
    then
      let raw_d20 =
        deterministic_raw_d20 ~turn ~actor_id
          ~salt:(string_of_action_type sa.sa_type)
      in
      let stat_value = 12 in
      let dc = 10 in
      let bonus = Trpg_rule_dnd5e_lite.stat_bonus stat_value in
      let total = raw_d20 + bonus in
      let c = Trpg_rule_dnd5e_lite.classify_roll ~raw_d20 ~total in
      let payload =
        `Assoc
          [
            ("phase", `String phase);
            ("turn", `Int turn);
            ("actor_id", `String actor_id);
            ("keeper", `String keeper_name);
            ("action", `String sa.description);
            ("action_type", `String (string_of_action_type sa.sa_type));
            ("stat_value", `Int stat_value);
            ("dc", `Int dc);
            ("raw_d20", `Int raw_d20);
            ("bonus", `Int bonus);
            ("total", `Int total);
            ("tier", `String (Trpg_rule_dnd5e_lite.roll_tier_to_string c.tier));
            ("label", `String c.label);
            ("passed", `Bool c.passed);
            ("resolved_by", `String "deterministic_round_run");
            ("source", `String "round_run");
          ]
      in
      let* event =
        append_event ~store ~room_id
          ~event_type:Trpg_engine_event.Dice_rolled ~actor_id ~payload ()
      in
      Ok (Some event)
    else Ok None
  in
  let observed_events =
    match dice_event_opt with
    | Some dice_event -> action_events @ [ dice_event ]
    | None -> action_events
  in
  let resolved_effects =
    let effects = resolved_effects_of_events observed_events in
    if effects = [] then
      [ `String ("action.applied:" ^ string_of_action_type sa.sa_type) ]
    else effects
  in
  let payload =
    `Assoc
      [
        ("phase", `String phase);
        ("turn", `Int turn);
        ("role", `String (role_to_string role));
        ("actor_id", `String actor_id);
        ("keeper", `String keeper_name);
        ("reply", `String reply);
        ("action_type", `String (string_of_action_type sa.sa_type));
        ("next_scene_or_state", `String "turn.continue");
        ("resolved_effects", `List resolved_effects);
        ("resolution_source", `String resolution_source);
        ("fallback", `Bool fallback);
      ]
  in
  let* resolved_event =
    append_event ~store ~room_id
      ~event_type:Trpg_engine_event.Turn_action_resolved ~actor_id ~payload ()
  in
  Ok
    (match dice_event_opt with
    | Some dice_event -> [ dice_event; resolved_event ]
    | None -> [ resolved_event ])

