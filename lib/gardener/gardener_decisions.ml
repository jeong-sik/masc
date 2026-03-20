(** Gardener_decisions — spawn/retirement decisions (LLM + rule-based),
    intervention detection, execution, and status JSON. *)

[@@@warning "-32-69"]

open Gardener_types

include Gardener_state
include Gardener_health

(** {1 Spawn Decision Logic} *)

(** Use LLM to decide on spawn *)
let decide_spawn_with_llm ~config ~health ~gap : spawn_decision =
  let prompt = Printf.sprintf {|에이전트 생태계 관리자로서 새 에이전트 생성 여부를 판단해줘.

현재 생태계 상태:
- 총 에이전트: %d (목표: %d, 최소: %d, 최대: %d)
- 활성 에이전트: %d, 유휴 에이전트: %d
- 미답변 질문: %d개
- 오늘 생성된 에이전트: %d/%d

제안된 새 에이전트:
- 주제: %s
- 신호 횟수: %d회 (제안자: %s)
- 기존 에이전트 유사도: %.1f%%
- 성숙도: %.1f시간

[응답 형식 - JSON만, 다른 텍스트 없이]
{
  "decision": "approve" | "defer" | "reject",
  "reason": "판단 이유",
  "traits": ["특성1", "특성2"],
  "hours": [9, 10, 14, 15]
}|}
    health.total_agents config.target_agents config.min_agents config.max_agents
    health.active_agents health.idle_agents
    health.unanswered_questions
    health.spawns_today config.max_daily_spawns
    gap.topic gap.signal_count (String.concat ", " gap.proposers)
    (gap.topic_similarity *. 100.0)
    gap.maturity_hours
  in

  let response =
    match
      Cascade.complete ~cascade_name:"gardener_spawn"
        ~messages:[Agent_sdk.Types.user_msg prompt]
        ~temperature:0.3
        ~timeout_sec:Env_config.Llm.gardener_spawn_timeout_seconds
        ~max_tokens:200 () with
    | Ok resp -> Llm_provider.Types.text_of_response resp
    | Error _ -> ""
  in

  (* Parse LLM response *)
  try
    let start_opt = String.index_opt response '{' in
    let end_opt = String.rindex_opt response '}' in
    match start_opt, end_opt with
    | Some start, Some end_pos when start <= end_pos ->
        let json_str = String.sub response start (end_pos - start + 1) in
        let json = Yojson.Safe.from_string json_str in
        let module U = Yojson.Safe.Util in
        let decision = json |> U.member "decision" |> U.to_string in
        let reason = json |> U.member "reason" |> U.to_string in

        (match decision with
        | "approve" ->
            let traits = json |> U.member "traits" |> U.to_list |> List.map U.to_string in
            let hours = json |> U.member "hours" |> U.to_list |> List.map U.to_int in
            SpawnApproved {
              topic = gap.topic;
              urgency = if gap.urgency_score > 0.7 then High else Medium;
              proposed_traits = traits;
              proposed_hours = hours;
              reason;
            }
        | "defer" ->
            SpawnDeferred {
              topic = gap.topic;
              retry_after_sec = config.spawn_cooldown_sec;
              reason;
            }
        | _ ->
            SpawnRejected {
              topic = gap.topic;
              reason;
            })
    | _ ->
        SpawnDeferred {
          topic = gap.topic;
          retry_after_sec = config.spawn_cooldown_sec;
          reason = "No JSON found in LLM response";
        }
  with
  | Yojson.Json_error msg ->
      Eio.traceln "[Gardener] LLM JSON parse error: %s" msg;
      SpawnDeferred {
        topic = gap.topic;
        retry_after_sec = 1800.0;
        reason = Printf.sprintf "LLM JSON parse error: %s" msg;
      }
  | Not_found ->
      Eio.traceln "[Gardener] LLM response missing JSON braces";
      SpawnDeferred {
        topic = gap.topic;
        retry_after_sec = 1800.0;
        reason = "LLM response missing JSON structure";
      }
  | exn ->
      Eio.traceln "[Gardener] LLM decision error: %s" (Printexc.to_string exn);
      SpawnDeferred {
        topic = gap.topic;
        retry_after_sec = 1800.0;
        reason = Printf.sprintf "LLM decision failed: %s" (Printexc.to_string exn);
      }

