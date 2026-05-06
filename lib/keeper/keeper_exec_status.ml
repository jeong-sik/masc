(** Keeper_exec_status — agent status parsing, health/diagnostic state,
    quiet-hours logic, and surface status helpers.
    Metrics summary aggregation is in Keeper_exec_status_metrics. *)

open Keeper_types

let active_model_of_meta (m : keeper_meta) : string =
  if m.runtime.usage.last_model_used <> "" then m.runtime.usage.last_model_used
  else
    match Keeper_model_labels.configured_model_labels_of_meta m with
    | model :: _ -> model
    | [] -> ""

let model_id_of_label (label : string) : string =
  match String.index_opt label ':' with
  | Some idx when idx < String.length label - 1 ->
      String.sub label (idx + 1) (String.length label - idx - 1) |> String.trim
  | _ -> String.trim label

let canonical_provider_of_label (label : string) : string option =
  match String.index_opt label ':' with
  | Some idx when idx > 0 ->
      String.sub label 0 idx
      |> String.trim
      |> Provider_adapter.resolve_direct_canonical_name
  | _ -> Provider_adapter.resolve_direct_canonical_name label

let active_model_label_of_meta (m : keeper_meta) : string =
  let active = String.trim (active_model_of_meta m) in
  if active = "" then ""
  else if String.contains active ':' then active
  else
    let configured = Keeper_model_labels.configured_model_labels_of_meta m in
    let active_norm = String.lowercase_ascii active in
    let matches_model_id label =
      String.lowercase_ascii (model_id_of_label label) = active_norm
    in
    match List.find_opt matches_model_id configured with
    | Some label -> label
    | None -> (
        match Provider_adapter.resolve_direct_adapter active with
        | Some adapter ->
            let matches_provider label =
              canonical_provider_of_label label = Some adapter.canonical_name
            in
            (match List.find_opt matches_provider configured with
             | Some label -> label
             | None ->
                 let model_id =
                   match adapter.default_model_id with
                   | Some value when String.trim value <> "" -> value
                   | _ -> "auto"
                 in
                 adapter.cascade_prefix ^ ":" ^ model_id)
        | None -> active)

let next_model_hint_of_meta (m : keeper_meta) : string option =
  let active = active_model_of_meta m in
  let pool =
    Keeper_model_labels.configured_model_labels_of_meta m
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

let keeper_health_to_string = function
  | KH_healthy -> "healthy"
  | KH_idle -> "idle"
  | KH_offline -> "offline"
  | KH_stale -> "stale"
  | KH_degraded -> "degraded"
  | KH_zombie -> "zombie"
  | KH_dead -> "dead"

(** Issue #8670: strict parser returning [None] on unknown strings so
    drift (producer typo, future variant) is visible to callers instead
    of silently masquerading as [KH_offline]. Mirrors the #8636 lenient
    parser pattern (option-typed reverse route on the parse boundary). *)
let keeper_health_of_string_opt = function
  | "healthy" -> Some KH_healthy
  | "idle" -> Some KH_idle
  | "offline" -> Some KH_offline
  | "stale" -> Some KH_stale
  | "degraded" -> Some KH_degraded
  | "zombie" -> Some KH_zombie
  | "dead" -> Some KH_dead
  | _ -> None

(** Back-compat wrapper for callers not yet migrated to the option form.
    Logs the unknown string once per call so drift is operator-visible
    even when callers do not branch on it. *)
let keeper_health_of_string s =
  match keeper_health_of_string_opt s with
  | Some h -> h
  | None ->
      Log.Keeper.warn
        "keeper_health_of_string: unknown wire string %S → KH_offline fallback (#8670)" s;
      KH_offline

let keeper_continuity_to_string = function
  | Continuity_healthy -> "healthy"
  | Continuity_recovering -> "recovering"
  | Continuity_not_running -> "not_running"

