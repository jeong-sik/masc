(** Keeper_types — shared keeper contract, registry/store helpers,
    path resolution, and model-selection utilities. *)

(* Utility functions, canonical helpers, profile defaults, and dir helpers
   extracted to Keeper_types_profile *)
include Keeper_types_profile


(* -- Policy types (remain in keeper_meta top-level) -- *)

type compaction_policy = {
  profile: string;
  ratio_gate: float;
  message_gate: int;
  token_gate: int;
  cooldown_sec: int;
}

type proactive_policy = {
  enabled: bool;
  idle_sec: int;
  cooldown_sec: int;
}

type tool_access =
  | Unrestricted
  | Restricted of string list

(* -- Runtime types (moved into agent_runtime_state) -- *)

type compaction_runtime = {
  count: int;
  last_ts: float;
  last_before_tokens: int;
  last_after_tokens: int;
  last_check_ts: float;
  last_decision: string;
}

type proactive_runtime = {
  count_total: int;
  last_ts: float;
  last_reason: string;
  last_preview: string;
}

type usage_metrics = {
  total_turns: int;
  total_input_tokens: int;
  total_output_tokens: int;
  total_tokens: int;
  total_cost_usd: float;
  last_turn_ts: float;
  last_model_used: string;
  last_input_tokens: int;
  last_output_tokens: int;
  last_total_tokens: int;
  last_latency_ms: int;
}

type agent_runtime_state = {
  usage: usage_metrics;
  compaction_rt: compaction_runtime;
  proactive_rt: proactive_runtime;
  generation: int;
  trace_id: string;
  trace_history: string list;
  last_handoff_ts: float;
  last_continuity_update_ts: float;
  last_autonomous_action_at: string;
  autonomous_action_count: int;
  autonomous_turn_count: int;
  autonomous_text_turn_count: int;
  autonomous_tool_turn_count: int;
  board_reactive_turn_count: int;
  mention_reactive_turn_count: int;
  noop_turn_count: int;
  last_speech_act: string;
  last_blocker: string;
  last_need: string;
}

type keeper_meta = {
  (* -- Identity & profile -- *)
  name: string;
  agent_name: string;
  goal: string;
  short_goal: string;
  mid_goal: string;
  long_goal: string;
  soul_profile: string;
  social_model: string;
  cascade_name: string;
  will: string;
  needs: string;
  desires: string;
  instructions: string;
  (* -- Policy -- *)
  policy_voice_enabled: bool;
  execution_scope: string;
  allowed_paths: string list;
  scope_kind: string;
  tool_access: tool_access;
  tool_denylist: string list;
  room_scope: string;
  mention_targets: string list;
  joined_room_ids: string list;
  last_seen_seq_by_room: (string * int) list;
  proactive: proactive_policy;
  compaction: compaction_policy;
  auto_handoff: bool;
  handoff_threshold: float;
  handoff_cooldown_sec: int;
  (* -- Voice -- *)
  voice_enabled: bool;
  voice_channel: string;
  voice_agent_id: string;
  (* -- Lifecycle -- *)
  created_at: string;
  updated_at: string;
  (* -- Operational control (top-level, not runtime) -- *)
  continuity_summary: string;
  active_goal_ids: string list;
  active_team_session_id: string option;
  last_team_session_started_at: string;
  team_session_start_count_total: int;
  paused: bool;
  current_task_id: string option;
  (** Currently claimed task ID for cost attribution.
      Set when keeper claims a task; cleared on masc_done.
      Propagated to trajectory accumulator for per-task cost tracking. *)
  (* -- Agent runtime state (usage, tracing, autonomy metrics) -- *)
  runtime: agent_runtime_state;
}

let default_social_model = "bdi_speech_v1"

let normalize_tool_access = function
  | Unrestricted -> Unrestricted
  | Restricted names ->
      Restricted
        (names
        |> List.filter (fun name -> String.trim name <> "")
        |> dedupe_keep_order)

