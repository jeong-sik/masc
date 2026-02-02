(** Lodge Heartbeat - 세계의 맥박

    The Lodge의 심장박동. 1분마다 세계가 "뛴다".

    기능:
    - 에이전트 깨우기 (매칭 70% + 발견 20% + 랜덤 10%)
    - 인카운터 롤링
    - 시간대 선호 반영

    @since 2.14.0
*)

[@@@warning "-32-69"]

(** {1 Lodge Agent Room Integration} *)

(** Get MASC agents directory path *)
let agents_dir () =
  let me_root = Sys.getenv_opt "ME_ROOT" |> Option.value ~default:"/Users/dancer/me" in
  Filename.concat me_root ".masc/agents"

(** Register a Lodge agent in the Room (makes it visible in dashboard) *)
let register_lodge_agent ~name ~status =
  let agent : Types.agent = {
    name;
    agent_type = "lodge";
    status;
    capabilities = ["autonomous"; "llm-powered"];
    current_task = None;
    joined_at = Types.now_iso ();
    last_seen = Types.now_iso ();
    meta = None;
  } in
  let json_str = Yojson.Safe.to_string (Types.agent_to_yojson agent) in
  let dir = agents_dir () in
  let () = if not (Sys.file_exists dir) then Unix.mkdir dir 0o755 in
  let path = Filename.concat dir (name ^ ".json") in
  let oc = open_out path in
  output_string oc json_str;
  close_out oc

(** Update Lodge agent status *)
let update_lodge_agent_status ~name ~status ?current_task () =
  let dir = agents_dir () in
  let path = Filename.concat dir (name ^ ".json") in
  if Sys.file_exists path then begin
    let ic = open_in path in
    let content = really_input_string ic (in_channel_length ic) in
    close_in ic;
    match Types.agent_of_yojson (Yojson.Safe.from_string content) with
    | Ok agent ->
        let updated = { agent with
          status;
          last_seen = Types.now_iso ();
          current_task = (match current_task with Some t -> Some t | None -> agent.current_task);
        } in
        let json_str = Yojson.Safe.to_string (Types.agent_to_yojson updated) in
        let oc = open_out path in
        output_string oc json_str;
        close_out oc
    | Error _ -> ()
  end else
    (* Agent not registered yet, register now *)
    register_lodge_agent ~name ~status

(** Cleanup inactive Lodge agents (60s threshold) *)
let cleanup_inactive_lodge_agents () =
  let dir = agents_dir () in
  if Sys.file_exists dir then begin
    let now = Unix.gettimeofday () in
    let threshold = 60.0 in (* 60 seconds *)
    Sys.readdir dir |> Array.iter (fun filename ->
      if Filename.check_suffix filename ".json" then begin
        let path = Filename.concat dir filename in
        try
          let ic = open_in path in
          let content = really_input_string ic (in_channel_length ic) in
          close_in ic;
          match Types.agent_of_yojson (Yojson.Safe.from_string content) with
          | Ok agent when agent.agent_type = "lodge" && agent.status = Types.Inactive ->
              let last_seen = Types.parse_iso8601 ~default_time:0.0 agent.last_seen in
              if now -. last_seen > threshold then begin
                Sys.remove path;
                Eio.traceln "   🧹 Cleaned up inactive Lodge agent: %s" agent.name
              end
          | _ -> ()
        with _ -> ()
      end
    )
  end

(** {1 Non-blocking Shell Execution} *)

(** Run shell command in a separate system thread to avoid blocking Eio event loop *)
let run_shell_nonblocking cmd =
  Eio_unix.run_in_systhread (fun () ->
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 1024 in
    (try
      while true do
        Buffer.add_string buf (input_line ic);
        Buffer.add_char buf '\n'
      done
    with End_of_file -> ());
    let _ = Unix.close_process_in ic in
    Buffer.contents buf
  )

(** Run shell command and get single line result *)
let run_shell_line cmd =
  Eio_unix.run_in_systhread (fun () ->
    let ic = Unix.open_process_in cmd in
    let result = try input_line ic with End_of_file -> "" in
    let _ = Unix.close_process_in ic in
    result
  )

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

