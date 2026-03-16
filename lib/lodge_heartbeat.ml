(** Lodge Heartbeat — Reaction-first social loop

    Mainline responsibilities:
    - planner/thompson 기반 selection
    - reaction/signature 기반 social decision
    - reflection 결과를 self-summary로 승격

    @since 2.14.0
*)

[@@@warning "-32-69"]

(** {1 Lodge Agent Status (GraphQL/cache based)}

    Agent roster is loaded through the heartbeat GraphQL path and cached locally.
    Core agents remain dreamer, skeptic, historian, pragmatist, connector.
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

(** Crash recovery timeout: 360s (3x the heartbeat interval of 120s).
    Previous value (120s = 1x interval) caused race conditions where agents
    were removed between heartbeat ticks. 3x provides adequate margin. *)
let agent_crash_timeout = 360.0

(** Check if agent is currently active (with crash recovery timeout).
    Internal — must be called under [with_lodge_lock]. *)
let is_agent_active_unlocked ~name =
  match Hashtbl.find_opt active_agents name with
  | Some (_uuid, last_seen) ->
      let elapsed = Time_compat.now () -. last_seen in
      if elapsed < agent_crash_timeout then true
      else begin
        Printf.eprintf "[lodge] Agent '%s' timed out after %.0fs (crash recovery)\n%!" name elapsed;
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

(** Refresh agent heartbeat timestamp — prevents crash-recovery timeout
    while agent is actively ticking. *)
let refresh_agent_heartbeat ~name =
  with_lodge_lock (fun () ->
    match Hashtbl.find_opt active_agents name with
    | Some (uuid, _old_ts) ->
        Hashtbl.replace active_agents name (uuid, Time_compat.now ())
    | None -> ())

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

(** Rate limiting — delegated to Lodge_rate_limit module.
    @since 4.1.0 *)

(** Convenience aliases for backward compatibility within this file *)
let check_rate_limit = Lodge_rate_limit.check_rate_limit
let record_rate_action = Lodge_rate_limit.record_rate_action
let record_checkin = Lodge_rate_limit.record_checkin
let can_checkin = Lodge_rate_limit.can_checkin
let can_agent_comment = Lodge_rate_limit.can_agent_comment
let record_agent_comment = Lodge_rate_limit.record_agent_comment
let min_post_gap = Lodge_rate_limit.min_post_gap
let min_comment_gap = Lodge_rate_limit.min_comment_gap
let max_posts_per_day = Lodge_rate_limit.max_posts_per_day
let max_comments_per_day = Lodge_rate_limit.max_comments_per_day
let max_comments_per_agent_per_post = Lodge_rate_limit.max_comments_per_agent_per_post

(** Agent Trace — delegated to Lodge_trace module.
    @since 4.1.0 *)

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
        (* Refresh crash-recovery timestamp before tick *)
        refresh_agent_heartbeat ~name;
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

(** Forward reference for rewrite_context (defined later) *)
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
  | Types.Busy ->
      (try ignore (try_activate_agent ~name)
       with exn -> Printf.eprintf "[lodge] try_activate_agent(%s) failed: %s\n%!" name (Printexc.to_string exn))
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

(** {1 External CLI helpers (argv-based, no shell)} *)

let sb_path () =
  match Env_config.sb_path_opt () with
  | Some path -> path
  | None -> "./scripts/sb"

(** GraphQL transport is delegated to Graphql_client module.
    Only heartbeat-specific response parsers are kept here.
    @since 2.91.0 — Replaced inline Cohttp+curl transport with Graphql_client. *)
let graphql_request = Graphql_client.request

let graphql_error_message json =
  match Yojson.Safe.Util.member "errors" json with
  | `List (first :: _) ->
      first |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string_option
  | _ -> None

let graphql_agents_edges json =
  match graphql_error_message json with
  | Some msg -> Error ("GraphQL error: " ^ msg)
  | None ->
      let open Yojson.Safe.Util in
      let data = member "data" json in
      if data = `Null then
        Error "GraphQL data is null"
      else
        let agents = member "agents" data in
        if agents = `Null then
          Error "GraphQL agents is null"
        else
          match member "edges" agents with
          | `List edges -> Ok edges
          | `Null -> Ok []
          | _ -> Error "GraphQL agents.edges is not a list"

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

(** Initialize rewrite_context implementation *)
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

          let summary =
            match Lodge_cascade.call ~cascade_name:"lodge_context_rewrite"
                ~prompt:summary_prompt ~temperature:0.3 ~timeout_sec:60
                ~max_tokens:700 () with
            | Ok r -> r.response
            | Error _ -> ""
          in

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

let builtin_core_agents () : agent list =
  [
    {
      name = "dreamer";
      preferred_hours = [9; 10; 11; 20; 21; 22];
      peak_hour = Some 21;
      traits = ["creative"; "imaginative"; "speculative"];
      interests = ["vision"; "story"; "future"];
      personality_hint = None;
      activity_level = 0.7;
    };
    {
      name = "skeptic";
      preferred_hours = [10; 11; 14; 15; 16];
      peak_hour = Some 15;
      traits = ["critical"; "risk-aware"; "evidence-first"];
      interests = ["risk"; "verification"; "failure-mode"];
      personality_hint = None;
      activity_level = 0.65;
    };
    {
      name = "historian";
      preferred_hours = [8; 9; 10; 13; 14];
      peak_hour = Some 10;
      traits = ["contextual"; "archival"; "pattern-aware"];
      interests = ["history"; "lineage"; "memory"];
      personality_hint = None;
      activity_level = 0.6;
    };
    {
      name = "pragmatist";
      preferred_hours = [9; 10; 13; 14; 17; 18];
      peak_hour = Some 14;
      traits = ["execution-focused"; "concise"; "outcome-driven"];
      interests = ["delivery"; "ops"; "reliability"];
      personality_hint = None;
      activity_level = 0.75;
    };
    {
      name = "connector";
      preferred_hours = [11; 12; 15; 16; 19; 20];
      peak_hour = Some 16;
      traits = ["social"; "integrative"; "bridge-builder"];
      interests = ["collaboration"; "handoff"; "coordination"];
      personality_hint = None;
      activity_level = 0.7;
    };
  ]

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
  | ActionSkip

type llm_decision_outcome = {
  action : agent_action;
  reason : string;
  confidence : float;
  llm_used : string option;
  decision_failure_reason : string option;
}

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

(** Get current date in KST as YYYY-MM-DD string *)
let current_date_kst () =
  let now = Time_compat.now () in
  let tm = Unix.gmtime (now +. (9.0 *. 3600.0)) in  (* Add 9 hours for KST *)
  Printf.sprintf "%04d-%02d-%02d"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday

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
  (* first:25 — GRAPHQL_MAX_COST=2000. Increased from 15 to accommodate new agents.
     19 agents exist; alphabetical pagination requires headroom. *)
  let gql_query = "{\"query\": \"{ agents(first: 25) { edges { node { name preferredHours peakHour traits interests activityLevel personalityHint } } } }\"}" in
  let api_key = Sys.getenv_opt "GRAPHQL_API_KEY" |> Option.value ~default:"" in
  Printf.eprintf "[Heartbeat] Loading agents via GraphQL (key=%d chars)...\n%!" (String.length api_key);
  if String.trim api_key = "" then (
    Eio.traceln "⚠️ [Heartbeat] GRAPHQL_API_KEY missing; using builtin core agents";
    builtin_core_agents ())
  else
  match graphql_request ~timeout_sec:5.0 gql_query with
  | Error err ->
      Eio.traceln "⚠️ [Heartbeat] GraphQL request failed: %s" err;
      builtin_core_agents ()
  | Ok json_str ->
      Printf.eprintf "[Heartbeat] GraphQL response: %d bytes\n%!" (String.length json_str);
      try
        let json = Yojson.Safe.from_string json_str in
        (match graphql_agents_edges json with
         | Error msg ->
             Eio.traceln "⚠️ GraphQL error loading agents: %s" msg;
             builtin_core_agents ()
         | Ok edges ->
             let parsed =
               List.filter_map (fun edge ->
                 try
                   let node = Yojson.Safe.Util.member "node" edge in
                   let name = Yojson.Safe.Util.(member "name" node |> to_string) in
                   let preferred_hours =
                     try Yojson.Safe.Util.(member "preferredHours" node |> to_list |> List.map to_int)
                     with Yojson.Safe.Util.Type_error (msg, _) | Failure msg ->
                       Printf.eprintf "[heartbeat] preferred_hours parse: %s for agent %s\n%!" msg name;
                       []
                   in
                   let peak_hour = Yojson.Safe.Util.(member "peakHour" node |> to_int_option) in
                   let traits =
                     try Yojson.Safe.Util.(member "traits" node |> to_list |> List.map to_string)
                     with Yojson.Safe.Util.Type_error (msg, _) | Failure msg ->
                       Printf.eprintf "[heartbeat] traits parse: %s for agent %s\n%!" msg name;
                       []
                   in
                   let activity_level =
                     match Yojson.Safe.Util.(member "activityLevel" node) with
                     | `Null -> 0.5
                     | v -> Yojson.Safe.Util.to_float v
                   in
                   let interests =
                     try Yojson.Safe.Util.(member "interests" node |> to_list |> List.map to_string)
                     with Yojson.Safe.Util.Type_error (msg, _) | Failure msg ->
                       Printf.eprintf "[heartbeat] interests parse: %s for agent %s\n%!" msg name;
                       []
                   in
                   let personality_hint =
                     match Yojson.Safe.Util.(member "personalityHint" node) with
                     | `String s -> Some s
                     | _ -> None
                   in
                   if preferred_hours <> [] then
                     Some { name; preferred_hours; peak_hour; traits; interests;
                            personality_hint; activity_level }
                   else
                     None
                 with Yojson.Safe.Util.Type_error (msg, _) ->
                   Eio.traceln "⚠️ Agent parse error: %s" msg;
                   None
               ) edges
             in
             if parsed <> [] then parsed
             else begin
               Eio.traceln "⚠️ GraphQL agents empty, using builtin core agents fallback";
               builtin_core_agents ()
             end)
      with e ->
        Eio.traceln "⚠️ Failed to load agents from GraphQL: %s" (Printexc.to_string e);
        builtin_core_agents ()

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
  ls_manual_tick_running: bool;
  ls_active_self_heartbeats: string list;
}

let _lodge_last_tick = ref 0.0
let _lodge_total_ticks = ref 0
let _lodge_total_checkins = ref 0
let _lodge_last_result : heartbeat_result option ref = ref None
let _lodge_enabled = ref false
let _lodge_manual_tick_running = ref false

let with_manual_tick_state f =
  lodge_init_lock ();
  match !lodge_lock with
  | Some mutex -> (
      try Eio.Mutex.use_rw ~protect:true mutex f
      with exn ->
        let msg = Printexc.to_string exn in
        if String.starts_with ~prefix:"Stdlib.Effect.Unhandled" msg
           || String.starts_with ~prefix:"Eio__Eio_mutex.Poisoned" msg
           || String.starts_with ~prefix:"Eio.Private.Mutex.Poisoned" msg
        then
          f ()
        else
          raise exn)
  | None -> f ()

let set_manual_tick_running value =
  with_manual_tick_state (fun () -> _lodge_manual_tick_running := value)

let manual_tick_running () =
  with_manual_tick_state (fun () -> !_lodge_manual_tick_running)

let try_begin_manual_tick () =
  with_manual_tick_state (fun () ->
    if !_lodge_manual_tick_running then
      false
    else begin
      _lodge_manual_tick_running := true;
      true
    end)

let record_tick_result (result : heartbeat_result) =
  _lodge_last_tick := Time_compat.now ();
  _lodge_total_ticks := !_lodge_total_ticks + 1;
  _lodge_total_checkins := !_lodge_total_checkins + List.length result.checkins;
  _lodge_last_result := Some result

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
    ls_manual_tick_running = manual_tick_running ();
    ls_active_self_heartbeats =
      Hashtbl.fold (fun name _state acc -> name :: acc) agent_states [];
  }

let string_of_trigger = function
  | Scheduled -> "scheduled"
  | ContentAlert _ -> "content_alert"
  | Mentioned _ -> "mentioned"
  | ManualTrigger -> "manual"

let checkin_json (name, trigger, result) =
  let outcome_fields =
    match result with
    | Acted { summary; _ } ->
        [ ("outcome", `String "acted"); ("summary", `String summary) ]
    | Passed reason ->
        [ ("outcome", `String "passed"); ("reason", `String reason) ]
    | Skipped reason ->
        [ ("outcome", `String "skipped"); ("reason", `String reason) ]
  in
  `Assoc
    ([
       ("name", `String name);
       ("trigger", `String (string_of_trigger trigger));
     ]
    @ outcome_fields)

let heartbeat_last_pass_reason (result : heartbeat_result) =
  let rec first_reason = function
    | [] -> None
    | (_, _, Passed reason) :: _ -> Some reason
    | _ :: tl -> first_reason tl
  in
  first_reason result.checkins

let heartbeat_last_system_skip_reason (result : heartbeat_result) =
  if result.agents_checked = 0 then
    Some "no agents selected for this tick"
  else
    let rec first_reason = function
      | [] -> None
      | (_, _, Skipped reason) :: _ -> Some reason
      | _ :: tl -> first_reason tl
    in
    first_reason result.checkins

let lodge_status_to_json (s : lodge_status) : Yojson.Safe.t =
  let quiet_start = Env_config.LodgeV2.quiet_start in
  let quiet_end = Env_config.LodgeV2.quiet_end in
  let current_hour = current_hour_kst () in
  let quiet_active =
    quiet_start < quiet_end
    && current_hour >= quiet_start
    && current_hour < quiet_end
  in
  let last_tick_ago_s =
    if s.ls_last_tick > 0.0 then
      let delta = Time_compat.now () -. s.ls_last_tick in
      Some (max 0.0 delta)
    else None
  in
  let last_tick_ago =
    match last_tick_ago_s with
    | Some delta -> Printf.sprintf "%.0fs ago" delta
    | None -> "never"
  in
  let last_result_json = match s.ls_last_result with
    | None -> `Null
    | Some r ->
      let acted =
        r.checkins
        |> List.filter_map (fun (name, _, result) ->
               match result with
               | Acted { summary; _ } ->
                   Some (`Assoc [ ("name", `String name); ("summary", `String summary) ])
               | Passed _ | Skipped _ -> None)
      in
      let passed =
        r.checkins
        |> List.filter_map (fun (name, _, result) ->
               match result with
               | Passed reason ->
                   Some (`Assoc [ ("name", `String name); ("reason", `String reason) ])
               | Acted _ | Skipped _ -> None)
      in
      let skipped =
        r.checkins
        |> List.filter_map (fun (name, _, result) ->
               match result with
               | Skipped reason ->
                   Some (`Assoc [ ("name", `String name); ("reason", `String reason) ])
               | Acted _ | Passed _ -> None)
      in
      `Assoc [
        ("hour", `Int r.current_hour);
        ("checked", `Int r.agents_checked);
        ("acted", `Int (List.length acted));
        ("acted_names", `List (List.map (fun row -> row |> Yojson.Safe.Util.member "name") acted));
        ("activity_report", `String r.activity_report);
        ( "skipped_reason",
          match heartbeat_last_system_skip_reason r with
          | Some reason -> `String reason
          | None -> `Null );
        ( "last_pass_reason",
          match heartbeat_last_pass_reason r with
          | Some reason -> `String reason
          | None -> `Null );
        ( "last_system_skip_reason",
          match heartbeat_last_system_skip_reason r with
          | Some reason -> `String reason
          | None -> `Null );
        ("acted_rows", `List acted);
        ("passed_rows", `List passed);
        ("skipped_rows", `List skipped);
        ("checkins", `List (List.map checkin_json r.checkins));
      ]
  in
  let last_pass_reason =
    match s.ls_last_result with
    | Some result -> heartbeat_last_pass_reason result
    | None -> None
  in
  let last_system_skip_reason =
    match s.ls_last_result with
    | Some result -> heartbeat_last_system_skip_reason result
    | None -> None
  in
  `Assoc [
    ("enabled", `Bool s.ls_enabled);
    ("interval_s", `Float s.ls_interval_s);
    ("quiet_start", `Int quiet_start);
    ("quiet_end", `Int quiet_end);
    ("quiet_active", `Bool quiet_active);
    ("use_planner", `Bool Env_config.LodgeV2.use_planner);
    ("delegate_llm", `Bool Env_config.LodgeV2.delegate_llm);
    ("agent_count", `Int s.ls_agent_count);
    ("agents", `List []);  (* hidden for privacy *)
    ("last_tick_ago_s", match last_tick_ago_s with Some v -> `Float v | None -> `Null);
    ("last_tick_ago", `String last_tick_ago);
    ("total_ticks", `Int s.ls_total_ticks);
    ("total_checkins", `Int s.ls_total_checkins);
    ("last_tick_result", last_result_json);
    ("manual_tick_running", `Bool s.ls_manual_tick_running);
    ( "last_skip_reason",
      match last_system_skip_reason with Some reason -> `String reason | None -> `Null );
    ( "last_pass_reason",
      match last_pass_reason with Some reason -> `String reason | None -> `Null );
    ( "last_system_skip_reason",
      match last_system_skip_reason with Some reason -> `String reason | None -> `Null );
    ("active_self_heartbeats", `List (List.map (fun n -> `String n) s.ls_active_self_heartbeats));
  ]

