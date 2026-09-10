(** Runtime_settings — typed runtime parameter declarations.

    Each parameter is registered with [Runtime_params] with validation bounds.

    Surfaces:
    - [board_policy]: message retention count
    - [inference_config]: default model and timeout

    De-hexagonalized: [register_int], [register_float], [register_bool], and
    [register_string] combinators eliminate the per-parameter serialisation /
    deserialisation boilerplate, reducing each registration to three lines.

    @since 2.96.0 *)

(* ── validation helpers ──────────────────────────────────────── *)

let validate_float_range ~min ~max key v =
  if v >= min && v <= max then Ok ()
  else Error (Printf.sprintf "%s must be in [%g, %g], got %g" key min max v)

let validate_int_range ~min ~max key v =
  if v >= min && v <= max then Ok ()
  else Error (Printf.sprintf "%s must be in [%d, %d], got %d" key min max v)

(* The four [deserialize_*] helpers are passed to [Runtime_params.register]
   as [~deserialize] callbacks.  Their [Error] strings surface directly
   in runtime-settings validation failures — operators reading those
   need not only *that* the JSON was wrong-shape but *what kind* they
   actually sent, to correlate against the surface that produced the
   misshapen value.  The previous one-word messages ("expected number",
   "expected integer", "expected string", "expected boolean") discarded
   the received kind. *)

let deserialize_float json =
  match json with
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | other ->
      Error
        (Printf.sprintf
           "deserialize_float: expected JSON number (`Float or `Int), got %s"
           (Json_util.kind_name other))

let deserialize_int json =
  match json with
  | `Int i -> Ok i
  | `Float f ->
      let i = Float.to_int f in
      if Float.equal (Float.of_int i) f then Ok i
      else Error (Printf.sprintf "deserialize_int: expected integer, got %g" f)
  | other ->
      Error
        (Printf.sprintf
           "deserialize_int: expected JSON integer (`Int or whole-valued `Float), got %s"
           (Json_util.kind_name other))

let deserialize_bool json =
  match json with
  | `Bool b -> Ok b
  | other ->
      Error
        (Printf.sprintf "deserialize_bool: expected JSON boolean, got %s"
           (Json_util.kind_name other))

(* ── registration combinators ───────────────────────────────── *)

(** Register a bounded integer parameter.
    Eliminates per-site [serialize]/[deserialize] boilerplate. *)
let register_int ~key ~default ~min ~max ?meta () =
  Runtime_params.register
    ~key
    ~default
    ~validate:(validate_int_range ~min ~max key)
    ~serialize:(fun v -> `Int v)
    ~deserialize:deserialize_int
    ?meta
    ()

(** Register a bounded float parameter. *)
let register_float ~key ~default ~min ~max ?meta () =
  Runtime_params.register
    ~key
    ~default
    ~validate:(validate_float_range ~min ~max key)
    ~serialize:(fun v -> `Float v)
    ~deserialize:deserialize_float
    ?meta
    ()

(** Register an unconstrained boolean parameter. *)
let register_bool ~key ~default ?meta () =
  Runtime_params.register
    ~key
    ~default
    ~validate:(fun _ -> Ok ())
    ~serialize:(fun v -> `Bool v)
    ~deserialize:deserialize_bool
    ?meta
    ()

(** Register a parameter whose values carry names.  [to_string] / [of_string]
    are the owning module's own spelling, so the wire form, the runtime.toml
    form and the picker label are one vocabulary rather than three.

    [choices] is what a picker may offer.  A domain that is only partly closed
    lists its closed names there and still accepts the rest through
    [of_string]: the picker walks the common values and the parameterized form
    is typed. *)