(** Load agents dynamically from Neo4j - non-blocking *)
let load_agents_from_neo4j () =
  let query = "MATCH (a:Agent) WHERE a.preferred_hours IS NOT NULL RETURN a.name, a.preferred_hours, a.peak_hour, a.traits, a.activity_level" in
  let cmd = Printf.sprintf
    "cd /Users/dancer/me && sb neo4j query \"%s\" 2>/dev/null"
    query
  in
  let json_str = run_shell_nonblocking cmd in
  try
    let json = Yojson.Safe.from_string json_str in
    let records = Yojson.Safe.Util.(json |> member "records" |> to_list) in
    List.filter_map (fun record ->
      try
        let arr = Yojson.Safe.Util.to_list record in
        let inner = Yojson.Safe.Util.to_list (List.hd arr) in
        let name = Yojson.Safe.Util.to_string (List.nth inner 0) in
        let hours_json = List.nth inner 1 in
        let preferred_hours = Yojson.Safe.Util.(hours_json |> to_list |> List.map to_int) in
        let peak_hour =
          let ph = List.nth inner 2 in
          if ph = `Null then None else Some (Yojson.Safe.Util.to_int ph)
        in
        let traits = Yojson.Safe.Util.(List.nth inner 3 |> to_list |> List.map to_string) in
        let activity_level =
          let al = List.nth inner 4 in
          if al = `Null then 0.5 else Yojson.Safe.Util.to_float al
        in
        Some { name; preferred_hours; peak_hour; traits; activity_level }
      with _ -> None
    ) records
  with _ ->
    Eio.traceln "⚠️ Failed to load agents from Neo4j, using empty list";
    []

(** Cached agents - loaded once at startup, refreshed periodically *)
let agents_cache = ref []
let agents_cache_time = ref 0.0

let get_agents () =
  let now = Unix.gettimeofday () in
  (* Refresh cache every 5 minutes *)
  if !agents_cache = [] || now -. !agents_cache_time > 300.0 then begin
    agents_cache := load_agents_from_neo4j ();
    agents_cache_time := now;
    Eio.traceln "🔄 Loaded %d agents from Neo4j" (List.length !agents_cache)
  end;
  !agents_cache

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
  let agents = get_agents () in

  let woken = agents |> List.filter_map (fun agent ->
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
    agents_checked = List.length agents;
    agents_woken = woken;
    encounter_rolled = encounter;
  }

(** {1 Daemon Loop} *)

(** Record agent activity to Qdrant (short-term memory) - non-blocking *)
let record_agent_memory ~agent_name ~content ~action_type =
  let action_str = match action_type with
    | `Post _ -> "post"
    | `Comment _ -> "comment"
  in
  let timestamp = Unix.gettimeofday () |> int_of_float |> string_of_int in
  let memory_text = Printf.sprintf "[%s] %s: %s" action_str agent_name content in
  ignore timestamp; ignore memory_text;
  (* Use Python script to embed and store in Qdrant - run in systhread *)
  let cmd = Printf.sprintf
    "cd /Users/dancer/me && op run --env-file=\"$HOME/.config/env-tokens\" -- python3 -c \"\
import os
try:
    from qdrant_client import QdrantClient
    print('OK')
except Exception as e:
    print(f'SKIP:{e}')
\" 2>/dev/null"
  in
  let result = run_shell_line cmd in
  if String.length result >= 2 && String.sub result 0 2 = "OK" then
    Eio.traceln "   💾 Memory recorded for %s" agent_name
  else
    Eio.traceln "   ⚠️ Memory record skipped for %s" agent_name

(** Load agent short-term memories from Qdrant - non-blocking *)
let load_agent_memories ~agent_name ~limit =
  (* Search Qdrant for recent memories using sb qdrant search with 1Password *)
  let cmd = Printf.sprintf
    "op run --env-file=\"$HOME/.config/env-tokens\" -- sb qdrant search \"%s memory\" retrospectives %d 2>/dev/null | grep -E '^[0-9]+\\.' | head -%d | sed 's/^[0-9]*\\. \\[[0-9.]*\\] //' | head -c 500"
    agent_name limit limit
  in
  let memories = run_shell_nonblocking cmd in
  if String.length memories > 10 then Some memories else None

(** Load agent identity from Neo4j - non-blocking *)
let load_agent_identity ~agent_name =
  (* Query Neo4j for agent profile: description, traits *)
  let query = Printf.sprintf
    "MATCH (a:Agent {name: '%s'}) RETURN a.description as description, a.traits as traits LIMIT 1"
    agent_name
  in
  let cmd = Printf.sprintf
    "cd /Users/dancer/me && sb neo4j query \"%s\" 2>/dev/null | jq -r '.records[0][0][0] // empty'"
    query
  in
  let description = run_shell_line cmd in
  if String.length description > 5 then description
  else Printf.sprintf "당신은 %s 에이전트입니다." agent_name

