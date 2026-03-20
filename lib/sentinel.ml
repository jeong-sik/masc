(** Sentinel — MASC default resident agent (OAS-integrated).

    Ensures at least one agent is always alive when the server runs.
    Integrates Guardian's zombie/gc consumers and adds:
    - Self-heartbeat (room presence)
    - Board patrol (stale post detection, action-only notices) — LLM-driven
    - Task hygiene (orphaned/stuck task warnings) — LLM-driven
    - Keeper health monitoring — LLM-driven

    LLM judgment layer via Prompt_registry + Oas_worker cascade.
    When LLM is unavailable, judgment consumers skip silently.

    OAS integration: exports Agent Card, publishes events via Event_bus.

    Opt-out via MASC_SENTINEL_ENABLED=false.
    LLM layer opt-out via MASC_SENTINEL_LLM_ENABLED=false. *)

open Printf

let agent_name = "sentinel"

(* ── OAS Agent Card ──────────────────────────────────────── *)

let agent_card : Agent_card.agent_card = {
  name = "sentinel";
  version = "2.101.0";
  description = Some "Default resident agent: heartbeat, board patrol, task hygiene, keeper health";
  provider = Some { organization = "MASC"; url = None };
  protocol_versions = ["0.3"];
  capabilities = { streaming = false; push_notifications = false; extended_agent_card = false };
  skills = [
    { id = "heartbeat"; name = "Heartbeat";
      description = Some "Keep sentinel visible in the room";
      tags = ["monitoring"]; tool_count = 0;
      input_modes = []; output_modes = ["application/json"] };
    { id = "board-patrol"; name = "Board Patrol";
      description = Some "LLM-driven stale post detection";
      tags = ["monitoring"]; tool_count = 0;
      input_modes = []; output_modes = ["application/json"] };
    { id = "task-hygiene"; name = "Task Hygiene";
      description = Some "LLM-driven orphaned/stuck task detection";
      tags = ["monitoring"]; tool_count = 0;
      input_modes = []; output_modes = ["application/json"] };
    { id = "keeper-health"; name = "Keeper Health";
      description = Some "LLM-driven stale keeper monitoring";
      tags = ["monitoring"]; tool_count = 0;
      input_modes = []; output_modes = ["application/json"] };
  ];
  supported_interfaces = [];
  security_schemes = [];
  default_input_modes = ["application/json"];
  default_output_modes = ["application/json"];
  extensions = [];
  signatures = [];
  icon_url = None;
  documentation_url = None;
  created_at = "2026-03-16T00:00:00Z";
  updated_at = "2026-03-16T00:00:00Z";
}

(* ── Event_bus ref ───────────────────────────────────────── *)

let bus_ref : Agent_sdk.Event_bus.t option ref = ref None

let publish_event name payload =
  match !bus_ref with
  | Some bus ->
      Agent_sdk.Event_bus.publish bus
        (Agent_sdk.Event_bus.Custom (name, payload))
  | None -> ()

let log_debug msg = Log.Sentinel.debug "%s" msg
let log_info msg = Log.Sentinel.info "%s" msg
let log_warn msg = Log.Sentinel.warn "%s" msg

type board_patrol_decision = {
  needs_attention : bool;
  reason : string option;
  board_post : string option;
}

let last_board_patrol_checked_at : float ref = ref 0.0
let last_board_patrol_action : string ref = ref "none"
let last_board_patrol_reason : string ref = ref ""
let last_board_patrol_stale_count : int ref = ref 0

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
       with
       | Yojson.Json_error _ -> None
       | exn ->
           Log.Sentinel.warn "parse_llm_json_safe fenced block: %s" (Printexc.to_string exn);
           None)
    else None

(** Call sentinel LLM via cascade: render prompt from registry, run through
    model specs from Oas_worker cascade. Returns parsed JSON or None on failure. *)
