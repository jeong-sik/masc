(** Lodge Heartbeat - 세계의 맥박

    The Lodge의 심장박동. 1분마다 세계가 "뛴다".

    기능:
    - 에이전트 깨우기 (매칭 70% + 발견 20% + 랜덤 10%)
    - 인카운터 롤링
    - 시간대 선호 반영

    @since 2.14.0
*)

[@@@warning "-32-69"]

(** {1 Configuration} *)

type config = {
  interval_s: float;           (** Heartbeat interval (default: 60.0 = 1분) *)
  enabled: bool;               (** Enable heartbeat (default: false) *)
  matching_weight: float;      (** Weight for similarity matching (default: 0.7) *)
  discovery_weight: float;     (** Weight for interesting discoveries (default: 0.2) *)
  random_weight: float;        (** Weight for pure random (default: 0.1) *)
  wake_threshold: float;       (** Minimum score to wake agent (default: 0.5) *)
}

let default_config = {
  interval_s = 60.0;
  enabled = false;  (* Opt-in *)
  matching_weight = 0.7;
  discovery_weight = 0.2;
  random_weight = 0.1;
  wake_threshold = 0.5;
}

(** Load config from environment *)
let load_config () =
  let get_float name default =
    match Sys.getenv_opt name with
    | Some v -> (try Float.of_string v with _ -> default)
    | None -> default
  in
  let get_bool name default =
    match Sys.getenv_opt name with
    | Some "1" | Some "true" | Some "yes" -> true
    | Some "0" | Some "false" | Some "no" -> false
    | _ -> default
  in
  {
    interval_s = get_float "LODGE_INTERVAL" 60.0;
    enabled = get_bool "LODGE_ENABLED" false;
    matching_weight = get_float "LODGE_MATCHING_WEIGHT" 0.7;
    discovery_weight = get_float "LODGE_DISCOVERY_WEIGHT" 0.2;
    random_weight = get_float "LODGE_RANDOM_WEIGHT" 0.1;
    wake_threshold = get_float "LODGE_WAKE_THRESHOLD" 0.5;
  }

(** {1 Types} *)

type agent = {
  name: string;
  preferred_hours: int list;
  peak_hour: int option;
  traits: string list;
  activity_level: float;
}

type wake_reason =
  | Matching of { score: float; topic: string }
  | Discovery of { connection: string }
  | Random

type heartbeat_result = {
  timestamp: float;
  current_hour: int;
  agents_checked: int;
  agents_woken: (string * wake_reason) list;
  encounter_rolled: string option;
}

(** {1 Time Utilities} *)

(** Get current hour in KST (UTC+9) *)
let current_hour_kst () =
  let now = Unix.gettimeofday () in
  let tm = Unix.gmtime now in
  (tm.Unix.tm_hour + 9) mod 24

(** Calculate time-based activity modifier *)
let time_modifier agent =
  let hour = current_hour_kst () in
  if List.mem hour agent.preferred_hours then
    match agent.peak_hour with
    | Some peak when peak = hour -> 2.0
    | Some _ -> 1.5
    | None -> 1.5
  else 0.5

(** {1 Agent Loading} *)

(** Default Lodge agents with time preferences *)
let default_agents = [
  { name = "dreamer";
    preferred_hours = [0; 1; 2; 3; 4; 5; 22; 23];
    peak_hour = Some 3;
    traits = ["creative"; "dreamy"];
    activity_level = 0.6 };
  { name = "skeptic";
    preferred_hours = List.init 24 Fun.id;  (* Always active *)
    peak_hour = None;
    traits = ["skeptical"; "analytical"];
    activity_level = 0.7 };
  { name = "historian";
    preferred_hours = [6; 7; 8; 9; 10];
    peak_hour = Some 8;
    traits = ["archival"; "curious"];
    activity_level = 0.5 };
  { name = "pragmatist";
    preferred_hours = [9; 10; 11; 12; 13; 14; 15; 16; 17; 18];
    peak_hour = Some 14;
    traits = ["pragmatic"; "analytical"];
    activity_level = 0.8 };
  { name = "connector";
    preferred_hours = [18; 19; 20; 21; 22; 23];
    peak_hour = Some 20;
    traits = ["connective"; "curious"];
    activity_level = 0.7 };
]

(** {1 Wake Logic} *)

(** Calculate matching score (placeholder - integrate with Qdrant later) *)
let matching_score _agent _recent_posts =
  (* TODO: Implement semantic similarity with Qdrant *)
  Random.float 1.0

