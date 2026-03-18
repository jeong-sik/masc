[@@@warning "-32-33-69"]

open Server_utils

include Server_trpg_rest_models

let trpg_json_string_opt_field (json : Yojson.Safe.t) (key : string) : string option =
  match Yojson.Safe.Util.member key json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let trpg_json_int_field (json : Yojson.Safe.t) (key : string) ~(default : int) : int =
  match Yojson.Safe.Util.member key json with
  | `Int value -> value
  | _ -> default

let trpg_json_bool_field (json : Yojson.Safe.t) (key : string) ~(default : bool) : bool =
  match Yojson.Safe.Util.member key json with
  | `Bool value -> value
  | _ -> default

let trpg_take_right n lst =
  lst |> List.rev |> take n |> List.rev

let trpg_recent_events ~base_dir ~room_id ~limit =
  match Trpg.Engine_store_sqlite.read_events ~base_dir ~room_id with
  | Ok events -> trpg_take_right limit events
  | Error _ -> []

let trpg_party_member_rows (state : Yojson.Safe.t) =
  trpg_state_party_fields state
  |> List.map (fun (actor_id, row) ->
         match row with
         | `Assoc _ ->
             let name =
               trpg_json_string_opt_field row "name" |> Option.value ~default:actor_id
             in
             let role =
               trpg_json_string_opt_field row "role" |> Option.value ~default:"player"
             in
             let alive = trpg_json_bool_field row "alive" ~default:true in
             let hp = trpg_json_int_field row "hp" ~default:0 in
             let max_hp = trpg_json_int_field row "max_hp" ~default:hp in
             let keeper =
               trpg_owner_for_actor state actor_id |> Option.value ~default:""
             in
             `Assoc
               [
                 ("actor_id", `String actor_id);
                 ("name", `String name);
                 ("role", `String role);
                 ("alive", `Bool alive);
                 ("hp", `Int hp);
                 ("max_hp", `Int max_hp);
                 ("keeper", `String keeper);
                 ("claimed", `Bool (String.trim keeper <> ""));
               ]
         | _ ->
             `Assoc
               [
                 ("actor_id", `String actor_id);
                 ("name", `String actor_id);
                 ("role", `String "player");
                 ("alive", `Bool true);
                 ("hp", `Int 0);
                 ("max_hp", `Int 0);
                 ("keeper", `String "");
                 ("claimed", `Bool false);
               ])

let trpg_actor_control_rows (state : Yojson.Safe.t) =
  trpg_party_member_rows state
  |> List.filter_map (fun row ->
         let role = trpg_json_string_opt_field row "role" |> Option.value ~default:"player" in
         let claimed = trpg_json_bool_field row "claimed" ~default:false in
         if String.equal role "dm" || claimed then Some row else None)

let trpg_keeper_summary_rows (config : Room.config) =
  let dir = Keeper_types.keeper_dir config in
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".json")
    |> List.map Filename.remove_extension
    |> List.filter Keeper_types.validate_name
    |> List.sort String.compare
    |> List.filter_map (fun name ->
           match Keeper_types.read_meta config name with
           | Error _ -> None
           | Ok None -> None
           | Ok (Some (m : Keeper_types.keeper_meta)) ->
               let agent = Keeper_exec_status.parse_agent_status config ~agent_name:m.agent_name in
               let agent_exists = trpg_json_bool_field agent "exists" ~default:false in
               let agent_status =
                 trpg_json_string_opt_field agent "status"
                 |> Option.value ~default:"unknown"
               in
               let is_zombie = trpg_json_bool_field agent "is_zombie" ~default:false in
               let keepalive_running = Keeper_keepalive.keeper_keepalive_running m.name in
               Some
                 (`Assoc
                   [
                     ("name", `String m.name);
                     ("agent_name", `String m.agent_name);
                     ("models", `List (List.map (fun item -> `String item) m.models));
                     ("goal", `String m.goal);
                     ("agent_exists", `Bool agent_exists);
                     ("agent_status", `String agent_status);
                     ("is_zombie", `Bool is_zombie);
                     ("keepalive_running", `Bool keepalive_running);
                   ]))

let trpg_lobby_catalog_json ~base_dir ~(config : Room.config) ~room_id ~rule_module :
    trpg_api_result =
  let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
  let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
  let state = trpg_state_from_derived derived in
  let preset_catalog =
    match Trpg.Preset_store.load_catalog ~base_dir with
    | Ok catalog -> catalog
    | Error _ -> Trpg.Preset_store.default_catalog
  in
  let keepers = trpg_keeper_summary_rows config in
  let keeper_names =
    keepers
    |> List.filter_map (fun row -> trpg_json_string_opt_field row "name")
  in
  let current_status =
    trpg_json_string_opt_field state "status" |> Option.value ~default:"lobby"
  in
  let current_phase =
    trpg_json_string_opt_field state "phase"
    |> Option.value ~default:"dm_narration"
  in
  let current_turn = trpg_json_int_field state "turn" ~default:0 in
  Ok
    (`Assoc
      [
        ("ok", `Bool true);
        ("room_id", `String room_id);
        ("rule_module", `String rule_module);
        ("keepers", `List (List.map (fun name -> `String name) keeper_names));
        ("keeper_rows", `List keepers);
        ( "world_presets",
          `List
            (List.map Trpg.Preset_store.world_preset_to_yojson
               preset_catalog.world_presets) );
        ( "dm_presets",
          `List
            (List.map Trpg.Preset_store.dm_preset_to_yojson
               preset_catalog.dm_presets) );
        ("model_catalog", trpg_available_models_json ());
        ("occupancy", `List (trpg_actor_control_rows state));
        ( "current_room",
          `Assoc
            [
              ("status", `String current_status);
              ("phase", `String current_phase);
              ("turn", `Int current_turn);
            ] );
      ])

let trpg_preflight_row ~id ~label ~ok ?hint detail =
  let status = if ok then "ok" else "fail" in
  let fields =
    [
      ("id", `String id);
      ("label", `String label);
      ("ok", `Bool ok);
      ("status", `String status);
      ("detail", `String detail);
    ]
  in
  match hint with
  | Some value when String.trim value <> "" ->
      `Assoc (fields @ [("hint", `String (String.trim value))])
  | _ -> `Assoc fields

let trpg_lobby_preflight_json ~base_dir ~(config : Room.config) ~room_id ~rule_module
    ~(dm_keeper : string option) ~(player_keepers : string list) ~(models : string list) :
    trpg_api_result =
  let selected_dm = Option.value ~default:"" dm_keeper |> String.trim in
  let players = player_keepers |> List.map String.trim |> List.filter (( <> ) "") in
  let selected_keepers =
    split_csv_nonempty (String.concat "," (selected_dm :: players))
  in
  let keepers = trpg_keeper_summary_rows config in
  let keeper_names =
    keepers
    |> List.filter_map (fun row -> trpg_json_string_opt_field row "name")
  in
  let keeper_lookup : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 32 in
  List.iter
    (fun row ->
      match trpg_json_string_opt_field row "name" with
      | Some name -> Hashtbl.replace keeper_lookup name row
      | None -> ())
    keepers;
  let preset_catalog_result = Trpg.Preset_store.load_catalog ~base_dir in
  let preset_ok = Result.is_ok preset_catalog_result in
  let derived =
    match trpg_derive_state_json ~base_dir ~room_id ~rule_module with
    | Ok json -> Some json
    | Error _ -> None
  in
  let state = derived |> Option.map trpg_state_from_derived |> Option.value ~default:(`Assoc []) in
  let room_status =
    trpg_json_string_opt_field state "status" |> Option.value ~default:"lobby"
  in
  let blocking_rev = ref [] in
  let warnings_rev = ref [] in
  let actions_rev = ref [] in
  let add_blocking message =
    let trimmed = String.trim message in
    if trimmed <> "" then blocking_rev := trimmed :: !blocking_rev
  in
  let add_warning message =
    let trimmed = String.trim message in
    if trimmed <> "" then warnings_rev := trimmed :: !warnings_rev
  in
  let add_action message =
    let trimmed = String.trim message in
    if trimmed <> "" then actions_rev := trimmed :: !actions_rev
  in
  let selection_ok =
    selected_dm <> "" && players <> [] && not (List.mem selected_dm players)
  in
  if selected_dm = "" then add_blocking "DM keeper를 선택하세요.";
  if players = [] then add_blocking "플레이어 keeper를 1명 이상 선택하세요.";
  if List.mem selected_dm players then
    add_blocking "DM keeper와 플레이어 keeper를 중복 선택할 수 없습니다.";
  if models = [] then add_blocking "AI 모델을 하나 이상 입력하세요.";
  let missing_keepers =
    selected_keepers
    |> List.filter (fun name -> not (List.mem name keeper_names))
  in
  if missing_keepers <> [] then
    add_blocking
      (Printf.sprintf "keeper pool 없음: %s"
         (String.concat ", " missing_keepers));
  let boot_required =
    selected_keepers
    |> List.filter_map (fun name ->
           match Hashtbl.find_opt keeper_lookup name with
           | None -> None
           | Some row ->
               let agent_exists = trpg_json_bool_field row "agent_exists" ~default:false in
               let agent_status =
                 trpg_json_string_opt_field row "agent_status"
                 |> Option.value ~default:"unknown"
               in
               let is_zombie = trpg_json_bool_field row "is_zombie" ~default:false in
               let keepalive_running =
                 trpg_json_bool_field row "keepalive_running" ~default:false
               in
               if (not agent_exists) || is_zombie then Some (Printf.sprintf "%s: boot 필요" name)
               else if not (List.mem agent_status [ "active"; "busy"; "listening" ]) then
                 Some (Printf.sprintf "%s: status=%s" name agent_status)
               else if not keepalive_running then
                 Some (Printf.sprintf "%s: keepalive off" name)
               else None)
  in
  if boot_required <> [] then
    add_warning
      (Printf.sprintf "선택 keeper 준비 필요: %s"
         (String.concat ", " boot_required));
  let occupied =
    trpg_actor_control_rows state
    |> List.filter_map (fun row ->
           let keeper = trpg_json_string_opt_field row "keeper" |> Option.value ~default:"" in
           let actor_id =
             trpg_json_string_opt_field row "actor_id" |> Option.value ~default:""
           in
           if List.mem keeper selected_keepers then
             Some (Printf.sprintf "%s→%s" keeper actor_id)
           else None)
  in
  if occupied <> [] then (
    add_blocking
      (Printf.sprintf "이미 점유 중: %s" (String.concat ", " occupied));
    add_action "새 room id로 바꾸거나 기존 actor 점유를 해제하세요.");
  if not preset_ok then add_blocking "프리셋 catalog를 불러오지 못했습니다.";
  if not selection_ok then add_action "Lobby에서 DM 1명과 플레이어를 다시 선택하세요.";
  if models = [] then add_action "Lobby에서 AI 모델을 입력하거나 칩에서 선택하세요.";
  if room_status = "ended" then
    add_warning "현재 room은 종료 상태입니다. 새 room id 사용을 권장합니다.";
  let checks =
    [
      trpg_preflight_row ~id:"server" ~label:"서버 연결" ~ok:true "MASC 서버 응답 정상";
      trpg_preflight_row ~id:"presets" ~label:"프리셋" ~ok:preset_ok
        (if preset_ok then "월드/DM 프리셋 로드 가능" else "프리셋 catalog를 불러오지 못했습니다.");
      trpg_preflight_row ~id:"keeper-pool" ~label:"키퍼 풀"
        ~ok:(keeper_names <> [])
        (Printf.sprintf "%d명 사용 가능" (List.length keeper_names));
      trpg_preflight_row ~id:"selection" ~label:"선택 키퍼"
        ~ok:(selected_keepers <> [] && missing_keepers = [] && selection_ok)
        (if selected_keepers = [] then "DM/플레이어 keeper를 선택하세요."
         else
           Printf.sprintf "DM %s · 플레이어 %d명"
             (if selected_dm = "" then "-" else selected_dm)
             (List.length players));
      trpg_preflight_row ~id:"models" ~label:"AI 모델" ~ok:(models <> [])
        (if models = [] then "입력된 모델이 없습니다."
         else Printf.sprintf "%d개 선택" (List.length models));
      trpg_preflight_row ~id:"occupancy" ~label:"점유 충돌" ~ok:(occupied = [])
        (if occupied = [] then "선택 keeper 모두 비점유"
         else Printf.sprintf "충돌 %s" (String.concat ", " occupied));
      trpg_preflight_row ~id:"room" ~label:"룸 상태" ~ok:true
        (Printf.sprintf "room %s · %s" room_id room_status);
    ]
  in
  let dedupe_list items = String.concat "," items |> split_csv_nonempty in
  let blocking = List.rev !blocking_rev |> dedupe_list in
  let warnings = List.rev !warnings_rev |> dedupe_list in
  let recommended_actions = List.rev !actions_rev |> dedupe_list in
  Ok
    (`Assoc
      [
        ("ok", `Bool true);
        ("room_id", `String room_id);
        ("ready", `Bool (blocking = []));
        ("checks", `List checks);
        ("blocking", `List (List.map (fun item -> `String item) blocking));
        ("warnings", `List (List.map (fun item -> `String item) warnings));
        ( "recommended_actions",
          `List (List.map (fun item -> `String item) recommended_actions) );
      ])

let trpg_build_alarm ~level ~code ~message =
  `Assoc
    [
      ("level", `String level);
      ("code", `String code);
      ("message", `String message);
    ]

let trpg_overview_json ~base_dir ~room_id ~rule_module : trpg_api_result =
  let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
  let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
  let state = trpg_state_from_derived derived in
  let recent_events = trpg_recent_events ~base_dir ~room_id ~limit:12 in
  let party = trpg_party_member_rows state in
  let players =
    party
    |> List.filter (fun row ->
           trpg_json_string_opt_field row "role" |> Option.value ~default:"player"
           |> String.lowercase_ascii = "player")
  in
  let player_count = List.length players in
  let alive_players =
    players |> List.filter (fun row -> trpg_json_bool_field row "alive" ~default:true)
    |> List.length
  in
  let claimed_players =
    players |> List.filter (fun row -> trpg_json_bool_field row "claimed" ~default:false)
    |> List.length
  in
  let unclaimed_players = max 0 (player_count - claimed_players) in
  let active_keepers =
    trpg_state_actor_control_fields state
    |> List.map snd |> String.concat "," |> split_csv_nonempty |> List.length
  in
  let status =
    trpg_json_string_opt_field state "status" |> Option.value ~default:"lobby"
  in
  let phase =
    trpg_json_string_opt_field state "phase"
    |> Option.value ~default:"dm_narration"
  in
  let scenario =
    trpg_json_string_fields [ "current_scenario"; "scenario"; "world" ] state
    |> Option.value ~default:""
  in
  let node =
    trpg_json_string_fields
      [ "current_node"; "node"; "current_area"; "area"; "scene" ]
      state
    |> Option.value ~default:""
  in
  let alarms_rev = ref [] in
  let add_alarm level code message =
    alarms_rev := trpg_build_alarm ~level ~code ~message :: !alarms_rev
  in
  if status = "unavailable" then
    add_alarm "error" "room_unavailable" "TRPG 엔진 상태를 읽지 못했습니다.";
  if status = "ended" then
    add_alarm "warn" "room_ended" "이 room은 종료 상태입니다.";
  if unclaimed_players > 0 && status <> "lobby" then
    add_alarm "warn" "unclaimed_players"
      (Printf.sprintf "player actor %d명이 아직 keeper와 연결되지 않았습니다."
         unclaimed_players);
  List.iter
    (fun ev ->
      match ev.Trpg.Engine_event.event_type with
      | Trpg.Engine_event.Turn_timeout ->
          add_alarm "warn" "turn_timeout" "최근 턴 timeout 이벤트가 기록되었습니다."
      | Trpg.Engine_event.Keeper_unavailable ->
          add_alarm "warn" "keeper_unavailable" "최근 keeper unavailable 이벤트가 기록되었습니다."
      | _ -> ())
    recent_events;
  let next_actions =
    let items = ref [] in
    let add item =
      let trimmed = String.trim item in
      if trimmed <> "" then items := trimmed :: !items
    in
    if status = "lobby" then add "Lobby에서 세션을 시작하세요.";
    if unclaimed_players > 0 then add "Control에서 actor 점유 상태를 확인하세요.";
    if status = "stopped" then add "세션 재개 또는 라운드 실행 여부를 결정하세요.";
    if !items = [] then add "Timeline에서 최근 이벤트를 확인하세요.";
    String.concat "," (List.rev !items) |> split_csv_nonempty
  in
  Ok
    (`Assoc
      [
        ("ok", `Bool true);
        ("room_id", `String room_id);
        ( "summary",
          `Assoc
            [
              ("status", `String status);
              ("turn", `Int (trpg_json_int_field state "turn" ~default:0));
              ("phase", `String phase);
              ("scenario", `String scenario);
              ("node", `String node);
              ("player_count", `Int player_count);
              ("alive_players", `Int alive_players);
              ("claimed_players", `Int claimed_players);
              ("unclaimed_players", `Int unclaimed_players);
              ("active_keepers", `Int active_keepers);
            ] );
        ("alarms", `List (List.rev !alarms_rev));
        ( "next_actions",
          `List (List.map (fun item -> `String item) next_actions) );
        ("party", `List party);
        ( "recent_events",
          `List
            (List.map Trpg.Engine_event.to_yojson recent_events) );
      ])

let trpg_control_state_json ~base_dir ~room_id ~rule_module : trpg_api_result =
  let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
  let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
  let state = trpg_state_from_derived derived in
  let status =
    trpg_json_string_opt_field state "status" |> Option.value ~default:"lobby"
  in
  let phase =
    trpg_json_string_opt_field state "phase"
    |> Option.value ~default:"dm_narration"
  in
  let actor_control = trpg_actor_control_rows state in
  let player_rows =
    trpg_party_member_rows state
    |> List.filter (fun row ->
           trpg_json_string_opt_field row "role" |> Option.value ~default:"player"
           |> String.lowercase_ascii = "player")
  in
  let unclaimed_players =
    player_rows
    |> List.filter (fun row -> not (trpg_json_bool_field row "claimed" ~default:false))
  in
  let recent_interventions =
    trpg_recent_events ~base_dir ~room_id ~limit:20
    |> List.filter (fun ev ->
           match ev.Trpg.Engine_event.event_type with
           | Trpg.Engine_event.Intervention_submitted
           | Trpg.Engine_event.Intervention_applied -> true
           | _ -> false)
  in
  let allowed_actions =
    [
      `Assoc
        [
          ("id", `String "run-round");
          ("label", `String "라운드 실행");
          ("enabled", `Bool (status <> "ended" && status <> "unavailable"));
          ( "reason",
            `String
              (if status = "ended" then "종료된 세션입니다."
               else if status = "unavailable" then "엔진 상태를 읽지 못했습니다."
               else "라운드 실행 가능") );
        ];
      `Assoc
        [
          ("id", `String "pause-session");
          ("label", `String "세션 멈춤");
          ("enabled", `Bool (status = "running"));
          ( "reason",
            `String (if status = "running" then "진행 중 세션입니다." else "running 상태에서만 사용") );
        ];
      `Assoc
        [
          ("id", `String "resume-session");
          ("label", `String "세션 재개");
          ("enabled", `Bool (status = "stopped"));
          ( "reason",
            `String (if status = "stopped" then "중단된 세션입니다." else "stopped 상태에서만 사용") );
        ];
    ]
  in
  let warnings =
    [
      (if unclaimed_players = [] then None
       else
         Some
           (Printf.sprintf "미점유 player actor %d명"
              (List.length unclaimed_players)));
      (if recent_interventions = [] then None
       else Some "최근 intervention 이벤트가 있습니다.");
    ]
    |> List.filter_map (fun item -> item)
  in
  Ok
    (`Assoc
      [
        ("ok", `Bool true);
        ("room_id", `String room_id);
        ( "summary",
          `Assoc
            [
              ("status", `String status);
              ("turn", `Int (trpg_json_int_field state "turn" ~default:0));
              ("phase", `String phase);
              ( "join_window_open",
                `Bool (trpg_join_gate_phase_open state) );
              ("join_gate_min_points", `Int (trpg_join_gate_min_points state));
            ] );
        ("actor_control", `List actor_control);
        ("unclaimed_players", `List unclaimed_players);
        ( "recent_interventions",
          `List
            (List.map Trpg.Engine_event.to_yojson recent_interventions) );
        ("allowed_actions", `List allowed_actions);
        ("warnings", `List (List.map (fun item -> `String item) warnings));
      ])

let trpg_event_phase_matches (phase_filter : string option)
    (event : Trpg.Engine_event.t) =
  match phase_filter with
  | None -> true
  | Some phase_filter ->
      let normalized = String.lowercase_ascii (String.trim phase_filter) in
      if normalized = "" then true
      else
        match
          trpg_json_string_fields
            [ "phase"; "phase_name"; "phase_after"; "phase_before" ]
            event.payload
        with
        | Some phase ->
            String.equal (String.lowercase_ascii (String.trim phase)) normalized
        | None -> false

let trpg_timeline_json ~base_dir ~room_id ~after_seq ~event_type_filter ~actor_filter
    ~phase_filter ~limit : trpg_api_result =
  match trpg_stream_json ~base_dir ~room_id ~after_seq ~event_type_filter with
  | Error _ as err -> err
  | Ok raw ->
      let normalized = trpg_normalize_events_json ~default_room_id:room_id raw in
      let events =
        match trpg_json_assoc_find "events" normalized with
        | Some (`List entries) ->
            entries
            |> List.filter_map (fun item ->
                   match Trpg.Engine_event.of_yojson item with
                   | Ok event -> Some event
                   | Error _ -> None)
            |> List.filter (fun (event : Trpg.Engine_event.t) ->
                   let actor_ok =
                     match actor_filter with
                     | Some actor when String.trim actor <> "" -> (
                         match event.actor_id with
                         | Some actor_id -> String.equal actor_id (String.trim actor)
                         | None -> false)
                     | _ -> true
                   in
                   actor_ok && trpg_event_phase_matches phase_filter event)
            |> take limit
        | _ -> []
      in
      let last_seq =
        events
        |> List.rev
        |> List.find_map (fun event -> Some event.Trpg.Engine_event.seq)
        |> Option.value ~default:after_seq
      in
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ( "filters",
              `Assoc
                [
                  ("after_seq", `Int after_seq);
                  ( "event_type",
                    match event_type_filter with
                    | Some value -> `String value
                    | None -> `Null );
                  ( "actor",
                    match actor_filter with
                    | Some value -> `String value
                    | None -> `Null );
                  ( "phase",
                    match phase_filter with
                    | Some value -> `String value
                    | None -> `Null );
                  ("limit", `Int limit);
                ] );
            ("count", `Int (List.length events));
            ("last_seq", `Int last_seq);
            ( "events",
              `List (List.map Trpg.Engine_event.to_yojson events) );
          ])

