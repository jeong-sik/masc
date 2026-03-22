(** Keeper_exec_context — shared keeper context utilities: working context,
    checkpoint management, compaction, room presence, system prompts,
    text processing, proactive prompt helpers, and proactive generation.

    Pure types and context operations are provided by
    [Keeper_working_context] (included below). This module adds
    keeper-specific logic on top. *)

open Keeper_types
open Keeper_memory
open Keeper_alerting
open Keeper_exec_tools [@@warning "-33"]
open Keeper_exec_status

include Keeper_working_context

let timed = Inference_utils.timed
let zero_usage = Inference_utils.zero_usage
let usage_of_response = Inference_utils.usage_of_response
let total_tokens = Inference_utils.total_tokens

(* ================================================================ *)
(* Checkpoint Store Delegation                                        *)
(* ================================================================ *)

let save_session_checkpoint (session : session_context) ckpt =
  session.checkpoints <- session.checkpoints @ [ckpt];
  Keeper_checkpoint_store.save ~session_dir:session.session_dir ckpt

let load_latest_checkpoint (session : session_context) =
  Keeper_checkpoint_store.load_latest ~session_dir:session.session_dir

(* ================================================================ *)
(* Keeper Context Lifecycle                                          *)
(* ================================================================ *)

let log_keeper_exn ~label exn =
  let tag = match exn with
    | Sys_error _ | Failure _ | Not_found
    | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ""
    | _ -> "[UNEXPECTED] "
  in
  Log.Keeper.info "%s%s: %s" tag label (Printexc.to_string exn)

let load_context_from_checkpoint ~trace_id ~primary_model_max_tokens ~base_dir =
  let session = create_session ~session_id:trace_id ~base_dir in
  let latest_ckpt =
    try load_latest_checkpoint session
    with ex ->
      Log.Keeper.error "keeper:%s checkpoint load failed: %s"
        trace_id
        (Printexc.to_string ex);
      None
  in
  match latest_ckpt with
  | None -> (session, None)
  | Some ckpt ->
      (try
         let ctx =
           restore_checkpoint ckpt
             ~max_tokens:primary_model_max_tokens
         in
         (session, Some ctx)
       with ex ->
         Log.Keeper.error "keeper:%s checkpoint restore failed: %s"
           trace_id
           (Printexc.to_string ex);
         (session, None))

let save_checkpoint session (ctx : working_context) ~generation =
  let ckpt = create_checkpoint ctx ~generation in
  save_session_checkpoint session ckpt;
  ckpt

let compaction_policy_of_keeper (meta : keeper_meta) : float * int * int =
  (meta.compaction_ratio_gate, meta.compaction_message_gate, meta.compaction_token_gate)

let compact_if_needed
    ~(meta : keeper_meta)
    ~(now_ts : float)
    (ctx : working_context) :
    working_context * string option * string =
  let ratio = context_ratio ctx in
  let message_count = List.length ctx.messages in
  let token_count = ctx.token_count in
  let ratio_gate, message_gate, token_gate = compaction_policy_of_keeper meta in
  let cooldown = Float.of_int meta.continuity_compaction_cooldown_sec in
  let last_reflection_ts = max meta.last_continuity_update_ts meta.last_proactive_ts in
  let reflection_ready =
    last_reflection_ts > 0.0 && now_ts -. last_reflection_ts >= cooldown
  in
  let hold_s =
    if cooldown <= 0.0 then 0.0
    else if last_reflection_ts <= 0.0 then
      Float.of_int meta.continuity_compaction_cooldown_sec
    else
      max
        0.0
        (Float.of_int meta.continuity_compaction_cooldown_sec
       -. (now_ts -. last_reflection_ts))
  in
  let trigger_reason =
    if not reflection_ready then
      Some
        (Printf.sprintf
           "skipped:continuity_reflection(%0.0fs<%ds)"
           hold_s meta.continuity_compaction_cooldown_sec)
    else if ratio >= ratio_gate then
      Some (Printf.sprintf "ratio(%.4f>=%.4f)" ratio ratio_gate)
    else if message_gate > 0 && message_count >= message_gate then
      Some (Printf.sprintf "messages(%d>=%d)" message_count message_gate)
    else if token_gate > 0 && token_count >= token_gate then
      Some (Printf.sprintf "tokens(%d>=%d)" token_count token_gate)
    else None
  in
  match trigger_reason with
  | None -> (ctx, None, "blocked:below_thresholds")
  | Some reason ->
      if String.starts_with ~prefix:"skipped:" reason then
        (ctx, None, reason)
      else
        let messages, token_count =
          Context_compact_oas.compact
            ~system_prompt:ctx.system_prompt
            ~messages:ctx.messages
            ~strategies:Context_compact_oas.[
              PruneToolOutputs; MergeContiguous;
              DropLowImportance; SummarizeOld]
        in
        let compacted_ctx =
          sync_oas_context
            { ctx with messages; token_count; importance_scores = [] }
        in
        (compacted_ctx, Some reason, "applied:" ^ reason)