let parse_agent_status (config : Coord.config) ~(agent_name : string) : Yojson.Safe.t =
  let agent_file =
    Filename.concat (Coord.agents_dir config) (Coord.safe_filename agent_name ^ ".json")
  in
  if not (Coord.path_exists config agent_file) then
    `Assoc [ ("exists", `Bool false) ]
  else (
    match Coord.read_json_opt config agent_file with
    | None ->
        `Assoc [ ("exists", `Bool true); ("error", `String "failed_to_read") ]
    | Some json -> (
        match Masc_domain.agent_of_yojson json with
        | Error _ ->
            `Assoc [ ("exists", `Bool true); ("error", `String "failed_to_parse") ]
        | Ok (agent : Masc_domain.agent) ->
            let now_ts = Time_compat.now () in
            let joined_ts =
              Coord_resilience.Time.parse_iso8601_opt agent.joined_at
              |> Option.value ~default:0.0
            in
            let last_seen_ts =
              Coord_resilience.Time.parse_iso8601_opt agent.last_seen
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
                ("status", `String (Masc_domain.string_of_agent_status agent.status));
                ( "capabilities",
                  `List (List.map (fun s -> `String s) agent.capabilities) );
                ( "current_task", Json_util.string_opt_to_json agent.current_task );
                ("joined_at", `String agent.joined_at);
                ("last_seen", `String agent.last_seen);
                ("age_s", `Float age_s);
                ("last_seen_ago_s", `Float last_seen_ago_s);
                ("is_zombie",
                 `Bool
                   (Coord.is_zombie_agent
                      ~agent_type:agent.agent_type
                      ~agent_name:agent.name
                      agent.last_seen));
              ]))

let json_string_opt key json =
  match Safe_ops.json_string_opt key json with
  | Some s ->
      let trimmed = String.trim s in
      if trimmed = "" then None else Some trimmed
  | None -> None

let json_bool key json default =
  Safe_ops.json_bool ~default key json

let json_float_opt key json =
  Safe_ops.json_float_opt key json

let agent_status_text agent_status =
  json_string_opt "status" agent_status
  |> Option.value ~default:"unknown"
  |> String.lowercase_ascii

let agent_last_seen_ts_opt agent_status =
  match json_string_opt "last_seen" agent_status with
  | Some value -> Coord_resilience.Time.parse_iso8601_opt value
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
      match Coord_resilience.Time.parse_iso8601_opt meta.created_at with
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
    ~meta ~keepalive_running ~agent_status ~quiet_reason ~now_ts () : keeper_health =
  (* Supervisor-level health takes priority *)
  match fiber_health with
  | Fiber_zombie -> KH_zombie
  | Fiber_dead -> KH_dead
  | Fiber_alive | Fiber_unknown ->
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
  then KH_offline
  (* H-4 fix: true zombies are stale regardless of keepalive state *)
  else if is_zombie then KH_stale
  else if keepalive_running then
    if last_seen_ago_s > 2.0 *. keepalive_interval_s then KH_stale
    else
      (match quiet_reason with
    | Some "graphql_error" | Some "model_error" -> KH_degraded
    | _ ->
        if meta.runtime.usage.total_turns = 0 && meta.runtime.proactive_rt.count_total = 0 then KH_idle
        else if effective_activity_ago_s > float_of_int (max meta.proactive.idle_sec 900)
        then KH_idle
        else KH_healthy)
  else if last_seen_ago_s > stale_threshold_s then KH_stale
  else KH_offline