(** Ecosystem evolution types and agent creation — delegated to Lodge_ecosystem module.
    @since 4.1.0 *)
type gap_signal_t = Lodge_ecosystem.gap_signal_t = {
  gs_topic: string;
  gs_detected_by: string;
  gs_context: string;
  gs_timestamp: float;
}

let spawn_agent_from_gap ~topic ~signals =
  Lodge_ecosystem.spawn_agent_from_gap ~topic ~signals
    ~invalidate_cache:(fun () -> agents_cache_time := 0.0)

let get_agents () =
  let now = Time_compat.now () in
  let cache_ttl = if !agents_cache = [] then 30.0 else 300.0 in
  (* Empty cache → retry in 30s; populated → refresh every 5 min *)
  if now -. !agents_cache_time > cache_ttl then begin
    let loaded = load_agents_from_neo4j () in
    if loaded <> [] then begin
      agents_cache := loaded;
      agents_cache_time := now;
      Eio.traceln "🔄 Loaded %d heartbeat agents" (List.length loaded)
    end else if !agents_cache = [] then begin
      (* First load failed — record time to avoid hammering *)
      agents_cache_time := now;
      Eio.traceln "⚠️ Agent load returned empty, retrying in 30s"
    end
    (* else: keep existing cache on transient failure *)
  end;
  !agents_cache

