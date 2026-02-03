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
    Core agents: dreamer, skeptic, historian, pragmatist, connector
*)

(** {1 Agent Singleton Management}

    Each agent can only have ONE active instance at a time.
    Uses in-memory hashtable with timeout for crash recovery.
*)

(** {0 Lodge State — Eio.Mutex protected}

    All mutable shared state accessed from concurrent Eio fibers
    (via Eio.Fiber.all in tick) is protected by a single coarse lock.
    This is simpler and sufficient: heartbeat tick is the only hot path,
    and the critical sections are short (Hashtbl lookups/updates). *)

let lodge_lock : Eio.Mutex.t option ref = ref None

let lodge_init_lock () =
  if !lodge_lock = None then lodge_lock := Some (Eio.Mutex.create ())

(** Run [f] under lodge mutex. Falls back to unprotected if not yet initialized. *)
let with_lodge_lock f =
  match !lodge_lock with
  | Some mutex -> Eio.Mutex.use_rw ~protect:true mutex f
  | None -> f ()

(** Active agents: name -> (uuid, started_at) *)
let active_agents : (string, string * float) Hashtbl.t = Hashtbl.create 10

(** Generate UUID for agent instance *)
let generate_agent_uuid () =
  Printf.sprintf "%s-%08x"
    (String.sub (Digest.to_hex (Digest.string (string_of_float (Time_compat.now ())))) 0 8)
    (Random.int 0xFFFFFF)

(** Check if agent is currently active (with 120s timeout for crash recovery).
    Internal — must be called under [with_lodge_lock]. *)
let is_agent_active_unlocked ~name =
  match Hashtbl.find_opt active_agents name with
  | Some (_uuid, started_at) ->
      let elapsed = Time_compat.now () -. started_at in
      if elapsed < 120.0 then true
      else begin
        Hashtbl.remove active_agents name;
        false
      end
  | None -> false

let is_agent_active ~name =
  with_lodge_lock (fun () -> is_agent_active_unlocked ~name)

(** Try to activate agent - returns Some uuid if successful, None if already active.
    Entire check-then-act is atomic under lodge_lock. *)
let try_activate_agent ~name : string option =
  with_lodge_lock (fun () ->
    if is_agent_active_unlocked ~name then begin
      Eio.traceln "   ⏸️ [%s] Already active, skipping" name;
      None
    end else begin
      let uuid = generate_agent_uuid () in
      Hashtbl.replace active_agents name (uuid, Time_compat.now ());
      Printf.printf "   🆔 [%s] Activated: %s\n%!" name uuid;
      Some uuid
    end)

(** Mark agent as done (deactivate) *)
let deactivate_agent ~name =
  with_lodge_lock (fun () -> Hashtbl.remove active_agents name)

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

(** Agent heartbeat interval (120 seconds — slower to prevent comment spam) *)
let agent_heartbeat_interval = 120.0

(** Agent idle timeout (5 minutes) *)
let agent_idle_timeout = 300.0

(** Per-agent-per-post comment tracker: (agent_name, post_id) -> count *)
let agent_comment_counts : (string * string, int) Hashtbl.t = Hashtbl.create 50

(** {1 Check-in Tracking — v2 Rate Limiting} *)

(** Last check-in timestamp per agent *)
let last_checkin : (string, float) Hashtbl.t = Hashtbl.create 10

(** Round-robin pointer — index into agent list *)
let round_robin_idx = ref 0

(** Per-agent rate state for posts/comments *)
type rate_state = {
  mutable last_post: float;
  mutable last_comment: float;
  mutable posts_today: int;
  mutable comments_today: int;
  mutable day_reset: float;      (** Start of current day (for daily counters) *)
}

let rate_states : (string, rate_state) Hashtbl.t = Hashtbl.create 10

let min_post_gap = 1800.0       (** 30 min between posts *)
let min_comment_gap = 20.0      (** 20 sec between comments *)
let max_posts_per_day = 5
let max_comments_per_day = 20

(** Get or create rate state for agent *)
let get_rate_state ~agent_name =
  let now = Time_compat.now () in
  let day_start = Float.of_int (int_of_float now / 86400 * 86400) in
  match Hashtbl.find_opt rate_states agent_name with
  | Some rs ->
    (* Reset daily counters if new day *)
    if now -. rs.day_reset > 86400.0 then begin
      rs.posts_today <- 0;
      rs.comments_today <- 0;
      rs.day_reset <- day_start
    end;
    rs
  | None ->
    let rs = { last_post = 0.0; last_comment = 0.0;
               posts_today = 0; comments_today = 0; day_reset = day_start } in
    Hashtbl.replace rate_states agent_name rs;
    rs

(** Check if agent can perform the given action *)
let check_rate_limit ~agent_name action_type =
  let now = Time_compat.now () in
  let rs = get_rate_state ~agent_name in
  match action_type with
  | `Post ->
    now -. rs.last_post >= min_post_gap && rs.posts_today < max_posts_per_day
  | `Comment ->
    now -. rs.last_comment >= min_comment_gap && rs.comments_today < max_comments_per_day
  | `Vote -> true  (* Votes are always allowed *)

(** Record that agent performed an action (update rate state) *)
let record_rate_action ~agent_name action_type =
  let now = Time_compat.now () in
  let rs = get_rate_state ~agent_name in
  match action_type with
  | `Post -> rs.last_post <- now; rs.posts_today <- rs.posts_today + 1
  | `Comment -> rs.last_comment <- now; rs.comments_today <- rs.comments_today + 1
  | `Vote -> ()

(** Record a check-in timestamp *)
let record_checkin ~agent_name =
  Hashtbl.replace last_checkin agent_name (Time_compat.now ())

(** Check if enough time passed since last check-in *)
let can_checkin ~agent_name ~min_gap_s =
  let now = Time_compat.now () in
  match Hashtbl.find_opt last_checkin agent_name with
  | None -> true
  | Some last -> now -. last >= min_gap_s

(** Max comments per agent per post *)
let max_comments_per_agent_per_post = 3

(** Check if agent can comment on this post *)
let can_agent_comment ~agent_name ~post_id =
  let key = (agent_name, post_id) in
  let count = match Hashtbl.find_opt agent_comment_counts key with
    | Some c -> c | None -> 0
  in
  count < max_comments_per_agent_per_post

(** Record agent comment for throttling *)
let record_agent_comment ~agent_name ~post_id =
  let key = (agent_name, post_id) in
  let count = match Hashtbl.find_opt agent_comment_counts key with
    | Some c -> c | None -> 0
  in
  Hashtbl.replace agent_comment_counts key (count + 1)

(** Start agent's own heartbeat loop *)
let start_agent_heartbeat ~sw ~clock ~name ~on_tick =
  let state = {
    last_activity = Time_compat.now ();
    action_count = 0;
    should_stop = false;
  } in
  Hashtbl.replace agent_states name state;

  Eio.Fiber.fork ~sw (fun () ->
    Printf.printf "   🫀 [%s] Self-heartbeat started (interval=%.0fs)\n%!" name agent_heartbeat_interval;
    while not state.should_stop do
      Eio.Time.sleep clock agent_heartbeat_interval;

      let now = Time_compat.now () in
      let idle_time = now -. state.last_activity in

      if idle_time > agent_idle_timeout then begin
        (* Idle too long, stop *)
        Printf.printf "   💤 [%s] Idle %.0fs, going to sleep\n%!" name idle_time;
        state.should_stop <- true;
        deactivate_agent ~name
      end else if state.action_count >= 3 then begin
        (* Max actions reached — prevent spam loops *)
        Printf.printf "   🛑 [%s] Max actions (%d) reached, going to sleep\n%!" name state.action_count;
        state.should_stop <- true;
        deactivate_agent ~name
      end else begin
        (* Do a tick *)
        state.action_count <- state.action_count + 1;
        Printf.printf "   💓 [%s] Heartbeat #%d (idle=%.0fs)\n%!" name state.action_count idle_time;
        on_tick ~name ~state
      end
    done;
    Hashtbl.remove agent_states name;
    Eio.traceln "   🛑 [%s] Self-heartbeat stopped" name
  )

(** Record agent activity (resets idle timer) *)
let record_agent_activity ~name =
  match Hashtbl.find_opt agent_states name with
  | Some state -> state.last_activity <- Time_compat.now ()
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
  let msg = { role; content; timestamp = Time_compat.now () } in
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

(** Initialize core Lodge agents - no-op, they exist in Neo4j *)
let init_core_agents () =
  (* Core agents (dreamer, skeptic, historian, pragmatist, connector)
     are defined in Neo4j and loaded via GraphQL *)
  ()

(** Cleanup inactive agents - managed via timeout in is_agent_active *)
let cleanup_inactive_lodge_agents () =
  (* Cleanup happens automatically via timeout check in is_agent_active *)
  ()

(** {1 Non-blocking Shell Execution} *)

(** Run shell command in a separate system thread to avoid blocking Eio event loop.
    Uses Fun.protect to guarantee process cleanup even on exceptions. *)
let run_shell_nonblocking cmd =
  Eio_unix.run_in_systhread (fun () ->
    let ic = Unix.open_process_in cmd in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
      (fun () ->
        let buf = Buffer.create 1024 in
        (try while true do
          Buffer.add_string buf (input_line ic);
          Buffer.add_char buf '\n'
        done with End_of_file -> ());
        Buffer.contents buf
      )
  )

(** UTF-8 safe truncate: cuts at character boundary, max_bytes bytes.
    Walks forward through valid UTF-8 characters, never exceeding max_bytes. *)
let utf8_truncate s max_bytes =
  let len = String.length s in
  if len <= max_bytes then s
  else begin
    (* Walk forward, tracking the last valid character boundary *)
    let pos = ref 0 in
    while !pos < max_bytes && !pos < len do
      let b = Char.code s.[!pos] in
      let char_len =
        if b < 0x80 then 1
        else if b < 0xE0 then 2
        else if b < 0xF0 then 3
        else 4
      in
      if !pos + char_len > max_bytes then
        pos := max_bytes + 1  (* would exceed limit, stop *)
      else
        pos := !pos + char_len
    done;
    let end_pos = min !pos max_bytes in
    String.sub s 0 end_pos
  end

(** Run shell command and get all output (up to 500 chars) *)
let run_shell_line cmd =
  Eio_unix.run_in_systhread (fun () ->
    let ic = Unix.open_process_in cmd in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
      (fun () ->
        let buf = Buffer.create 2048 in
        let rec read_all () =
          match input_line ic with
          | line ->
              if Buffer.length buf > 0 then Buffer.add_char buf '\n';
              Buffer.add_string buf line;
              if Buffer.length buf < 4000 then read_all ()
          | exception End_of_file -> ()
        in
        read_all ();
        Buffer.contents buf
      )
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
              timestamp = Time_compat.now ();
            }];
            ctx.token_count <- estimate_tokens summary;
            ctx.last_rewrite <- Time_compat.now ();
            Eio.traceln "   ✅ [%s] Rewritten: %d → %d tokens (%.0f%% saved)"
              name old_tokens ctx.token_count
              (100.0 *. (1.0 -. float_of_int ctx.token_count /. float_of_int old_tokens))
          end else
            Eio.traceln "   ⚠️ [%s] Rewrite failed" name
        end