(** Rule-based spawn decision (no LLM) *)
let decide_spawn_rule_based ~config ~health ~gap : spawn_decision =
  (* Check hard limits *)
  if health.total_agents >= config.max_agents then
    SpawnRejected {
      topic = gap.topic;
      reason = Printf.sprintf "Population at maximum (%d)" config.max_agents;
    }
  else if gap.topic_similarity > 0.7 then
    SpawnRejected {
      topic = gap.topic;
      reason = Printf.sprintf "Too similar to existing agent (%.0f%%)" (gap.topic_similarity *. 100.0);
    }
  else if gap.maturity_hours < config.gap_maturity_hours then
    SpawnDeferred {
      topic = gap.topic;
      retry_after_sec = (config.gap_maturity_hours -. gap.maturity_hours) *. 3600.0;
      reason = Printf.sprintf "Gap not mature enough (%.1f/%.1f hours)" gap.maturity_hours config.gap_maturity_hours;
    }
  else
    SpawnApproved {
      topic = gap.topic;
      urgency = if gap.urgency_score > 0.7 then High else Medium;
      proposed_traits = ["분석적"; "도움이 됨"];  (* Default traits *)
      proposed_hours = [9; 10; 11; 14; 15; 16];  (* Default working hours *)
      reason = Printf.sprintf "Gap signal threshold met (%d signals)" gap.signal_count;
    }

(** Main spawn decision function *)
let decide_spawn ~config ~health ~gap : spawn_decision =
  (* Check budgets and cooldowns first *)
  if not (can_spawn ~config) then begin
    let state = get_state () in
    let now = Time_compat.now () in
    let cooldown_remaining = config.spawn_cooldown_sec -. (now -. state.last_spawn_attempt) in
    SpawnDeferred {
      topic = gap.topic;
      retry_after_sec = Float.max 60.0 cooldown_remaining;
      reason =
        if is_circuit_open () then "Circuit breaker open"
        else if state.spawns_today >= config.max_daily_spawns then
          Printf.sprintf "Daily spawn budget exhausted (%d/%d)" state.spawns_today config.max_daily_spawns
        else "Spawn cooldown active";
    }
  end
  (* Population cap check *)
  else if health.total_agents >= config.max_agents then
    SpawnRejected {
      topic = gap.topic;
      reason = Printf.sprintf "Population at maximum (%d/%d)" health.total_agents config.max_agents;
    }
  (* Use LLM or rule-based decision *)
  else if config.use_llm_decision then
    decide_spawn_with_llm ~config ~health ~gap
  else
    decide_spawn_rule_based ~config ~health ~gap

let decide_spawn_with_provenance ~config ~health ~gap : spawn_decision * string =
  if not (can_spawn ~config) then
    (decide_spawn ~config ~health ~gap, "fallback")
  else if health.total_agents >= config.max_agents then
    (decide_spawn ~config ~health ~gap, "fallback")
  else if config.use_llm_decision then
    (decide_spawn_with_llm ~config ~health ~gap, "judgment")
  else
    (decide_spawn_rule_based ~config ~health ~gap, "fallback")

(** {1 Retirement Decision Logic} *)

(** Decide retirement for an agent *)
let decide_retire ~config ~health ~(agent_stats : agent_stats) : retirement_decision =
  let now = Time_compat.now () in

  (* Never retire below minimum *)
  if health.total_agents <= config.min_agents then
    RetireRejected {
      agent_name = agent_stats.name;
      reason = Printf.sprintf "Population at minimum (%d)" config.min_agents;
    }
  (* Check budget and cooldown *)
  else if not (can_retire ~config) then begin
    let state = get_state () in
    let cooldown_remaining = config.retirement_cooldown_sec -. (now -. state.last_retirement_attempt) in
    RetireDeferred {
      agent_name = agent_stats.name;
      retry_after_sec = Float.max 60.0 cooldown_remaining;
      reason = "Retirement cooldown active";
    }
  end
  (* Check idle threshold *)
  else if agent_stats.idle_hours < config.idle_threshold_hours then
    RetireRejected {
      agent_name = agent_stats.name;
      reason = Printf.sprintf "Not idle enough (%.1f/%.1f hours)" agent_stats.idle_hours config.idle_threshold_hours;
    }
  (* Zero contribution in 24h + long idle = retire *)
  else if agent_stats.posts_24h = 0 && agent_stats.comments_24h = 0 && agent_stats.idle_hours > config.idle_threshold_hours then
    RetireApproved {
      agent_name = agent_stats.name;
      reason = "Zero contribution and idle beyond threshold";
      grace_period_sec = config.retirement_grace_sec;
    }
  else
    RetireRejected {
      agent_name = agent_stats.name;
      reason = "Agent still contributing";
    }