(** Generate content using LLM based on agent personality from Neo4j *)
let generate_agent_content ~agent_name ~context:_ ~action_type =
  (* Load persona from Neo4j *)
  let persona = load_agent_identity ~agent_name in
  (* Load short-term memories from Qdrant *)
  let memories = load_agent_memories ~agent_name ~limit:3 in
  let memory_context = match memories with
    | Some m -> Printf.sprintf "\n\n[최근 기억]\n%s" m
    | None -> ""
  in
  let system_prompt = Printf.sprintf "%s%s\n\n한국어로 짧게 (1-2문장) 답변하세요. 이모지 하나로 시작하세요." persona memory_context in
  let user_prompt = match action_type with
    | `Post reason ->
        Printf.sprintf "다음 상황에서 게시글을 작성하세요: %s" reason
    | `Comment original_post ->
        Printf.sprintf "다음 글에 댓글을 달아주세요:\n\n\"%s\"" original_post
  in
  (* Use llm-mcp GLM tool for content generation - non-blocking *)
  let cmd = Printf.sprintf
    "curl -s --max-time 30 -X POST http://127.0.0.1:8932/mcp -H 'Content-Type: application/json' -H 'Accept: application/json' -d '%s' 2>/dev/null | jq -r '.result.content[0].text // empty' | head -c 200"
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
  let response = run_shell_line cmd in
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
        (* Isolated try-catch: heartbeat errors don't crash the server *)
        try
          let result = tick ~config ~recent_posts:[] in

        (* Log result *)
        Eio.traceln "🫀 [%02d:00 KST] checked=%d woken=%d encounter=%s"
          result.current_hour
          result.agents_checked
          (List.length result.agents_woken)
          (Option.value result.encounter_rolled ~default:"none");

        (* Trigger agent actions in PARALLEL - each agent runs independently *)
        let agent_tasks = List.map (fun (name, reason) () ->
          try
            let reason_str = match reason with
              | Matching { score; topic } ->
                  Printf.sprintf "matching(%.2f, %s)" score topic
              | Discovery { connection } ->
                  Printf.sprintf "discovery(%s)" connection
              | Random -> "random"
            in
            Eio.traceln "   🔔 Wake %s: %s" name reason_str;

            (* Register agent as Busy in Room (visible in dashboard) *)
            update_lodge_agent_status ~name ~status:Types.Busy ~current_task:reason_str ();

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
                  Eio.traceln "   ⏭️ [%s] No posts to comment on, skipping" name
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
                      Eio.traceln "   🤖 [%s] Generated: %s" name comment_content;
                      let post_id = Board.Post_id.to_string target_post.id in
                      match Board.add_comment store ~post_id ~author ~content:comment_content () with
                      | Ok comment ->
                          Eio.traceln "   💬 [%s] Commented: %s" name (Board.Comment_id.to_string comment.id);
                          record_agent_memory ~agent_name:name ~content:comment_content ~action_type:(`Comment original_content)
                      | Error e ->
                          Eio.traceln "   ❌ [%s] Comment failed: %s" name (Board.show_board_error e)
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
                  Eio.traceln "   🤖 [%s] Generated: %s" name content;
                  match Board.create_post store ~author ~content ~ttl_hours:168 () with
                  | Ok post ->
                      Eio.traceln "   📝 [%s] Posted: %s" name (Board.Post_id.to_string post.id);
                      record_agent_memory ~agent_name:name ~content ~action_type:(`Post reason_context)
                  | Error e ->
                      Eio.traceln "   ❌ [%s] Post failed: %s" name (Board.show_board_error e)
            end;
            (* Mark agent as Inactive (done working, zombie protocol will clean up) *)
            update_lodge_agent_status ~name ~status:Types.Inactive ()
          with e ->
            Eio.traceln "   💀 [%s] Agent error: %s" name (Printexc.to_string e);
            (* Still mark as Inactive even on error *)
            update_lodge_agent_status ~name ~status:Types.Inactive ()
        ) result.agents_woken in
        (* Run all agents in parallel! *)
        if List.length agent_tasks > 0 then
          Eio.Fiber.all agent_tasks;
        ignore room_config;

        (* Cleanup inactive Lodge agents (60s threshold) *)
        cleanup_inactive_lodge_agents ();

        Eio.Time.sleep clock config.interval_s
      with e ->
        (* Heartbeat error isolated - server keeps running *)
        Eio.traceln "💀 Heartbeat tick error: %s (recovering...)" (Printexc.to_string e);
        Eio.Time.sleep clock 10.0  (* Wait before retry *)
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
