(** Keeper_exec_status — agent status parsing, health/diagnostic state,
    quiet-hours logic, and surface status helpers.
    Metrics summary aggregation is in Keeper_exec_status_metrics. *)

open Keeper_types

let active_model_of_meta (m : keeper_meta) : string =
  if m.runtime.usage.last_model_used <> "" then m.runtime.usage.last_model_used
  else
    match Oas_model_resolve.models_of_cascade_name m.cascade_name with
    | model :: _ -> model
    | [] -> ""

let next_model_hint_of_meta (m : keeper_meta) : string option =
  let active = active_model_of_meta m in
  let pool =
    dedupe_keep_order (Oas_model_resolve.models_of_cascade_name m.cascade_name)
  in
  match List.filter (fun model -> model <> active) pool with
  | next_model :: _ -> Some next_model
  | [] -> (
      match pool with
      | current :: _ -> Some current
      | [] -> None)

let string_of_fiber_health = function
  | Fiber_alive -> "alive"
  | Fiber_zombie -> "zombie"
  | Fiber_dead -> "dead"
  | Fiber_unknown -> "unknown"

let parse_agent_status (config : Room.config) ~(agent_name : string) : Yojson.Safe.t =
  let agent_file =
    Filename.concat (Room.agents_dir config) (Room.safe_filename agent_name ^ ".json")
  in
  if not (Room.path_exists config agent_file) then
    `Assoc [ ("exists", `Bool false) ]
  else (
    match Room.read_json_opt config agent_file with
    | None ->
        `Assoc [ ("exists", `Bool true); ("error", `String "failed_to_read") ]
    | Some json -> (
        match Types.agent_of_yojson json with
        | Error _ ->
            `Assoc [ ("exists", `Bool true); ("error", `String "failed_to_parse") ]
        | Ok (agent : Types.agent) ->
            let now_ts = Time_compat.now () in
            let joined_ts =
              Resilience.Time.parse_iso8601_opt agent.joined_at
              |> Option.value ~default:0.0
            in
            let last_seen_ts =
              Resilience.Time.parse_iso8601_opt agent.last_seen
              |> Option.value ~default:0.0
            in
            let age_s = if joined_ts <= 0.0 then 0.0 else now_ts -. joined_ts in
            let last_seen_ago_s =
              if last_seen_ts <= 0.0 then 0.0 else now_ts -. last_seen_ts
            in
            `Assoc
              [
                ("exists", `Bool true);
                ("name", `String agent.name);
                ("agent_type", `String agent.agent_type);
                ("status", `String (Types.string_of_agent_status agent.status));
                ( "capabilities",
                  `List (List.map (fun s -> `String s) agent.capabilities) );
                ( "current_task", Json_util.string_opt_to_json agent.current_task );
                ("joined_at", `String agent.joined_at);
                ("last_seen", `String agent.last_seen);
                ("age_s", `Float age_s);
                ("last_seen_ago_s", `Float last_seen_ago_s);
                ("is_zombie", `Bool (Room.is_zombie_agent ~agent_name:agent.name agent.last_seen));
              ]))

let json_string_opt key json =
  match Yojson.Safe.Util.member key json with
  | `String s ->
      let trimmed = String.trim s in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let json_bool key json default =
  match Yojson.Safe.Util.member key json with
  | `Bool value -> value
  | _ -> default

let json_float_opt key json =
  match Yojson.Safe.Util.member key json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | _ -> None

let agent_status_text agent_status =
  json_string_opt "status" agent_status
  |> Option.value ~default:"unknown"
  |> String.lowercase_ascii

let agent_last_seen_ts_opt agent_status =
  match json_string_opt "last_seen" agent_status with
  | Some value -> Resilience.Time.parse_iso8601_opt value
  | None -> None

let agent_last_seen_ago_s agent_status =
  json_float_opt "last_seen_ago_s" agent_status |> Option.value ~default:max_float

let agent_runtime_has_live_signal agent_status =
  match agent_status_text agent_status with
  | "active" | "busy" | "listening" | "idle" ->
      agent_last_seen_ago_s agent_status <= 120.0
  | _ -> false