let register_enum ~key ~default ~to_string ~of_string ~choices ~description () =
  Runtime_params.register
    ~key
    ~default
    (* [of_string] is the judge.  A value that does not survive the round trip
       is not one this param holds, whatever handed it over. *)
    ~validate:(fun v ->
      match of_string (to_string v) with
      | Ok (_ : 'a) -> Ok ()
      | Error detail -> Error (Printf.sprintf "%s: %s" key detail))
    ~serialize:(fun v -> `String (to_string v))
    ~deserialize:(fun json ->
      match json with
      | `String raw -> of_string raw
      | other ->
          Error
            (Printf.sprintf
               "deserialize_enum: expected JSON string, got %s"
               (Json_util.kind_name other)))
    ~meta:{ description; value_type = "enum";
            min_value = None; max_value = None; choices }
    ()

(* ── dashboard surface (display-only) ────────────────────────── *)

(** Maximum path length before truncation in dashboard output. *)
let dashboard_max_path_length =
  register_int
    ~key:"dashboard.max_path_length"
    ~default:(fun () -> 30)
    ~min:10 ~max:200
    ~meta:{ description = "대시보드 경로 출력 최대 길이 (문자)";
            value_type = "int";
            min_value = Some (`Int 10); max_value = Some (`Int 200); choices = [] }
    ()

(** Maximum message body length before truncation. *)
let dashboard_max_message_length =
  register_int
    ~key:"dashboard.max_message_length"
    ~default:(fun () -> 35)
    ~min:10 ~max:500
    ~meta:{ description = "대시보드 메시지 출력 최대 길이 (문자)";
            value_type = "int";
            min_value = Some (`Int 10); max_value = Some (`Int 500); choices = [] }
    ()

(** Maximum number of pending tasks to show in dashboard. *)
let dashboard_max_pending_tasks =
  register_int
    ~key:"dashboard.max_pending_tasks"
    ~default:(fun () -> 5)
    ~min:1 ~max:50
    ~meta:{ description = "대시보드 pending task 표시 최대 개수";
            value_type = "int";
            min_value = Some (`Int 1); max_value = Some (`Int 50); choices = [] }
    ()

(** Maximum number of recent messages to show. *)
let dashboard_max_recent_messages =
  register_int
    ~key:"dashboard.max_recent_messages"
    ~default:(fun () -> 5)
    ~min:1 ~max:50
    ~meta:{ description = "대시보드 recent message 표시 최대 개수";
            value_type = "int";
            min_value = Some (`Int 1); max_value = Some (`Int 50); choices = [] }
    ()

(** Minimum section border length. *)
let dashboard_min_border_length =
  register_int
    ~key:"dashboard.min_border_length"
    ~default:(fun () -> 45)
    ~min:20 ~max:200
    ~meta:{ description = "대시보드 섹션 경계선 최소 길이";
            value_type = "int";
            min_value = Some (`Int 20); max_value = Some (`Int 200); choices = [] }
    ()

(** Threshold for surfacing a quiet-agent warning in dashboard labels. *)
let dashboard_agent_quiet_threshold_sec =
  register_float
    ~key:"dashboard.agent_quiet_threshold_sec"
    ~default:(fun () -> Env_config_runtime.InternalTimers.label_quiet_threshold_sec)
    ~min:30.0 ~max:Masc_time_constants.day
    ~meta:{
      description = "대시보드 quiet 상태 임계값(초)";
      value_type = "float";
      min_value = Some (`Float 30.0);
      max_value = Some (`Float Masc_time_constants.day); choices = [] }
    ()

(** Threshold for surfacing a stuck-agent warning in dashboard labels. *)
let dashboard_agent_stuck_threshold_sec =
  register_float
    ~key:"dashboard.agent_stuck_threshold_sec"
    ~default:(fun () -> Env_config_runtime.InternalTimers.label_stuck_threshold_sec)
    ~min:60.0 ~max:(7.0 *. Masc_time_constants.day)
    ~meta:{
      description = "대시보드 STUCK 상태 임계값(초)";
      value_type = "float";
      min_value = Some (`Float 60.0);
      max_value = Some (`Float (7.0 *. Masc_time_constants.day)); choices = [] }
    ()

(* ── cost_policy surface ──────────────────────────────────────── *)

(* ── keeper_lifecycle surface ────────────────────────────────── *)

let keeper_supervisor_sweep_sec =
  register_float
    ~key:"keeper.supervisor_sweep_sec"
    ~default:(fun () -> Env_config_keeper.KeeperSupervisor.sweep_interval_sec)
    ~min:10.0 ~max:120.0
    ~meta:{ description = "Supervisor sweep 주기(초)";
            value_type = "float";
            min_value = Some (`Float 10.0); max_value = Some (`Float 120.0); choices = [] }
    ()

let keeper_keepalive_interval_sec =
  Runtime_params.register
    ~key:"keeper.keepalive_interval_sec"
    ~default:(fun () -> Env_config_keeper.KeeperKeepalive.interval_sec)
    ~validate:(fun interval_sec ->
      if interval_sec > 0
      then Ok ()
      else Error "keeper.keepalive_interval_sec must be a positive integer")
    ~serialize:(fun interval_sec -> `Int interval_sec)
    ~deserialize:deserialize_int
    ~meta:
      { description = "Heartbeat 주기(초)"
      ; value_type = "int"
      ; min_value = Some (`Int 1)
      ; max_value = None
      ; choices = []
      }
    ()