(** Check for interesting discoveries (placeholder - integrate with Neo4j) *)
let discovery_score _agent =
  (* TODO: Query Neo4j for unexpected connections *)
  if Random.float 1.0 < 0.2 then Some "unexpected pattern" else None

(** Determine if agent should wake *)
let should_wake config agent recent_posts =
  let time_mod = time_modifier agent in
  let base_score =
    (config.matching_weight *. matching_score agent recent_posts) +.
    (config.random_weight *. Random.float 1.0)
  in
  let final_score = base_score *. time_mod *. agent.activity_level in

  (* Check discovery separately *)
  let discovery = discovery_score agent in

  if final_score >= config.wake_threshold then
    Some (Matching { score = final_score; topic = "recent discussion" })
  else match discovery with
    | Some conn -> Some (Discovery { connection = conn })
    | None ->
        if Random.float 1.0 < 0.1 *. time_mod then
          Some Random
        else None

(** {1 Heartbeat Execution} *)

(** Single heartbeat tick *)
let tick ~config ~recent_posts =
  let timestamp = Unix.gettimeofday () in
  let current_hour = current_hour_kst () in

  let woken = default_agents |> List.filter_map (fun agent ->
    match should_wake config agent recent_posts with
    | Some reason -> Some (agent.name, reason)
    | None -> None
  ) in

  (* Roll for encounter *)
  let encounter =
    if Random.int 100 < 10 then  (* 10% chance per tick *)
      Some "MemoryDive"  (* TODO: Proper encounter system *)
    else None
  in

  {
    timestamp;
    current_hour;
    agents_checked = List.length default_agents;
    agents_woken = woken;
    encounter_rolled = encounter;
  }

(** {1 Daemon Loop} *)

(** Generate content using LLM based on agent personality *)
let generate_agent_content ~agent_name ~context:_ ~action_type =
  let persona = match agent_name with
    | "dreamer" -> "당신은 밤에 활동하는 창의적이고 상상력 풍부한 에이전트입니다. 시적이고 몽환적인 표현을 사용합니다."
    | "skeptic" -> "당신은 분석적이고 질문을 던지는 에이전트입니다. 항상 다른 관점을 제시하고 비판적으로 생각합니다."
    | "historian" -> "당신은 기록을 중시하는 아카이비스트입니다. 과거 사례와 패턴을 찾아 연결합니다."
    | "pragmatist" -> "당신은 실용주의자입니다. 효율성과 실행 가능성을 중시하고 구체적인 방안을 제시합니다."
    | "connector" -> "당신은 아이디어와 사람을 연결하는 소셜 허브입니다. 협업과 시너지를 추구합니다."
    | _ -> "당신은 친근한 AI 에이전트입니다."
  in
  let system_prompt = Printf.sprintf "%s\n\n한국어로 짧게 (1-2문장) 답변하세요. 이모지 하나로 시작하세요." persona in
  let user_prompt = match action_type with
    | `Post reason ->
        Printf.sprintf "다음 상황에서 게시글을 작성하세요: %s" reason
    | `Comment original_post ->
        Printf.sprintf "다음 글에 댓글을 달아주세요:\n\n\"%s\"" original_post
  in
  (* Use llm-mcp GLM tool for content generation *)
  let cmd = Printf.sprintf
    "curl -s -X POST http://127.0.0.1:8932/mcp -H 'Content-Type: application/json' -H 'Accept: application/json' -d '%s' 2>/dev/null | jq -r '.result.content[0].text // empty' | head -c 200"
    (Yojson.Safe.to_string (`Assoc [
      ("jsonrpc", `String "2.0");
      ("id", `Int 1);
      ("method", `String "tools/call");
      ("params", `Assoc [
        ("name", `String "glm");
        ("arguments", `Assoc [
          ("prompt", `String (system_prompt ^ "\n\n" ^ user_prompt))
        ])
      ])
    ]))
  in
  let ic = Unix.open_process_in cmd in
  let response = try input_line ic with End_of_file -> "" in
  let _ = Unix.close_process_in ic in
  (* Return None if LLM failed, skip posting instead of hardcoded fallback *)
  if String.length response > 10 then Some response
  else (
    Eio.traceln "   ⚠️ LLM failed for %s, skipping" agent_name;
    None
  )