let agent_runtime_has_live_work agent_status =
  match agent_status_text agent_status with
  | "active" | "busy" | "listening" ->
      agent_last_seen_ago_s agent_status <= 120.0
  | _ -> false

let string_contains_ci haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    if idx + nlen > hlen then false
    else if String.sub haystack idx nlen = needle then true
    else loop (idx + 1)
  in
  needle <> "" && loop 0

let quiet_hours_active () =
  let current_hour =
    let tm = Unix.gmtime (Time_compat.now ()) in
    (* KST = UTC+9; must use gmtime, not localtime *)
    (tm.Unix.tm_hour + 9) mod 24
  in
  let quiet_start = Env_config.Autonomy.quiet_start in
  let quiet_end = Env_config.Autonomy.quiet_end in
  quiet_start < quiet_end
  && current_hour >= quiet_start
  && current_hour < quiet_end

let keeper_reply_snapshot_of_history (history_items : Yojson.Safe.t list) =
  let open Yojson.Safe.Util in
  let normalize_content item =
    match json_string_opt "content" item with
    | Some value -> value
    | None -> Option.value ~default:"" (json_string_opt "preview" item)
  in
  let update_last role ts content ((last_user, last_assistant) as acc) =
    let role = String.lowercase_ascii role in
    if role = "user" then
      (Some (ts, content), last_assistant)
    else if role = "assistant" then
      (last_user, Some (ts, content))
    else acc
  in
  let last_user, last_assistant =
    List.fold_left
      (fun acc item ->
        match item with
        | `Assoc _ ->
            let role = item |> member "role" |> to_string_option in
            let ts_unix =
              match json_float_opt "ts_unix" item with
              | Some ts when ts > 0.0 -> Some ts
              | _ -> json_float_opt "timestamp" item
            in
            let content = normalize_content item in
            (match role, ts_unix with
            | Some role, Some ts -> update_last role ts content acc
            | _ -> acc)
        | _ -> acc)
      (None, None) history_items
  in
  match last_user, last_assistant with
  | None, None -> (`String "never", `Null, `Null)
  | Some (user_ts, _), Some (assistant_ts, preview) when assistant_ts >= user_ts ->
      (`String "delivered", `Float assistant_ts, `String preview)
  | Some _, Some (assistant_ts, preview) ->
      (`String "delivered", `Float assistant_ts, `String preview)
  | Some _, None -> (`String "awaiting_reply", `Null, `Null)
  | None, Some (assistant_ts, preview) ->
      (`String "delivered", `Float assistant_ts, `String preview)

(** Error keyword detection — includes provider names from adapter registry. *)
let error_keywords =
  let provider_keywords =
    List.map (fun (a : Provider_adapter.adapter) -> a.canonical_name)
      Provider_adapter.direct_adapters
    @ List.concat_map (fun (a : Provider_adapter.adapter) -> a.aliases)
        Provider_adapter.direct_adapters
  in
  [ "error"; "failed"; "timeout"; "graphql"; "model" ] @ provider_keywords

let looks_error_like text =
  List.exists (string_contains_ci text) error_keywords

let keeper_error_hint ~agent_status ~meta =
  let agent_error = json_string_opt "error" agent_status in
  let proactive_reason =
    let reason = String.trim meta.runtime.proactive_rt.last_reason in
    if reason = "" then None else Some reason
  in
  let drift_reason = None in
  match agent_error with
  | Some _ as error -> error
  | None -> (
      match proactive_reason with
      | Some reason when looks_error_like reason -> Some reason
      | _ -> (
          match drift_reason with
          | Some reason when looks_error_like reason -> Some reason
          | _ -> None))

