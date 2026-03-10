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

(** {1 Agent Trace — Prompt/Response Logging for Tuning} *)

(** Trace entry: captures full prompt, response, timing, and action *)
type trace_entry = {
  tick_id : string;         (* Unique tick identifier *)
  agent_name : string;
  phase : string;           (* "decide_action", "auto_respond", etc. *)
  prompt : string;          (* Full prompt sent to LLM *)
  response : string;        (* LLM response *)
  llm_used : string;        (* Which LLM was used, e.g. "glm(glm-4.7)" *)
  action : string;          (* Parsed action: "POST", "COMMENT:id", "SKIP" *)
  duration_ms : int;        (* Time taken in milliseconds *)
  timestamp : float;        (* Unix timestamp *)
}

(** Ensure directory exists *)
let ensure_trace_dir ~agent_name =
  let me_root =
    match Env_config.me_root_opt () with
    | Some root -> root
    | None -> Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp"
  in
  let trace_dir = Filename.concat me_root (Printf.sprintf ".masc/traces/%s" agent_name) in
  if not (Sys.file_exists trace_dir) then begin
    let parent = Filename.concat me_root ".masc/traces" in
    if not (Sys.file_exists parent) then
      Unix.mkdir parent 0o755;
    Unix.mkdir trace_dir 0o755
  end;
  trace_dir

(** Save a trace entry to JSONL file *)
let save_trace (entry : trace_entry) =
  let trace_dir = ensure_trace_dir ~agent_name:entry.agent_name in
  let date_str =
    let tm = Unix.gmtime entry.timestamp in
    Printf.sprintf "%04d-%02d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
  in
  let trace_file = Filename.concat trace_dir (date_str ^ ".jsonl") in
  let json = `Assoc [
    ("tick_id", `String entry.tick_id);
    ("agent_name", `String entry.agent_name);
    ("phase", `String entry.phase);
    ("prompt", `String entry.prompt);
    ("response", `String entry.response);
    ("llm_used", `String entry.llm_used);
    ("action", `String entry.action);
    ("duration_ms", `Int entry.duration_ms);
    ("timestamp", `Float entry.timestamp);
  ] in
  let line = Yojson.Safe.to_string json ^ "\n" in
  let oc = open_out_gen [Open_append; Open_creat; Open_text] 0o644 trace_file in
  output_string oc line;
  close_out oc;
  Printf.printf "   📝 [%s] Trace saved: %s (%dms, %s)\n%!" entry.agent_name trace_file entry.duration_ms entry.llm_used

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

(** Use local GraphQL by default for local MCP runs.
    Set GRAPHQL_URL explicitly to force remote endpoint. *)
(** Use Railway GraphQL by default.
    Set GRAPHQL_URL explicitly for local dev or alternate endpoints. *)
let graphql_url () = Graphql_endpoint.graphql_url ()

let looks_like_html_response body =
  let trimmed = String.lowercase_ascii (String.trim body) in
  trimmed <> "" && trimmed.[0] = '<'

let ensure_graphql_json_response body =
  if String.length body = 0 then
    Error "empty response"
  else if looks_like_html_response body then
    Error "endpoint returned HTML instead of JSON"
  else
    Ok body

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

(** Keep auth token out of argv so process errors don't leak secrets. *)
let with_auth_header_file api_key f =
  if api_key = "" then f None
  else
    let path = Filename.temp_file "masc-gql-auth-" ".hdr" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
      (fun () ->
         let fd = Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
         let oc = Unix.out_channel_of_descr fd in
         output_string oc ("Authorization: Bearer " ^ api_key ^ "\n");
         close_out oc;
         f (Some path))

let with_body_file body f =
  let path = Filename.temp_file "masc-gql-body-" ".json" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       let oc = open_out_bin path in
       Fun.protect
         ~finally:(fun () -> close_out_noerr oc)
         (fun () -> output_string oc body);
       f path)

