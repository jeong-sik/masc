(** Sentinel — MASC default resident agent.

    Ensures at least one agent is always alive when the server runs.
    Integrates Guardian's zombie/gc consumers and adds:
    - Self-heartbeat (room presence)
    - Board patrol (stale post detection, daily status) — LLM-driven
    - Task hygiene (orphaned/stuck task warnings) — LLM-driven
    - Keeper health monitoring — LLM-driven

    LLM judgment layer via Prompt_registry + Lodge_cascade.
    When LLM is unavailable, judgment consumers skip silently.

    Opt-out via MASC_SENTINEL_ENABLED=false.
    LLM layer opt-out via MASC_SENTINEL_LLM_ENABLED=false. *)

open Printf

let agent_name = "sentinel"

let log msg =
  eprintf "[sentinel] %s\n%!" msg

(** Parse ISO 8601 timestamp to float; returns epoch (0.0) on failure
    so that unparseable timestamps are treated as maximally stale. *)
let parse_iso_or_epoch s =
  Resilience.Time.parse_iso8601_opt s |> Option.value ~default:0.0

(* ── LLM Helper ───────────────────────────────────────────── *)

(** Try to parse a JSON value from an LLM response string.
    Handles both raw JSON and markdown code-fenced JSON. *)
let parse_llm_json_safe s =
  try Some (Yojson.Safe.from_string s)
  with Yojson.Json_error _ ->
    let re = Str.regexp "```\\(json\\)?[\n\r]+\\([^`]+\\)```" in
    if Str.string_match re s 0 then
      (try Some (Yojson.Safe.from_string (Str.matched_group 2 s))
       with _ -> None)
    else None

(** Call sentinel LLM via cascade: render prompt from registry, run through
    model specs from Lodge_cascade. Returns parsed JSON or None on failure. *)
let call_sentinel_llm ~cascade_name ~prompt_id ~vars () =
  if not Env_config.Sentinel.llm_enabled then None
  else
    match Prompt_registry.render ~id:prompt_id ~vars () with
    | Error msg ->
        log (sprintf "prompt %s render failed: %s" prompt_id msg);
        None
    | Ok prompt ->
        let timeout = Env_config.Sentinel.llm_timeout_sec in
        (match Lodge_cascade.call ~cascade_name ~prompt
            ~temperature:0.3 ~timeout_sec:timeout ~max_tokens:800 () with
        | Ok r when String.length r.response > 5 ->
            log (sprintf "LLM response from %s (%d chars)" r.llm_used
                   (String.length r.response));
            parse_llm_json_safe r.response
        | Ok r ->
            log (sprintf "LLM response too short from %s" r.llm_used);
            None
        | Error err ->
            log (sprintf "LLM cascade %s failed: %s" cascade_name err);
            None)

(* ── Sentinel-specific Pulse Consumers ─────────────────────── *)

(** Heartbeat consumer: keeps sentinel visible in the room. *)
let make_heartbeat_consumer config : (module Pulse.Consumer) =
  (module struct
    let name = "sentinel-heartbeat"
    let should_act _beat = true
    let on_beat _beat =
      try
        let _msg = Room.heartbeat config ~agent_name in
        Ok ()
      with exn ->
        let msg = sprintf "heartbeat failed: %s" (Printexc.to_string exn) in
        log msg;
        Error msg
  end)

(** Board patrol consumer: posts a daily status summary via LLM.
    Skips posting when LLM is unavailable. *)
let make_board_patrol_consumer config : (module Pulse.Consumer) =
  let last_daily_post = ref 0 in (* day-of-year of last post *)
  (module struct
    let name = "sentinel-board-patrol"
    let should_act _beat = true
    let on_beat _beat =
      try
        let state = Room.read_state config in
        let tm = Unix.localtime (Time_compat.now ()) in
        let today = tm.Unix.tm_yday in
        if today <> !last_daily_post then begin
          last_daily_post := today;
          let agent_names = String.concat ", " state.active_agents in
          let board_posts = (try Board_dispatch.list_posts ~limit:50 ()
                             with _ -> []) in
          let post_count = List.length board_posts in
          let now_f = Time_compat.now () in
          let stale_posts = List.filter (fun (p : Board.post) ->
            now_f -. p.created_at > 604800.0 (* 7 days *)
          ) board_posts |> List.length in
          let latest_age = match board_posts with
            | p :: _ -> sprintf "%.0fs" (now_f -. p.created_at)
            | [] -> "no posts"
          in
          let llm_content = call_sentinel_llm
            ~cascade_name:"sentinel_board"
            ~prompt_id:"sentinel-board-patrol"
            ~vars:[
              ("total_posts", string_of_int post_count);
              ("stale_count", string_of_int stale_posts);
              ("latest_post_age", latest_age);
              ("active_agents", agent_names);
            ] () in
          match llm_content with
          | Some json ->
              let open Yojson.Safe.Util in
              let summary = json |> member "daily_summary" |> to_string_option
                            |> Option.value ~default:"" in
              if String.length summary > 10 then begin
                let content = sprintf "[Sentinel Daily] %s" summary in
                (match Board_dispatch.create_post
                         ~author:agent_name ~content
                         ~visibility:Board.Internal
                         ~hearth:"sentinel" () with
                 | Ok _post -> log "daily status posted"
                 | Error e -> log (sprintf "daily post failed: %s" (Board.show_board_error e)))
              end else
                log "LLM summary too short, skipping daily post"
          | None ->
              log "LLM unavailable, skipping daily post"
        end;
        Ok ()
      with exn ->
        let msg = sprintf "board patrol failed: %s" (Printexc.to_string exn) in
        log msg;
        Error msg
  end)