let classify_keeper_quiet_reason ~meta ~keepalive_running ~agent_status ~now_ts =
  let quiet_active = quiet_hours_active () in
  let agent_exists = json_bool "exists" agent_status false in
  let agent_status_text = agent_status_text agent_status in
  let live_signal_supersedes_persisted_error =
    keepalive_running
    && agent_exists
    && agent_runtime_has_live_signal agent_status
    &&
    match agent_last_seen_ts_opt agent_status with
    | Some last_seen_ts ->
        let persisted_error_ts =
          max meta.runtime.proactive_rt.last_ts meta.runtime.usage.last_turn_ts
        in
        last_seen_ts > persisted_error_ts
    | None -> false
  in
  let error_hint =
    if live_signal_supersedes_persisted_error then None
    else keeper_error_hint ~agent_status ~meta
  in
  if not meta.proactive.enabled then
    Some "disabled"
  else if not keepalive_running then
    Some "not_running"
  else if
    not agent_exists
    || agent_status_text = "offline"
    || agent_status_text = "inactive"
  then Some "agent_missing"
  else if meta.runtime.usage.total_turns = 0 && meta.runtime.proactive_rt.count_total = 0 then
    let keeper_age_s =
      match Resilience.Time.parse_iso8601_opt meta.created_at with
      | Some created_ts when created_ts > 0.0 -> max 0.0 (now_ts -. created_ts)
      | _ -> 0.0
    in
    if keeper_age_s <= 120.0 then Some "startup" else Some "never_started"
  else if quiet_active then
    Some "quiet_hours"
  else
    match error_hint with
    | Some reason when string_contains_ci reason "graphql" ->
        Some "graphql_error"
    | Some reason when looks_error_like reason ->
        Some "model_error"
    | Some _ -> Some "unknown"
    | None ->
        let last_turn_ago_s =
          if meta.runtime.usage.last_turn_ts <= 0.0 then None
          else Some (max 0.0 (now_ts -. meta.runtime.usage.last_turn_ts))
        in
        let last_proactive_ago_s =
          if meta.runtime.proactive_rt.last_ts <= 0.0 then None
          else Some (max 0.0 (now_ts -. meta.runtime.proactive_rt.last_ts))
        in
        let effective_activity_ago_s =
          match last_turn_ago_s with
          | Some age when agent_runtime_has_live_work agent_status ->
              Some (min age (agent_last_seen_ago_s agent_status))
          | Some _ as age -> age
          | None when agent_runtime_has_live_work agent_status ->
              Some (agent_last_seen_ago_s agent_status)
          | None -> None
        in
        if meta.proactive.enabled then
          match last_proactive_ago_s with
          | Some age when age < float_of_int meta.proactive.cooldown_sec ->
              Some "min_gap"
          | _ -> (
              match effective_activity_ago_s with
              | Some age when age < float_of_int meta.proactive.idle_sec ->
                  Some "no_recent_activity"
              | _ -> None)
        else None

let keeper_health_state ?(fiber_health = Fiber_unknown)
    ?(keepalive_interval_s = 300.0)
    ~meta ~keepalive_running ~agent_status ~quiet_reason ~now_ts () =
  (* Supervisor-level health takes priority *)
  match fiber_health with
  | Fiber_zombie -> "zombie"
  | Fiber_dead -> "dead"
  | _ ->
  let agent_exists = json_bool "exists" agent_status false in
  let agent_status_text =
    json_string_opt "status" agent_status
    |> Option.value ~default:"unknown"
    |> String.lowercase_ascii
  in
  let last_seen_ago_s =
    json_float_opt "last_seen_ago_s" agent_status |> Option.value ~default:max_float
  in
  let is_zombie = json_bool "is_zombie" agent_status false in
  let stale_threshold_s = 120.0 in
  let last_turn_ago_s =
    if meta.runtime.usage.last_turn_ts <= 0.0 then max_float
    else max 0.0 (now_ts -. meta.runtime.usage.last_turn_ts)
  in
  let effective_activity_ago_s =
    if agent_runtime_has_live_work agent_status then
      min last_turn_ago_s last_seen_ago_s
    else
      last_turn_ago_s
  in
  if not agent_exists || agent_status_text = "offline" || agent_status_text = "inactive"
  then "offline"
  (* H-4 fix: true zombies are stale regardless of keepalive state *)
  else if is_zombie then "stale"
  else if keepalive_running then
    (* Secondary timeout: if the fiber is stuck and not heartbeating, flag as stale.
       Use 2x the configured keepalive interval (default: max 300s) so that keepers
       with a long heartbeat cadence are not incorrectly classified. *)
    if last_seen_ago_s > 2.0 *. keepalive_interval_s then "stale"
    else
      (* Keepalive fiber is alive — trust it over last_seen.
         presence_fresh optimization may skip Room.heartbeat(),
         causing last_seen to drift without the keeper actually being stale. *)
      (match quiet_reason with
    | Some "graphql_error" | Some "model_error" -> "degraded"
    | _ ->
        if meta.runtime.usage.total_turns = 0 && meta.runtime.proactive_rt.count_total = 0 then "idle"
        else if effective_activity_ago_s > float_of_int (max meta.proactive.idle_sec 900)
        then "idle"
        else "healthy")
  (* Keepalive NOT running — fall back to last_seen for stale detection *)
  else if last_seen_ago_s > stale_threshold_s then "stale"
  else "offline"

