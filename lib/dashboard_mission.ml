module U = Yojson.Safe.Util

let json_string_option value =
  match value with
  | Some text when String.trim text <> "" -> `String (String.trim text)
  | _ -> `Null

let member_assoc key json =
  match json with
  | `Assoc fields -> (match List.assoc_opt key fields with Some value -> value | None -> `Null)
  | _ -> `Null

let int_field ?(default = 0) key json =
  match member_assoc key json with
  | `Int value -> value
  | `Intlit raw -> (try int_of_string raw with _ -> default)
  | `Float value -> int_of_float value
  | _ -> default

let bool_field ?(default = false) key json =
  match member_assoc key json with
  | `Bool value -> value
  | _ -> default

let string_field ?(default = "") key json =
  match member_assoc key json with
  | `String value -> value
  | _ -> default

let list_field key json =
  match member_assoc key json with
  | `List items -> items
  | _ -> []

let severity_rank = function
  | "bad" -> 2
  | "warn" -> 1
  | _ -> 0

let compare_attention_json a b =
  Int.compare
    (severity_rank (string_field ~default:"ok" "severity" b))
    (severity_rank (string_field ~default:"ok" "severity" a))

let rec take n items =
  if n <= 0 then []
  else
    match items with
    | [] -> []
    | x :: xs -> x :: take (n - 1) xs

let keeper_pressure_count snapshot_json =
  let keepers = member_assoc "keepers" snapshot_json |> member_assoc "items" |> function
    | `List items -> items
    | _ -> []
  in
  List.fold_left
    (fun acc keeper ->
      let status = string_field ~default:"unknown" "status" keeper in
      let context_ratio =
        match member_assoc "context_ratio" keeper with
        | `Float value -> value
        | `Int value -> float_of_int value
        | _ -> 0.0
      in
      let last_turn_ago_s =
        match member_assoc "last_turn_ago_s" keeper with
        | `Float value -> value
        | `Int value -> float_of_int value
        | _ -> 0.0
      in
      if List.mem status [ "offline"; "inactive"; "error" ]
         || context_ratio >= 0.80
         || last_turn_ago_s >= 3600.0
      then acc + 1
      else acc)
    0 keepers

let active_agent_count config =
  Room.get_agents_raw config
  |> List.fold_left
       (fun acc (agent : Types.agent) ->
         match agent.status with
         | Types.Active | Types.Busy | Types.Listening -> acc + 1
         | Types.Inactive -> acc)
       0

let top_item items =
  match items with
  | item :: _ -> item
  | [] -> `Null

let json ?actor ~config ~sw ~clock ~proc_mgr () =
  let actor_name =
    match actor with
    | Some value when String.trim value <> "" -> String.trim value
    | _ -> "dashboard"
  in
  let ctx : _ Operator_control.context =
    {
      config;
      agent_name = actor_name;
      sw;
      clock;
      proc_mgr;
      mcp_session_id = None;
    }
  in
  let snapshot_json =
    Operator_control.snapshot_json
      ~actor:actor_name
      ~view:"summary"
      ~include_messages:false
      ~include_sessions:true
      ~include_keepers:true
      ctx
  in
  let digest_json =
    match Operator_control.digest_json ~actor:actor_name ctx with
    | Ok json -> json
    | Error message ->
        `Assoc
          [
            ("health", `String "warn");
            ("attention_items", `List []);
            ("recommended_actions", `List []);
            ("session_cards", `List []);
            ("swarm_status", Swarm_status.empty_json);
            ("command_plane", `Assoc []);
            ("error", `String message);
          ]
  in
  let room_json = member_assoc "room" snapshot_json in
  let command_json = member_assoc "command_plane" digest_json in
  let operations_summary = member_assoc "operations" command_json |> member_assoc "summary" in
  let decisions_summary = member_assoc "decisions" command_json |> member_assoc "summary" in
  let incidents =
    list_field "attention_items" digest_json
    |> List.sort compare_attention_json
  in
  let recommended_actions = list_field "recommended_actions" digest_json in
  let session_cards = list_field "session_cards" digest_json in
  let summary_json =
    `Assoc
      [
        ("room_health", `String (string_field ~default:"ok" "health" digest_json));
        ("cluster", json_string_option (Some (string_field "cluster" room_json)));
        ("project", json_string_option (Some (string_field "project" room_json)));
        ("current_room", member_assoc "current_room" room_json);
        ("paused", `Bool (bool_field "paused" room_json));
        ("tempo_interval_s", member_assoc "tempo_interval_s" room_json);
        ("active_agents", `Int (active_agent_count config));
        ("keeper_pressure", `Int (keeper_pressure_count snapshot_json));
        ("active_operations", `Int (int_field "active" operations_summary));
        ("pending_approvals", `Int (int_field "pending" decisions_summary));
        ("incident_count", `Int (List.length incidents));
        ("recommended_action_count", `Int (List.length recommended_actions));
        ("top_attention", top_item incidents);
        ("top_action", top_item recommended_actions);
      ]
  in
  let command_focus_json =
    `Assoc
      [
        ("health", `String (string_field ~default:"ok" "health" digest_json));
        ("active_operations", `Int (int_field "active" operations_summary));
        ("pending_approvals", `Int (int_field "pending" decisions_summary));
        ("swarm_overview", member_assoc "swarm_status" digest_json |> member_assoc "overview");
        ("top_attention", top_item incidents);
        ("top_action", top_item recommended_actions);
        ("session_cards", `List (take 3 session_cards));
      ]
  in
  let operator_targets_json =
    `Assoc
      [
        ("sessions", member_assoc "sessions" snapshot_json |> member_assoc "items");
        ("keepers", member_assoc "keepers" snapshot_json |> member_assoc "items");
        ("pending_confirms", member_assoc "pending_confirms" snapshot_json);
        ("available_actions", member_assoc "available_actions" snapshot_json);
      ]
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("summary", summary_json);
      ("incidents", `List incidents);
      ("recommended_actions", `List recommended_actions);
      ("command_focus", command_focus_json);
      ("operator_targets", operator_targets_json);
    ]