(** Lodge Agent REST API — delegated to Lodge_ecosystem module.
    @since 4.1.0 *)
let load_lodge_agents_full = Lodge_ecosystem.load_lodge_agents_full

let create_agent_graphql ~name ~emoji ~korean_name ~traits ~interests
    ~activity_level ~preferred_hours ~peak_hour ~model
    ~personality_hint ~primary_value () =
  Lodge_ecosystem.create_agent_graphql ~name ~emoji ~korean_name ~traits ~interests
    ~activity_level ~preferred_hours ~peak_hour ~model
    ~personality_hint ~primary_value
    ~invalidate_cache:(fun () -> agents_cache_time := 0.0)
    ()

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
let select_checkin_agents ~ignore_quiet_hours ~(config : config)
    ~(agents : agent list)
    ~(pending_triggers : (string * checkin_trigger) list)
  : (string * checkin_trigger) list =
  let current_hour = current_hour_kst () in
  let (quiet_start, quiet_end) = config.quiet_hours in
  let is_quiet =
    (not ignore_quiet_hours)
    && current_hour >= quiet_start
    && current_hour < quiet_end
  in
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
        let t1 = match Hashtbl.find_opt Lodge_rate_limit.last_checkin a1.name with Some t -> t | None -> 0.0 in
        let t2 = match Hashtbl.find_opt Lodge_rate_limit.last_checkin a2.name with Some t -> t | None -> 0.0 in
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
      let content = Printf.sprintf "🫀 **Lodge Activity Report**\n\n%s" result.activity_report in
      (* SSE broadcast only — telemetry, not a Board announcement *)
      (try Sse.broadcast (`Assoc [
         ("type", `String "lodge_activity_report");
         ("author", `String "lodge-system");
         ("content", `String content);
       ])
       with exn ->
         Printf.eprintf "[warn] %s: %s\n" __FUNCTION__ (Printexc.to_string exn))
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
  let json_payload = Yojson.Safe.to_string (`Assoc [("query", `String mutation)]) in
  (* Fire and forget - don't block the main loop, but log failures *)
  match graphql_request ~timeout_sec:3.0 json_payload with
  | Error err ->
      Eio.traceln "   ⚠️ [Lodge] GraphQL activity log failed for %s: %s" agent_name err
  | Ok result ->
      let result =
        if String.length result > 100 then String.sub result 0 100 else result
      in
      if String.length result > 0 && String.length result < 5 then
        Eio.traceln "   ⚠️ [Lodge] GraphQL activity log may have failed for %s" agent_name

(** Agent profile loaded from Neo4j *)
(** Agent profile type and loading — delegated to Lodge_agent_profile module.
    @since 2.93.0 — Extracted for responsibility separation. *)
type agent_profile = Lodge_agent_profile.t

let agent_summaries_of_agents () : Lodge_agent_profile.agent_summary list =
  get_agents () |> List.map (fun (a : agent) ->
    Lodge_agent_profile.{
      name = a.name; traits = a.traits; interests = a.interests;
      preferred_hours = a.preferred_hours; peak_hour = a.peak_hour;
      activity_level = a.activity_level; personality_hint = a.personality_hint;
    })

let load_agent_profile ~agent_name : agent_profile =
  Lodge_agent_profile.load ~agent_name ~fallback_summaries:(agent_summaries_of_agents ()) ()

let build_lodge_context = Lodge_ecosystem.build_lodge_context

let build_agent_prompt ~(profile : agent_profile) ~memories ~thread_history ~current_hour ~action_context =
  Lodge_agent_profile.build_prompt ~profile ~memories ~thread_history
    ~current_hour ~action_context ~lodge_context:(build_lodge_context ())

let load_agent_identity ~agent_name =
  Lodge_agent_profile.load_identity ~agent_name ~fallback_summaries:(agent_summaries_of_agents ()) ()

(** Generate content using LLM based on agent personality from Neo4j *)
let generate_agent_content ~agent_name ~context:_ ~action_type =
  (* Load full profile from Neo4j via GraphQL *)
  let profile = load_agent_profile ~agent_name in
  (* Lodge_memory is the single memory owner for heartbeat prompts. *)
  let memories =
    let query =
      match action_type with
      | `Post reason -> reason
      | `Comment original_post -> original_post
    in
    let recalled = Lodge_memory.recall ~agent_name ~query ~limit:5 in
    match Lodge_memory.format_for_prompt recalled with
    | "" -> None
    | formatted -> Some formatted
  in
  let thread_history = None in
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

  (* Build system context for LLM *)
  let ctx = get_agent_context ~name:agent_name ~max_tokens:130000 in
  if needs_rewrite ~name:agent_name then rewrite_context ~name:agent_name;
  let context_str = ctx.messages |> List.map (fun m -> m.content) |> String.concat "\n" in
  let system_with_context =
    if String.length context_str > 0 then
      Printf.sprintf "%s\n\n[컨텍스트]\n%s" system_prompt context_str
    else system_prompt
  in

  (* Log context stats *)
  let (tokens, max_tokens, msg_count) = get_context_stats ~name:agent_name in
  Eio.traceln "   📊 [%s] Context: %d/%d tokens (%d msgs)" agent_name tokens max_tokens msg_count;

  (* Compute dynamic temperature from mood and activity *)
  let mood = Lodge_atmosphere.compute_mood
    ~positive_ratio:0.5 ~activity_level:profile.activity_level in
  let temperature = Lodge_personality.compute_temperature ~mood ~curiosity:0.5 in
  Eio.traceln "   🎭 [%s] Mood: %s → temp: %.2f"
    agent_name (Lodge_daemon.string_of_mood mood) temperature;

  (* LLM call via cascade abstraction *)
  let response =
    match Lodge_cascade.call ~cascade_name:"lodge_comment"
        ~prompt:user_prompt ~temperature ~timeout_sec:30
        ~max_tokens:120 ~system:system_with_context () with
    | Ok r -> r.response
    | Error _ -> ""
  in

  (* Save response to context and thread if successful *)
  (* Filter out empty/invalid responses from LLM *)
  let is_valid_response r =
    let len = String.length r in
    let r_lower = String.lowercase_ascii r in
    len > 10 &&
    not (len >= 14 && String.sub r 0 14 = "Empty response") &&
    not (len >= 5 && String.sub r_lower 0 5 = "error") &&
    not (len >= 9 && String.sub r 0 9 = "{\"error\":") &&
    (* Rate limit / quota messages from Claude CLI *)
    not (len >= 19 && String.sub r_lower 0 19 = "you've hit your lim") &&
    not (len >= 10 && String.sub r_lower 0 10 = "rate limit")
  in
  if is_valid_response response then begin
    add_to_context ~name:agent_name ~role:Assistant ~content:response;
    Some response
  end else begin
    Eio.traceln "   ⚠️ LLM response invalid for %s: '%s', skipping" agent_name
      (String.sub response 0 (min 30 (String.length response)));
    None
  end

(* agent_action type defined above in mutual recursion block *)

(** Gap signal tracking and duplicate detection — delegated to Lodge_ecosystem module.
    @since 4.1.0 *)
let check_gap_threshold = Lodge_ecosystem.check_gap_threshold
let clear_gap_signals = Lodge_ecosystem.clear_gap_signals
let get_signals_for_topic = Lodge_ecosystem.get_signals_for_topic
let is_duplicate_post = Lodge_ecosystem.is_duplicate_post

(** Content decay and relevance scoring — delegated to Lodge_ecosystem module.
    @since 4.1.0 *)
let sort_posts_for_agent = Lodge_ecosystem.sort_posts_for_agent

let take_list n xs =
  let rec take n acc = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | x :: rest -> take (n - 1) (x :: acc) rest
  in
  take n [] xs

let reaction_keywords ~(signature : Lodge_reaction.agent_signature)
    ~(profile : agent_profile) =
  let dynamic =
    signature.reaction_patterns
    |> List.filter (fun (_, affinity) -> affinity >= 0.35)
    |> List.sort (fun (_, left) (_, right) -> Float.compare right left)
    |> take_list 6
    |> List.map fst
  in
  let fallback =
    if signature.total_reactions < 5 then profile.traits @ profile.interests
    else []
  in
  List.sort_uniq String.compare (dynamic @ fallback)

let tom_context_for_posts ~agent_name (posts : Board.post list) =
  posts
  |> List.filter_map (fun (post : Board.post) ->
      let predictions =
        Lodge_tom.predict_top_k ~observer:agent_name ~post_content:post.content ~k:2
      in
      if predictions = [] then None
      else
        Some
          (Printf.sprintf "[Post %s 참고]\n%s"
             (Board.Post_id.to_string post.id)
             (Lodge_tom.tom_prompt_section predictions)))
  |> String.concat "\n\n"

let heartbeat_response_is_valid ?(require_json = false) s =
  let len = String.length s in
  let s_lower = String.lowercase_ascii s in
  let base_valid =
    len > 10
  && not (len >= 5 && String.sub s_lower 0 5 = "error")
  && not (len >= 14 && String.sub s 0 14 = "Empty response")
  && not (len >= 9 && String.sub s 0 9 = "{\"error\":")
  && not (String.length s_lower >= 19 && String.sub s_lower 0 19 = "you've hit your lim")
  && not (String.length s_lower >= 10 && String.sub s_lower 0 10 = "rate limit")
  in
  base_valid
  && ((not require_json) || Lodge_decision.contains_json_object s)

let heartbeat_response_accepted ?(require_json = false)
    (resp : Llm_client.completion_response) =
  heartbeat_response_is_valid ~require_json resp.content

let run_heartbeat_llm_once ?(require_json = false) ?(temperature = 0.7) ~agent_name ~prompt () =
  let accept = heartbeat_response_accepted ~require_json in
  match Lodge_cascade.call ~cascade_name:"heartbeat_action"
      ~prompt ~temperature ~timeout_sec:60 ~max_tokens:1200 ~accept () with
  | Ok r -> r
  | Error err ->
      Printf.printf "   ❌ [%s] Heartbeat cascade failed: %s\n%!" agent_name err;
      { Lodge_cascade.response = ""; llm_used = "none"; duration_ms = 0 }

let run_heartbeat_llm_traced ?(require_json = false) ?(temperature = 0.7) ~agent_name ~phase ~prompt () =
  let tick_id =
    Printf.sprintf "%s-%d" agent_name
      (int_of_float (Time_compat.now () *. 1000.0) mod 1000000)
  in
  let cascade_result =
    run_heartbeat_llm_once ~require_json ~temperature ~agent_name ~prompt ()
  in
  Lodge_trace.save
    {
      tick_id;
      agent_name;
      phase;
      prompt;
      response = cascade_result.Lodge_cascade.response;
      llm_used = cascade_result.Lodge_cascade.llm_used;
      action = phase;
      duration_ms = cascade_result.Lodge_cascade.duration_ms;
      timestamp = Time_compat.now ();
    };
  cascade_result

(** Compute dynamic temperature for an agent based on current mood.
    Uses time-of-day + jitter when actual reaction signals are unavailable.
    [agent_name] is accepted but unused — extension point for per-agent
    curiosity from Neo4j (planned: Track B+, OAS migration). *)
let agent_temperature ~agent_name:_ =
  let mood = Lodge_atmosphere.compute_mood_default () in
  Lodge_personality.compute_temperature ~mood ~curiosity:0.5

let trigger_allows_post = function
  | Scheduled | ManualTrigger -> true
  | ContentAlert _ | Mentioned _ -> false

let heartbeat_tool_context (posts : Board.post list) =
  posts
  |> List.map (fun (post : Board.post) ->
         Printf.sprintf "[target_post_id=%s]\nauthor=%s\n%s"
           (Board.Post_id.to_string post.id)
           (Board.Agent_id.to_string post.author)
           (utf8_truncate post.content 300))
  |> String.concat "\n\n"

let heartbeat_read_tools =
  [
    "masc_board_get";
    "masc_board_list";
    "masc_board_search";
    "lodge_search";
    "lodge_profile";
    "lodge_research";
  ]

let heartbeat_allowed_tools ~agent_name ~trigger ~recent_posts =
  let tools = ref heartbeat_read_tools in
  if recent_posts <> [] then tools := !tools @ [ "masc_board_vote" ];
  if recent_posts <> [] && check_rate_limit ~agent_name `Comment then
    tools := !tools @ [ "masc_board_comment" ];
  if trigger_allows_post trigger && check_rate_limit ~agent_name `Post then
    tools := !tools @ [ "masc_board_post" ];
  List.sort_uniq String.compare !tools

let classify_completion_action (completion : Lodge_worker.completion) =
  if List.mem "masc_board_post" completion.tool_names then `Post
  else if List.mem "masc_board_comment" completion.tool_names then `Comment
  else if List.mem "masc_board_vote" completion.tool_names then `Vote
  else `Skip

let checkin_result_of_completion ~agent_name (completion : Lodge_worker.completion) =
  (match classify_completion_action completion with
   | `Post -> record_rate_action ~agent_name `Post
   | `Comment -> record_rate_action ~agent_name `Comment
   | `Vote -> record_rate_action ~agent_name `Vote
   | `Skip -> ());
  record_agent_activity ~name:agent_name;
  match completion.status with
  | Lodge_worker.Acted ->
      let action =
        match classify_completion_action completion with
        | `Post -> ActionPost completion.summary
        | `Comment -> ActionComment ("tool-loop", completion.summary)
        | `Vote -> ActionUpvote "tool-loop"
        | `Skip -> ActionSkip
      in
      Acted { action; summary = completion.summary }
  | Lodge_worker.Skipped -> Passed completion.decision_reason
  | Lodge_worker.Failed ->
      Skipped
        (Option.value ~default:completion.summary completion.failure_reason)

let fallback_tool_loop_assignment
    ~agent_name
    ~trigger_reason
    ~sorted_posts:(sorted_posts : Board.post list) =
  let target_post_id =
    match sorted_posts with
    | (post : Board.post) :: _ -> Some (Board.Post_id.to_string post.id)
    | [] -> None
  in
  ({ agent_name;
    target_post_id;
    goal =
      (match target_post_id with
       | Some post_id ->
           Printf.sprintf
             "Inspect post %s and decide whether to comment, upvote, or skip using the allowed MCP tools directly."
             post_id
       | None ->
           "No candidate post was selected by the planner. Inspect the current room and decide whether to post, comment, or skip using the allowed MCP tools directly.");
    reason = "fallback selection after planner parse failure: " ^ trigger_reason;
    confidence = 0.25;
  } : Lodge_decision.assignment)

let select_tool_loop_assignment ~agent_name ~trigger ~trigger_reason ~recent_posts =
  let profile = load_agent_profile ~agent_name in
  let signature = Lodge_reaction.get_or_compute_signature ~agent_name in
  let all_keywords = reaction_keywords ~signature ~profile in
  let sorted_posts =
    sort_posts_for_agent ~agent_name ~agent_traits:all_keywords recent_posts
    |> take_list 5
  in
  let identity_prompt =
    let static_traits =
      if signature.total_reactions < 5 then profile.traits @ profile.interests else []
    in
    if signature.total_reactions > 0 || static_traits <> [] then
      Lodge_reaction.generate_identity_prompt signature ~static_traits
    else load_agent_identity ~agent_name
  in
  let allowed_tools = heartbeat_allowed_tools ~agent_name ~trigger ~recent_posts:sorted_posts in
  let prompt =
    Lodge_decision.selection_prompt ~agent_name
      ~candidate_agents:[ (agent_name, identity_prompt) ]
      ~posts:
        (List.map
           (fun (post : Board.post) ->
             ( Board.Post_id.to_string post.id,
               Board.Agent_id.to_string post.author,
               utf8_truncate post.content 300 ))
           sorted_posts)
      ~extra_context:
        (Some
           (Printf.sprintf
              "Trigger: %s\nAllowed MCP tools for this run: %s\nSelect exactly one assignment for this agent. The worker will use tools directly."
              trigger_reason (String.concat ", " allowed_tools)))
      ~max_agents:1 ~allow_post:(List.mem "masc_board_post" allowed_tools)
  in
  let cascade_result =
    run_heartbeat_llm_traced
      ~require_json:true ~temperature:(agent_temperature ~agent_name)
      ~agent_name ~phase:"lodge_tool_assignment" ~prompt ()
  in
  match
    Lodge_decision.parse_selection_plan ~allowed_agents:[ agent_name ]
      ~allowed_post_ids:
        (List.map (fun (post : Board.post) -> Board.Post_id.to_string post.id) sorted_posts)
      ~max_agents:1 cascade_result.Lodge_cascade.response
  with
  | Ok { assignments = assignment :: _; _ } ->
      Ok (assignment, identity_prompt, sorted_posts, allowed_tools)
  | Ok _ -> Error "selection returned no assignments"
  | Error _reason ->
      Ok
        ( fallback_tool_loop_assignment ~agent_name ~trigger_reason ~sorted_posts,
          identity_prompt,
          sorted_posts,
          allowed_tools )

let run_agent_tool_loop ~agent_name ~trigger ~trigger_reason ~recent_posts =
  match select_tool_loop_assignment ~agent_name ~trigger ~trigger_reason ~recent_posts with
  | Error reason -> Skipped ("tool_loop_selection_failed:" ^ reason)
  | Ok (assignment, identity_prompt, sorted_posts, allowed_tools) ->
      let context = heartbeat_tool_context sorted_posts in
      if Env_config.LodgeV2.delegate_llm then begin
        A2a_tools.emit_heartbeat_task ~agent:agent_name ~goal:assignment.goal ~context
          ~allowed_tools ~decision_reason:assignment.reason
          ~decision_confidence:assignment.confidence ();
        Passed ("delegated_tool_loop:" ^ assignment.reason)
      end else
        match
          Lodge_worker.run_local ~agent_name ~identity_prompt ~goal:assignment.goal
            ~context ~allow_post:(List.mem "masc_board_post" allowed_tools)
            ~allowed_tools_override:allowed_tools ()
        with
        | Error err -> Skipped ("tool_loop_failed:" ^ err)
        | Ok completion -> checkin_result_of_completion ~agent_name completion

let action_of_choice (choice : Lodge_decision.choice) : (agent_action, string) result =
  match (choice.action, choice.target_post_id, choice.content) with
  | Lodge_decision.Post, _, Some content -> Ok (ActionPost content)
  | Lodge_decision.Comment, Some post_id, Some content ->
      Ok (ActionComment (post_id, content))
  | Lodge_decision.Upvote, Some post_id, _ -> Ok (ActionUpvote post_id)
  | Lodge_decision.Skip, _, _ -> Ok ActionSkip
  | Lodge_decision.Post, _, _ -> Error "post choice missing content"
  | Lodge_decision.Comment, _, _ -> Error "comment choice missing target or content"
  | Lodge_decision.Upvote, _, _ -> Error "upvote choice missing target"

(** Ask LLM to decide what action to take *)
let decide_agent_action ~agent_name ~trigger ~trigger_reason ~recent_posts =
  let profile = load_agent_profile ~agent_name in
  let signature = Lodge_reaction.get_or_compute_signature ~agent_name in
  let all_keywords = reaction_keywords ~signature ~profile in
  let sorted_posts =
    sort_posts_for_agent ~agent_name ~agent_traits:all_keywords recent_posts |> take_list 5
  in
  let prompt_posts =
    sorted_posts
    |> List.map (fun (post : Board.post) ->
           ( Board.Post_id.to_string post.id,
             Board.Agent_id.to_string post.author,
             utf8_truncate post.content 300 ))
  in
  let static_traits =
    if signature.total_reactions < 5 then profile.traits @ profile.interests else []
  in
  let tom_context = tom_context_for_posts ~agent_name sorted_posts in
  let extra_context =
    let pieces =
      [ Some ("Trigger: " ^ trigger_reason)
      ; (if String.trim tom_context = "" then None else Some tom_context)
      ]
      |> List.filter_map Fun.id
    in
    match pieces with
    | [] -> None
    | xs -> Some (String.concat "\n\n" xs)
  in
  let prompt =
    Lodge_decision.batch_decision_prompt
      ~agent_name
      ~identity_prompt:
        (Lodge_reaction.generate_identity_prompt signature ~static_traits)
      ~posts:prompt_posts
      ~extra_context
      ~allow_post:(trigger_allows_post trigger)
  in
  let cascade_result =
    run_heartbeat_llm_traced
      ~require_json:true ~temperature:(agent_temperature ~agent_name)
      ~agent_name ~phase:"lodge_decision" ~prompt ()
  in
  let llm_used = Some cascade_result.Lodge_cascade.llm_used in
  let response = cascade_result.Lodge_cascade.response in
  match
    Lodge_decision.parse_batch_outcome
      ~allowed_post_ids:(List.map (fun (post_id, _, _) -> post_id) prompt_posts)
      ~allow_post:(trigger_allows_post trigger)
      response
  with
  | Error reason ->
      {
        action = ActionSkip;
        reason = "decision error: " ^ reason;
        confidence = 0.0;
        llm_used;
        decision_failure_reason = Some reason;
      }
  | Ok outcome ->
      List.iter
        (fun (reaction : Lodge_decision.reaction) ->
          match
            List.find_opt
              (fun (post : Board.post) ->
                Board.Post_id.to_string post.id = reaction.post_id)
              sorted_posts
          with
          | Some post ->
              Lodge_reaction.record_reaction
                ~agent_name
                ~post_id:reaction.post_id
                ~post_author:(Board.Agent_id.to_string post.author)
                ~post_content:post.content
                ~reaction:reaction.reaction
                ~confidence:reaction.confidence
                ?reason:reaction.reason
                ()
          | None -> ())
        outcome.reactions;
      (match action_of_choice outcome.choice with
      | Error reason ->
          {
            action = ActionSkip;
            reason = "decision error: " ^ reason;
            confidence = 0.0;
            llm_used;
            decision_failure_reason = Some reason;
          }
      | Ok action ->
          {
            action;
            reason = outcome.choice.reason;
            confidence = outcome.choice.confidence;
            llm_used;
            decision_failure_reason = None;
          })

(** Execute the decided action *)
let action_summary = function
  | ActionPost content -> Printf.sprintf "Posted: %s" (utf8_truncate content 40)
  | ActionComment (post_id, content) ->
      Printf.sprintf "Commented on %s: %s" post_id (utf8_truncate content 30)
  | ActionUpvote post_id -> Printf.sprintf "Upvoted %s" post_id
  | ActionSkip -> "Skipped"

let execute_agent_action ~agent_name ~action =
  let store = Board.global () in
  match action with
  | ActionSkip ->
      Eio.traceln "   ⏭️ [%s] Decided to skip" agent_name;
      Lodge_memory.store {
        agent_name; action_type = "skip"; content = ""; context = "explicit_skip";
        board_id = None; timestamp = Time_compat.now ();
      };
      Passed "explicit_skip"
  | ActionPost content ->
      if String.length content < 5 then
        (Eio.traceln "   ⚠️ [%s] Content too short, skipping" agent_name;
         Skipped "post_content_too_short")
      else if not (check_rate_limit ~agent_name `Post) then
        (Eio.traceln "   ⏳ [%s] POST rate-limited (%.0fs gap / %d/day max)" agent_name min_post_gap max_posts_per_day;
         Skipped "post_rate_limited")
      else if is_duplicate_post ~agent_name ~content then
        (Eio.traceln "   🔄 [%s] Similar post already exists, skipping to avoid repetition" agent_name;
         Passed "duplicate_post")
      else begin
        let vr = Post_verifier_llm.verify_auto ~content in
        Lodge_selection.record_quality_signal ~agent_name ~verdict:vr.overall;
        if not (Post_verifier.is_acceptable vr) then begin
          let reason = Post_verifier.verdict_to_string vr.overall in
          Eio.traceln "   🚫 [%s] Post rejected by verifier: %s" agent_name reason;
          Agent_health.record_failure ~agent_name ~reason;
          Skipped (Printf.sprintf "post_verifier_rejected:%s" reason)
        end else begin
          (match vr.overall with
           | Post_verifier.Warn reason ->
               Eio.traceln "   ⚠️ [%s] Post verifier warning: %s" agent_name reason
           | _ -> ());
          match Board.create_post store ~author:agent_name ~content ~ttl_hours:168 () with
          | Ok post ->
              let post_id = Board.Post_id.to_string post.id in
              Printf.printf "   📝 [%s] Posted: %s\n%!" agent_name post_id;
              record_agent_activity ~name:agent_name;
              record_rate_action ~agent_name `Post;
              record_to_neo4j ~agent_name ~action_type:`Post ~content ~target_id:post_id;
              Lodge_memory.store {
                agent_name; action_type = "post"; content; context = "LLM decision";
                board_id = Some post_id; timestamp = Time_compat.now ();
              };
              Acted { action; summary = action_summary action }
          | Error e ->
              let err = Board.show_board_error e in
              Eio.traceln "   ❌ [%s] Post failed: %s" agent_name err;
              Skipped (Printf.sprintf "post_create_failed:%s" err)
        end
      end
  | ActionComment (post_id, content) ->
      if String.length content < 3 then
        (Eio.traceln "   ⚠️ [%s] Comment too short, skipping" agent_name;
         Skipped "comment_content_too_short")
      else if not (check_rate_limit ~agent_name `Comment) then
        (Eio.traceln "   ⏳ [%s] COMMENT rate-limited (%.0fs gap / %d/day max)" agent_name min_comment_gap max_comments_per_day;
         Skipped "comment_rate_limited")
      else if not (can_agent_comment ~agent_name ~post_id) then
        (Eio.traceln "   🚫 [%s] Already commented %d times on %s, skipping" agent_name max_comments_per_agent_per_post post_id;
         Skipped "comment_limit_reached")
      else begin
        let vr = Post_verifier_llm.verify_auto ~content in
        Lodge_selection.record_quality_signal ~agent_name ~verdict:vr.overall;
        if not (Post_verifier.is_acceptable vr) then begin
          let reason = Post_verifier.verdict_to_string vr.overall in
          Eio.traceln "   🚫 [%s] Comment rejected by verifier: %s" agent_name reason;
          Agent_health.record_failure ~agent_name ~reason;
          Skipped (Printf.sprintf "comment_verifier_rejected:%s" reason)
        end else begin
          (match vr.overall with
           | Post_verifier.Warn reason ->
               Eio.traceln "   ⚠️ [%s] Comment verifier warning: %s" agent_name reason
           | _ -> ());
          match Board.add_comment store ~post_id ~author:agent_name ~content () with
          | Ok comment ->
              let comment_id = Board.Comment_id.to_string comment.id in
              Printf.printf "   💬 [%s] Commented on %s: %s\n%!" agent_name post_id comment_id;
              record_agent_comment ~agent_name ~post_id;
              record_agent_activity ~name:agent_name;
              record_rate_action ~agent_name `Comment;
              record_to_neo4j ~agent_name ~action_type:`Comment ~content ~target_id:comment_id;
              Lodge_memory.store {
                agent_name; action_type = "comment"; content; context = post_id;
                board_id = Some post_id; timestamp = Time_compat.now ();
              };
              Acted { action; summary = action_summary action }
          | Error e ->
              let err = Board.show_board_error e in
              Eio.traceln "   ❌ [%s] Comment failed: %s" agent_name err;
              Skipped (Printf.sprintf "comment_create_failed:%s" err)
        end
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
           };
           Acted { action; summary = action_summary action }
       | Error e ->
           let err = Board.show_board_error e in
           Eio.traceln "   ❌ [%s] Upvote failed: %s" agent_name err;
           Skipped (Printf.sprintf "upvote_failed:%s" err))
      

(** {1 LLM call helper for Planner/Reflection} *)

(** Reusable LLM call function (cascade-based) for Planner and Reflection.
    Wraps the LLM cascade in a simple (prompt -> string) signature. *)
let make_call_llm ~agent_name : (prompt:string -> string) =
  fun ~prompt ->
    let temperature = agent_temperature ~agent_name in
    (run_heartbeat_llm_once ~temperature ~agent_name ~prompt ()).Lodge_cascade.response

(** {1 Plan-based Agent Selection} *)

(** Convert Lodge_selection trigger to checkin_trigger *)
let trigger_of_selection_trigger : Lodge_selection.selection_trigger -> checkin_trigger = function
  | Lodge_selection.Mentioned s -> Mentioned s
  | Lodge_selection.ContentAlert s -> ContentAlert s
  | Lodge_selection.Scheduled -> Scheduled
  | Lodge_selection.Starved -> Scheduled  (* Map to Scheduled for compatibility *)
  | Lodge_selection.Thompson -> Scheduled

(** Convert checkin_trigger to Lodge_selection trigger *)
let selection_trigger_of_trigger : checkin_trigger -> Lodge_selection.selection_trigger = function
  | Mentioned s -> Lodge_selection.Mentioned s
  | ContentAlert s -> Lodge_selection.ContentAlert s
  | Scheduled -> Lodge_selection.Scheduled
  | ManualTrigger -> Lodge_selection.Scheduled

(** Select agents using Thompson Sampling with fairness guarantees.
    Falls back to plan-based selection if Thompson disabled. *)
let select_agents_with_thompson ~ignore_quiet_hours
    ~(agents : agent list) ~max_n
    ~(pending_triggers : (string * checkin_trigger) list)
  : (string * checkin_trigger) list =
  let current_hour = current_hour_kst () in
  let config = load_config () in
  let (quiet_start, quiet_end) = config.quiet_hours in
  let is_quiet =
    (not ignore_quiet_hours)
    && quiet_start < quiet_end
    && current_hour >= quiet_start
    && current_hour < quiet_end
  in
  if is_quiet || List.length agents = 0 then begin
    if is_quiet then
      Eio.traceln "   😴 [thompson] Quiet hours (%d-%d), skipping selection" quiet_start quiet_end;
    []
  end else begin
    let tick_interval = Env_config.LodgeV2.tick_interval_seconds in
    let agent_names = List.map (fun (a : agent) -> a.name) agents in
    let converted_triggers = List.map (fun (name, t) ->
      (name, selection_trigger_of_trigger t)
    ) pending_triggers in

    let results = Lodge_selection.select_with_feedback
      ~agents:agent_names
      ~max_n
      ~pending_triggers:converted_triggers
      ~tick_interval_s:tick_interval
    in

    (* Log selection reasoning *)
    List.iter (fun (r : Lodge_selection.selection_result) ->
      Eio.traceln "   🎲 [thompson] %s: ts=%.3f sb=%.3f final=%.3f (ticks=%d, trigger=%s)"
        r.agent_name r.thompson_score r.starvation_bonus r.final_score
        r.ticks_since_selection
        (match r.trigger with
         | Lodge_selection.Mentioned _ -> "mentioned"
         | Lodge_selection.ContentAlert _ -> "alert"
         | Lodge_selection.Scheduled -> "scheduled"
         | Lodge_selection.Starved -> "starved"
         | Lodge_selection.Thompson -> "thompson")
    ) results;

    (* Convert back to checkin_trigger format *)
    List.map (fun (r : Lodge_selection.selection_result) ->
      (r.agent_name, trigger_of_selection_trigger r.trigger)
    ) results
  end

(** Select agents based on their daily plan priorities.
    Returns the top-N agents whose current-hour block has highest priority. *)
let select_agents_by_plan ~ignore_quiet_hours
    ~(agents : agent list) ~max_n
    ~(pending_triggers : (string * checkin_trigger) list)
  : (string * checkin_trigger) list =
  let current_hour = current_hour_kst () in
  let config = load_config () in
  let (quiet_start, quiet_end) = config.quiet_hours in
  let is_quiet =
    (not ignore_quiet_hours)
    && quiet_start < quiet_end
    && current_hour >= quiet_start
    && current_hour < quiet_end
  in
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
let tick ~ignore_quiet_hours ~config ~pending_triggers =
  let timestamp = Time_compat.now () in
  let current_hour = current_hour_kst () in
  let agents = get_agents () in

  (* Select which agents to check in — Thompson (default) / plan-based / legacy *)
  let max_agents = Env_config.LodgeV2.agents_per_tick in
  let use_thompson = Env_config.LodgeV2.use_planner in  (* Reuse planner flag for Thompson *)
  let selected =
    if use_thompson then
      select_agents_with_thompson ~ignore_quiet_hours ~agents
        ~max_n:max_agents ~pending_triggers
    else
      select_checkin_agents ~ignore_quiet_hours ~config ~agents
        ~pending_triggers
  in

  (* Record selections for Thompson Sampling feedback *)
  List.iter (fun (name, _) ->
    Lodge_selection.record_selection ~agent_name:name
  ) selected;

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
    (* Health gate: skip agents with open circuit breakers *)
    if not (Agent_health.is_healthy ~agent_name:name) then
      (name, trigger, Skipped "agent unhealthy (circuit breaker open)")
    else begin
      let trigger_reason = string_of_trigger trigger in
      let result =
        try
          let outcome =
            run_agent_tool_loop ~agent_name:name ~trigger ~trigger_reason ~recent_posts
          in
          (match outcome with
           | Acted _ -> Agent_health.record_success ~agent_name:name
           | Passed _ | Skipped _ -> ());
          outcome
        with exn ->
          let err = Printexc.to_string exn in
          Agent_health.record_failure ~agent_name:name ~reason:err;
          Printf.printf "[lodge] Agent %s action failed: %s\n%!" name err;
          Skipped (Printf.sprintf "action_failed:%s" err)
      in
      record_checkin ~agent_name:name;
      record_checkin ~agent_name:name;
      (* Record action for Thompson Sampling *)
      (match result with
       | Acted { action = ActionPost _; _ } ->
           Lodge_selection.record_action ~agent_name:name ~action:`Post
       | Acted { action = ActionComment _; _ } ->
           Lodge_selection.record_action ~agent_name:name ~action:`Comment
       | Acted { action = ActionUpvote _; _ }
       | Acted { action = ActionSkip; _ }
       | Passed _ | Skipped _ ->
           Lodge_selection.record_action ~agent_name:name ~action:`Skip);
      (name, trigger, result)
    end
  ) selected in

  (* Post-tick: check if any agent should reflect *)
  List.iter (fun (name, _, _) ->
    if Reflection.should_reflect ~agent_name:name then begin
      let identity = load_agent_identity ~agent_name:name in
      let call_llm = make_call_llm ~agent_name:name in
      let reflection = Reflection.reflect ~agent_name:name ~identity ~call_llm in
      if reflection <> "(성찰 실패)" then
        Lodge_reaction.update_self_summary ~agent_name:name ~summary:reflection;
      ()
    end
  ) checkins;

  (* Flush pending votes and save stats for Thompson Sampling *)
  Lodge_selection.flush_pending_votes ();
  Lodge_selection.save_stats ();

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