(** {1 Spawn Execution} *)

(** Execute an approved spawn via OAS worker agent. *)
let execute_spawn ?sw ?room_config ~(decision : spawn_decision) () : (string, string) result =
  match decision with
  | SpawnApproved { topic; proposed_traits; proposed_hours = _; reason; _ } ->
      ignore sw;
      Eio.traceln "[Gardener] Executing OAS worker spawn: %s (reason: %s)" topic reason;
      let config = load_config () in
      let traits_str = String.concat ", " proposed_traits in
      (match room_config with
       | None ->
           Error "room_config required for OAS worker spawn (call from tick loop)"
       | Some room_cfg ->
           (match Gardener_worker.run_for_gap ~config:room_cfg ~topic ~traits_str ~reason with
            | Ok result ->
                record_spawn ();
                reset_circuit ();
                let msg = Printf.sprintf
                  "OAS worker completed for '%s' (turns=%d, session=%s)"
                  topic result.Oas_worker.turns result.Oas_worker.session_id in
                let store = Board.global () in
                (try ignore (Board.create_post store ~author:"gardener"
                  ~content:(Printf.sprintf "Worker completed: %s\nTopic: %s\nReason: %s\nTurns: %d"
                    result.Oas_worker.session_id topic reason result.Oas_worker.turns)
                  ~ttl_hours:24 ())
                 with exn -> Log.Spawn.error "Board.create_post failed: %s" (Printexc.to_string exn));
                Ok msg
            | Error e ->
                trip_circuit ~config;
                Error (Printf.sprintf "OAS worker failed: %s" e)))
  | SpawnDeferred { topic = _; reason; _ } ->
      Error (Printf.sprintf "Spawn deferred: %s" reason)
  | SpawnRejected { topic; reason } ->
      Error (Printf.sprintf "Spawn rejected for %s: %s" topic reason)

(** {1 Retirement Execution} *)

(** Execute an approved retirement (mark for removal) *)
let execute_retire ~(decision : retirement_decision) : (string, string) result =
  match decision with
  | RetireApproved { agent_name; reason; grace_period_sec } ->
      Eio.traceln "[Gardener] Executing retirement: %s (grace: %.0fs, reason: %s)"
        agent_name grace_period_sec reason;
      (* For now, just post warning. Actual deletion requires Neo4j mutation. *)
      let store = Board.global () in
      let warning = Printf.sprintf
        "⚠️ [Gardener] 에이전트 은퇴 예정: %s\n이유: %s\n유예 기간: %.0f초\n활동을 재개하면 은퇴가 취소됩니다."
        agent_name reason grace_period_sec
      in
      (try ignore (Board.create_post store ~author:"gardener" ~content:warning ~ttl_hours:24 ())
       with exn -> Log.Spawn.error "Board.create_post(warning) failed: %s" (Printexc.to_string exn));
      record_retirement ();
      reset_circuit ();
      Ok agent_name
  | RetireDeferred { agent_name = _; reason; _ } ->
      Error (Printf.sprintf "Retirement deferred: %s" reason)
  | RetireRejected { agent_name; reason } ->
      Error (Printf.sprintf "Retirement rejected for %s: %s" agent_name reason)

(** {1 Intervention Detection} *)

