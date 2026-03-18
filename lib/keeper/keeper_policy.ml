(** Keeper_policy — keeper policy, autonomy, and evaluation handlers. *)

open Tool_args
open Keeper_types
open Keeper_memory
open Keeper_exec_persona

type tool_result = Keeper_types.tool_result

let handle_keeper_policy_set ctx args : tool_result =
  let name = get_string args "name" "" in
  let policy_mode_raw = get_string args "policy_mode" "" |> String.trim in
  let action_budget_opt = get_string_opt args "action_budget" |> Option.map String.trim in
  let reward_model_path =
    get_string_opt args "reward_model_path" |> Option.value ~default:"" |> String.trim
  in
  let policy_mode_result =
    if policy_mode_raw = "" then
      Error "policy_mode is required"
    else
      match Keeper_contract.parse_policy_mode policy_mode_raw with
      | Some mode -> Ok mode
      | None -> Error (Printf.sprintf "invalid policy_mode: %s" policy_mode_raw)
  in
  let action_budget_result =
    match action_budget_opt with
    | None -> Ok Keeper_contract.Conversation
    | Some raw -> (
        match Keeper_contract.parse_policy_action_budget raw with
        | Some budget -> Ok budget
        | None -> Error (Printf.sprintf "invalid action_budget: %s" raw))
  in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else if Result.is_error policy_mode_result then
    (false, "❌ " ^ Result.get_error policy_mode_result)
  else if Result.is_error action_budget_result then
    (false, "❌ " ^ Result.get_error action_budget_result)
  else
    let policy_mode = Result.get_ok policy_mode_result in
    let action_budget = Result.get_ok action_budget_result in
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some meta) ->
        let effective_reward_model_path_raw =
          if reward_model_path <> "" then reward_model_path else meta.policy_reward_model_path
        in
        let effective_reward_model_path =
          if effective_reward_model_path_raw <> ""
             && Filename.is_relative effective_reward_model_path_raw
          then
            Filename.concat ctx.config.base_path effective_reward_model_path_raw
          else
            effective_reward_model_path_raw
        in
        if Keeper_contract.policy_mode_is_learned policy_mode then
          match load_keeper_reward_model effective_reward_model_path with
          | Error e -> (false, "❌ " ^ e)
          | Ok reward_model ->
              let updated =
                {
                  meta with
                  policy_mode = Keeper_contract.policy_mode_to_string policy_mode;
                  policy_action_budget =
                    Keeper_contract.policy_action_budget_to_string action_budget;
                  policy_reward_model_path = reward_model.path;
                  updated_at = now_iso ();
                }
              in
              (match write_meta ctx.config updated with
               | Error e -> (false, "❌ " ^ e)
               | Ok () ->
                   ( true,
                     Yojson.Safe.pretty_to_string
                       (`Assoc
                         [
                           ("name", `String updated.name);
                           ("policy_mode", `String updated.policy_mode);
                           ("action_budget", `String updated.policy_action_budget);
                           ("reward_model_path", `String updated.policy_reward_model_path);
                           ("reward_model_version", `String reward_model.version);
                         ]) ))
        else
          let updated =
            {
              meta with
              policy_mode = Keeper_contract.policy_mode_to_string policy_mode;
              policy_action_budget =
                Keeper_contract.policy_action_budget_to_string action_budget;
              policy_reward_model_path = effective_reward_model_path;
              updated_at = now_iso ();
            }
          in
          match write_meta ctx.config updated with
          | Error e -> (false, "❌ " ^ e)
          | Ok () ->
              ( true,
                Yojson.Safe.pretty_to_string
                  (`Assoc
                    [
                      ("name", `String updated.name);
                      ("policy_mode", `String updated.policy_mode);
                      ("action_budget", `String updated.policy_action_budget);
                      ("reward_model_path",
                        if String.trim updated.policy_reward_model_path = ""
                        then `Null
                        else `String updated.policy_reward_model_path);
                    ]) )