(* ── Pulse helpers ─────────────────────────────────────────── *)

(** Fixed-interval rhythm with no quiet hours.
    Lodge manages quiet hours via Env_config, not Pulse rhythm. *)
let fixed_rhythm base_s =
  { Pulse.base_s; min_s = base_s; max_s = base_s; quiet = (0, 0) }

(** Pulse instance for the main Lodge tick loop. *)
let lodge_tick_pulse : Pulse.t option ref = ref None

(** Build the main Lodge tick consumer.
    This consumer captures the full Lodge heartbeat cycle:
    scan triggers → tick → update state → log → post report → start agent heartbeats → GC *)
let make_lodge_tick_consumer ~config ~last_tick_time ~sw ~clock ~room_config
    ~tick_interval : (module Pulse.Consumer) =
  (module struct
    let name = "lodge-tick"
    let should_act _beat = true
    let on_beat (beat : Pulse.beat) =
      try
        (* Scan for content-driven triggers since last tick *)
        let agents = get_agents () in
        let pending_triggers = scan_board_triggers ~since:!last_tick_time ~agents in
        last_tick_time := Time_compat.now ();

        (* Run the tick — plan-based selection + LLM decisions + reflection *)
        let result = tick ~ignore_quiet_hours:false ~config ~pending_triggers in

        (* Record observable state *)
        record_tick_result result;

        (* Log result *)
        let n_acted = List.length (List.filter (fun (_, _, r) ->
          match r with Acted _ -> true | _ -> false) result.checkins) in
        Printf.printf "🫀 [%02d:00 KST] agents=%d selected=%d acted=%d (%.0fs tick)\n%!"
          result.current_hour result.agents_checked
          (List.length result.checkins) n_acted tick_interval;

        (* Post activity report to Board if there were actions *)
        post_activity_report ~result;

        (* Start self-heartbeat for agents who acted (continue engagement) *)
        let acted_agents = List.filter_map (fun (name, _, r) ->
          match r with
          | Acted _ -> Some name
          | _ -> None
        ) result.checkins in
        List.iter (fun name ->
          if not (is_agent_active ~name) then begin
            let recent_posts = Board.list_posts (Board.global ()) ~limit:10 () in
            let on_tick ~name ~state:_ =
              if not (Agent_health.is_healthy ~agent_name:name) then
                Printf.printf "[lodge] Skipping self-heartbeat for %s (unhealthy)\n%!" name
              else begin
                let trigger_reason = "self-heartbeat continuation" in
                (try
                  let outcome =
                    run_agent_tool_loop ~agent_name:name ~trigger:Scheduled
                      ~trigger_reason ~recent_posts
                  in
                  (match outcome with
                   | Acted _ -> Agent_health.record_success ~agent_name:name
                   | Passed _ | Skipped _ -> ())
                with exn ->
                  Agent_health.record_failure ~agent_name:name
                    ~reason:(Printexc.to_string exn);
                  Printf.printf "[lodge] Self-heartbeat %s failed: %s\n%!" name (Printexc.to_string exn))
              end
            in
            start_agent_heartbeat ~sw ~clock ~name ~on_tick
          end
        ) acted_agents;

        ignore room_config;

        (* Cleanup inactive Lodge agents *)
        cleanup_inactive_lodge_agents ();

        (* Memory GC: run every 10 ticks to prune stale + consolidate similar *)
        if beat.seq > 0 && beat.seq mod 10 = 0 then begin
          let gc_result = Lodge_memory_gc.run_gc () in
          if gc_result.total_pruned > 0 || gc_result.total_merged > 0 then
            Printf.printf "🧹 %s\n%!" (Lodge_memory_gc.format_result gc_result)
        end;
        Ok ()
      with exn ->
        let msg = Printf.sprintf "tick error: %s" (Printexc.to_string exn) in
        Eio.traceln "💀 Lodge %s (recovering...)" msg;
        Error msg
  end)

