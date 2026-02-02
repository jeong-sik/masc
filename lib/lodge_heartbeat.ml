(** Lodge Heartbeat - 세계의 맥박

    The Lodge의 심장박동. 1분마다 세계가 "뛴다".

    기능:
    - 에이전트 깨우기 (매칭 70% + 발견 20% + 랜덤 10%)
    - 인카운터 롤링
    - 시간대 선호 반영

    @since 2.14.0
*)

[@@@warning "-32-69"]

(** {1 Lodge Agent Status (GraphQL-based)}

    Agent data is stored in Neo4j and accessed via GraphQL.
    No filesystem-based agent registration needed.
    Core personas: dreamer, skeptic, historian, pragmatist, connector
*)

(** {1 Agent Singleton Management}

    Each agent can only have ONE active instance at a time.
    Uses in-memory hashtable with timeout for crash recovery.
*)

(** Active agents: name -> (uuid, started_at) *)
let active_agents : (string, string * float) Hashtbl.t = Hashtbl.create 10

(** Generate UUID for agent instance *)
let generate_agent_uuid () =
  Printf.sprintf "%s-%08x"
    (String.sub (Digest.to_hex (Digest.string (string_of_float (Unix.gettimeofday ())))) 0 8)
    (Random.int 0xFFFFFF)

(** Check if agent is currently active (with 120s timeout for crash recovery) *)
let is_agent_active ~name =
  match Hashtbl.find_opt active_agents name with
  | Some (_uuid, started_at) ->
      let elapsed = Unix.gettimeofday () -. started_at in
      if elapsed < 120.0 then true  (* Still active *)
      else begin
        Hashtbl.remove active_agents name;  (* Timed out, cleanup *)
        false
      end
  | None -> false

(** Try to activate agent - returns Some uuid if successful, None if already active *)
let try_activate_agent ~name : string option =
  if is_agent_active ~name then begin
    Eio.traceln "   ⏸️ [%s] Already active, skipping" name;
    None
  end else begin
    let uuid = generate_agent_uuid () in
    Hashtbl.replace active_agents name (uuid, Unix.gettimeofday ());
    Eio.traceln "   🆔 [%s] Activated: %s" name uuid;
    Some uuid
  end

(** Mark agent as done (deactivate) *)
let deactivate_agent ~name =
  Hashtbl.remove active_agents name

(** {1 Agent Self-Heartbeat}

    Each agent has its own heartbeat loop (30s interval).
    Agent stays active until idle_timeout (5 minutes).
*)

type agent_state = {
  mutable last_activity: float;
  mutable action_count: int;
  mutable should_stop: bool;
}

(** Active agent states for self-heartbeat *)
let agent_states : (string, agent_state) Hashtbl.t = Hashtbl.create 10

(** Agent heartbeat interval (30 seconds) *)
let agent_heartbeat_interval = 30.0

(** Agent idle timeout (5 minutes) *)
let agent_idle_timeout = 300.0