let handle_keeper_feedback_record ctx args : tool_result =
  let name = get_string args "name" "" in
  let action_id = get_string args "action_id" "" |> String.trim in
  let verdict = get_string args "verdict" "" |> String.trim in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else if action_id = "" then
    (false, "❌ action_id is required")
  else if verdict = "" then
    (false, "❌ verdict is required")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some meta) ->
        let score_json =
          match Yojson.Safe.Util.member "score" args with
          | `Float score -> Some (`Float score)
          | `Int n -> Some (`Float (float_of_int n))
          | `Intlit raw ->
              Some (`Float (Safe_ops.float_of_string_with_default ~default:0.0 raw))
          | _ -> None
        in
        let note = get_string_opt args "note" |> Option.value ~default:"" |> String.trim in
        let json =
          `Assoc
            [
              ("ts", `String (now_iso ()));
              ("ts_unix", `Float (Time_compat.now ()));
              ("keeper", `String name);
              ("trace_id", `String meta.trace_id);
              ("action_id", `String action_id);
              ("verdict", `String verdict);
              ("score", Option.value ~default:`Null score_json);
              ("note", if note = "" then `Null else `String note);
            ]
        in
        append_jsonl_line (keeper_feedback_log_path ctx.config name) json;
        (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_dataset_export ctx args : tool_result =
  let name = get_string args "name" "" in
  let limit = max 1 (get_int args "limit" 200) in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some meta) ->
        let policy_rows =
          read_jsonl_rows
            (keeper_policy_log_path ctx.config name)
            ~max_bytes:600000
            ~max_lines:limit
        in
        let feedback_rows =
          read_jsonl_rows
            (keeper_feedback_log_path ctx.config name)
            ~max_bytes:400000
            ~max_lines:(limit * 4)
        in
        let feedback_by_action =
          List.fold_left
            (fun acc json ->
              match Safe_ops.json_string_opt "action_id" json with
              | Some action_id when String.trim action_id <> "" ->
                  let current =
                    acc
                    |> List.find_map (fun (key, value) ->
                           if key = action_id then Some value else None)
                    |> Option.value ~default:[]
                  in
                  (action_id, json :: current)
                  :: List.filter (fun (key, _) -> key <> action_id) acc
              | _ -> acc)
            []
            feedback_rows
        in
        let examples =
          policy_rows
          |> List.map (fun row ->
                 let action_id =
                   Safe_ops.json_string_opt "action_id" row |> Option.value ~default:""
                 in
                 let feedback =
                   feedback_by_action
                   |> List.find_map (fun (key, rows) ->
                          if key = action_id then Some (List.rev rows) else None)
                   |> Option.value ~default:[]
                 in
                 `Assoc
                   [
                     ("action", row);
                     ("feedback", `List feedback);
                   ])
        in
        let output_path =
          get_string_opt args "output_path"
          |> Option.value ~default:(keeper_dataset_export_path ctx.config name)
        in
        let resolved_output_path =
          if Filename.is_relative output_path then
            Filename.concat ctx.config.base_path output_path
          else
            output_path
        in
        Fs_compat.mkdir_p (Filename.dirname resolved_output_path);
        let json =
          `Assoc
            [
              ("keeper", `String name);
              ("trace_id", `String meta.trace_id);
              ("exported_at", `String (now_iso ()));
              ("policy_row_count", `Int (List.length policy_rows));
              ("feedback_row_count", `Int (List.length feedback_rows));
              ("examples", `List examples);
            ]
        in
        Fs_compat.save_file resolved_output_path (Yojson.Safe.pretty_to_string json);
        ( true,
          Yojson.Safe.pretty_to_string
            (`Assoc
              [
                ("keeper", `String name);
                ("output_path", `String resolved_output_path);
                ("policy_row_count", `Int (List.length policy_rows));
                ("feedback_row_count", `Int (List.length feedback_rows));
              ]) )

let handle_keeper_action_explain ctx args : tool_result =
  let name = get_string args "name" "" in
  let action_id = get_string_opt args "action_id" |> Option.value ~default:"" |> String.trim in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some _) ->
        let rows =
          read_jsonl_rows
            (keeper_policy_log_path ctx.config name)
            ~max_bytes:400000
            ~max_lines:120
        in
        let selected =
          if action_id = "" then
            match List.rev rows with row :: _ -> Some row | [] -> None
          else
            find_jsonl_row_by_action_id rows action_id
        in
        (match selected with
         | None -> (false, "❌ no policy action found")
         | Some row -> (true, Yojson.Safe.pretty_to_string row))