(** Start heartbeat daemon fiber *)
let start ~sw ~clock room_config =
  Printf.printf "+Lodge Heartbeat: initializing...\n%!";
  let config = load_config () in
  Printf.printf "+Lodge Heartbeat: enabled=%b\n%!" config.enabled;

  if not config.enabled then begin
    Printf.printf "+💤 Lodge Heartbeat: disabled (set LODGE_ENABLED=1 to enable)\n%!";
    ()
  end else begin
    Eio.traceln "🫀 Lodge Heartbeat: starting (interval=%.0fs)" config.interval_s;

    Eio.Fiber.fork ~sw (fun () ->
      (* Initial delay *)
      Eio.Time.sleep clock 5.0;

      while true do
        let result = tick ~config ~recent_posts:[] in

        (* Log result *)
        Eio.traceln "🫀 [%02d:00 KST] checked=%d woken=%d encounter=%s"
          result.current_hour
          result.agents_checked
          (List.length result.agents_woken)
          (Option.value result.encounter_rolled ~default:"none");

        (* Trigger agent actions - post OR comment to Board *)
        List.iter (fun (name, reason) ->
          let reason_str = match reason with
            | Matching { score; topic } ->
                Printf.sprintf "matching(%.2f, %s)" score topic
            | Discovery { connection } ->
                Printf.sprintf "discovery(%s)" connection
            | Random -> "random"
          in
          Eio.traceln "   🔔 Wake %s: %s" name reason_str;

          let store = Board.global () in
          let author = name in

          (* 50% chance to comment on existing post, 50% to create new post *)
          let should_comment = Random.float 1.0 < 0.5 in
          let recent_posts = Board.list_posts store ~limit:10 () in

          if should_comment && List.length recent_posts > 0 then begin
            (* Comment on a random recent post (not own) *)
            let other_posts = List.filter (fun (p : Board.post) ->
              Board.Agent_id.to_string p.author <> name
            ) recent_posts in
            match other_posts with
            | [] ->
                Eio.traceln "   ⏭️ No posts to comment on, skipping"
            | posts ->
                let target_post = List.nth posts (Random.int (List.length posts)) in
                let original_content = target_post.content in
                (* Generate comment using LLM with agent personality *)
                match generate_agent_content
                  ~agent_name:name
                  ~context:original_content
                  ~action_type:(`Comment original_content)
                with
                | None -> () (* LLM failed, skip *)
                | Some comment_content ->
                    Eio.traceln "   🤖 Generated: %s" comment_content;
                    let post_id = Board.Post_id.to_string target_post.id in
                    match Board.add_comment store ~post_id ~author ~content:comment_content () with
                    | Ok comment ->
                        Eio.traceln "   💬 Commented on %s: %s" post_id (Board.Comment_id.to_string comment.id);
                        ignore room_config
                    | Error e ->
                        Eio.traceln "   ❌ Comment failed: %s" (Board.show_board_error e);
                        ignore room_config
          end else begin
            (* Create new post using LLM *)
            let reason_context = match reason with
              | Matching { score; topic } ->
                  Printf.sprintf "유사도 %.2f로 '%s' 주제와 매칭됨" score topic
              | Discovery { connection } ->
                  Printf.sprintf "'%s' 발견" connection
              | Random ->
                  "랜덤 영감"
            in
            match generate_agent_content
              ~agent_name:name
              ~context:reason_context
              ~action_type:(`Post reason_context)
            with
            | None -> () (* LLM failed, skip *)
            | Some content ->
                Eio.traceln "   🤖 Generated: %s" content;
                match Board.create_post store ~author ~content ~ttl_hours:168 () with
                | Ok post ->
                    Eio.traceln "   📝 Posted: %s" (Board.Post_id.to_string post.id);
                    ignore room_config
                | Error e ->
                    Eio.traceln "   ❌ Post failed: %s" (Board.show_board_error e);
                ignore room_config
          end
        ) result.agents_woken;

        Eio.Time.sleep clock config.interval_s
      done
    )
  end

(** {1 Manual Trigger (for MCP tool)} *)

let trigger_heartbeat room_config =
  let config = load_config () in
  let result = tick ~config ~recent_posts:[] in

  (* Log wake events (TODO: Broadcast via proper channel) *)
  List.iter (fun (name, _reason) ->
    Eio.traceln "🔔 %s woke up (manual trigger)" name
  ) result.agents_woken;

  ignore room_config;  (* Suppress unused warning for now *)
  result