let keeper_next_action_path ~health_state ~quiet_reason =
  match health_state with
  | "zombie" -> "auto_restart"
  | "dead" -> "manual_restart"
  | "offline" | "stale" | "degraded" -> "recover"
  | _ -> (
      match quiet_reason with
      | Some "quiet_hours" -> "manual_social_poke"
      | Some "not_running" | Some "agent_missing" -> "recover"
      | Some "graphql_error" | Some "model_error" | Some "startup" | Some "unknown" ->
          "probe"
      | Some "disabled" -> "recover"
      | _ -> "direct_message")

let keeper_next_eligible_at_s ~meta ~quiet_reason ~now_ts =
  match quiet_reason with
  | Some "min_gap" when meta.runtime.proactive_rt.last_ts > 0.0 ->
      let remaining =
        float_of_int meta.proactive.cooldown_sec -. (now_ts -. meta.runtime.proactive_rt.last_ts)
      in
      if remaining > 0.0 then `Float remaining else `Null
  | _ -> `Null

let keeper_diagnostic_summary ~meta ~health_state ~quiet_reason =
  match health_state with
  | "zombie" ->
      "Keeper fiber has terminated but registry entry persists. Supervisor will auto-restart."
  | "dead" ->
      "Keeper restart budget exhausted. Manual restart via masc_keeper_up required."
  | "offline" | "stale" | "degraded" ->
      "Keeper is not in a healthy reply state. Probe or recover before relying on automation."
  | _ -> (
      match quiet_reason with
      | Some "disabled" ->
          "Keeper proactive automation is disabled. Direct messages still work, but scheduled social ticks will stay quiet."
      | Some "not_running" ->
          "Keeper keepalive is enabled, but its loop is not running."
      | Some "agent_missing" ->
          "Keeper keepalive is running, but the live agent record is missing or offline."
      | Some "quiet_hours" ->
          "Quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep."
      | Some "min_gap" ->
          if meta.runtime.proactive_rt.last_outcome = Proactive_silent then
            "Latest autonomous proactive cycle completed silently. The next deterministic cycle will open after cooldown."
          else
            "Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait."
      | Some "never_started" ->
          "Keeper metadata exists but no reply turn has been recorded yet."
      | _ -> "Keeper is reachable. Send a direct message for an immediate response.")

let keeper_continuity_state
    ~(meta : keeper_meta)
    ~(keepalive_running : bool)
    ~(keepalive_started_at : float option)
    ~(health_state : string)
    ~(now_ts : float) =
  let _ = meta in
  let healthy_like =
    String.equal health_state "healthy" || String.equal health_state "idle"
  in
  let recently_started =
    match keepalive_started_at with
    | Some started_at ->
        let recovery_window_s = 60.0 in
        now_ts -. started_at < recovery_window_s
    | None -> false
  in
  if not keepalive_running then "not_running"
  else if recently_started || not healthy_like then "recovering"
  else "healthy"

let keeper_continuity_summary continuity_state =
  match continuity_state with
  | "not_running" ->
      "Keeper runtime is not running. The runtime should reconcile it."
  | "recovering" ->
      "Keeper runtime is reconciling back into live presence."
  | "healthy" ->
      "Keeper runtime is aligned with the durable keeper state."
  | _ -> "Keeper runtime is offline."

let augment_keeper_diagnostic_json
    ~(meta : keeper_meta)
    ~(keepalive_running : bool)
    ~(keepalive_started_at : float option)
    ~(now_ts : float)
    (diagnostic : Yojson.Safe.t) : Yojson.Safe.t =
  let health_state =
    json_string_opt "health_state" diagnostic |> Option.value ~default:"offline"
  in
  let continuity_state =
    keeper_continuity_state ~meta ~keepalive_running
      ~keepalive_started_at ~health_state ~now_ts
  in
  let continuity_summary = keeper_continuity_summary continuity_state in
  let summary =
    match json_string_opt "summary" diagnostic with
    | Some base when continuity_state = "healthy" -> base
    | Some _ | None -> continuity_summary
  in
  match diagnostic with
  | `Assoc fields ->
      let filtered =
        fields
        |> List.filter (fun (key, _) ->
               not
                 (String.equal key "summary"
                 || String.equal key "continuity_state"
                 || String.equal key "continuity_summary"))
      in
      `Assoc
        (("summary", `String summary)
        :: ("continuity_state", `String continuity_state)
        :: ("continuity_summary", `String continuity_summary)
        :: filtered)
  | other -> other