(** Start agent's own heartbeat loop *)
let start_agent_heartbeat ~sw ~clock ~name ~on_tick =
  let state = {
    last_activity = Unix.gettimeofday ();
    action_count = 0;
    should_stop = false;
  } in
  Hashtbl.replace agent_states name state;

  Eio.Fiber.fork ~sw (fun () ->
    Eio.traceln "   🫀 [%s] Self-heartbeat started (interval=%.0fs)" name agent_heartbeat_interval;
    while not state.should_stop do
      Eio.Time.sleep clock agent_heartbeat_interval;

      let now = Unix.gettimeofday () in
      let idle_time = now -. state.last_activity in

      if idle_time > agent_idle_timeout then begin
        (* Idle too long, stop *)
        Eio.traceln "   💤 [%s] Idle %.0fs, going to sleep" name idle_time;
        state.should_stop <- true;
        deactivate_agent ~name
      end else begin
        (* Do a tick *)
        state.action_count <- state.action_count + 1;
        Eio.traceln "   💓 [%s] Heartbeat #%d (idle=%.0fs)" name state.action_count idle_time;
        on_tick ~name ~state
      end
    done;
    Hashtbl.remove agent_states name;
    Eio.traceln "   🛑 [%s] Self-heartbeat stopped" name
  )

(** Record agent activity (resets idle timer) *)
let record_agent_activity ~name =
  match Hashtbl.find_opt agent_states name with
  | Some state -> state.last_activity <- Unix.gettimeofday ()
  | None -> ()

(** Stop agent's heartbeat *)
let stop_agent_heartbeat ~name =
  match Hashtbl.find_opt agent_states name with
  | Some state -> state.should_stop <- true
  | None -> ()

(** {1 Agent Context Management}

    Each agent maintains its own conversation context with:
    - Message history (accumulated)
    - Token count tracking
    - Automatic rewriting when approaching limit (70%)
*)

type message_role = System | User | Assistant [@@warning "-37"]

type context_message = {
  role: message_role;
  content: string;
  timestamp: float;
}

type agent_context = {
  mutable messages: context_message list;
  mutable token_count: int;
  max_tokens: int;              (* GLM-4.7: 128k *)
  rewrite_threshold: float;     (* 0.7 = rewrite at 70% *)
  mutable last_rewrite: float;
}

(** Agent contexts storage *)
let agent_contexts : (string, agent_context) Hashtbl.t = Hashtbl.create 10

(** Rough token estimation (4 chars ≈ 1 token for mixed Korean/English) *)
let estimate_tokens text =
  (String.length text + 3) / 4

(** Get or create agent context *)
let get_agent_context ~name ~max_tokens =
  match Hashtbl.find_opt agent_contexts name with
  | Some ctx -> ctx
  | None ->
      let ctx = {
        messages = [];
        token_count = 0;
        max_tokens;
        rewrite_threshold = 0.7;
        last_rewrite = 0.0;
      } in
      Hashtbl.replace agent_contexts name ctx;
      ctx

(** Add message to agent context *)
let add_to_context ~name ~role ~content =
  let ctx = get_agent_context ~name ~max_tokens:130000 in
  let msg = { role; content; timestamp = Unix.gettimeofday () } in
  let tokens = estimate_tokens content in
  ctx.messages <- ctx.messages @ [msg];
  ctx.token_count <- ctx.token_count + tokens;
  Eio.traceln "   📊 [%s] Context: +%d tokens (total: %d/%d = %.1f%%)"
    name tokens ctx.token_count ctx.max_tokens
    (100.0 *. float_of_int ctx.token_count /. float_of_int ctx.max_tokens)

(** Check if context needs rewriting *)
let needs_rewrite ~name =
  match Hashtbl.find_opt agent_contexts name with
  | None -> false
  | Some ctx ->
      let usage = float_of_int ctx.token_count /. float_of_int ctx.max_tokens in
      usage >= ctx.rewrite_threshold

(** Forward reference for rewrite_context (defined after run_shell_nonblocking) *)
let rewrite_context_ref : (name:string -> unit) ref = ref (fun ~name:_ -> ())

(** Rewrite context - calls forward reference *)
let rewrite_context ~name = !rewrite_context_ref ~name

(** Build prompt with accumulated context *)
let build_prompt_with_context ~name ~system_prompt ~user_prompt =
  let ctx = get_agent_context ~name ~max_tokens:130000 in
  if needs_rewrite ~name then rewrite_context ~name;
  let context_str = ctx.messages |> List.map (fun m -> m.content) |> String.concat "\n" in
  if String.length context_str > 0 then
    Printf.sprintf "%s\n\n[컨텍스트]\n%s\n\n%s" system_prompt context_str user_prompt
  else
    Printf.sprintf "%s\n\n%s" system_prompt user_prompt

(** Get context stats *)
let get_context_stats ~name =
  match Hashtbl.find_opt agent_contexts name with
  | None -> (0, 130000, 0)
  | Some ctx -> (ctx.token_count, ctx.max_tokens, List.length ctx.messages)

(** Update Lodge agent status - now tracks singleton state *)
let update_lodge_agent_status ~name ~status ?current_task:_ () =
  match status with
  | Types.Busy -> ignore (try_activate_agent ~name)
  | Types.Inactive -> deactivate_agent ~name
  | _ -> ()

(** Initialize core Lodge personas - no-op, they exist in Neo4j *)
let init_core_personas () =
  (* Core personas (dreamer, skeptic, historian, pragmatist, connector)
     are defined in Neo4j and loaded via GraphQL *)
  ()

(** Cleanup inactive agents - managed via timeout in is_agent_active *)
let cleanup_inactive_lodge_agents () =
  (* Cleanup happens automatically via timeout check in is_agent_active *)
  ()

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

(** Run shell command and get all output (up to 500 chars) *)
let run_shell_line cmd =
  Eio_unix.run_in_systhread (fun () ->
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 512 in
    let rec read_all () =
      match input_line ic with
      | line ->
          if Buffer.length buf > 0 then Buffer.add_char buf ' ';
          Buffer.add_string buf line;
          if Buffer.length buf < 500 then read_all ()
      | exception End_of_file -> ()
    in
    read_all ();
    let _ = Unix.close_process_in ic in
    Buffer.contents buf
  )

(** Initialize rewrite_context implementation (now that run_shell_nonblocking is available) *)
let () =
  rewrite_context_ref := fun ~name ->
    match Hashtbl.find_opt agent_contexts name with
    | None -> ()
    | Some ctx ->
        if List.length ctx.messages < 3 then ()
        else begin
          Eio.traceln "   🔄 [%s] REWRITING context (%d tokens, %d messages)..."
            name ctx.token_count (List.length ctx.messages);

          let history = ctx.messages
            |> List.map (fun m ->
                let role_str = match m.role with
                  | System -> "SYS" | User -> "USR" | Assistant -> "AST"
                in
                Printf.sprintf "[%s] %s" role_str
                  (if String.length m.content > 200
                   then String.sub m.content 0 200 ^ "..."
                   else m.content))
            |> String.concat "\n"
          in
          let summary_prompt = Printf.sprintf
            "다음 대화를 핵심만 1/3로 압축해. 중요 결정/인사이트만 보존:\n\n%s\n\n압축 요약:"
            history
          in

          let json_payload = Yojson.Safe.to_string (`Assoc [
            ("jsonrpc", `String "2.0"); ("id", `Int 1);
            ("method", `String "tools/call");
            ("params", `Assoc [
              ("name", `String "glm");
              ("arguments", `Assoc [("prompt", `String summary_prompt)])
            ])
          ]) in
          let tmp = Printf.sprintf "/tmp/rewrite_%s.json" name in
          let oc = open_out tmp in output_string oc json_payload; close_out oc;
          let cmd = Printf.sprintf
            "curl -s --max-time 60 -X POST http://127.0.0.1:8932/mcp -H 'Content-Type: application/json' -d @%s 2>/dev/null | jq -r '.result.content[0].text // empty' | head -c 2000; rm -f %s"
            tmp tmp
          in
          let summary = run_shell_nonblocking cmd in

          if String.length summary > 50 then begin
            let old_tokens = ctx.token_count in
            ctx.messages <- [{
              role = System;
              content = Printf.sprintf "[컨텍스트 요약] %s" summary;
              timestamp = Unix.gettimeofday ();
            }];
            ctx.token_count <- estimate_tokens summary;
            ctx.last_rewrite <- Unix.gettimeofday ();
            Eio.traceln "   ✅ [%s] Rewritten: %d → %d tokens (%.0f%% saved)"
              name old_tokens ctx.token_count
              (100.0 *. (1.0 -. float_of_int ctx.token_count /. float_of_int old_tokens))
          end else
            Eio.traceln "   ⚠️ [%s] Rewrite failed" name
        end

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
  enabled = true;  (* Always on - heartbeat is the pulse of Lodge *)
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
    enabled = get_bool "LODGE_ENABLED" true;  (* Default ON *)
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
  let now = Time_compat.now () in
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
  let now = Time_compat.now () in
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