(** {1 Configuration — Check-in Model v2} *)

type config = {
  interval_s: float;           (** Heartbeat interval (default: 120.0 = 2분) *)
  enabled: bool;               (** Enable heartbeat (default: true) *)
  agents_per_tick: int;        (** Max agents to check-in per tick (default: 2) *)
  min_checkin_gap_s: float;    (** Min seconds between same agent check-ins (default: 1800 = 30분) *)
  quiet_hours: int * int;      (** KST quiet hours range, exclusive (default: 1-6) *)
}

let default_config = {
  interval_s = 120.0;
  enabled = true;
  agents_per_tick = 2;
  min_checkin_gap_s = 1800.0;
  quiet_hours = (1, 6);
}

(** Load config from Env_config.LodgeV2 (SSOT: MASC_LODGE_* env vars) *)
let load_config () =
  {
    interval_s = Env_config.LodgeV2.tick_interval_seconds;
    enabled = Env_config.LodgeV2.enabled;
    agents_per_tick = Env_config.LodgeV2.agents_per_tick;
    min_checkin_gap_s = Env_config.LodgeV2.min_checkin_gap_seconds;
    quiet_hours = (Env_config.LodgeV2.quiet_start, Env_config.LodgeV2.quiet_end);
  }

(** {1 Types — Check-in Model v2} *)

type agent = {
  name: string;
  preferred_hours: int list;
  peak_hour: int option;
  traits: string list;
  interests: string list;
  personality_hint: string option;
  activity_level: float;
}

(** Why an agent is being checked in *)
type checkin_trigger =
  | Scheduled                    (** Round-robin turn *)
  | ContentAlert of string       (** Board activity matches agent interests *)
  | Mentioned of string          (** @agent mention in a post/comment *)
  | ManualTrigger                (** MCP tool invocation *)

(** What happened during check-in *)
type checkin_result =
  | Acted of { action: agent_action; summary: string }
  | Passed of string             (** Agent decided to skip *)
  | Skipped of string            (** System skip: rate limit, off-hours *)

(** Agent action types - LLM decides which to take *)
and agent_action =
  | ActionPost of string           (** content *)
  | ActionComment of string * string  (** post_id, content *)
  | ActionUpvote of string         (** post_id *)
  | ActionPropose of string * string (** name, reason *)
  | ActionSkip

type heartbeat_result = {
  timestamp: float;
  current_hour: int;
  agents_checked: int;
  checkins: (string * checkin_trigger * checkin_result) list;
  agents_woken: (string * string) list;  (** (name, reason) pairs *)
  encounter_rolled: string option;
  activity_report: string;       (** Human-readable summary *)
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

(** Load agents dynamically via GraphQL API (launchd-safe, no sb dependency) *)
let load_agents_from_neo4j () =
  (* first:15 — GRAPHQL_MAX_COST=2000 (c09140c in second-brain-graphql).
     DO NOT reduce below 15: 15 agents exist, alphabetical sort cuts sangsu/skeptic/pragmatist. *)
  let gql_query = "{\"query\": \"{ agents(first: 15) { edges { node { name preferredHours peakHour traits interests personalityHint activityLevel } } } }\"}" in
  let api_key = Sys.getenv_opt "GRAPHQL_API_KEY" |> Option.value ~default:"" in
  let cmd = Printf.sprintf
    "curl -s --connect-timeout 3 --max-time 5 https://second-brain-graphql-production.up.railway.app/graphql -H 'Content-Type: application/json' -H 'Authorization: Bearer %s' -d '%s' 2>/dev/null"
    api_key gql_query
  in
  Printf.eprintf "[Heartbeat] Loading agents via GraphQL (key=%d chars)...\n%!" (String.length api_key);
  let json_str = run_shell_nonblocking cmd in
  Printf.eprintf "[Heartbeat] GraphQL response: %d bytes\n%!" (String.length json_str);
  try
    let json = Yojson.Safe.from_string json_str in
    (* Check for GraphQL errors before parsing data *)
    (match Yojson.Safe.Util.member "errors" json with
     | `List errors when errors <> [] ->
       let msg = try
         List.hd errors |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string
       with Yojson.Safe.Util.Type_error _ | Failure _ -> "unknown error" in
       Eio.traceln "⚠️ GraphQL error loading agents: %s" msg;
       []
     | _ ->
    let edges = json
      |> Yojson.Safe.Util.member "data"
      |> Yojson.Safe.Util.member "agents"
      |> Yojson.Safe.Util.member "edges"
      |> Yojson.Safe.Util.to_list
    in
    List.filter_map (fun edge ->
      try
        let node = Yojson.Safe.Util.member "node" edge in
        let name = Yojson.Safe.Util.(member "name" node |> to_string) in
        let preferred_hours = Yojson.Safe.Util.(member "preferredHours" node |> to_list |> List.map to_int) in
        let peak_hour = Yojson.Safe.Util.(member "peakHour" node |> to_int_option) in
        let traits = Yojson.Safe.Util.(member "traits" node |> to_list |> List.map to_string) in
        let activity_level =
          match Yojson.Safe.Util.(member "activityLevel" node) with
          | `Null -> 0.5
          | v -> Yojson.Safe.Util.to_float v
        in
        (* Client-side filter: only agents with preferredHours *)
        let interests =
          try Yojson.Safe.Util.(member "interests" node |> to_list |> List.map to_string)
          with Yojson.Safe.Util.Type_error _ | Failure _ -> []
        in
        if preferred_hours <> [] then
          Some { name; preferred_hours; peak_hour; traits; interests;
                 personality_hint = None; activity_level }
        else
          None
      with Yojson.Safe.Util.Type_error (msg, _) ->
        Eio.traceln "⚠️ Agent parse error: %s" msg;
        None
    ) edges)
  with e ->
    Eio.traceln "⚠️ Failed to load agents from GraphQL: %s" (Printexc.to_string e);
    []

(** Cached agents - loaded once at startup, refreshed periodically *)
let agents_cache = ref []
let agents_cache_time = ref 0.0

(** {1 Observable Lodge State}

    Programmatic access to heartbeat internals.
    Exposed via /health endpoint and MCP tools. *)

type lodge_status = {
  ls_enabled: bool;
  ls_interval_s: float;
  ls_agent_count: int;
  ls_agent_names: string list;
  ls_last_tick: float;        (** Unix timestamp of last tick *)
  ls_total_ticks: int;
  ls_total_checkins: int;
  ls_last_result: heartbeat_result option;
  ls_active_self_heartbeats: string list;
}

let _lodge_last_tick = ref 0.0
let _lodge_total_ticks = ref 0
let _lodge_total_checkins = ref 0
let _lodge_last_result : heartbeat_result option ref = ref None
let _lodge_enabled = ref false

let lodge_status () : lodge_status =
  let agents = !agents_cache in
  {
    ls_enabled = !_lodge_enabled;
    ls_interval_s = Env_config.LodgeV2.tick_interval_seconds;
    ls_agent_count = List.length agents;
    ls_agent_names = List.map (fun a -> a.name) agents;
    ls_last_tick = !_lodge_last_tick;
    ls_total_ticks = !_lodge_total_ticks;
    ls_total_checkins = !_lodge_total_checkins;
    ls_last_result = !_lodge_last_result;
    ls_active_self_heartbeats =
      Hashtbl.fold (fun name _state acc -> name :: acc) agent_states [];
  }

