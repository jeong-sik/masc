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

(** Run [f] under lodge mutex. Falls back to unprotected if not yet initialized.

    The [None] case is safe only during single-domain startup before
    [lodge_init_lock] is called (i.e., before any Eio fibers are spawned).
    Once the Eio scheduler is running, [lodge_init_lock] must have been
    called so that all concurrent accesses are properly serialized. *)
let with_lodge_lock f =
  match !lodge_lock with
  | Some mutex -> Eio.Mutex.use_rw ~protect:true mutex f
  | None ->
    (* Pre-Eio startup: single domain, no concurrent fibers possible. *)
    f ()

(** Active agents: name -> (uuid, started_at) *)
let active_agents : (string, string * float) Hashtbl.t = Hashtbl.create 10

(** Generate UUID for agent instance *)
let generate_agent_uuid () =
  Printf.sprintf "%s-%08x"
    (String.sub (Digest.to_hex (Digest.string (string_of_float (Time_compat.now ())))) 0 8)
    (Random.int 0xFFFFFF)

(** Crash recovery timeout (default 360s = 3x the heartbeat interval of 120s).
    Previous value (120s = 1x interval) caused race conditions where agents
    were removed between heartbeat ticks. 3x provides adequate margin.
    Configurable via MASC_AGENT_TIMEOUT_SEC. *)
let agent_crash_timeout = Env_config_governance.Timeouts.agent_timeout_sec

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