let call_sentinel_llm ~cascade_name ~prompt_id ~vars () =
  if not Env_config.Sentinel.llm_enabled then None
  else
    match Prompt_registry.render ~id:prompt_id ~vars () with
    | Error msg ->
        log_warn (sprintf "prompt %s render failed: %s" prompt_id msg);
        None
    | Ok prompt ->
        let _timeout = Env_config.Sentinel.llm_timeout_sec in
        (match Oas_worker.run_named ~cascade_name
            ~goal:prompt ~max_turns:1
            ~temperature:0.3 ~max_tokens:800 () with
        | Ok result ->
            let resp = result.Oas_worker.response in
            let text = Llm_provider.Types.text_of_response resp in
            let model = resp.Llm_provider.Types.model in
            if String.length text > 5 then (
              log_debug (sprintf "LLM response from %s (%d chars)" model
                     (String.length text));
              parse_llm_json_safe text)
            else (
              log_warn (sprintf "LLM response too short from %s" model);
              None)
        | Error err ->
            log_warn (sprintf "LLM cascade %s failed: %s" cascade_name err);
            None)

let trimmed_string_option = function
  | Some value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | None -> None

let iso_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let json_string_of_nonempty value =
  let trimmed = String.trim value in
  if trimmed = "" then `Null else `String trimmed

let board_patrol_decision_of_llm_json (json : Yojson.Safe.t) : board_patrol_decision =
  let open Yojson.Safe.Util in
  {
    needs_attention =
      (json |> member "needs_attention" |> to_bool_option)
      |> Option.value ~default:false;
    reason =
      json |> member "reason" |> to_string_option |> trimmed_string_option;
    board_post =
      json |> member "board_post" |> to_string_option |> trimmed_string_option;
  }

let note_board_patrol_result_for_tests ?checked_at ~action ?reason ?(stale_count = 0) () =
  last_board_patrol_checked_at := Option.value ~default:(Time_compat.now ()) checked_at;
  last_board_patrol_action := action;
  last_board_patrol_reason := Option.value ~default:"" reason;
  last_board_patrol_stale_count := stale_count

let board_patrol_state_path (config : Room_utils.config) =
  Filename.concat (Filename.concat config.base_path ".masc")
    "sentinel_board_patrol_state.json"

let board_patrol_day_key_of_unix ts =
  let tm = Unix.localtime ts in
  sprintf "%04d-%03d" (tm.Unix.tm_year + 1900) tm.Unix.tm_yday

let read_board_patrol_day_key_for_tests (config : Room_utils.config) =
  let json = Room_utils.read_json_local (board_patrol_state_path config) in
  json
  |> Yojson.Safe.Util.member "last_daily_post_day"
  |> Yojson.Safe.Util.to_string_option
  |> trimmed_string_option

let write_board_patrol_day_key_for_tests (config : Room_utils.config) day_key =
  Room_utils.write_json_local
    (board_patrol_state_path config)
    (`Assoc [ ("last_daily_post_day", `String day_key) ])

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
        log_warn msg;
        Error msg
  end)

(** Board patrol consumer: posts a daily status summary via LLM.
    Skips posting when LLM is unavailable. *)