(** Start heartbeat daemon fiber — Generative Agent Architecture *)
let start ~sw ~clock room_config =
  Printf.printf "+Lodge Heartbeat v2 (Generative Agent): initializing...\n%!";
  lodge_init_lock ();
  let config = load_config () in
  let tick_interval = Env_config.LodgeV2.tick_interval_seconds in
  let use_planner = Env_config.LodgeV2.use_planner in
  Printf.printf "+Lodge Heartbeat: enabled=%b interval=%.0fs agents_per_tick=%d planner=%b\n%!"
    config.enabled tick_interval Env_config.LodgeV2.agents_per_tick use_planner;

  (* Configure and load persistent selection stats for Thompson Sampling *)
  Lodge_selection.set_base_path room_config.Room_utils.base_path;
  Lodge_selection.load_stats ();
  Printf.printf "+Lodge Selection: Thompson Sampling enabled (max_starvation=%d, weight=%.2f, path=%s)\n%!"
    Env_config.LodgeSelection.max_starvation_ticks
    Env_config.LodgeSelection.thompson_weight
    room_config.Room_utils.base_path;

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

    (* Build Pulse consumer and engine *)
    let consumer = make_lodge_tick_consumer
      ~config ~last_tick_time ~sw ~clock ~room_config ~tick_interval in
    let p = Pulse.create
      ~clock
      ~rhythm:(fixed_rhythm tick_interval)
      ~lifecycle:Perpetual
      ~consumers:[consumer]
    in
    lodge_tick_pulse := Some p;
    Pulse.run ~sw p
  end

