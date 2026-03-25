(** Keeper_types — shared keeper contract, registry/store helpers,
    path resolution, and model-selection utilities. *)

(* Utility functions, canonical helpers, profile defaults, and dir helpers
   extracted to Keeper_types_profile *)
include Keeper_types_profile


type compaction_state = {
  profile: string;
  ratio_gate: float;
  message_gate: int;
  token_gate: int;
  cooldown_sec: int;
  count: int;
  last_ts: float;
  last_before_tokens: int;
  last_after_tokens: int;
  last_check_ts: float;
  last_decision: string;
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

type proactive_config = {
  enabled: bool;
  idle_sec: int;
  cooldown_sec: int;
  count_total: int;
  last_ts: float;
  last_reason: string;
  last_preview: string;
}

type keeper_meta = {
  name: string;
  agent_name: string;
  persona_profile_path: string;
  trace_id: string;
  trace_history: string list;
  goal: string;
  short_goal: string;
  mid_goal: string;
  long_goal: string;
  soul_profile: string;
  cascade_name: string;
  will: string;
  needs: string;
  desires: string;
  instructions: string;
  models: string list;
  allowed_models: string list;
  active_model: string;
  policy_mode: string;
  policy_voice_enabled: bool;
  policy_shell_mode: string;
  execution_scope: string;
  allowed_paths: string list;
  scope_kind: string;
  room_scope: string;
  trigger_mode: string;
  mention_targets: string list;
  joined_room_ids: string list;
  last_seen_seq_by_room: (string * int) list;
  generation: int;
  presence_keepalive: bool;
  presence_keepalive_sec: int;
  proactive: proactive_config;
  compaction: compaction_state;
  auto_handoff: bool;
  handoff_threshold: float;
  handoff_cooldown_sec: int;
  voice_enabled: bool;
  voice_channel: string;
  voice_agent_id: string;
  last_handoff_ts: float;
  created_at: string;
  updated_at: string;
  usage: usage_metrics;

  last_continuity_update_ts: float;
  continuity_summary: string;
  active_goal_ids: string list;
  active_team_session_id: string option;
  last_team_session_started_at: string;
  team_session_start_count_total: int;
  last_autonomous_action_at: string;
  autonomous_action_count: int;
  last_triage_triggers: string;
  paused: bool;
}

let now_iso () = Types.now_iso ()

let meta_to_json (m : keeper_meta) : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String m.name);
      ("agent_name", `String m.agent_name);
      ("persona_profile_path", `String m.persona_profile_path);
      ("trace_id", `String m.trace_id);
      ("trace_history", `List (List.map (fun s -> `String s) m.trace_history));
      ("goal", `String m.goal);
      ("short_goal", `String m.short_goal);
      ("mid_goal", `String m.mid_goal);
      ("long_goal", `String m.long_goal);
      ("soul_profile", `String m.soul_profile);
      ("cascade_name", `String m.cascade_name);
      ("will", `String m.will);
      ("needs", `String m.needs);
      ("desires", `String m.desires);
      ("instructions", `String m.instructions);
      ("models", `List (List.map (fun s -> `String s) m.models));
      ("allowed_models", `List (List.map (fun s -> `String s) m.allowed_models));
      ("active_model", `String m.active_model);
      ("policy_mode", `String m.policy_mode);
      ("policy_voice_enabled", `Bool m.policy_voice_enabled);
      ("policy_shell_mode", `String m.policy_shell_mode);
      ("execution_scope", `String m.execution_scope);
      ("allowed_paths", `List (List.map (fun s -> `String s) m.allowed_paths));
      ("scope_kind", `String m.scope_kind);
      ("room_scope", `String m.room_scope);
      ("trigger_mode", `String m.trigger_mode);
      ("mention_targets", `List (List.map (fun s -> `String s) m.mention_targets));
      ("joined_room_ids", `List (List.map (fun s -> `String s) m.joined_room_ids));
      ("last_seen_seq_by_room", room_seq_map_to_json m.last_seen_seq_by_room);
      ("generation", `Int m.generation);
      ("presence_keepalive", `Bool m.presence_keepalive);
      ("presence_keepalive_sec", `Int m.presence_keepalive_sec);
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
      ("last_handoff_ts", `Float m.last_handoff_ts);
      ("created_at", `String m.created_at);
      ("updated_at", `String m.updated_at);
      ("total_turns", `Int m.usage.total_turns);
      ("total_input_tokens", `Int m.usage.total_input_tokens);
      ("total_output_tokens", `Int m.usage.total_output_tokens);
      ("total_tokens", `Int m.usage.total_tokens);
      ("total_cost_usd", `Float m.usage.total_cost_usd);
      ("last_turn_ts", `Float m.usage.last_turn_ts);
      ("last_model_used", `String m.usage.last_model_used);
      ("last_input_tokens", `Int m.usage.last_input_tokens);
      ("last_output_tokens", `Int m.usage.last_output_tokens);
      ("last_total_tokens", `Int m.usage.last_total_tokens);
      ("last_latency_ms", `Int m.usage.last_latency_ms);
      ("compaction_count", `Int m.compaction.count);
      ("last_compaction_ts", `Float m.compaction.last_ts);
      ("last_compaction_before_tokens", `Int m.compaction.last_before_tokens);
      ("last_compaction_after_tokens", `Int m.compaction.last_after_tokens);
      ("proactive_count_total", `Int m.proactive.count_total);
      ("last_proactive_ts", `Float m.proactive.last_ts);
      ("last_proactive_reason", `String m.proactive.last_reason);
      ("last_proactive_preview", `String m.proactive.last_preview);
      ("last_compaction_check_ts", `Float m.compaction.last_check_ts);
      ("last_compaction_decision", `String m.compaction.last_decision);
      ("last_continuity_update_ts", `Float m.last_continuity_update_ts);
      ("continuity_summary", `String m.continuity_summary);
      ("active_goal_ids", `List (List.map (fun s -> `String s) m.active_goal_ids));
      ( "active_team_session_id",
        match m.active_team_session_id with
        | Some value -> `String value
        | None -> `Null );
      ("last_team_session_started_at", `String m.last_team_session_started_at);
      ("team_session_start_count_total", `Int m.team_session_start_count_total);
      ("last_autonomous_action_at", `String m.last_autonomous_action_at);
      ("autonomous_action_count", `Int m.autonomous_action_count);
      ("last_triage_triggers", `String m.last_triage_triggers);
      ("paused", `Bool m.paused);
    ]

let meta_of_json (json : Yojson.Safe.t) : (keeper_meta, string) result =
  try
    let name = Safe_ops.json_string ~default:"" "name" json in
    let agent_name = Safe_ops.json_string ~default:"" "agent_name" json in
    let persona_profile_path = Safe_ops.json_string ~default:"" "persona_profile_path" json in
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
    let models_raw = Safe_ops.json_string_list "models" json in
    let models =
      if models_raw <> [] then models_raw
      else Oas_model_resolve.models_of_cascade_name cascade_name
    in
    let allowed_models_raw = Safe_ops.json_string_list "allowed_models" json in
    let allowed_models =
      let base = if allowed_models_raw <> [] then allowed_models_raw else models in
      dedupe_keep_order base
    in
    let active_model = Safe_ops.json_string ~default:"" "active_model" json in
    let policy_mode = "heuristic" in
    let policy_voice_enabled =
      Safe_ops.json_bool ~default:(default_voice_enabled_for name) "policy_voice_enabled" json
    in
    let policy_shell_mode =
      Safe_ops.json_string ~default:"disabled" "policy_shell_mode" json
      |> canonical_policy_shell_mode
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
    let room_scope =
      Safe_ops.json_string ~default:"current" "room_scope" json |> canonical_room_scope
    in
    let trigger_mode =
      Safe_ops.json_string ~default:"explicit_only" "trigger_mode" json
      |> canonical_trigger_mode
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
    let presence_keepalive = Safe_ops.json_bool ~default:true "presence_keepalive" json in
    let presence_keepalive_sec =
      Safe_ops.json_int ~default:30 "presence_keepalive_sec" json
    in
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
    let handoff_cooldown_sec = Safe_ops.json_int ~default:300 "handoff_cooldown_sec" json in
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
    let proactive_count_total = Safe_ops.json_int ~default:0 "proactive_count_total" json in
    let last_proactive_ts = Safe_ops.json_float ~default:0.0 "last_proactive_ts" json in
    let last_proactive_reason = Safe_ops.json_string ~default:"" "last_proactive_reason" json in
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
    let last_triage_triggers =
      Safe_ops.json_string ~default:"" "last_triage_triggers" json
    in
    let paused =
      Safe_ops.json_bool ~default:false "paused" json
    in
    if not (validate_name name) then
      Error "invalid keeper meta (bad name)"
    else if not (validate_name trace_id) then
      Error "invalid keeper meta (bad trace_id)"
    else
      Ok
        {
          name;
          agent_name = if agent_name = "" then keeper_agent_name name else agent_name;
          persona_profile_path;
          trace_id;
          trace_history;
          goal;
          short_goal;
          mid_goal;
          long_goal;
          soul_profile;
          cascade_name;
          will;
          needs;
          desires;
          instructions;
          models;
          allowed_models;
          active_model;
          policy_mode;
          policy_voice_enabled;
          policy_shell_mode;
          execution_scope;
          allowed_paths;
          scope_kind;
          room_scope;
          trigger_mode;
          mention_targets;
          joined_room_ids;
          last_seen_seq_by_room;
          generation;
          presence_keepalive;
          presence_keepalive_sec;
          proactive = {
            enabled = proactive_enabled;
            idle_sec = proactive_idle_sec;
            cooldown_sec = proactive_cooldown_sec;
            count_total = proactive_count_total;
            last_ts = last_proactive_ts;
            last_reason = last_proactive_reason;
            last_preview = last_proactive_preview;
          };
          compaction = {
            profile = compaction_profile;
            ratio_gate = compaction_ratio_gate;
            message_gate = compaction_message_gate;
            token_gate = compaction_token_gate;
            cooldown_sec = continuity_compaction_cooldown_sec;
            count = compaction_count;
            last_ts = last_compaction_ts;
            last_before_tokens = last_compaction_before_tokens;
            last_after_tokens = last_compaction_after_tokens;
            last_check_ts = last_compaction_check_ts;
            last_decision = last_compaction_decision;
          };
          auto_handoff;
          handoff_threshold;
          handoff_cooldown_sec;
          voice_enabled;
          voice_channel;
          voice_agent_id;
          last_handoff_ts;
          created_at = if created_at = "" then now_iso () else created_at;
          updated_at = if updated_at = "" then now_iso () else updated_at;
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
          last_continuity_update_ts;
          continuity_summary;
          active_goal_ids;
          active_team_session_id;
          last_team_session_started_at;
          team_session_start_count_total;
          last_autonomous_action_at;
          autonomous_action_count;
          last_triage_triggers;
          paused;
        }
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Error (Printf.sprintf "meta parse error: %s" (Printexc.to_string exn))

type resident_keeper_spec = {
  name : string;
  persistent_name : string;
  desired : bool;
  voice_enabled : bool;
  voice_channel : string;
  voice_agent_id : string;
  seed_meta : Yojson.Safe.t;
  created_at : string;
  updated_at : string;
}

let resident_keeper_dir (config : Room.config) =
  let d = Filename.concat (Room.masc_root_dir config) "resident-keepers" in
  mkdir_p d;
  d

let resident_keeper_path config name =
  Filename.concat (resident_keeper_dir config) (name ^ ".json")

let resident_keeper_to_json (spec : resident_keeper_spec) =
  `Assoc
    [
      ("name", `String spec.name);
      ("persistent_name", `String spec.persistent_name);
      ("desired", `Bool spec.desired);
      ("voice_enabled", `Bool spec.voice_enabled);
      ("voice_channel", `String spec.voice_channel);
      ("voice_agent_id", `String spec.voice_agent_id);
      ("seed_meta", spec.seed_meta);
      ("created_at", `String spec.created_at);
      ("updated_at", `String spec.updated_at);
    ]

let resident_keeper_of_json (json : Yojson.Safe.t) :
    (resident_keeper_spec, string) result =
  try
    let open Yojson.Safe.Util in
    let name = json |> member "name" |> to_string in
    let persistent_name =
      json |> member "persistent_name" |> to_string_option
      |> Option.value ~default:name
    in
    let desired =
      match json |> member "desired" with
      | `Bool value -> value
      | _ -> true
    in
    let voice_enabled =
      match json |> member "voice_enabled" with
      | `Bool value -> value
      | _ -> default_voice_enabled_for name
    in
    let voice_channel =
      match json |> member "voice_channel" |> to_string_option with
      | Some value -> canonical_voice_channel value
      | None -> default_voice_channel_for name
    in
    let voice_agent_id =
      json |> member "voice_agent_id" |> to_string_option
      |> Option.value ~default:(default_voice_agent_id_for name)
    in
    let seed_meta =
      match json |> member "seed_meta" with
      | `Assoc _ as value -> value
      | _ -> `Assoc []
    in
    let created_at =
      json |> member "created_at" |> to_string_option
      |> Option.value ~default:(now_iso ())
    in
    let updated_at =
      json |> member "updated_at" |> to_string_option
      |> Option.value ~default:created_at
    in
    Ok
      {
        name;
        persistent_name;
        desired;
        voice_enabled;
        voice_channel;
        voice_agent_id;
        seed_meta;
        created_at;
        updated_at;
      }
  with Yojson.Safe.Util.Type_error (msg, _) | Failure msg ->
    Error ("resident keeper parse error: " ^ msg)

let write_resident_keeper config (spec : resident_keeper_spec) :
    (unit, string) result =
  let path = resident_keeper_path config spec.name in
  let content = Yojson.Safe.pretty_to_string (resident_keeper_to_json spec) in
  try
    Fs_compat.save_file path content;
    Ok ()
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Error
      (Printf.sprintf "failed to write resident keeper %s: %s" path
         (Printexc.to_string exn))

let read_resident_keeper config name : (resident_keeper_spec option, string) result =
  let path = resident_keeper_path config name in
  if not (Sys.file_exists path) then Ok None
  else
    try
      let json = Room_utils.read_json_local path in
      match resident_keeper_of_json json with
      | Ok spec -> Ok (Some spec)
      | Error msg -> Error msg
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Error
        (Printf.sprintf "failed to read resident keeper %s: %s" path
           (Printexc.to_string exn))

let remove_resident_keeper config name =
  Safe_ops.remove_file_logged ~context:"resident_keeper_remove"
    (resident_keeper_path config name)

let list_resident_keepers config : resident_keeper_spec list =
  let dir = resident_keeper_dir config in
  match Safe_ops.list_dir_safe dir with
  | Error _ -> []
  | Ok files ->
      files
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.map Filename.remove_extension
      |> List.filter validate_name
      |> List.filter_map (fun name ->
             match read_resident_keeper config name with
             | Ok (Some spec) -> Some spec
             | _ -> None)
      |> List.sort (fun a b -> String.compare a.name b.name)

let resident_keeper_names config =
  list_resident_keepers config |> List.map (fun spec -> spec.name)

let is_resident_keeper config name =
  List.mem name (resident_keeper_names config)

let register_resident_keeper_from_meta config (meta : keeper_meta) :
    (unit, string) result =
  let existing =
    match read_resident_keeper config meta.name with
    | Ok (Some spec) -> Some spec
    | _ -> None
  in
  let created_at =
    match existing with
    | Some spec -> spec.created_at
    | None -> now_iso ()
  in
  write_resident_keeper config
    {
      name = meta.name;
      persistent_name = meta.name;
      desired = true;
      voice_enabled = meta.voice_enabled;
      voice_channel = meta.voice_channel;
      voice_agent_id = meta.voice_agent_id;
      seed_meta = meta_to_json meta;
      created_at;
      updated_at = now_iso ();
    }

let persistent_agent_names ?resident_names config =
  let dir = keeper_dir config in
  let resident = match resident_names with
    | Some n -> n
    | None -> resident_keeper_names config
  in
  match Safe_ops.list_dir_safe dir with
  | Error _ -> []
  | Ok files ->
      files
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.map Filename.remove_extension
      |> List.filter validate_name
      |> List.filter (fun name -> not (List.mem name resident))
      |> List.sort String.compare

let sync_registered_resident_keeper_from_meta config (meta : keeper_meta) :
    (unit, string) result =
  match read_resident_keeper config meta.name with
  | Ok None -> Ok ()
  | Ok (Some _) -> register_resident_keeper_from_meta config meta
  | Error e -> Error e

let write_meta config (m : keeper_meta) : (unit, string) result =
  let path = keeper_meta_path config m.name in
  let content = Yojson.Safe.pretty_to_string (meta_to_json m) in
  try
    Fs_compat.save_file path content;
    (match sync_registered_resident_keeper_from_meta config m with
     | Ok () -> Ok ()
     | Error e ->
         Error
           (Printf.sprintf
              "meta written but resident sync failed for %s: %s"
              m.name e))
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Error (Printf.sprintf "failed to write meta %s: %s" path (Printexc.to_string exn))

let read_meta config name : (keeper_meta option, string) result =
  let path = keeper_meta_path config name in
  if keeper_debug then
    Log.Keeper.debug "read_meta name=%s path=%s exists=%b"
      name path (Sys.file_exists path);
  if not (Sys.file_exists path) then Ok None
  else
    match Safe_ops.read_json_file_safe path with
    | Error e -> Error e
    | Ok json -> (
        match meta_of_json json with
        | Ok m -> Ok (Some m)
        | Error e -> Error e)

(* Model selection, path utilities, and JSONL helpers
   extracted to Keeper_types_resident *)
include Keeper_types_resident

(** Fiber-level health for keeper supervisor monitoring.
    Defined here (not in Keeper_resident_supervisor) to avoid circular
    dependencies between keeper_exec_status and the resident supervisor. *)
type fiber_health =
  | Fiber_alive    (** Fiber running, promise unresolved *)
  | Fiber_zombie   (** Registry entry exists but fiber terminated *)
  | Fiber_dead     (** Restart budget exhausted, manual recovery needed *)
  | Fiber_unknown  (** Not in supervised registry *)
