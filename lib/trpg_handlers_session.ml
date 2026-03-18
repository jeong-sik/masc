(** Trpg_handlers_session — join eligibility, mid-join, interventions, and round audit utilities. *)

open Yojson.Safe.Util

include Trpg_handlers_actors

let handle_join_eligibility ctx args : result =
  let ( let* ) = Result.bind in
  let store = ctx.store in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id = get_required_string args "actor_id" in
    let* keeper_name_opt = get_optional_string args "keeper_name" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* derived = derive_state ~store ~room_id ~rule_module in
    let state = state_of_derived derived in
    let* events = store.read_events ~room_id in
    let gate = join_gate_of_state state in
    let actor_exists = actor_exists_in_state state actor_id in
    let actor_role =
      if actor_exists then actor_role_in_state state actor_id else "player"
    in
    let server_score, reasons =
      contribution_for_actor_from_events events actor_id
    in
    let keeper_eval =
      match keeper_name_opt with
      | Some keeper_name ->
          evaluate_keeper_bonus ctx ~keeper_name ~room_id ~actor_id ~server_score
            ~required_points:gate.min_points
      | None ->
          {
            bonus = 0;
            source = "server_only";
            reason = None;
            warning = None;
          }
    in
    let effective_score = server_score + keeper_eval.bonus in
    let eligible, reason_code, reason =
      if actor_role <> "player" then
        (true, None, None)
      else if not gate.phase_open then
        ( false,
          Some "join_window_closed",
          Some "mid-join is only allowed at round boundary window" )
      else if effective_score < gate.min_points then
        ( false,
          Some "insufficient_contribution",
          Some
            (Printf.sprintf "score=%d required=%d"
               effective_score gate.min_points) )
      else (true, None, None)
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("room_id", `String room_id);
          ("actor_id", `String actor_id);
          ("actor_exists", `Bool actor_exists);
          ("actor_role", `String actor_role);
          ("phase_open", `Bool gate.phase_open);
          ("window", `String gate.window);
          ("required_points", `Int gate.min_points);
          ("server_score", `Int server_score);
          ("keeper_bonus", `Int keeper_eval.bonus);
          ("effective_score", `Int effective_score);
          ("eligible", `Bool eligible);
          ("reason_code", Option.fold ~none:`Null ~some:(fun v -> `String v) reason_code);
          ("reason", Option.fold ~none:`Null ~some:(fun v -> `String v) reason);
          ("score_reasons", json_of_strings reasons);
          ("judge_source", `String keeper_eval.source);
          ("judge_reason", Option.fold ~none:`Null ~some:(fun v -> `String v) keeper_eval.reason);
          ("judge_warning", Option.fold ~none:`Null ~some:(fun v -> `String v) keeper_eval.warning);
          ("state", state);
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_mid_join_request ctx args : result =
  let ( let* ) = Result.bind in
  let store = ctx.store in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id = get_required_string args "actor_id" in
    let* keeper_name = get_required_string args "keeper_name" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* derived = derive_state ~store ~room_id ~rule_module in
    let state = state_of_derived derived in
    let* events = store.read_events ~room_id in
    let gate = join_gate_of_state state in
    let actor_exists = actor_exists_in_state state actor_id in
    let actor_role =
      if actor_exists then actor_role_in_state state actor_id
      else
        (match get_optional_string args "role" with
        | Ok (Some role) -> String.lowercase_ascii role
        | _ -> "player")
    in
    let server_score, score_reasons =
      contribution_for_actor_from_events events actor_id
    in
    let keeper_eval =
      evaluate_keeper_bonus ctx ~keeper_name ~room_id ~actor_id ~server_score
        ~required_points:gate.min_points
    in
    let effective_score = server_score + keeper_eval.bonus in
    let requested_payload =
      `Assoc
        [
          ("actor_id", `String actor_id);
          ("keeper_name", `String keeper_name);
          ("actor_role", `String actor_role);
          ("phase_open", `Bool gate.phase_open);
          ("window", `String gate.window);
          ("required_points", `Int gate.min_points);
          ("server_score", `Int server_score);
          ("keeper_bonus", `Int keeper_eval.bonus);
          ("effective_score", `Int effective_score);
          ("requested_by", `String ctx.agent_name);
        ]
    in
    let* requested_event =
      append_event ~store ~room_id
        ~event_type:Trpg.Engine_event.Mid_join_requested ~actor_id
        ~payload:requested_payload ()
    in
    let reject ~reason_code ~reason ~importance_score =
      let rejected_payload =
        `Assoc
          [
            ("actor_id", `String actor_id);
            ("keeper_name", `String keeper_name);
            ("reason_code", `String reason_code);
            ("reason", `String reason);
            ("required_points", `Int gate.min_points);
            ("effective_score", `Int effective_score);
          ]
      in
      let* rejected_event =
        append_event ~store ~room_id
          ~event_type:Trpg.Engine_event.Mid_join_rejected ~actor_id
          ~payload:rejected_payload ()
      in
      let* memory_event =
        append_memory_signal_event ~store ~room_id ~event_tier:"short"
          ~importance_score
          ~summary_ko:(Printf.sprintf "중간 참여 거절: %s (%s)" actor_id reason_code)
          ~summary_en:(Printf.sprintf "Mid-join rejected: %s (%s)" actor_id reason_code)
          ~entity_refs:
            [
              ("actor_id", `String actor_id);
              ("keeper_name", `String keeper_name);
              ("reason_code", `String reason_code);
            ]
      in
      let* next_derived = derive_state ~store ~room_id ~rule_module in
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("actor_id", `String actor_id);
            ("keeper_name", `String keeper_name);
            ("granted", `Bool false);
            ("reason_code", `String reason_code);
            ("reason", `String reason);
            ("required_points", `Int gate.min_points);
            ("server_score", `Int server_score);
            ("keeper_bonus", `Int keeper_eval.bonus);
            ("effective_score", `Int effective_score);
            ("score_reasons", json_of_strings score_reasons);
            ("judge_source", `String keeper_eval.source);
            ("judge_warning", Option.fold ~none:`Null ~some:(fun v -> `String v) keeper_eval.warning);
            ( "events",
              `List
                [
                  Trpg.Engine_event.to_yojson requested_event;
                  Trpg.Engine_event.to_yojson rejected_event;
                  Trpg.Engine_event.to_yojson memory_event;
                ] );
            ("state", state_of_derived next_derived);
          ])
    in
    if actor_exists && not (actor_alive_in_state state actor_id) then
      reject ~reason_code:"actor_not_alive"
        ~reason:"target actor is not alive"
        ~importance_score:55
    else if actor_role = "player" && not gate.phase_open then
      reject ~reason_code:"join_window_closed"
        ~reason:"mid-join is only allowed at round boundary window"
        ~importance_score:40
    else if actor_role = "player" && effective_score < gate.min_points then
      reject ~reason_code:"insufficient_contribution"
        ~reason:
          (Printf.sprintf "effective_score=%d required_points=%d"
             effective_score gate.min_points)
        ~importance_score:45
    else
      let* spawn_event_opt, state_after_spawn =
        if actor_exists then Ok (None, state)
        else
          let* actor_json = actor_payload_from_spawn_args args ~actor_id in
          let spawn_payload =
            `Assoc
              [
                ("actor_id", `String actor_id);
                ("actor", actor_json);
                ("spawned_by", `String ctx.agent_name);
                ("source", `String "mid_join");
              ]
          in
          let* spawn_event =
            append_event ~store ~room_id
              ~event_type:Trpg.Engine_event.Actor_spawned ~actor_id
              ~payload:spawn_payload ()
          in
          let* d = derive_state ~store ~room_id ~rule_module in
          Ok (Some spawn_event, state_of_derived d)
      in
      let normalized_keeper = normalize_keeper_name keeper_name in
      let* claim_resolution =
        match owner_for_actor state_after_spawn actor_id with
        | Some owner when normalize_keeper_name owner = normalized_keeper ->
            Ok (`Proceed (true, None, state_after_spawn))
        | Some owner -> (
            let* rejected_json =
              reject ~reason_code:"actor_claimed_by_other_keeper"
                ~reason:(Printf.sprintf "actor already claimed by %s" owner)
                ~importance_score:50
            in
            Ok (`Rejected rejected_json))
        | None -> (
            match actor_for_keeper state_after_spawn keeper_name with
            | Some current_actor -> (
                let* rejected_json =
                  reject ~reason_code:"keeper_already_controls_actor"
                    ~reason:
                      (Printf.sprintf "keeper=%s already controls actor=%s"
                         keeper_name current_actor)
                    ~importance_score:48
                in
                Ok (`Rejected rejected_json))
            | None ->
                let claim_payload =
                  `Assoc
                    [
                      ("actor_id", `String actor_id);
                      ("keeper_name", `String keeper_name);
                      ("claimed_by", `String ctx.agent_name);
                      ("source", `String "mid_join");
                    ]
                in
                let* claim_event =
                  append_event ~store ~room_id
                    ~event_type:Trpg.Engine_event.Actor_claimed ~actor_id
                    ~payload:claim_payload ()
                in
                let* d = derive_state ~store ~room_id ~rule_module in
                Ok (`Proceed (false, Some claim_event, state_of_derived d)))
      in
      match claim_resolution with
      | `Rejected json -> Ok json
      | `Proceed (already_claimed, claim_event_opt, state_after_claim) ->
          let* penalty_event_opt, _state_after_penalty =
            if actor_role <> "player" then Ok (None, state_after_claim)
            else
              let actor_json =
                state_after_claim |> member "party" |> member actor_id
              in
              let max_hp =
                actor_json |> member "max_hp" |> to_int_option
                |> Option.value ~default:10
              in
              let hp =
                actor_json |> member "hp" |> to_int_option
                |> Option.value ~default:max_hp
              in
              let penalty_hp_target =
                max 1 (int_of_float (float_of_int max_hp *. 0.7))
              in
              let penalty_hp = min hp penalty_hp_target in
              let actor_patch =
                `Assoc
                  [
                    ("hp", `Int penalty_hp);
                    ("late_join_penalty", `Bool true);
                    ("late_join_penalty_turns", `Int 2);
                  ]
              in
              let payload =
                `Assoc
                  [
                    ("actor_id", `String actor_id);
                    ("actor_patch", actor_patch);
                    ("updated_by", `String ctx.agent_name);
                    ("source", `String "mid_join_penalty");
                  ]
              in
              let* penalty_event =
                append_event ~store ~room_id
                  ~event_type:Trpg.Engine_event.Actor_updated ~actor_id
                  ~payload ()
              in
              let* d = derive_state ~store ~room_id ~rule_module in
              Ok (Some penalty_event, state_of_derived d)
          in
          let granted_payload =
            `Assoc
              [
                ("actor_id", `String actor_id);
                ("keeper_name", `String keeper_name);
                ("actor_role", `String actor_role);
                ("already_claimed", `Bool already_claimed);
                ("required_points", `Int gate.min_points);
                ("effective_score", `Int effective_score);
                ("source", `String "hard_gate");
              ]
          in
          let* granted_event =
            append_event ~store ~room_id
              ~event_type:Trpg.Engine_event.Mid_join_granted ~actor_id
              ~payload:granted_payload ()
          in
          let* memory_event =
            append_memory_signal_event ~store ~room_id ~event_tier:"mid"
              ~importance_score:72
              ~summary_ko:
                (Printf.sprintf "중간 참여 승인: %s (%s)" actor_id keeper_name)
              ~summary_en:
                (Printf.sprintf "Mid-join granted: %s (%s)" actor_id keeper_name)
              ~entity_refs:
                [
                  ("actor_id", `String actor_id);
                  ("keeper_name", `String keeper_name);
                  ("effective_score", `Int effective_score);
                ]
          in
          let* final_derived = derive_state ~store ~room_id ~rule_module in
          let events =
            [
              Some requested_event;
              spawn_event_opt;
              claim_event_opt;
              penalty_event_opt;
              Some granted_event;
              Some memory_event;
            ]
            |> List.filter_map (fun x -> x)
            |> List.map Trpg.Engine_event.to_yojson
          in
          Ok
            (`Assoc
              [
                ("ok", `Bool true);
                ("room_id", `String room_id);
                ("actor_id", `String actor_id);
                ("keeper_name", `String keeper_name);
                ("granted", `Bool true);
                ( "status",
                  `String
                    (if already_claimed then "already_claimed" else "joined")
                );
                ("required_points", `Int gate.min_points);
                ("server_score", `Int server_score);
                ("keeper_bonus", `Int keeper_eval.bonus);
                ("effective_score", `Int effective_score);
                ("score_reasons", json_of_strings score_reasons);
                ("judge_source", `String keeper_eval.source);
                ( "judge_warning",
                  Option.fold ~none:`Null
                    ~some:(fun v -> `String v)
                    keeper_eval.warning );
                ("events", `List events);
                ("state", state_of_derived final_derived);
              ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_intervention_submit ctx args : result =
  let ( let* ) = Result.bind in
  let store = ctx.store in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* session_id_opt = get_optional_string args "session_id" in
    let* intervention_type = get_required_string args "intervention_type" in
    let* scope_opt = get_optional_string args "scope" in
    let scope = scope_opt |> Option.value ~default:"turn.before" in
    let* target_actor = get_optional_string args "target_actor" in
    let* expected_turn = get_optional_int args "expected_turn" in
    let* reason = get_optional_string args "reason" in
    let* payload_opt = get_optional_object args "payload" in
    let intervention_id =
      Printf.sprintf "intrv-%Ld"
        (Int64.of_float (Time_compat.now () *. 1000.0))
    in
    let payload =
      `Assoc
        [
          ("intervention_id", `String intervention_id);
          ("intervention_type", `String intervention_type);
          ("scope", `String scope);
          ("session_id", Option.fold ~none:`Null ~some:(fun v -> `String v) session_id_opt);
          ("target_actor", Option.fold ~none:`Null ~some:(fun v -> `String v) target_actor);
          ("expected_turn", Option.fold ~none:`Null ~some:(fun v -> `Int v) expected_turn);
          ("reason", Option.fold ~none:`Null ~some:(fun v -> `String v) reason);
          ("payload", Option.value ~default:(`Assoc []) payload_opt);
          ("status", `String "pending");
          ("submitted_by", `String ctx.agent_name);
        ]
    in
    let* event =
      append_event ~store ~room_id
        ~event_type:Trpg.Engine_event.Intervention_submitted
        ~actor_id:ctx.agent_name ~payload ()
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("room_id", `String room_id);
          ("intervention_id", `String intervention_id);
          ("status", `String "pending");
          ("event", Trpg.Engine_event.to_yojson event);
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let take_first_n n xs =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: tl -> loop (remaining - 1) (x :: acc) tl
  in
  loop n [] xs

let compact_summary_text ?(max_len = 96) raw =
  let compact =
    raw |> String.trim |> String.split_on_char '\n'
    |> List.map String.trim |> List.filter (fun s -> s <> "")
    |> String.concat " "
  in
  if compact = "" then ""
  else if String.length compact <= max_len then compact
  else String.sub compact 0 (max_len - 1) ^ "…"

let json_member_nonempty_string json key =
  match json |> member key with
  | `String raw ->
      let value = String.trim raw in
      if value = "" then None else Some value
  | _ -> None

let json_member_int_value json key =
  match json |> member key with
  | `Int value -> Some value
  | `Intlit value -> int_of_string_opt value
  | `Float value -> Some (int_of_float value)
  | _ -> None

let json_member_bool_value json key =
  match json |> member key with `Bool value -> Some value | _ -> None

let first_some a b = match a with Some _ -> a | None -> b
let option_filter f = function Some value when f value -> Some value | _ -> None

let status_non_ok_detail (status_json : Yojson.Safe.t) : string option =
  let status_name =
    status_json |> member "status" |> to_string_option
    |> Option.value ~default:""
    |> String.trim |> String.lowercase_ascii
  in
  if status_name = "" || status_name = "ok" then None
  else
    let actor_id =
      status_json |> member "actor_id" |> to_string_option
      |> Option.value ~default:"-" |> String.trim
    in
    let stage =
      status_json |> member "stage" |> to_string_option
      |> Option.value ~default:"" |> String.trim
    in
    let reason =
      json_member_nonempty_string status_json "reason"
      |> first_some (json_member_nonempty_string status_json "error")
      |> first_some (json_member_nonempty_string status_json "reply")
      |> Option.map (compact_summary_text ~max_len:120)
    in
    let head = Printf.sprintf "%s=%s" actor_id status_name in
    let with_stage =
      if stage = "" then head else Printf.sprintf "%s @%s" head stage
    in
    Some
      (match reason with
      | Some detail when detail <> "" ->
          Printf.sprintf "%s (%s)" with_stage detail
      | _ -> with_stage)

let status_first_non_ok_detail (statuses : Yojson.Safe.t list) : string option =
  let rec loop = function
    | [] -> None
    | status_json :: tl -> (
        match status_non_ok_detail status_json with
        | Some detail -> Some detail
        | None -> loop tl )
  in
  loop statuses

let status_first_non_ok_detail_for_role ~role (statuses : Yojson.Safe.t list) :
    string option =
  let wanted_role = String.lowercase_ascii (String.trim role) in
  let rec loop = function
    | [] -> None
    | status_json :: tl ->
        let role_name =
          status_json |> member "role" |> to_string_option
          |> Option.value ~default:""
          |> String.trim |> String.lowercase_ascii
        in
        if role_name <> wanted_role then loop tl
        else
          match status_non_ok_detail status_json with
          | Some detail -> Some detail
          | None -> loop tl
  in
  loop statuses

let status_non_ok_detail_list_for_role ~role ~max_items
    (statuses : Yojson.Safe.t list) : string list =
  let wanted_role = String.lowercase_ascii (String.trim role) in
  let rec loop acc remaining = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | status_json :: tl ->
        let role_name =
          status_json |> member "role" |> to_string_option
          |> Option.value ~default:""
          |> String.trim |> String.lowercase_ascii
        in
        if role_name <> wanted_role then loop acc remaining tl
        else
          match status_non_ok_detail status_json with
          | Some detail -> loop (detail :: acc) (remaining - 1) tl
          | None -> loop acc remaining tl
  in
  loop [] max_items statuses

let count_event_type_in_list event_type (events : Trpg.Engine_event.t list) =
  List.fold_left
    (fun acc (event : Trpg.Engine_event.t) ->
      if event.event_type = event_type then acc + 1 else acc)
    0 events

let count_npc_attacks_in_list (events : Trpg.Engine_event.t list) =
  List.fold_left
    (fun acc (event : Trpg.Engine_event.t) ->
      if event.event_type <> Trpg.Engine_event.Combat_attack then acc
      else
        let actor_id =
          json_member_nonempty_string event.payload "actor_id"
          |> first_some
               (event.actor_id
               |> Option.map String.trim
               |> option_filter (fun value -> value <> ""))
          |> Option.value ~default:""
          |> String.lowercase_ascii
        in
        if String.starts_with ~prefix:"npc-" actor_id then acc + 1 else acc)
    0 events

let structured_memory_decision_of_event (event : Trpg.Engine_event.t) :
    Yojson.Safe.t option =
  if event.event_type <> Trpg.Engine_event.Memory_signal then None
  else
    match event.payload |> member "entity_refs" with
    | `Assoc _ as refs -> (
        match refs |> member "source" with
        | `String "structured_action" ->
            Some
              (`Assoc
                [
                  ( "requested_tier",
                    match refs |> member "requested_tier" with
                    | `String tier -> `String tier
                    | _ -> `Null );
                  ( "effective_tier",
                    match refs |> member "effective_tier" with
                    | `String tier -> `String tier
                    | _ -> `Null );
                  ( "floor_tier",
                    match refs |> member "floor_tier" with
                    | `String tier -> `String tier
                    | _ -> `Null );
                  ( "guardrail_applied",
                    match refs |> member "guardrail_applied" with
                    | `Bool b -> `Bool b
                    | _ -> `Bool false );
                ])
        | _ -> None)
    | _ -> None

let memory_status_fields_of_action_events (events : Trpg.Engine_event.t list) :
    (string * Yojson.Safe.t) list =
  let decision =
    events |> List.find_map structured_memory_decision_of_event
  in
  match decision with
  | None ->
      [
        ("memory_requested_tier", `Null);
        ("memory_effective_tier", `Null);
        ("memory_floor_tier", `Null);
        ("memory_guardrail_applied", `Bool false);
      ]
  | Some memory_json ->
      [
        ("memory_requested_tier", memory_json |> member "requested_tier");
        ("memory_effective_tier", memory_json |> member "effective_tier");
        ("memory_floor_tier", memory_json |> member "floor_tier");
        ("memory_guardrail_applied", memory_json |> member "guardrail_applied");
      ]

let memory_observability_from_events (events : Trpg.Engine_event.t list) :
    int * int =
  List.fold_left
    (fun (total, escalated) (event : Trpg.Engine_event.t) ->
      if event.event_type <> Trpg.Engine_event.Memory_signal then
        (total, escalated)
      else
        let escalated' =
          match event.payload |> member "entity_refs" |> member "guardrail_applied" with
          | `Bool true -> escalated + 1
          | _ -> escalated
        in
        (total + 1, escalated'))
    (0, 0) events

let build_round_roll_audit (events : Trpg.Engine_event.t list) : Yojson.Safe.t list =
  let to_json_opt_string = function Some value -> `String value | None -> `Null in
  let to_json_opt_int = function Some value -> `Int value | None -> `Null in
  let to_json_opt_bool = function Some value -> `Bool value | None -> `Null in
  let rec collect acc = function
    | [] -> List.rev acc
    | (event : Trpg.Engine_event.t) :: tl -> (
        match event.event_type with
        | Trpg.Engine_event.Dice_rolled ->
            let payload = event.payload in
            let actor_id =
              json_member_nonempty_string payload "actor_id"
              |> first_some event.actor_id
            in
            let row =
              `Assoc
                [
                  ("seq", `Int event.seq);
                  ("source", `String "dice.rolled");
                  ("actor_id", to_json_opt_string actor_id);
                  ("action", to_json_opt_string (json_member_nonempty_string payload "action"));
                  ("raw_d20", to_json_opt_int (json_member_int_value payload "raw_d20"));
                  ("bonus", to_json_opt_int (json_member_int_value payload "bonus"));
                  ("total", to_json_opt_int (json_member_int_value payload "total"));
                  ("dc", to_json_opt_int (json_member_int_value payload "dc"));
                  ("passed", to_json_opt_bool (json_member_bool_value payload "passed"));
                ]
            in
            collect (row :: acc) tl
        | Trpg.Engine_event.Combat_attack ->
            let payload = event.payload in
            let actor_id =
              json_member_nonempty_string payload "actor_id"
              |> first_some event.actor_id
            in
            let row =
              `Assoc
                [
                  ("seq", `Int event.seq);
                  ("source", `String "combat.attack");
                  ("resolved_by", `String "deterministic_damage");
                  ("actor_id", to_json_opt_string actor_id);
                  ( "target_id",
                    to_json_opt_string
                      (json_member_nonempty_string payload "target_id") );
                  ("damage", to_json_opt_int (json_member_int_value payload "damage"));
                  ("skill", to_json_opt_string (json_member_nonempty_string payload "skill"));
                  ( "action",
                    to_json_opt_string
                      (json_member_nonempty_string payload "action"
                      |> Option.map (compact_summary_text ~max_len:72)) );
                  ("hp_source_reason", `String "combat.attack");
                ]
            in
            collect (row :: acc) tl
        | _ -> collect acc tl)
  in
  collect [] events