let keeper_next_action_path ~(health_state : keeper_health) ~quiet_reason =
  match health_state with
  | KH_zombie -> "auto_restart"
  | KH_dead -> "manual_restart"
  | KH_offline | KH_stale | KH_degraded -> "recover"
  | KH_healthy | KH_idle -> (
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

let keeper_diagnostic_summary ~meta ~(health_state : keeper_health) ~quiet_reason =
  match health_state with
  | KH_zombie ->
      "Keeper fiber has terminated but registry entry persists. Supervisor will auto-restart."
  | KH_dead ->
      "Keeper restart budget exhausted. Manual restart via masc_keeper_up required."
  | KH_offline | KH_stale | KH_degraded ->
      "Keeper is not in a healthy reply state. Probe or recover before relying on automation."
  | KH_healthy | KH_idle -> (
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
    ~(health_state : keeper_health)
    ~(now_ts : float) : keeper_continuity =
  let _ = meta in
  let healthy_like =
    match health_state with KH_healthy | KH_idle -> true | KH_offline | KH_stale | KH_degraded | KH_zombie | KH_dead -> false
  in
  let recently_started =
    match keepalive_started_at with
    | Some started_at ->
        let recovery_window_s = 60.0 in
        now_ts -. started_at < recovery_window_s
    | None -> false
  in
  if not keepalive_running then Continuity_not_running
  else if recently_started || not healthy_like then Continuity_recovering
  else Continuity_healthy

let keeper_continuity_summary = function
  | Continuity_not_running ->
      "Keeper runtime is not running. The runtime should reconcile it."
  | Continuity_recovering ->
      "Keeper runtime is reconciling back into live presence."
  | Continuity_healthy ->
      "Keeper runtime is aligned with the durable keeper state."

let augment_keeper_diagnostic_json
    ~(meta : keeper_meta)
    ~(keepalive_running : bool)
    ~(keepalive_started_at : float option)
    ~(now_ts : float)
    (diagnostic : Yojson.Safe.t) : Yojson.Safe.t =
  let health_state =
    json_string_opt "health_state" diagnostic
    |> Option.value ~default:"offline"
    |> keeper_health_of_string
  in
  let continuity_state =
    keeper_continuity_state ~meta ~keepalive_running
      ~keepalive_started_at ~health_state ~now_ts
  in
  let continuity_summary = keeper_continuity_summary continuity_state in
  let continuity_str = keeper_continuity_to_string continuity_state in
  let summary =
    match json_string_opt "summary" diagnostic with
    | Some base when continuity_state = Continuity_healthy -> base
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
        :: ("continuity_state", `String continuity_str)
        :: ("continuity_summary", `String continuity_summary)
        :: filtered)
  | other -> other

let keeper_surface_status
    ~(agent_status : Yojson.Safe.t)
    ~(diagnostic : Yojson.Safe.t) =
  let health_state =
    json_string_opt "health_state" diagnostic
    |> Option.value ~default:"offline"
    |> keeper_health_of_string
  in
  let agent_runtime_status =
    json_string_opt "status" agent_status |> Option.map String.lowercase_ascii
  in
  match health_state with
  | KH_healthy -> (
      match agent_runtime_status with
      | Some (("active" | "busy" | "listening" | "idle") as status) -> status
      | Some ("offline" | "inactive") -> "offline"
      | _ -> "active")
  | KH_idle -> "idle"
  | KH_stale | KH_degraded | KH_zombie | KH_dead -> "inactive"
  | KH_offline -> "offline"

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
      ("health_state", `String (keeper_health_to_string health_state));
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

(** Derive pipeline stage directly from the 12-state phase (RFC-0002).
    Deterministic mapping — no 30s recency heuristic. *)
let pipeline_stage_of_phase (phase : Keeper_state_machine.phase) : string =
  match phase with
  | Keeper_state_machine.Offline -> "offline"
  | Keeper_state_machine.Running -> "idle"
  | Keeper_state_machine.Failing -> "failing"
  | Keeper_state_machine.Overflowed -> "overflowed"
  | Keeper_state_machine.Compacting -> "compacting"
  | Keeper_state_machine.HandingOff -> "handoff"
  | Keeper_state_machine.Draining -> "draining"
  | Keeper_state_machine.Paused -> "paused"
  | Keeper_state_machine.Stopped -> "offline"
  | Keeper_state_machine.Crashed -> "crashed"
  | Keeper_state_machine.Restarting -> "restarting"
  | Keeper_state_machine.Dead | Keeper_state_machine.Zombie -> "offline"