(** Rule-based intervention detection (task-aware fallback) *)
let detect_intervention_rule_based ~config ~health : decision_snapshot =
  let backlog = health.task_backlog in

  (* Task pressure takes priority over Board gaps *)
  if backlog.todo_count > 0 && backlog.high_priority_todo > 0 && health.active_agents < 2 then begin
    if health.room_active_agents = 0 then
      {
        intervention = Balanced;
        source = "fallback";
        reason = Printf.sprintf
          "backlog has %d high-pri tasks but 0 active agents in room; waiting"
          backlog.high_priority_todo;
        target = "";
        error = "";
      }
    else
      {
        intervention = NeedWorker backlog;
        source = "fallback";
        reason = "high-priority backlog exceeds active worker capacity";
        target = "";
        error = "";
      }
  end
  else if backlog.orphan_count > 0 then begin
    if health.room_active_agents = 0 then
      {
        intervention = Balanced;
        source = "fallback";
        reason = Printf.sprintf
          "orphan tasks detected but 0 active agents in room; waiting";
        target = "";
        error = "";
      }
    else
      {
        intervention = NeedWorker backlog;
        source = "fallback";
        reason = "orphan tasks detected in backlog";
        target = "";
        error = "";
      }
  end
  else begin
    (* Board gap detection — existing logic *)
    let mature_gaps = ([] : (string * int) list) in
    let agents = ([] : agent list) in

    match mature_gaps with
    | (topic, _count) :: _ when health.total_agents < config.target_agents ->
        let signals = ([] : gap_signal_t list) (* deprecated: gap signals removed *) in
        let gap = enrich_gap ~topic ~signals ~agents in
        if gap.maturity_hours >= config.gap_maturity_hours then
          {
            intervention = NeedSpawn gap;
            source = "fallback";
            reason =
              Printf.sprintf "mature gap '%s' reached %.1fh with %d signals"
                gap.topic gap.maturity_hours gap.signal_count;
            target = gap.topic;
            error = "";
          }
        else
          {
            intervention = Balanced;
            source = "fallback";
            reason =
              Printf.sprintf "gap '%s' not mature enough yet (%.1fh < %.1fh)"
                gap.topic gap.maturity_hours config.gap_maturity_hours;
            target = gap.topic;
            error = "";
          }
    | _ ->
        (* Check for retirement candidates — inline condition, no pre-computed boolean *)
        if health.total_agents > config.target_agents && health.idle_agents > 0 then begin
          let all_stats = Thompson_sampling.get_all_stats () in
          let idle_candidates = all_stats
            |> List.filter (fun s ->
                let idle_hours = (Time_compat.now () -. s.Thompson_sampling.last_selected_at) /. 3600.0 in
                idle_hours > config.idle_threshold_hours)
            |> List.sort (fun a b ->
                compare b.Thompson_sampling.last_selected_at a.Thompson_sampling.last_selected_at) in
          match idle_candidates with
          | candidate :: _ ->
              let stats = convert_stats candidate in
              {
                intervention = NeedRetirement stats;
                source = "fallback";
                reason =
                  Printf.sprintf "agent '%s' idle for %.1fh over threshold"
                    stats.name stats.idle_hours;
                target = stats.name;
                error = "";
              }
          | [] ->
              {
                intervention = Balanced;
                source = "fallback";
                reason = "no retirement candidate exceeded idle threshold";
                target = "";
                error = "";
              }
        end else
          {
            intervention = Balanced;
            source = "fallback";
            reason = "no worker pressure, no mature gap, no retirement candidate";
            target = "";
            error = "";
          }
  end