let generate_trace_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let hash = Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFF in
  Printf.sprintf "trace-%d-%05x" ts hash

let keeper_board_write_tool_names =
  [ "keeper_board_post"; "keeper_board_comment"; "keeper_board_vote" ]

let keeper_write_done tool_names =
  List.exists (fun name -> List.mem name keeper_board_write_tool_names) tool_names

let keeper_action_kind_of_tool_names tool_names =
  if List.mem "keeper_board_post" tool_names then "post"
  else if List.mem "keeper_board_comment" tool_names then "comment"
  else if List.mem "keeper_board_vote" tool_names then "vote"
  else "none"


let effective_model_labels_for_turn
    (m : keeper_meta)
    ~(inline_models : string list) : string list =
  if inline_models <> [] then
    inline_models
  else
    match active_model_of_meta m with
    | "" ->
        let pool = dedupe_keep_order (m.allowed_models @ m.models) in
        if pool = [] then m.models else pool
    | model -> [ model ]

let room_cursor_for meta room_id =
  meta.last_seen_seq_by_room
  |> List.find_map (fun (rid, seq) -> if rid = room_id then Some seq else None)
  |> Option.value ~default:0

let set_room_cursor meta room_id seq =
  let kept =
    meta.last_seen_seq_by_room
    |> List.filter (fun (rid, _) -> rid <> room_id)
  in
  {
    meta with
    last_seen_seq_by_room = dedupe_keep_order ((room_id, seq) :: kept);
  }

let room_ids_for_meta config (meta : keeper_meta) : string list =
  match Keeper_contract.room_scope_of_string meta.room_scope with
  | Keeper_contract.All ->
      let open Yojson.Safe.Util in
      let listed =
        match Room.rooms_list config |> member "rooms" with
        | `List rooms ->
            rooms
            |> List.filter_map (fun room ->
                   match room |> member "id" with
                   | `String room_id when validate_name room_id -> Some room_id
                   | _ -> None)
        | _ -> []
      in
      let current = Room.current_room_id config in
      dedupe_keep_order (current :: listed)
  | Keeper_contract.Current -> [ Room.current_room_id config ]

let ensure_keeper_room_presence config (meta : keeper_meta) : keeper_meta =
  let room_ids = room_ids_for_meta config meta in
  let successful_rooms =
    List.fold_left
      (fun acc room_id ->
        try
          if
            not
              (Room.is_agent_joined_in_room config ~room_id
                 ~agent_name:meta.agent_name)
          then
            ignore
              (Room.join_in_room config ~room_id ~agent_name:meta.agent_name
                 ~capabilities:[ "keeper" ] ());
          ignore
            (Room.heartbeat_in_room config ~room_id ~agent_name:meta.agent_name);
          room_id :: acc
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          log_keeper_exn ~label:(Printf.sprintf "room presence sync failed for %s in %s" meta.name room_id) exn;
          acc)
      [] room_ids
  in
  { meta with joined_room_ids = List.rev successful_rooms }

let exact_direct_mention_present ~(targets : string list) (content : string) :
    bool =
  Mention.any_mentioned ~targets content

(* Delegate to Keeper_prompt — single source of truth for keeper prompts. *)
let keeper_constitution = Keeper_prompt.keeper_constitution

let build_keeper_system_prompt = Keeper_prompt.build_keeper_system_prompt

let append_trait_clause ~(base : string) ~(clause : string) : string =
  let b = String.trim base in
  let c = String.trim clause in
  if c = "" then b
  else if b = "" then c
  else if contains_ci b c then b
  else Printf.sprintf "%s; %s" b c


let proactive_prompt_for_keeper = Keeper_prompt.proactive_prompt_for_keeper

