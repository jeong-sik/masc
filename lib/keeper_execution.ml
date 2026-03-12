(** Keeper_execution — tool-call execution loop, LLM system prompts,
    metrics summarization, agent diagnostics, constitution, context
    checkpoint management, proactive reply generation, and autonomous
    goal turns. *)

include Keeper_alerting

let execute_keeper_tool_call
    ~(config : Room.config)
    ~(meta : keeper_meta)
    ~(ctx_work : Context_manager.working_context)
    (tc : Llm_client.tool_call) : string =
  let args =
    try Yojson.Safe.from_string tc.call_arguments
    with Yojson.Json_error _ -> `Assoc []
  in
  let now_ts = Time_compat.now () in
  match tc.call_name with
  | "keeper_time_now" ->
      Yojson.Safe.to_string (`Assoc [
        ("now_iso", `String (now_iso ()));
        ("now_unix", `Float now_ts);
      ])
  | "keeper_context_status" ->
      let continuity = latest_state_snapshot_from_messages ctx_work.messages in
      let continuity_summary =
        match continuity with
        | None ->
            let trimmed = String.trim meta.continuity_summary in
            if trimmed = "" then "No continuity snapshot available." else trimmed
        | Some snapshot -> keeper_state_snapshot_to_summary_text snapshot
      in
      Yojson.Safe.to_string (`Assoc [
        ("name", `String meta.name);
        ("trace_id", `String meta.trace_id);
        ("generation", `Int meta.generation);
        ("context_ratio", `Float (Context_manager.context_ratio ctx_work));
        ("context_tokens", `Int ctx_work.token_count);
        ("context_max", `Int ctx_work.max_tokens);
        ("message_count", `Int (List.length ctx_work.messages));
        ("last_model_used", `String meta.last_model_used);
        ("continuity_state",
          match continuity with
          | None -> `Null
          | Some snapshot -> keeper_state_snapshot_to_json snapshot);
        ("continuity_summary",
          `String
            continuity_summary)
      ])
  | "keeper_memory_search" ->
      let query = Safe_ops.json_string ~default:"" "query" args |> String.trim in
      let limit = max 1 (min 8 (Safe_ops.json_int ~default:5 "limit" args)) in
      let user_msgs = extract_user_messages ctx_work in
      let matches =
        user_msgs
        |> List.filter (fun msg -> query <> "" && contains_ci msg query)
        |> List.rev
        |> take limit
        |> List.map (fun msg -> `String msg)
      in
      Yojson.Safe.to_string (`Assoc [
        ("query", `String query);
        ("match_count", `Int (List.length matches));
        ("matches", `List matches);
      ])
  | "keeper_weather_note" ->
      let location = Safe_ops.json_string ~default:"current location" "location" args in
      let recent_weather_questions =
        extract_user_messages ctx_work
        |> List.filter is_weather_text
        |> List.rev
        |> take 5
        |> List.map (fun q -> `String q)
      in
      Yojson.Safe.to_string (`Assoc [
        ("location", `String location);
        ("capability", `String "no_realtime_weather_feed");
        ("note", `String "This keeper cannot fetch live weather by itself.");
        ("recent_weather_questions", `List recent_weather_questions);
      ])
  (* Board tools — delegate to Tool_board with keeper name as author *)
  | "keeper_board_post" ->
      let author = meta.name in
      Printf.eprintf "[TRPG-TRACE] keeper_board_post called by %s, raw args: %s\n%!"
        author (Yojson.Safe.to_string args);
      let board_args = match args with
        | `Assoc fields ->
            (* Inject author from keeper meta, override if LLM set it *)
            let fields' = List.filter (fun (k, _) -> k <> "author") fields in
            `Assoc (("author", `String author) :: fields')
        | other -> other
      in
      Printf.eprintf "[TRPG-TRACE] board_args: %s\n%!" (Yojson.Safe.to_string board_args);
      let (ok, msg) = Tool_board.handle_tool "masc_board_post" board_args in
      Printf.eprintf "[TRPG-TRACE] handle_tool result: ok=%b msg=%s\n%!" ok
        (if String.length msg > 200 then String.sub msg 0 200 ^ "..." else msg);
      if ok then msg else Yojson.Safe.to_string (`Assoc [("error", `String msg)])
  | "keeper_board_list" ->
      let (ok, msg) = Tool_board.handle_tool "masc_board_list" args in
      if ok then msg else Yojson.Safe.to_string (`Assoc [("error", `String msg)])
  | "keeper_board_comment" ->
      let author = meta.name in
      let board_args = match args with
        | `Assoc fields ->
            let fields' = List.filter (fun (k, _) -> k <> "author") fields in
            `Assoc (("author", `String author) :: fields')
        | other -> other
      in
      let (ok, msg) = Tool_board.handle_tool "masc_board_comment" board_args in
      if ok then msg else Yojson.Safe.to_string (`Assoc [("error", `String msg)])
  | "keeper_fs_read" | "keeper_read" ->
      let path = Safe_ops.json_string ~default:"" "path" args in
      let max_bytes =
        Safe_ops.json_int ~default:20000 "max_bytes" args
        |> fun n -> max 512 (min 200000 n)
      in
      (match resolve_keeper_target_path ~config ~raw_path:path with
       | Error e ->
           Yojson.Safe.to_string (`Assoc [("error", `String e)])
       | Ok target ->
           (match Safe_ops.read_file_safe target with
            | Error e ->
                Yojson.Safe.to_string (`Assoc [("error", `String e); ("path", `String target)])
            | Ok content ->
                let total = String.length content in
                let truncated = total > max_bytes in
                let body =
                  if truncated then String.sub content 0 max_bytes else content
                in
                Yojson.Safe.to_string
                  (`Assoc [
                    ("ok", `Bool true);
                    ("path", `String target);
                    ("bytes", `Int total);
                    ("truncated", `Bool truncated);
                    ("content", `String body);
                  ])))
  | "keeper_fs_edit" | "keeper_edit" ->
      let path = Safe_ops.json_string ~default:"" "path" args in
      let content = Safe_ops.json_string ~default:"" "content" args in
      let mode =
        Safe_ops.json_string ~default:"overwrite" "mode" args
        |> String.lowercase_ascii
      in
      (match resolve_keeper_target_path ~config ~raw_path:path with
       | Error e ->
           Yojson.Safe.to_string (`Assoc [("error", `String e)])
       | Ok target ->
           (try
              let parent = Filename.dirname target in
              if not (Sys.file_exists parent) then Unix.mkdir parent 0o755;
              (match mode with
               | "append" ->
                   let oc =
                     open_out_gen [Open_wronly; Open_creat; Open_append] 0o644 target
                   in
                   Common.protect
                     ~module_name:"tool_keeper"
                     ~finally_label:"keeper_fs_edit_append_close"
                     ~finally:(fun () -> close_out_noerr oc)
                     (fun () -> output_string oc content)
               | "overwrite" | "" ->
                   let oc = open_out target in
                   Common.protect
                     ~module_name:"tool_keeper"
                     ~finally_label:"keeper_fs_edit_overwrite_close"
                     ~finally:(fun () -> close_out_noerr oc)
                     (fun () -> output_string oc content)
               | other ->
                   raise (Invalid_argument ("unsupported_mode:" ^ other)));
              Yojson.Safe.to_string
                (`Assoc [
                  ("ok", `Bool true);
                  ("path", `String target);
                  ("mode", `String (if mode = "" then "overwrite" else mode));
                  ("bytes_written", `Int (String.length content));
                ])
            with
            | Invalid_argument e ->
                Yojson.Safe.to_string (`Assoc [("error", `String e); ("path", `String target)])
            | Sys_error e ->
                Yojson.Safe.to_string (`Assoc [("error", `String e); ("path", `String target)])
            | Unix.Unix_error (err, _, _) ->
                Yojson.Safe.to_string
                  (`Assoc [
                    ("error", `String (Unix.error_message err));
                    ("path", `String target);
                  ])))
  | "keeper_bash" ->
      let cmd = Safe_ops.json_string ~default:"" "cmd" args |> String.trim in
      let timeout_sec =
        Safe_ops.json_float ~default:30.0 "timeout_sec" args
        |> fun n -> max 1.0 (min 180.0 n)
      in
      if cmd = "" then Yojson.Safe.to_string (`Assoc [("error", `String "cmd_required")])
      else
        let root = project_root_of_config config in
        let shell_cmd =
          Printf.sprintf "cd %s && %s 2>&1" (Filename.quote root) cmd
        in
        let (st, out) =
          Process_eio.run_argv_with_status
            ~timeout_sec
            ["/bin/zsh"; "-lc"; shell_cmd]
        in
        Yojson.Safe.to_string
          (`Assoc [
            ("ok", `Bool (st = Unix.WEXITED 0));
            ("status", process_status_to_json st);
            ("output", `String (truncate_tool_output out));
          ])
  | "keeper_github" ->
      let cmd = Safe_ops.json_string ~default:"" "cmd" args |> String.trim in
      let gh_args = Safe_ops.json_string_list "args" args in
      let timeout_sec =
        Safe_ops.json_float ~default:30.0 "timeout_sec" args
        |> fun n -> max 1.0 (min 180.0 n)
      in
      let gh_cmd =
        if cmd <> "" then "gh " ^ cmd
        else if gh_args <> [] then
          "gh " ^ String.concat " " (List.map Filename.quote gh_args)
        else
          ""
      in
      if gh_cmd = "" then Yojson.Safe.to_string (`Assoc [("error", `String "cmd_or_args_required")])
      else
        let root = project_root_of_config config in
        let shell_cmd =
          Printf.sprintf "cd %s && %s 2>&1" (Filename.quote root) gh_cmd
        in
        let (st, out) =
          Process_eio.run_argv_with_status
            ~timeout_sec
            ["/bin/zsh"; "-lc"; shell_cmd]
        in
        Yojson.Safe.to_string
          (`Assoc [
            ("ok", `Bool (st = Unix.WEXITED 0));
            ("status", process_status_to_json st);
            ("output", `String (truncate_tool_output out));
          ])
  (* Taskboard tools — Board Gardener operations *)
  | "keeper_tasks_list" ->
      let status_filter = Safe_ops.json_string_opt "status" args in
      let include_done = Safe_ops.json_bool ~default:false "include_done" args in
      Room.list_tasks ?status:status_filter ~include_done config
  | "keeper_tasks_audit" ->
      let orphans = Room.audit_orphan_tasks config in
      let items = List.map (fun ((task : Types.task), assignee) ->
        `Assoc [
          ("task_id", `String task.id);
          ("title", `String task.title);
          ("assignee", `String assignee);
          ("status", `String (Types.string_of_task_status task.task_status));
        ]
      ) orphans in
      Yojson.Safe.to_string (`Assoc [
        ("orphan_count", `Int (List.length orphans));
        ("orphans", `List items);
      ])
  | "keeper_task_force_release" ->
      let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
      let reason = Safe_ops.json_string ~default:"" "reason" args in
      if task_id = "" then
        Yojson.Safe.to_string (`Assoc [("error", `String "task_id required")])
      else begin
        let agent = Printf.sprintf "gardener:%s" meta.name in
        let _ = Room.broadcast config ~from_agent:agent
            ~content:(Printf.sprintf "Force-releasing task %s (reason: %s)" task_id
              (if reason = "" then "no reason given" else reason)) in
        match Room.force_release_task_r config ~agent_name:agent ~task_id () with
        | Ok msg ->
            Yojson.Safe.to_string (`Assoc [("ok", `Bool true); ("result", `String msg)])
        | Error e ->
            Yojson.Safe.to_string (`Assoc [("ok", `Bool false); ("error", `String (Types.masc_error_to_string e))])
      end
  | "keeper_task_force_done" ->
      let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
      let notes = Safe_ops.json_string ~default:"" "notes" args in
      if task_id = "" then
        Yojson.Safe.to_string (`Assoc [("error", `String "task_id required")])
      else begin
        let agent = Printf.sprintf "gardener:%s" meta.name in
        match Room.force_done_task_r config ~agent_name:agent ~task_id ~notes () with
        | Ok msg ->
            Yojson.Safe.to_string (`Assoc [("ok", `Bool true); ("result", `String msg)])
        | Error e ->
            Yojson.Safe.to_string (`Assoc [("ok", `Bool false); ("error", `String (Types.masc_error_to_string e))])
      end
  | "keeper_broadcast" ->
      let message = Safe_ops.json_string ~default:"" "message" args |> String.trim in
      if message = "" then
        Yojson.Safe.to_string (`Assoc [("error", `String "message required")])
      else begin
        let agent = Printf.sprintf "gardener:%s" meta.name in
        let _ = Room.broadcast config ~from_agent:agent ~content:message in
        Yojson.Safe.to_string (`Assoc [("ok", `Bool true); ("broadcast", `String message)])
      end
  | other ->
      Yojson.Safe.to_string (`Assoc [
        ("error", `String "unknown_tool");
        ("tool", `String other);
      ])

(** Build system prompt for tool-loop follow-up calls.
    Includes the agent's identity/character context but strips skill-routing
    instructions that confuse the model into outputting SKILL: prefixes. *)
let keeper_tool_loop_system_prompt ~(character_context : string) : string =
  Printf.sprintf
    "%s\n\n\
     TOOL-LOOP INSTRUCTIONS:\n\
     When you have all the information needed, produce a final text answer.\n\
     When you still need more data or actions, call the appropriate tool.\n\
     Never output SKILL: prefixes. Use function calling only.\n\
     Stay in character when writing content."
    character_context

let keeper_tool_followup_prompt
    ~(user_message : string)
    ~(draft_reply : string)
    ~(tool_outputs : (Llm_client.tool_call * string) list)
    ~(already_executed : string list) : string =
  let rendered =
    tool_outputs
    |> List.map (fun ((tc : Llm_client.tool_call), output) ->
         Printf.sprintf
           "- %s(%s)\n  => %s"
           tc.call_name
           tc.call_arguments
           output)
    |> String.concat "\n"
  in
  let is_write_tool (name : string) : bool =
    List.mem
      name
      [ "keeper_board_post"; "keeper_board_comment"; "keeper_fs_edit"; "keeper_edit";
        "keeper_task_force_release"; "keeper_task_force_done"; "keeper_broadcast" ]
  in
  let has_write =
    List.exists is_write_tool already_executed
  in
  let rules =
    if has_write then
      "RULES (follow strictly):\n\
       You have already posted to the board. ALL required actions are DONE.\n\
       Produce a brief final text answer confirming what you did. Do NOT call any more tools."
    else
      "RULES (follow strictly):\n\
       1. If the user asked you to POST, WRITE, or UPDATE something, you MUST call \
          the appropriate tool (e.g. keeper_board_post). Do NOT return the content as text.\n\
       2. If you still need information, call the appropriate read/list tool.\n\
       3. Only produce a final text answer when ALL required actions (reads AND writes) are done.\n\
       4. Use tool outputs as source of truth.\n\
       5. Reply in user's language and stay concise."
  in
  Printf.sprintf
    "You called tools. Here are the results.\n\n\
     User message: %s\n\
     Draft reply: %s\n\
     Tool results:\n%s\n\
     Previously executed: [%s]\n\n\
     %s\n"
    user_message draft_reply rendered
    (String.concat ", " already_executed)
    rules

let memory_correction_prompt
    ~(user_message : string)
    ~(first_reply : string)
    ~(candidate_user_msgs : string list)
    ~(expected_topic : string option) : string =
  let evidence =
    candidate_user_msgs
    |> List.mapi (fun i msg -> Printf.sprintf "%d) %s" (i + 1) msg)
    |> String.concat "\n"
  in
  let topic_instruction =
    match expected_topic with
    | Some "first_question" ->
        (match List.rev candidate_user_msgs with
         | earliest :: _ ->
             Printf.sprintf
               "- You MUST return the earliest question in the list exactly or near-verbatim: %s\n"
               earliest
         | [] ->
             "- User asked for the first question. Pick the earliest evidence if available.\n")
    | Some "weather" ->
        "- User asked about weather recall. Choose the weather-related question from evidence.\n"
    | _ ->
        "- Choose the single most relevant previous user question from evidence.\n"
  in
  Printf.sprintf
    "Memory correction required.\n\
     User asked: %s\n\
     Your previous answer: %s\n\
     Ground truth previous user questions:\n%s\n\n\
     Rewrite your answer using ONLY this evidence.\n\
     - If uncertain, explicitly say uncertain.\n\
     - Do not invent questions.\n\
     %s\
     - Keep concise.\n"
    user_message first_reply evidence topic_instruction

let memory_forced_grounding_prompt
    ~(user_message : string)
    ~(first_reply : string)
    ~(candidate_user_msgs : string list)
    ~(expected_topic : string option) : string =
  let evidence =
    candidate_user_msgs
    |> List.mapi (fun i msg -> Printf.sprintf "%d) %s" (i + 1) msg)
    |> String.concat "\n"
  in
  let topic_instruction =
    match expected_topic with
    | Some "first_question" ->
        "- Intent: user asked for the first question. Evidence list order is newest->oldest, so choose the LAST evidence line.\n"
    | Some "weather" ->
        "- Intent: user asked about weather. Choose the weather-related evidence line.\n"
    | _ ->
        "- Intent: user asked about previous question. Prefer the most recent evidence unless user asked otherwise.\n"
  in
  Printf.sprintf
    "Strict memory grounding retry.\n\
     User asked: %s\n\
     Your previous answer failed grounding validation: %s\n\
     Evidence (ordered newest to oldest):\n%s\n\n\
     You MUST answer using exactly one evidence line.\n\
     - The first line MUST be the chosen evidence question copied verbatim and wrapped in double quotes.\n\
     - Then add one concise sentence in the user's language.\n\
     - Do not invent or paraphrase the chosen question.\n\
     - Keep [STATE] continuity block at the end.\n\
     %s"
    user_message first_reply evidence topic_instruction

let contains_korean_text (s : string) : bool =
  try
    let _ = Str.search_forward (Str.regexp "[가-힣]") s 0 in
    true
  with Not_found ->
    false

let is_recent_question_query (s : string) : bool =
  let q = String.lowercase_ascii s in
  let has_ko needle =
    try
      let _ = Str.search_forward (Str.regexp_string needle) s 0 in
      true
    with Not_found ->
      false
  in
  let has_en needle =
    try
      let _ = Str.search_forward (Str.regexp_string needle) q 0 in
      true
    with Not_found ->
      false
  in
  has_ko "방금"
  || has_ko "직전"
  || has_ko "바로 전"
  || has_ko "좀 전에"
  || has_ko "전 질문"
  || has_en "just asked"
  || has_en "last question"
  || has_en "previous question"
  || has_en "most recent question"

let has_weather_keyword (s : string) : bool =
  let q = String.lowercase_ascii s in
  (try
     let _ = Str.search_forward (Str.regexp_string "날씨") s 0 in
     true
   with Not_found ->
     false)
  ||
  (try
     let _ = Str.search_forward (Str.regexp_string "weather") q 0 in
     true
   with Not_found ->
     false)

let select_recall_candidate
    ~(user_message : string)
    ~(expected_topic : string option)
    ~(best_match : string option)
    (candidates : string list) : string option =
  let best_match =
    match best_match with
    | Some text ->
        let text = String.trim text in
        if text = "" then None else Some text
    | None -> None
  in
  let most_recent =
    match candidates with
    | c :: _ ->
        let c = String.trim c in
        if c = "" then None else Some c
    | [] -> None
  in
  let oldest =
    match List.rev candidates with
    | c :: _ ->
        let c = String.trim c in
        if c = "" then None else Some c
    | [] -> None
  in
  let weather_candidate =
    match List.find_opt has_weather_keyword candidates with
    | None -> None
    | Some c ->
        let c = String.trim c in
        if c = "" then None else Some c
  in
  match expected_topic with
  | Some "first_question" -> (match oldest with Some _ as x -> x | None -> best_match)
  | Some "weather" ->
      (match weather_candidate with
       | Some _ as x -> x
       | None -> (match best_match with Some _ as x -> x | None -> most_recent))
  | _ ->
      if is_recent_question_query user_message then
        (match most_recent with Some _ as x -> x | None -> best_match)
      else
        (match best_match with Some _ as x -> x | None -> most_recent)

let recall_fallback_reply
    ~(meta : keeper_meta)
    ~(user_message : string)
    ~(selected_question : string)
    ~(expected_topic : string option) : string =
  let ko =
    contains_korean_text user_message || contains_korean_text selected_question
  in
  if ko then
    let lead =
      match expected_topic with
      | Some "first_question" -> "내 기록상 가장 처음 물어본 건 이거야:"
      | Some "weather" -> "내 기록에 남아있는 날씨 관련 질문은 이거야:"
      | _ -> "내 기록 기준으로는, 직전에 이런 질문을 했어:"
    in
    Printf.sprintf
      "%s\n\"%s\"\n\n\
       [STATE]\n\
       Goal: %s\n\
       Progress: 회상 실패 시 저장된 질문 기록으로 자연스럽게 직접 응답\n\
       Next: 필요하면 첫 질문/직전 질문/주제별로 다시 좁혀서 조회\n\
       Decisions: 회상 질의는 추측보다 저장된 사용자 질문 기록 우선\n\
       OpenQuestions: 없음\n\
       Constraints: 저장된 대화 기록 범위 밖으로는 추측하지 않음\n\
       [/STATE]"
      lead selected_question meta.goal
  else
    let lead =
      match expected_topic with
      | Some "first_question" -> "From stored history, your earliest question was:"
      | Some "weather" -> "From stored history, your weather-related question was:"
      | _ -> "From stored history, your previous question was:"
    in
    Printf.sprintf
      "%s\n\"%s\"\n\n\
       [STATE]\n\
       Goal: %s\n\
       Progress: Returned a deterministic recall answer from stored user messages\n\
       Next: Narrow to earliest/most-recent/topic-specific question if needed\n\
       Decisions: For recall queries, prefer stored user-message evidence over generation\n\
       OpenQuestions: none\n\
       Constraints: Do not infer outside stored conversation history\n\
       [/STATE]"
      lead selected_question meta.goal

let deterministic_recall_fallback
    ~(meta : keeper_meta)
    ~(user_message : string)
    ~(eval : memory_recall_eval)
    ~(candidates : string list) : (string * memory_recall_eval) option =
  if (not eval.performed) || eval.passed || eval.candidate_count <= 0 then
    None
  else
    match
      select_recall_candidate
        ~user_message
        ~expected_topic:eval.expected_topic
        ~best_match:eval.best_match
        candidates
    with
    | None -> None
    | Some selected_question ->
        let forced_reply =
          recall_fallback_reply
            ~meta
            ~user_message
            ~selected_question
            ~expected_topic:eval.expected_topic
        in
        let eval2 =
          evaluate_memory_recall
            ~user_message
            ~assistant_reply:forced_reply
            ~candidates
        in
        Some (forced_reply, eval2)

type metrics_summary = {
  sample_points: int;
  turn_points: int;
  heartbeat_points: int;
  proactive_points: int;
  auto_reflect_count: int;
  auto_plan_count: int;
  auto_compact_count: int;
  auto_handoff_count: int;
  guardrail_stop_count: int;
  drift_applied_count: int;
  handoff_count: int;
  compaction_events: int;
  compaction_saved_tokens: int;
  memory_compaction_events: int;
  memory_compaction_before_notes: int;
  memory_compaction_dropped_notes: int;
  memory_compaction_invalid_dropped: int;
  memory_checks: int;
  memory_passed: int;
  memory_failed: int;
  memory_correction_applied: int;
  memory_correction_success: int;
  memory_score_sum: float;
  memory_weather_checks: int;
  memory_weather_passed: int;
  repetition_risk_sum: float;
  repetition_risk_points: int;
  goal_alignment_sum: float;
  goal_alignment_points: int;
  response_alignment_sum: float;
  response_alignment_points: int;
  goal_drift_sum: float;
  goal_drift_points: int;
  last_handoff: Yojson.Safe.t option;
  last_compaction: Yojson.Safe.t option;
}

let empty_metrics_summary = {
  sample_points = 0;
  turn_points = 0;
  heartbeat_points = 0;
  proactive_points = 0;
  auto_reflect_count = 0;
  auto_plan_count = 0;
  auto_compact_count = 0;
  auto_handoff_count = 0;
  guardrail_stop_count = 0;
  drift_applied_count = 0;
  handoff_count = 0;
  compaction_events = 0;
  compaction_saved_tokens = 0;
  memory_compaction_events = 0;
  memory_compaction_before_notes = 0;
  memory_compaction_dropped_notes = 0;
  memory_compaction_invalid_dropped = 0;
  memory_checks = 0;
  memory_passed = 0;
  memory_failed = 0;
  memory_correction_applied = 0;
  memory_correction_success = 0;
  memory_score_sum = 0.0;
  memory_weather_checks = 0;
  memory_weather_passed = 0;
  repetition_risk_sum = 0.0;
  repetition_risk_points = 0;
  goal_alignment_sum = 0.0;
  goal_alignment_points = 0;
  response_alignment_sum = 0.0;
  response_alignment_points = 0;
  goal_drift_sum = 0.0;
  goal_drift_points = 0;
  last_handoff = None;
  last_compaction = None;
}

let metrics_summary_to_json (s : metrics_summary) : Yojson.Safe.t =
  let interaction_points = s.turn_points + s.proactive_points in
  let intervention_share =
    if interaction_points = 0 then 0.0
    else float_of_int s.proactive_points /. float_of_int interaction_points
  in
  let intervention_per_turn =
    if s.turn_points = 0 then 0.0
    else float_of_int s.proactive_points /. float_of_int s.turn_points
  in
  let drift_applied_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.drift_applied_count /. float_of_int interaction_points
  in
  let auto_reflect_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_reflect_count /. float_of_int interaction_points
  in
  let auto_plan_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_plan_count /. float_of_int interaction_points
  in
  let auto_compact_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_compact_count /. float_of_int interaction_points
  in
  let auto_handoff_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_handoff_count /. float_of_int interaction_points
  in
  let guardrail_stop_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.guardrail_stop_count /. float_of_int interaction_points
  in
  let memory_pass_rate =
    if s.memory_checks = 0 then 0.0
    else float_of_int s.memory_passed /. float_of_int s.memory_checks
  in
  let memory_avg_score =
    if s.memory_checks = 0 then 0.0
    else s.memory_score_sum /. float_of_int s.memory_checks
  in
  let memory_weather_pass_rate =
    if s.memory_weather_checks = 0 then 0.0
    else float_of_int s.memory_weather_passed /. float_of_int s.memory_weather_checks
  in
  let memory_compaction_drop_ratio =
    if s.memory_compaction_before_notes = 0 then 0.0
    else
      float_of_int s.memory_compaction_dropped_notes
      /. float_of_int s.memory_compaction_before_notes
  in
  let memory_compaction_drop_avg =
    if s.memory_compaction_events = 0 then 0.0
    else
      float_of_int s.memory_compaction_dropped_notes
      /. float_of_int s.memory_compaction_events
  in
  let repetition_risk_avg =
    if s.repetition_risk_points = 0 then 0.0
    else s.repetition_risk_sum /. float_of_int s.repetition_risk_points
  in
  let goal_alignment_avg =
    if s.goal_alignment_points = 0 then 0.0
    else s.goal_alignment_sum /. float_of_int s.goal_alignment_points
  in
  let response_alignment_avg =
    if s.response_alignment_points = 0 then 0.0
    else s.response_alignment_sum /. float_of_int s.response_alignment_points
  in
  let goal_drift_avg =
    if s.goal_drift_points = 0 then 0.0
    else s.goal_drift_sum /. float_of_int s.goal_drift_points
  in
  `Assoc [
    ("sample_points", `Int s.sample_points);
    ("turn_points", `Int s.turn_points);
    ("heartbeat_points", `Int s.heartbeat_points);
    ("proactive_points", `Int s.proactive_points);
    ("window_interactions", `Int interaction_points);
    ("intervention_share", `Float intervention_share);
    ("intervention_per_turn", `Float intervention_per_turn);
    ("auto_reflect_count", `Int s.auto_reflect_count);
    ("auto_plan_count", `Int s.auto_plan_count);
    ("auto_compact_count", `Int s.auto_compact_count);
    ("auto_handoff_count", `Int s.auto_handoff_count);
    ("guardrail_stop_count", `Int s.guardrail_stop_count);
    ("auto_reflect_rate", `Float auto_reflect_rate);
    ("auto_plan_rate", `Float auto_plan_rate);
    ("auto_compact_rate", `Float auto_compact_rate);
    ("auto_handoff_rate", `Float auto_handoff_rate);
    ("guardrail_stop_rate", `Float guardrail_stop_rate);
    ("drift_applied_count", `Int s.drift_applied_count);
    ("drift_applied_rate", `Float drift_applied_rate);
    ("handoff_count", `Int s.handoff_count);
    ("compaction_events", `Int s.compaction_events);
    ("compaction_saved_tokens", `Int s.compaction_saved_tokens);
    ("memory_compaction_events", `Int s.memory_compaction_events);
    ("memory_compaction_before_notes", `Int s.memory_compaction_before_notes);
    ("memory_compaction_dropped_notes", `Int s.memory_compaction_dropped_notes);
    ("memory_compaction_invalid_dropped", `Int s.memory_compaction_invalid_dropped);
    ("memory_compaction_drop_ratio", `Float memory_compaction_drop_ratio);
    ("memory_compaction_drop_avg", `Float memory_compaction_drop_avg);
    ("memory_checks", `Int s.memory_checks);
    ("memory_passed", `Int s.memory_passed);
    ("memory_failed", `Int s.memory_failed);
    ("memory_pass_rate", `Float memory_pass_rate);
    ("memory_avg_score", `Float memory_avg_score);
    ("memory_correction_applied", `Int s.memory_correction_applied);
    ("memory_correction_success", `Int s.memory_correction_success);
    ("memory_weather_checks", `Int s.memory_weather_checks);
    ("memory_weather_passed", `Int s.memory_weather_passed);
    ("memory_weather_pass_rate", `Float memory_weather_pass_rate);
    ("repetition_risk_avg", `Float repetition_risk_avg);
    ("goal_alignment_avg", `Float goal_alignment_avg);
    ("response_alignment_avg", `Float response_alignment_avg);
    ("goal_drift_avg", `Float goal_drift_avg);
    ("last_handoff", match s.last_handoff with Some j -> j | None -> `Null);
    ("last_compaction", match s.last_compaction with Some j -> j | None -> `Null);
  ]

let summarize_metrics_lines (lines : string list) ~(default_generation : int) : metrics_summary =
  let open Yojson.Safe.Util in
  List.fold_left (fun acc line ->
    try
      let j = Yojson.Safe.from_string line in
      let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
      let trace_id = Safe_ops.json_string ~default:"" "trace_id" j in
      let generation = Safe_ops.json_int ~default:default_generation "generation" j in
      let channel = Safe_ops.json_string ~default:"turn" "channel" j in
      let is_turn = channel = "turn" in
      let is_heartbeat = channel = "heartbeat" in
      let is_proactive = channel = "proactive" in
      let is_interaction = is_turn || is_proactive in
      let compacted = Safe_ops.json_bool ~default:false "compacted" j in
      let before_tokens = Safe_ops.json_int ~default:0 "compaction_before_tokens" j in
      let after_tokens = Safe_ops.json_int ~default:0 "compaction_after_tokens" j in
      let saved_tokens = max 0 (before_tokens - after_tokens) in
      let handoff = j |> member "handoff" in
      let handoff_performed = Safe_ops.json_bool ~default:false "performed" handoff in
      let to_model = Safe_ops.json_string_opt "to_model" handoff in
      let prev_trace_id = Safe_ops.json_string_opt "prev_trace_id" handoff in
      let new_trace_id = Safe_ops.json_string_opt "new_trace_id" handoff in
      let memory = j |> member "memory_check" in
      let memory_performed = Safe_ops.json_bool ~default:false "performed" memory in
      let memory_passed = Safe_ops.json_bool ~default:false "passed" memory in
      let memory_final_score = Safe_ops.json_float ~default:0.0 "final_score" memory in
      let memory_correction_applied =
        Safe_ops.json_bool ~default:false "correction_applied" memory
      in
      let memory_correction_success =
        Safe_ops.json_bool ~default:false "correction_success" memory
      in
      let memory_expected_topic = Safe_ops.json_string_opt "expected_topic" memory in
      let memory_compaction_performed =
        Safe_ops.json_bool ~default:false "memory_compaction_performed" j
      in
      let memory_compaction_before_now =
        Safe_ops.json_int ~default:0 "memory_compaction_before_notes" j
      in
      let memory_compaction_dropped_now =
        Safe_ops.json_int ~default:0 "memory_compaction_dropped_notes" j
      in
      let memory_compaction_invalid_now =
        Safe_ops.json_int ~default:0 "memory_compaction_invalid_dropped" j
      in
      let drift =
        j |> member "drift"
      in
      let drift_applied_now =
        Safe_ops.json_bool ~default:false "applied" drift
      in
      let memory_is_weather =
        match memory_expected_topic with Some "weather" -> true | _ -> false
      in
      let auto_rules = j |> member "auto_rules" in
      let auto_reflect_now =
        Safe_ops.json_bool
          ~default:(Safe_ops.json_bool ~default:false "reflect" auto_rules)
          "auto_reflect"
          j
      in
      let auto_plan_now =
        Safe_ops.json_bool
          ~default:(Safe_ops.json_bool ~default:false "plan" auto_rules)
          "auto_plan"
          j
      in
      let auto_compact_now =
        Safe_ops.json_bool
          ~default:(Safe_ops.json_bool ~default:false "compact" auto_rules)
          "auto_compact"
          j
      in
      let auto_handoff_now =
        Safe_ops.json_bool
          ~default:(Safe_ops.json_bool ~default:false "handoff" auto_rules)
          "auto_handoff"
          j
      in
      let guardrail_stop_now =
        Safe_ops.json_bool
          ~default:(Safe_ops.json_bool ~default:false "guardrail_stop" auto_rules)
          "guardrail_stop"
          j
      in
      let repetition_risk_opt = Safe_ops.json_float_opt "repetition_risk" j in
      let goal_alignment_opt = Safe_ops.json_float_opt "goal_alignment" j in
      let response_alignment_opt = Safe_ops.json_float_opt "response_alignment" j in
      let goal_drift_opt = Safe_ops.json_float_opt "goal_drift" j in
      let handoff_json =
        if handoff_performed then
          Some (`Assoc [
            ("ts_unix", `Float ts_unix);
            ("trace_id", `String trace_id);
            ("generation", `Int generation);
            ("to_model", match to_model with Some s when s <> "" -> `String s | _ -> `Null);
            ("prev_trace_id", match prev_trace_id with Some s when s <> "" -> `String s | _ -> `Null);
            ("new_trace_id", match new_trace_id with Some s when s <> "" -> `String s | _ -> `Null);
          ])
        else
          acc.last_handoff
      in
      let compaction_json =
        if compacted then
          let trigger =
            Safe_ops.json_string_opt "compaction_trigger" j
          in
          Some (`Assoc [
            ("ts_unix", `Float ts_unix);
            ("trace_id", `String trace_id);
            ("generation", `Int generation);
            ("before_tokens", `Int before_tokens);
            ("after_tokens", `Int after_tokens);
            ("saved_tokens", `Int saved_tokens);
            ( "trigger",
              match trigger with
              | Some reason when String.trim reason <> "" -> `String reason
              | _ -> `Null );
          ])
        else
          acc.last_compaction
      in
      {
        sample_points = acc.sample_points + 1;
        turn_points = acc.turn_points + (if is_turn then 1 else 0);
        heartbeat_points = acc.heartbeat_points + (if is_heartbeat then 1 else 0);
        proactive_points = acc.proactive_points + (if is_proactive then 1 else 0);
        auto_reflect_count =
          acc.auto_reflect_count + (if is_interaction && auto_reflect_now then 1 else 0);
        auto_plan_count =
          acc.auto_plan_count + (if is_interaction && auto_plan_now then 1 else 0);
        auto_compact_count =
          acc.auto_compact_count + (if is_interaction && auto_compact_now then 1 else 0);
        auto_handoff_count =
          acc.auto_handoff_count + (if is_interaction && auto_handoff_now then 1 else 0);
        guardrail_stop_count =
          acc.guardrail_stop_count + (if is_interaction && guardrail_stop_now then 1 else 0);
        drift_applied_count =
          acc.drift_applied_count + (if is_interaction && drift_applied_now then 1 else 0);
        handoff_count = acc.handoff_count + (if is_interaction && handoff_performed then 1 else 0);
        compaction_events = acc.compaction_events + (if is_interaction && compacted then 1 else 0);
        compaction_saved_tokens =
          acc.compaction_saved_tokens + (if is_interaction && compacted then saved_tokens else 0);
        memory_compaction_events =
          acc.memory_compaction_events
          + (if is_interaction && memory_compaction_performed then 1 else 0);
        memory_compaction_before_notes =
          acc.memory_compaction_before_notes
          + (if is_interaction && memory_compaction_performed then memory_compaction_before_now else 0);
        memory_compaction_dropped_notes =
          acc.memory_compaction_dropped_notes
          + (if is_interaction && memory_compaction_performed then memory_compaction_dropped_now else 0);
        memory_compaction_invalid_dropped =
          acc.memory_compaction_invalid_dropped
          + (if is_interaction && memory_compaction_performed then memory_compaction_invalid_now else 0);
        memory_checks = acc.memory_checks + (if is_interaction && memory_performed then 1 else 0);
        memory_passed =
          acc.memory_passed + (if is_interaction && memory_performed && memory_passed then 1 else 0);
        memory_failed =
          acc.memory_failed + (if is_interaction && memory_performed && not memory_passed then 1 else 0);
        memory_correction_applied =
          acc.memory_correction_applied
          + (if is_interaction && memory_performed && memory_correction_applied then 1 else 0);
        memory_correction_success =
          acc.memory_correction_success
          + (if is_interaction && memory_performed && memory_correction_success then 1 else 0);
        memory_score_sum =
          acc.memory_score_sum
          +. (if is_interaction && memory_performed then memory_final_score else 0.0);
        memory_weather_checks =
          acc.memory_weather_checks
          + (if is_interaction && memory_performed && memory_is_weather then 1 else 0);
        memory_weather_passed =
          acc.memory_weather_passed
          + (if is_interaction && memory_performed && memory_is_weather && memory_passed then 1 else 0);
        repetition_risk_sum =
          acc.repetition_risk_sum
          +. (match repetition_risk_opt with Some v -> v | None -> 0.0);
        repetition_risk_points =
          acc.repetition_risk_points
          + (if Option.is_some repetition_risk_opt then 1 else 0);
        goal_alignment_sum =
          acc.goal_alignment_sum
          +. (match goal_alignment_opt with Some v -> v | None -> 0.0);
        goal_alignment_points =
          acc.goal_alignment_points
          + (if Option.is_some goal_alignment_opt then 1 else 0);
        response_alignment_sum =
          acc.response_alignment_sum
          +. (if is_interaction then Option.value ~default:0.0 response_alignment_opt else 0.0);
        response_alignment_points =
          acc.response_alignment_points
          + (if is_interaction && Option.is_some response_alignment_opt then 1 else 0);
        goal_drift_sum =
          acc.goal_drift_sum
          +. (if is_interaction then Option.value ~default:0.0 goal_drift_opt else 0.0);
        goal_drift_points =
          acc.goal_drift_points
          + (if is_interaction && Option.is_some goal_drift_opt then 1 else 0);
        last_handoff = handoff_json;
        last_compaction = compaction_json;
      }
    with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
      acc
  ) empty_metrics_summary lines

let active_model_of_meta (m : keeper_meta) : string =
  if m.last_model_used <> "" then m.last_model_used
  else
    match m.models with
    | model :: _ -> model
    | [] -> ""

let next_model_hint_of_meta (m : keeper_meta) : string option =
  match m.models with
  | _current :: next_model :: _ -> Some next_model
  | current :: [] -> Some current
  | [] -> None

let parse_agent_status (config : Room.config) ~(agent_name : string) : Yojson.Safe.t =
  let agent_file =
    Filename.concat (Room.agents_dir config) (Room.safe_filename agent_name ^ ".json")
  in
  if not (Sys.file_exists agent_file) then
    `Assoc [("exists", `Bool false)]
  else
    match Safe_ops.read_json_file_safe agent_file with
    | Error _ -> `Assoc [("exists", `Bool true); ("error", `String "failed_to_read")]
    | Ok json ->
      (match Types.agent_of_yojson json with
       | Error _ -> `Assoc [("exists", `Bool true); ("error", `String "failed_to_parse")]
       | Ok (agent : Types.agent) ->
         let now_ts = Time_compat.now () in
         let joined_ts = Resilience.Time.parse_iso8601_opt agent.joined_at |> Option.value ~default:0.0 in
         let last_seen_ts = Resilience.Time.parse_iso8601_opt agent.last_seen |> Option.value ~default:0.0 in
         let age_s = if joined_ts <= 0.0 then 0.0 else now_ts -. joined_ts in
         let last_seen_ago_s = if last_seen_ts <= 0.0 then 0.0 else now_ts -. last_seen_ts in
         `Assoc [
           ("exists", `Bool true);
           ("name", `String agent.name);
           ("agent_type", `String agent.agent_type);
           ("status", `String (Types.string_of_agent_status agent.status));
           ("capabilities", `List (List.map (fun s -> `String s) agent.capabilities));
           ("current_task", match agent.current_task with None -> `Null | Some t -> `String t);
           ("joined_at", `String agent.joined_at);
           ("last_seen", `String agent.last_seen);
           ("age_s", `Float age_s);
           ("last_seen_ago_s", `Float last_seen_ago_s);
           ("is_zombie", `Bool (Room.is_zombie_agent agent.last_seen));
         ])

let json_string_opt key json =
  match Yojson.Safe.Util.member key json with
  | `String s ->
      let trimmed = String.trim s in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let json_bool key json default =
  match Yojson.Safe.Util.member key json with
  | `Bool value -> value
  | _ -> default

let json_float_opt key json =
  match Yojson.Safe.Util.member key json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | _ -> None

let string_contains_ci haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  needle <> "" && contains_ci haystack needle

let quiet_hours_active () =
  let current_hour = Lodge_heartbeat.current_hour_kst () in
  let quiet_start = Env_config.LodgeV2.quiet_start in
  let quiet_end = Env_config.LodgeV2.quiet_end in
  quiet_start < quiet_end
  && current_hour >= quiet_start
  && current_hour < quiet_end

let keeper_reply_snapshot_of_history (history_items : Yojson.Safe.t list) =
  let open Yojson.Safe.Util in
  let normalize_content item =
    match json_string_opt "content" item with
    | Some value -> value
    | None -> Option.value ~default:"" (json_string_opt "preview" item)
  in
  let update_last role ts content ((last_user, last_assistant) as acc) =
    let role = String.lowercase_ascii role in
    if role = "user" then
      (Some (ts, content), last_assistant)
    else if role = "assistant" then
      (last_user, Some (ts, content))
    else
      acc
  in
  let (last_user, last_assistant) =
    List.fold_left
      (fun acc item ->
        match item with
        | `Assoc _ ->
            let role = item |> member "role" |> to_string_option in
            let ts_unix =
              match json_float_opt "ts_unix" item with
              | Some ts when ts > 0.0 -> Some ts
              | _ -> json_float_opt "timestamp" item
            in
            let content = normalize_content item in
            (match role, ts_unix with
             | Some role, Some ts -> update_last role ts content acc
             | _ -> acc)
        | _ -> acc)
      (None, None)
      history_items
  in
  match last_user, last_assistant with
  | None, None ->
      (`String "never", `Null, `Null)
  | Some (user_ts, _), Some (assistant_ts, preview) when assistant_ts >= user_ts ->
      (`String "delivered", `Float assistant_ts, `String preview)
  | Some _, Some (assistant_ts, preview) ->
      (`String "delivered", `Float assistant_ts, `String preview)
  | Some _, None ->
      (`String "awaiting_reply", `Null, `Null)
  | None, Some (assistant_ts, preview) ->
      (`String "delivered", `Float assistant_ts, `String preview)

let keeper_error_hint ~agent_status ~meta =
  let agent_error = json_string_opt "error" agent_status in
  let proactive_reason =
    let reason = String.trim meta.last_proactive_reason in
    if reason = "" then None else Some reason
  in
  let drift_reason =
    let reason = String.trim meta.last_drift_reason in
    if reason = "" then None else Some reason
  in
  let looks_error_like text =
    List.exists (string_contains_ci text)
      [ "error"; "failed"; "timeout"; "graphql"; "llm"; "model"; "ollama"; "gemini"; "openai" ]
  in
  match agent_error with
  | Some _ as error -> error
  | None ->
      (match proactive_reason with
       | Some reason when looks_error_like reason -> Some reason
       | _ ->
           match drift_reason with
           | Some reason when looks_error_like reason -> Some reason
           | _ -> None)

let classify_keeper_quiet_reason ~meta ~keepalive_running ~agent_status ~now_ts =
  let quiet_active = quiet_hours_active () in
  let agent_exists = json_bool "exists" agent_status false in
  let agent_status_text =
    json_string_opt "status" agent_status
    |> Option.value ~default:"unknown"
    |> String.lowercase_ascii
  in
  let error_hint = keeper_error_hint ~agent_status ~meta in
  if not keepalive_running || not agent_exists || agent_status_text = "offline" || agent_status_text = "inactive" then
    Some "disabled"
  else if meta.total_turns = 0 && meta.proactive_count_total = 0 then
    let keeper_age_s =
      match Resilience.Time.parse_iso8601_opt meta.created_at with
      | Some created_ts when created_ts > 0.0 -> max 0.0 (now_ts -. created_ts)
      | _ -> 0.0
    in
    if keeper_age_s <= 120.0 then Some "startup" else Some "never_started"
  else if quiet_active then
    Some "quiet_hours"
  else
    match error_hint with
    | Some reason when string_contains_ci reason "graphql" -> Some "graphql_error"
    | Some reason
      when List.exists (string_contains_ci reason)
             [ "llm"; "model"; "timeout"; "ollama"; "gemini"; "openai" ] ->
        Some "llm_error"
    | Some _ -> Some "unknown"
    | None ->
        let last_turn_ago_s =
          if meta.last_turn_ts <= 0.0 then None else Some (max 0.0 (now_ts -. meta.last_turn_ts))
        in
        let last_proactive_ago_s =
          if meta.last_proactive_ts <= 0.0 then None
          else Some (max 0.0 (now_ts -. meta.last_proactive_ts))
        in
        if meta.proactive_enabled then
          match last_proactive_ago_s with
          | Some age when age < float_of_int meta.proactive_cooldown_sec -> Some "min_gap"
          | _ ->
              (match last_turn_ago_s with
               | Some age when age < float_of_int meta.proactive_idle_sec -> Some "no_recent_activity"
               | _ -> None)
        else
          None

let keeper_health_state ~meta ~keepalive_running ~agent_status ~quiet_reason ~now_ts =
  let agent_exists = json_bool "exists" agent_status false in
  let agent_status_text =
    json_string_opt "status" agent_status
    |> Option.value ~default:"unknown"
    |> String.lowercase_ascii
  in
  let last_seen_ago_s = json_float_opt "last_seen_ago_s" agent_status |> Option.value ~default:max_float in
  let is_zombie = json_bool "is_zombie" agent_status false in
  let stale_threshold_s =
    float_of_int (max 120 (meta.presence_keepalive_sec * 4))
  in
  let last_turn_ago_s =
    if meta.last_turn_ts <= 0.0 then max_float else max 0.0 (now_ts -. meta.last_turn_ts)
  in
  if not keepalive_running || not agent_exists || agent_status_text = "offline" || agent_status_text = "inactive" then
    "offline"
  else if is_zombie || last_seen_ago_s > stale_threshold_s then
    "stale"
  else
    match quiet_reason with
    | Some "graphql_error" | Some "llm_error" -> "degraded"
    | _ ->
        if meta.total_turns = 0 && meta.proactive_count_total = 0 then
          "idle"
        else if last_turn_ago_s > float_of_int (max meta.proactive_idle_sec 900) then
          "idle"
        else
          "healthy"

let keeper_next_action_path ~health_state ~quiet_reason =
  match health_state with
  | "offline" | "stale" | "degraded" -> "recover"
  | _ ->
      (match quiet_reason with
       | Some "quiet_hours" -> "manual_lodge_poke"
       | Some "graphql_error" | Some "llm_error" | Some "startup" | Some "unknown" -> "probe"
       | Some "disabled" -> "recover"
       | _ -> "direct_message")

let keeper_next_eligible_at_s ~meta ~quiet_reason ~now_ts =
  match quiet_reason with
  | Some "min_gap" when meta.last_proactive_ts > 0.0 ->
      let remaining =
        float_of_int meta.proactive_cooldown_sec -. (now_ts -. meta.last_proactive_ts)
      in
      if remaining > 0.0 then `Float remaining else `Null
  | _ -> `Null

let keeper_diagnostic_summary ~health_state ~quiet_reason =
  match health_state with
  | "offline" | "stale" | "degraded" ->
      "Keeper is not in a healthy reply state. Probe or recover before relying on automation."
  | _ ->
      (match quiet_reason with
       | Some "quiet_hours" ->
           "Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep."
       | Some "min_gap" ->
           "Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait."
       | Some "never_started" ->
           "Keeper metadata exists but no reply turn has been recorded yet."
       | _ -> "Keeper is reachable. Send a direct message for an immediate response.")

let keeper_diagnostic_json
    ~(meta : keeper_meta)
    ~(agent_status : Yojson.Safe.t)
    ~(keepalive_running : bool)
    ~(history_items : Yojson.Safe.t list)
    ~(now_ts : float) : Yojson.Safe.t =
  let quiet_reason = classify_keeper_quiet_reason ~meta ~keepalive_running ~agent_status ~now_ts in
  let health_state =
    keeper_health_state ~meta ~keepalive_running ~agent_status ~quiet_reason ~now_ts
  in
  let next_action_path = keeper_next_action_path ~health_state ~quiet_reason in
  let (last_reply_status, last_reply_at, last_reply_preview) =
    keeper_reply_snapshot_of_history history_items
  in
  let last_error =
    match keeper_error_hint ~agent_status ~meta with
    | Some reason -> `String reason
    | None -> `Null
  in
  `Assoc
    [
      ("health_state", `String health_state);
      ( "quiet_reason",
        match quiet_reason with Some reason -> `String reason | None -> `Null );
      ("next_action_path", `String next_action_path);
      ("recoverable", `Bool (String.equal next_action_path "recover"));
      ("summary", `String (keeper_diagnostic_summary ~health_state ~quiet_reason));
      ("last_reply_status", last_reply_status);
      ("last_reply_at", last_reply_at);
      ("last_reply_preview", last_reply_preview);
      ("last_error", last_error);
      ("keepalive_running", `Bool keepalive_running);
      ("next_eligible_at_s", keeper_next_eligible_at_s ~meta ~quiet_reason ~now_ts);
    ]

let keeper_constitution =
  "Continuity rules:\n\
   - This conversation may be compacted/summarized and handed off to a successor.\n\
   - You MUST preserve continuity by emitting a stable state block at the end of each reply.\n\
   - The state block is used for compaction/handoff. Do not include secrets.\n\
   - Reply in the user's language. Keep the main reply concise.\n\
   - Do not output [GOAL_COMPLETE] unless explicitly requested.\n\
   \n\
   State block template (must use these exact markers):\n\
   [STATE]\n\
   Goal: <short>\n\
   Progress: <short>\n\
   Next: <0-3 items separated by ';'>\n\
   Decisions: <0-3 items separated by ';'>\n\
   OpenQuestions: <0-3 items separated by ';'>\n\
   Constraints: <0-3 items separated by ';'>\n\
   [/STATE]\n"

let build_keeper_system_prompt
    ~goal
    ~short_goal
    ~mid_goal
    ~long_goal
    ~soul_profile
    ~will
    ~needs
    ~desires
    ~instructions =
  let profile =
    canonical_soul_profile soul_profile |> Option.value ~default:default_soul_profile
  in
  let goal = normalize_goal_horizon_text goal in
  let (short_goal, mid_goal, long_goal) =
    resolve_goal_horizons
      ~goal
      ~short_goal_opt:(Some short_goal)
      ~mid_goal_opt:(Some mid_goal)
      ~long_goal_opt:(Some long_goal)
  in
  let profile_policy = soul_profile_policy profile in
  let will =
    let s = normalize_self_model_text will in
    if s = "" then "Maintain coherent identity and goal continuity." else s
  in
  let needs =
    let s = normalize_self_model_text needs in
    if s = "" then "Reliable context continuity, factual grounding, and explicit next steps." else s
  in
  let desires =
    let s = normalize_self_model_text desires in
    if s = "" then "Make progress that is observable and useful to the user." else s
  in
  let custom =
    let s = String.trim instructions in
    if s = "" then ""
    else Printf.sprintf "\nCustom instructions:\n%s\n" s
  in
  Printf.sprintf
    "You are a keeper agent with persistent memory.\n\
     Goal: %s\n\
     Goal horizons:\n\
     - Short: %s\n\
     - Mid: %s\n\
     - Long: %s\n\
     \n\
     Tool guidance:\n\
     - You can call tools for time/context/memory/weather checks.\n\
     - Prefer tools when user asks for factual current status or memory lookup evidence.\n\
     - After tool use, answer with concise, grounded statements.\n\
     \n\
     Self model:\n\
     - Will: %s\n\
     - Needs: %s\n\
     - Desires: %s\n\
     \n\
     %s\n\
     \n\
    %s\
    %s"
    goal short_goal mid_goal long_goal will needs desires profile_policy keeper_constitution custom

let append_trait_clause ~(base : string) ~(clause : string) : string =
  let b = String.trim base in
  let c = String.trim clause in
  if c = "" then b
  else if b = "" then c
  else if contains_ci b c then b
  else Printf.sprintf "%s; %s" b c

let apply_self_model_drift
    ~(meta : keeper_meta)
    ~(user_message : string)
    ~(work_kind : string) : keeper_meta * bool * string option =
  if not meta.drift_enabled then (meta, false, None)
  else if String.trim user_message = "" then (meta, false, None)
  else if work_kind <> "general_chat" && work_kind <> "memory_recall" then (meta, false, None)
  else
    let turn_gap = meta.total_turns - meta.last_drift_turn in
    if turn_gap < meta.drift_min_turn_gap then
      (meta, false, None)
    else
      let msg = String.lowercase_ascii user_message in
      let has_any keywords =
        List.exists (fun kw -> contains_ci msg kw) keywords
      in
      let relationship_flag =
        has_any
          [ "연애"; "관계"; "감정"; "사람"; "호감"; "불호"; "신뢰"; "친밀"; "친구";
            "relationship"; "emotion"; "trust"; "liking"; "dislike" ]
      in
      let safety_flag =
        has_any
          [ "위험"; "리스크"; "장애"; "실패"; "사고"; "롤백"; "incident"; "risk";
            "failure"; "rollback"; "outage" ]
      in
      let delivery_flag =
        has_any
          [ "실행"; "마감"; "배포"; "완료"; "일정"; "ship"; "deliver"; "deadline";
            "execute" ]
      in
      let memory_flag =
        has_any
          [ "기억"; "메모"; "승계"; "핸드오프"; "컴팩팅"; "memory"; "handoff";
            "compaction"; "context" ]
      in
      let conflict_flag =
        has_any
          [ "갈등"; "충돌"; "싸움"; "비난"; "불편"; "conflict"; "fight"; "blame" ]
      in
      if not (relationship_flag || safety_flag || delivery_flag || memory_flag || conflict_flag) then
        (meta, false, None)
      else
        let will' =
          meta.will
          |> (fun v ->
                if safety_flag
                then append_trait_clause ~base:v ~clause:"불확실성이 커지면 즉시 보수 모드로 전환한다."
                else v)
          |> (fun v ->
                if conflict_flag
                then append_trait_clause ~base:v ~clause:"갈등 상황에서는 해석보다 사실 확인과 경계선 선언을 먼저 수행한다."
                else v)
          |> compact_self_model_text
        in
        let needs' =
          meta.needs
          |> (fun v ->
                if relationship_flag
                then append_trait_clause ~base:v ~clause:"관계의 비대칭, 감정 신호, 실제 사실을 분리 기록한다."
                else v)
          |> (fun v ->
                if memory_flag
                then append_trait_clause ~base:v ~clause:"기억 항목은 사실/해석/결정을 분리해 보존한다."
                else v)
          |> compact_self_model_text
        in
        let desires' =
          meta.desires
          |> (fun v ->
                if delivery_flag
                then append_trait_clause ~base:v ~clause:"다음 행동을 책임/기한/검증 기준과 함께 즉시 고정한다."
                else v)
          |> (fun v ->
                if relationship_flag
                then append_trait_clause ~base:v ~clause:"관계를 해치지 않으면서도 핵심을 말하는 문장을 우선 선택한다."
                else v)
          |> compact_self_model_text
        in
        if will' = meta.will && needs' = meta.needs && desires' = meta.desires then
          (meta, false, None)
        else
          let tags =
            []
            |> (fun xs -> if relationship_flag then "relationship" :: xs else xs)
            |> (fun xs -> if safety_flag then "safety" :: xs else xs)
            |> (fun xs -> if delivery_flag then "delivery" :: xs else xs)
            |> (fun xs -> if memory_flag then "memory" :: xs else xs)
            |> (fun xs -> if conflict_flag then "conflict" :: xs else xs)
            |> List.rev
          in
          let reason =
            Printf.sprintf
              "auto-drift(turn=%d,gap=%d,tags=%s)"
              meta.total_turns
              turn_gap
              (String.concat "," tags)
          in
          ( { meta with
              will = will';
              needs = needs';
              desires = desires';
              drift_count_total = meta.drift_count_total + 1;
              last_drift_turn = meta.total_turns;
              last_drift_reason = reason;
              updated_at = now_iso ();
            },
            true,
            Some reason )

let load_context_from_checkpoint ~trace_id ~primary_model_max_tokens ~base_dir =
  let session = Context_manager.create_session ~session_id:trace_id ~base_dir in
  let latest_ckpt =
    try Context_manager.load_latest_checkpoint session
    with ex ->
      Printf.eprintf
        "[keeper:%s] checkpoint load failed: %s\n%!"
        trace_id
        (Printexc.to_string ex);
      None
  in
  match latest_ckpt with
  | None -> (session, None)
  | Some ckpt ->
    (try
       let ctx =
         Context_manager.restore_checkpoint
           ckpt
           ~max_tokens:primary_model_max_tokens
       in
       (session, Some ctx)
     with ex ->
       Printf.eprintf
         "[keeper:%s] checkpoint restore failed: %s\n%!"
         trace_id
         (Printexc.to_string ex);
       (session, None))

let save_checkpoint session (ctx : Context_manager.working_context) ~generation =
  let ckpt = Context_manager.create_checkpoint ctx ~generation in
  Context_manager.save_checkpoint session ckpt;
  ckpt

let compaction_policy_of_keeper (meta : keeper_meta) : float * int * int =
  ( meta.compaction_ratio_gate,
    meta.compaction_message_gate,
    meta.compaction_token_gate )

let compact_if_needed
    ~(meta : keeper_meta)
    ~(now_ts : float)
    (ctx : Context_manager.working_context) :
    Context_manager.working_context * string option * string =
  let ratio = Context_manager.context_ratio ctx in
  let message_count = List.length ctx.messages in
  let token_count = ctx.token_count in
  let (ratio_gate, message_gate, token_gate) = compaction_policy_of_keeper meta in
  let cooldown = Float.of_int meta.continuity_compaction_cooldown_sec in
  let last_reflection_ts = max meta.last_continuity_update_ts meta.last_proactive_ts in
  let reflection_ready =
    last_reflection_ts > 0.0 && now_ts -. last_reflection_ts >= cooldown
  in
  let hold_s =
    if cooldown <= 0.0 then
      0.0
    else if last_reflection_ts <= 0.0 then
      Float.of_int meta.continuity_compaction_cooldown_sec
    else
      max
        0.0
        (Float.of_int meta.continuity_compaction_cooldown_sec -. (now_ts -. last_reflection_ts))
  in
  let trigger_reason =
    if not reflection_ready then
      Some
        (Printf.sprintf
           "skipped:continuity_reflection(%0.0fs<%ds)"
           hold_s
           meta.continuity_compaction_cooldown_sec)
    else if ratio >= ratio_gate then
      Some
        (Printf.sprintf
           "ratio(%.4f>=%.4f)"
           ratio
           ratio_gate)
    else if message_gate > 0 && message_count >= message_gate then
      Some
        (Printf.sprintf
           "messages(%d>=%d)"
           message_count
           message_gate)
    else if token_gate > 0 && token_count >= token_gate then
      Some
        (Printf.sprintf
           "tokens(%d>=%d)"
           token_count
           token_gate)
    else
      None
  in
  match trigger_reason with
  | None -> (ctx, None, "blocked:below_thresholds")
  | Some reason ->
      if String.starts_with ~prefix:"skipped:" reason then
        (ctx, None, reason)
      else
      let compacted_ctx =
        Context_manager.compact
          ctx
          Context_manager.[PruneToolOutputs; MergeContiguous; DropLowImportance; SummarizeOld]
      in
      (compacted_ctx, Some reason, "applied:" ^ reason)

let generate_trace_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let rnd = Random.int 99999 in
  Printf.sprintf "trace-%d-%05d" ts rnd