let run_argv_unix (argv : string list)
  : (string, string) Stdlib.result =
  match argv with
  | [] -> Error "empty argv"
  | prog :: _ -> (
      try
        let ic = Unix.open_process_args_in prog (Array.of_list argv) in
        let output =
          Fun.protect
            ~finally:(fun () -> ignore (Unix.close_process_in ic))
            (fun () -> In_channel.input_all ic)
        in
        Ok output
      with exn -> Error (Printexc.to_string exn))

(** curl-based GraphQL request — reliable DNS resolution in Railway containers *)
let graphql_request_curl body : (string, string) Stdlib.result =
  let url = graphql_url () in
  let api_key = Sys.getenv_opt "GRAPHQL_API_KEY" |> Option.value ~default:"" in
  with_auth_header_file api_key (fun auth_header_file ->
      with_body_file body (fun body_file ->
          let argv =
            [ "curl"; "-s"; "-m"; "10"; "-X"; "POST"; url;
              "-H"; "Content-Type: application/json";
              "-H"; "Accept: application/json"
            ]
            |> fun base ->
            match auth_header_file with
            | None -> base
            | Some header_file -> base @ [ "-H"; "@" ^ header_file ]
            |> fun with_auth ->
            with_auth @ [ "-d"; "@" ^ body_file ]
          in
          let process_eio_result =
            if Process_eio.is_initialized () then
              try
                Ok (Process_eio.run_argv ~timeout_sec:15.0 argv)
              with exn -> Error (Printf.sprintf "curl: %s" (Printexc.to_string exn))
            else
              Error "Process_eio not initialized"
          in
          match process_eio_result with
          | Ok output -> (
              match ensure_graphql_json_response output with
              | Ok _ as success -> success
              | Error "empty response" as process_err ->
                  Printf.eprintf
                    "[Heartbeat] Process_eio curl failed (%s), trying Unix curl fallback...\n%!"
                    (match process_err with Error msg -> msg | _ -> "empty response");
                  (match run_argv_unix argv with
                   | Ok unix_output -> ensure_graphql_json_response unix_output
                   | Error unix_err ->
                       Error
                         (Printf.sprintf "curl(process_eio=empty response; unix=%s)" unix_err))
              | Error msg -> Error msg)
          | Error process_err ->
              Printf.eprintf
                "[Heartbeat] Process_eio curl failed (%s), trying Unix curl fallback...\n%!"
                process_err;
              (match run_argv_unix argv with
               | Ok output -> ensure_graphql_json_response output
               | Error unix_err ->
                   Error
                     (Printf.sprintf "curl(process_eio=%s; unix=%s)" process_err unix_err))))

(** GraphQL request via Cohttp_eio with curl fallback.
    Falls back to curl if Cohttp fails (Railway DNS issues). *)
