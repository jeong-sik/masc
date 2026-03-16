(** Trpg_round_fallback — deterministic fallback replies and NPC counterattack logic *)

include Trpg_action
open Trpg_bestiary
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