(** Task hygiene consumer: detects orphaned/stuck tasks via LLM assessment.
    Skips warnings when LLM is unavailable. *)
let make_task_hygiene_consumer config : (module Pulse.Consumer) =
  (module struct
    let name = "sentinel-task-hygiene"
    let should_act _beat = true
    let on_beat _beat =
      try
        let backlog = Room.read_backlog config in
        let now_f = Time_compat.now () in
        let stuck_threshold = Env_config.Sentinel.task_stuck_threshold_sec in
        let stale_threshold = Env_config.Sentinel.task_stale_threshold_sec in

        (* Collect candidate stuck/stale tasks *)
        let candidates = ref [] in
        List.iter (fun (t : Types.task) ->
          match t.task_status with
          | Types.Claimed { assignee; claimed_at } ->
              let is_alive = Room.is_agent_joined config ~agent_name:assignee in
              let age = now_f -. (parse_iso_or_epoch claimed_at) in
              if (not is_alive) || age > stuck_threshold then
                candidates := (t.id, assignee, age, is_alive, "claimed") :: !candidates
          | Types.InProgress { assignee; started_at } ->
              let age = now_f -. (parse_iso_or_epoch started_at) in
              if age > stale_threshold then
                candidates := (t.id, assignee, age, true, "in_progress") :: !candidates
          | _ -> ()
        ) backlog.tasks;

        if !candidates <> [] then begin
          (* Build task list string for LLM *)
          let task_lines = List.map (fun (id, assignee, age, alive, status) ->
            sprintf "- %s: %s by %s, %.0fs ago, agent_alive=%b"
              id status assignee age alive
          ) !candidates in
          let task_list_str = String.concat "\n" task_lines in

          (* LLM-first: let LLM assess each task *)
          let llm_result = call_sentinel_llm
            ~cascade_name:"sentinel_task"
            ~prompt_id:"sentinel-task-hygiene"
            ~vars:[("task_list", task_list_str)] () in

          let warnings = match llm_result with
            | Some (`List items) ->
                log (sprintf "task hygiene LLM assessed %d tasks" (List.length items));
                List.filter_map (fun item ->
                  let open Yojson.Safe.Util in
                  let action = item |> member "action" |> to_string_option
                               |> Option.value ~default:"ignore" in
                  if action = "ignore" then None
                  else
                    let task_id = item |> member "task_id" |> to_string_option
                                  |> Option.value ~default:"?" in
                    let reason = item |> member "reason" |> to_string_option
                                 |> Option.value ~default:"" in
                    let priority = item |> member "priority" |> to_string_option
                                   |> Option.value ~default:"medium" in
                    Some (sprintf "task %s: %s [%s] %s" task_id action priority reason)
                ) items
            | _ ->
                log (sprintf "%d candidate stuck tasks, LLM unavailable — skipping"
                  (List.length !candidates));
                []
          in

          if warnings <> [] then begin
            let msg = sprintf "[sentinel] %d task warning(s): %s"
              (List.length warnings) (String.concat "; " warnings) in
            log msg;
            Sse.broadcast (`Assoc [
              ("type", `String "sentinel_warning");
              ("source", `String agent_name);
              ("warnings", `List (List.map (fun w -> `String w) warnings));
              ("ts", `String (Types.now_iso ()));
            ])
          end
        end;
        Ok ()
      with exn ->
        let msg = sprintf "task hygiene failed: %s" (Printexc.to_string exn) in
        log msg;
        Error msg
  end)

(** Keeper health consumer: detects stale keepers via LLM assessment.
    Skips action when LLM is unavailable. *)
let make_keeper_health_consumer _config : (module Pulse.Consumer) =
  (module struct
    let name = "sentinel-keeper-health"
    let should_act _beat = true
    let on_beat _beat =
      try
        (* Read keeper meta directory for stale entries *)
        let keepers_dir =
          match Env_config.me_root_opt () with
          | Some root -> Filename.concat root ".masc/keepers"
          | None -> ".masc/keepers"
        in
        if Sys.file_exists keepers_dir && Sys.is_directory keepers_dir then begin
          let now_f = Time_compat.now () in
          let threshold = Env_config.KeeperBootstrap.stale_turn_seconds in
          let stale = ref [] in
          Sys.readdir keepers_dir |> Array.iter (fun name ->
            if Filename.check_suffix name ".json" then begin
              let path = Filename.concat keepers_dir name in
              try
                let json = Yojson.Safe.from_file path in
                (match Yojson.Safe.Util.member "last_turn_at" json with
                 | `String ts ->
                     let last = parse_iso_or_epoch ts in
                     let age = now_f -. last in
                     if age > threshold then
                       stale := (Filename.chop_suffix name ".json", age) :: !stale
                 | _ -> ())
              with _ -> ()
            end
          );
          if !stale <> [] then begin
            (* Build keeper list for LLM *)
            let keeper_lines = List.map (fun (k, age) ->
              sprintf "- %s: last active %.0fs ago (threshold=%.0fs)"
                k age threshold
            ) !stale in
            let keeper_list_str = String.concat "\n" keeper_lines in

            (* LLM-first: let LLM assess each stale keeper *)
            let llm_result = call_sentinel_llm
              ~cascade_name:"sentinel_keeper"
              ~prompt_id:"sentinel-keeper-health"
              ~vars:[("keeper_list", keeper_list_str)] () in

            match llm_result with
            | Some (`List items) ->
                log (sprintf "keeper health LLM assessed %d keepers" (List.length items));
                List.iter (fun item ->
                  let open Yojson.Safe.Util in
                  let keeper = item |> member "keeper" |> to_string_option
                               |> Option.value ~default:"?" in
                  let action = item |> member "action" |> to_string_option
                               |> Option.value ~default:"ignore" in
                  let reason = item |> member "reason" |> to_string_option
                               |> Option.value ~default:"" in
                  if action <> "ignore" then
                    log (sprintf "keeper %s: %s — %s" keeper action reason)
                ) items
            | _ ->
                log (sprintf "%d stale keeper(s) detected, LLM unavailable — skipping"
                  (List.length !stale))
          end
        end;
        Ok ()
      with exn ->
        let msg = sprintf "keeper health failed: %s" (Printexc.to_string exn) in
        log msg;
        Error msg
  end)

(* ── Status ────────────────────────────────────────────────── *)

let started = ref false
let start_ts : float ref = ref 0.0

let reset_runtime_state_for_tests () =
  started := false;
  start_ts := 0.0

let mark_started_for_tests () =
  started := true;
  start_ts := Time_compat.now ()

let status_json () : Yojson.Safe.t =
  let embedded_guardian_loops_running = Guardian.masc_loops_running () in
  let consumers =
    [
      `String "sentinel-heartbeat";
    ]
    @
    (if embedded_guardian_loops_running then
       [ `String "guardian-zombie"; `String "guardian-gc" ]
     else [])
    @
    [
      `String "sentinel-board-patrol";
      `String "sentinel-task-hygiene";
      `String "sentinel-keeper-health";
    ]
  in
  `Assoc [
    ("enabled", `Bool Env_config.Sentinel.enabled);
    ("started", `Bool !started);
    ("agent_name", `String agent_name);
    ("llm_enabled", `Bool Env_config.Sentinel.llm_enabled);
    ("uptime_s", `Float (if !started then Time_compat.now () -. !start_ts else 0.0));
    ("embedded_guardian_loops_running", `Bool embedded_guardian_loops_running);
    ("guardian_runtime_owner", `String (Guardian.masc_runtime_owner_label ()));
    ("consumers", `List consumers);
  ]

(* ── Start ─────────────────────────────────────────────────── *)

let start ~sw ~clock ~net config =
  if not Env_config.Sentinel.enabled then
    log "disabled (set MASC_SENTINEL_ENABLED=true)"
  else begin
    (* 1. Join room as sentinel agent *)
    let join_result = Room.join config ~agent_name ~capabilities:["sentinel"; "housekeeping"] () in
    log (sprintf "join: %s" (String.sub join_result 0 (min 80 (String.length join_result))));

    (* 2. Heartbeat pulse (30s) *)
    let p_hb = Pulse.create
      ~clock
      ~rhythm:(Guardian.fixed_rhythm Env_config.Sentinel.heartbeat_interval_sec)
      ~lifecycle:Perpetual
      ~consumers:[make_heartbeat_consumer config]
    in
    Pulse.run ~sw p_hb;

    (* 3. Embedded guardian masc loops: zombie + gc stay under sentinel ownership. *)
    Guardian.start_embedded_masc_loops ~sw ~clock config;

    (* 4. Board patrol (10min) *)
    let p_board = Pulse.create
      ~clock
      ~rhythm:(Guardian.fixed_rhythm Env_config.Sentinel.board_patrol_interval_sec)
      ~lifecycle:Perpetual
      ~consumers:[make_board_patrol_consumer config]
    in
    Pulse.run ~sw p_board;

    (* 5. Task hygiene + Keeper health (5min) *)
    let p_ops = Pulse.create
      ~clock
      ~rhythm:(Guardian.fixed_rhythm Env_config.Sentinel.task_hygiene_interval_sec)
      ~lifecycle:Perpetual
      ~consumers:[
        make_task_hygiene_consumer config;
        make_keeper_health_consumer config;
      ]
    in
    Pulse.run ~sw p_ops;

    started := true;
    start_ts := Time_compat.now ();
    ignore net;  (* net reserved for future HTTP-based health checks *)
    log "started (heartbeat, embedded zombie/gc, board-patrol, task-hygiene, keeper-health)"
  end
