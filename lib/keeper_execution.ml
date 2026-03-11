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

let proactive_prompt_for_keeper
    ~(meta : keeper_meta)
    ~(idle_seconds : int)
    (snapshot : keeper_state_snapshot option)
    (continuity_summary : string) : string =
  let seed = proactive_seed_for_soul_profile meta.soul_profile in
  let profile =
    canonical_soul_profile meta.soul_profile
    |> Option.value ~default:default_soul_profile
  in
  let last_preview =
    if String.trim meta.last_proactive_preview = "" then "none"
    else meta.last_proactive_preview
  in
  let continuity_snapshot =
    match snapshot with
    | None -> "No continuity snapshot available."
    | Some s -> keeper_state_snapshot_to_summary_text s
  in
  let continuity_snapshot =
    if continuity_snapshot = "No continuity snapshot available." then
      let fallback = String.trim continuity_summary in
      if fallback = "" then continuity_snapshot else fallback
    else continuity_snapshot
  in
  Printf.sprintf
    "Autonomous proactive turn (no new user message) after %d seconds idle.\n\
     Keeper SOUL profile: %s.\n\
     Goal: %s\n\
     Last proactive preview (avoid repeating): %s\n\
     Continuity snapshot:\n%s\n\
     SOUL perspective hint: %s\n\
     Guidance (strict):\n\
     - Prefer the same language as the recent conversation.\n\
     - Avoid repeating the previous proactive message verbatim.\n\
     - Keep it concise and useful for the current goal.\n\
     - If external checks or actions are needed, call tools before finalizing.\n\
     - When a required write action is identified, execute it via tools and then summarize.\n\
     - For this proactive turn only, do NOT output [STATE] blocks.\n\
     - Output exactly one line using this format:\n\
       CHECKIN: <single complete sentence ending with punctuation>"
    idle_seconds profile meta.goal last_preview continuity_snapshot seed

type proactive_generation_result = {
  reply: string;
  usage: Llm_client.token_usage;
  model_used: string;
  latency_ms: int;
  attempts: int;
  total_cost_usd: float;
  fallback_applied: bool;
  tools_used: string list;
}

let proactive_retry_instruction attempt ~(reason : string) =
  if attempt = 2 then
    Printf.sprintf
      "Retry policy: previous attempt failed (%s). You MUST output now with a clearly different angle."
      reason
  else
    Printf.sprintf
      "Retry policy: previous attempts failed (%s). You MUST output one decisive check-in now, materially different from the last preview."
      reason

let proactive_temperature attempt =
  if attempt <= 1 then 0.55
  else if attempt = 2 then 0.75
  else 0.9

let strip_state_blocks_text (s : string) : string =
  let start_marker = "[STATE]" in
  let end_marker = "[/STATE]" in
  let start_re = Str.regexp_string start_marker in
  let end_re = Str.regexp_string end_marker in
  let len = String.length s in
  let rec loop from (buf : Buffer.t) =
    if from >= len then ()
    else
      try
        let i = Str.search_forward start_re s from in
        if i > from then Buffer.add_substring buf s from (i - from);
        let block_start = i + String.length start_marker in
        let next_from =
          try
            let j = Str.search_forward end_re s block_start in
            j + String.length end_marker
          with Not_found ->
            len
        in
        loop next_from buf
      with Not_found ->
        Buffer.add_substring buf s from (len - from)
  in
  let buf = Buffer.create len in
  loop 0 buf;
  Buffer.contents buf

let normalize_proactive_text (raw : string) : string =
  raw
  |> strip_state_blocks_text
  |> Str.global_replace (Str.regexp "[ \t\r\n]+") " "
  |> String.trim

let extract_checkin_text (raw : string) : string option =
  let cleaned = normalize_proactive_text raw in
  if cleaned = "" then None
  else
    let lines =
      raw
      |> String.split_on_char '\n'
      |> List.map String.trim
      |> List.filter (fun line -> line <> "")
    in
    let checkin_line =
      List.find_map
        (fun line ->
          match strip_prefix_ci ~prefix:"CHECKIN:" line with
          | Some s ->
              let s = normalize_proactive_text s in
              if s = "" then None else Some s
          | None -> None)
        lines
    in
    match checkin_line with
    | Some s -> Some s
    | None -> Some cleaned

let proactive_has_terminal_punct (s : string) : bool =
  let t = String.trim s in
  t <> "" && Str.string_match (Str.regexp ".*[.!?。！？]$") t 0

let proactive_has_terminal_korean_ending (s : string) : bool =
  let t = String.trim s in
  t <> ""
  && Str.string_match
       (Str.regexp ".*\\(다\\|요\\|니다\\|습니다\\|중입니다\\|함\\)$")
       t 0

let proactive_has_terminal_ending (s : string) : bool =
  proactive_has_terminal_punct s || proactive_has_terminal_korean_ending s

let proactive_looks_fragmentary (s : string) : bool =
  let t = String.trim s in
  t = ""
  || Str.string_match (Str.regexp ".*[\"'([{]$") t 0
  || Str.string_match (Str.regexp ".*[:;,\\-]$") t 0

let proactive_fallback_reply ~(meta : keeper_meta) ~(idle_seconds : int) : string =
  let goal =
    let g = String.trim meta.goal in
    if g = "" then "현재 목표" else g
  in
  let goal_phrase =
    goal
    |> Str.global_replace (Str.regexp "[.!?。！？]+$") ""
    |> String.trim
    |> fun s -> if s = "" then goal else s
  in
  let soul_hint =
    match String.lowercase_ascii (String.trim meta.soul_profile) with
    | "safety" -> "리스크 우선 점검을 마쳤고"
    | "delivery" -> "실행 단위로 정리해 두었고"
    | "research" -> "가설 검증 포인트를 갱신했고"
    | _ -> "진행 상태를 점검했고"
  in
  let templates =
    [|
      Printf.sprintf
        "%s %s, 다음 지시를 받으면 즉시 진행하겠습니다."
        goal soul_hint;
      Printf.sprintf
        "현재는 %s에 맞춰 대기 중이며, 새 입력이 오면 바로 실행 단계로 전환하겠습니다."
        goal_phrase;
      Printf.sprintf
        "%s 기준으로 우선순위를 업데이트했습니다. 다음 턴에서 바로 이어가겠습니다."
        goal;
      Printf.sprintf
        "idle %ds 동안 %s 관련 체크를 유지했습니다. 후속 요청에 맞춰 계속 진행하겠습니다."
        idle_seconds goal_phrase;
    |]
  in
  let idx =
    abs (Hashtbl.hash (meta.name, meta.proactive_count_total, idle_seconds))
    mod Array.length templates
  in
  templates.(idx)