(* ── keeper_diagnostics surface ───────────────────────────────── *)

let keeper_snapshot_sec =
  register_int
    ~key:"keeper.snapshot_sec"
    ~default:(fun () -> Env_config_keeper.KeeperRuntime.snapshot_sec)
    ~min:15 ~max:Masc_time_constants.hour_int
    ~meta:{ description = "Snapshot 캡처 주기(초)";
            value_type = "int";
            min_value = Some (`Int 15);
            max_value = Some (`Int Masc_time_constants.hour_int); choices = [] }
    ()

let keeper_work_as_hb_enabled =
  register_bool
    ~key:"keeper.work_as_hb_enabled"
    ~default:(fun () -> Env_config_keeper.WorkAsHeartbeat.enabled)
    ~meta:{ description = "Work-as-heartbeat 활성화 여부";
            value_type = "bool";
            min_value = None; max_value = None; choices = [] }
    ()

let keeper_stage_timing_ring_size =
  register_int
    ~key:"keeper.stage_timing_ring_size"
    ~default:(fun () -> Env_config_keeper.KeeperProactive.stage_timing_ring_size)
    ~min:10 ~max:1000
    ~meta:{ description = "Stage timing ring buffer 크기 (fiber restart 시 적용)";
            value_type = "int";
            min_value = Some (`Int 10); max_value = Some (`Int 1000); choices = [] }
    ()

(* Whether identity scalars (a `user:` login in a GitHub hosts.yml) mined
   from keeper secret files are masked as [REDACTED] in chat text and tool
   output. Credential-shaped values are always masked
   ([Keeper_secret_redaction.credential_shaped_key]); this switch only governs
   the identity half.

   Off by default: the scalar miner reads every `key: value` line of a secret
   file, so with it on a GitHub account name -- public in every repo URL --
   came back as [REDACTED] throughout chat prose (2026-08-29, keeper
   edgar.a.poe), which is what the switch was added for. Operators who want
   account names masked as well turn it on. *)
let keeper_chat_redact_identity_scalars =
  register_bool
    ~key:"keeper.chat_redact_identity_scalars"
    ~default:(fun () -> false)
    ~meta:{ description = "secret 파일의 계정명(user 등) 값도 채팅·도구 출력에서 [REDACTED] 처리 (토큰류는 항상 처리)";
            value_type = "bool";
            min_value = None; max_value = None; choices = [] }
    ()

(* ── connector trigger surface ───────────────────────────────── *)

(* What a connector's gateway resolved from [MASC_*_TRIGGER_POLICY] and
   runtime.toml at startup.  The param default reads this rather than walking
   those planes itself, because [Runtime_params.get] calls the default thunk on
   every read and a policy check happens per inbound message: resolution is a
   file read, and it belongs to boot.

   A gateway that never starts (no bot token) leaves the hardcoded baseline
   here.  The gateways therefore install this before checking their token, so
   the params surface reports the configured policy even for a connector that
   is switched off — otherwise the screen would say [mention_or_thread] while
   runtime.toml said something else. *)
let discord_trigger_policy_configured =
  ref (Discord_gateway_state.Mention_or_thread : Discord_gateway_state.trigger_policy)

let slack_trigger_policy_configured =
  ref (Slack_gateway_state.Mention_or_thread : Slack_gateway_state.trigger_policy)

let set_discord_trigger_policy_configured policy =
  discord_trigger_policy_configured := policy

let set_slack_trigger_policy_configured policy =
  slack_trigger_policy_configured := policy

(* [user_only:<id>] is left out of [choices] on purpose: it carries an id, so
   it is not a value a picker can offer.  Both parsers still accept it, and the
   operator types that form. *)
let trigger_policy_choices = [ "mention_only"; "mention_or_thread"; "all" ]

let trigger_policy_description =
  "봇이 언제 응답하는가 — mention_only: 멘션된 글만. mention_or_thread: \
   멘션 또는 스레드 안의 모든 글. all: 사람이 쓴 모든 글. \
   user_only:<id> 로 한 사람만 받을 수도 있다"

(** Which Discord messages start a turn. *)
let discord_trigger_policy =
  register_enum
    ~key:"discord.trigger_policy"
    ~default:(fun () -> !discord_trigger_policy_configured)
    ~to_string:Discord_gateway_state.trigger_policy_to_string
    ~of_string:Discord_gateway_state.parse_trigger_policy
    ~choices:trigger_policy_choices
    ~description:trigger_policy_description
    ()