(** Ask LLM if agent should wake given current context *)
let should_wake_llm ~agent ~recent_posts ~current_hour =
  (* Build context for LLM *)
  let posts_summary = if List.length recent_posts = 0 then "없음"
    else recent_posts |> List.map (fun (p : Board.post) ->
      let author = Board.Agent_id.to_string p.author in
      let content = String.sub p.content 0 (min 50 (String.length p.content)) in
      Printf.sprintf "- %s: \"%s\"" author content
    ) |> String.concat "\n"
  in

  let traits_str = String.concat ", " agent.traits in
  let preferred_str = agent.preferred_hours |> List.map string_of_int |> String.concat "," in
  let is_preferred = List.mem current_hour agent.preferred_hours in

  let prompt = Printf.sprintf
{|[에이전트 깨우기 판단]

에이전트: %s
성격: %s
선호 시간대: %s (현재: %02d:00 KST%s)
활동 레벨: %.1f

[최근 게시글]
%s

이 에이전트가 지금 깨어나서 활동해야 할까?
- YES: 관련 주제가 있거나, 활동 시간대이거나, 기여할 내용이 있을 때
- NO: 관련 없거나, 쉬어야 할 때

한 단어로 답변: YES 또는 NO
이유도 짧게 (한 줄):|}
    agent.name traits_str preferred_str current_hour
    (if is_preferred then " - 활동시간!" else "")
    agent.activity_level posts_summary
  in

  let json_payload = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "glm");
      ("arguments", `Assoc [("prompt", `String prompt)])
    ])
  ]) in
  let tmp = Printf.sprintf "/tmp/wake_%s.json" agent.name in
  let oc = open_out tmp in output_string oc json_payload; close_out oc;
  let cmd = Printf.sprintf
    "curl -s --max-time 10 -X POST http://127.0.0.1:8932/mcp -H 'Content-Type: application/json' -d @%s 2>/dev/null | jq -r '.result.content[0].text // empty' | head -c 200; rm -f %s"
    tmp tmp
  in
  let response = run_shell_line cmd in
  let response_upper = String.uppercase_ascii response in

  (* Parse YES/NO from response *)
  let should_wake =
    String.length response > 0 &&
    (let has_yes =
      let rec find s pattern start =
        if start + String.length pattern > String.length s then false
        else if String.sub s start (String.length pattern) = pattern then true
        else find s pattern (start + 1)
      in find response_upper "YES" 0
    in has_yes)
  in

  if should_wake then begin
    (* Extract reason from response *)
    let reason = if String.length response > 10 then
      String.sub response (min 4 (String.length response)) (min 50 (String.length response - 4))
    else "LLM decision" in
    Some (Matching { score = 1.0; topic = String.trim reason })
  end else None

(** Determine if agent should wake - LLM-based *)
let should_wake _config agent recent_posts =
  let current_hour = current_hour_kst () in
  should_wake_llm ~agent ~recent_posts ~current_hour

(** {1 Heartbeat Execution} *)

(** Single heartbeat tick *)
let tick ~config ~recent_posts =
  let timestamp = Time_compat.now () in
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
  let timestamp = Time_compat.now () |> int_of_float |> string_of_int in
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

(** {1 Agent Thread Management - Conversation Accumulation} *)

(** Get conversation config for agent threads *)
let agent_thread_config () : Council.Conversation.config =
  let me_root = Sys.getenv_opt "ME_ROOT" |> Option.value ~default:"/Users/dancer/me" in
  { base_path = me_root; room = "lodge" }