let proactive_quality_check (raw : string) : (string, string) result =
  match extract_checkin_text raw with
  | None -> Error "empty"
  | Some text ->
      if proactive_looks_fragmentary text then Error "fragmentary"
      else if not (proactive_has_terminal_ending text) then Error "missing_terminal_ending"
      else Ok text

let looks_fragmentary_history_text (raw : string) : bool =
  let t = normalize_proactive_text raw in
  if t = "" then true
  else
    let hard_fragment = proactive_looks_fragmentary t in
    let has_terminal = proactive_has_terminal_ending t in
    let ends_korean_sentence =
      Str.string_match
        (Str.regexp ".*\\(다\\|요\\|니다\\|습니다\\|중입니다\\|함\\)$")
        t 0
    in
    let short_unterminated =
      (not has_terminal) && (not ends_korean_sentence) && String.length t <= 24
    in
    let trailing_connector =
      (not has_terminal)
      && Str.string_match
           (Str.regexp
              ".*\\(and\\|or\\|with\\|to\\|for\\|그리고\\|또는\\|및\\)$")
           (String.lowercase_ascii t) 0
    in
    hard_fragment || short_unterminated || trailing_connector

let run_proactive_generation
    ~(specs : Llm_client.model_spec list)
    ~(primary : Llm_client.model_spec)
    ~(config : Room.config)
    ~(ctx_work : Context_manager.working_context)
    ~(meta : keeper_meta)
    ~(continuity_snapshot : keeper_state_snapshot option)
    ~(continuity_summary : string)
    ~(idle_seconds : int) : proactive_generation_result option =
  let base_prompt =
    proactive_prompt_for_keeper ~meta ~idle_seconds continuity_snapshot continuity_summary
  in
  let zero_usage : Llm_client.token_usage =
    { Llm_client.input_tokens = 0; output_tokens = 0; total_tokens = 0;
      cache_creation_input_tokens = 0; cache_read_input_tokens = 0; }
  in
  let max_attempts = 3 in
  let previous_preview = String.trim meta.last_proactive_preview in
  let similarity_threshold = 0.72 in
  let fallback_skill_route =
    route_keeper_skill ~soul_profile:meta.soul_profile ~message:"proactive idle automation checkin"
  in
  let skill_selection_mode = keeper_skill_selection_mode () in
  let base_turn_system_prompt =
    match skill_selection_mode with
    | SkillSelectHeuristic ->
        skill_route_system_prompt_heuristic
          ~base_system_prompt:ctx_work.system_prompt
          ~route:fallback_skill_route
    | SkillSelectAgent ->
        skill_route_system_prompt_agent
          ~base_system_prompt:ctx_work.system_prompt
          ~fallback_route:fallback_skill_route
          ~soul_profile:meta.soul_profile
  in
  let turn_system_prompt =
    append_continuity_context_prompt
      ~base_prompt:base_turn_system_prompt
      continuity_snapshot
      ~continuity_summary
  in
  let max_tool_rounds = 3 in
  let execute_tool_calls
      ~(ctx_work : Context_manager.working_context)
      (tcs : Llm_client.tool_call list) : (Llm_client.tool_call * string) list =
    List.map
      (fun (tc : Llm_client.tool_call) ->
         let output =
           try execute_keeper_tool_call ~config ~meta ~ctx_work tc
           with exn ->
             Yojson.Safe.to_string
               (`Assoc [
                 ("error", `String (Printexc.to_string exn));
                 ("tool", `String tc.call_name);
               ])
         in
         (tc, output))
      tcs
  in
  let run_cascade requests = Llm_client.cascade requests in
  let rec loop attempt usage_acc latency_acc cost_acc retry_hint =
    if attempt > max_attempts then
      Some {
        reply = proactive_fallback_reply ~meta ~idle_seconds;
        usage = usage_acc;
        model_used = primary.model_id;
        latency_ms = latency_acc;
        attempts = max_attempts;
        total_cost_usd = cost_acc;
        fallback_applied = true;
        tools_used = [];
      }
    else
      let prompt =
        if String.trim retry_hint = "" then base_prompt
        else Printf.sprintf "%s\n\n%s" base_prompt retry_hint
      in
      let requests =
        List.map
          (fun (model : Llm_client.model_spec) ->
            ({
               Llm_client.model;
               messages =
                 (Llm_client.system_msg turn_system_prompt)
                 :: (ctx_work.messages @ [ Llm_client.user_msg prompt ]);
               temperature = proactive_temperature attempt;
               max_tokens = 1024; (* increased from 220 to allow tool calls *)
               tools = keeper_llm_tools;
               response_format = `Text;
             }
              : Llm_client.completion_request))
          specs
      in
      match run_cascade requests with
      | Error _ -> None
      | Ok resp0 ->
          let used_model0 =
            model_spec_for_used specs resp0.model_used
            |> Option.value ~default:primary
          in
          let cost0 = cost_usd_of_usage resp0.usage used_model0 in
          let rec tool_loop ~round ~acc_usage ~acc_latency ~acc_cost
              ~acc_tools_used ~last_resp =
            if last_resp.Llm_client.tool_calls = [] || round > max_tool_rounds then
              let content =
                let c = String.trim last_resp.Llm_client.content in
                if c = "" && acc_tools_used <> [] then
                  Printf.sprintf "(tools executed: %s)"
                    (String.concat ", " acc_tools_used)
                else last_resp.Llm_client.content
              in
              ( content,
                acc_usage,
                last_resp.Llm_client.model_used,
                acc_latency,
                acc_cost,
                acc_tools_used )
            else
              let round_tools =
                List.map
                  (fun (tc : Llm_client.tool_call) -> tc.call_name)
                  last_resp.Llm_client.tool_calls
              in
              let all_tools_so_far = acc_tools_used @ round_tools in
              let tool_outputs =
                execute_tool_calls ~ctx_work last_resp.Llm_client.tool_calls
              in
              let followup_prompt =
                keeper_tool_followup_prompt
                  ~user_message:prompt
                  ~draft_reply:last_resp.Llm_client.content
                  ~tool_outputs
                  ~already_executed:all_tools_so_far
              in
              let write_done =
                List.exists
                  (fun n ->
                     List.mem n
                       [
                         "keeper_board_post";
                         "keeper_board_comment";
                         "keeper_fs_edit";
                         "keeper_edit";
                       ])
                  all_tools_so_far
              in
              let next_tools =
                if write_done then [] else keeper_llm_tools
              in
              let followup_requests =
                List.map
                  (fun (model : Llm_client.model_spec) ->
                     ({
                        Llm_client.model;
                        messages = [
                          Llm_client.system_msg
                            (keeper_tool_loop_system_prompt
                               ~character_context:turn_system_prompt);
                          Llm_client.user_msg followup_prompt;
                        ];
                        temperature = 0.3;
                        max_tokens = 1024; (* increased from 220 to allow tool calls *)
                        tools = next_tools;
                        response_format = `Text;
                      }
                       : Llm_client.completion_request))
                  specs
              in
              match run_cascade followup_requests with
              | Error _ ->
                  ( last_resp.Llm_client.content,
                    acc_usage,
                    last_resp.Llm_client.model_used,
                    acc_latency,
                    acc_cost,
                    acc_tools_used @ round_tools )
              | Ok resp_next ->
                  let used_model_next =
                    model_spec_for_used specs resp_next.model_used
                    |> Option.value ~default:primary
                  in
                  let cost_next = cost_usd_of_usage resp_next.usage used_model_next in
                  tool_loop
                    ~round:(round + 1)
                    ~acc_usage:(merge_usage acc_usage resp_next.usage)
                    ~acc_latency:(acc_latency + resp_next.latency_ms)
                    ~acc_cost:(acc_cost +. cost_next)
                    ~acc_tools_used:(acc_tools_used @ round_tools)
                    ~last_resp:resp_next
          in
          let (attempt_content, attempt_usage, attempt_model_used, attempt_latency_ms,
               attempt_cost_usd, attempt_tools_used) =
            tool_loop
              ~round:1
              ~acc_usage:resp0.usage
              ~acc_latency:resp0.latency_ms
              ~acc_cost:cost0
              ~acc_tools_used:[]
              ~last_resp:resp0
          in
          let usage_acc = merge_usage usage_acc attempt_usage in
          let latency_acc = latency_acc + attempt_latency_ms in
          let cost_acc = cost_acc +. attempt_cost_usd in
          let trimmed = String.trim attempt_content in
          if trimmed <> "" then
            (match proactive_quality_check trimmed with
             | Error reason when attempt < max_attempts ->
                 let hint =
                   proactive_retry_instruction (attempt + 1) ~reason
                 in
                 loop (attempt + 1) usage_acc latency_acc cost_acc hint
             | Error _ ->
                 Some {
                   reply = proactive_fallback_reply ~meta ~idle_seconds;
                   usage = usage_acc;
                   model_used = attempt_model_used;
                   latency_ms = latency_acc;
                   attempts = attempt;
                   total_cost_usd = cost_acc;
                   fallback_applied = true;
                   tools_used = attempt_tools_used;
                 }
             | Ok checked_reply ->
                 let too_similar =
                   if previous_preview = "" then false
                   else
                     proactive_similarity_score
                       ~candidate:checked_reply
                       ~previous:previous_preview
                     >= similarity_threshold
                 in
                 if too_similar && attempt < max_attempts then
                   let hint =
                     proactive_retry_instruction (attempt + 1) ~reason:"too_similar"
                   in
                   loop (attempt + 1) usage_acc latency_acc cost_acc hint
                 else
                   Some {
                     reply = checked_reply;
                     usage = usage_acc;
                     model_used = attempt_model_used;
                     latency_ms = latency_acc;
                     attempts = attempt;
                     total_cost_usd = cost_acc;
                     fallback_applied = false;
                     tools_used = attempt_tools_used;
                   })
          else
            let hint =
              proactive_retry_instruction (attempt + 1) ~reason:"empty"
            in
            loop (attempt + 1) usage_acc latency_acc cost_acc hint
  in
  loop 1 zero_usage 0 0.0 ""

let memory_check_default_json () : Yojson.Safe.t =
  `Assoc [
    ("performed", `Bool false);
    ("query_kind", `String "none");
    ("expected_topic", `Null);
    ("candidate_count", `Int 0);
    ("initial_score", `Float 0.0);
    ("final_score", `Float 0.0);
    ("threshold", `Float 0.18);
    ("passed", `Bool true);
    ("best_match", `Null);
    ("correction_applied", `Bool false);
    ("correction_success", `Bool false);
    ("prompt_fallback_applied", `Bool false);
    ("prompt_fallback_success", `Bool false);
    ("deterministic_fallback_applied", `Bool false);
    ("recall_fallback_applied", `Bool false);
  ]

(** Check if keeper autonomy engine is enabled via environment variable. *)
let keeper_autonomy_enabled () =
  match Sys.getenv_opt "MASC_KEEPER_AUTONOMY_ENABLED" with
  | Some s -> String.lowercase_ascii (String.trim s) = "true"
  | None -> false

(* ================================================================ *)
(* Autonomous Execution Engine (Phase 5)                            *)
(* ================================================================ *)

(** Gate config for autonomous keeper execution.
    Restricts allowed tools to safe, read-only + board operations.
    @since 2.74.0 *)
let autonomous_gate_config
    ~(autonomy_level : Keeper_autonomy.autonomy_level) : Eval_gate.gate_config =
  let base_allowed = [
    "keeper_board_post"; "keeper_board_comment"; "keeper_board_list";
    "keeper_read"; "keeper_fs_read";
    "keeper_memory_search";
    "keeper_time_now"; "keeper_context_status";
  ] in
  let base_denied = [
    "keeper_bash"; "keeper_edit"; "keeper_fs_edit"; "keeper_github";
  ] in
  match autonomy_level with
  | L4_Autonomous ->
      (* L4: allow bash for safe commands *)
      {
        max_cost_usd = 0.10;
        max_tool_calls_per_turn = 5;
        entropy_threshold = 2;
        destructive_check_enabled = true;
        allowlist_enabled = true;
        allowed_tools = "keeper_bash" :: base_allowed;
        denied_tools = List.filter (fun t -> t <> "keeper_bash") base_denied;
      }
  | L5_Independent ->
      (* L5: all tools allowed, higher budget *)
      {
        max_cost_usd = 0.50;
        max_tool_calls_per_turn = 10;
        entropy_threshold = 3;
        destructive_check_enabled = true;
        allowlist_enabled = false;
        allowed_tools = [];
        denied_tools = [];
      }
  | _ ->
      (* L3 and below: strict safe-only *)
      {
        max_cost_usd = 0.10;
        max_tool_calls_per_turn = 5;
        entropy_threshold = 2;
        destructive_check_enabled = true;
        allowlist_enabled = true;
        allowed_tools = base_allowed;
        denied_tools = base_denied;
      }

(** Execute an approved/cautioned action plan via LLM + tool loop with gate sandboxing.

    1. Inject plan text into LLM system prompt
    2. LLM generates tool_calls based on plan
    3. Each tool_call goes through Eval_gate.guarded_execute
    4. Recursive tool_loop (max 3 rounds)
    5. Returns execution summary

    @since 2.74.0 *)
let execute_approved_plan
    ~(config : Room.config)
    ~(meta : keeper_meta)
    ~(specs : Llm_client.model_spec list)
    ~(plan : string)
    ~(pa : Keeper_autonomy.proposed_action)
    ~(autonomy_level : Keeper_autonomy.autonomy_level)
    ~(trajectory_acc : Trajectory.accumulator option)
    : string * float * string list =
  let gate_config = autonomous_gate_config ~autonomy_level in
  let primary = match specs with p :: _ -> p | [] -> Llm_client.default_local_model_spec () in
  let system_prompt = Printf.sprintf
{|You are a keeper agent executing an approved action plan.
Your name: %s
Goal: %s (id=%s)

Approved Plan:
%s

Execute step 1 of this plan using the available tools.
Be concise. Only use tools that directly advance the plan.
Do NOT use destructive tools (bash rm, edit, delete).|}
    meta.name pa.goal_title pa.goal_id plan
  in
  let ctx_work = Context_manager.create
    ~system_prompt:(Printf.sprintf "Keeper %s autonomous execution" meta.name)
    ~max_tokens:4000 in
  let execute_tool_calls
      (tcs : Llm_client.tool_call list) : (Llm_client.tool_call * string) list =
    List.map
      (fun (tc : Llm_client.tool_call) ->
         let execute () =
           execute_keeper_tool_call ~config ~meta ~ctx_work tc
         in
         let (decision, result_opt, _post_eval, duration_ms) =
           Eval_gate.guarded_execute
             ~config:gate_config
             ~accumulated_cost:0.0
             ~trajectory_acc
             ~tool_name:tc.call_name
             ~args_json:tc.call_arguments
             ~execute
         in
         let result = match decision, result_opt with
           | Trajectory.Reject reason, _ ->
               Printf.eprintf "[keeper-autonomy] GATE BLOCKED %s: %s\n%!"
                 tc.call_name reason;
               Yojson.Safe.to_string (`Assoc [("gate_blocked", `String tc.call_name); ("reason", `String reason)])
           | _, Some r -> r
           | _, None -> "{\"error\":\"no result\"}"
         in
         (* Record to trajectory *)
         (match trajectory_acc with
          | Some acc ->
              Trajectory.record_entry acc {
                ts = Time_compat.now ();
                ts_iso = Types.now_iso ();
                turn = acc.Trajectory.turn;
                round = 0;
                tool_name = tc.call_name;
                args_json = tc.call_arguments;
                gate_decision = decision;
                result = Some (if String.length result > 500
                          then String.sub result 0 500 ^ "..."
                          else result);
                duration_ms;
                error = None;
                cost_usd = 0.0;
              }
          | None -> ());
         (tc, result))
      tcs
  in
  let run_cascade requests = Llm_client.cascade requests in
  let max_rounds = 3 in
  let initial_request =
    { Llm_client.model = primary;
      messages = [
        Llm_client.system_msg system_prompt;
        Llm_client.user_msg "Execute the first step of the plan now.";
      ];
      temperature = 0.3;
      max_tokens = 1024;
      tools = keeper_llm_tools;
      response_format = `Text;
    }
  in
  let requests = List.map (fun (spec : Llm_client.model_spec) ->
    { initial_request with Llm_client.model = spec }
  ) specs in
  match run_cascade requests with
  | Error e ->
      (Printf.sprintf "LLM cascade failed: %s" e, 0.0, [])
  | Ok resp0 ->
      let rec exec_loop ~round ~acc_cost ~acc_tools ~last_resp =
        if last_resp.Llm_client.tool_calls = [] || round > max_rounds then
          let content =
            let c = String.trim last_resp.Llm_client.content in
            if c = "" && acc_tools <> [] then
              Printf.sprintf "(autonomous execution: %s)"
                (String.concat ", " acc_tools)
            else c
          in
          (content, acc_cost, acc_tools)
        else
          let round_tools =
            List.map (fun (tc : Llm_client.tool_call) -> tc.call_name)
              last_resp.Llm_client.tool_calls
          in
          let all_tools = acc_tools @ round_tools in
          let tool_outputs = execute_tool_calls last_resp.Llm_client.tool_calls in
          let followup_prompt =
            keeper_tool_followup_prompt
              ~user_message:"Execute the next step of the plan."
              ~draft_reply:last_resp.Llm_client.content
              ~tool_outputs
              ~already_executed:all_tools
          in
          (* Stop providing tools after write operations *)
          let write_done =
            List.exists (fun n ->
              List.mem n ["keeper_board_post"; "keeper_board_comment"])
              all_tools
          in
          let next_tools = if write_done then [] else keeper_llm_tools in
          let followup_requests = List.map (fun (spec : Llm_client.model_spec) ->
            { Llm_client.model = spec;
              messages = [
                Llm_client.system_msg system_prompt;
                Llm_client.user_msg followup_prompt;
              ];
              temperature = 0.3;
              max_tokens = 1024;
              tools = next_tools;
              response_format = `Text;
            }
          ) specs in
          match run_cascade followup_requests with
          | Error _ ->
              (last_resp.Llm_client.content, acc_cost, all_tools)
          | Ok next_resp ->
              let used_spec =
                model_spec_for_used specs next_resp.model_used
                |> Option.value ~default:primary
              in
              let round_cost = cost_usd_of_usage next_resp.usage used_spec in
              exec_loop ~round:(round + 1)
                ~acc_cost:(acc_cost +. round_cost)
                ~acc_tools:all_tools
                ~last_resp:next_resp
      in
      let used_spec0 =
        model_spec_for_used specs resp0.model_used
        |> Option.value ~default:primary
      in
      let cost0 = cost_usd_of_usage resp0.usage used_spec0 in
      exec_loop ~round:1 ~acc_cost:cost0 ~acc_tools:[] ~last_resp:resp0

(** Autonomous goal turn: evaluate goals and optionally generate/verify action plan.
    Returns Some updated_meta when an autonomous action decision was made,
    None to fall through to regular proactive generation.
    @since 2.74.0 *)
let run_autonomous_goal_turn ~(config : Room.config) ~(meta : keeper_meta)
    ~(specs : Llm_client.model_spec list) : keeper_meta option =
  if not (keeper_autonomy_enabled ()) then None
  else if meta.active_goal_ids = [] then None
  else
    match Keeper_autonomy.autonomy_level_of_string meta.autonomy_level with
    | None -> None
    | Some L1_Reactive -> None
    | Some level ->
        let primary = match specs with p :: _ -> p | [] -> Llm_client.default_local_model_spec () in
        let verify_model =
          match Llm_client.default_verifier_model_spec () with
          | Ok model -> model
          | Error _ -> primary
        in
        let keeper_context =
          Printf.sprintf "keeper=%s autonomy=%s turns=%d cost=$%.4f"
            meta.name (Keeper_autonomy.autonomy_level_to_string level)
            meta.total_turns meta.total_cost_usd
        in
        match level with
        | L1_Reactive -> None
        | L2_Suggestive ->
            (* L2: evaluate and post suggestion to Board *)
            let next = Keeper_autonomy.evaluate_next_action
              ~config ~goal_ids:meta.active_goal_ids ~keeper_name:meta.name in
            (match next with
             | Propose pa ->
                 Printf.eprintf "[keeper-autonomy] %s L2 suggest: %s (risk=%s, cost=$%.2f)\n%!"
                   meta.name pa.action_description
                   (Keeper_autonomy.risk_level_to_string pa.risk_level)
                   pa.estimated_cost_usd;
                 let board_args = `Assoc [
                   ("author", `String meta.name);
                   ("title", `String (Printf.sprintf "[L2 제안] %s" pa.goal_title));
                   ("content", `String (Printf.sprintf
                     "**제안 액션**: %s\n\n- Risk: %s\n- Estimated cost: $%.2f\n- Goal: %s (id=%s)"
                     pa.action_description
                     (Keeper_autonomy.risk_level_to_string pa.risk_level)
                     pa.estimated_cost_usd
                     pa.goal_title pa.goal_id));
                   ("tags", `List [
                     `String "keeper-autonomy";
                     `String "L2-suggestion";
                     `String meta.name;
                   ]);
                 ] in
                 let (ok, _msg) = Tool_board.handle_tool "masc_board_post" board_args in
                 if not ok then
                   Printf.eprintf "[keeper-autonomy] %s L2 board post failed\n%!" meta.name;
                 Some { meta with
                   last_autonomous_action_at = now_iso ();
                   autonomous_action_count = meta.autonomous_action_count + 1;
                   updated_at = now_iso ();
                 }
             | StartPerpetualAgent req ->
                 Printf.eprintf "[keeper-autonomy] %s L2 perpetual suggest: %s\n%!"
                   meta.name req.goal_title;
                 let board_args = `Assoc [
                   ("author", `String meta.name);
                   ("title", `String (Printf.sprintf "[L2 제안] Perpetual Agent: %s" req.goal_title));
                   ("content", `String (Printf.sprintf
                     "**장기 목표 감지**: %s\n\n이 목표는 Perpetual Agent가 적합합니다.\n- Models: %s\n- Coding mode: %b\n- Agent: %s\n\nL3+ 자율성에서 자동 시작됩니다."
                     req.goal_title
                     (String.concat ", " req.models)
                     req.coding_mode
                     req.coding_agent));
                   ("tags", `List [
                     `String "keeper-autonomy";
                     `String "perpetual-suggestion";
                     `String meta.name;
                   ]);
                 ] in
                 (match Tool_board.handle_tool "masc_board_post" board_args with
                  | (true, _) -> ()
                  | (false, err) ->
                      Printf.eprintf "[keeper-autonomy] %s L2 perpetual board post failed: %s\n%!" meta.name err
                  | exception exn ->
                      Printf.eprintf "[keeper-autonomy] %s L2 board post error: %s\n%!" meta.name (Printexc.to_string exn));
                 Some { meta with
                   last_autonomous_action_at = now_iso ();
                   autonomous_action_count = meta.autonomous_action_count + 1;
                   updated_at = now_iso ();
                 }
             | _ -> None)
        | _ ->
            (* L3+: full pipeline — evaluate, plan, verify, decide *)
            let result = Keeper_verifier.run_pipeline
              ~config
              ~goal_ids:meta.active_goal_ids
              ~keeper_name:meta.name
              ~keeper_context
              ~plan_model:primary
              ~verify_model
              ~autonomy_level:level
            in
            (match result with
             | NothingToDo reason ->
                 Printf.eprintf "[keeper-autonomy] %s: nothing to do (%s)\n%!" meta.name reason;
                 None
             | PerpetualRequested req ->
                 Printf.eprintf "[keeper-autonomy] %s PERPETUAL: starting for %s\n%!"
                   meta.name req.goal_title;
                 (* Keeper runs in heartbeat timer context without Eio.Switch.t,
                    so coding_mode (= Claude Code spawn) is structurally unavailable.
                    Force LLM-only mode to prevent guaranteed failure. *)
                 let effective_coding_mode = false in
                 (if req.coding_mode then
                    Printf.eprintf "[keeper-autonomy] %s: coding_mode requested but unavailable (no Eio.Switch in heartbeat context), falling back to LLM-only\n%!" meta.name);
                 let perp_args = `Assoc [
                   ("goal", `String req.goal_title);
                   ("models", `List (List.map (fun m -> `String m) req.models));
                   ("coding_mode", `Bool effective_coding_mode);
                   ("coding_agent", `String req.coding_agent);
                 ] in
                 let perp_ctx = {
                   Tool_perpetual.agent_name = meta.name;
                   start_loop = None;
                   sw = None;
                   proc_mgr = None;
                 } in
                 (match Tool_perpetual.dispatch perp_ctx ~name:"masc_perpetual_start" ~args:perp_args with
                  | Some (true, result_json) ->
                      Printf.eprintf "[keeper-autonomy] %s perpetual started: %s\n%!"
                        meta.name result_json;
                      (* Update goal with perpetual agent info *)
                      (try ignore (Goal_store.review_goal config
                        ~goal_id:req.goal_id ~outcome:"progress"
                        ~note:(Printf.sprintf "Perpetual agent started (models: %s)"
                          (String.concat ", " req.models)) ()) with exn ->
                        Printf.eprintf "[keeper] goal review failed: %s\n%!" (Printexc.to_string exn));
                      (* Post to Board *)
                      let board_args = `Assoc [
                        ("author", `String meta.name);
                        ("title", `String (Printf.sprintf "[L%d Perpetual] %s"
                          (Keeper_autonomy.autonomy_level_to_int level) req.goal_title));
                        ("content", `String (Printf.sprintf
                          "Perpetual Agent started for long-horizon goal.\n\n- Goal: %s (id=%s)\n- Models: %s\n- Coding mode: %b"
                          req.goal_title req.goal_id
                          (String.concat ", " req.models) req.coding_mode));
                        ("tags", `List [
                          `String "keeper-autonomy";
                          `String "perpetual-start";
                          `String meta.name;
                        ]);
                      ] in
                      (match Tool_board.handle_tool "masc_board_post" board_args with
                       | (true, _) -> ()
                       | (false, err) ->
                           Printf.eprintf "[keeper-autonomy] %s: board post failed: %s\n%!" meta.name err
                       | exception exn ->
                           Printf.eprintf "[keeper-autonomy] %s: board post error: %s\n%!" meta.name (Printexc.to_string exn));
                      Some { meta with
                        last_autonomous_action_at = now_iso ();
                        autonomous_action_count = meta.autonomous_action_count + 1;
                        updated_at = now_iso ();
                      }
                  | Some (false, err) ->
                      Printf.eprintf "[keeper-autonomy] %s perpetual start failed: %s\n%!"
                        meta.name err;
                      None
                  | None ->
                      Printf.eprintf "[keeper-autonomy] %s perpetual dispatch returned None\n%!" meta.name;
                      None)
             | Approved (pa, plan) ->
                 Printf.eprintf "[keeper-autonomy] %s APPROVED: %s\n%!"
                   meta.name pa.action_description;
                 (* 5-3: Create trajectory accumulator for this autonomous turn *)
                 let masc_root = Filename.concat config.base_path ".masc" in
                 let traj_acc = Trajectory.create_accumulator
                   ~masc_root
                   ~keeper_name:meta.name
                   ~trace_id:(Printf.sprintf "keeper-auto-%s-%d"
                     meta.name meta.autonomous_action_count)
                   ~generation:meta.generation in
                 (* 5-4: SSE — keeper_autonomy_start *)
                 (try Sse.broadcast (`Assoc [
                   ("type", `String "keeper_autonomy_start");
                   ("name", `String meta.name);
                   ("goal_id", `String pa.goal_id);
                   ("action", `String pa.action_description);
                   ("autonomy_level", `String (Keeper_autonomy.autonomy_level_to_string level));
                 ]) with exn ->
                   Printf.eprintf "[keeper] SSE keeper_autonomy_start broadcast failed: %s\n%!" (Printexc.to_string exn));
                 (* 5-2: Execute the approved plan *)
                 let (summary, exec_cost, tools_used) =
                   execute_approved_plan ~config ~meta ~specs ~plan ~pa
                     ~autonomy_level:level ~trajectory_acc:(Some traj_acc) in
                 (* 5-3: Finalize trajectory *)
                 (try ignore (Trajectory.finalize traj_acc Trajectory.Completed)
                  with exn -> Printf.eprintf "[keeper] trajectory finalize failed: %s\n%!" (Printexc.to_string exn));
                 (* 5-3: Update goal progress *)
                 let outcome = if tools_used <> [] then "progress" else "blocked" in
                 let review_note = Printf.sprintf
                   "Autonomous execution (L%d): %s | tools: [%s] | cost: $%.4f"
                   (Keeper_autonomy.autonomy_level_to_int level)
                   (if String.length summary > 200 then String.sub summary 0 200 ^ "..." else summary)
                   (String.concat ", " tools_used)
                   exec_cost in
                 (try ignore (Goal_store.review_goal config
                   ~goal_id:pa.goal_id ~outcome ~note:review_note ()) with exn ->
                   Printf.eprintf "[keeper] goal review failed: %s\n%!" (Printexc.to_string exn));
                 (* 5-4: Post execution report to Board *)
                 let report_args = `Assoc [
                   ("author", `String meta.name);
                   ("title", `String (Printf.sprintf "[L%d 실행] %s"
                     (Keeper_autonomy.autonomy_level_to_int level) pa.goal_title));
                   ("content", `String (Printf.sprintf
                     "**실행 결과**: %s\n\n- Tools used: [%s]\n- Cost: $%.4f\n- Goal: %s (id=%s)\n- Outcome: %s"
                     (if String.length summary > 500 then String.sub summary 0 500 ^ "..." else summary)
                     (String.concat ", " tools_used) exec_cost
                     pa.goal_title pa.goal_id outcome));
                   ("tags", `List [
                     `String "keeper-autonomy";
                     `String "execution-report";
                     `String meta.name;
                   ]);
                 ] in
                 let (_ok, _msg) = Tool_board.handle_tool "masc_board_post" report_args in
                 (* 5-4: SSE — keeper_autonomy_complete *)
                 (try Sse.broadcast (`Assoc [
                   ("type", `String "keeper_autonomy_complete");
                   ("name", `String meta.name);
                   ("goal_id", `String pa.goal_id);
                   ("result", `String outcome);
                   ("tools_used", `List (List.map (fun t -> `String t) tools_used));
                   ("cost_usd", `Float exec_cost);
                 ]) with exn ->
                   Printf.eprintf "[keeper] SSE keeper_autonomy_complete broadcast failed: %s\n%!" (Printexc.to_string exn));
                 Some { meta with
                   last_autonomous_action_at = now_iso ();
                   autonomous_action_count = meta.autonomous_action_count + 1;
                   total_cost_usd = meta.total_cost_usd +. exec_cost;
                   updated_at = now_iso ();
                 }
             | Cautioned (pa, plan, warning) ->
                 Printf.eprintf "[keeper-autonomy] %s CAUTIONED: %s (warning: %s)\n%!"
                   meta.name pa.action_description warning;
                 (* 5-3: Trajectory with warning recorded *)
                 let masc_root = Filename.concat config.base_path ".masc" in
                 let traj_acc = Trajectory.create_accumulator
                   ~masc_root
                   ~keeper_name:meta.name
                   ~trace_id:(Printf.sprintf "keeper-auto-%s-%d-cautioned"
                     meta.name meta.autonomous_action_count)
                   ~generation:meta.generation in
                 (* Record caution warning to trajectory *)
                 Trajectory.record_entry traj_acc {
                   ts = Time_compat.now ();
                   ts_iso = Types.now_iso ();
                   turn = traj_acc.Trajectory.turn;
                   round = 0;
                   tool_name = "_caution_warning";
                   args_json = Yojson.Safe.to_string (`Assoc [("warning", `String warning)]);
                   gate_decision = Trajectory.Pass;
                   result = Some warning;
                   duration_ms = 0;
                   error = None;
                   cost_usd = 0.0;
                 };
                 (* 5-4: SSE — keeper_autonomy_start (cautioned) *)
                 (try Sse.broadcast (`Assoc [
                   ("type", `String "keeper_autonomy_start");
                   ("name", `String meta.name);
                   ("goal_id", `String pa.goal_id);
                   ("action", `String pa.action_description);
                   ("autonomy_level", `String (Keeper_autonomy.autonomy_level_to_string level));
                   ("caution", `String warning);
                 ]) with exn ->
                   Printf.eprintf "[keeper] SSE keeper_autonomy_start (cautioned) broadcast failed: %s\n%!" (Printexc.to_string exn));
                 (* 5-2: Execute despite caution *)
                 let (summary, exec_cost, tools_used) =
                   execute_approved_plan ~config ~meta ~specs ~plan ~pa
                     ~autonomy_level:level ~trajectory_acc:(Some traj_acc) in
                 (try ignore (Trajectory.finalize traj_acc Trajectory.Completed)
                  with exn -> Printf.eprintf "[keeper] trajectory finalize (cautioned) failed: %s\n%!" (Printexc.to_string exn));
                 (* 5-3: Update goal progress *)
                 let outcome = if tools_used <> [] then "progress" else "blocked" in
                 let review_note = Printf.sprintf
                   "Cautioned execution (L%d, warning: %s): %s | tools: [%s] | cost: $%.4f"
                   (Keeper_autonomy.autonomy_level_to_int level) warning
                   (if String.length summary > 150 then String.sub summary 0 150 ^ "..." else summary)
                   (String.concat ", " tools_used)
                   exec_cost in
                 (try ignore (Goal_store.review_goal config
                   ~goal_id:pa.goal_id ~outcome ~note:review_note ()) with exn ->
                   Printf.eprintf "[keeper] goal review (cautioned) failed: %s\n%!" (Printexc.to_string exn));
                 (* 5-4: Board report + SSE complete *)
                 let report_args = `Assoc [
                   ("author", `String meta.name);
                   ("title", `String (Printf.sprintf "[L%d 실행⚠] %s"
                     (Keeper_autonomy.autonomy_level_to_int level) pa.goal_title));
                   ("content", `String (Printf.sprintf
                     "**경고**: %s\n\n**실행 결과**: %s\n\n- Tools: [%s]\n- Cost: $%.4f\n- Goal: %s (id=%s)"
                     warning
                     (if String.length summary > 400 then String.sub summary 0 400 ^ "..." else summary)
                     (String.concat ", " tools_used) exec_cost
                     pa.goal_title pa.goal_id));
                   ("tags", `List [
                     `String "keeper-autonomy";
                     `String "execution-report";
                     `String "cautioned";
                     `String meta.name;
                   ]);
                 ] in
                 let (_ok, _msg) = Tool_board.handle_tool "masc_board_post" report_args in
                 (try Sse.broadcast (`Assoc [
                   ("type", `String "keeper_autonomy_complete");
                   ("name", `String meta.name);
                   ("goal_id", `String pa.goal_id);
                   ("result", `String outcome);
                   ("tools_used", `List (List.map (fun t -> `String t) tools_used));
                   ("cost_usd", `Float exec_cost);
                   ("warning", `String warning);
                 ]) with exn ->
                   Printf.eprintf "[keeper] SSE keeper_autonomy_complete (cautioned) broadcast failed: %s\n%!" (Printexc.to_string exn));
                 Some { meta with
                   last_autonomous_action_at = now_iso ();
                   autonomous_action_count = meta.autonomous_action_count + 1;
                   total_cost_usd = meta.total_cost_usd +. exec_cost;
                   updated_at = now_iso ();
                 }
             | Rejected (pa, reason) ->
                 Printf.eprintf "[keeper-autonomy] %s REJECTED: %s (%s)\n%!"
                   meta.name pa.action_description reason;
                 None)

let maybe_emit_proactive (ctx : _ context) (meta : keeper_meta) : keeper_meta =
  if not meta.proactive_enabled then meta
  else
    let now_ts = Time_compat.now () in
    let created_ts =
      Resilience.Time.parse_iso8601_opt meta.created_at |> Option.value ~default:0.0
    in
    let activity_ts =
      let base = max meta.last_turn_ts meta.last_proactive_ts in
      if base > 0.0 then base else created_ts
    in
    let idle_seconds =
      if activity_ts <= 0.0 then 0 else int_of_float (max 0.0 (now_ts -. activity_ts))
    in
    let idle_gate = normalize_proactive_idle_sec meta.proactive_idle_sec in
    let cooldown_gate = normalize_proactive_cooldown_sec meta.proactive_cooldown_sec in
    let cooldown_elapsed =
      if meta.last_proactive_ts <= 0.0 then max_int
      else int_of_float (max 0.0 (now_ts -. meta.last_proactive_ts))
    in
    if idle_seconds < idle_gate || cooldown_elapsed < cooldown_gate then meta
    else
      match model_specs_of_strings meta.models with
      | Error _ -> meta
      | Ok specs ->
          (match ensure_api_keys specs with
           | Error _ -> meta
           | Ok () ->
               (* Phase 2: Autonomous goal turn (L2+ with active goals) *)
               (match run_autonomous_goal_turn ~config:ctx.config ~meta ~specs with
                | Some updated_meta ->
                    (match write_meta ctx.config updated_meta with
                     | Ok () -> ()
                     | Error msg ->
                         Printf.eprintf "[keeper] write_meta failed after goal turn: %s\n%!" msg);
                    updated_meta
                | None ->
               let primary =
                 match specs with
                 | p :: _ -> p
                 | [] -> Llm_client.default_local_model_spec ()
               in
               let base_dir = session_base_dir ctx.config in
               let (session, ctx_opt) =
                 load_context_from_checkpoint
                   ~trace_id:meta.trace_id
                   ~primary_model_max_tokens:primary.max_context
                   ~base_dir
               in
               match ctx_opt with
               | None -> meta
               | Some ctx_work ->
                   let continuity_snapshot = latest_state_snapshot_from_messages ctx_work.messages in
                   let continuity_summary =
                     match continuity_snapshot with
                     | Some s -> keeper_state_snapshot_to_summary_text s
                     | None -> (
                         let trimmed = String.trim meta.continuity_summary in
                         if trimmed = "" then "No continuity snapshot available." else trimmed)
                   in
                   let continuity_summary = String.trim continuity_summary in
                   let last_continuity_update_ts =
                     if
                       continuity_summary <> ""
                       && String.trim meta.continuity_summary <> continuity_summary
                     then
                       now_ts
                     else
                       meta.last_continuity_update_ts
                   in
                   let meta_for_compaction =
                     { meta with
                       continuity_summary;
                       last_continuity_update_ts
                     }
                   in
                   match
                     run_proactive_generation
                       ~specs
                       ~primary
                       ~config:ctx.config
                       ~ctx_work
                       ~meta
                       ~continuity_snapshot
                       ~continuity_summary
                       ~idle_seconds
                   with
                       | None -> meta
	                   | Some generated ->
	                       let model_used =
	                         let m = String.trim generated.model_used in
	                         if m <> "" then m else primary.model_id
	                       in
	                       let proactive_skill_route =
	                         route_keeper_skill
	                           ~soul_profile:meta.soul_profile
	                           ~message:"proactive idle checkin"
	                       in
	                       let safe_reply = generated.reply in
	                       let assistant_msg = Llm_client.assistant_msg safe_reply in
	                       let ctx_work = Context_manager.append ctx_work assistant_msg in
                       Context_manager.persist_message session assistant_msg;
                       let before_compact_tokens = ctx_work.token_count in
                       let (ctx_work, compaction_trigger, compaction_decision) =
                        compact_if_needed ~meta:meta_for_compaction ~now_ts ctx_work
                       in
                       let after_compact_tokens = ctx_work.token_count in
                       let compacted = after_compact_tokens < before_compact_tokens in
                       (try ignore (save_checkpoint session ctx_work ~generation:meta.generation)
                        with exn -> Printf.eprintf "[keeper] save_checkpoint (tool_loop) failed: %s\n%!" (Printexc.to_string exn));
                       let turn_cost = generated.total_cost_usd in
                       let proactive_reason =
                         Printf.sprintf
                           "idle=%ds>=gate=%ds; cooldown_elapsed=%ds>=gate=%ds; soul=%s; skill=%s; attempts=%d; mode=tool_loop; tool_calls=%d; fallback=%d"
                           idle_seconds idle_gate cooldown_elapsed cooldown_gate meta.soul_profile
                           proactive_skill_route.primary_skill
                           generated.attempts
                           (List.length generated.tools_used)
                           (if generated.fallback_applied then 1 else 0)
                       in
                           let updated =
                             {
                               meta with
                           updated_at = now_iso ();
                           total_turns = meta.total_turns + 1;
                           total_input_tokens =
                             meta.total_input_tokens + generated.usage.input_tokens;
                           total_output_tokens =
                             meta.total_output_tokens + generated.usage.output_tokens;
                           total_tokens = meta.total_tokens + generated.usage.total_tokens;
                           total_cost_usd = meta.total_cost_usd +. turn_cost;
                           last_turn_ts = now_ts;
                           last_model_used = model_used;
                           last_input_tokens = generated.usage.input_tokens;
                           last_output_tokens = generated.usage.output_tokens;
                           last_total_tokens = generated.usage.total_tokens;
                           last_latency_ms = generated.latency_ms;
                           compaction_count =
                             meta.compaction_count + if compacted then 1 else 0;
                           last_compaction_check_ts = now_ts;
                           last_compaction_decision = compaction_decision;
                           last_compaction_ts =
                             if compacted then now_ts else meta.last_compaction_ts;
                           last_compaction_before_tokens =
                             if compacted
                             then before_compact_tokens
                             else meta.last_compaction_before_tokens;
                           last_compaction_after_tokens =
                             if compacted
                             then after_compact_tokens
                             else meta.last_compaction_after_tokens;
                           proactive_count_total = meta.proactive_count_total + 1;
                           last_proactive_ts = now_ts;
                           last_proactive_reason = proactive_reason;
                               last_proactive_preview = short_preview safe_reply;
                               continuity_summary;
                               last_continuity_update_ts;
                             }
                       in
                       (match write_meta ctx.config updated with
                        | Ok () -> ()
                        | Error msg ->
                            Printf.eprintf "[keeper] write_meta failed after proactive turn: %s\n%!" msg);
                       (try
                          let metrics_path = keeper_metrics_path ctx.config updated.name in
                          let metrics_json =
                            `Assoc
                              [
                                ("ts", `String (now_iso ()));
                                ("ts_unix", `Float now_ts);
                                ("channel", `String "proactive");
                                ("name", `String updated.name);
                                ("agent_name", `String updated.agent_name);
                                ("trace_id", `String updated.trace_id);
                                ("generation", `Int updated.generation);
                                ("model_used", `String model_used);
                                ( "usage",
                                  `Assoc
                                    [
                                      ("input_tokens", `Int generated.usage.input_tokens);
                                      ("output_tokens", `Int generated.usage.output_tokens);
                                      ("total_tokens", `Int generated.usage.total_tokens);
                                    ] );
                                ("latency_ms", `Int generated.latency_ms);
                                ("cost_usd", `Float turn_cost);
                                ("context_ratio", `Float (Context_manager.context_ratio ctx_work));
                                ("context_tokens", `Int ctx_work.token_count);
                                ("context_max", `Int ctx_work.max_tokens);
                                ("message_count", `Int (List.length ctx_work.messages));
                                ("compacted", `Bool compacted);
                                ("compaction_before_tokens", `Int before_compact_tokens);
                                ("compaction_after_tokens", `Int after_compact_tokens);
                                  ( "compaction_trigger",
                                    match compaction_trigger with
                                    | Some reason -> `String reason
                                    | None -> `Null );
                                ("compaction_decision", `String compaction_decision);
                                ("work_kind", `String "proactive_checkin");
	                                ("tool_call_count", `Int (List.length generated.tools_used));
	                                ("tools_used", `List (List.map (fun s -> `String s) generated.tools_used));
	                                ("skill_primary", `String proactive_skill_route.primary_skill);
	                                ("skill_secondary",
	                                  `List
	                                    (List.map
	                                       (fun s -> `String s)
	                                       proactive_skill_route.secondary_skills));
	                                ("skill_reason", `String proactive_skill_route.reason);
	                                ("memory_check", memory_check_default_json ());
	                                ("proactive", `Assoc [
                                  ("performed", `Bool true);
                                  ("attempts", `Int generated.attempts);
                                  ("fallback_applied", `Bool generated.fallback_applied);
                                  ("idle_seconds", `Int idle_seconds);
                                  ("idle_gate_seconds", `Int idle_gate);
                                  ("cooldown_elapsed_seconds", `Int cooldown_elapsed);
                                  ("cooldown_gate_seconds", `Int cooldown_gate);
                                  ("reason", `String proactive_reason);
                                  ("preview", `String (short_preview safe_reply));
                                ]);
                                ("handoff", `Assoc [ ("performed", `Bool false) ]);
                              ]
                          in
                          append_jsonl_line metrics_path metrics_json
                        with exn ->
                          Printf.eprintf "[keeper] metrics JSONL write failed: %s\n%!" (Printexc.to_string exn));
                       updated))

