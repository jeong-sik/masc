open Keeper_approval_queue_rules_types

let summary_timeout_s = 30.0
let chat_context_message_limit = 20

let system_prompt =
  "You are a neutral forensic analyst helping a human operator review a keeper \
   tool-approval request. Summarize the context, surface the most important \
   uncertainties, and suggest concrete approval options. Each option should \
   include a short label, a rationale, and an optional estimated risk delta \
   (one of: low, medium, high, critical). If context collection was partial \
   (partial_context=true), raise uncertainty and call out what is missing. \
   Respond only with the requested JSON."
;;

type context_acc =
  { partial : bool
  ; notes : string list
  }

let note acc msg = { partial = true; notes = msg :: acc.notes }

let task_context config ~task_id acc =
  try
    let tasks = Workspace_query.get_tasks_safe config in
    match List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id) tasks with
    | None ->
      let acc = note acc (Printf.sprintf "task %s not found" task_id) in
      `Assoc [ "task_id", `String task_id; "found", `Bool false ], acc
    | Some task ->
      let task_goal_id =
        let index = Workspace_goal_index.build_task_goal_index_for_config config in
        match Hashtbl.find_opt index task_id with
        | Some (g :: _) -> Some g
        | _ -> None
      in
      `Assoc
        [ "task_id", `String task_id
        ; "title", `String task.title
        ; "status", `String (Masc_domain.task_status_to_string task.task_status)
        ; "goal_id", Json_util.string_opt_to_json task_goal_id
        ; "found", `Bool true
        ], acc
  with
  | exn ->
    let acc = note acc (Printf.sprintf "task %s lookup failed: %s" task_id (Printexc.to_string exn)) in
    `Assoc [ "task_id", `String task_id; "found", `Bool false ], acc
;;

let goal_context config ~goal_id acc =
  try
    match Goal_store.get_goal config ~goal_id with
    | None ->
      let acc = note acc (Printf.sprintf "goal %s not found" goal_id) in
      `Assoc [ "goal_id", `String goal_id; "found", `Bool false ], acc
    | Some goal ->
      let status_label =
        match Goal_store.goal_status_to_yojson goal.status with
        | `String s -> s
        | _ -> "unknown"
      in
      `Assoc
        [ "goal_id", `String goal_id
        ; "title", `String goal.title
        ; "phase", `String (Goal_phase.to_string goal.phase)
        ; "status", `String status_label
        ; "priority", `Int goal.priority
        ; "found", `Bool true
        ], acc
  with
  | exn ->
    let acc = note acc (Printf.sprintf "goal %s lookup failed: %s" goal_id (Printexc.to_string exn)) in
    `Assoc [ "goal_id", `String goal_id; "found", `Bool false ], acc
;;

let chat_context ~base_dir ~keeper_name ~turn_id acc =
  try
    let messages = Keeper_chat_store.load ~base_dir ~keeper_name in
    let filtered =
      List.filter
        (fun (m : Keeper_chat_store.chat_message) ->
           match m.turn_ref with
           | None -> false
           | Some tr -> Int.equal (Ids.Turn_ref.absolute_turn tr) turn_id)
        messages
    in
    let rec take n acc = function
      | [] -> List.rev acc
      | _ when n <= 0 -> List.rev acc
      | x :: xs -> take (n - 1) (x :: acc) xs
    in
    Keeper_chat_store.to_json_array (take chat_context_message_limit [] filtered), acc
  with
  | exn ->
    let acc = note acc (Printf.sprintf "chat lookup failed: %s" (Printexc.to_string exn)) in
    `List [], acc
;;