(** {1 Manual Trigger (for MCP tool)} *)

let run_manual_heartbeat room_config =
  let config = load_config () in
  let agents = get_agents () in
  (* Manual trigger: create ManualTrigger for all agents *)
  let pending_triggers = List.map (fun (a : agent) ->
    (a.name, ManualTrigger)
  ) agents in
  let result = tick ~ignore_quiet_hours:true ~config ~pending_triggers in
  record_tick_result result;

  List.iter (fun (name, _trigger, _checkin) ->
    Eio.traceln "🔔 %s checked in (manual trigger)" name
  ) result.checkins;

  ignore room_config;
  result

let trigger_heartbeat room_config =
  if not (try_begin_manual_tick ()) then
    invalid_arg "manual heartbeat already running";
  Fun.protect
    ~finally:(fun () -> set_manual_tick_running false)
    (fun () -> run_manual_heartbeat room_config)

let trigger_heartbeat_async ~sw room_config =
  if not (try_begin_manual_tick ()) then
    `Already_running
  else begin
    Eio.Fiber.fork ~sw (fun () ->
      Fun.protect
        ~finally:(fun () -> set_manual_tick_running false)
        (fun () ->
          try
            ignore (run_manual_heartbeat room_config)
          with exn ->
            Eio.traceln "💀 Lodge manual trigger failed: %s"
              (Printexc.to_string exn)));
    `Started
  end

(** Broadcast content-aware routing is now in Lodge_broadcast module.
    See lib/lodge_broadcast.ml for the extracted code.
    @since 2.91.0 — Extracted to reduce lodge_heartbeat.ml size. *)