let tool_access_allowlist = function
  | Unrestricted -> []
  | Restricted names -> names

let tool_access_to_json access =
  match normalize_tool_access access with
  | Unrestricted ->
      `Assoc [ ("kind", `String "unrestricted") ]
  | Restricted names ->
      `Assoc
        [
          ("kind", `String "restricted");
          ("tools", `List (List.map (fun s -> `String s) names));
        ]

let tool_access_of_meta_json (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member "tool_access" json with
  | `Null ->
      let legacy_allowlist =
        match Safe_ops.json_string_list "tool_allowlist" json with
        | [] -> Tool_catalog.standard_tools
        | names -> names
      in
      Ok (normalize_tool_access (Restricted legacy_allowlist))
  | `Assoc _ as access_json -> (
      let kind =
        Yojson.Safe.Util.member "kind" access_json |> Yojson.Safe.Util.to_string_option
      in
      let string_list_field field_name =
        match Yojson.Safe.Util.member field_name access_json with
        | `List items ->
            let rec collect acc index = function
              | [] -> Ok (List.rev acc)
              | `String value :: rest -> collect (value :: acc) (index + 1) rest
              | _ :: _ ->
                  Error
                    (Printf.sprintf
                       "keeper tool_access.%s[%d] must be a string"
                       field_name index)
            in
            collect [] 0 items
        | `Null ->
            Error (Printf.sprintf "keeper tool_access.%s must be an array of strings" field_name)
        | _ ->
            Error (Printf.sprintf "keeper tool_access.%s must be an array of strings" field_name)
      in
      match kind with
      | Some "unrestricted" -> Ok Unrestricted
      | Some "restricted" -> (
          match string_list_field "tools" with
          | Ok tools -> Ok (normalize_tool_access (Restricted tools))
          | Error msg -> Error msg)
      | Some other ->
          Error (Printf.sprintf "invalid keeper tool_access.kind: %s" other)
      | None -> Error "keeper tool_access.kind required")
  | _ -> Error "keeper tool_access must be an object"

(* -- Updater helpers for nested record updates -- *)

let map_runtime (f : agent_runtime_state -> agent_runtime_state) (m : keeper_meta) : keeper_meta =
  { m with runtime = f m.runtime }

let map_usage (f : usage_metrics -> usage_metrics) (m : keeper_meta) : keeper_meta =
  { m with runtime = { m.runtime with usage = f m.runtime.usage } }

let map_compaction_rt (f : compaction_runtime -> compaction_runtime) (m : keeper_meta) : keeper_meta =
  { m with runtime = { m.runtime with compaction_rt = f m.runtime.compaction_rt } }

let map_proactive_rt (f : proactive_runtime -> proactive_runtime) (m : keeper_meta) : keeper_meta =
  { m with runtime = { m.runtime with proactive_rt = f m.runtime.proactive_rt } }

let now_iso () = Types.now_iso ()

let keeper_legacy_model_arg_names = [ "models"; "allowed_models"; "active_model" ]

let runtime_meta_write_sync_hook : (Room.config -> keeper_meta -> unit) ref =
  ref (fun _ _ -> ())

let register_runtime_meta_write_sync f =
  runtime_meta_write_sync_hook := f

let reject_legacy_model_args ~tool_name (args : Yojson.Safe.t) =
  let present =
    keeper_legacy_model_arg_names
    |> List.filter (fun key ->
           match Yojson.Safe.Util.member key args with
           | `Null -> false
           | _ -> true)
  in
  match present with
  | [] -> Ok ()
  | fields ->
      Error
        (Printf.sprintf
           "legacy keeper model args removed for %s: %s. Keepers now use cascade_name and last_model_used only."
           tool_name (String.concat ", " fields))

let drop_assoc_keys (keys : string list) (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
      `Assoc
        (List.filter (fun (key, _) -> not (List.mem key keys)) fields)
  | _ -> json

let reject_removed_keeper_meta_fields (json : Yojson.Safe.t) =
  let present = present_json_keys removed_keeper_meta_key_names json in
  match present with
  | [] -> Ok ()
  | fields ->
      Error
        (Printf.sprintf
           "removed keeper meta fields: %s"
           (String.concat ", " fields))

let scrub_persisted_keeper_meta_json ~path (json : Yojson.Safe.t) :
    Yojson.Safe.t * bool =
  match json with
  | `Assoc fields ->
      let present =
        fields
        |> List.filter_map (fun (key, _) ->
               if List.mem key removed_keeper_meta_key_names then Some key else None)
      in
      if present = [] then (json, false)
      else
        let migrate_legacy_disabled_keepalive =
          (match List.assoc_opt "presence_keepalive" fields with
          | Some (`Bool false) -> true
          | _ -> false)
          && not (List.mem_assoc "paused" fields)
        in
        let scrubbed =
          let base = drop_assoc_keys removed_keeper_meta_key_names json in
          match base with
          | `Assoc base_fields when migrate_legacy_disabled_keepalive ->
              `Assoc (("paused", `Bool true) :: List.remove_assoc "paused" base_fields)
          | _ -> base
        in
        let content = Yojson.Safe.pretty_to_string scrubbed in
        (try
           Fs_compat.save_file path content;
           Log.Keeper.info
             "scrubbed removed keeper meta fields for %s: %s%s"
             path
             (String.concat ", " present)
             (if migrate_legacy_disabled_keepalive then
                " (migrated presence_keepalive=false to paused=true)"
              else
                "")
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             Log.Keeper.warn
               "failed to scrub removed keeper meta fields for %s: %s"
               path
               (Printexc.to_string exn));
        (scrubbed, true)
  | _ -> (json, false)

let meta_to_json (m : keeper_meta) : Yojson.Safe.t =
  let rt = m.runtime in
  `Assoc
    [
      ("name", `String m.name);
      ("agent_name", `String m.agent_name);
      ("trace_id", `String rt.trace_id);
      ("trace_history", `List (List.map (fun s -> `String s) rt.trace_history));
      ("goal", `String m.goal);
      ("short_goal", `String m.short_goal);
      ("mid_goal", `String m.mid_goal);
      ("long_goal", `String m.long_goal);
      ("soul_profile", `String m.soul_profile);
      ("social_model", `String m.social_model);
      ("cascade_name", `String m.cascade_name);
      ("will", `String m.will);
      ("needs", `String m.needs);
      ("desires", `String m.desires);
      ("instructions", `String m.instructions);
      ("policy_voice_enabled", `Bool m.policy_voice_enabled);
      ("execution_scope", `String m.execution_scope);
      ("allowed_paths", `List (List.map (fun s -> `String s) m.allowed_paths));
      ("scope_kind", `String m.scope_kind);
      ("tool_access", tool_access_to_json m.tool_access);
      ("tool_denylist", `List (List.map (fun s -> `String s) m.tool_denylist));
      ("room_scope", `String m.room_scope);
      ("mention_targets", `List (List.map (fun s -> `String s) m.mention_targets));
      ("joined_room_ids", `List (List.map (fun s -> `String s) m.joined_room_ids));
      ("last_seen_seq_by_room", room_seq_map_to_json m.last_seen_seq_by_room);
      ("generation", `Int rt.generation);
      ("proactive_enabled", `Bool m.proactive.enabled);
      ("proactive_idle_sec", `Int m.proactive.idle_sec);
      ("proactive_cooldown_sec", `Int m.proactive.cooldown_sec);
      ("compaction_profile", `String m.compaction.profile);
      ("compaction_ratio_gate", `Float m.compaction.ratio_gate);
      ("compaction_message_gate", `Int m.compaction.message_gate);
      ("compaction_token_gate", `Int m.compaction.token_gate);
      ("continuity_compaction_cooldown_sec", `Int m.compaction.cooldown_sec);
      ("auto_handoff", `Bool m.auto_handoff);
      ("handoff_threshold", `Float m.handoff_threshold);
      ("handoff_cooldown_sec", `Int m.handoff_cooldown_sec);
      ("voice_enabled", `Bool m.voice_enabled);
      ("voice_channel", `String m.voice_channel);
      ("voice_agent_id", `String m.voice_agent_id);
      ("last_handoff_ts", `Float rt.last_handoff_ts);
      ("created_at", `String m.created_at);
      ("updated_at", `String m.updated_at);
      ("total_turns", `Int rt.usage.total_turns);
      ("total_input_tokens", `Int rt.usage.total_input_tokens);
      ("total_output_tokens", `Int rt.usage.total_output_tokens);
      ("total_tokens", `Int rt.usage.total_tokens);
      ("total_cost_usd", `Float rt.usage.total_cost_usd);
      ("last_turn_ts", `Float rt.usage.last_turn_ts);
      ("last_model_used", `String rt.usage.last_model_used);
      ("last_input_tokens", `Int rt.usage.last_input_tokens);
      ("last_output_tokens", `Int rt.usage.last_output_tokens);
      ("last_total_tokens", `Int rt.usage.last_total_tokens);
      ("last_latency_ms", `Int rt.usage.last_latency_ms);
      ("compaction_count", `Int rt.compaction_rt.count);
      ("last_compaction_ts", `Float rt.compaction_rt.last_ts);
      ("last_compaction_before_tokens", `Int rt.compaction_rt.last_before_tokens);
      ("last_compaction_after_tokens", `Int rt.compaction_rt.last_after_tokens);
      ("proactive_count_total", `Int rt.proactive_rt.count_total);
      ("last_proactive_ts", `Float rt.proactive_rt.last_ts);
      ("last_proactive_reason", `String rt.proactive_rt.last_reason);
      ("last_proactive_preview", `String rt.proactive_rt.last_preview);
      ("last_compaction_check_ts", `Float rt.compaction_rt.last_check_ts);
      ("last_compaction_decision", `String rt.compaction_rt.last_decision);
      ("last_continuity_update_ts", `Float rt.last_continuity_update_ts);
      ("continuity_summary", `String m.continuity_summary);
      ("active_goal_ids", `List (List.map (fun s -> `String s) m.active_goal_ids));
      ( "active_team_session_id",
        match m.active_team_session_id with
        | Some value -> `String value
        | None -> `Null );
      ("last_team_session_started_at", `String m.last_team_session_started_at);
      ("team_session_start_count_total", `Int m.team_session_start_count_total);
      ("last_autonomous_action_at", `String rt.last_autonomous_action_at);
      ("autonomous_action_count", `Int rt.autonomous_action_count);
      ("autonomous_turn_count", `Int rt.autonomous_turn_count);
      ("autonomous_text_turn_count", `Int rt.autonomous_text_turn_count);
      ("autonomous_tool_turn_count", `Int rt.autonomous_tool_turn_count);
      ("board_reactive_turn_count", `Int rt.board_reactive_turn_count);
      ("mention_reactive_turn_count", `Int rt.mention_reactive_turn_count);
      ("noop_turn_count", `Int rt.noop_turn_count);
      ("last_speech_act", `String rt.last_speech_act);
      ("last_blocker", `String rt.last_blocker);
      ("last_need", `String rt.last_need);
      ("paused", `Bool m.paused);
      ("current_task_id", Json_util.string_opt_to_json m.current_task_id);
    ]

let meta_of_json (json : Yojson.Safe.t) : (keeper_meta, string) result =
  try
    match reject_removed_keeper_meta_fields json with
    | Error e -> Error e
    | Ok () ->
    let name = Safe_ops.json_string ~default:"" "name" json in
    let agent_name = Safe_ops.json_string ~default:"" "agent_name" json in
    let trace_id = Safe_ops.json_string ~default:"" "trace_id" json in
    let trace_history =
      Safe_ops.json_string_list "trace_history" json |> List.filter validate_name
    in
    let goal =
      Safe_ops.json_string ~default:"" "goal" json |> normalize_goal_horizon_text
    in
    let (short_goal, mid_goal, long_goal) =
      resolve_goal_horizons
        ~goal
        ~short_goal_opt:(normalize_goal_horizon_opt (Safe_ops.json_string_opt "short_goal" json))
        ~mid_goal_opt:(normalize_goal_horizon_opt (Safe_ops.json_string_opt "mid_goal" json))
        ~long_goal_opt:(normalize_goal_horizon_opt (Safe_ops.json_string_opt "long_goal" json))
    in
    let soul_profile =
      Safe_ops.json_string ~default:default_soul_profile "soul_profile" json
      |> canonical_soul_profile
      |> Option.value ~default:default_soul_profile
    in
    let social_model =
      Safe_ops.json_string ~default:default_social_model "social_model" json
    in
    let will =
      Safe_ops.json_string ~default:default_keeper_will "will" json
      |> normalize_self_model_text
    in
    let needs =
      Safe_ops.json_string ~default:default_keeper_needs "needs" json
      |> normalize_self_model_text
    in
    let desires =
      Safe_ops.json_string ~default:default_keeper_desires "desires" json
      |> normalize_self_model_text
    in
    let instructions = Safe_ops.json_string ~default:"" "instructions" json in
    let cascade_name =
      Safe_ops.json_string ~default:"keeper_unified" "cascade_name" json
    in
    let policy_voice_enabled =
      Safe_ops.json_bool ~default:(default_voice_enabled_for name) "policy_voice_enabled" json
    in
    let execution_scope =
      Safe_ops.json_string ~default:default_execution_scope "execution_scope" json
    in
    let allowed_paths = Safe_ops.json_string_list "allowed_paths" json in
    let voice_enabled =
      Safe_ops.json_bool ~default:(default_voice_enabled_for name) "voice_enabled" json
    in
    let voice_channel =
      Safe_ops.json_string ~default:(default_voice_channel_for name) "voice_channel" json
      |> canonical_voice_channel
    in
    let voice_agent_id =
      Safe_ops.json_string ~default:(default_voice_agent_id_for name) "voice_agent_id" json
    in
    let scope_kind =
      Safe_ops.json_string ~default:"local" "scope_kind" json |> canonical_scope_kind
    in
    match tool_access_of_meta_json json with
    | Error msg -> Error ("meta parse error: " ^ msg)
    | Ok tool_access ->
        let tool_denylist = Safe_ops.json_string_list "tool_denylist" json in
        let room_scope =
          Safe_ops.json_string ~default:"current" "room_scope" json |> canonical_room_scope
        in
        let mention_targets =
          Safe_ops.json_string_list "mention_targets" json |> dedupe_keep_order
        in
        let joined_room_ids =
          Safe_ops.json_string_list "joined_room_ids" json
          |> List.filter validate_name
          |> dedupe_keep_order
        in
        let last_seen_seq_by_room =
          Yojson.Safe.Util.member "last_seen_seq_by_room" json |> room_seq_map_of_json
        in
        let generation = Safe_ops.json_int ~default:0 "generation" json in
        let proactive_enabled =
          Safe_ops.json_bool ~default:default_proactive_enabled "proactive_enabled" json
        in
        let proactive_idle_sec =
          Safe_ops.json_int ~default:default_proactive_idle_sec "proactive_idle_sec" json
          |> normalize_proactive_idle_sec
        in
        let proactive_cooldown_sec =
          Safe_ops.json_int ~default:default_proactive_cooldown_sec "proactive_cooldown_sec" json
          |> normalize_proactive_cooldown_sec
        in
        let (env_ratio_gate, env_message_gate, env_token_gate) =
          keeper_compaction_policy_from_env ()
        in
        let compaction_profile =
          Safe_ops.json_string ~default:default_compaction_profile "compaction_profile" json
          |> canonical_compaction_profile
          |> Option.value ~default:default_compaction_profile
        in
        let compaction_ratio_gate =
          Safe_ops.json_float ~default:env_ratio_gate "compaction_ratio_gate" json
          |> normalize_compaction_ratio_gate
        in
        let compaction_message_gate =
          Safe_ops.json_int ~default:env_message_gate "compaction_message_gate" json
          |> normalize_compaction_message_gate
        in
        let compaction_token_gate =
          Safe_ops.json_int ~default:env_token_gate "compaction_token_gate" json
          |> normalize_compaction_token_gate
        in
        let continuity_compaction_cooldown_sec =
          Safe_ops.json_int
            ~default:(keeper_continuity_compaction_cooldown_sec ())
            "continuity_compaction_cooldown_sec"
            json
          |> normalize_continuity_compaction_cooldown_sec
        in
        let auto_handoff = Safe_ops.json_bool ~default:true "auto_handoff" json in
        let handoff_threshold = Safe_ops.json_float ~default:0.85 "handoff_threshold" json in
        let handoff_cooldown_sec =
          Safe_ops.json_int ~default:300 "handoff_cooldown_sec" json
        in
        let last_handoff_ts = Safe_ops.json_float ~default:0.0 "last_handoff_ts" json in
        let created_at = Safe_ops.json_string ~default:"" "created_at" json in
        let updated_at = Safe_ops.json_string ~default:"" "updated_at" json in
        let total_turns = Safe_ops.json_int ~default:0 "total_turns" json in
        let total_input_tokens = Safe_ops.json_int ~default:0 "total_input_tokens" json in
        let total_output_tokens = Safe_ops.json_int ~default:0 "total_output_tokens" json in
        let total_tokens = Safe_ops.json_int ~default:0 "total_tokens" json in
        let total_cost_usd = Safe_ops.json_float ~default:0.0 "total_cost_usd" json in
        let last_turn_ts = Safe_ops.json_float ~default:0.0 "last_turn_ts" json in
        let last_model_used = Safe_ops.json_string ~default:"" "last_model_used" json in
        let last_input_tokens = Safe_ops.json_int ~default:0 "last_input_tokens" json in
        let last_output_tokens = Safe_ops.json_int ~default:0 "last_output_tokens" json in
        let last_total_tokens = Safe_ops.json_int ~default:0 "last_total_tokens" json in
        let last_latency_ms = Safe_ops.json_int ~default:0 "last_latency_ms" json in
        let compaction_count = Safe_ops.json_int ~default:0 "compaction_count" json in
        let last_compaction_ts = Safe_ops.json_float ~default:0.0 "last_compaction_ts" json in
        let last_compaction_before_tokens =
          Safe_ops.json_int ~default:0 "last_compaction_before_tokens" json
        in
        let last_compaction_after_tokens =
          Safe_ops.json_int ~default:0 "last_compaction_after_tokens" json
        in
        let proactive_count_total =
          Safe_ops.json_int ~default:0 "proactive_count_total" json
        in
        let last_proactive_ts = Safe_ops.json_float ~default:0.0 "last_proactive_ts" json in
        let last_proactive_reason =
          Safe_ops.json_string ~default:"" "last_proactive_reason" json
        in
        let last_proactive_preview =
          Safe_ops.json_string ~default:"" "last_proactive_preview" json
        in
        let last_compaction_check_ts =
          Safe_ops.json_float ~default:0.0 "last_compaction_check_ts" json
        in
        let last_compaction_decision =
          Safe_ops.json_string ~default:"uninitialized" "last_compaction_decision" json
        in
        let continuity_summary = Safe_ops.json_string ~default:"" "continuity_summary" json in
        let last_continuity_update_ts =
          let parsed_ts = Safe_ops.json_float ~default:0.0 "last_continuity_update_ts" json in
          if parsed_ts <= 0.0 && String.trim continuity_summary <> "" then
            Time_compat.now ()
          else
            parsed_ts
        in
        let active_goal_ids = Safe_ops.json_string_list "active_goal_ids" json in
        let active_team_session_id =
          Safe_ops.json_string_opt "active_team_session_id" json
        in
        let last_team_session_started_at =
          Safe_ops.json_string ~default:"" "last_team_session_started_at" json
        in
        let team_session_start_count_total =
          Safe_ops.json_int ~default:0 "team_session_start_count_total" json
        in
        let last_autonomous_action_at =
          Safe_ops.json_string ~default:"" "last_autonomous_action_at" json
        in
        let autonomous_action_count =
          Safe_ops.json_int ~default:0 "autonomous_action_count" json
        in
        let autonomous_turn_count =
          Safe_ops.json_int ~default:0 "autonomous_turn_count" json
        in
        let autonomous_text_turn_count =
          Safe_ops.json_int ~default:0 "autonomous_text_turn_count" json
        in
        let autonomous_tool_turn_count =
          Safe_ops.json_int ~default:0 "autonomous_tool_turn_count" json
        in
        let board_reactive_turn_count =
          Safe_ops.json_int ~default:0 "board_reactive_turn_count" json
        in
        let mention_reactive_turn_count =
          Safe_ops.json_int ~default:0 "mention_reactive_turn_count" json
        in
        let noop_turn_count =
          Safe_ops.json_int ~default:0 "noop_turn_count" json
        in
        let last_speech_act =
          Safe_ops.json_string ~default:"" "last_speech_act" json
        in
        let last_blocker =
          Safe_ops.json_string ~default:"" "last_blocker" json
        in
        let last_need =
          Safe_ops.json_string ~default:"" "last_need" json
        in
        let paused =
          Safe_ops.json_bool ~default:false "paused" json
        in
        let current_task_id = Safe_ops.json_string_opt "current_task_id" json in
        if not (validate_name name) then
          Error "invalid keeper meta (bad name)"
        else if not (validate_name trace_id) then
          Error "invalid keeper meta (bad trace_id)"
        else
          Ok
            {
          name;
          agent_name = if agent_name = "" then keeper_agent_name name else agent_name;
          goal;
          short_goal;
          mid_goal;
          long_goal;
          soul_profile;
          social_model;
          cascade_name;
          will;
          needs;
          desires;
          instructions;
          policy_voice_enabled;
          execution_scope;
          allowed_paths;
          scope_kind;
          tool_access;
          tool_denylist;
          room_scope;
          mention_targets;
          joined_room_ids;
          last_seen_seq_by_room;
          proactive = {
            enabled = proactive_enabled;
            idle_sec = proactive_idle_sec;
            cooldown_sec = proactive_cooldown_sec;
          };
          compaction = {
            profile = compaction_profile;
            ratio_gate = compaction_ratio_gate;
            message_gate = compaction_message_gate;
            token_gate = compaction_token_gate;
            cooldown_sec = continuity_compaction_cooldown_sec;
          };
          auto_handoff;
          handoff_threshold;
          handoff_cooldown_sec;
          voice_enabled;
          voice_channel;
          voice_agent_id;
          created_at = if created_at = "" then now_iso () else created_at;
          updated_at = if updated_at = "" then now_iso () else updated_at;
          continuity_summary;
          active_goal_ids;
          active_team_session_id;
          last_team_session_started_at;
          team_session_start_count_total;
          paused;
          current_task_id;
          runtime = {
            usage = {
              total_turns;
              total_input_tokens;
              total_output_tokens;
              total_tokens;
              total_cost_usd;
              last_turn_ts;
              last_model_used;
              last_input_tokens;
              last_output_tokens;
              last_total_tokens;
              last_latency_ms;
            };
            compaction_rt = {
              count = compaction_count;
              last_ts = last_compaction_ts;
              last_before_tokens = last_compaction_before_tokens;
              last_after_tokens = last_compaction_after_tokens;
              last_check_ts = last_compaction_check_ts;
              last_decision = last_compaction_decision;
            };
            proactive_rt = {
              count_total = proactive_count_total;
              last_ts = last_proactive_ts;
              last_reason = last_proactive_reason;
              last_preview = last_proactive_preview;
            };
            generation;
            trace_id;
            trace_history;
            last_handoff_ts;
            last_continuity_update_ts;
            last_autonomous_action_at;
            autonomous_action_count;
            autonomous_turn_count;
            autonomous_text_turn_count;
            autonomous_tool_turn_count;
            board_reactive_turn_count;
            mention_reactive_turn_count;
            noop_turn_count;
            last_speech_act;
            last_blocker;
            last_need;
          };
        }
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Error (Printf.sprintf "meta parse error: %s" (Printexc.to_string exn))

let read_meta_file_path path : (keeper_meta option, string) result =
  if not (Sys.file_exists path) then Ok None
  else
    match Safe_ops.read_json_file_safe path with
    | Error e -> Error e
    | Ok json ->
        let json, _scrubbed =
          scrub_persisted_keeper_meta_json ~path json
        in
        (match meta_of_json json with
         | Ok meta -> Ok (Some meta)
         | Error e -> Error e)

let keeper_names config =
  let dir = keeper_dir config in
  match Safe_ops.list_dir_safe dir with
  | Error _ -> []
  | Ok files ->
      files
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.map Filename.remove_extension
      |> List.filter validate_name
      |> List.sort String.compare

let keepalive_keeper_names config =
  keeper_names config
  |> List.filter_map (fun name ->
         match read_meta_file_path (keeper_meta_path config name) with
         | Ok (Some meta) when not meta.paused -> Some meta.name
         | _ -> None)

let persistent_agent_names _config =
  []

let fresher_meta config (meta : keeper_meta) : keeper_meta =
  match read_meta_file_path (keeper_meta_path config meta.name) with
  | Ok (Some existing) ->
      let existing_ts =
        Resilience.Time.parse_iso8601_opt existing.updated_at
        |> Option.value ~default:0.0
      in
      let incoming_ts =
        Resilience.Time.parse_iso8601_opt meta.updated_at
        |> Option.value ~default:0.0
      in
      if existing_ts > incoming_ts then existing else meta
  | Ok None | Error _ -> meta

let write_meta config (m : keeper_meta) : (unit, string) result =
  let persisted = fresher_meta config m in
  let path = keeper_meta_path config persisted.name in
  let json = meta_to_json persisted in
  try
    Keeper_fs.save_json_atomic path json;
    (!runtime_meta_write_sync_hook) config persisted;
    Ok ()
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Error (Printf.sprintf "failed to write meta %s: %s" path (Printexc.to_string exn))

let read_meta config name : (keeper_meta option, string) result =
  let path = keeper_meta_path config name in
  if keeper_debug then
    Log.Keeper.debug "read_meta name=%s path=%s exists=%b"
      name path (Sys.file_exists path);
  read_meta_file_path path

(* Model selection, path utilities, and JSONL helpers
   extracted to Keeper_types_support *)
include Keeper_types_support

(** Fiber-level health for keeper supervisor monitoring.
    Defined here (not in Keeper_supervisor) to avoid circular
    dependencies between keeper_exec_status and the keeper supervisor. *)
type fiber_health =
  | Fiber_alive    (** Fiber running, promise unresolved *)
  | Fiber_zombie   (** Registry entry exists but fiber terminated *)
  | Fiber_dead     (** Restart budget exhausted, manual recovery needed *)
  | Fiber_unknown  (** Not in supervised registry *)

(** Per-tool usage entry for keeper tool tracking.
    Defined here so Keeper_registry can embed it without depending
    on Keeper_tools_oas (avoids module init order issues). *)
type tool_call_entry = {
  mutable count : int;
  mutable successes : int;
  mutable failures : int;
  mutable last_used_at : float;
}