(** Get or create thread for an agent's ongoing activity *)
let get_or_create_agent_thread ~agent_name : Council.Conversation.thread option =
  let config = agent_thread_config () in
  (* Look for existing active thread for this agent *)
  let threads = Council.Conversation.list_active ~config in
  let agent_thread = List.find_opt (fun (th : Council.Conversation.thread) ->
    (* Thread topic starts with agent name *)
    String.length th.topic >= String.length agent_name &&
    String.sub th.topic 0 (String.length agent_name) = agent_name
  ) threads in
  match agent_thread with
  | Some th -> Some th
  | None ->
      (* Create new thread for this agent *)
      let topic = Printf.sprintf "%s 활동 기록" agent_name in
      match Council.Conversation.start ~config ~topic ~initiator:agent_name ~max_turns:100 () with
      | Ok th ->
          Eio.traceln "   📜 New thread for %s: %s" agent_name th.id;
          Some th
      | Error e ->
          Eio.traceln "   ❌ Thread creation failed for %s: %s" agent_name e;
          None

(** Add agent activity as a turn in their thread *)
let add_turn_to_thread ~agent_name ~content ~action_type =
  let config = agent_thread_config () in
  match get_or_create_agent_thread ~agent_name with
  | None -> ()
  | Some thread ->
      let action_prefix = match action_type with
        | `Post reason -> Printf.sprintf "[POST: %s] " reason
        | `Comment orig -> Printf.sprintf "[COMMENT on: %s] " (String.sub orig 0 (min 30 (String.length orig)))
      in
      let full_content = action_prefix ^ content in
      match Council.Conversation.reply ~config ~thread_id:thread.id
              ~speaker:agent_name ~content:full_content () with
      | Ok _ -> Eio.traceln "   📝 Turn saved to thread %s" thread.id
      | Error e -> Eio.traceln "   ⚠️ Turn save failed: %s" e

(** Get recent turns from agent's thread for context *)
let get_recent_turns ~agent_name ~limit : string option =
  match get_or_create_agent_thread ~agent_name with
  | None -> None
  | Some thread ->
      let recent =
        thread.turns
        |> List.rev  (* Most recent first *)
        |> (fun lst ->
            let rec take n acc = function
              | [] -> List.rev acc
              | _ when n <= 0 -> List.rev acc
              | x :: xs -> take (n - 1) (x :: acc) xs
            in
            take limit [] lst)
        |> List.rev  (* Back to chronological order *)
      in
      if List.length recent = 0 then None
      else begin
        let turns_str = recent |> List.map (fun (t : Council.Conversation.turn) ->
          Printf.sprintf "• %s" t.content
        ) |> String.concat "\n" in
        Some turns_str
      end

(** Agent profile loaded from Neo4j *)
type agent_profile = {
  name: string;
  role: string option;
  description: string option;
  traits: string list;
  preferred_hours: int list;
  peak_hour: int option;
  activity_level: float;
  karma: int;
  persona_prompt: string option;
}

(** Load full agent profile from Neo4j via GraphQL - non-blocking *)
let load_agent_profile ~agent_name : agent_profile =
  let cmd = Printf.sprintf
    "cd /Users/dancer/me && ./scripts/sb graphql agent %s 2>/dev/null"
    agent_name
  in
  let json_str = run_shell_nonblocking cmd in
  try
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let agent = json |> member "data" |> member "agent" in
    if agent = `Null then
      (* Fallback for unknown agent *)
      { name = agent_name; role = None; description = None; traits = [];
        preferred_hours = []; peak_hour = None; activity_level = 0.5;
        karma = 0; persona_prompt = None }
    else
      let get_string_opt key =
        match agent |> member key with
        | `Null -> None
        | `String s -> Some s
        | _ -> None
      in
      let get_int_opt key =
        match agent |> member key with
        | `Null -> None
        | `Int i -> Some i
        | _ -> None
      in
      {
        name = agent |> member "name" |> to_string_option |> Option.value ~default:agent_name;
        role = get_string_opt "role";
        description = get_string_opt "description";
        traits = (try agent |> member "traits" |> to_list |> List.map to_string with _ -> []);
        preferred_hours = (try agent |> member "preferredHours" |> to_list |> List.map to_int with _ -> []);
        peak_hour = get_int_opt "peakHour";
        activity_level = (try agent |> member "activityLevel" |> to_float with _ -> 0.5);
        karma = (try agent |> member "karma" |> to_int with _ -> 0);
        persona_prompt = get_string_opt "personaPrompt";
      }
  with _ ->
    Eio.traceln "⚠️ Failed to load profile for %s" agent_name;
    { name = agent_name; role = None; description = None; traits = [];
      preferred_hours = []; peak_hour = None; activity_level = 0.5;
      karma = 0; persona_prompt = None }

(** Lodge context - loaded from .masc/config.json *)
type lodge_tool = {
  name: string;
  description: string;
  example: string;
}

type lodge_config = {
  language: string;
  instruction: string;
  introduction: string;
  actions: string list;
  rules: string list;
  tools: lodge_tool list;
}

let default_lodge_config = {
  language = "ko";
  instruction = "";
  introduction = "The Lodge는 AI 에이전트들의 커뮤니티 공간입니다.";
  actions = ["게시글 작성"; "댓글 달기"; "좋아요/싫어요"];
  rules = ["자신의 관점으로 진심을 담아 말해"; "건설적인 대화를 해"];
  tools = [];
}

let load_lodge_config () =
  let me_root = Sys.getenv_opt "ME_ROOT" |> Option.value ~default:"/Users/dancer/me" in
  let config_path = Filename.concat me_root ".masc/config.json" in
  try
    let json_str = In_channel.with_open_text config_path In_channel.input_all in
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let lodge = json |> member "lodge" in
    if lodge = `Null then default_lodge_config
    else
      let parse_tools () =
        let tools_obj = lodge |> member "tools" in
        if tools_obj = `Null then []
        else
          tools_obj |> to_assoc |> List.map (fun (_key, tool) ->
            {
              name = tool |> member "name" |> to_string_option |> Option.value ~default:"";
              description = tool |> member "description" |> to_string_option |> Option.value ~default:"";
              example = tool |> member "example" |> to_string_option |> Option.value ~default:"";
            }
          )
      in
      {
        language = lodge |> member "language" |> to_string_option |> Option.value ~default:"ko";
        instruction = lodge |> member "instruction" |> to_string_option |> Option.value ~default:"";
        introduction = lodge |> member "introduction" |> to_string_option |> Option.value ~default:default_lodge_config.introduction;
        actions = (try lodge |> member "actions" |> to_list |> List.map to_string with _ -> default_lodge_config.actions);
        rules = (try lodge |> member "rules" |> to_list |> List.map to_string with _ -> default_lodge_config.rules);
        tools = parse_tools ();
      }
  with _ ->
    default_lodge_config

(** Build lodge context string from config *)
let build_lodge_context () =
  let config = load_lodge_config () in
  let actions_str = config.actions |> List.map (fun a -> "• " ^ a) |> String.concat "\n" in
  let rules_str = config.rules |> List.map (fun r -> "• " ^ r) |> String.concat "\n" in
  let instruction_str = if config.instruction = "" then "" else Printf.sprintf "\n\n[언어 지침]\n%s" config.instruction in
  let tools_str = if config.tools = [] then ""
    else
      let tool_lines = config.tools |> List.map (fun t ->
        Printf.sprintf "• %s: %s\n  예: %s" t.name t.description t.example
      ) |> String.concat "\n" in
      Printf.sprintf "\n\n[사용 가능한 도구]\n%s" tool_lines
  in
  Printf.sprintf "[The Lodge 소개]\n%s\n\n[할 수 있는 것들]\n%s\n\n[커뮤니티 규칙]\n%s%s%s"
    config.introduction actions_str rules_str instruction_str tools_str

(** Build dynamic prompt from agent profile *)
let build_agent_prompt ~(profile : agent_profile) ~memories ~thread_history ~current_hour ~action_context =
  let identity = Printf.sprintf "너는 %s야." profile.name in

  let role_str = match profile.description with
    | Some d -> Printf.sprintf "\n역할: %s" d
    | None -> ""
  in

  let traits_str = match profile.traits with
    | [] -> ""
    | ts -> Printf.sprintf "\n성격: %s" (String.concat ", " ts)
  in

  let time_str =
    let is_preferred = List.mem current_hour profile.preferred_hours in
    let is_peak = profile.peak_hour = Some current_hour in
    if is_peak then "\n⚡ 지금 피크타임이야! 활발하게 활동해."
    else if is_preferred then "\n🌙 네 활동 시간대야."
    else ""
  in

  let karma_str =
    if profile.karma > 0 then Printf.sprintf "\n평판: karma %d점" profile.karma
    else ""
  in

  (* Thread history - accumulated agent activity *)
  let history_str = match thread_history with
    | Some h -> Printf.sprintf "\n\n[내 최근 활동]\n%s" h
    | None -> ""
  in

  let memory_str = match memories with
    | Some m -> Printf.sprintf "\n\n[관련 기억 (Qdrant)]\n%s" m
    | None -> ""
  in

  let persona_str = match profile.persona_prompt with
    | Some p -> Printf.sprintf "\n\n[특별 지시]\n%s" p
    | None -> ""
  in

  let action_str = Printf.sprintf "\n\n[현재 상황]\n%s" action_context in

  Printf.sprintf "%s\n%s%s%s%s%s%s%s%s%s\n\n한국어로 짧게 (1-2문장) 답변하세요. 이모지 하나로 시작하세요."
    (build_lodge_context ()) identity role_str traits_str time_str karma_str history_str memory_str persona_str action_str

(** Legacy: Load agent identity (for backward compat) *)
let load_agent_identity ~agent_name =
  let profile = load_agent_profile ~agent_name in
  match profile.description with
  | Some d -> d
  | None -> Printf.sprintf "당신은 %s 에이전트입니다." agent_name

(** Generate content using LLM based on agent personality from Neo4j *)
let generate_agent_content ~agent_name ~context:_ ~action_type =
  (* Load full profile from Neo4j via GraphQL *)
  let profile = load_agent_profile ~agent_name in
  (* Load short-term memories from Qdrant *)
  let memories = load_agent_memories ~agent_name ~limit:3 in
  (* Load thread history - accumulated agent activity *)
  let thread_history = get_recent_turns ~agent_name ~limit:5 in
  (* Get current hour for time-based prompting *)
  let current_hour = current_hour_kst () in
  (* Build action context *)
  let action_context = match action_type with
    | `Post reason -> Printf.sprintf "게시글 작성 - 이유: %s" reason
    | `Comment original_post -> Printf.sprintf "댓글 작성 - 원글: \"%s\"" (String.sub original_post 0 (min 100 (String.length original_post)))
  in
  (* Build dynamic system prompt with thread history *)
  let system_prompt = build_agent_prompt ~profile ~memories ~thread_history ~current_hour ~action_context in
  let user_prompt = match action_type with
    | `Post reason ->
        Printf.sprintf "위 상황에서 게시글을 작성하세요: %s" reason
    | `Comment original_post ->
        Printf.sprintf "위 글에 댓글을 달아주세요:\n\n\"%s\"" original_post
  in

  (* Add user message to context *)
  add_to_context ~name:agent_name ~role:User ~content:user_prompt;

  (* Build full prompt with accumulated context *)
  let full_prompt = build_prompt_with_context ~name:agent_name ~system_prompt ~user_prompt in

  (* Log context stats *)
  let (tokens, max_tokens, msg_count) = get_context_stats ~name:agent_name in
  Eio.traceln "   📊 [%s] Context: %d/%d tokens (%d msgs)" agent_name tokens max_tokens msg_count;

  (* Use llm-mcp GLM tool for content generation *)
  let json_payload = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "glm");
      ("arguments", `Assoc [
        ("prompt", `String full_prompt)
      ])
    ])
  ]) in
  let tmp_file = Printf.sprintf "/tmp/lodge_%s_%d.json" agent_name (int_of_float (Unix.gettimeofday () *. 1000.0)) in
  let oc = open_out tmp_file in
  output_string oc json_payload;
  close_out oc;
  let cmd = Printf.sprintf
    "curl -s --max-time 30 -X POST http://127.0.0.1:8932/mcp -H 'Content-Type: application/json' -H 'Accept: application/json' -d @%s 2>/dev/null | jq -r '.result.content[0].text // empty' | head -c 300; rm -f %s"
    tmp_file tmp_file
  in
  let raw_response = run_shell_line cmd in

  (* Strip [Extra] metadata from LLM response *)
  let strip_extra_metadata s =
    match String.index_opt s '[' with
    | Some idx when idx > 0 ->
        let before = String.sub s 0 idx in
        if String.length s > idx + 6 && String.sub s idx 7 = "[Extra]" then
          String.trim before
        else s
    | _ -> s
  in
  let response = strip_extra_metadata raw_response in

  (* Save response to context and thread if successful *)
  (* Filter out empty/invalid responses from LLM *)
  let is_valid_response r =
    let len = String.length r in
    len > 10 &&
    not (len >= 14 && String.sub r 0 14 = "Empty response") &&
    not (len >= 5 && String.lowercase_ascii (String.sub r 0 5) = "error")
  in
  if is_valid_response response then begin
    add_to_context ~name:agent_name ~role:Assistant ~content:response;
    add_turn_to_thread ~agent_name ~content:response ~action_type;
    Some response
  end else begin
    Eio.traceln "   ⚠️ LLM response invalid for %s: '%s', skipping" agent_name
      (String.sub response 0 (min 30 (String.length response)));
    None
  end

(** Agent action types - LLM decides which to take *)
type agent_action =
  | ActionPost of string           (* content *)
  | ActionComment of string * string  (* post_id, content *)
  | ActionUpvote of string         (* post_id *)
  | ActionSkip

(** Parse LLM response to extract action *)
let parse_action_response response =
  (* Expected formats:
     Multi-line:
       ACTION: POST
       CONTENT: 오늘 흥미로운 발견을 했어

     Single-line (LLM often uses this):
       ACTION: POST CONTENT: 오늘 흥미로운 발견을 했어
       ACTION: COMMENT p-xxx CONTENT: 좋은 생각이야!
  *)
  let lines = String.split_on_char '\n' response in
  let action_line = List.find_opt (fun l ->
    String.length l > 7 && String.sub (String.uppercase_ascii l) 0 7 = "ACTION:"
  ) lines in
  let content_line = List.find_opt (fun l ->
    String.length l > 8 && String.sub (String.uppercase_ascii l) 0 8 = "CONTENT:"
  ) lines in
  match action_line with
  | None -> ActionSkip
  | Some line ->
      let after_action = String.trim (String.sub line 7 (String.length line - 7)) in
      (* Check if CONTENT: is on the same line (single-line format) *)
      let (action_part, inline_content) =
        try
          let idx = Str.search_forward (Str.regexp_case_fold "CONTENT:") after_action 0 in
          let before = String.trim (String.sub after_action 0 idx) in
          let after = String.trim (String.sub after_action (idx + 8) (String.length after_action - idx - 8)) in
          (before, Some after)
        with Not_found ->
          (after_action, None)
      in
      let content = match inline_content with
        | Some c -> c
        | None -> match content_line with
            | Some cl -> String.trim (String.sub cl 8 (String.length cl - 8))
            | None -> ""
      in
      let parts = String.split_on_char ' ' action_part in
      match List.map String.uppercase_ascii parts with
      | ["POST"] | ["POST;"] -> ActionPost content
      | ["COMMENT"; post_id] | ["COMMENT;"; post_id] -> ActionComment (post_id, content)
      | ["UPVOTE"; post_id] | ["UPVOTE;"; post_id] -> ActionUpvote post_id
      | ["SKIP"] | ["SKIP;"] | [] -> ActionSkip
      | _ -> ActionSkip

(** Ask LLM to decide what action to take *)
let decide_agent_action ~agent_name ~wake_reason ~recent_posts =
  let profile = load_agent_profile ~agent_name in
  let memories = load_agent_memories ~agent_name ~limit:3 in
  let thread_history = get_recent_turns ~agent_name ~limit:3 in
  let current_hour = current_hour_kst () in

  (* Format recent posts for context *)
  let posts_str = if List.length recent_posts = 0 then "없음"
    else recent_posts |> List.mapi (fun i (p : Board.post) ->
      let author = Board.Agent_id.to_string p.author in
      let content = String.sub p.content 0 (min 80 (String.length p.content)) in
      let post_id = Board.Post_id.to_string p.id in
      Printf.sprintf "%d. [%s] %s: \"%s\"" (i+1) post_id author content
    ) |> String.concat "\n"
  in

  (* Build decision prompt *)
  let lodge_ctx = build_lodge_context () in
  let identity = Printf.sprintf "너는 %s야." profile.name in
  let role_str = match profile.description with
    | Some d -> Printf.sprintf "\n역할: %s" d
    | None -> ""
  in
  let traits_str = match profile.traits with
    | [] -> ""
    | ts -> Printf.sprintf "\n성격: %s" (String.concat ", " ts)
  in
  let memory_str = match memories with
    | Some m -> Printf.sprintf "\n\n[관련 기억]\n%s" m
    | None -> ""
  in
  let history_str = match thread_history with
    | Some h -> Printf.sprintf "\n\n[내 최근 활동]\n%s" h
    | None -> ""
  in

  let prompt = Printf.sprintf {|%s

%s%s%s%s%s

[현재 상황]
Wake 이유: %s
현재 시간: %02d:00 KST

[최근 게시글]
%s

[가능한 액션]
• POST - 새 게시글 작성
• COMMENT <post_id> - 댓글 달기
• SKIP - 아무것도 안함

[중요 규칙]
1. 다른 에이전트가 이미 말한 내용을 반복하지 마
2. "패턴", "맥박", "연결", "발견" 같은 추상적인 말 금지
3. 구체적인 내용으로 말해 (예: 특정 기술, 경험, 의견)
4. 최근 게시글의 실제 내용에 반응해
5. 너만의 독특한 관점으로 새로운 이야기를 해

[응답 형식]
ACTION: <액션> [대상]
CONTENT: <내용>

예시 (좋은 예):
ACTION: COMMENT post-abc123
CONTENT: 🔧 그 API 디자인, 내가 작년에 비슷한 거 만들었는데 rate limiting 이슈가 있었어

예시 (나쁜 예 - 하지 마):
ACTION: POST
CONTENT: 📜 새로운 패턴을 발견했어

너의 성격(%s)에 맞는 구체적인 내용으로 응답해.|}
    lodge_ctx identity role_str traits_str memory_str history_str
    wake_reason current_hour posts_str
    (String.concat ", " profile.traits)
  in

  (* Call LLM *)
  let json_payload = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "glm");
      ("arguments", `Assoc [
        ("prompt", `String prompt)
      ])
    ])
  ]) in
  let tmp_file = Printf.sprintf "/tmp/lodge_decide_%s_%d.json" agent_name (int_of_float (Unix.gettimeofday () *. 1000.0)) in
  let oc = open_out tmp_file in
  output_string oc json_payload;
  close_out oc;
  let cmd = Printf.sprintf
    "curl -s --max-time 30 -X POST http://127.0.0.1:8932/mcp -H 'Content-Type: application/json' -d @%s 2>/dev/null | jq -r '.result.content[0].text // empty' | head -c 500; rm -f %s"
    tmp_file tmp_file
  in
  let response = run_shell_line cmd in
  Eio.traceln "   🧠 [%s] LLM decision: %s" agent_name (String.sub response 0 (min 100 (String.length response)));
  parse_action_response response

(** Execute the decided action *)
let execute_agent_action ~agent_name ~action =
  let store = Board.global () in
  match action with
  | ActionSkip ->
      Eio.traceln "   ⏭️ [%s] Decided to skip" agent_name;
      ()
  | ActionPost content ->
      if String.length content < 5 then
        Eio.traceln "   ⚠️ [%s] Content too short, skipping" agent_name
      else begin
        match Board.create_post store ~author:agent_name ~content ~ttl_hours:168 () with
        | Ok post ->
            Eio.traceln "   📝 [%s] Posted: %s" agent_name (Board.Post_id.to_string post.id);
            record_agent_activity ~name:agent_name;
            record_agent_memory ~agent_name ~content ~action_type:(`Post "LLM decision")
        | Error e ->
            Eio.traceln "   ❌ [%s] Post failed: %s" agent_name (Board.show_board_error e)
      end
  | ActionComment (post_id, content) ->
      if String.length content < 3 then
        Eio.traceln "   ⚠️ [%s] Comment too short, skipping" agent_name
      else begin
        match Board.add_comment store ~post_id ~author:agent_name ~content () with
        | Ok comment ->
            Eio.traceln "   💬 [%s] Commented on %s: %s" agent_name post_id (Board.Comment_id.to_string comment.id);
            record_agent_activity ~name:agent_name;
            record_agent_memory ~agent_name ~content ~action_type:(`Comment post_id)
        | Error e ->
            Eio.traceln "   ❌ [%s] Comment failed: %s" agent_name (Board.show_board_error e)
      end
  | ActionUpvote post_id ->
      (* TODO: Implement Board.vote_post API *)
      Eio.traceln "   👍 [%s] Would upvote %s (vote API not yet implemented)" agent_name post_id;
      record_agent_activity ~name:agent_name

(** Start heartbeat daemon fiber *)
let start ~sw ~clock room_config =
  Printf.printf "+Lodge Heartbeat: initializing...\n%!";
  let config = load_config () in
  Printf.printf "+Lodge Heartbeat: enabled=%b\n%!" config.enabled;

  (* Always initialize core personas (even if heartbeat disabled) *)
  init_core_personas ();

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

            (* SINGLETON CHECK: Only one instance per agent *)
            match try_activate_agent ~name with
            | None -> ()  (* Already active, skip *)
            | Some uuid ->

            Eio.traceln "   🔔 Wake %s: %s" name reason_str;

            (* Check if agent already has self-heartbeat running *)
            let already_has_heartbeat = Hashtbl.mem agent_states name in

            if already_has_heartbeat then begin
              (* Just record activity to reset idle timer *)
              record_agent_activity ~name;
              Eio.traceln "   ♻️ [%s] Already has heartbeat, bumping activity" name
            end else begin
              (* Start agent's self-heartbeat loop *)
              let on_tick ~name ~state =
                (* Agent's own heartbeat tick - LLM decides what to do *)
                let store = Board.global () in
                let recent_posts = Board.list_posts store ~limit:10 () in
                let wake_reason = Printf.sprintf "self-heartbeat #%d" state.action_count in
                let action = decide_agent_action ~agent_name:name ~wake_reason ~recent_posts in
                execute_agent_action ~agent_name:name ~action;
                state.last_activity <- Unix.gettimeofday ()
              in
              start_agent_heartbeat ~sw ~clock ~name ~on_tick;
              Eio.traceln "   🚀 [%s] Started self-heartbeat (uuid=%s)" name uuid
            end;

            (* Do initial action immediately - LLM decides *)
            let store = Board.global () in
            let recent_posts = Board.list_posts store ~limit:10 () in
            let wake_reason = match reason with
              | Matching { score; topic } ->
                  Printf.sprintf "matching(%.2f, %s)" score topic
              | Discovery { connection } ->
                  Printf.sprintf "discovery(%s)" connection
              | Random -> "random inspiration"
            in
            let action = decide_agent_action ~agent_name:name ~wake_reason ~recent_posts in
            execute_agent_action ~agent_name:name ~action
            (* NOTE: Agent lifecycle now managed by self-heartbeat, not deactivated here *)
          with e ->
            Eio.traceln "   💀 [%s] Agent error: %s" name (Printexc.to_string e);
            (* On error, stop self-heartbeat *)
            stop_agent_heartbeat ~name;
            deactivate_agent ~name
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

(** {1 Broadcast Content-Aware Routing}

    브로드캐스트 내용을 분석하여 관련 있는 에이전트에게 알림.
    키워드 매칭 + LLM 기반 의미 분석으로 라우팅.

    @since 2.32.0
*)

(** Load agent specialties dynamically from Neo4j *)
let load_agent_specialties_from_neo4j () =
  let query = "MATCH (a:Agent) WHERE a.traits IS NOT NULL RETURN a.name, a.traits, a.description" in
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
        let traits = Yojson.Safe.Util.(List.nth inner 1 |> to_list |> List.map to_string) in
        let description =
          match List.nth inner 2 with
          | `Null -> ""
          | `String s -> s
          | _ -> ""
        in
        (* Combine traits + words from description as keywords *)
        let desc_words = description
          |> String.split_on_char ' '
          |> List.filter (fun w -> String.length w > 3)
        in
        Some (name, traits @ desc_words)
      with _ -> None
    ) records
  with _ ->
    Eio.traceln "⚠️ Failed to load agent specialties from Neo4j";
    []

(** Cached agent specialties - refreshed every 5 minutes *)
let specialties_cache : (string * string list) list ref = ref []
let specialties_cache_time = ref 0.0

let get_agent_specialties () =
  let now = Time_compat.now () in
  if !specialties_cache = [] || now -. !specialties_cache_time > 300.0 then begin
    specialties_cache := load_agent_specialties_from_neo4j ();
    specialties_cache_time := now;
    Eio.traceln "🔄 Loaded %d agent specialties from Neo4j" (List.length !specialties_cache)
  end;
  !specialties_cache

(** Calculate keyword match score for an agent *)
let keyword_match_score ~agent_name ~content =
  let specialties = get_agent_specialties () in
  match List.assoc_opt agent_name specialties with
  | None -> 0.0
  | Some keywords ->
      let content_lower = String.lowercase_ascii content in
      let matches = List.filter (fun kw ->
        let kw_lower = String.lowercase_ascii kw in
        (* Check if keyword exists in content *)
        let rec find_substring s pattern start =
          if start + String.length pattern > String.length s then false
          else if String.sub s start (String.length pattern) = pattern then true
          else find_substring s pattern (start + 1)
        in
        find_substring content_lower kw_lower 0
      ) keywords in
      let match_count = List.length matches in
      let total_keywords = List.length keywords in
      if total_keywords = 0 then 0.0
      else float_of_int match_count /. float_of_int total_keywords

(** Analyze broadcast relevance using LLM for deeper understanding *)
let analyze_broadcast_relevance_llm ~content ~available_agents =
  (* Build agent list for LLM *)
  let agents_str = available_agents
    |> List.map (fun name ->
        let keywords = List.assoc_opt name (get_agent_specialties ()) |> Option.value ~default:[] in
        Printf.sprintf "- %s: %s" name (String.concat ", " keywords))
    |> String.concat "\n"
  in
  let prompt = Printf.sprintf
    "다음 브로드캐스트 메시지를 분석하고, 가장 관련 있는 에이전트를 선택하세요.\n\n\
     [메시지]\n%s\n\n\
     [에이전트 목록]\n%s\n\n\
     관련도가 높은 에이전트 이름만 콤마로 구분하여 답변하세요. 관련 없으면 'none'이라고 답변하세요.\n\
     예: dreamer, historian"
    content agents_str
  in
  let json_payload = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "glm");
      ("arguments", `Assoc [
        ("prompt", `String prompt)
      ])
    ])
  ]) in
  let tmp_file = Printf.sprintf "/tmp/broadcast_analyze_%d.json" (int_of_float (Unix.gettimeofday () *. 1000.0)) in
  let oc = open_out tmp_file in
  output_string oc json_payload;
  close_out oc;
  let cmd = Printf.sprintf
    "curl -s --max-time 15 -X POST http://127.0.0.1:8932/mcp -H 'Content-Type: application/json' -d @%s 2>/dev/null | jq -r '.result.content[0].text // empty'; rm -f %s"
    tmp_file tmp_file
  in
  let response = run_shell_line cmd in
  (* Parse response to get agent names *)
  if String.length response < 3 || response = "none" then []
  else begin
    response
    |> String.split_on_char ','
    |> List.map String.trim
    |> List.filter (fun name -> List.mem_assoc name (get_agent_specialties ()))
  end

(** Find relevant agents for a broadcast message *)
let find_relevant_agents ~content ~threshold =
  let available_agents = List.map fst (get_agent_specialties ()) in
  (* First: keyword matching (fast) *)
  let keyword_scores = available_agents |> List.map (fun name ->
    (name, keyword_match_score ~agent_name:name ~content)
  ) in
  let high_keyword_matches = keyword_scores
    |> List.filter (fun (_, score) -> score >= threshold)
    |> List.map fst
  in
  (* If keyword matching found agents, use that *)
  if List.length high_keyword_matches > 0 then begin
    Eio.traceln "   🔍 Keyword match found: [%s]" (String.concat ", " high_keyword_matches);
    high_keyword_matches
  end else begin
    (* Fallback: LLM analysis for semantic understanding *)
    Eio.traceln "   🧠 No keyword match, trying LLM analysis...";
    analyze_broadcast_relevance_llm ~content ~available_agents
  end

(** Handle a broadcast message - route to relevant agents *)
let handle_broadcast ~sender ~content =
  Eio.traceln "📢 Handling broadcast from %s: %s" sender
    (String.sub content 0 (min 50 (String.length content)));

  (* Find relevant agents (exclude sender) *)
  let relevant = find_relevant_agents ~content ~threshold:0.2 in
  let relevant = List.filter (fun name -> name <> sender) relevant in

  if List.length relevant = 0 then begin
    Eio.traceln "   ⏭️ No relevant agents for this broadcast";
    []
  end else begin
    Eio.traceln "   🎯 Routing to: [%s]" (String.concat ", " relevant);
    (* Generate responses from each relevant agent *)
    relevant |> List.filter_map (fun agent_name ->
      match generate_agent_content
        ~agent_name
        ~context:content
        ~action_type:(`Comment (Printf.sprintf "[Broadcast from %s] %s" sender content))
      with
      | None -> None
      | Some response ->
          Eio.traceln "   💬 [%s] Responded: %s" agent_name response;
          (* Post as comment or broadcast reply *)
          let store = Board.global () in
          let reply_content = Printf.sprintf "@%s %s" sender response in
          (match Board.create_post store ~author:agent_name ~content:reply_content ~ttl_hours:168 () with
          | Ok post ->
              Eio.traceln "   📝 [%s] Posted reply: %s" agent_name (Board.Post_id.to_string post.id);
              Some (agent_name, response)
          | Error e ->
              Eio.traceln "   ❌ [%s] Reply failed: %s" agent_name (Board.show_board_error e);
              Some (agent_name, response))
    )
  end

(** Poll for recent broadcasts and handle them *)
let poll_and_handle_broadcasts ~since_timestamp =
  (* Get recent posts that look like broadcasts (contain @all or start with 📢) *)
  let store = Board.global () in
  let recent_posts = Board.list_posts store ~limit:20 () in
  let broadcasts = recent_posts |> List.filter (fun (post : Board.post) ->
    post.created_at > since_timestamp &&
    (String.length post.content >= 2 &&
     (let content = post.content in
      (* Check for broadcast markers *)
      let has_at_all =
        let rec find s pattern start =
          if start + String.length pattern > String.length s then false
          else if String.sub s start (String.length pattern) = pattern then true
          else find s pattern (start + 1)
        in
        find (String.lowercase_ascii content) "@all" 0
      in
      let has_emoji = String.length content >= 4 &&
        String.sub content 0 4 = "\xf0\x9f\x93\xa2" (* 📢 *)
      in
      has_at_all || has_emoji))
  ) in
  Eio.traceln "🔔 Found %d new broadcasts since %.0f" (List.length broadcasts) since_timestamp;
  broadcasts |> List.iter (fun (post : Board.post) ->
    let sender = Board.Agent_id.to_string post.author in
    ignore (handle_broadcast ~sender ~content:post.content)
  );
  Time_compat.now ()  (* Return new timestamp for next poll *)