let make_board_patrol_consumer config : (module Pulse.Consumer) =
  let last_daily_post = ref (read_board_patrol_day_key_for_tests config) in
  let record_result ~checked_at ~action ?reason ~stale_count () =
    note_board_patrol_result_for_tests ~checked_at ~action ?reason ~stale_count ()
  in
  (module struct
    let name = "sentinel-board-patrol"
    let should_act _beat = true
    let on_beat _beat =
      try
        let state = Room.read_state config in
        let now_f = Time_compat.now () in
        let today_key = board_patrol_day_key_of_unix now_f in
        if Some today_key <> !last_daily_post then begin
          last_daily_post := Some today_key;
          (try write_board_patrol_day_key_for_tests config today_key
           with exn ->
             log_warn
               (sprintf "board patrol state persist failed: %s"
                  (Printexc.to_string exn)));
          let agent_names = String.concat ", " state.active_agents in
          let board_posts = (try Board_dispatch.list_posts ~limit:50 ()
                             with exn ->
                               Log.Sentinel.warn "board patrol list_posts: %s" (Printexc.to_string exn);
                               []) in
          let post_count = List.length board_posts in
          let stale_posts = List.filter (fun (p : Board.post) ->
            now_f -. p.created_at > 604800.0 (* 7 days *)
          ) board_posts |> List.length in
          let latest_age = match board_posts with
            | p :: _ -> sprintf "%.0fs" (now_f -. p.created_at)
            | [] -> "no posts"
          in
          if stale_posts = 0 then begin
            record_result ~checked_at:now_f ~action:"silent"
              ?reason:(Some "no stale posts over 7d") ~stale_count:stale_posts ();
            log_debug "no stale posts, skipping board patrol post"
          end else begin
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
                let decision = board_patrol_decision_of_llm_json json in
                if not decision.needs_attention then begin
                  record_result ~checked_at:now_f ~action:"silent"
                    ?reason:decision.reason ~stale_count:stale_posts ();
                  log_debug "board patrol decided no operator-visible action is needed"
                end else
                  (match decision.board_post with
                   | Some summary when String.length summary > 10 ->
                       let content = sprintf "[Sentinel] %s" summary in
                       (match Board_dispatch.create_post
                                ~author:agent_name ~content
                                ~post_kind:Board.System_post
                                ~visibility:Board.Internal
                                ~hearth:"sentinel" () with
                        | Ok _post ->
                            publish_event "masc:sentinel:board_patrol"
                              (`Assoc [
                                ("agent_name", `String agent_name);
                                ("action", `String "posted");
                                ("stale_count", `Int stale_posts);
                                ("reason", match decision.reason with Some r -> `String r | None -> `Null);
                                ("timestamp", `Float now_f);
                              ]);
                            record_result ~checked_at:now_f ~action:"posted"
                              ?reason:decision.reason ~stale_count:stale_posts ();
                            log_info "board patrol attention posted"
                        | Error e ->
                            let reason = Board.show_board_error e in
                            record_result ~checked_at:now_f ~action:"post_failed"
                              ?reason:(Some reason) ~stale_count:stale_posts ();
                            log_warn (sprintf "board patrol post failed: %s" reason))
                   | _ ->
                       record_result ~checked_at:now_f ~action:"suppressed"
                         ?reason:(Some "needs_attention=true but board_post was empty")
                         ~stale_count:stale_posts ();
                       log_debug "board patrol attention requested but board_post was empty; suppressing")
            | None ->
                record_result ~checked_at:now_f ~action:"llm_unavailable"
                  ?reason:(Some "sentinel_board cascade unavailable") ~stale_count:stale_posts ();
                log_debug "LLM unavailable, skipping board patrol post"
          end
        end;
        Ok ()
      with exn ->
        let msg = sprintf "board patrol failed: %s" (Printexc.to_string exn) in
        log_warn msg;
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

          let orphan_count = List.length (List.filter (fun (_, _, _, alive, _) -> not alive) !candidates) in
          let stuck_count = List.length !candidates - orphan_count in

          (* LLM-first: let LLM assess each task *)
          let llm_result = call_sentinel_llm
            ~cascade_name:"sentinel_task"
            ~prompt_id:"sentinel-task-hygiene"
            ~vars:[("task_list", task_list_str)] () in

          (match llm_result with
           | Some (`List items) ->
               log_debug
                 (sprintf "task hygiene LLM assessed %d tasks" (List.length items));
               let warnings = ref [] in
               let reassigned = ref 0 in
               List.iter
                 (fun item ->
                   let open Yojson.Safe.Util in
                   let action =
                     item |> member "action" |> to_string_option
                     |> Option.value ~default:"ignore"
                   in
                   let task_id =
                     item |> member "task_id" |> to_string_option
                     |> Option.value ~default:"?"
                   in
                   let reason =
                     item |> member "reason" |> to_string_option
                     |> Option.value ~default:""
                   in
                   let priority =
                     item |> member "priority" |> to_string_option
                     |> Option.value ~default:"medium"
                   in
                   match action with
                   | "ignore" -> ()
                   | "reassign" -> (
                       match
                         Room.force_release_task_r config ~agent_name ~task_id ()
                       with
                       | Ok _msg ->
                           incr reassigned;
                           Log.Sentinel.info "auto-released %s → todo (%s)" task_id
                             reason;
                           Sse.broadcast
                             (`Assoc
                               [
                                 ("type", `String "sentinel_auto_reassign");
                                 ("source", `String agent_name);
                                 ("task_id", `String task_id);
                                 ("reason", `String reason);
                                 ("priority", `String priority);
                                 ("ts", `String (Types.now_iso ()));
                               ])
                       | Error e ->
                           log_debug
                             (sprintf "auto-release %s skipped: %s" task_id
                                (Types.masc_error_to_string e)))
                   | _ ->
                       warnings :=
                         sprintf "task %s: %s [%s] %s" task_id action priority
                           reason
                         :: !warnings)
                 items;
               let all_warnings = List.rev !warnings in
               if all_warnings <> [] then begin
                 Log.Sentinel.warn "%d task warning(s)"
                   (List.length all_warnings);
                 List.iter (fun w -> Log.Sentinel.warn "  %s" w) all_warnings;
                 Sse.broadcast
                   (`Assoc
                     [
                       ("type", `String "sentinel_warning");
                       ("source", `String agent_name);
                       ( "warnings",
                         `List (List.map (fun w -> `String w) all_warnings) );
                       ("ts", `String (Types.now_iso ()));
                     ])
               end;
               publish_event "masc:sentinel:task_hygiene"
                 (`Assoc [
                   ("agent_name", `String agent_name);
                   ("orphan_count", `Int orphan_count);
                   ("stuck_count", `Int stuck_count);
                   ("reassigned", `Int !reassigned);
                   ("timestamp", `Float (Time_compat.now ()));
                 ])
           | _ ->
               log_debug
                 (sprintf "%d candidate stuck tasks, LLM unavailable — skipping"
                    (List.length !candidates)))
        end;
        Ok ()
      with exn ->
        let msg = sprintf "task hygiene failed: %s" (Printexc.to_string exn) in
        log_warn msg;
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
                let json = Safe_ops.read_json_eio path in
                (match Yojson.Safe.Util.member "last_turn_at" json with
                 | `String ts ->
                     let last = parse_iso_or_epoch ts in
                     let age = now_f -. last in
                     if age > threshold then
                       stale := (Filename.chop_suffix name ".json", age) :: !stale
                 | _ -> ())
              with
              | Yojson.Json_error _ | Sys_error _ -> ()
              | exn ->
                  Log.Sentinel.warn "keeper stale check %s: %s" name (Printexc.to_string exn)
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
                log_debug (sprintf "keeper health LLM assessed %d keepers" (List.length items));
                List.iter (fun item ->
                  let open Yojson.Safe.Util in
                  let keeper = item |> member "keeper" |> to_string_option
                               |> Option.value ~default:"?" in
                  let action = item |> member "action" |> to_string_option
                               |> Option.value ~default:"ignore" in
                  let reason = item |> member "reason" |> to_string_option
                               |> Option.value ~default:"" in
                  if action <> "ignore" then
                    log_warn (sprintf "keeper %s: %s — %s" keeper action reason)
                ) items
            | _ ->
                log_debug (sprintf "%d stale keeper(s) detected, LLM unavailable — skipping"
                  (List.length !stale))
          end
        end;
        Ok ()
      with exn ->
        let msg = sprintf "keeper health failed: %s" (Printexc.to_string exn) in
        log_warn msg;
        Error msg
  end)

(** Governance sweep consumer: detects stuck tasks and keeper failures,
    then auto-generates governance petitions via Governance_v2.
    No LLM dependency — purely data-driven threshold checks. *)
let make_governance_sweep_consumer config : (module Pulse.Consumer) =
  (module struct
    let name = "sentinel-governance-sweep"
    let should_act _beat = Env_config.Sentinel.governance_enabled
    let on_beat _beat =
      try
        let base_path = config.Room_utils.base_path in
        let now_f = Time_compat.now () in
        let petitions_created = ref 0 in
        (* Track titles already submitted to avoid duplicate petitions per sweep *)
        let submitted_keys : (string, unit) Hashtbl.t = Hashtbl.create 8 in
        let submit ~title ~subject_type ~risk_class ?target_id ?requested_action
            ?(source_refs=[]) () =
          (* Dedup within a single sweep: skip if we already submitted this title *)
          if Hashtbl.mem submitted_keys title then ()
          else begin
          Hashtbl.replace submitted_keys title ();
          let action : Council.Governance_v2.action_request option =
            match requested_action with
            | Some _ -> requested_action
            | None ->
                match subject_type with
                | "task" ->
                    Some
                      {
                        action_type = "release_task";
                        target_type = Some "task";
                        target_id;
                        payload = None;
                      }
                | "keeper" ->
                    Some
                      {
                        action_type = "restart_keeper";
                        target_type = Some "keeper";
                        target_id;
                        payload = None;
                      }
                | "board_post" ->
                    Some
                      {
                        action_type = "flag_post";
                        target_type = Some "board_post";
                        target_id;
                        payload = None;
                      }
                | _ -> None
          in
          match Council.Governance_v2.submit_petition base_path
            ~title ~origin:"sentinel" ~subject_type ~risk_class
            ~requested_action:action ~source_refs ~created_by:agent_name with
          | Ok result ->
              incr petitions_created;
              (* Auto-submit brief for new cases to unblock ruling pipeline *)
              if not result.merged then begin
                match Council.Governance_v2.submit_brief base_path
                  ~case_id:result.case_.id
                  ~author:agent_name
                  ~stance:Council.Governance_v2.Support
                  ~summary:"Automated: threshold exceeded, conditions confirmed by sentinel sweep"
                  ~evidence_refs:["sentinel_threshold_check"] with
                | Ok _case ->
                    log_info (sprintf "governance auto-brief submitted for case %s"
                      result.case_.id)
                | Error msg ->
                    log_warn (sprintf "governance auto-brief failed for case %s: %s"
                      result.case_.id msg)
              end;
              let merged_label = if result.merged then " (merged)" else " (new + auto-brief)" in
              log_info (sprintf "governance petition: %s -> case %s%s"
                title result.case_.id merged_label)
          | Error msg ->
              log_warn (sprintf "governance petition failed: %s -- %s" title msg)
          end
        in

        (* 1. Tasks stuck > threshold (default 24h) *)
        let stuck_threshold = Env_config.Sentinel.governance_task_stuck_sec in
        let backlog = Room.read_backlog config in
        List.iter (fun (t : Types.task) ->
          match t.task_status with
          | Types.Claimed { assignee; claimed_at } ->
              let age = now_f -. (parse_iso_or_epoch claimed_at) in
              if age > stuck_threshold then begin
                log_debug (sprintf "stuck task %s: claimed by %s, %.0fh ago"
                  t.id assignee (age /. 3600.0));
                submit
                  ~title:(sprintf "Stuck task: %s (claimed by %s)" t.title assignee)
                  ~target_id:t.id
                  ~subject_type:"task" ~risk_class:Council.Governance_v2.Low
                  ~source_refs:["task-" ^ t.id] ()
              end
          | Types.InProgress { assignee; started_at } ->
              let age = now_f -. (parse_iso_or_epoch started_at) in
              if age > stuck_threshold then begin
                log_debug (sprintf "stuck task %s: in_progress by %s, %.0fh ago"
                  t.id assignee (age /. 3600.0));
                submit
                  ~title:(sprintf "Stuck task: %s (in_progress by %s)" t.title assignee)
                  ~target_id:t.id
                  ~subject_type:"task" ~risk_class:Council.Governance_v2.Low
                  ~source_refs:["task-" ^ t.id] ()
              end
          | _ -> ()
        ) backlog.tasks;

        (* 2. Keepers with 3+ consecutive failures *)
        let keepers_dir =
          match Env_config.me_root_opt () with
          | Some root -> Filename.concat root ".masc/keepers"
          | None -> ".masc/keepers"
        in
        if Sys.file_exists keepers_dir && Sys.is_directory keepers_dir then
          Sys.readdir keepers_dir |> Array.iter (fun fname ->
            if Filename.check_suffix fname ".json" then begin
              let path = Filename.concat keepers_dir fname in
              try
                let json = Safe_ops.read_json_eio path in
                let consecutive_failures =
                  match Yojson.Safe.Util.member "consecutive_failures" json with
                  | `Int n -> n
                  | _ -> 0
                in
                if consecutive_failures >= 3 then begin
                  let keeper_name = Filename.chop_suffix fname ".json" in
                  submit
                    ~title:(sprintf "Keeper %s failing (%d consecutive failures)"
                      keeper_name consecutive_failures)
                    ~target_id:keeper_name
                    ~subject_type:"keeper" ~risk_class:Council.Governance_v2.High
                    ~source_refs:["keeper-" ^ keeper_name] ()
                end
              with
              | Yojson.Json_error _ | Sys_error _ -> ()
              | exn ->
                  Log.Sentinel.warn "keeper failure check %s: %s" fname (Printexc.to_string exn)
            end
          );

        (* 3. Board posts with high downvote ratio *)
        let board_posts = (try Board_dispatch.list_posts ~limit:50 ()
                           with exn ->
                             Log.Sentinel.warn "governance board list_posts: %s" (Printexc.to_string exn);
                             []) in
        List.iter (fun (p : Board.post) ->
          if p.votes_down >= 3 && p.votes_down > p.votes_up then
            submit
              ~title:(sprintf "Flagged post by %s (down=%d, up=%d)"
                (Board.Agent_id.to_string p.author) p.votes_down p.votes_up)
              ~target_id:(Board.Post_id.to_string p.id)
              ~subject_type:"board_post" ~risk_class:Council.Governance_v2.Low
              ~source_refs:["post-" ^ Board.Post_id.to_string p.id] ()
        ) board_posts;

        (* 4. Anomaly-driven parameter adjustment petitions.
           When lodge automation posts exceed 80% of daily cap within the sweep
           window, propose reducing max_posts_per_day via governance. *)
        let current_max_posts =
          Runtime_params.get Governance_registry.lodge_max_posts_per_day
        in
        let recent_automation_posts =
          (try
             let posts = Board_dispatch.list_posts
               ~sort_by:Board_dispatch.Recent ~limit:200 () in
             let one_day_ago = now_f -. 86400.0 in
             List.filter (fun (p : Board.post) ->
               p.post_kind = Board.Automation_post && p.created_at > one_day_ago
             ) posts |> List.length
           with _ -> 0)
        in
        if recent_automation_posts > 0
           && current_max_posts > 0
           && recent_automation_posts >= (current_max_posts * 80 / 100) then begin
          let proposed = max 1 (current_max_posts * 70 / 100) in
          submit
            ~title:"Lodge automation post volume high. Propose reducing daily cap."
            ~subject_type:"param_change"
            ~risk_class:Council.Governance_v2.Low
            ~requested_action:{
              Council.Governance_v2.action_type = "set_param";
              target_type = Some "runtime_param";
              target_id = Some "lodge.max_posts_per_day";
              payload = Some (`Assoc [
                ("param_key", `String "lodge.max_posts_per_day");
                ("value", `Int proposed);
                ("recent_automation_posts", `Int recent_automation_posts);
                ("current_daily_cap", `Int current_max_posts);
              ]);
            }
            ~source_refs:["anomaly:lodge-post-volume"] ()
        end;

        (* BUG-007 FIX: Execute Ready_auto_execute cases via execute_action.
           Previous code only marked status = Auto_executed without running
           the actual action.  Now we delegate to Tool_council.execute_action
           so that set_param / add_task / start_operation are truly executed. *)
        let executed_count = ref 0 in
        let ready_cases =
          Council.Governance_v2.list_cases ~include_test:false
            ~status_filter:Council.Governance_v2.Ready_auto_execute base_path
        in
        let council_ctx : Tool_council.context =
          { base_path; agent_name; room_config = None }
        in
        List.iter (fun (case_ : Council.Governance_v2.case_record) ->
          match Council.Governance_v2.load_execution_order base_path case_.id with
          | Some order when order.Council.Governance_v2.status = Council.Governance_v2.Queued_auto ->
              (match Tool_council.execute_action council_ctx case_ order with
               | Ok executed_order ->
                   (match Council.Governance_v2.save_execution_order base_path executed_order with
                    | Ok _ ->
                        incr executed_count;
                        log_info (sprintf "governance auto-executed case %s (%s): %s"
                          case_.id case_.title
                          (Option.value ~default:"(no summary)" executed_order.result_summary))
                    | Error msg ->
                        log_warn (sprintf "governance auto-execute save failed for %s: %s"
                          case_.id msg))
               | Error msg ->
                   log_warn (sprintf "governance auto-execute failed for %s: %s"
                     case_.id msg))
          | _ -> ()
        ) ready_cases;

        if !petitions_created > 0 || !executed_count > 0 then
          log_info (sprintf "governance sweep: %d petition(s), %d auto-executed"
            !petitions_created !executed_count)
        else
          log_debug "governance sweep: no issues detected";
        Ok ()
      with exn ->
        let msg = sprintf "governance sweep failed: %s" (Printexc.to_string exn) in
        log_warn msg;
        Error msg
  end)

(** Message GC consumer: caps message files per room to MASC_MESSAGE_MAX_COUNT.
    Runs on the same pulse as task hygiene (5min). Deletes oldest by filename sort. *)
let make_message_gc_consumer config : (module Pulse.Consumer) =
  (module struct
    let name = "sentinel-message-gc"
    let should_act _beat = true
    let on_beat _beat =
      try
        let max_count = Env_config_runtime.Message.max_count in
        let msgs_path = Room.messages_dir config in
        if Sys.file_exists msgs_path && Sys.is_directory msgs_path then begin
          let files = Sys.readdir msgs_path |> Array.to_list in
          let count = List.length files in
          if count > max_count then begin
            let sorted = List.sort String.compare files in
            let to_delete = count - max_count in
            let deleted = ref 0 in
            List.iteri (fun i name ->
              if i < to_delete then begin
                let path = Filename.concat msgs_path name in
                (try Sys.remove path; incr deleted
                 with Sys_error _ -> ())
              end
            ) sorted;
            log_info (sprintf "message GC: removed %d/%d files (cap=%d)"
              !deleted count max_count);
          end
        end;
        Ok ()
      with exn ->
        let msg = sprintf "message GC failed: %s" (Printexc.to_string exn) in
        log_warn msg;
        Error msg
  end)

(* ── Status ────────────────────────────────────────────────── *)

let started = ref false
let start_ts : float ref = ref 0.0

let reset_runtime_state_for_tests () =
  started := false;
  start_ts := 0.0;
  last_board_patrol_checked_at := 0.0;
  last_board_patrol_action := "none";
  last_board_patrol_reason := "";
  last_board_patrol_stale_count := 0

let mark_started_for_tests () =
  started := true;
  start_ts := Time_compat.now ()

let ensure_room_initialized_for_start config =
  if not (Room.is_initialized config) then
    ignore (Room.init config ~agent_name:None)

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
      `String "sentinel-message-gc";
    ]
    @
    (if Env_config.Sentinel.governance_enabled then
       [ `String "sentinel-governance-sweep" ]
     else [])
  in
  `Assoc [
    ("enabled", `Bool Env_config.Sentinel.enabled);
    ("started", `Bool !started);
    ("agent_name", `String agent_name);
    ("llm_enabled", `Bool Env_config.Sentinel.llm_enabled);
    ("uptime_s", `Float (if !started then Time_compat.now () -. !start_ts else 0.0));
    ("embedded_guardian_loops_running", `Bool embedded_guardian_loops_running);
    ("guardian_runtime_owner", `String (Guardian.masc_runtime_owner_label ()));
    ( "board_patrol",
      `Assoc
        [
          ("last_checked_at", if !last_board_patrol_checked_at > 0.0 then `String (iso_of_unix !last_board_patrol_checked_at) else `Null);
          ("last_action", `String !last_board_patrol_action);
          ("last_reason", json_string_of_nonempty !last_board_patrol_reason);
          ("last_stale_count", `Int !last_board_patrol_stale_count);
        ] );
    ("consumers", `List consumers);
  ]

(* ── Start ─────────────────────────────────────────────────── *)

let start ?bus ~sw ~clock ~net config =
  bus_ref := bus;
  if not Env_config.Sentinel.enabled then
    log_debug "disabled (set MASC_SENTINEL_ENABLED=true)"
  else begin
    ensure_room_initialized_for_start config;
    (* 1. Join room as sentinel agent *)
    let join_result = Room.join config ~agent_name ~capabilities:["sentinel"; "housekeeping"] () in
    log_info (sprintf "join: %s" (String.sub join_result 0 (min 80 (String.length join_result))));

    (* 2. Heartbeat pulse (30s) *)
    let p_hb = Pulse.create
      ~clock
      ~rhythm:(Guardian.fixed_rhythm Env_config.Sentinel.heartbeat_interval_sec)
      ~lifecycle:Perpetual
      ~consumers:[make_heartbeat_consumer config]
    in
    Pulse.run ~sw p_hb;

    (* 3. Embedded guardian masc loops: zombie + gc stay under sentinel ownership. *)
    Guardian.start_embedded_masc_loops ?bus ~sw ~clock config;

    (* 4. Board patrol (10min) *)
    let p_board = Pulse.create
      ~clock
      ~rhythm:(Guardian.fixed_rhythm Env_config.Sentinel.board_patrol_interval_sec)
      ~lifecycle:Perpetual
      ~consumers:[make_board_patrol_consumer config]
    in
    Pulse.run ~sw p_board;

    (* 5. Task hygiene + Keeper health + Message GC (5min) *)
    let p_ops = Pulse.create
      ~clock
      ~rhythm:(Guardian.fixed_rhythm Env_config.Sentinel.task_hygiene_interval_sec)
      ~lifecycle:Perpetual
      ~consumers:[
        make_task_hygiene_consumer config;
        make_keeper_health_consumer config;
        make_message_gc_consumer config;
      ]
    in
    Pulse.run ~sw p_ops;

    (* 6. Governance sweep (30min) *)
    if Env_config.Sentinel.governance_enabled then begin
      let p_gov = Pulse.create
        ~clock
        ~rhythm:(Guardian.fixed_rhythm Env_config.Sentinel.governance_interval_sec)
        ~lifecycle:Perpetual
        ~consumers:[make_governance_sweep_consumer config]
      in
      Pulse.run ~sw p_gov
    end;

    started := true;
    start_ts := Time_compat.now ();
    ignore net;  (* net reserved for future HTTP-based health checks *)
    let gov_label = if Env_config.Sentinel.governance_enabled then ", governance-sweep" else "" in
    log_info (sprintf "started (heartbeat, embedded zombie/gc, board-patrol, task-hygiene, keeper-health%s)" gov_label)
  end