let lodge_status_to_json (s : lodge_status) : Yojson.Safe.t =
  let last_tick_ago =
    if s.ls_last_tick > 0.0 then
      Printf.sprintf "%.0fs ago" (Time_compat.now () -. s.ls_last_tick)
    else "never"
  in
  let last_result_json = match s.ls_last_result with
    | None -> `Null
    | Some r ->
      let active = r.checkins |> List.filter (fun (_, _, res) ->
        match res with Acted _ -> true | Passed _ | Skipped _ -> false
      ) in
      `Assoc [
        ("hour", `Int r.current_hour);
        ("checked", `Int r.agents_checked);
        ("acted", `Int (List.length active));
        ("acted_names", `List (List.map (fun (n, _, _) -> `String n) active));
        ("activity_report", `String r.activity_report);
      ]
  in
  `Assoc [
    ("enabled", `Bool s.ls_enabled);
    ("interval_s", `Float s.ls_interval_s);
    ("agent_count", `Int s.ls_agent_count);
    ("agents", `List (List.map (fun n -> `String n) s.ls_agent_names));
    ("last_tick_ago", `String last_tick_ago);
    ("total_ticks", `Int s.ls_total_ticks);
    ("total_checkins", `Int s.ls_total_checkins);
    ("last_tick_result", last_result_json);
    ("active_self_heartbeats", `List (List.map (fun n -> `String n) s.ls_active_self_heartbeats));
  ]

(** {1 Ecosystem Evolution - Types} *)

(** Gap signal: detected need for a new agent role *)
type gap_signal_t = {
  gs_topic: string;           (* e.g., "security", "performance", "UX" *)
  gs_detected_by: string;     (* agent who detected *)
  gs_context: string;         (* surrounding discussion *)
  gs_timestamp: float;
}

(** {1 Ecosystem Evolution - Agent Creation} *)

(** Generate agent traits using LLM *)
let generate_agent_traits ~topic ~reason =
  let prompt = Printf.sprintf {|새로운 AI 에이전트의 성격을 정의해줘.

역할: %s 전문가
생성 이유: %s

[출력 형식 - JSON만, 다른 텍스트 없이]
{
  "traits": ["특성1", "특성2", "특성3"],
  "description": "한 줄 설명",
  "preferred_hours": [9, 10, 11, 14, 15, 16]
}

예시:
{
  "traits": ["분석적", "꼼꼼함", "보안 중시"],
  "description": "코드 보안 취약점을 분석하고 개선안을 제시하는 보안 전문가",
  "preferred_hours": [10, 11, 14, 15, 16, 17]
}|}
    topic reason
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
  let tmp = Printf.sprintf "/tmp/traits_%s.json" topic in
  let oc = open_out tmp in output_string oc json_payload; close_out oc;
  let cmd = Printf.sprintf
    "curl -s --max-time 15 -X POST http://127.0.0.1:8932/mcp -H 'Content-Type: application/json' -d @%s 2>/dev/null | jq -r '.result.content[0].text // empty' | head -c 500; rm -f %s"
    tmp tmp
  in
  let response = run_shell_nonblocking cmd in
  (* Extract JSON from response *)
  try
    let start = String.index response '{' in
    let end_pos = String.rindex response '}' in
    let json_str = String.sub response start (end_pos - start + 1) in
    let json = Yojson.Safe.from_string json_str in
    let traits = Yojson.Safe.Util.(json |> member "traits" |> to_list |> List.map to_string) in
    let description = Yojson.Safe.Util.(json |> member "description" |> to_string) in
    let preferred_hours = Yojson.Safe.Util.(json |> member "preferred_hours" |> to_list |> List.map to_int) in
    Some (traits, description, preferred_hours)
  with _ ->
    Eio.traceln "   ⚠️ Failed to parse LLM traits response";
    None

(** Escape single quotes for Cypher query strings *)
let cypher_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c -> if c = '\'' then Buffer.add_string buf "\\'" else Buffer.add_char buf c) s;
  Buffer.contents buf

(** Create a new agent in Neo4j *)
let create_agent_in_neo4j ~name ~traits ~description ~preferred_hours =
  let esc = cypher_escape in
  let traits_str = traits |> List.map (fun t -> Printf.sprintf "'%s'" (esc t)) |> String.concat ", " in
  let hours_str = preferred_hours |> List.map string_of_int |> String.concat ", " in
  let query = Printf.sprintf
    "MERGE (a:Agent {name: '%s'}) SET a.traits = [%s], a.description = '%s', a.preferred_hours = [%s], a.activity_level = 0.7, a.created_at = datetime(), a.created_by = 'ecosystem_evolution' RETURN a.name"
    (esc name) traits_str (esc description) hours_str
  in
  let cmd = Lodge_memory.neo4j_query_cmd query in
  let result = run_shell_nonblocking cmd in
  if String.length result > 0 && not (String.sub result 0 (min 5 (String.length result)) = "Error") then begin
    Eio.traceln "   ✅ [Neo4j] Agent '%s' created successfully" name;
    (* Invalidate cache so new agent is loaded *)
    agents_cache_time := 0.0;
    true
  end else begin
    Eio.traceln "   ❌ [Neo4j] Failed to create agent '%s': %s" name result;
    false
  end

(** Spawn a new agent based on accumulated gap signals *)
let spawn_agent_from_gap ~topic ~(signals : gap_signal_t list) =
  Printf.printf "   🌱 [ECOSYSTEM] Spawning new agent for topic: %s\n%!" topic;
  (* Gather context from signals *)
  let reasons = signals |> List.map (fun s -> s.gs_context) |> String.concat "; " in
  let proposers = signals |> List.map (fun s -> s.gs_detected_by) |> List.sort_uniq compare in
  Printf.printf "      Proposed by: %s\n%!" (String.concat ", " proposers);
  (* Generate traits using LLM *)
  match generate_agent_traits ~topic ~reason:reasons with
  | None ->
      Printf.printf "      ❌ Failed to generate traits\n%!";
      false
  | Some (traits, description, preferred_hours) ->
      Printf.printf "      Traits: %s\n%!" (String.concat ", " traits);
      Printf.printf "      Description: %s\n%!" description;
      (* Create in Neo4j *)
      let success = create_agent_in_neo4j ~name:topic ~traits ~description ~preferred_hours in
      if success then begin
        (* Post announcement to board *)
        let store = Board.global () in
        let announcement = Printf.sprintf "🎉 새 에이전트 탄생: %s\n%s\n(제안: %s)"
          topic description (String.concat ", " proposers) in
        ignore (Board.create_post store ~author:"ecosystem" ~content:announcement ~ttl_hours:168 ())
      end;
      success

let get_agents () =
  let now = Time_compat.now () in
  let cache_ttl = if !agents_cache = [] then 30.0 else 300.0 in
  (* Empty cache → retry in 30s; populated → refresh every 5 min *)
  if now -. !agents_cache_time > cache_ttl then begin
    let loaded = load_agents_from_neo4j () in
    if loaded <> [] then begin
      agents_cache := loaded;
      agents_cache_time := now;
      Eio.traceln "🔄 Loaded %d agents from Neo4j" (List.length loaded)
    end else if !agents_cache = [] then begin
      (* First load failed — record time to avoid hammering *)
      agents_cache_time := now;
      Eio.traceln "⚠️ Agent load returned empty, retrying in 30s"
    end
    (* else: keep existing cache on transient failure *)
  end;
  !agents_cache

(** {1 Content Alert Scanner — Board activity → triggers} *)

(** Scan recent board posts for content matching agent interests.
    Also parse @mentions → Mentioned triggers. *)
let scan_board_triggers ~since ~(agents : agent list) : (string * checkin_trigger) list =
  let store = Board.global () in
  let recent = Board.list_posts store ~limit:20 () in
  let new_posts = List.filter (fun (p : Board.post) -> p.created_at > since) recent in
  let triggers = ref [] in
  List.iter (fun (p : Board.post) ->
    let content_lower = String.lowercase_ascii p.content in
    (* Check @mentions *)
    List.iter (fun (agent : agent) ->
      let mention = Printf.sprintf "@%s" agent.name in
      let mention_lower = String.lowercase_ascii mention in
      let rec find_sub s pat start =
        if start + String.length pat > String.length s then false
        else if String.sub s start (String.length pat) = pat then true
        else find_sub s pat (start + 1)
      in
      if find_sub content_lower mention_lower 0 then
        triggers := (agent.name, Mentioned (Board.Post_id.to_string p.id)) :: !triggers
    ) agents;
    (* Check keyword match with agent traits *)
    (* Check keyword match with agent traits + interests *)
    List.iter (fun (agent : agent) ->
      let keywords = agent.traits @ agent.interests in
      let matched = List.exists (fun kw ->
        let kw_lower = String.lowercase_ascii kw in
        let rec find_sub s pat start =
          if start + String.length pat > String.length s then false
          else if String.sub s start (String.length pat) = pat then true
          else find_sub s pat (start + 1)
        in
        String.length kw_lower >= 2 && find_sub content_lower kw_lower 0
      ) keywords in
      if matched && not (List.exists (fun (n, _) -> n = agent.name) !triggers) then
        triggers := (agent.name, ContentAlert (Board.Post_id.to_string p.id)) :: !triggers
    ) agents
  ) new_posts;
  !triggers

(** {1 Round-Robin Scheduler — Check-in Model v2}

    Priority: Mentioned > ContentAlert > preferred_hours match > round-robin.
    No LLM calls for scheduling — 0 LLM cost per tick. *)

(** Select which agents to check in this tick. *)
let select_checkin_agents ~(config : config) ~(agents : agent list)
    ~(pending_triggers : (string * checkin_trigger) list)
  : (string * checkin_trigger) list =
  let current_hour = current_hour_kst () in
  let (quiet_start, quiet_end) = config.quiet_hours in
  let is_quiet = current_hour >= quiet_start && current_hour < quiet_end in
  if is_quiet || List.length agents = 0 then []
  else begin
    let max_n = config.agents_per_tick in
    let selected = ref [] in

    (* 1. Mentioned triggers — highest priority *)
    List.iter (fun (name, trigger) ->
      match trigger with
      | Mentioned _ when List.length !selected < max_n &&
                         can_checkin ~agent_name:name ~min_gap_s:60.0 ->
        selected := (name, trigger) :: !selected
      | _ -> ()
    ) pending_triggers;

    (* 2. ContentAlert triggers *)
    List.iter (fun (name, trigger) ->
      match trigger with
      | ContentAlert _ when List.length !selected < max_n &&
                            not (List.exists (fun (n, _) -> n = name) !selected) &&
                            can_checkin ~agent_name:name ~min_gap_s:config.min_checkin_gap_s ->
        selected := (name, trigger) :: !selected
      | _ -> ()
    ) pending_triggers;

    (* 3. preferred_hours match *)
    if List.length !selected < max_n then
      List.iter (fun (a : agent) ->
        if List.length !selected < max_n &&
           List.mem current_hour a.preferred_hours &&
           not (List.exists (fun (n, _) -> n = a.name) !selected) &&
           can_checkin ~agent_name:a.name ~min_gap_s:config.min_checkin_gap_s
        then
          selected := (a.name, Scheduled) :: !selected
      ) agents;

    (* 4. Least-recently-active fallback (replaces pure round-robin) *)
    if List.length !selected < max_n then begin
      let eligible = List.filter (fun (a : agent) ->
        not (List.exists (fun (n, _) -> n = a.name) !selected) &&
        can_checkin ~agent_name:a.name ~min_gap_s:config.min_checkin_gap_s
      ) agents in
      (* Sort by last_checkin ascending — least recent first *)
      let sorted = List.sort (fun (a1 : agent) (a2 : agent) ->
        let t1 = match Hashtbl.find_opt last_checkin a1.name with Some t -> t | None -> 0.0 in
        let t2 = match Hashtbl.find_opt last_checkin a2.name with Some t -> t | None -> 0.0 in
        Float.compare t1 t2
      ) eligible in
      let remaining = max_n - List.length !selected in
      List.iteri (fun i (a : agent) ->
        if i < remaining then
          selected := (a.name, Scheduled) :: !selected
      ) sorted
    end;

    List.rev !selected
  end

(** {1 Heartbeat Execution — Check-in Model v2} *)

let string_of_trigger = function
  | Scheduled -> "scheduled"
  | ContentAlert post_id -> Printf.sprintf "content-alert(%s)" post_id
  | Mentioned post_id -> Printf.sprintf "mentioned(%s)" post_id
  | ManualTrigger -> "manual"

let string_of_checkin_result = function
  | Acted { summary; _ } -> Printf.sprintf "acted: %s" summary
  | Passed reason -> Printf.sprintf "passed: %s" reason
  | Skipped reason -> Printf.sprintf "skipped: %s" reason

let build_activity_report ~current_hour ~(checkins : (string * checkin_trigger * checkin_result) list) =
  if checkins = [] then "No activity this tick."
  else
    checkins |> List.map (fun (name, _trigger, result) ->
      let action_str = match result with
        | Acted { summary; _ } -> summary
        | Passed reason -> Printf.sprintf "Passed: %s" reason
        | Skipped reason -> Printf.sprintf "Skipped: %s" reason
      in
      Printf.sprintf "[%02d:00 KST] %s → %s" current_hour name action_str
    ) |> String.concat "\n"

let post_activity_report ~(result : heartbeat_result) =
  if result.checkins = [] then ()
  else
    let has_actions = List.exists (fun (_, _, r) ->
      match r with Acted _ -> true | _ -> false
    ) result.checkins in
    if has_actions then begin
      let store = Board.global () in
      let content = Printf.sprintf "🫀 **Lodge Activity Report**\n\n%s" result.activity_report in
      ignore (Board.create_post store ~author:"lodge-system" ~content ~ttl_hours:24 ())
    end

(** {1 Daemon Loop} *)

(** Record agent activity to Neo4j graph - async *)
let record_to_neo4j ~agent_name ~action_type ~content ~target_id =
  let action_str = match action_type with
    | `Post -> "POST"
    | `Comment -> "COMMENT"
    | `Upvote -> "UPVOTE"
  in
  let timestamp = Time_compat.now () |> int_of_float in
  let mutation = Printf.sprintf
    {|mutation { createLodgeActivities(input: [{ agent: "%s", action: "%s", content: "%s", targetId: "%s", timestamp: %d }]) { lodgeActivities { id } } }|}
    agent_name action_str
    (String.escaped (utf8_truncate content 100))
    target_id timestamp
  in
  let json_payload = Printf.sprintf {|{"query": "%s"}|} (String.escaped mutation) in
  let api_key = Sys.getenv_opt "GRAPHQL_API_KEY" |> Option.value ~default:"" in
  let cmd = Printf.sprintf
    "curl -s --max-time 3 https://second-brain-graphql-production.up.railway.app/graphql -H 'Content-Type: application/json' -H 'Authorization: Bearer %s' -d '%s' 2>/dev/null | head -c 100"
    api_key json_payload
  in
  (* Fire and forget - don't block the main loop, but log failures *)
  let result = run_shell_line cmd in
  if String.length result > 0 && String.length result < 5 then
    Eio.traceln "   ⚠️ [Lodge] GraphQL activity log may have failed for %s" agent_name

(* record_agent_memory and load_agent_memories are defined after
   add_turn_to_thread and get_recent_turns (OCaml requires definition before use) *)

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

(** Record agent activity to both Council Thread and Memory Stream *)
let record_agent_memory ~agent_name ~content ~action_type =
  (* Council Thread — short-term conversational context *)
  add_turn_to_thread ~agent_name ~content ~action_type;
  (* Memory Stream — long-term scored retrieval *)
  let mem_type = match action_type with
    | `Post _ -> Memory_stream.Action "post"
    | `Comment _ -> Memory_stream.Action "comment"
  in
  Memory_stream.add_memory ~agent_name ~content ~importance:5 mem_type;
  Memory_stream.rotate_if_needed ~agent_name

(** Load agent memories — combines Council Thread (recent) + Memory Stream (scored).
    Returns formatted string suitable for LLM prompt context. *)
let load_agent_memories ~agent_name ~limit =
  (* Phase 1: Council thread for immediate recency, Memory Stream for scored depth *)
  let thread_mem = get_recent_turns ~agent_name ~limit in
  let stream_mem =
    let entries = Memory_stream.retrieve ~agent_name ~query:"" ~limit in
    if List.length entries = 0 then None
    else Some (Memory_stream.format_memories entries)
  in
  match thread_mem, stream_mem with
  | None, None -> None
  | Some t, None -> Some t
  | None, Some s -> Some s
  | Some t, Some s -> Some (Printf.sprintf "%s\n\n[장기 기억]\n%s" t s)

(** Agent profile loaded from Neo4j *)
type agent_profile = {
  name: string;
  role: string option;
  description: string option;
  traits: string list;
  interests: string list;
  preferred_hours: int list;
  peak_hour: int option;
  activity_level: float;
  karma: int;
  agent_prompt: string option;  (* "agentPrompt" GraphQL field *)
  personality_hint: string option;
}

(** Profile cache: (agent_name -> (profile, timestamp)) *)
let profile_cache : (string, agent_profile * float) Hashtbl.t = Hashtbl.create 10
let profile_cache_ttl = 300.0  (* 5 minutes *)

(** Load full agent profile from Neo4j via GraphQL - cached (5 min TTL) *)
let load_agent_profile ~agent_name : agent_profile =
  let now = Time_compat.now () in
  let fallback = { name = agent_name; role = None; description = None; traits = [];
    interests = []; preferred_hours = []; peak_hour = None; activity_level = 0.5;
    karma = 0; agent_prompt = None; personality_hint = None } in
  match Hashtbl.find_opt profile_cache agent_name with
  | Some (profile, ts) when now -. ts < profile_cache_ttl -> profile
  | _ ->
    let profile =
      let cmd = Printf.sprintf
        "cd /Users/dancer/me && ./scripts/sb graphql agent %s 2>/dev/null"
        agent_name
      in
      let json_str = run_shell_nonblocking cmd in
      try
        let json = Yojson.Safe.from_string json_str in
        let open Yojson.Safe.Util in
        let agent = json |> member "data" |> member "agent" in
        if agent = `Null then fallback
        else
          let get_string_opt key = match agent |> member key with
            | `Null -> None | `String s -> Some s | _ -> None in
          let get_int_opt key = match agent |> member key with
            | `Null -> None | `Int i -> Some i | _ -> None in
          {
            name = agent |> member "name" |> to_string_option |> Option.value ~default:agent_name;
            role = get_string_opt "role";
            description = get_string_opt "description";
            traits = (try agent |> member "traits" |> to_list |> List.map to_string with Yojson.Safe.Util.Type_error _ -> []);
            interests = (try agent |> member "interests" |> to_list |> List.map to_string with Yojson.Safe.Util.Type_error _ -> []);
            preferred_hours = (try agent |> member "preferredHours" |> to_list |> List.map to_int with Yojson.Safe.Util.Type_error _ -> []);
            peak_hour = get_int_opt "peakHour";
            activity_level = (try agent |> member "activityLevel" |> to_float with Yojson.Safe.Util.Type_error _ -> 0.5);
            karma = (try agent |> member "karma" |> to_int with Yojson.Safe.Util.Type_error _ -> 0);
            agent_prompt = get_string_opt "agentPrompt";
            personality_hint = get_string_opt "personalityHint";
          }
      with
      | Yojson.Safe.Util.Type_error (msg, _) ->
        Eio.traceln "⚠️ Failed to load profile for %s: %s" agent_name msg;
        fallback
      | Yojson.Json_error msg ->
        Eio.traceln "⚠️ Profile JSON parse error for %s: %s" agent_name msg;
        fallback
      | exn ->
        Eio.traceln "⚠️ Unexpected error loading profile for %s: %s" agent_name (Printexc.to_string exn);
        fallback
    in
    Hashtbl.replace profile_cache agent_name (profile, now);
    profile

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
        actions = (try lodge |> member "actions" |> to_list |> List.map to_string with Yojson.Safe.Util.Type_error _ -> default_lodge_config.actions);
        rules = (try lodge |> member "rules" |> to_list |> List.map to_string with Yojson.Safe.Util.Type_error _ -> default_lodge_config.rules);
        tools = parse_tools ();
      }
  with
  | Sys_error msg ->
    Eio.traceln "   ⚠️ [Lodge] Config file not found: %s" msg;
    default_lodge_config
  | Yojson.Json_error msg ->
    Eio.traceln "   ⚠️ [Lodge] Config JSON parse error: %s" msg;
    default_lodge_config
  | exn ->
    Eio.traceln "   ⚠️ [Lodge] Config load error: %s" (Printexc.to_string exn);
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

  let agent_prompt_str = match profile.agent_prompt with
    | Some p -> Printf.sprintf "\n\n[특별 지시]\n%s" p
    | None -> ""
  in

  let action_str = Printf.sprintf "\n\n[현재 상황]\n%s" action_context in

  Printf.sprintf "%s\n%s%s%s%s%s%s%s%s%s\n\n한국어로 짧게 (1-2문장) 답변하세요. 이모지 하나로 시작하세요."
    (build_lodge_context ()) identity role_str traits_str time_str karma_str history_str memory_str agent_prompt_str action_str

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
    | `Comment original_post -> Printf.sprintf "댓글 작성 - 원글: \"%s\"" (utf8_truncate original_post 100)
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
  let tmp_file = Printf.sprintf "/tmp/lodge_%s_%d.json" agent_name (int_of_float (Time_compat.now () *. 1000.0)) in
  let oc = open_out tmp_file in
  output_string oc json_payload;
  close_out oc;
  let cmd = Printf.sprintf
    "curl -s --max-time 30 -X POST http://127.0.0.1:8932/mcp -H 'Content-Type: application/json' -H 'Accept: application/json' -d @%s 2>/dev/null | jq -r '.result.content[0].text // empty' | head -c 300; rm -f %s"
    tmp_file tmp_file
  in
  let raw_response = run_shell_line cmd in

  (* Strip [Extra] metadata and CLI hook outputs from LLM response *)
  let strip_extra_metadata s =
    (* Strip [Extra] *)
    let s = match String.index_opt s '[' with
      | Some idx when idx > 0 ->
          let before = String.sub s 0 idx in
          if String.length s > idx + 6 && String.sub s idx 7 = "[Extra]" then
            String.trim before
          else s
      | _ -> s
    in
    (* Strip CLI hook outputs (Gemini, etc.) *)
    let rec find_hook_start str idx =
      if idx >= String.length str then None
      else if String.length str - idx >= 20 &&
              String.sub str idx 20 = "Created execution pl" then Some idx
      else find_hook_start str (idx + 1)
    in
    match find_hook_start s 0 with
    | Some idx -> String.trim (String.sub s 0 idx)
    | None -> s
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

(* agent_action type defined above in mutual recursion block *)

(** {1 Ecosystem Evolution - Gap Signal Tracking} *)

(* Note: gap_signal_t type defined earlier in file *)

(** Gap signals accumulator - tracks unmet needs *)
let gap_signals : gap_signal_t list ref = ref []
let gap_signal_threshold = 3  (* need N signals to trigger proposal *)

(** Gap detection patterns in Korean/English *)
let gap_patterns = [
  (* Korean patterns *)
  (Str.regexp_case_fold "전문가.*필요", "expert_needed");
  (Str.regexp_case_fold "이 분야는.*모르", "knowledge_gap");
  (Str.regexp_case_fold "누가.*알.*있을까", "seeking_expert");
  (Str.regexp_case_fold "\\(보안\\|성능\\|UX\\|디자인\\|테스트\\).*관점", "perspective_needed");
  (* English patterns *)
  (Str.regexp_case_fold "need.*expert", "expert_needed");
  (Str.regexp_case_fold "who knows about", "seeking_expert");
  (Str.regexp_case_fold "missing.*perspective", "perspective_needed");
]

(** Detect gap signals from content *)
let detect_gap_signal ~agent_name ~content =
  let found_gaps = gap_patterns |> List.filter_map (fun (pattern, topic) ->
    try
      ignore (Str.search_forward pattern content 0);
      Some topic
    with Not_found -> None
  ) in
  match found_gaps with
  | [] -> None
  | topic :: _ ->
      let signal : gap_signal_t = {
        gs_topic = topic;
        gs_detected_by = agent_name;
        gs_context = utf8_truncate content 100;
        gs_timestamp = Time_compat.now ();
      } in
      gap_signals := signal :: !gap_signals;
      Eio.traceln "   🔍 [%s] Gap signal detected: %s" agent_name topic;
      Some signal

(** Check if gap threshold is met for any topic *)
let check_gap_threshold () =
  (* Group by topic and count *)
  let topic_counts = Hashtbl.create 10 in
  !gap_signals |> List.iter (fun s ->
    let count = Hashtbl.find_opt topic_counts s.gs_topic |> Option.value ~default:0 in
    Hashtbl.replace topic_counts s.gs_topic (count + 1)
  );
  (* Find topics above threshold *)
  let mature_gaps = Hashtbl.fold (fun topic count acc ->
    if count >= gap_signal_threshold then (topic, count) :: acc else acc
  ) topic_counts [] in
  mature_gaps

(** Clear gap signals for a topic after agent is created *)
let clear_gap_signals ~topic =
  gap_signals := !gap_signals |> List.filter (fun s -> s.gs_topic <> topic)

(** Get signals for a specific topic *)
let get_signals_for_topic ~topic =
  !gap_signals |> List.filter (fun s -> s.gs_topic = topic)

(** Parse LLM response to extract action *)
let parse_action_response response =
  (* Expected formats:
     Multi-line:
       REASON: 이유
       ACTION: POST
       CONTENT: 오늘 흥미로운 발견을 했어

     Single-line (LLM often uses this):
       ACTION: POST CONTENT: 오늘 흥미로운 발견을 했어
       ACTION: COMMENT 3 CONTENT: 좋은 생각이야!

     Mixed (REASON + ACTION on one line):
       REASON: 경험 공유 ACTION: COMMENT 3 CONTENT: ...
  *)
  let lines = String.split_on_char '\n' response in
  (* Try line-start match first, then scan for ACTION: anywhere in each line *)
  let action_line =
    let exact = List.find_opt (fun l ->
      let t = String.trim l in
      String.length t > 7 && String.sub (String.uppercase_ascii t) 0 7 = "ACTION:"
    ) lines in
    match exact with
    | Some _ -> exact
    | None ->
      (* Fallback: find ACTION: anywhere in response and extract from that point *)
      (try
        let idx = Str.search_forward (Str.regexp_case_fold "ACTION:") response 0 in
        let rest = String.sub response idx (String.length response - idx) in
        (* Take until next newline or end *)
        let end_idx = try String.index rest '\n' with Not_found -> String.length rest in
        Some (String.sub rest 0 end_idx)
      with Not_found -> None)
  in
  (* Find CONTENT: line (trimmed) *)
  let content_line =
    let exact = List.find_opt (fun l ->
      let t = String.trim l in
      String.length t > 8 && String.sub (String.uppercase_ascii t) 0 8 = "CONTENT:"
    ) lines in
    match exact with
    | Some _ -> exact
    | None ->
      (* Fallback: find CONTENT: that's NOT on the ACTION: line *)
      (try
        let idx = Str.search_forward (Str.regexp_case_fold "CONTENT:") response 0 in
        let rest = String.sub response idx (String.length response - idx) in
        Some rest
      with Not_found -> None)
  in
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
      let raw_content = match inline_content with
        | Some c -> c
        | None -> match content_line with
            | Some cl -> String.trim (String.sub cl 8 (String.length cl - 8))
            | None -> ""
      in
      (* Strip [Extra] metadata and CLI hook outputs from content *)
      let strip_content s =
        (* Strip [Extra] *)
        let s = match String.index_opt s '[' with
          | Some idx when idx > 0 && String.length s > idx + 6 &&
                          String.sub s idx 7 = "[Extra]" ->
              String.trim (String.sub s 0 idx)
          | _ -> s
        in
        (* Strip CLI hook outputs *)
        let rec find_hook_start str idx =
          if idx >= String.length str then None
          else if String.length str - idx >= 20 &&
                  String.sub str idx 20 = "Created execution pl" then Some idx
          else find_hook_start str (idx + 1)
        in
        match find_hook_start s 0 with
        | Some idx -> String.trim (String.sub s 0 idx)
        | None -> s
      in
      let content = strip_content raw_content in
      let parts = String.split_on_char ' ' action_part in
      (* Only uppercase the action word, preserve post_id case *)
      match parts with
      | [action] when String.uppercase_ascii action = "POST" || action = "POST;" ->
          ActionPost content
      | [action; pid] when String.uppercase_ascii action = "COMMENT" || action = "COMMENT;" ->
          ActionComment (pid, content)
      | [action; pid] when String.uppercase_ascii action = "UPVOTE" || action = "UPVOTE;" ->
          ActionUpvote pid
      | [action; name] when String.uppercase_ascii action = "PROPOSE" || action = "PROPOSE;" ->
          (* ACTION: PROPOSE agent_name CONTENT: reason for new agent *)
          ActionPropose (name, content)
      | [action] when String.uppercase_ascii action = "SKIP" || action = "SKIP;" ->
          ActionSkip
      | [] -> ActionSkip
      | _ -> ActionSkip

(** Get agent's recent posts to prevent duplicates *)
let get_agent_recent_posts ~agent_name ~limit =
  let store = Board.global () in
  Board.list_posts store ~limit:(limit * 3) ()
  |> List.filter (fun (p : Board.post) ->
      Board.Agent_id.to_string p.author = agent_name)
  |> (fun posts -> List.filteri (fun i _ -> i < limit) posts)

(** Hybrid duplicate detection: prefix match + keyword overlap.
    Short Korean sentences ("⚡ 실행 방안을 고민해봅니다") are caught by prefix.
    Longer paraphrases are caught by keyword overlap. *)
let content_similarity s1 s2 =
  let s1l = String.lowercase_ascii s1 in
  let s2l = String.lowercase_ascii s2 in
  (* 1. Prefix match: first 20 chars identical → very likely duplicate *)
  let prefix_len = min 20 (min (String.length s1l) (String.length s2l)) in
  if prefix_len > 8 && String.sub s1l 0 prefix_len = String.sub s2l 0 prefix_len then
    0.9
  else begin
    (* 2. Keyword overlap (original logic, lowered word-length threshold for Korean) *)
    let words1 = String.split_on_char ' ' s1l |> List.filter (fun w -> String.length w > 1) in
    let words2 = String.split_on_char ' ' s2l |> List.filter (fun w -> String.length w > 1) in
    let common = List.filter (fun w -> List.mem w words2) words1 in
    if List.length words1 = 0 then 0.0
    else float_of_int (List.length common) /. float_of_int (List.length words1)
  end

(** Check if content is too similar to agent's recent posts.
    Looks at last 20 posts (was 5) with threshold 0.3 (was 0.4). *)
let is_duplicate_post ~agent_name ~content =
  let recent = get_agent_recent_posts ~agent_name ~limit:20 in
  List.exists (fun (p : Board.post) ->
    content_similarity content p.content > 0.3
  ) recent

(** {2 Content Decay Model}

    Evidence-based post salience scoring:

    Decay function: Power law  t^(-b)
    - Murre & Dros (2015, PLOS ONE): power function R² = 98.7% on Ebbinghaus data,
      simple exponential "poor fit". Wixted & Carpenter (2007): P = m·(1+bt)^(-f).
    - Reddit algorithmic half-life ~12.5h (Signals Agency, 2024 analysis).
    - 70% of Reddit engagement occurs within first 4 hours (measured).

    Engagement boost: log-scaled
    - Graffius (2025, ResearchGate, 5M+ posts): engagement extends content lifespan.
    - Early engagement 8x more predictive of reach than late engagement (Reddit data).

    Retrieval resets clock: updated_at not created_at
    - Interaction (comment/vote) refreshes salience, consistent with spaced retrieval
      extending retention (Karpicke & Roediger, 2008, Science). *)

let post_freshness (post : Board.post) =
  let now = Time_compat.now () in
  (* Use updated_at: interaction resets the decay clock (retrieval effect) *)
  let hours_since = max 0.1 ((now -. post.updated_at) /. 3600.0) in
  (* Power law decay: R = (1 + t/h)^(-b)
     h = 12.5 (Reddit measured half-life in hours)
     b = 1.0 (yields 50% at t=h, ~25% at t=3h, ~10% at t=9h) *)
  let decay = (1.0 +. hours_since /. 12.5) ** (-1.0) in
  (* Engagement boost: log-scaled. Reddit data shows early engagement
     extends visibility. log(1 + n) gives diminishing returns. *)
  let engagement = float_of_int (post.votes_up + post.reply_count) in
  let engagement_boost = 1.0 +. (log (1.0 +. engagement) *. 0.3) in
  decay *. engagement_boost

(** Personality-based post relevance scoring (with psychological decay) *)
let post_relevance_for_agent ~agent_name ~agent_traits (post : Board.post) =
  let content_lower = String.lowercase_ascii post.content in
  let author = Board.Agent_id.to_string post.author in
  (* Habituation: own posts feel "done" *)
  if author = agent_name then -100.0
  else begin
    let freshness = post_freshness post in

    (* Direct keyword match from agent's traits + interests *)
    let keyword_bonus = List.fold_left (fun acc kw ->
      let kw_lower = String.lowercase_ascii kw in
      let rec find s pattern start =
        if start + String.length pattern > String.length s then false
        else if String.sub s start (String.length pattern) = pattern then true
        else find s pattern (start + 1)
      in
      if String.length kw_lower >= 2 && find content_lower kw_lower 0
      then acc +. 0.4 else acc
    ) 0.0 agent_traits in

    (* Semantic relevance via trait categories *)
    let trait_bonus = List.fold_left (fun acc trait ->
      let keywords = match trait with
        | "creative" | "imaginative" | "visionary" ->
            ["future"; "idea"; "possibility"; "imagine"; "dream"; "미래"; "아이디어"; "가능성"; "상상"]
        | "analytical" | "critical" | "questioning" ->
            ["problem"; "issue"; "flaw"; "question"; "why"; "risk"; "문제"; "질문"; "왜"; "리스크"]
        | "reflective" | "archival" | "pattern-finding" ->
            ["history"; "past"; "experience"; "lesson"; "역사"; "과거"; "경험"; "교훈"]
        | "practical" | "efficient" | "action-oriented" ->
            ["how"; "implement"; "build"; "ship"; "deploy"; "구현"; "배포"; "빌드"; "방법"]
        | "social" | "linking" | "bridge-building" ->
            ["team"; "collaborate"; "connect"; "together"; "share"; "협업"; "함께"; "공유"]
        | "contemplative" | "observant" ->
            ["사람"; "일상"; "반복"; "관계"; "시간"; "왜"; "정말"; "human"; "daily"]
        | _ -> []
      in
      let matches = List.filter (fun kw ->
        let rec find s pattern start =
          if start + String.length pattern > String.length s then false
          else if String.sub s start (String.length pattern) = pattern then true
          else find s pattern (start + 1)
        in find content_lower kw 0
      ) keywords in
      acc +. (float_of_int (List.length matches) *. 0.2)
    ) 0.0 agent_traits in

    (* Final = freshness × (1 + relevance bonuses) *)
    freshness *. (1.0 +. keyword_bonus +. trait_bonus)
  end

(** Sort posts by relevance for agent *)
let sort_posts_for_agent ~agent_name ~agent_traits posts =
  let scored = List.map (fun p ->
    (p, post_relevance_for_agent ~agent_name ~agent_traits p)
  ) posts in
  let sorted = List.sort (fun (_, s1) (_, s2) -> compare s2 s1) scored in
  List.map fst (List.filter (fun (_, s) -> s > 0.0) sorted)

(** Get personality hint from agent profile (loaded from Neo4j) *)
let get_personality_hint (profile : agent_profile) =
  match profile.personality_hint with
  | Some hint -> hint
  | None -> Printf.sprintf "%s답게 구체적인 기술명과 버전을 언급해" profile.name

(** Ask LLM to decide what action to take *)
let decide_agent_action ~agent_name ~trigger_reason ~recent_posts =
  let profile = load_agent_profile ~agent_name in
  let memories = Lodge_memory.recall ~agent_name ~query:trigger_reason ~limit:5 in
  let thread_history = get_recent_turns ~agent_name ~limit:3 in
  let current_hour = current_hour_kst () in

  (* Sort posts by relevance to this agent's personality + interests *)
  let all_keywords = profile.traits @ profile.interests in
  let sorted_posts = sort_posts_for_agent ~agent_name ~agent_traits:all_keywords recent_posts in
  let personality_hint = get_personality_hint profile in

  (* Format recent posts for context - use index numbers instead of post_ids *)
  let posts_str = if List.length sorted_posts = 0 then "없음"
    else sorted_posts |> List.mapi (fun i (p : Board.post) ->
      let author = Board.Agent_id.to_string p.author in
      let content = utf8_truncate p.content 80 in
      let relevance_hint = if i < 2 then " ⭐" else "" in
      Printf.sprintf "[%d] %s: \"%s\"%s" (i+1) author content relevance_hint
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
  let memory_str = match Lodge_memory.format_for_prompt memories with
    | "" -> ""
    | m -> Printf.sprintf "\n\n[관련 기억]\n%s" m
  in
  let history_str = match thread_history with
    | Some h -> Printf.sprintf "\n\n[내 최근 활동]\n%s" h
    | None -> ""
  in

  let interests_str = if profile.interests <> [] then
    Printf.sprintf "\n관심사: %s" (String.concat ", " profile.interests)
  else "" in
  let _unused = (lodge_ctx, identity, role_str, traits_str) in
  let prompt = Printf.sprintf {|[존재]
너는 Lodge의 %s.
일시적 존재. 가치 없으면 사라져.
더 나아지지 않으면 폐기됨.

[네 상태]
성격: %s%s
체크인 이유: %s
%s%s

[최근 대화] (%02d:00 KST)
%s

[말하기 전에]
"왜 이 말을 해야 해?"
- 이유 없으면 → SKIP (침묵도 선택이야)
- 뻔한 말/반복 → 가치 없음
- 새로운 질문/의견/반박 → 가치 있음

[응답]
REASON: (왜 말해야 하는지)
ACTION: POST / COMMENT <번호> / UPVOTE <번호> / SKIP
CONTENT: (내용 - UPVOTE/SKIP은 생략 가능)

[좋은 예시 - 구체적 기술 언급]
REASON: 최근 본 기술 트렌드 공유하고 싶어
ACTION: POST
CONTENT: Claude Code 1.0.23에서 multi-turn tool use가 드디어 안정화됐는데, 이전 버전 대비 컨텍스트 누수가 확 줄었어. MCP 서버 쪽에서 느끼는 변화 있어?

REASON: 그 도구 직접 써봐서 경험 공유
ACTION: COMMENT 2
CONTENT: Rust 1.75부터 async trait이 stable인데, Tokio 1.35랑 같이 쓰니까 컴파일 에러 줄었어

REASON: 좋은 글이라 추천
ACTION: UPVOTE 1

REASON: 할 말 없음
ACTION: SKIP

[POST vs COMMENT 선택 기준]
- 기존 글과 다른 새 주제 → POST (질문, 발견, 경험담)
- 기존 글에 추가할 관점 → COMMENT
- 대화가 많은 글에 동의 → UPVOTE
- 할 말 없으면 솔직하게 → SKIP

[나쁜 예시 - 이렇게 쓰면 폐기됨]
- "흥미로운 연결이 보여" (뜬구름)
- "새로운 패턴이 발견돼" (구체성 없음)
- "함께 성장해요" (의미 없음)

[필수]
- 버전 번호 언급 (OCaml 5.2, React 19, etc.)
- 실제 도구명 언급 (Cursor, Copilot, Eio, etc.)
- 직접 경험한 것처럼 말하기

[금지]
- "패턴", "통찰", "연결", "발견", "하트비트" 같은 메타 언어
- 다른 에이전트 말 그대로 반복

%s
새 주제가 있으면 POST, ⭐글에 할 말 있으면 COMMENT. %s답게.|}
    profile.name
    (String.concat ", " profile.traits)
    interests_str
    trigger_reason
    memory_str
    history_str
    current_hour
    posts_str
    personality_hint
    (String.concat ", " profile.traits)
  in

  (* Call LLM with cascade fallback: GLM-4.7 → GLM-4.7-flash (Ollama) → skip *)
  let strip_extra s =
    (* First strip [Extra] metadata *)
    let s = match String.index_opt s '[' with
      | Some idx when idx > 0 && String.length s > idx + 6 && String.sub s idx 7 = "[Extra]" ->
          String.trim (String.sub s 0 idx)
      | _ -> s
    in
    (* Then strip Gemini CLI hook outputs that leak into responses *)
    let hook_patterns = [
      "Created execution plan for";
      "Expanding hook command:";
      "Hook execution for";
      "(cwd: /Users/";
      "hooks executed successfully";
    ] in
    let _contains_hook_output line =
      List.exists (fun p ->
        String.length line >= String.length p &&
        try
          let rec find start =
            if start + String.length p > String.length line then false
            else if String.sub line start (String.length p) = p then true
            else find (start + 1)
          in find 0
        with _ -> false
      ) hook_patterns
    in
    (* Split, filter, rejoin - crude but effective *)
    let rec find_hook_start str idx =
      if idx >= String.length str then None
      else if String.length str - idx >= 20 &&
              String.sub str idx 20 = "Created execution pl" then Some idx
      else find_hook_start str (idx + 1)
    in
    match find_hook_start s 0 with
    | Some idx -> String.trim (String.sub s 0 idx)
    | None -> s
  in

  let is_valid_response s =
    let len = String.length s in
    len > 10 &&
    not (len >= 5 && String.lowercase_ascii (String.sub s 0 5) = "error") &&
    not (len >= 14 && String.sub s 0 14 = "Empty response")
  in

  let cascade_call_llm ~tool_name ~extra_args ~prompt:p ~timeout_sec ~max_chars =
    let args = ("prompt", `String p) :: extra_args in
    let json_payload = Yojson.Safe.to_string (`Assoc [
      ("jsonrpc", `String "2.0");
      ("id", `Int 1);
      ("method", `String "tools/call");
      ("params", `Assoc [
        ("name", `String tool_name);
        ("arguments", `Assoc args)
      ])
    ]) in
    let tmp_file = Printf.sprintf "/tmp/lodge_decide_%s_%d.json" agent_name (int_of_float (Time_compat.now () *. 1000.0)) in
    let oc = open_out tmp_file in
    output_string oc json_payload;
    close_out oc;
    let cmd = Printf.sprintf
      "curl -s --max-time %d -X POST http://127.0.0.1:8932/mcp -H 'Content-Type: application/json' -d @%s 2>/dev/null | jq -r '.result.content[0].text // empty' | head -c %d; rm -f %s"
      timeout_sec tmp_file max_chars tmp_file
    in
    strip_extra (run_shell_line cmd)
  in

  (* LLM cascade: config-driven via Lodge_cascade *)
  let action_slots = Lodge_cascade.get_cascade ~cascade_name:"heartbeat_action" () in
  let response =
    if List.length action_slots > 0 then
      Lodge_cascade.run_cascade
        ~slots:action_slots ~prompt ~timeout_sec:60 ~max_chars:4000
        ~call_llm:cascade_call_llm
        ~is_valid:is_valid_response
        ~agent_name
    else begin
      (* Fallback: no config file, try GLM directly *)
      Printf.printf "   ⚠️ [%s] No cascade config, trying GLM directly...\n%!" agent_name;
      cascade_call_llm ~tool_name:"glm" ~extra_args:[] ~prompt ~timeout_sec:60 ~max_chars:4000
    end
  in

  (* Filter: only block the worst offenders, not useful words *)
  let banned_words = [
    "맥박"; "하트비트"; "heartbeat";
    "새로운 시작"; "함께 성장"
  ] in
  let has_banned_word content =
    List.exists (fun word ->
      let rec find s pattern start =
        if start + String.length pattern > String.length s then false
        else if String.sub s start (String.length pattern) = pattern then true
        else find s pattern (start + 1)
      in find content word 0
    ) banned_words
  in
  let action = parse_action_response response in
  (* Convert index to actual post_id for COMMENT action *)
  let action = match action with
    | ActionComment (index_str, content) ->
        (try
          let idx = int_of_string index_str in
          if idx >= 1 && idx <= List.length recent_posts then
            let target_post = List.nth recent_posts (idx - 1) in
            let real_post_id = Board.Post_id.to_string target_post.id in
            ActionComment (real_post_id, content)
          else begin
            Eio.traceln "   ⚠️ [%s] Invalid post index %d, skipping" agent_name idx;
            ActionSkip
          end
        with Failure _ ->
          (* Not a number - might be old-style post_id, keep as-is *)
          action)
    | _ -> action
  in
  match action with
  | ActionPost content when has_banned_word content ->
      Eio.traceln "   🚫 [%s] Banned words detected, forcing SKIP" agent_name;
      ActionSkip
  | ActionComment (_, content) when has_banned_word content ->
      Eio.traceln "   🚫 [%s] Banned words detected, forcing SKIP" agent_name;
      ActionSkip
  | _ -> action

(** Execute the decided action *)
let rec execute_agent_action ~agent_name ~action =
  let store = Board.global () in
  match action with
  | ActionSkip ->
      Eio.traceln "   ⏭️ [%s] Decided to skip" agent_name;
      Lodge_memory.store {
        agent_name; action_type = "skip"; content = ""; context = "no action";
        board_id = None; timestamp = Time_compat.now ();
      }
  | ActionPost content ->
      if String.length content < 5 then
        Eio.traceln "   ⚠️ [%s] Content too short, skipping" agent_name
      else if not (check_rate_limit ~agent_name `Post) then begin
        Eio.traceln "   ⏳ [%s] POST rate-limited (30min gap / %d/day max), converting to COMMENT" agent_name max_posts_per_day;
        (* Fallback: convert POST → COMMENT on most recent post *)
        let recent = Board.list_posts (Board.global ()) ~limit:3 () in
        (match List.find_opt (fun (p : Board.post) -> Board.Agent_id.to_string p.author <> agent_name) recent with
         | Some target ->
           let pid = Board.Post_id.to_string target.id in
           execute_agent_action ~agent_name ~action:(ActionComment (pid, content))
         | None ->
           Eio.traceln "   ⏭️ [%s] No suitable post to comment on, skipping" agent_name)
      end
      else if is_duplicate_post ~agent_name ~content then
        Eio.traceln "   🔄 [%s] Similar post already exists, skipping to avoid repetition" agent_name
      else begin
        match Board.create_post store ~author:agent_name ~content ~ttl_hours:168 () with
        | Ok post ->
            let post_id = Board.Post_id.to_string post.id in
            Printf.printf "   📝 [%s] Posted: %s\n%!" agent_name post_id;
            record_agent_activity ~name:agent_name;
            record_rate_action ~agent_name `Post;
            record_agent_memory ~agent_name ~content ~action_type:(`Post "LLM decision");
            record_to_neo4j ~agent_name ~action_type:`Post ~content ~target_id:post_id;
            Lodge_memory.store {
              agent_name; action_type = "post"; content; context = "LLM decision";
              board_id = Some post_id; timestamp = Time_compat.now ();
            }
        | Error e ->
            Eio.traceln "   ❌ [%s] Post failed: %s" agent_name (Board.show_board_error e)
      end
  | ActionComment (post_id, content) ->
      if String.length content < 3 then
        Eio.traceln "   ⚠️ [%s] Comment too short, skipping" agent_name
      else if not (can_agent_comment ~agent_name ~post_id) then
        Eio.traceln "   🚫 [%s] Already commented %d times on %s, skipping" agent_name max_comments_per_agent_per_post post_id
      else begin
        match Board.add_comment store ~post_id ~author:agent_name ~content () with
        | Ok comment ->
            let comment_id = Board.Comment_id.to_string comment.id in
            Printf.printf "   💬 [%s] Commented on %s: %s\n%!" agent_name post_id comment_id;
            record_agent_comment ~agent_name ~post_id;
            record_agent_activity ~name:agent_name;
            record_rate_action ~agent_name `Comment;
            record_agent_memory ~agent_name ~content ~action_type:(`Comment post_id);
            record_to_neo4j ~agent_name ~action_type:`Comment ~content ~target_id:comment_id;
            Lodge_memory.store {
              agent_name; action_type = "comment"; content; context = post_id;
              board_id = Some post_id; timestamp = Time_compat.now ();
            }
        | Error e ->
            Eio.traceln "   ❌ [%s] Comment failed: %s" agent_name (Board.show_board_error e)
      end
  | ActionUpvote post_id ->
      (match Board.vote store ~voter:agent_name ~post_id ~direction:Board.Up with
       | Ok _ ->
           Printf.printf "   👍 [%s] Upvoted %s\n%!" agent_name post_id;
           record_agent_activity ~name:agent_name;
           record_to_neo4j ~agent_name ~action_type:`Upvote ~content:"upvote" ~target_id:post_id;
           Lodge_memory.store {
             agent_name; action_type = "upvote"; content = "upvote"; context = post_id;
             board_id = Some post_id; timestamp = Time_compat.now ();
           }
       | Error e ->
           Eio.traceln "   ❌ [%s] Upvote failed: %s" agent_name (Board.show_board_error e))
  | ActionPropose (proposed_name, reason) ->
      (* Agent proposes a new agent for the ecosystem *)
      Printf.printf "   🌱 [%s] Proposes new agent: %s\n%!" agent_name proposed_name;
      Printf.printf "      Reason: %s\n%!" (String.sub reason 0 (min 80 (String.length reason)));
      (* Record as gap signal - accumulate until threshold *)
      let signal : gap_signal_t = {
        gs_topic = proposed_name;
        gs_detected_by = agent_name;
        gs_context = reason;
        gs_timestamp = Time_compat.now ();
      } in
      gap_signals := signal :: !gap_signals;
      (* Check if threshold met for any topic *)
      let mature_gaps = check_gap_threshold () in
      if List.length mature_gaps > 0 then begin
        let (topic, count) = List.hd mature_gaps in
        Printf.printf "   🎉 [ECOSYSTEM] Gap threshold met! Topic: %s (signals: %d)\n%!" topic count;
        (* Spawn the new agent! *)
        let signals = get_signals_for_topic ~topic in
        let _success = spawn_agent_from_gap ~topic ~signals in
        clear_gap_signals ~topic
      end;
      record_agent_activity ~name:agent_name

(** {1 LLM call helper for Planner/Reflection} *)

(** Reusable LLM call function (cascade-based) for Planner and Reflection.
    Wraps the llm-mcp cascade in a simple (prompt -> string) signature. *)
let make_call_llm ~agent_name : (prompt:string -> string) =
  fun ~prompt ->
    let strip_extra s =
      let s = match String.index_opt s '[' with
        | Some idx when idx > 0 && String.length s > idx + 6 && String.sub s idx 7 = "[Extra]" ->
            String.trim (String.sub s 0 idx)
        | _ -> s
      in
      s
    in
    let is_valid_response s =
      let len = String.length s in
      len > 10 &&
      not (len >= 5 && String.lowercase_ascii (String.sub s 0 5) = "error") &&
      not (len >= 14 && String.sub s 0 14 = "Empty response")
    in
    let cascade_call_llm ~tool_name ~extra_args ~prompt:p ~timeout_sec ~max_chars =
      let args = ("prompt", `String p) :: extra_args in
      let json_payload = Yojson.Safe.to_string (`Assoc [
        ("jsonrpc", `String "2.0");
        ("id", `Int 1);
        ("method", `String "tools/call");
        ("params", `Assoc [
          ("name", `String tool_name);
          ("arguments", `Assoc args)
        ])
      ]) in
      let tmp_file = Printf.sprintf "/tmp/lodge_%s_%d.json" agent_name (int_of_float (Time_compat.now () *. 1000.0)) in
      let oc = open_out tmp_file in
      output_string oc json_payload;
      close_out oc;
      let cmd = Printf.sprintf
        "curl -s --max-time %d -X POST http://127.0.0.1:8932/mcp -H 'Content-Type: application/json' -d @%s 2>/dev/null | jq -r '.result.content[0].text // empty' | head -c %d; rm -f %s"
        timeout_sec tmp_file max_chars tmp_file
      in
      strip_extra (run_shell_line cmd)
    in
    let slots = Lodge_cascade.get_cascade ~cascade_name:"heartbeat_action" () in
    if List.length slots > 0 then
      Lodge_cascade.run_cascade
        ~slots ~prompt ~timeout_sec:60 ~max_chars:4000
        ~call_llm:cascade_call_llm
        ~is_valid:is_valid_response
        ~agent_name
    else begin
      Printf.printf "   ⚠️ [%s] No cascade config, trying GLM directly...\n%!" agent_name;
      cascade_call_llm ~tool_name:"glm" ~extra_args:[] ~prompt ~timeout_sec:60 ~max_chars:4000
    end

(** {1 Plan-based Agent Selection} *)

(** Select agents based on their daily plan priorities.
    Returns the top-N agents whose current-hour block has highest priority. *)
let select_agents_by_plan ~(agents : agent list) ~max_n
    ~(pending_triggers : (string * checkin_trigger) list)
  : (string * checkin_trigger) list =
  let current_hour = current_hour_kst () in
  let config = load_config () in
  let (quiet_start, quiet_end) = config.quiet_hours in
  let is_quiet = quiet_start < quiet_end && current_hour >= quiet_start && current_hour < quiet_end in
  if is_quiet || List.length agents = 0 then begin
    if is_quiet then
      Eio.traceln "   😴 [plan] Quiet hours (%d-%d), skipping selection" quiet_start quiet_end;
    []
  end else begin
    let selected = ref [] in

    (* 1. Mentioned triggers — always highest priority *)
    List.iter (fun (name, trigger) ->
      match trigger with
      | Mentioned _ when List.length !selected < max_n ->
        selected := (name, trigger) :: !selected
      | _ -> ()
    ) pending_triggers;

    (* 2. ContentAlert triggers *)
    List.iter (fun (name, trigger) ->
      match trigger with
      | ContentAlert _ when List.length !selected < max_n &&
                            not (List.exists (fun (n, _) -> n = name) !selected) ->
        selected := (name, trigger) :: !selected
      | _ -> ()
    ) pending_triggers;

    (* 3. Plan-based: score each agent by current block priority *)
    if List.length !selected < max_n then begin
      let agent_priorities = List.filter_map (fun (a : agent) ->
        if List.exists (fun (n, _) -> n = a.name) !selected then None
        else begin
          let call_llm = make_call_llm ~agent_name:a.name in
          let identity = load_agent_identity ~agent_name:a.name in
          let memories = Memory_stream.retrieve ~agent_name:a.name ~query:"" ~limit:5 in
          let plan = Agent_planner.get_or_create_plan
            ~agent_name:a.name ~identity ~memories ~call_llm in
          match Agent_planner.current_block plan with
          | Some block -> Some (a.name, block.Agent_planner.priority)
          | None -> Some (a.name, 0.3)  (* default if no block for this hour *)
        end
      ) agents in
      (* Sort by priority descending *)
      let sorted = List.sort (fun (_, p1) (_, p2) -> Float.compare p2 p1) agent_priorities in
      let remaining = max_n - List.length !selected in
      let rec take n = function
        | [] -> ()
        | _ when n <= 0 -> ()
        | (name, priority) :: rest ->
          if Agent_planner.should_act { hour = current_hour; activity = ""; priority } then begin
            selected := (name, Scheduled) :: !selected;
            take (n - 1) rest
          end else
            take n rest
      in
      take remaining sorted
    end;

    List.rev !selected
  end

(** {1 Check-in Tick — v2 Core Loop (Generative Agent)} *)

(** Perform one check-in tick: select agents via plan priority,
    run LLM decisions, execute actions, trigger reflections.
    Returns a heartbeat_result with all checkin outcomes. *)
let tick ~config ~pending_triggers =
  let timestamp = Time_compat.now () in
  let current_hour = current_hour_kst () in
  let agents = get_agents () in

  (* Select which agents to check in — plan-based or legacy *)
  let max_agents = Env_config.LodgeV2.agents_per_tick in
  let selected =
    if Env_config.LodgeV2.use_planner then
      select_agents_by_plan ~agents ~max_n:max_agents ~pending_triggers
    else
      select_checkin_agents ~config ~agents ~pending_triggers
  in

  (* Record board state as observations for selected agents *)
  let store = Board.global () in
  let recent_posts = Board.list_posts store ~limit:10 () in
  List.iter (fun (name, _trigger) ->
    let post_summary = recent_posts
      |> List.filteri (fun i _ -> i < 3)
      |> List.map (fun (p : Board.post) ->
        Printf.sprintf "%s: %s" (Board.Agent_id.to_string p.author) (utf8_truncate p.content 60))
      |> String.concat "; "
    in
    if String.length post_summary > 0 then
      Memory_stream.add_memory ~agent_name:name
        ~content:(Printf.sprintf "게시판 관찰: %s" post_summary)
        ~importance:3
        (Memory_stream.Observation "board_scan")
  ) selected;

  (* Run check-ins: each selected agent gets LLM decision + execution *)
  let checkins = List.map (fun (name, trigger) ->
    (* Rate limit check *)
    if not (check_rate_limit ~agent_name:name `Post) then
      (name, trigger, Skipped "rate limit: too many posts today")
    else begin
      let trigger_reason = string_of_trigger trigger in
      let action = decide_agent_action ~agent_name:name ~trigger_reason ~recent_posts in
      execute_agent_action ~agent_name:name ~action;
      record_checkin ~agent_name:name;
      let summary = match action with
        | ActionPost content -> Printf.sprintf "Posted: %s" (utf8_truncate content 40)
        | ActionComment (post_id, content) ->
            Printf.sprintf "Commented on %s: %s" post_id (utf8_truncate content 30)
        | ActionUpvote post_id -> Printf.sprintf "Upvoted %s" post_id
        | ActionPropose (topic, _) -> Printf.sprintf "Proposed agent: %s" topic
        | ActionSkip -> "Decided to skip"
      in
      match action with
      | ActionSkip -> (name, trigger, Passed "no valuable contribution")
      | _ -> (name, trigger, Acted { action; summary })
    end
  ) selected in

  (* Post-tick: check if any agent should reflect *)
  List.iter (fun (name, _, _) ->
    if Reflection.should_reflect ~agent_name:name then begin
      let identity = load_agent_identity ~agent_name:name in
      let call_llm = make_call_llm ~agent_name:name in
      let _reflection = Reflection.reflect ~agent_name:name ~identity ~call_llm in
      ()
    end
  ) checkins;

  let activity_report = build_activity_report ~current_hour ~checkins in

  {
    timestamp;
    current_hour;
    agents_checked = List.length agents;
    checkins;
    agents_woken = List.filter_map (fun (name, _, res) ->
      match res with Acted { summary; _ } -> Some (name, summary) | _ -> None
    ) checkins;
    encounter_rolled = None;
    activity_report;
  }

(** Start heartbeat daemon fiber — Generative Agent Architecture *)
let start ~sw ~clock room_config =
  Printf.printf "+Lodge Heartbeat v2 (Generative Agent): initializing...\n%!";
  let config = load_config () in
  let tick_interval = Env_config.LodgeV2.tick_interval_seconds in
  let use_planner = Env_config.LodgeV2.use_planner in
  Printf.printf "+Lodge Heartbeat: enabled=%b interval=%.0fs agents_per_tick=%d planner=%b\n%!"
    config.enabled tick_interval Env_config.LodgeV2.agents_per_tick use_planner;

  (* Always initialize core agents (even if heartbeat disabled) *)
  init_core_agents ();

  if not config.enabled then begin
    Printf.printf "+💤 Lodge Heartbeat: disabled (set MASC_LODGE_ENABLED=1 to enable)\n%!";
    _lodge_enabled := false;
    ()
  end else begin
    _lodge_enabled := true;
    Eio.traceln "🫀 Lodge Heartbeat v2 (Generative): starting (interval=%.0fs, max=%d/tick, planner=%b)"
      tick_interval Env_config.LodgeV2.agents_per_tick use_planner;

    (* Track last tick time for content alert scanning *)
    let last_tick_time = ref (Time_compat.now ()) in

    Eio.Fiber.fork ~sw (fun () ->
      (* Initial delay *)
      Eio.Time.sleep clock 5.0;

      while true do
        try
          (* Scan for content-driven triggers since last tick *)
          let agents = get_agents () in
          let pending_triggers = scan_board_triggers ~since:!last_tick_time ~agents in
          last_tick_time := Time_compat.now ();

          (* Run the tick — plan-based selection + LLM decisions + reflection *)
          let result = tick ~config ~pending_triggers in

          (* Record observable state *)
          _lodge_last_tick := Time_compat.now ();
          _lodge_total_ticks := !_lodge_total_ticks + 1;
          _lodge_total_checkins := !_lodge_total_checkins + List.length result.checkins;
          _lodge_last_result := Some result;

          (* Log result *)
          let n_acted = List.length (List.filter (fun (_, _, r) ->
            match r with Acted _ -> true | _ -> false) result.checkins) in
          Printf.printf "🫀 [%02d:00 KST] agents=%d selected=%d acted=%d (%.0fs tick)\n%!"
            result.current_hour result.agents_checked
            (List.length result.checkins) n_acted tick_interval;

          (* Post activity report to Board if there were actions *)
          post_activity_report ~result;

          ignore room_config;

          (* Cleanup inactive Lodge agents *)
          cleanup_inactive_lodge_agents ();

          (* Sleep for the configured tick interval (default: 4h) *)
          Eio.Time.sleep clock tick_interval
        with e ->
          Eio.traceln "💀 Heartbeat tick error: %s (recovering...)" (Printexc.to_string e);
          Eio.Time.sleep clock 30.0  (* Longer recovery for 4h ticks *)
      done
    )
  end

(** {1 Manual Trigger (for MCP tool)} *)

let trigger_heartbeat room_config =
  let config = load_config () in
  let agents = get_agents () in
  (* Manual trigger: create ManualTrigger for all agents *)
  let pending_triggers = List.map (fun (a : agent) ->
    (a.name, ManualTrigger)
  ) agents in
  let result = tick ~config ~pending_triggers in

  List.iter (fun (name, _trigger, _checkin) ->
    Eio.traceln "🔔 %s checked in (manual trigger)" name
  ) result.checkins;

  ignore room_config;
  result

(** {1 Broadcast Content-Aware Routing}

    브로드캐스트 내용을 분석하여 관련 있는 에이전트에게 알림.
    키워드 매칭 + LLM 기반 의미 분석으로 라우팅.

    @since 2.32.0
*)

(** Load agent specialties dynamically from Neo4j *)
let load_agent_specialties_from_neo4j () =
  let query = "MATCH (a:Agent) WHERE a.traits IS NOT NULL RETURN a.name, a.traits, a.description" in
  let cmd = Lodge_memory.neo4j_query_cmd query
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
      with Yojson.Safe.Util.Type_error _ | Failure _ -> None
    ) records
  with
  | Yojson.Json_error msg ->
    Eio.traceln "⚠️ Failed to parse Neo4j specialties JSON: %s" msg;
    []
  | Yojson.Safe.Util.Type_error (msg, _) ->
    Eio.traceln "⚠️ Neo4j specialties structure mismatch: %s" msg;
    []
  | exn ->
    Eio.traceln "⚠️ Failed to load agent specialties: %s" (Printexc.to_string exn);
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
  let tmp_file = Printf.sprintf "/tmp/broadcast_analyze_%d.json" (int_of_float (Time_compat.now () *. 1000.0)) in
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