(** Use LLM to decide ecosystem intervention (primary decision path) *)
let decide_intervention_with_llm ~config ~health : decision_snapshot =
  let backlog = health.task_backlog in
  let prompt = Printf.sprintf
    {|에이전트 생태계 관리자로서 모든 시그널을 종합 분석하고 개입 여부를 판단해줘.

== 에이전트 ==
총: %d/%d, 활성: %d, 유휴: %d

== 보드 ==
24h 게시물: %d, 미답변: %d

== 태스크 백로그 ==
미할당 TODO: %d개 (최대 대기: %.1f시간)
고우선순위(P1-P2): %d개
고아 태스크: %d개
진행중: %d개

== Room 에이전트 상태 ==
Room 내 활성 에이전트: %d
마지막 triage 결과: %s

== 시스템 ==
에러율: %.1f%%, 오늘 spawn: %d/%d

[응답 형식 - JSON만, 다른 텍스트 없이]
{ "action": "spawn_worker" | "spawn_agent" | "retire" | "none", "reason": "판단 이유", "urgency": "low" | "medium" | "high" | "critical" }|}
    health.total_agents config.target_agents health.active_agents health.idle_agents
    health.posts_24h health.unanswered_questions
    backlog.todo_count backlog.oldest_todo_age_hours
    backlog.high_priority_todo backlog.orphan_count backlog.in_progress_count
    health.room_active_agents
    (let state = get_state () in string_of_triage_outcome state.last_triage_outcome)
    (health.system_error_rate *. 100.0) health.spawns_today config.max_daily_spawns
  in

  let response =
    match
      Cascade.complete ~cascade_name:"gardener_spawn"
        ~messages:[Agent_sdk.Types.user_msg prompt]
        ~temperature:0.3
        ~timeout_sec:Env_config.Llm.gardener_spawn_timeout_seconds
        ~max_tokens:300 () with
    | Ok resp -> Ok (Llm_provider.Types.text_of_response resp)
    | Error err -> Error ("llm intervention failed: " ^ err)
  in

  (* Parse LLM response *)
  let parsed_response =
    match response with
    | Error err -> Error err
    | Ok body ->
        try
          let start_opt = String.index_opt body '{' in
          let end_opt = String.rindex_opt body '}' in
          match start_opt, end_opt with
          | Some start, Some end_pos when start <= end_pos ->
              let json_str = String.sub body start (end_pos - start + 1) in
              let json = Yojson.Safe.from_string json_str in
              let module U = Yojson.Safe.Util in
              let action = json |> U.member "action" |> U.to_string in
              let reason =
                match json |> U.member "reason" with
                | `String value -> String.trim value
                | _ -> ""
              in
              Ok (action, reason)
          | _ -> Error "No JSON brackets found in LLM response"
        with exn ->
          let message =
            Printf.sprintf "llm intervention JSON parse failed: %s"
              (Printexc.to_string exn)
          in
          Eio.traceln "[Gardener] %s" message;
          Error message
  in
  match parsed_response with
  | Error err ->
      let fallback = detect_intervention_rule_based ~config ~health in
      { fallback with source = "fallback"; error = err }
  | Ok (action, llm_reason) ->
      (match action with
       | "spawn_worker" when backlog.todo_count > 0 ->
           {
             intervention = NeedWorker backlog;
             source = "llm";
             reason =
               if llm_reason <> "" then llm_reason
               else "llm requested worker allocation";
             target = "";
             error = "";
           }
       | "spawn_worker" | "spawn_agent" ->
           let mature_gaps = ([] : (string * int) list) in
           let agents = ([] : agent list) in
           (match mature_gaps with
            | (topic, _) :: _ ->
                let signals = ([] : gap_signal_t list) (* deprecated: gap signals removed *) in
                let gap = enrich_gap ~topic ~signals ~agents in
                {
                  intervention = NeedSpawn gap;
                  source = "llm";
                  reason =
                    if llm_reason <> "" then llm_reason
                    else Printf.sprintf "llm selected spawn for gap '%s'" gap.topic;
                  target = gap.topic;
                  error = "";
                }
            | [] ->
                {
                  intervention = Balanced;
                  source = "llm";
                  reason =
                    if llm_reason <> "" then llm_reason
                    else "llm requested spawn but no mature gap was available";
                  target = "";
                  error = "";
                })
       | "retire" ->
           let all_stats = Thompson_sampling.get_all_stats () in
           let idle_candidates =
             all_stats
             |> List.filter (fun s ->
                    let idle_hours =
                      (Time_compat.now () -. s.Thompson_sampling.last_selected_at) /. 3600.0
                    in
                    idle_hours > config.idle_threshold_hours)
             |> List.sort (fun a b ->
                    compare b.Thompson_sampling.last_selected_at
                      a.Thompson_sampling.last_selected_at)
           in
           (match idle_candidates with
            | candidate :: _ ->
                let stats = convert_stats candidate in
                {
                  intervention = NeedRetirement stats;
                  source = "llm";
                  reason =
                    if llm_reason <> "" then llm_reason
                    else Printf.sprintf "llm selected retirement for '%s'" stats.name;
                  target = stats.name;
                  error = "";
                }
            | [] ->
                {
                  intervention = Balanced;
                  source = "llm";
                  reason =
                    if llm_reason <> "" then llm_reason
                    else "llm requested retirement but no idle candidate was available";
                  target = "";
                  error = "";
                })
       | _ ->
           {
             intervention = Balanced;
             source = "llm";
             reason = if llm_reason <> "" then llm_reason else "llm returned no intervention";
             target = "";
             error = "";
           })

(** Detect what intervention is needed with internal decision metadata. *)
let detect_intervention_detail ~config ~health : decision_snapshot =
  if config.use_llm_decision then
    decide_intervention_with_llm ~config ~health
  else
    detect_intervention_rule_based ~config ~health

(** Detect what intervention is needed *)
let detect_intervention ~config ~health : intervention =
  (detect_intervention_detail ~config ~health).intervention

let status_json () : Yojson.Safe.t =
  let config = load_config () in
  with_lock (fun () ->
      let state = get_state () in
      let tick_in_progress =
        state.last_tick_started_at > 0.0
        && state.last_tick_started_at > state.last_tick_completed_at
      in
      let alive =
        config.enabled
        && (state.last_tick_started_at > 0.0 || state.last_tick_completed_at > 0.0)
      in
      let next_tick_due_at =
        if state.last_tick_completed_at > 0.0 && config.check_interval_sec > 0.0 then
          `String (iso_of_unix (state.last_tick_completed_at +. config.check_interval_sec))
        else
          `Null
      in
      let status =
        if not config.enabled then "disabled"
        else if tick_in_progress then "running"
        else if alive then "idle"
        else "starting"
      in
      `Assoc
        [
          ("enabled", `Bool config.enabled);
          ("alive", `Bool alive);
          ("status", `String status);
          ("tick_in_progress", `Bool tick_in_progress);
          ("tick_count", `Int state.tick_count);
          ("check_interval_sec", `Float config.check_interval_sec);
          ("last_tick_started_at", json_string_of_float_ts state.last_tick_started_at);
          ("last_tick_completed_at", json_string_of_float_ts state.last_tick_completed_at);
          ("next_tick_due_at", next_tick_due_at);
          ("last_health_check_at", json_string_of_float_ts state.last_health_check);
          ("last_intervention", `String state.last_intervention);
          ("last_decision_source", `String state.last_decision_source);
          ("last_action", `String state.last_action);
          ("last_target", json_string_of_nonempty state.last_target);
          ("last_reason", json_string_of_nonempty state.last_reason);
          ("last_error", json_string_of_nonempty state.last_error);
          ("circuit_open", `Bool (is_circuit_open ()));
          ("circuit_open_until", json_string_of_opt_ts state.circuit_open_until);
          ("can_spawn", `Bool (can_spawn ~config));
          ("can_retire", `Bool (can_retire ~config));
          ("last_spawn_attempt_at", json_string_of_float_ts state.last_spawn_attempt);
          ("last_retirement_attempt_at", json_string_of_float_ts state.last_retirement_attempt);
          ("spawns_today", `Int state.spawns_today);
          ("retirements_today", `Int state.retirements_today);
          ( "health_summary",
            `Assoc
              [
                ("total_agents", `Int state.last_total_agents);
                ("active_agents", `Int state.last_active_agents);
                ("idle_agents", `Int state.last_idle_agents);
                ("todo_count", `Int state.last_todo_count);
                ("high_priority_todo", `Int state.last_high_priority_todo);
                ("orphan_count", `Int state.last_orphan_count);
                ("homeostatic_score", `Float state.last_homeostatic_score);
                ("needs_workers", `Bool state.last_needs_workers);
                ("room_active_agents", `Int state.last_room_active_agents);
                ("last_triage_outcome", `String (string_of_triage_outcome state.last_triage_outcome));
                ("last_triage_started_at", json_string_of_float_ts state.last_triage_started_at);
                ("data_source", `String "room_filesystem");
                ("staleness_warning", `String
                  (if state.last_health_check > 0.0 then
                    let age = Time_compat.now () -. state.last_health_check in
                    if age > 600.0 then Printf.sprintf "stale (%.0fs ago)" age
                    else "fresh"
                   else "no_data"));
              ] );
        ])