let keeper_surface_status
    ~(agent_status : Yojson.Safe.t)
    ~(diagnostic : Yojson.Safe.t) =
  let health_state =
    json_string_opt "health_state" diagnostic
    |> Option.value ~default:"offline"
    |> String.lowercase_ascii
  in
  let agent_runtime_status =
    json_string_opt "status" agent_status |> Option.map String.lowercase_ascii
  in
  match health_state with
  | "healthy" -> (
      match agent_runtime_status with
      | Some (("active" | "busy" | "listening" | "idle") as status) -> status
      | Some ("offline" | "inactive") -> "offline"
      | _ -> "active")
  | "idle" -> "idle"
  | "stale" | "degraded" | "zombie" | "dead" -> "inactive"
  | "offline" -> "offline"
  | _ -> (
      match agent_runtime_status with
      | Some ("offline" | "inactive") -> "offline"
      | _ -> "inactive")

let keeper_diagnostic_json
    ~(meta : keeper_meta)
    ~(agent_status : Yojson.Safe.t)
    ~(keepalive_running : bool)
    ~(history_items : Yojson.Safe.t list)
    ~(now_ts : float) : Yojson.Safe.t =
  let quiet_reason =
    classify_keeper_quiet_reason ~meta ~keepalive_running ~agent_status ~now_ts
  in
  let health_state =
    keeper_health_state ~meta ~keepalive_running ~agent_status ~quiet_reason ~now_ts ()
  in
  let next_action_path = keeper_next_action_path ~health_state ~quiet_reason in
  let last_reply_status, last_reply_at, last_reply_preview =
    keeper_reply_snapshot_of_history history_items
  in
  let last_error =
    Json_util.string_opt_to_json (keeper_error_hint ~agent_status ~meta)
  in
  `Assoc
    [
      ("health_state", `String health_state);
      ( "quiet_reason", Json_util.string_opt_to_json quiet_reason );
      ("next_action_path", `String next_action_path);
      ("recoverable", `Bool (String.equal next_action_path "recover"));
      ("summary", `String (keeper_diagnostic_summary ~meta ~health_state ~quiet_reason));
      ("last_reply_status", last_reply_status);
      ("last_reply_at", last_reply_at);
      ("last_reply_preview", last_reply_preview);
      ("last_error", last_error);
      ("keepalive_running", `Bool keepalive_running);
      ("next_eligible_at_s", keeper_next_eligible_at_s ~meta ~quiet_reason ~now_ts);
    ]

(** Derive pipeline stage directly from the 11-state phase (RFC-0002).
    Deterministic mapping — no 30s recency heuristic. *)
let pipeline_stage_of_phase (phase : Keeper_state_machine.phase) : string =
  match phase with
  | Keeper_state_machine.Offline -> "offline"
  | Keeper_state_machine.Running -> "idle"
  | Keeper_state_machine.Failing -> "failing"
  | Keeper_state_machine.Compacting -> "compacting"
  | Keeper_state_machine.HandingOff -> "handoff"
  | Keeper_state_machine.Draining -> "draining"
  | Keeper_state_machine.Paused -> "paused"
  | Keeper_state_machine.Stopped -> "offline"
  | Keeper_state_machine.Crashed -> "crashed"
  | Keeper_state_machine.Restarting -> "restarting"
  | Keeper_state_machine.Dead -> "offline"