let handle_keeper_eval_replay ctx args : tool_result =
  let name = get_string args "name" "" in
  let limit = max 1 (get_int args "limit" 50) in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some meta) -> (
        match load_keeper_reward_model meta.policy_reward_model_path with
        | Error e -> (false, "❌ " ^ e)
        | Ok reward_model ->
            let rows =
              read_jsonl_rows
                (keeper_policy_log_path ctx.config name)
                ~max_bytes:500000
                ~max_lines:limit
            in
            let replayed =
              rows
              |> List.filter_map (fun row ->
                     let feature_vector =
                       match Yojson.Safe.Util.member "feature_vector" row with
                       | `Assoc fields ->
                           fields
                           |> List.filter_map (fun (feature, value) ->
                                  match value with
                                  | `Float v -> Some (feature, v)
                                  | `Int n -> Some (feature, float_of_int n)
                                  | _ -> None)
                       | _ -> []
                     in
                     let chosen_action = Safe_ops.json_string_opt "chosen_action" row in
                     let observation = Yojson.Safe.Util.member "observation" row in
                     let direct_mention =
                       Safe_ops.json_bool ~default:false "direct_mention" observation
                     in
                     let heuristic_action =
                       deterministic_policy_baseline_action
                         {
                           source_kind =
                             Safe_ops.json_string ~default:"room_message" "source_kind" observation;
                           room_id = Safe_ops.json_string_opt "room_id" observation;
                           from_agent =
                             Safe_ops.json_string ~default:"" "from_agent" observation;
                           message =
                             Safe_ops.json_string ~default:"" "message" observation;
                           direct_mention;
                           has_question =
                             Safe_ops.json_bool ~default:false "has_question" observation;
                           message_chars =
                             Safe_ops.json_int ~default:0 "message_chars" observation;
                           total_turns =
                             Safe_ops.json_int ~default:0 "total_turns" observation;
                           active_goal_count =
                             Safe_ops.json_int ~default:0 "active_goal_count" observation;
                           joined_room_count =
                             Safe_ops.json_int ~default:0 "joined_room_count" observation;
                           room_scope =
                             Safe_ops.json_string ~default:"current" "room_scope" observation
                             |> Keeper_contract.room_scope_of_string;
                           trigger_mode =
                             Safe_ops.json_string ~default:"legacy" "trigger_mode" observation
                             |> Keeper_contract.trigger_mode_of_string;
                           last_turn_ago_s =
                             Safe_ops.json_float ~default:0.0 "last_turn_ago_s" observation;
                         }
                     in
                     let candidate_names =
                       match Yojson.Safe.Util.member "candidates" row with
                       | `List xs ->
                           xs
                           |> List.filter_map (fun candidate ->
                                  Safe_ops.json_string_opt "action" candidate)
                       | _ -> []
                     in
                     let rescored =
                       candidate_names
                       |> List.map (fun action ->
                              score_keeper_policy_candidate
                                ~model:reward_model
                                ~features:feature_vector
                                ~action
                                ~allowed:true)
                     in
                     choose_policy_action rescored
                     |> Option.map (fun learned_candidate ->
                            `Assoc
                              [
                                ("action_id",
                                  match Safe_ops.json_string_opt "action_id" row with
                                  | Some value -> `String value
                                  | None -> `Null);
                                ("chosen_action",
                                  match chosen_action with
                                  | Some value -> `String value
                                  | None -> `Null);
                                ("heuristic_action", `String heuristic_action);
                                ("replayed_action", `String learned_candidate.action);
                                ("replayed_score", `Float learned_candidate.score);
                                ("matches_logged",
                                  `Bool
                                    (match chosen_action with
                                     | Some value -> value = learned_candidate.action
                                     | None -> false));
                                ("differs_from_heuristic",
                                  `Bool (heuristic_action <> learned_candidate.action));
                              ]))
            in
            let matches_logged =
              replayed
              |> List.fold_left
                   (fun acc json ->
                     if Safe_ops.json_bool ~default:false "matches_logged" json then acc + 1
                     else acc)
                   0
            in
            let differs_from_heuristic =
              replayed
              |> List.fold_left
                   (fun acc json ->
                     if Safe_ops.json_bool ~default:false "differs_from_heuristic" json then acc + 1
                     else acc)
                   0
            in
            let json =
              `Assoc
                [
                  ("keeper", `String name);
                  ("reward_model_path", `String reward_model.path);
                  ("reward_model_version", `String reward_model.version);
                  ("replayed_count", `Int (List.length replayed));
                  ("matches_logged_count", `Int matches_logged);
                  ("differs_from_heuristic_count", `Int differs_from_heuristic);
                  ("entries", `List replayed);
                ]
            in
            (true, Yojson.Safe.pretty_to_string json))