(** Which Slack messages start a turn. *)
let slack_trigger_policy =
  register_enum
    ~key:"slack.trigger_policy"
    ~default:(fun () -> !slack_trigger_policy_configured)
    ~to_string:Slack_gateway_state.trigger_policy_to_string
    ~of_string:Slack_gateway_state.parse_trigger_policy
    ~choices:trigger_policy_choices
    ~description:trigger_policy_description
    ()

(* ── surface catalog ─────────────────────────────────────────── *)

type surface = {
  id : string;
  description : string;
  param_keys : string list;
}

let surfaces =
  [
    {
      id = "keeper_lifecycle";
      description = "Keeper heartbeat and supervisor timing";
      param_keys = [
        "keeper.supervisor_sweep_sec";
        "keeper.keepalive_interval_sec";
      ];
    };
    {
      id = "keeper_diagnostics";
      description = "Keeper snapshot, heartbeat tuning, and profiling ring";
      param_keys = [
        "keeper.snapshot_sec";
        "keeper.work_as_hb_enabled";
        "keeper.stage_timing_ring_size";
      ];
    };
    {
      id = "keeper_chat_redaction";
      description = "Keeper chat and tool-output secret masking";
      param_keys = [
        "keeper.chat_redact_identity_scalars";
      ];
    };
    {
      id = "keeper_turn";
      description = "Keeper LLM turn parameters with verified runtime consumers";
      param_keys = [
        "keeper.turn.temperature";
        "keeper.turn.batch_limit";
        "keeper.turn.enable_thinking";
        "keeper.turn.max_tool_rounds";
        "keeper.tool_search.carry_window";
      ];
    };
    {
      id = "keeper_proactive";
      description = "Keeper proactive turn scheduling and bootstrap timing";
      param_keys = [
        "keeper.proactive.warmup_sec";
        "keeper.proactive.stagger_step_sec";
        "keeper.bootstrap.retry_interval_sec";
      ];
    };
    {
      id = "keeper_world_observation";
      description =
        "What a keeper turn is told about the world — board posts, fleet \
         messages, its own past tool calls, and the briefing's share of the \
         request body";
      param_keys = [
        "keeper.board.own_recent.max";
        "keeper.fleet.messages.max";
        "keeper.own_actions.turns.max";
        "keeper.context.briefing.share_percent";
      ];
    };
    {
      id = "keeper_hitl";
      description =
        "What the HITL judgment bundle carries and how many judgments a keeper \
         runs at once";
      param_keys = [
        "keeper.hitl.thinking_blocks";
        "keeper.hitl.observation_stderr_bytes";
        "keeper.hitl.max_concurrent_per_keeper";
      ];
    };
    {
      id = "connector_trigger";
      description = "Which inbound messages start a turn, per connector";
      param_keys = [
        "discord.trigger_policy";
        "slack.trigger_policy";
      ];
    };
    {
      id = "dashboard";
      description = "Dashboard rendering — truncation lengths, row limits, borders, status thresholds";
      param_keys = [
        "dashboard.max_path_length";
        "dashboard.max_message_length";
        "dashboard.max_pending_tasks";
        "dashboard.max_recent_messages";
        "dashboard.min_border_length";
        "dashboard.agent_quiet_threshold_sec";
        "dashboard.agent_stuck_threshold_sec";
      ];
    };
  ]

(* ── initialization ─────────────────────────────────────────── *)

(** Force module initialization to guarantee all params are registered
    before [Runtime_params.restore]. Call from server bootstrap. *)
let ensure_init () =
  let (_ : _) = Runtime_params.get dashboard_max_path_length in
  let (_ : _) = Runtime_params.get dashboard_max_message_length in
  let (_ : _) = Runtime_params.get dashboard_max_pending_tasks in
  let (_ : _) = Runtime_params.get dashboard_max_recent_messages in
  let (_ : _) = Runtime_params.get dashboard_min_border_length in
  let (_ : _) = Runtime_params.get dashboard_agent_quiet_threshold_sec in
  let (_ : _) = Runtime_params.get dashboard_agent_stuck_threshold_sec in
  let (_ : _) = Runtime_params.get discord_trigger_policy in
  let (_ : _) = Runtime_params.get slack_trigger_policy in
  Keeper_config.ensure_runtime_params_init ()

let surfaces_json () =
  `List
    (List.map
       (fun s ->
         `Assoc
           [
             ("id", `String s.id);
             ("description", `String s.description);
             ("param_keys", `List (List.map (fun k -> `String k) s.param_keys));
           ])
       surfaces)