let collect_context_parts entry =
  let acc0 = { partial = false; notes = [] } in
  let config_opt, acc =
    try Some (Workspace_utils.default_config entry.audit_base_path), acc0 with
    | exn ->
      ( None
      , note acc0 (Printf.sprintf "workspace config unavailable: %s" (Printexc.to_string exn)) )
  in
  let task_json, acc =
    match entry.task_id, config_opt with
    | Some task_id, Some config -> task_context config ~task_id acc
    | Some task_id, None ->
      let acc = note acc (Printf.sprintf "task %s skipped (no workspace config)" task_id) in
      `Assoc [ "task_id", `String task_id; "found", `Bool false ], acc
    | None, _ -> `Null, acc
  in
  let goal_ids =
    (match entry.goal_id with
     | Some g -> [ g ]
     | None -> [])
    @ entry.goal_ids
    |> List.filter (fun s -> not (String.equal s ""))
    |> List.sort_uniq String.compare
  in
  let goals_json, acc =
    match config_opt with
    | Some config ->
      let goals, acc =
        List.fold_left
          (fun (goals, acc) goal_id ->
             let g, acc = goal_context config ~goal_id acc in
             g :: goals, acc)
          ([], acc)
          goal_ids
      in
      `List (List.rev goals), acc
    | None ->
      let acc =
        if goal_ids <> [] then note acc "goals skipped (no workspace config)" else acc
      in
      `List [], acc
  in
  let chat_json, acc =
    match entry.turn_id with
    | Some turn_id ->
      chat_context ~base_dir:entry.audit_base_path ~keeper_name:entry.keeper_name ~turn_id acc
    | None -> `Null, acc
  in
  let acc = note acc "board signals skipped (not easily accessible)" in
  task_json, goals_json, chat_json, acc.partial, acc.notes
;;

let build_context_bundle ~(entry : pending_approval) : Yojson.Safe.t =
  let task_json, goals_json, chat_json, partial_context, context_notes =
    collect_context_parts entry
  in
  `Assoc
    [ "keeper_name", `String entry.keeper_name
    ; "tool_name", `String entry.tool_name
    ; "action_key", `String entry.action_key
    ; "risk_level", `String (risk_level_to_string entry.risk_level)
    ; "sandbox_target", `String entry.sandbox_target
    ; "turn_id", Json_util.int_opt_to_json entry.turn_id
    ; "task_id", Json_util.string_opt_to_json entry.task_id
    ; "goal_id", Json_util.string_opt_to_json entry.goal_id
    ; "goal_ids", `List (List.map (fun g -> `String g) entry.goal_ids)
    ; "input", entry.input
    ; "task", task_json
    ; "goals", goals_json
    ; "chat_messages", chat_json
    ; "board_signals", `Null
    ; "partial_context", `Bool partial_context
    ; "context_notes", `List (List.rev_map (fun s -> `String s) context_notes)
    ]
;;

let message role text = Agent_sdk.Types.text_message role text

let messages_for_summary ~context_bundle =
  [ message Agent_sdk.Types.System system_prompt
  ; message Agent_sdk.Types.User (Yojson.Safe.to_string context_bundle)
  ]
;;

let call_summary_llm ~sw ~net ~provider_config ~context_bundle () =
  let config =
    provider_config
    |> Keeper_structured_output_schema.apply_hitl_summary_schema_to_config
  in
  let messages = messages_for_summary ~context_bundle in
  Keeper_llm_bridge.run_with_timeout_and_fallback
    ~timeout_s:summary_timeout_s
    (fun () ->
       Llm_provider.Complete.complete ~sw ~net ~config ~messages ()
       |> Result.map_error (fun http_err ->
            Agent_sdk.Error.Internal (Provider_http_error.to_message http_err)))
;;

let parse_suggested_option json =
  let open Yojson.Safe.Util in
  let label = json |> member "label" |> to_string in
  let rationale = json |> member "rationale" |> to_string in
  let estimated_risk_delta =
    match json |> member "estimated_risk_delta" with
    | `Null -> None
    | `String s -> risk_level_of_string s
    | _ -> None
  in
  { label; rationale; estimated_risk_delta }
;;

let parse_summary ~model_run_id json =
  let open Yojson.Safe.Util in
  { summary_version = 1
  ; generated_at = Unix.gettimeofday ()
  ; model_run_id
  ; context_summary = json |> member "context_summary" |> to_string
  ; key_questions = json |> member "key_questions" |> convert_each to_string
  ; suggested_options = json |> member "suggested_options" |> convert_each parse_suggested_option
  ; risk_rationale = json |> member "risk_rationale" |> to_string_option
  ; uncertainty = json |> member "uncertainty" |> to_float
  }
;;

let summary_of_response (response : Agent_sdk.Types.api_response) =
  match
    Agent_sdk_response.structured_json_of_response
      ~schema_name:"hitl_context_summary"
      response
  with
  | Ok json ->
    (try Ok (parse_summary ~model_run_id:response.id json) with
     | exn ->
       Error (Printf.sprintf "HITL summary parse failed: %s" (Printexc.to_string exn)))
  | Error detail ->
    Error (Printf.sprintf "HITL summary structured response parse failed: %s" detail)
;;

let spawn ~sw ?provider_config ~(entry : pending_approval) ~on_summary ~on_failure () =
  match provider_config with
  | None -> on_failure ~reason:"HITL summary: no provider config available" ~retryable:false
  | Some provider_config ->
    Eio.Fiber.fork ~sw (fun () ->
      try
        let context_bundle = build_context_bundle ~entry in
        match Eio_context.get_net_opt () with
        | None -> on_failure ~reason:"HITL summary worker: Eio net unavailable" ~retryable:true
        | Some net ->
          (match call_summary_llm ~sw ~net ~provider_config ~context_bundle () with
           | Ok response ->
             (match summary_of_response response with
              | Ok summary -> on_summary summary
              | Error reason -> on_failure ~reason ~retryable:true)
           | Error err ->
             on_failure ~reason:(Agent_sdk.Error.to_string err) ~retryable:true)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Keeper.warn
          "HITL summary worker crashed approval_id=%s err=%s"
          entry.id
          (Printexc.to_string exn);
        on_failure ~reason:(Printexc.to_string exn) ~retryable:true)
;;

module For_testing = struct
  let build_context_bundle = build_context_bundle
  let parse_summary = parse_summary
  let summary_of_response = summary_of_response
end
;;