let graphql_request ?(timeout_sec=5.0) body : (string, string) Stdlib.result =
  let url = graphql_url () in
  let api_key = Sys.getenv_opt "GRAPHQL_API_KEY" |> Option.value ~default:"" in
  let max_response_bytes = 1_000_000 in
  let suppress_body _s = "body suppressed" in
  let cohttp_result = match Eio_context.get_net_opt () with
  | None -> Error "Eio net not initialized"
  | Some net ->
      let headers =
        if api_key = "" then
          Cohttp.Header.of_list [("Content-Type", "application/json")]
        else
          Cohttp.Header.of_list [
            ("Content-Type", "application/json");
            ("Authorization", "Bearer " ^ api_key);
          ]
      in
      let uri = Uri.of_string url in
      let is_https = Uri.scheme uri = Some "https" in
      let run () =
        Eio.Switch.run (fun sw ->
          let client =
            if is_https then
              Cohttp_eio.Client.make ~https:(Some (Eio_context.get_https_connector ())) net
            else
              Cohttp_eio.Client.make ~https:None net
          in
          let body_content = Eio.Flow.string_source body in
          let resp, resp_body =
            Cohttp_eio.Client.post client ~sw uri ~headers ~body:body_content
          in
          let status = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
          let body_str =
            Eio.Buf_read.(parse_exn take_all) resp_body ~max_size:max_response_bytes
          in
          if not (Cohttp.Code.is_success status) then
            Error (Printf.sprintf "HTTP %d (%s)" status (suppress_body body_str))
          else
            ensure_graphql_json_response body_str
        )
      in
      match Eio_context.get_clock_opt () with
      | Some clock ->
          (try Eio.Time.with_timeout_exn clock timeout_sec run
           with exn -> Error (Printexc.to_string exn))
      | None ->
          (try run () with exn -> Error (Printexc.to_string exn))
  in
  match cohttp_result with
  | Ok _ as success -> success
  | Error cohttp_err ->
      Printf.eprintf "[Heartbeat] Cohttp failed (%s), trying curl fallback...\n%!" cohttp_err;
      graphql_request_curl body

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

          let summary = Llm_direct.call_glm ~model:"glm-4.7" ~prompt:summary_prompt ~timeout_sec:60 ~max_chars:2000 () in

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
                   let preferred_hours = Yojson.Safe.Util.(member "preferredHours" node |> to_list |> List.map to_int) in
                   let peak_hour = Yojson.Safe.Util.(member "peakHour" node |> to_int_option) in
                   let traits = Yojson.Safe.Util.(member "traits" node |> to_list |> List.map to_string) in
                   let activity_level =
                     match Yojson.Safe.Util.(member "activityLevel" node) with
                     | `Null -> 0.5
                     | v -> Yojson.Safe.Util.to_float v
                   in
                   let interests =
                     try Yojson.Safe.Util.(member "interests" node |> to_list |> List.map to_string)
                     with Yojson.Safe.Util.Type_error _ | Failure _ -> []
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

let heartbeat_last_skip_reason (result : heartbeat_result) =
  if result.agents_checked = 0 then
    Some "no agents selected for this tick"
  else
    let rec first_reason = function
      | [] -> None
      | (_, _, Passed reason) :: _ | (_, _, Skipped reason) :: _ -> Some reason
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
          match heartbeat_last_skip_reason r with
          | Some reason -> `String reason
          | None -> `Null );
        ("acted_rows", `List acted);
        ("passed_rows", `List passed);
        ("skipped_rows", `List skipped);
        ("checkins", `List (List.map checkin_json r.checkins));
      ]
  in
  let last_skip_reason =
    match s.ls_last_result with
    | Some result -> heartbeat_last_skip_reason result
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
      match last_skip_reason with Some reason -> `String reason | None -> `Null );
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
  let response = Llm_direct.call_glm ~model:"glm-4.7" ~prompt ~timeout_sec:15 ~max_chars:500 () in
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
  with exn ->
    Eio.traceln "   ⚠️ Failed to parse LLM traits response: %s" (Printexc.to_string exn);
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
  let sb = sb_path () in
  let result = Process_eio.run_argv ~timeout_sec:30.0 [sb; "neo4j"; "query"; query] in
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
        (try ignore (Board.create_post store ~author:"ecosystem" ~content:announcement ~ttl_hours:168 ())
         with exn -> Printf.eprintf "[lodge] Board.create_post(ecosystem) failed: %s\n%!" (Printexc.to_string exn))
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
      Eio.traceln "🔄 Loaded %d heartbeat agents" (List.length loaded)
    end else if !agents_cache = [] then begin
      (* First load failed — record time to avoid hammering *)
      agents_cache_time := now;
      Eio.traceln "⚠️ Agent load returned empty, retrying in 30s"
    end
    (* else: keep existing cache on transient failure *)
  end;
  !agents_cache

(** {1 Lodge Agent REST API — Full agent data for dashboard} *)

(** Load all agents with full identity fields for REST API *)
let load_lodge_agents_full () =
  (* first:25 with 6 core fields to stay under GRAPHQL_MAX_COST=2000.
     Returns all 19 agents. Detailed fields (traits, interests, preferredHours)
     available via individual agent queries if needed. *)
  let gql_query = "{\"query\": \"{ agents(first: 25) { edges { node { name emoji koreanName activityLevel status model } } } }\"}" in
  match graphql_request ~timeout_sec:5.0 gql_query with
  | Error err ->
      Error (Printf.sprintf "GraphQL request failed: %s" err)
  | Ok json_str ->
      try
        let json = Yojson.Safe.from_string json_str in
        (match graphql_agents_edges json with
         | Error msg -> Error msg
         | Ok edges ->
             let agents = List.filter_map (fun edge ->
               try
                 let node = Yojson.Safe.Util.member "node" edge in
                 let open Yojson.Safe.Util in
                 let name = member "name" node |> to_string in
                 let emoji = (match member "emoji" node with `String s -> s | _ -> "🤖") in
                 let korean_name = (match member "koreanName" node with `String s -> Some s | _ -> None) in
                 let traits = (try member "traits" node |> to_list |> List.map to_string with exn -> Printf.eprintf "[heartbeat] traits parse: %s\n%!" (Printexc.to_string exn); []) in
                 let interests = (try member "interests" node |> to_list |> List.map to_string with exn -> Printf.eprintf "[heartbeat] interests parse: %s\n%!" (Printexc.to_string exn); []) in
                 let activity_level = (match member "activityLevel" node with `Float f -> f | `Int i -> float_of_int i | _ -> 0.5) in
                 let preferred_hours = (try member "preferredHours" node |> to_list |> List.map to_int with exn -> Printf.eprintf "[heartbeat] preferred_hours parse: %s\n%!" (Printexc.to_string exn); []) in
                 let peak_hour = (match member "peakHour" node with `Int i -> Some i | _ -> None) in
                 let model = (match member "model" node with `String s -> s | _ -> "glm-4.7-flash:latest") in
                 let status = (match member "status" node with `String s -> s | _ -> "active") in
                 let primary_value = (match member "primaryValue" node with `String s -> Some s | _ -> None) in
                 let personality_hint = (match member "personalityHint" node with `String s -> Some s | _ -> None) in
                 Some (`Assoc [
                   ("name", `String name);
                   ("emoji", `String emoji);
                   ("koreanName", match korean_name with Some s -> `String s | None -> `Null);
                   ("traits", `List (List.map (fun s -> `String s) traits));
                   ("interests", `List (List.map (fun s -> `String s) interests));
                   ("activityLevel", `Float activity_level);
                   ("preferredHours", `List (List.map (fun i -> `Int i) preferred_hours));
                   ("peakHour", match peak_hour with Some i -> `Int i | None -> `Null);
                   ("model", `String model);
                   ("status", `String status);
                   ("primaryValue", match primary_value with Some s -> `String s | None -> `Null);
                   ("personalityHint", match personality_hint with Some s -> `String s | None -> `Null);
                 ])
               with Yojson.Safe.Util.Type_error (_, _) -> None
             ) edges in
             Ok (`Assoc [("agents", `List agents)]))
      with e ->
        Error (Printf.sprintf "Failed to load agents: %s" (Printexc.to_string e))