type proactive_generation_result = {
  reply: string;
  usage: Agent_sdk.Types.api_usage;
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
  if attempt <= 1 then Keeper_config.keeper_proactive_temperature_low ()
  else if attempt = 2 then Keeper_config.keeper_proactive_temperature_mid ()
  else Keeper_config.keeper_proactive_temperature_high ()

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

let trim_to_option (s : string) : string option =
  let trimmed = String.trim s in
  if trimmed = "" then None else Some trimmed

let state_snapshot_reply_fallback (snapshot : keeper_state_snapshot option) :
    string option =
  match snapshot with
  | Some { progress = Some progress; _ } -> trim_to_option progress
  | Some { goal = Some goal; _ } -> trim_to_option goal
  | _ -> None

let strip_internal_reply_markup (raw : string) : string =
  raw
  |> strip_skill_route_lines
  |> strip_state_blocks_text
  |> String.trim

let user_visible_reply_text ?fallback (raw : string) : string =
  match trim_to_option (strip_internal_reply_markup raw) with
  | Some text -> text
  | None -> (
      match Option.bind fallback trim_to_option with
      | Some text -> text
      | None -> (
          match state_snapshot_reply_fallback (parse_state_snapshot_from_reply raw) with
          | Some text -> text
          | None -> "State updated."))

let normalize_proactive_text (raw : string) : string =
  raw
  |> strip_internal_reply_markup
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
    ~(model_labels : string list)
    ~(config : Room.config)
    ~(ctx_work : working_context)
    ~(meta : keeper_meta)
    ~(continuity_snapshot : keeper_state_snapshot option)
    ~(continuity_summary : string)
    ~(idle_seconds : int) : proactive_generation_result option =
  let primary_model_id = (match Llm_provider.Cascade_config.parse_model_strings model_labels with c :: _ -> c.Llm_provider.Provider_config.model_id | [] -> "auto") in
  let base_prompt =
    proactive_prompt_for_keeper ~meta ~idle_seconds continuity_snapshot continuity_summary
  in
  let max_attempts = 3 in
  let previous_preview = String.trim meta.last_proactive_preview in
  let similarity_threshold = Keeper_config.keeper_proactive_similarity_threshold () in
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
  let ctx_ref = ref ctx_work in
  let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_ref in
  let rec loop attempt usage_acc latency_acc cost_acc retry_hint =
    if attempt > max_attempts then
      Some {
        reply = proactive_fallback_reply ~meta ~idle_seconds;
        usage = usage_acc;
        model_used = primary_model_id;
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
      let temperature = proactive_temperature attempt in
      let max_tokens = 1024 in
      let (agent_result, attempt_latency) = timed (fun () ->
          Oas_worker.run_named ~cascade_name:"keeper_turn"
            ~goal:prompt ~system_prompt:turn_system_prompt
            ~tools ~initial_messages:ctx_work.messages
            ~max_turns:10 ~temperature ~max_tokens ()) in
      match agent_result with
      | Error _ -> None
      | Ok result ->
          let resp = result.Oas_worker.response in
          let model_used_raw = resp.model in
          let used_model_id =
            let cfgs = Llm_provider.Cascade_config.parse_model_strings model_labels in
            let strip s = if String.length s > 7 && String.sub s (String.length s - 7) 7 = ":latest" then String.sub s 0 (String.length s - 7) else s in
            let u = strip model_used_raw in
            match List.find_opt (fun (c : Llm_provider.Provider_config.t) -> c.model_id = model_used_raw || c.model_id = u) cfgs with
            | Some c -> c.model_id
            | None -> (match cfgs with c :: _ -> c.model_id | [] -> model_used_raw)
          in
          let attempt_usage = usage_of_response resp in
          let attempt_cost_usd =
            cost_usd_of_usage attempt_usage ~model_id:used_model_id
          in
          let attempt_content =
            let c = String.trim (Agent_sdk.Types.text_of_content resp.content) in
            let tool_names = List.filter_map (function
              | Agent_sdk.Types.ToolUse { name; _ } -> Some name | _ -> None)
              resp.content in
            if c = "" && tool_names <> [] then
              Printf.sprintf "(tools executed: %s)" (String.concat ", " tool_names)
            else c
          in
          let attempt_model_used = resp.model in
          let attempt_tools_used = List.filter_map (function
            | Agent_sdk.Types.ToolUse { name; _ } -> Some name | _ -> None)
            resp.content in
          let attempt_latency_ms = attempt_latency in
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