let handle_keeper_autonomy ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "read error: " ^ e)
    | Ok None -> (false, Printf.sprintf "keeper not found: %s" name)
    | Ok (Some m) ->
      let level_opt = get_string_opt args "level" in
      (match level_opt with
       | None ->
         (* GET mode: return current autonomy info *)
         let info = Printf.sprintf
           "Keeper: %s\nAutonomy Level: %s\nActive Goals: [%s]\nAutonomous Actions: %d\nLast Autonomous Action: %s"
           m.name
           (match Keeper_contract.parse_autonomy_level m.autonomy_level with
            | Some level -> Keeper_autonomy.autonomy_level_to_string level
            | None -> m.autonomy_level)
           (String.concat ", " m.active_goal_ids)
           m.autonomous_action_count
           (if m.last_autonomous_action_at = "" then "never" else m.last_autonomous_action_at)
         in
         (true, info)
       | Some level_str ->
         (* SET mode: validate and update autonomy level *)
         match Keeper_autonomy.autonomy_level_of_string level_str with
         | None ->
             (false, Printf.sprintf "invalid autonomy level: %s (use L1_Reactive..L5_Independent)" level_str)
         | Some al ->
             let canonical = Keeper_autonomy.autonomy_level_to_string al in
             let updated =
               { m with autonomy_level = Keeper_contract.autonomy_level_to_storage_string al }
             in
             (match write_meta ctx.config updated with
             | Error e -> (false, "write error: " ^ e)
             | Ok () ->
                 (true, Printf.sprintf "Keeper %s autonomy level updated to %s" name canonical)))

let handle_keeper_goals ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "read error: " ^ e)
    | Ok None -> (false, Printf.sprintf "keeper not found: %s" name)
    | Ok (Some m) ->
      let action = get_string_opt args "action" in
      (match action with
       | None ->
         (* LIST mode: show active goals with details *)
         let goals = Goal_store.list_goals ctx.config () in
         let active =
           List.filter
             (fun (g : Goal_store.goal) -> List.mem g.id m.active_goal_ids)
             goals
         in
         if active = [] then
           (true, Printf.sprintf "Keeper %s has no active goals." name)
         else
           let lines =
             List.map
               (fun (g : Goal_store.goal) ->
                 Printf.sprintf "- [%s] %s (horizon:%s, priority:%d, status:%s)"
                   g.id g.title g.horizon g.priority g.status)
               active
           in
           (true, Printf.sprintf "Keeper %s goals (%d):\n%s"
              name (List.length active) (String.concat "\n" lines))
       | Some "link" ->
         let goal_id = get_string args "goal_id" "" in
         if goal_id = "" then
           (false, "goal_id is required for link action")
         else if List.mem goal_id m.active_goal_ids then
           (true, Printf.sprintf "Goal %s already linked to keeper %s" goal_id name)
         else begin
           (* Verify goal exists *)
           let goals = Goal_store.list_goals ctx.config () in
           match List.find_opt (fun (g : Goal_store.goal) -> g.id = goal_id) goals with
           | None -> (false, Printf.sprintf "Goal %s not found in goal_store" goal_id)
           | Some g ->
             let updated = { m with active_goal_ids = goal_id :: m.active_goal_ids } in
             (match write_meta ctx.config updated with
              | Error e -> (false, "write error: " ^ e)
              | Ok () ->
                (true, Printf.sprintf "Linked goal [%s] %s to keeper %s" g.id g.title name))
         end
       | Some "unlink" ->
         let goal_id = get_string args "goal_id" "" in
         if goal_id = "" then
           (false, "goal_id is required for unlink action")
         else if not (List.mem goal_id m.active_goal_ids) then
           (true, Printf.sprintf "Goal %s not linked to keeper %s" goal_id name)
         else
           let updated = { m with
             active_goal_ids = List.filter (fun gid -> gid <> goal_id) m.active_goal_ids
           } in
           (match write_meta ctx.config updated with
            | Error e -> (false, "write error: " ^ e)
            | Ok () ->
              (true, Printf.sprintf "Unlinked goal %s from keeper %s" goal_id name))
       | Some other ->
         (false, Printf.sprintf "unknown action: %s (use link | unlink)" other))
