[@@@warning "-32-69"]

(** Keeper_engine — proactive generation, autonomous execution engine,
    quality checks, and keepalive management for keeper agents.

    Includes [Keeper_execution] so consumers get the full tool-call loop,
    system prompts, and context management. *)

include Keeper_execution

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