(** Create a new agent via GraphQL mutation (admin API) *)
let create_agent_graphql ~name ~emoji ~korean_name ~traits ~interests
    ~activity_level ~preferred_hours ~peak_hour ~model
    ~personality_hint ~primary_value () =
  let esc s =
    let buf = Buffer.create (String.length s) in
    String.iter (fun c ->
      match c with
      | '"' -> Buffer.add_string buf {|\"|}
      | '\\' -> Buffer.add_string buf {|\\|}
      | '\n' -> Buffer.add_string buf {|\n|}
      | c -> Buffer.add_char buf c
    ) s;
    Buffer.contents buf
  in
  let opt_str key = function
    | Some s -> Printf.sprintf {|, %s: "%s"|} key (esc s)
    | None -> ""
  in
  let opt_int key = function
    | Some i -> Printf.sprintf ", %s: %d" key i
    | None -> ""
  in
  let traits_str = traits |> List.map (fun t -> Printf.sprintf {|"%s"|} (esc t)) |> String.concat ", " in
  let interests_str = interests |> List.map (fun t -> Printf.sprintf {|"%s"|} (esc t)) |> String.concat ", " in
  let hours_str = preferred_hours |> List.map string_of_int |> String.concat ", " in
  let mutation = Printf.sprintf
    {|mutation { createAgent(name: "%s", emoji: "%s"%s, traits: [%s], interests: [%s], activityLevel: %f, preferredHours: [%s]%s, model: "%s"%s%s, status: "active") { success message agent { name emoji koreanName } } }|}
    (esc name) (esc emoji) (opt_str "koreanName" korean_name)
    traits_str interests_str activity_level hours_str
    (opt_int "peakHour" peak_hour) (esc model)
    (opt_str "personalityHint" personality_hint)
    (opt_str "primaryValue" primary_value)
  in
  let gql_body = Yojson.Safe.to_string (`Assoc [("query", `String mutation)]) in
  Printf.eprintf "[Admin] Creating agent '%s' via GraphQL...\n%!" name;
  match graphql_request ~timeout_sec:10.0 gql_body with
  | Error err ->
      Printf.eprintf "[Admin] GraphQL request failed: %s\n%!" err;
      Error err
  | Ok json_str ->
      try
        let json = Yojson.Safe.from_string json_str in
        (match Yojson.Safe.Util.member "errors" json with
         | `List errors when errors <> [] ->
           let msg = try
             List.hd errors |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string
           with Failure _ | Yojson.Safe.Util.Type_error (_, _) -> "unknown error" in
           Printf.eprintf "[Admin] GraphQL error creating agent: %s\n%!" msg;
           Error msg
         | _ ->
           let result = json |> Yojson.Safe.Util.member "data" |> Yojson.Safe.Util.member "createAgent" in
           let success = result |> Yojson.Safe.Util.member "success" |> Yojson.Safe.Util.to_bool in
           if not success then begin
             let msg = result |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string_option |> Option.value ~default:"unknown error" in
             Printf.eprintf "[Admin] GraphQL mutation failed: %s\n%!" msg;
             Error msg
           end else begin
             (* Invalidate heartbeat cache *)
             agents_cache_time := 0.0;
             Printf.eprintf "[Admin] Agent '%s' created successfully\n%!" name;
             let agent = result |> Yojson.Safe.Util.member "agent" in
             match agent with
             | `Null -> Ok (`Assoc [("name", `String name); ("emoji", `String emoji)])
             | a -> Ok a
           end)
      with e ->
        let msg = Printexc.to_string e in
        Printf.eprintf "[Admin] Failed to create agent: %s\n%!" msg;
        Error msg

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

(** Profile cache refreshed from the same GraphQL path used by heartbeat. *)
let profile_cache : (string, agent_profile) Hashtbl.t = Hashtbl.create 16
let profile_cache_ttl = 300.0  (* 5 minutes *)
let profile_cache_time = ref 0.0

let default_agent_profile ~agent_name =
  { name = agent_name; role = None; description = None; traits = [];
    interests = []; preferred_hours = []; peak_hour = None; activity_level = 0.5;
    karma = 0; agent_prompt = None; personality_hint = None }

let profile_of_agent_summary (agent : agent) : agent_profile =
  {
    name = agent.name;
    role = None;
    description = None;
    traits = agent.traits;
    interests = agent.interests;
    preferred_hours = agent.preferred_hours;
    peak_hour = agent.peak_hour;
    activity_level = agent.activity_level;
    karma = 0;
    agent_prompt = None;
    personality_hint = agent.personality_hint;
  }

let load_agent_profiles_from_graphql () : agent_profile list =
  let gql_query =
    "{\"query\": \"{ agents(first: 25) { edges { node { name role description preferredHours traits peakHour activityLevel personalityHint interests } } } }\"}"
  in
  match graphql_request ~timeout_sec:5.0 gql_query with
  | Error _ -> []
  | Ok json_str ->
      try
        let json = Yojson.Safe.from_string json_str in
        match graphql_agents_edges json with
        | Error _ -> []
        | Ok edges ->
            let open Yojson.Safe.Util in
            List.filter_map
              (fun edge ->
                try
                  let node = member "node" edge in
                  let get_string_opt key =
                    match member key node with
                    | `Null -> None
                    | `String s -> Some s
                    | _ -> None
                  in
                  let get_int_opt key =
                    match member key node with
                    | `Null -> None
                    | `Int i -> Some i
                    | _ -> None
                  in
                  Some
                    {
                      name =
                        node |> member "name" |> to_string_option
                        |> Option.value ~default:"";
                      role = get_string_opt "role";
                      description = get_string_opt "description";
                      traits =
                        (try member "traits" node |> to_list |> List.map to_string
                         with Type_error _ -> []);
                      interests =
                        (try member "interests" node |> to_list |> List.map to_string
                         with Type_error _ -> []);
                      preferred_hours =
                        (try member "preferredHours" node |> to_list |> List.map to_int
                         with Type_error _ -> []);
                      peak_hour = get_int_opt "peakHour";
                      activity_level =
                        (match member "activityLevel" node with
                         | `Float f -> f
                         | `Int i -> float_of_int i
                         | _ -> 0.5);
                      karma = 0;
                      agent_prompt = None;
                      personality_hint = get_string_opt "personalityHint";
                    }
                with Type_error _ | Failure _ -> None)
              edges
      with Yojson.Json_error _ -> []

let refresh_profile_cache () =
  let now = Time_compat.now () in
  if now -. !profile_cache_time >= profile_cache_ttl then begin
    Hashtbl.clear profile_cache;
    let profiles = load_agent_profiles_from_graphql () in
    let profiles =
      if profiles <> [] then profiles
      else List.map profile_of_agent_summary (get_agents ())
    in
    List.iter
      (fun profile ->
        if profile.name <> "" then Hashtbl.replace profile_cache profile.name profile)
      profiles;
    profile_cache_time := now
  end

(** Load full agent profile from Neo4j via GraphQL - cached (5 min TTL) *)
let load_agent_profile ~agent_name : agent_profile =
  refresh_profile_cache ();
  match Hashtbl.find_opt profile_cache agent_name with
  | Some profile -> profile
  | None ->
      let fallback =
        match List.find_opt (fun (agent : agent) -> agent.name = agent_name) (get_agents ()) with
        | Some agent -> profile_of_agent_summary agent
        | None -> default_agent_profile ~agent_name
      in
      Hashtbl.replace profile_cache agent_name fallback;
      fallback

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
  let me_root = Env_config.me_root () in
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
    | Some m -> Printf.sprintf "\n\n[관련 기억]\n%s" m
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
  let signature = Lodge_reaction.get_or_compute_signature ~agent_name in
  let static_traits = profile.traits @ profile.interests in
  if signature.total_reactions > 0 || static_traits <> [] then
    Lodge_reaction.generate_identity_prompt signature ~static_traits
  else
    match profile.description with
    | Some d -> d
    | None -> Printf.sprintf "당신은 %s 에이전트입니다." agent_name

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

  (* Build full prompt with accumulated context *)
  let full_prompt = build_prompt_with_context ~name:agent_name ~system_prompt ~user_prompt in

  (* Log context stats *)
  let (tokens, max_tokens, msg_count) = get_context_stats ~name:agent_name in
  Eio.traceln "   📊 [%s] Context: %d/%d tokens (%d msgs)" agent_name tokens max_tokens msg_count;

  (* Direct GLM call for content generation (no llm-mcp dependency) *)
  let raw_response = Llm_direct.call_glm ~model:"glm-4.7" ~prompt:full_prompt ~timeout_sec:30 ~max_chars:300 () in

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

let run_heartbeat_llm_once ?(require_json = false) ~agent_name ~prompt () =
  let models = Lodge_cascade.get_cascade ~cascade_name:"heartbeat_action" () in
  let heartbeat_max_tokens = 1200 in
  let started_at = Time_compat.now () in
  let result =
    if models = [] then (
      Printf.printf
        "   ⚠️ [%s] No heartbeat model pool available, skipping\n%!" agent_name;
      Error "no heartbeat model pool available")
    else
      Llm_client.run_prompt_cascade ~timeout_sec:60
        ~accept:(heartbeat_response_accepted ~require_json)
        ~model_specs:models ~max_tokens:heartbeat_max_tokens ~prompt ()
  in
  let duration_ms =
    int_of_float ((Time_compat.now () -. started_at) *. 1000.0)
  in
  match result with
  | Ok resp ->
      {
        Lodge_cascade.response = resp.content;
        llm_used = resp.model_used;
        duration_ms;
      }
  | Error err ->
      Printf.printf "   ❌ [%s] Heartbeat cascade failed: %s\n%!" agent_name err;
      { Lodge_cascade.response = ""; llm_used = "none"; duration_ms }

let run_heartbeat_llm_traced ?(require_json = false) ~agent_name ~phase ~prompt () =
  let tick_id =
    Printf.sprintf "%s-%d" agent_name
      (int_of_float (Time_compat.now () *. 1000.0) mod 1000000)
  in
  let cascade_result =
    run_heartbeat_llm_once ~require_json ~agent_name ~prompt ()
  in
  save_trace
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
      ~require_json:true ~agent_name ~phase:"lodge_tool_assignment" ~prompt ()
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
      ~require_json:true ~agent_name ~phase:"lodge_decision" ~prompt ()
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
        (Eio.traceln "   ⏳ [%s] POST rate-limited (30min gap / %d/day max)" agent_name max_posts_per_day;
         Skipped "post_rate_limited")
      else if is_duplicate_post ~agent_name ~content then
        (Eio.traceln "   🔄 [%s] Similar post already exists, skipping to avoid repetition" agent_name;
         Passed "duplicate_post")
      else begin
        let vr = Post_verifier.verify ~content in
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
        (Eio.traceln "   ⏳ [%s] COMMENT rate-limited (20s gap / %d/day max)" agent_name max_comments_per_day;
         Skipped "comment_rate_limited")
      else if not (can_agent_comment ~agent_name ~post_id) then
        (Eio.traceln "   🚫 [%s] Already commented %d times on %s, skipping" agent_name max_comments_per_agent_per_post post_id;
         Skipped "comment_limit_reached")
      else begin
        let vr = Post_verifier.verify ~content in
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
    (run_heartbeat_llm_once ~agent_name ~prompt ()).Lodge_cascade.response

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

(** {1 Broadcast Content-Aware Routing}

    브로드캐스트 내용을 분석하여 관련 있는 에이전트에게 알림.
    키워드 매칭 + LLM 기반 의미 분석으로 라우팅.

    @since 2.32.0
*)

(** Load agent specialties dynamically from Neo4j *)
let load_agent_specialties_from_neo4j () =
  let query = "MATCH (a:Agent) WHERE a.traits IS NOT NULL RETURN a.name, a.traits, a.description" in
  let sb = sb_path () in
  let json_str = Process_eio.run_argv ~timeout_sec:30.0 [sb; "neo4j"; "query"; query] in
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
  let response = Llm_direct.call_glm ~model:"glm-4.7" ~prompt ~timeout_sec:15 ~max_chars:500 () in
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
    (try ignore (handle_broadcast ~sender ~content:post.content)
     with exn -> Printf.eprintf "[lodge] handle_broadcast(%s) failed: %s\n%!" sender (Printexc.to_string exn))
  );
  Time_compat.now ()  (* Return new timestamp for next poll *)
