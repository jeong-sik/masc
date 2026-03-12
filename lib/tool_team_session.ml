(** MCP tools for long-running team sessions (1h orchestration). *)

open Types
open Tool_args

type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
}

type result = bool * string

let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let parse_execution_scope args =
  match String.lowercase_ascii (get_string args "execution_scope" "observe_only") with
  | "limited_code_change" -> Team_session_types.Limited_code_change
  | _ -> Team_session_types.Observe_only

let parse_orchestration_mode args =
  match String.lowercase_ascii (get_string args "orchestration_mode" "assist") with
  | "manual" -> Team_session_types.Manual
  | "auto" -> Team_session_types.Auto
  | _ -> Team_session_types.Assist

let parse_communication_mode args =
  match String.lowercase_ascii (get_string args "communication_mode" "broadcast") with
  | "off" -> Team_session_types.Comm_off
  | "portal" -> Team_session_types.Comm_portal
  | "hybrid" -> Team_session_types.Comm_hybrid
  | _ -> Team_session_types.Comm_broadcast

let parse_scale_profile args =
  match String.lowercase_ascii (get_string args "scale_profile" "standard") with
  | "local64" -> Team_session_types.Scale_local64
  | _ -> Team_session_types.Scale_standard

let parse_control_profile ~scale_profile args =
  match get_string_opt args "control_profile" with
  | Some raw -> (
      match
        Team_session_types.control_profile_of_string
          (String.lowercase_ascii (String.trim raw))
      with
      | profile -> profile)
  | None -> (
      match scale_profile with
      | Team_session_types.Scale_local64 ->
          Team_session_types.Control_hierarchical_quality_v1
      | Team_session_types.Scale_standard -> Team_session_types.Control_flat)

let parse_fallback_policy args =
  match String.lowercase_ascii (get_string args "fallback_policy" "cascade_then_task") with
  | "none" -> Team_session_types.Fallback_none
  | "strict_local_only" -> Team_session_types.Fallback_none
  | "task_only" -> Team_session_types.Fallback_task_only
  | "local_first_conditional" -> Team_session_types.Fallback_cascade_then_task
  | "cloud_first" -> Team_session_types.Fallback_cascade_then_task
  | _ -> Team_session_types.Fallback_cascade_then_task

let parse_instruction_profile args =
  match String.lowercase_ascii (get_string args "instruction_profile" "standard") with
  | "strict" -> Team_session_types.Profile_strict
  | _ -> Team_session_types.Profile_standard

let parse_alert_channel args =
  match String.lowercase_ascii (get_string args "alert_channel" "both") with
  | "broadcast" -> Team_session_types.Alert_broadcast
  | "board" -> Team_session_types.Alert_board
  | _ -> Team_session_types.Alert_both

let parse_report_formats args =
  let raw = get_string_list args "report_formats" in
  let parsed = Team_session_types.report_formats_of_strings raw in
  if parsed = [] then [ Team_session_types.Markdown; Team_session_types.Json ]
  else parsed

let get_agent_names args key =
  match Yojson.Safe.Util.member key args with
  | `List xs ->
      xs
      |> List.filter_map (function
             | `String s ->
                 let t = String.trim s in
                 if t = "" then None else Some t
             | `Assoc fields -> (
                 match List.assoc_opt "name" fields with
                 | Some (`String s) ->
                     let t = String.trim s in
                     if t = "" then None else Some t
                 | _ -> None)
             | _ -> None)
  | _ -> []

let parse_turn_kind args =
  let raw = get_string args "turn_kind" "note" |> String.trim |> String.lowercase_ascii in
  match Team_session_types.turn_kind_of_string raw with
  | Some k -> Ok k
  | None ->
      Error
        "invalid turn_kind (allowed: note|broadcast|portal|task|checkpoint)"

let parse_turn_kind_opt args =
  match get_string_opt args "turn_kind" with
  | None -> Ok None
  | Some raw -> (
      match Team_session_types.turn_kind_of_string (String.lowercase_ascii raw) with
      | Some k -> Ok (Some k)
      | None ->
          Error
            "invalid turn_kind (allowed: note|broadcast|portal|task|checkpoint)")

let parse_proof_level args =
  let raw =
    get_string args "proof_level" "standard"
    |> String.trim |> String.lowercase_ascii
  in
  Team_session_types.proof_level_of_string raw

let is_all_digits s =
  let len = String.length s in
  len > 0 && String.for_all (function '0' .. '9' -> true | _ -> false) s

let is_all_hex s =
  let len = String.length s in
  len > 0
  && String.for_all
       (function
         | '0' .. '9'
         | 'a' .. 'f'
         | 'A' .. 'F' ->
             true
         | _ -> false)
       s

let is_valid_session_id session_id =
  match String.split_on_char '-' session_id with
  | [ "ts"; epoch_ms; suffix ] -> is_all_digits epoch_ms && is_all_hex suffix
  | _ -> false

let get_valid_session_id_key args key =
  match get_string_opt args key with
  | None -> Error (key ^ " is required")
  | Some session_id ->
      if is_valid_session_id session_id then
        Ok session_id
      else
        Error ("invalid " ^ key ^ " format")

let get_valid_session_id args = get_valid_session_id_key args "session_id"

let parse_status_filter args =
  match get_string_opt args "status" with
  | None -> Ok None
  | Some status ->
      let normalized = String.lowercase_ascii (String.trim status) in
      match normalized with
      | "running" | "paused" | "completed" | "interrupted" | "failed" ->
          Ok (Some (Team_session_types.status_of_string normalized))
      | _ -> Error "invalid status filter"

let can_access_session ~agent_name (session : Team_session_types.session) =
  String.equal agent_name session.created_by
  || List.exists (String.equal agent_name) session.agent_names

let ensure_session_access ctx session_id =
  match Team_session_store.load_session ctx.config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some session ->
      if can_access_session ~agent_name:ctx.agent_name session then
        Ok ()
      else
        Error "not authorized for this team session"

let record_session_turn_json ~(config : Room.config) ~session_id ~actor
    ~turn_kind ~message ~target_agent ~task_title ~task_description
    ~task_priority =
  Team_session_engine_eio.record_turn ~config ~session_id ~actor ~turn_kind
    ~message ~target_agent ~task_title ~task_description ~task_priority

let handle_start ctx args : result =
  let goal = get_string args "goal" "" in
  if String.trim goal = "" then
    (false, json_error "goal is required")
  else
    let duration_seconds =
      let raw_seconds = get_int args "duration_seconds" 0 in
      if raw_seconds > 0 then
        raw_seconds
      else
        let duration_minutes = get_int args "duration_minutes" 60 in
        max 1 duration_minutes * 60
    in
    let checkpoint_interval_sec = get_int args "checkpoint_interval_sec" 60 in
    let min_agents = get_int args "min_agents" 2 in
    let scale_profile = parse_scale_profile args in
    let control_profile = parse_control_profile ~scale_profile args in
    let auto_resume = get_bool args "auto_resume" true in
    let report_formats = parse_report_formats args in
    let execution_scope = parse_execution_scope args in
    let orchestration_mode = parse_orchestration_mode args in
    let communication_mode = parse_communication_mode args in
    let model_cascade = get_string_list args "model_cascade" in
    let fallback_policy = parse_fallback_policy args in
    let instruction_profile = parse_instruction_profile args in
    let alert_channel = parse_alert_channel args in
    let agents = get_agent_names args "agents" in
    let operation_id = get_string_opt args "operation_id" in
    match
      Team_session_engine_eio.start_session ~sw:ctx.sw ~clock:ctx.clock
        ~config:ctx.config ~created_by:ctx.agent_name ~goal ~duration_seconds
        ~execution_scope ~checkpoint_interval_sec ~min_agents
        ~scale_profile ~control_profile
        ~orchestration_mode ~communication_mode ~model_cascade ~fallback_policy
        ~instruction_profile ~alert_channel ~auto_resume ~report_formats
        ~agent_names:agents ~operation_id
    with
    | Ok json -> (true, json_ok [ ("result", json) ])
    | Error e -> (false, json_error e)

let handle_status ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () -> (
          match Team_session_engine_eio.status_session ~config:ctx.config ~session_id with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_stop ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let reason = get_string args "reason" "manual_stop" in
          let generate_report = get_bool args "generate_report" true in
          (match
             Team_session_engine_eio.stop_session ~config:ctx.config ~session_id
               ~reason ~generate_report
           with
          | Ok json ->
              let linked_result =
                match
                  Autoresearch.load_swarm_link_by_session
                    ~base_path:ctx.config.base_path session_id
                with
                | None -> None
                | Some link ->
                    Autoresearch.stop_loop ~base_path:ctx.config.base_path
                      ~reason:(Printf.sprintf "team_session_stop:%s" reason)
                      link.loop_id
                    |> Option.map (fun (state : Autoresearch.loop_state) ->
                           `Assoc
                             [
                               ("loop_id", `String state.loop_id);
                               ( "status",
                                 `String
                                   (Autoresearch.status_to_string state.status) );
                               ("current_cycle", `Int state.current_cycle);
                               ("best_score", `Float state.best_score);
                             ])
              in
              let json =
                match json with
                | `Assoc fields -> (
                    match linked_result with
                    | Some linked ->
                        `Assoc
                          (List.remove_assoc "linked_autoresearch" fields
                          @ [ ("linked_autoresearch", linked) ])
                    | None -> json)
                | _ -> json
              in
              (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_report ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let force_regenerate = get_bool args "force_regenerate" false in
          (match
             Team_session_engine_eio.generate_report ~config:ctx.config ~session_id
               ~force_regenerate
           with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_list ctx args : result =
  let limit = get_int args "limit" 20 in
  match parse_status_filter args with
  | Error e -> (false, json_error e)
  | Ok status_filter -> (
      match
        Team_session_engine_eio.list_sessions ~config:ctx.config
          ~requester_agent:(Some ctx.agent_name) ~status_filter ~limit
      with
      | Ok json -> (true, json_ok [ ("result", json) ])
      | Error e -> (false, json_error e))

let handle_compare ctx args : result =
  match
    ( get_valid_session_id_key args "base_session_id",
      get_valid_session_id_key args "target_session_id" )
  with
  | Ok base_session_id, Ok target_session_id -> (
      match
        Team_session_engine_eio.compare_sessions ~config:ctx.config
          ~requester_agent:(Some ctx.agent_name) ~base_session_id
          ~target_session_id
      with
      | Ok json -> (true, json_ok [ ("result", json) ])
      | Error e -> (false, json_error e))
  | Error e, _ -> (false, json_error e)
  | _, Error e -> (false, json_error e)

let handle_turn ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () -> (
          match parse_turn_kind args with
          | Error e -> (false, json_error e)
          | Ok turn_kind ->
              let message = get_string_opt args "message" in
              let target_agent = get_string_opt args "target_agent" in
              let task_title = get_string_opt args "task_title" in
              let task_description = get_string_opt args "task_description" in
              let task_priority = get_int args "task_priority" 3 in
              (match
                 record_session_turn_json ~config:ctx.config ~session_id
                   ~actor:ctx.agent_name ~turn_kind ~message ~target_agent
                   ~task_title ~task_description ~task_priority
               with
              | Ok json -> (true, json_ok [ ("result", json) ])
              | Error e -> (false, json_error e))))

let int_opt_to_json = function Some n -> `Int n | None -> `Null
let float_opt_to_json = function Some v -> `Float v | None -> `Null

let truncate_for_event ?(max_len = 320) (s : string) =
  if String.length s <= max_len then
    s
  else
    String.sub s 0 max_len ^ "..."

let derived_llama_runtime_actor ~session_id ~prompt =
  let digest = Digest.string (session_id ^ "\n" ^ prompt) |> Digest.to_hex in
  Printf.sprintf "llama-local-%s" (String.sub digest 0 8)

type routing_decision = {
  model_tier : Team_session_types.model_tier;
  task_profile : Team_session_types.task_profile;
  risk_level : Team_session_types.risk_level;
  confidence : float option;
  reason : string;
  judge_used : bool;
  escalate_if : string list;
  escalated : bool;
}

type spawn_spec = {
  spawn_agent : string;
  spawn_prompt : string;
  spawn_model : string option;
  spawn_model_explicit : bool;
  spawn_role : string option;
  worker_class : Team_session_types.worker_class option;
  parent_actor : string option;
  capsule_mode : Team_session_types.capsule_mode option;
  runtime_pool : string option;
  lane_id : string option;
  control_domain : Team_session_types.control_domain option;
  supervisor_actor : string option;
  model_tier : Team_session_types.model_tier option;
  model_tier_explicit : bool;
  task_profile : Team_session_types.task_profile option;
  risk_level : Team_session_types.risk_level option;
  routing_confidence : float option;
  routing_reason : string option;
  spawn_selection_note : string option;
  spawn_timeout_seconds : int;
}

type prepared_spawn = {
  spec : spawn_spec;
  runtime_actor_name : string option;
  runtime_model : Llm_client.model_spec;
  runtime_lease : Local_runtime_pool.lease option;
  assigned_runtime : string option;
}

let trim_opt = function
  | None -> None
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed

let env_trim_opt name = Sys.getenv_opt name |> trim_opt

let bool_env_default name ~default =
  match env_trim_opt name with
  | Some ("1" | "true" | "yes" | "on") -> true
  | Some ("0" | "false" | "no" | "off") -> false
  | _ -> default

let float_env_default name ~default =
  match env_trim_opt name with
  | Some raw -> (
      try float_of_string raw with Failure _ -> default)
  | None -> default

let int_env_default name ~default =
  match env_trim_opt name with
  | Some raw -> (
      try int_of_string raw with Failure _ -> default)
  | None -> default

let contains_ci haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then
      true
    else if idx + needle_len > haystack_len then
      false
    else if String.sub haystack idx needle_len = needle then
      true
    else loop (idx + 1)
  in
  loop 0

let contains_any_ci haystack needles =
  List.exists (fun needle -> contains_ci haystack needle) needles

let runtime_inventory_models () =
  Local_runtime_pool.snapshots ()
  |> List.filter_map (fun (runtime : Local_runtime_pool.runtime_snapshot) ->
         trim_opt runtime.model)
  |> Team_session_types.dedup_strings

let explicit_lead_model () = env_trim_opt "MASC_TEAM_SESSION_MODEL_35B"
let explicit_middle_model () = env_trim_opt "MASC_TEAM_SESSION_MODEL_27B"
let explicit_worker_model () = env_trim_opt "MASC_TEAM_SESSION_MODEL_9B"

let inferred_lead_model () =
  match explicit_lead_model () with
  | Some _ as explicit -> explicit
  | None -> (
      match env_trim_opt "LLAMA_SWARM_MODEL" with
      | Some _ as env_model -> env_model
      | None ->
          runtime_inventory_models ()
          |> List.find_opt (fun model -> contains_ci model "35b"))

let inferred_middle_model () =
  match explicit_middle_model () with
  | Some _ as explicit -> explicit
  | None ->
      runtime_inventory_models ()
      |> List.find_opt (fun model -> contains_ci model "27b")

let inferred_worker_model () =
  match explicit_worker_model () with
  | Some _ as explicit -> explicit
  | None ->
      runtime_inventory_models ()
      |> List.find_opt (fun model -> contains_ci model "9b")

let infer_model_tier_from_model_name model_name =
  match trim_opt model_name with
  | None -> None
  | Some model_name -> (
      match
        (inferred_worker_model (), inferred_middle_model (), inferred_lead_model ())
      with
      | Some worker_model, _, _ when String.equal worker_model model_name ->
          Some Team_session_types.Tier_9b
      | _, Some middle_model, _ when String.equal middle_model model_name ->
          Some Team_session_types.Tier_27b
      | _, _, Some lead_model when String.equal lead_model model_name ->
          Some Team_session_types.Tier_35b
      | _ when contains_ci model_name "35b" -> Some Team_session_types.Tier_35b
      | _ when contains_ci model_name "27b" -> Some Team_session_types.Tier_27b
      | _ when contains_ci model_name "9b" -> Some Team_session_types.Tier_9b
      | _ -> None)

let default_risk_for_profile = function
  | Team_session_types.Profile_extract
  | Team_session_types.Profile_normalize
  | Team_session_types.Profile_summarize ->
      Team_session_types.Risk_low
  | Team_session_types.Profile_verify
  | Team_session_types.Profile_decide ->
      Team_session_types.Risk_high
  | Team_session_types.Profile_synthesize ->
      Team_session_types.Risk_medium

let min_risk left right =
  match (left, right) with
  | Team_session_types.Risk_high, _
  | _, Team_session_types.Risk_high ->
      Team_session_types.Risk_high
  | Team_session_types.Risk_medium, _
  | _, Team_session_types.Risk_medium ->
      Team_session_types.Risk_medium
  | _ -> Team_session_types.Risk_low

let default_tier_for_profile ~risk_level = function
  | (Team_session_types.Profile_extract
    | Team_session_types.Profile_normalize
    | Team_session_types.Profile_summarize)
    when risk_level <> Team_session_types.Risk_high ->
      Team_session_types.Tier_9b
  | (Team_session_types.Profile_verify | Team_session_types.Profile_synthesize)
    when risk_level <> Team_session_types.Risk_high ->
      Team_session_types.Tier_27b
  | _ -> Team_session_types.Tier_35b

let normalized_spawn_text ~spawn_prompt ~spawn_role =
  String.concat "\n"
    ([ spawn_prompt ]
    @
    match spawn_role with
    | Some role -> [ role ]
    | None -> [])
  |> String.lowercase_ascii

let keyword_matches text =
  let groups =
    [
      ( Team_session_types.Profile_extract,
        [ "fetch"; "collect"; "gather"; "search"; "find source"; "read docs"; "web"; "official docs"; "article"; "paper"; "source" ] );
      ( Team_session_types.Profile_normalize,
        [ "normalize"; "convert"; "transform"; "schema"; "format"; "json"; "label"; "tag"; "dedup" ] );
      ( Team_session_types.Profile_summarize,
        [ "summarize"; "summary"; "digest"; "brief"; "recap"; "short answer"; "bullet" ] );
      ( Team_session_types.Profile_verify,
        [ "verify"; "validate"; "check"; "review"; "audit"; "judge"; "prove"; "test"; "compare" ] );
      ( Team_session_types.Profile_decide,
        [ "decide"; "choose"; "route"; "triage"; "prioritize"; "assign"; "classify" ] );
      ( Team_session_types.Profile_synthesize,
        [ "synthesize"; "write"; "draft"; "compose"; "architecture"; "design"; "plan"; "proposal"; "explain" ] );
    ]
  in
  List.filter_map
    (fun (profile, keywords) ->
      if contains_any_ci text keywords then Some profile else None)
    groups

let high_risk_keywords =
  [ "security"; "policy"; "final"; "merge"; "customer"; "public"; "external"; "production"; "critical"; "architecture"; "decision" ]

let router_judge_enabled () =
  bool_env_default "MASC_TEAM_SESSION_ROUTER_JUDGE" ~default:true

let router_judge_timeout_sec () =
  max 5 (int_env_default "MASC_TEAM_SESSION_ROUTER_JUDGE_TIMEOUT_SEC" ~default:15)

let router_judge_confidence_threshold () =
  let value =
    float_env_default "MASC_TEAM_SESSION_ROUTER_CONFIDENCE_THRESHOLD"
      ~default:0.72
  in
  if value < 0.0 then 0.0 else if value > 1.0 then 1.0 else value

let router_judge_model () =
  match env_trim_opt "MASC_TEAM_SESSION_ROUTER_JUDGE_MODEL" with
  | Some _ as explicit -> explicit
  | None -> inferred_lead_model ()

let llama_router_model_spec model_id =
  {
    Llm_client.provider = Llm_client.Llama;
    model_id;
    max_context = 262_144;
    api_url = Env_config.Llama.server_url;
    api_key_env = None;
    cost_per_1k_input = 0.0;
    cost_per_1k_output = 0.0;
  }

let classify_risk ~task_profile ~spawn_prompt ~spawn_role =
  let text = normalized_spawn_text ~spawn_prompt ~spawn_role in
  let base = default_risk_for_profile task_profile in
  if contains_any_ci text high_risk_keywords then
    min_risk base Team_session_types.Risk_high
  else base

let heuristic_routing ~spawn_prompt ~spawn_role ~worker_class ~task_profile
    ~risk_level ~model_tier ~routing_confidence ~routing_reason =
  let resolved_profile =
    match task_profile with
    | Some profile -> Some (profile, "explicit_task_profile", 0.99)
    | None -> (
        match worker_class with
        | Some Team_session_types.Worker_manager ->
            Some (Team_session_types.Profile_decide, "rule:worker_class=manager", 0.97)
        | Some Team_session_types.Worker_metacog ->
            Some (Team_session_types.Profile_verify, "rule:worker_class=metacog", 0.97)
        | Some Team_session_types.Worker_scout ->
            Some (Team_session_types.Profile_extract, "rule:worker_class=scout", 0.95)
        | Some Team_session_types.Worker_librarian ->
            Some (Team_session_types.Profile_summarize, "rule:worker_class=librarian", 0.94)
        | _ ->
            let matches =
              keyword_matches
                (normalized_spawn_text ~spawn_prompt ~spawn_role)
            in
            match matches with
            | [ profile ] -> Some (profile, "rule:keyword_match", 0.78)
            | _ -> None)
  in
  match resolved_profile with
  | Some (profile, reason, confidence) ->
      let resolved_risk =
        match risk_level with
        | Some explicit -> explicit
        | None -> classify_risk ~task_profile:profile ~spawn_prompt ~spawn_role
      in
      let resolved_tier =
        match model_tier with
        | Some explicit -> explicit
        | None -> default_tier_for_profile ~risk_level:resolved_risk profile
      in
      let confidence =
        match routing_confidence with
        | Some value -> Some value
        | None -> Some confidence
      in
      let reason =
        match routing_reason with
        | Some explicit -> explicit
        | None -> reason
      in
      Some
        {
          model_tier = resolved_tier;
          task_profile = profile;
          risk_level = resolved_risk;
          confidence;
          reason;
          judge_used = false;
          escalate_if =
            [ "worker failure"; "schema mismatch"; "context pressure"; "evidence conflict" ];
          escalated = false;
        }
  | None -> None

let parse_routing_decision_json (json : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  let model_tier =
    match member "model_tier" json |> to_string_option with
    | Some raw ->
        Team_session_types.model_tier_of_string
          (String.lowercase_ascii (String.trim raw))
    | None -> None
  in
  let task_profile =
    match member "task_profile" json |> to_string_option with
    | Some raw ->
        Team_session_types.task_profile_of_string
          (String.lowercase_ascii (String.trim raw))
    | None -> None
  in
  let risk_level =
    match member "risk_level" json |> to_string_option with
    | Some raw ->
        Team_session_types.risk_level_of_string
          (String.lowercase_ascii (String.trim raw))
    | None -> None
  in
  match (model_tier, task_profile, risk_level) with
  | Some model_tier, Some task_profile, Some risk_level ->
      let confidence =
        match member "confidence" json with
        | `Float value -> Some value
        | `Int value -> Some (float_of_int value)
        | `Intlit raw -> (try Some (float_of_string raw) with Failure _ -> None)
        | _ -> None
      in
      let reason =
        member "reason" json |> to_string_option
        |> Option.value ~default:"llm_judge"
      in
      let escalate_if =
        match member "escalate_if" json with
        | `List xs ->
            xs
            |> List.filter_map (function
                   | `String value ->
                       let trimmed = String.trim value in
                       if trimmed = "" then None else Some trimmed
                   | _ -> None)
        | _ -> []
      in
      Some
        {
          model_tier;
          task_profile;
          risk_level;
          confidence;
          reason;
          judge_used = true;
          escalate_if;
          escalated = false;
        }
  | _ -> None

let llm_judge_routing ~spawn_prompt ~spawn_role ~worker_class =
  match router_judge_model () with
  | None -> None
  | Some judge_model ->
      let worker_class_text =
        match worker_class with
        | Some kind -> Team_session_types.worker_class_to_string kind
        | None -> "unspecified"
      in
      let role_text = Option.value ~default:"unspecified" spawn_role in
      let prompt =
        Printf.sprintf
          "Classify the worker task for a quality-first 2-tier swarm router.\n\
           Return strict JSON only with keys: model_tier, task_profile, risk_level, confidence, reason, escalate_if.\n\
           model_tier must be one of [\"35b\",\"27b\",\"9b\"].\n\
           task_profile must be one of [\"extract\",\"normalize\",\"summarize\",\"verify\",\"decide\",\"synthesize\"].\n\
           risk_level must be one of [\"low\",\"medium\",\"high\"].\n\
           Use 35b for root judgment, final arbitration, or high-risk outputs.\n\
           Use 27b for lane managers, quality review, knowledge review, and medium-risk synthesis.\n\
           Use 9b only for low-risk, machine-checkable, or strict-template subtasks.\n\
           worker_class=%s\n\
           spawn_role=%s\n\
           worker_prompt=%S\n"
          worker_class_text role_text spawn_prompt
      in
      let request : Llm_client.completion_request =
        {
          model = llama_router_model_spec judge_model;
          messages =
            [
              {
                Llm_client.role = Llm_client.System;
                content =
                  "You are a routing judge for a hybrid swarm. Output only JSON.";
                name = None;
                tool_call_id = None;
              };
              {
                Llm_client.role = Llm_client.User;
                content = prompt;
                name = None;
                tool_call_id = None;
              };
            ];
          temperature = 0.0;
          max_tokens = 220;
          tools = [];
          response_format = `Json;
        }
      in
      match
        Llm_client.complete ~timeout_sec:(router_judge_timeout_sec ()) request
      with
      | Ok response -> (
          try
            Yojson.Safe.from_string response.content
            |> parse_routing_decision_json
          with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None)
      | Error _ -> None

let routing_summary_line (decision : routing_decision) =
  Printf.sprintf
    "[routing] profile=%s tier=%s risk=%s confidence=%s reason=%s judge=%b escalated=%b"
    (Team_session_types.task_profile_to_string decision.task_profile)
    (Team_session_types.model_tier_to_string decision.model_tier)
    (Team_session_types.risk_level_to_string decision.risk_level)
    (match decision.confidence with
    | Some value -> Printf.sprintf "%.2f" value
    | None -> "n/a")
    decision.reason decision.judge_used decision.escalated

let merge_selection_note selection_note routing_note =
  match (trim_opt selection_note, trim_opt (Some routing_note)) with
  | None, None -> None
  | Some note, None | None, Some note -> Some note
  | Some note, Some routing when String.equal note routing -> Some note
  | Some note, Some routing -> Some (note ^ " | " ^ routing)

let finalize_routing_decision ~spawn_model ~(decision : routing_decision) =
  let resolved_model, escalated, reason =
    match decision.model_tier with
    | Team_session_types.Tier_35b -> (inferred_lead_model (), decision.escalated, decision.reason)
    | Team_session_types.Tier_27b -> (
        match inferred_middle_model () with
        | Some model -> (Some model, decision.escalated, decision.reason)
        | None ->
            ( inferred_lead_model (),
              true,
              decision.reason ^ "; fallback:27b_unavailable->35b" ))
    | Team_session_types.Tier_9b -> (
        match inferred_worker_model () with
        | Some model -> (Some model, decision.escalated, decision.reason)
        | None ->
            ( inferred_lead_model (),
              true,
              decision.reason ^ "; fallback:9b_unavailable->35b" ))
  in
  let resolved_model =
    match trim_opt spawn_model with
    | Some explicit -> Some explicit
    | None -> resolved_model
  in
  let resolved_tier =
    match trim_opt spawn_model with
    | Some explicit ->
        Option.value ~default:decision.model_tier
          (infer_model_tier_from_model_name (Some explicit))
    | None ->
        if escalated then Team_session_types.Tier_35b else decision.model_tier
  in
  (resolved_model, resolved_tier, escalated, reason)

let resolve_routing_for_spec (spec : spawn_spec) =
  if not (String.equal spec.spawn_agent "llama") then
    spec
  else
    let explicit_tier =
      match spec.model_tier with
      | Some tier -> Some tier
      | None -> infer_model_tier_from_model_name spec.spawn_model
    in
    let heuristic =
      heuristic_routing ~spawn_prompt:spec.spawn_prompt ~spawn_role:spec.spawn_role
        ~worker_class:spec.worker_class ~task_profile:spec.task_profile
        ~risk_level:spec.risk_level ~model_tier:explicit_tier
        ~routing_confidence:spec.routing_confidence
        ~routing_reason:spec.routing_reason
    in
    let decision =
      match heuristic with
      | Some decision ->
          let confidence =
            Option.value ~default:1.0 decision.confidence
          in
          if confidence >= router_judge_confidence_threshold ()
             || Option.is_some spec.task_profile
             || Option.is_some spec.model_tier
          then
            decision
          else
            (match llm_judge_routing ~spawn_prompt:spec.spawn_prompt
                     ~spawn_role:spec.spawn_role ~worker_class:spec.worker_class with
            | Some llm -> llm
            | None ->
                {
                  decision with
                  model_tier = Team_session_types.Tier_35b;
                  risk_level = Team_session_types.Risk_high;
                  reason = decision.reason ^ "; fallback:uncertain->35b";
                  escalated = true;
                })
      | None -> (
          match llm_judge_routing ~spawn_prompt:spec.spawn_prompt
                   ~spawn_role:spec.spawn_role ~worker_class:spec.worker_class with
          | Some llm -> llm
          | None ->
              {
                model_tier = Option.value ~default:Team_session_types.Tier_35b explicit_tier;
                task_profile =
                  Option.value ~default:Team_session_types.Profile_synthesize
                    spec.task_profile;
                risk_level =
                  Option.value ~default:Team_session_types.Risk_high spec.risk_level;
                confidence = Some 0.0;
                reason = Option.value ~default:"fallback:ambiguous->35b" spec.routing_reason;
                judge_used = false;
                escalate_if =
                  [ "worker failure"; "schema mismatch"; "context pressure"; "evidence conflict" ];
                escalated = true;
              })
    in
    let spawn_model, model_tier, routing_escalated, routing_reason =
      finalize_routing_decision ~spawn_model:spec.spawn_model ~decision
    in
    let routing_confidence =
      match spec.routing_confidence with
      | Some _ as explicit -> explicit
      | None -> decision.confidence
    in
    let routing_note =
      routing_summary_line { decision with model_tier; reason = routing_reason; escalated = routing_escalated }
    in
    {
      spec with
      spawn_model;
      model_tier = Some model_tier;
      task_profile = Some decision.task_profile;
      risk_level = Some decision.risk_level;
      routing_confidence;
      routing_reason = Some routing_reason;
      spawn_selection_note =
        merge_selection_note spec.spawn_selection_note routing_note;
    }

let hierarchy_lane_ids = [| "lane-a"; "lane-b"; "lane-c"; "lane-d" |]

let hierarchy_lane_id_of_index index =
  hierarchy_lane_ids.(index mod Array.length hierarchy_lane_ids)

let inferred_control_domain_of_spec (spec : spawn_spec) =
  match spec.control_domain with
  | Some domain -> Some domain
  | None -> (
      match (spec.worker_class, spec.task_profile) with
      | Some Team_session_types.Worker_metacog, _ ->
          Some Team_session_types.Domain_meta
      | Some Team_session_types.Worker_scout, _
      | Some Team_session_types.Worker_librarian, _ ->
          Some Team_session_types.Domain_knowledge
      | _, Some Team_session_types.Profile_verify ->
          Some Team_session_types.Domain_quality
      | _, Some Team_session_types.Profile_extract
      | _, Some Team_session_types.Profile_summarize ->
          Some Team_session_types.Domain_knowledge
      | _ -> Some Team_session_types.Domain_execution)

let inferred_controller_level_of_spec (spec : spawn_spec) =
  match spec.worker_class with
  | Some Team_session_types.Worker_manager -> Some Team_session_types.Controller_lane
  | Some Team_session_types.Worker_metacog
  | Some Team_session_types.Worker_scout
  | Some Team_session_types.Worker_librarian ->
      Some Team_session_types.Controller_submanager
  | _ -> Some Team_session_types.Controller_worker

let inferred_lane_id_of_spec ~index (spec : spawn_spec) =
  match spec.lane_id with
  | Some lane -> Some lane
  | None -> (
      match spec.worker_class with
      | Some Team_session_types.Worker_metacog -> Some "global"
      | _ -> Some (hierarchy_lane_id_of_index index))

let inferred_supervisor_actor_of_spec ~lane_id ~control_domain (spec : spawn_spec)
    =
  match spec.supervisor_actor with
  | Some actor -> Some actor
  | None -> (
      match spec.worker_class with
      | Some Team_session_types.Worker_manager -> Some "ctrl-root"
      | _ -> (
          match (lane_id, control_domain) with
          | _, Some Team_session_types.Domain_meta -> Some "ctrl-global-metacog"
          | _, Some Team_session_types.Domain_runtime -> Some "ctrl-runtime-warden"
          | Some "global", _ -> Some "ctrl-root"
          | Some lane, Some Team_session_types.Domain_quality ->
              Some (Printf.sprintf "ctrl-%s-quality" lane)
          | Some lane, Some Team_session_types.Domain_knowledge ->
              Some (Printf.sprintf "ctrl-%s-knowledge" lane)
          | Some lane, _ -> Some (Printf.sprintf "ctrl-%s" lane)
          | None, _ -> Some "ctrl-root"))

let controller_target_tier_of_spec ~control_domain (spec : spawn_spec) =
  match control_domain with
  | Some Team_session_types.Domain_meta -> Team_session_types.Tier_35b
  | Some Team_session_types.Domain_quality
  | Some Team_session_types.Domain_knowledge -> Team_session_types.Tier_27b
  | _ -> (
      match spec.worker_class with
      | Some Team_session_types.Worker_manager -> Team_session_types.Tier_27b
      | _ ->
          Option.value
            ~default:(Option.value ~default:Team_session_types.Tier_9b spec.model_tier)
            spec.model_tier)

let annotate_control_hierarchy_for_session
    (session : Team_session_types.session) (specs : spawn_spec list) =
  if
    session.control_profile <> Team_session_types.Control_hierarchical_quality_v1
  then
    specs
  else
    List.mapi
      (fun index spec ->
        let lane_id = inferred_lane_id_of_spec ~index spec in
        let control_domain = inferred_control_domain_of_spec spec in
        let supervisor_actor =
          inferred_supervisor_actor_of_spec ~lane_id ~control_domain spec
        in
        let model_tier =
          match (spec.model_tier_explicit, spec.model_tier) with
          | true, (Some _ as explicit) -> explicit
          | _ -> Some (controller_target_tier_of_spec ~control_domain spec)
        in
        let spawn_model =
          match (spec.spawn_model_explicit, trim_opt spec.spawn_model) with
          | true, (Some _ as explicit) -> explicit
          | _ -> (
              match model_tier with
              | Some Team_session_types.Tier_35b -> inferred_lead_model ()
              | Some Team_session_types.Tier_27b -> inferred_middle_model ()
              | Some Team_session_types.Tier_9b -> inferred_worker_model ()
              | None -> spec.spawn_model)
        in
        {
          spec with
          spawn_model;
          lane_id;
          control_domain;
          supervisor_actor;
          model_tier;
        })
      specs

let parse_spawn_spec_from_object ?(default_timeout = 300) batch_index json =
  let open Yojson.Safe.Util in
  let get_required_string key =
    match member key json with
    | `String s ->
        let trimmed = String.trim s in
        if trimmed = "" then
          Error
            (Printf.sprintf "spawn_batch[%d].%s is required" batch_index key)
        else
          Ok trimmed
    | _ ->
        Error
          (Printf.sprintf "spawn_batch[%d].%s is required" batch_index key)
  in
  let get_optional_string key =
    match member key json with
    | `String s ->
        let trimmed = String.trim s in
        if trimmed = "" then None else Some trimmed
    | _ -> None
  in
  let get_optional_worker_class key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.worker_class_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_model_tier key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.model_tier_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_task_profile key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.task_profile_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_risk_level key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.risk_level_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_capsule_mode key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.capsule_mode_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_control_domain key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.control_domain_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_float key =
    match member key json with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | `Intlit raw -> (try Some (float_of_string raw) with Failure _ -> None)
    | _ -> None
  in
  let get_timeout key =
    match member key json with
    | `Int n -> max 1 n
    | `Intlit s -> (try max 1 (int_of_string s) with Failure _ -> default_timeout)
    | _ -> default_timeout
  in
  match (get_required_string "spawn_agent", get_required_string "spawn_prompt") with
  | Ok spawn_agent, Ok spawn_prompt ->
      Ok
        {
          spawn_agent;
          spawn_prompt;
          spawn_model = get_optional_string "spawn_model";
          spawn_model_explicit = Option.is_some (get_optional_string "spawn_model");
          spawn_role = get_optional_string "spawn_role";
          worker_class = get_optional_worker_class "worker_class";
          parent_actor = get_optional_string "parent_actor";
          capsule_mode = get_optional_capsule_mode "capsule_mode";
          runtime_pool = get_optional_string "runtime_pool";
          lane_id = get_optional_string "lane_id";
          control_domain = get_optional_control_domain "control_domain";
          supervisor_actor = get_optional_string "supervisor_actor";
          model_tier = get_optional_model_tier "model_tier";
          model_tier_explicit = Option.is_some (get_optional_string "model_tier");
          task_profile = get_optional_task_profile "task_profile";
          risk_level = get_optional_risk_level "risk_level";
          routing_confidence = get_optional_float "routing_confidence";
          routing_reason = get_optional_string "routing_reason";
          spawn_selection_note = get_optional_string "spawn_selection_note";
          spawn_timeout_seconds = get_timeout "spawn_timeout_seconds";
        }
  | Error e, _ | _, Error e -> Error e

let parse_step_spawn_specs args =
  let singular_agent = get_string_opt args "spawn_agent" in
  let singular_prompt = get_string_opt args "spawn_prompt" in
  let singular_present = Option.is_some singular_agent || Option.is_some singular_prompt in
  let default_batch_timeout =
    match Yojson.Safe.Util.member "spawn_timeout_seconds" args with
    | `Int value -> max 1 value
    | `Intlit raw -> (try max 1 (int_of_string raw) with Failure _ -> 300)
    | _ -> max 1 (get_int args "spawn_timeout_seconds" 300)
  in
  let batch_specs_result =
    match Yojson.Safe.Util.member "spawn_batch" args with
    | `Null -> Ok []
    | `List xs ->
        let rec loop idx acc = function
          | [] -> Ok (List.rev acc)
          | json :: rest -> (
              match
                parse_spawn_spec_from_object ~default_timeout:default_batch_timeout
                  idx json
              with
              | Ok spec -> loop (idx + 1) (spec :: acc) rest
              | Error e -> Error e)
        in
        loop 0 [] xs
    | _ -> Error "spawn_batch must be an array"
  in
  match batch_specs_result with
  | Error e -> Error e
  | Ok batch_specs ->
      let route_specs specs = Ok (List.map resolve_routing_for_spec specs) in
      if singular_present && batch_specs <> [] then
        Error "spawn_batch cannot be combined with spawn_agent/spawn_prompt"
      else if batch_specs <> [] then
        route_specs batch_specs
      else
        match (singular_agent, singular_prompt) with
        | None, None -> Ok []
        | Some _, None | None, Some _ ->
            Error "spawn_agent and spawn_prompt must be provided together"
        | Some spawn_agent, Some spawn_prompt ->
            route_specs
              [
                {
                  spawn_agent;
                  spawn_prompt;
                  spawn_model = get_string_opt args "spawn_model";
                  spawn_model_explicit = Option.is_some (get_string_opt args "spawn_model");
                  spawn_role = get_string_opt args "spawn_role";
                  worker_class =
                    Option.bind
                      (get_string_opt args "worker_class")
                      (fun raw ->
                        Team_session_types.worker_class_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  parent_actor = get_string_opt args "parent_actor";
                  capsule_mode =
                    Option.bind
                      (get_string_opt args "capsule_mode")
                      (fun raw ->
                        Team_session_types.capsule_mode_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  runtime_pool = get_string_opt args "runtime_pool";
                  lane_id = get_string_opt args "lane_id";
                  control_domain =
                    Option.bind
                      (get_string_opt args "control_domain")
                      (fun raw ->
                        Team_session_types.control_domain_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  supervisor_actor = get_string_opt args "supervisor_actor";
                  model_tier =
                    Option.bind
                      (get_string_opt args "model_tier")
                      (fun raw ->
                        Team_session_types.model_tier_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  model_tier_explicit = Option.is_some (get_string_opt args "model_tier");
                  task_profile =
                    Option.bind
                      (get_string_opt args "task_profile")
                      (fun raw ->
                        Team_session_types.task_profile_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  risk_level =
                    Option.bind
                      (get_string_opt args "risk_level")
                      (fun raw ->
                        Team_session_types.risk_level_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  routing_confidence = get_float_opt args "routing_confidence";
                  routing_reason = get_string_opt args "routing_reason";
                  spawn_selection_note = get_string_opt args "spawn_selection_note";
                  spawn_timeout_seconds = get_int args "spawn_timeout_seconds" 300;
                };
              ]

let planned_worker_of_spec ?runtime_actor (spec : spawn_spec) :
    Team_session_types.planned_worker =
  {
    spawn_agent = spec.spawn_agent;
    runtime_actor;
    spawn_role = spec.spawn_role;
    spawn_model = spec.spawn_model;
    worker_class = spec.worker_class;
    parent_actor = spec.parent_actor;
    capsule_mode = spec.capsule_mode;
    runtime_pool = spec.runtime_pool;
    lane_id = spec.lane_id;
    controller_level = inferred_controller_level_of_spec spec;
    control_domain = spec.control_domain;
    supervisor_actor = spec.supervisor_actor;
    model_tier = spec.model_tier;
    task_profile = spec.task_profile;
    risk_level = spec.risk_level;
    routing_confidence = spec.routing_confidence;
    routing_reason = spec.routing_reason;
    routing_escalated =
      (match spec.routing_reason with
      | Some reason ->
          contains_ci reason "fallback:"
          || contains_ci reason "escalate"
          || contains_ci reason "uncertain->35b"
      | None -> false);
  }

let register_planned_workers config session_id workers =
  match Team_session_store.update_session config session_id (fun session ->
            {
              session with
              planned_workers =
                Team_session_types.dedup_planned_workers
                  (session.planned_workers @ workers);
              updated_at_iso = Types.now_iso ();
            })
  with
  | Ok updated ->
      Team_session_store.append_event config session_id
        ~event_type:"session_planned_workers_updated"
        ~detail:
          (`Assoc
            [
              ("planned_worker_count", `Int (List.length updated.planned_workers));
              ( "worker_class_counts",
                Team_session_types.worker_class_counts updated.planned_workers
                |> Team_session_types.counts_to_json );
              ( "runtime_pool_counts",
                Team_session_types.runtime_pool_counts updated.planned_workers
                |> Team_session_types.counts_to_json );
              ( "lane_counts",
                Team_session_types.lane_counts updated.planned_workers
                |> Team_session_types.counts_to_json );
              ( "controller_counts",
                Team_session_types.controller_level_counts updated.planned_workers
                |> Team_session_types.counts_to_json );
              ( "control_domain_counts",
                Team_session_types.control_domain_counts updated.planned_workers
                |> Team_session_types.counts_to_json );
              ( "tier_counts",
                Team_session_types.model_tier_counts updated.planned_workers
                |> Team_session_types.counts_to_json );
              ( "task_profile_counts",
                Team_session_types.task_profile_counts updated.planned_workers
                |> Team_session_types.counts_to_json );
              ( "escalation_count",
                `Int
                  (Team_session_types.escalation_count updated.planned_workers)
              );
              ( "runtime_actors",
                `List
                  (workers
                  |> List.filter_map (fun worker ->
                         worker.Team_session_types.runtime_actor)
                  |> List.map (fun actor -> `String actor)) );
              ("ts_iso", `String (Types.now_iso ()));
            ]);
      Ok ()
  | Error e -> Error e

let ensure_session_actor config session_id actor_name =
  match Team_session_store.update_session config session_id (fun session ->
            let agent_names =
              Team_session_types.dedup_strings (session.agent_names @ [ actor_name ])
            in
            { session with agent_names; updated_at_iso = Types.now_iso () })
  with
  | Ok updated ->
      Team_session_store.append_event config session_id
        ~event_type:"session_agent_attached"
        ~detail:
          (`Assoc
            [
              ("actor", `String actor_name);
              ("agent_count", `Int (List.length updated.agent_names));
              ("ts_iso", `String (Types.now_iso ()));
            ]);
      Ok ()
  | Error e -> Error e

let detach_session_actor config session_id actor_name ~reason =
  match Team_session_store.update_session config session_id (fun session ->
            let agent_names =
              List.filter
                (fun existing -> not (String.equal existing actor_name))
                session.agent_names
            in
            { session with agent_names; updated_at_iso = Types.now_iso () })
  with
  | Ok updated ->
      Team_session_store.append_event config session_id
        ~event_type:"session_agent_detached"
        ~detail:
          (`Assoc
            [
              ("actor", `String actor_name);
              ("reason", `String reason);
              ("agent_count", `Int (List.length updated.agent_names));
              ("ts_iso", `String (Types.now_iso ()));
            ]);
      Ok ()
  | Error e -> Error e

let session_has_turn_for_actor config session_id actor_name =
  Team_session_store.read_events config session_id
  |> List.exists (fun json ->
         match
           ( Yojson.Safe.Util.member "event_type" json,
             Yojson.Safe.Util.member "detail" json
             |> Yojson.Safe.Util.member "actor" )
         with
         | `String "team_turn", `String recorded_actor ->
             String.equal (String.trim recorded_actor) actor_name
         | _ -> false)

let auto_note_message_of_spawn_output output =
  let trimmed = String.trim output in
  if trimmed = "" then
    None
  else
    Some ("[auto-note] " ^ truncate_for_event ~max_len:480 trimmed)

let reconcile_failed_spawn_actor config session_id actor_name =
  if session_has_turn_for_actor config session_id actor_name then
    Ok `Retained
  else
    detach_session_actor config session_id actor_name
      ~reason:"spawn_failed_without_turn"
    |> Result.map (fun () -> `Detached)

let extract_vote_id (text : string) =
  let re = Str.regexp "vote-[0-9-]+-[0-9]+" in
  try
    let _ = Str.search_forward re text 0 in
    Some (Str.matched_string text)
  with Not_found -> None

let status_of_engine_status_json (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member "session" json |> Yojson.Safe.Util.member "status" with
  | `String s -> s
  | _ -> "unknown"

let handle_step ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let spawn_specs_result = parse_step_spawn_specs args in
          match spawn_specs_result with
          | Error e -> (false, json_error e)
          | Ok raw_spawn_specs ->
              let spawn_specs =
                match Team_session_store.load_session ctx.config session_id with
                | Some session ->
                    annotate_control_hierarchy_for_session session raw_spawn_specs
                | None -> raw_spawn_specs
              in
              let turn_kind_result =
                if spawn_specs <> [] then parse_turn_kind_opt args
                else
                  match parse_turn_kind args with
                  | Ok kind -> Ok (Some kind)
                  | Error e -> Error e
              in
              match turn_kind_result with
              | Error e -> (false, json_error e)
              | Ok turn_kind_opt ->
              let actor_result =
                match get_string_opt args "actor" with
                | None -> Ok ctx.agent_name
                | Some actor_name
                  when String.equal (String.trim actor_name) ctx.agent_name ->
                    Ok ctx.agent_name
                | Some _ ->
                    Error
                      "actor must match the authenticated caller; omit actor to use the current agent"
              in
              match actor_result with
              | Error e -> (false, json_error e)
              | Ok actor ->
              let base_message = get_string_opt args "message" in
              let target_agent = get_string_opt args "target_agent" in
              let task_title = get_string_opt args "task_title" in
              let task_description = get_string_opt args "task_description" in
              let task_priority = get_int args "task_priority" 3 in
              let append_spawn_event ?spawn_agent ?runtime_actor ?spawn_role
                  ?spawn_model ?worker_class ?parent_actor ?capsule_mode
                  ?runtime_pool ?lane_id ?controller_level ?control_domain
                  ?supervisor_actor ?model_tier ?task_profile ?risk_level
                  ?routing_confidence ?routing_reason ?assigned_runtime
                  ?spawn_selection_note ~success ?exit_code
                  ?elapsed_ms ?output_preview ?error () =
                let detail =
                  `Assoc
                    [
                      ("actor", `String actor);
                      ( "spawn_agent",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          spawn_agent );
                      ( "runtime_actor",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          runtime_actor );
                      ( "spawn_role",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          spawn_role );
                      ( "spawn_model",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          spawn_model );
                      ( "worker_class",
                        Option.fold ~none:`Null
                          ~some:(fun kind ->
                            `String
                              (Team_session_types.worker_class_to_string kind))
                          worker_class );
                      ( "parent_actor",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          parent_actor );
                      ( "capsule_mode",
                        Option.fold ~none:`Null
                          ~some:(fun mode ->
                            `String
                              (Team_session_types.capsule_mode_to_string mode))
                          capsule_mode );
                      ( "runtime_pool",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          runtime_pool );
                      ( "lane_id",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          lane_id );
                      ( "controller_level",
                        Option.fold ~none:`Null
                          ~some:(fun level ->
                            `String
                              (Team_session_types.controller_level_to_string
                                 level))
                          controller_level );
                      ( "control_domain",
                        Option.fold ~none:`Null
                          ~some:(fun domain ->
                            `String
                              (Team_session_types.control_domain_to_string
                                 domain))
                          control_domain );
                      ( "supervisor_actor",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          supervisor_actor );
                      ( "model_tier",
                        Option.fold ~none:`Null
                          ~some:(fun tier ->
                            `String
                              (Team_session_types.model_tier_to_string tier))
                          model_tier );
                      ( "task_profile",
                        Option.fold ~none:`Null
                          ~some:(fun profile ->
                            `String
                              (Team_session_types.task_profile_to_string
                                 profile))
                          task_profile );
                      ( "risk_level",
                        Option.fold ~none:`Null
                          ~some:(fun level ->
                            `String
                              (Team_session_types.risk_level_to_string level))
                          risk_level );
                      ("routing_confidence", float_opt_to_json routing_confidence);
                      ( "routing_reason",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          routing_reason );
                      ( "assigned_runtime",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          assigned_runtime );
                      ( "spawn_selection_note",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          spawn_selection_note );
                      ("success", `Bool success);
                      ("exit_code", int_opt_to_json exit_code);
                      ("elapsed_ms", int_opt_to_json elapsed_ms);
                      ( "output_preview",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          output_preview );
                      ("error", Option.fold ~none:`Null ~some:(fun s -> `String s) error);
                      ("ts_iso", `String (Types.now_iso ()));
                    ]
                in
                Team_session_store.append_event ctx.config session_id
                  ~event_type:"team_step_spawn" ~detail
              in
              let release_prepared_runtime (prepared : prepared_spawn) ~success
                  ?error ?latency_ms () =
                match prepared.runtime_lease with
                | Some lease ->
                    Local_runtime_pool.release lease ~success ?error ?latency_ms ()
                | None -> ()
              in
              let release_all_prepared prepareds ~error =
                List.iter
                  (fun prepared ->
                    release_prepared_runtime prepared ~success:false ~error ())
                  prepareds
              in
              let prepare_spawn (spec : spawn_spec) =
                let runtime_actor_name =
                  if String.equal spec.spawn_agent "llama" then
                    Some
                      (derived_llama_runtime_actor ~session_id
                         ~prompt:spec.spawn_prompt)
                  else
                    None
                in
                let runtime_model =
                  if String.equal spec.spawn_agent "llama" then
                    match spec.spawn_model with
                    | None ->
                        Error
                          "spawn_model is required when spawn_agent=llama"
                    | Some model_name -> (
                        match
                          Local_runtime_pool.acquire
                            ?preferred_pool:spec.runtime_pool
                            ~model_name:(Some model_name) ()
                        with
                        | Ok assignment ->
                            Ok
                              ( Local_runtime_pool.model_spec_of_assignment
                                  assignment,
                                Some assignment.lease,
                                Some assignment.runtime_id )
                        | Error err -> Error err)
                  else
                    Ok (Llm_client.default_local_model_spec (), None, None)
                in
                match runtime_model with
                | Error e -> Error (spec, runtime_actor_name, e)
                | Ok (runtime_model, runtime_lease, assigned_runtime) ->
                    Ok
                      {
                        spec;
                        runtime_actor_name;
                        runtime_model;
                        runtime_lease;
                        assigned_runtime;
                      }
              in
              let prepared_spawns_result =
                let rec loop acc = function
                  | [] -> Ok (List.rev acc)
                  | spec :: rest -> (
                      match prepare_spawn spec with
                      | Ok prepared -> loop (prepared :: acc) rest
                      | Error (failed_spec, runtime_actor_name, msg) ->
                          release_all_prepared (List.rev acc) ~error:msg;
                          append_spawn_event ~spawn_agent:failed_spec.spawn_agent
                            ?runtime_actor:runtime_actor_name
                            ?spawn_role:failed_spec.spawn_role
                            ?spawn_model:failed_spec.spawn_model
                            ?worker_class:failed_spec.worker_class
                            ?parent_actor:failed_spec.parent_actor
                            ?capsule_mode:failed_spec.capsule_mode
                            ?runtime_pool:failed_spec.runtime_pool
                            ?lane_id:failed_spec.lane_id
                            ?controller_level:(inferred_controller_level_of_spec failed_spec)
                            ?control_domain:failed_spec.control_domain
                            ?supervisor_actor:failed_spec.supervisor_actor
                            ?model_tier:failed_spec.model_tier
                            ?task_profile:failed_spec.task_profile
                            ?risk_level:failed_spec.risk_level
                            ?routing_confidence:failed_spec.routing_confidence
                            ?routing_reason:failed_spec.routing_reason
                            ?spawn_selection_note:failed_spec.spawn_selection_note
                            ~success:false ~error:msg ();
                          Error msg)
                in
                loop [] spawn_specs
              in
              let spawn_result_json =
                match prepared_spawns_result with
                | Error msg -> Some (`Assoc [ ("error", `String msg) ])
                | Ok [] -> None
                | Ok prepared_spawns ->
                    let planned_workers =
                      List.map
                        (fun prepared ->
                          planned_worker_of_spec
                            ?runtime_actor:prepared.runtime_actor_name
                            prepared.spec)
                        prepared_spawns
                    in
                    let planning_error =
                      match
                        register_planned_workers ctx.config session_id
                          planned_workers
                      with
                      | Error msg -> Some msg
                      | Ok () -> None
                    in
                    match planning_error with
                    | Some msg ->
                        List.iter
                          (fun prepared ->
                            release_prepared_runtime prepared ~success:false
                              ~error:msg ();
                            append_spawn_event
                              ~spawn_agent:prepared.spec.spawn_agent
                              ?runtime_actor:prepared.runtime_actor_name
                              ?spawn_role:prepared.spec.spawn_role
                              ?spawn_model:prepared.spec.spawn_model
                              ?worker_class:prepared.spec.worker_class
                              ?parent_actor:prepared.spec.parent_actor
                              ?capsule_mode:prepared.spec.capsule_mode
                              ?runtime_pool:prepared.spec.runtime_pool
                              ?lane_id:prepared.spec.lane_id
                              ?controller_level:(inferred_controller_level_of_spec prepared.spec)
                              ?control_domain:prepared.spec.control_domain
                              ?supervisor_actor:prepared.spec.supervisor_actor
                              ?model_tier:prepared.spec.model_tier
                              ?task_profile:prepared.spec.task_profile
                              ?risk_level:prepared.spec.risk_level
                              ?routing_confidence:prepared.spec.routing_confidence
                              ?routing_reason:prepared.spec.routing_reason
                              ?assigned_runtime:prepared.assigned_runtime
                              ?spawn_selection_note:
                                prepared.spec.spawn_selection_note
                              ~success:false ~error:msg ())
                          prepared_spawns;
                        Some (`Assoc [ ("error", `String msg) ])
                    | None ->
                        match ctx.proc_mgr with
                        | None ->
                            let msg =
                              "process manager unavailable for team step spawn"
                            in
                            List.iter
                              (fun prepared ->
                                release_prepared_runtime prepared ~success:false
                                  ~error:msg ();
                                append_spawn_event
                                  ~spawn_agent:prepared.spec.spawn_agent
                                  ?runtime_actor:prepared.runtime_actor_name
                                  ?spawn_role:prepared.spec.spawn_role
                                  ?spawn_model:prepared.spec.spawn_model
                                  ?worker_class:prepared.spec.worker_class
                                  ?parent_actor:prepared.spec.parent_actor
                                  ?capsule_mode:prepared.spec.capsule_mode
                                  ?runtime_pool:prepared.spec.runtime_pool
                                  ?lane_id:prepared.spec.lane_id
                                  ?controller_level:(inferred_controller_level_of_spec prepared.spec)
                                  ?control_domain:prepared.spec.control_domain
                                  ?supervisor_actor:prepared.spec.supervisor_actor
                                  ?model_tier:prepared.spec.model_tier
                                  ?task_profile:prepared.spec.task_profile
                                  ?risk_level:prepared.spec.risk_level
                                  ?routing_confidence:
                                    prepared.spec.routing_confidence
                                  ?routing_reason:prepared.spec.routing_reason
                                  ?assigned_runtime:prepared.assigned_runtime
                                  ?spawn_selection_note:
                                    prepared.spec.spawn_selection_note
                                  ~success:false ~error:msg ())
                              prepared_spawns;
                            Some (`Assoc [ ("error", `String msg) ])
                        | Some pm ->
                            let rec ensure_all = function
                              | [] -> Ok ()
                              | prepared :: rest -> (
                                  match prepared.runtime_actor_name with
                                  | None -> ensure_all rest
                                  | Some worker_actor -> (
                                      match
                                        ensure_session_actor ctx.config
                                          session_id worker_actor
                                      with
                                      | Ok () -> ensure_all rest
                                      | Error msg -> Error msg))
                            in
                            match ensure_all prepared_spawns with
                             | Error msg ->
                                 List.iter
                                   (fun prepared ->
                                     release_prepared_runtime prepared
                                       ~success:false ~error:msg ();
                                     append_spawn_event
                                       ~spawn_agent:prepared.spec.spawn_agent
                                       ?runtime_actor:prepared.runtime_actor_name
                                       ?spawn_role:prepared.spec.spawn_role
                                       ?spawn_model:prepared.spec.spawn_model
                                       ?worker_class:prepared.spec.worker_class
                                       ?parent_actor:prepared.spec.parent_actor
                                       ?capsule_mode:prepared.spec.capsule_mode
                                       ?runtime_pool:prepared.spec.runtime_pool
                                       ?lane_id:prepared.spec.lane_id
                                       ?controller_level:(inferred_controller_level_of_spec prepared.spec)
                                       ?control_domain:prepared.spec.control_domain
                                       ?supervisor_actor:prepared.spec.supervisor_actor
                                       ?model_tier:prepared.spec.model_tier
                                       ?task_profile:prepared.spec.task_profile
                                       ?risk_level:prepared.spec.risk_level
                                       ?routing_confidence:
                                         prepared.spec.routing_confidence
                                       ?routing_reason:
                                         prepared.spec.routing_reason
                                       ?assigned_runtime:prepared.assigned_runtime
                                       ?spawn_selection_note:
                                         prepared.spec.spawn_selection_note
                                       ~success:false ~error:msg ())
                                   prepared_spawns;
                                 Some (`Assoc [ ("error", `String msg) ])
                             | Ok () ->
                                 let results =
                                   Array.make (List.length prepared_spawns) None
                                 in
                                 Eio.Fiber.all
                                   (List.mapi
                                      (fun index prepared () ->
                                        let spawn_result =
                                          Spawn_eio.spawn ~sw:ctx.sw ~proc_mgr:pm
                                            ~agent_name:prepared.spec.spawn_agent
                                            ~prompt:prepared.spec.spawn_prompt
                                            ~timeout_seconds:
                                              prepared.spec.spawn_timeout_seconds
                                            ~room_config:ctx.config
                                            ?runtime_agent_name:
                                              prepared.runtime_actor_name
                                            ~runtime_model:prepared.runtime_model
                                            ?runtime_role:prepared.spec.spawn_role
                                            ?runtime_selection_note:
                                              prepared.spec.spawn_selection_note
                                            ~runtime_session_id:session_id ()
                                        in
                                        let output_preview =
                                          truncate_for_event spawn_result.output
                                        in
                                        (match spawn_result.success with
                                        | true ->
                                            release_prepared_runtime prepared
                                              ~success:true
                                              ~latency_ms:spawn_result.elapsed_ms ()
                                        | false ->
                                            release_prepared_runtime prepared
                                              ~success:false
                                              ~error:spawn_result.output
                                              ~latency_ms:spawn_result.elapsed_ms ());
                                        append_spawn_event
                                          ~spawn_agent:prepared.spec.spawn_agent
                                          ?runtime_actor:prepared.runtime_actor_name
                                          ?spawn_role:prepared.spec.spawn_role
                                          ?spawn_model:prepared.spec.spawn_model
                                          ?worker_class:prepared.spec.worker_class
                                          ?parent_actor:prepared.spec.parent_actor
                                          ?capsule_mode:prepared.spec.capsule_mode
                                          ?runtime_pool:prepared.spec.runtime_pool
                                          ?lane_id:prepared.spec.lane_id
                                          ?controller_level:(inferred_controller_level_of_spec prepared.spec)
                                          ?control_domain:prepared.spec.control_domain
                                          ?supervisor_actor:prepared.spec.supervisor_actor
                                          ?model_tier:prepared.spec.model_tier
                                          ?task_profile:prepared.spec.task_profile
                                          ?risk_level:prepared.spec.risk_level
                                          ?routing_confidence:prepared.spec.routing_confidence
                                          ?routing_reason:prepared.spec.routing_reason
                                          ?assigned_runtime:prepared.assigned_runtime
                                          ?spawn_selection_note:
                                            prepared.spec.spawn_selection_note
                                          ~success:spawn_result.success
                                          ~exit_code:spawn_result.exit_code
                                          ~elapsed_ms:spawn_result.elapsed_ms
                                          ~output_preview ();
                                        (match
                                           ( spawn_result.success,
                                             prepared.runtime_actor_name,
                                             auto_note_message_of_spawn_output
                                               spawn_result.output )
                                         with
                                        | true, Some worker_actor, Some auto_note
                                          when not
                                                 (session_has_turn_for_actor
                                                    ctx.config session_id
                                                    worker_actor) ->
                                            ignore
                                              (record_session_turn_json
                                                 ~config:ctx.config ~session_id
                                                 ~actor:worker_actor
                                                 ~turn_kind:
                                                   Team_session_types.Turn_note
                                                 ~message:(Some auto_note)
                                                 ~target_agent:None
                                                 ~task_title:None
                                                 ~task_description:None
                                                 ~task_priority:3)
                                        | _ -> ());
                                        (match
                                           (spawn_result.success, prepared.runtime_actor_name)
                                         with
                                        | false, Some worker_actor ->
                                            ignore
                                              (reconcile_failed_spawn_actor
                                                 ctx.config session_id
                                                 worker_actor)
                                        | _ -> ());
                                        results.(index) <-
                                          Some
                                            (`Assoc
                                              [
                                                ("agent", `String prepared.spec.spawn_agent);
                                                ( "runtime_actor",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun s -> `String s)
                                                    prepared.runtime_actor_name );
                                                ( "spawn_role",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun s -> `String s)
                                                    prepared.spec.spawn_role );
                                                ( "spawn_model",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun s -> `String s)
                                                    prepared.spec.spawn_model );
                                                ( "worker_class",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun kind ->
                                                      `String
                                                        (Team_session_types.worker_class_to_string
                                                           kind))
                                                    prepared.spec.worker_class );
                                                ( "parent_actor",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun s -> `String s)
                                                    prepared.spec.parent_actor );
                                                ( "capsule_mode",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun mode ->
                                                      `String
                                                        (Team_session_types.capsule_mode_to_string
                                                           mode))
                                                    prepared.spec.capsule_mode );
                                                ( "runtime_pool",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun s -> `String s)
                                                    prepared.spec.runtime_pool );
                                                ( "lane_id",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun s -> `String s)
                                                    prepared.spec.lane_id );
                                                ( "controller_level",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun level ->
                                                      `String
                                                        (Team_session_types.controller_level_to_string
                                                           level))
                                                    (inferred_controller_level_of_spec
                                                       prepared.spec) );
                                                ( "control_domain",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun domain ->
                                                      `String
                                                        (Team_session_types.control_domain_to_string
                                                           domain))
                                                    prepared.spec.control_domain );
                                                ( "supervisor_actor",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun s -> `String s)
                                                    prepared.spec.supervisor_actor );
                                                ( "model_tier",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun tier ->
                                                      `String
                                                        (Team_session_types.model_tier_to_string
                                                           tier))
                                                    prepared.spec.model_tier );
                                                ( "task_profile",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun profile ->
                                                      `String
                                                        (Team_session_types.task_profile_to_string
                                                           profile))
                                                    prepared.spec.task_profile );
                                                ( "risk_level",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun level ->
                                                      `String
                                                        (Team_session_types.risk_level_to_string
                                                           level))
                                                    prepared.spec.risk_level );
                                                ( "routing_confidence",
                                                  float_opt_to_json
                                                    prepared.spec.routing_confidence
                                                );
                                                ( "routing_reason",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun s -> `String s)
                                                    prepared.spec.routing_reason );
                                                ( "assigned_runtime",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun s -> `String s)
                                                    prepared.assigned_runtime );
                                                ( "spawn_selection_note",
                                                  Option.fold ~none:`Null
                                                    ~some:(fun s -> `String s)
                                                    prepared.spec.spawn_selection_note );
                                                ("success", `Bool spawn_result.success);
                                                ("exit_code", `Int spawn_result.exit_code);
                                                ("elapsed_ms", `Int spawn_result.elapsed_ms);
                                                ("output_preview", `String output_preview);
                                                ( "input_tokens",
                                                  int_opt_to_json
                                                    spawn_result.input_tokens );
                                                ( "output_tokens",
                                                  int_opt_to_json
                                                    spawn_result.output_tokens );
                                                ( "cache_creation_tokens",
                                                  int_opt_to_json
                                                    spawn_result.cache_creation_tokens
                                                );
                                                ( "cache_read_tokens",
                                                  int_opt_to_json
                                                    spawn_result.cache_read_tokens );
                                                ( "cost_usd",
                                                  float_opt_to_json
                                                    spawn_result.cost_usd );
                                              ]))
                                      prepared_spawns);
                                 let spawn_results =
                                   results
                                   |> Array.to_list
                                   |> List.filter_map (fun item -> item)
                                 in
                                 Some
                                   (if List.length spawn_results = 1 then
                                      List.hd spawn_results
                                    else
                                      `Assoc
                                        [
                                          ("mode", `String "batch");
                                          ("count", `Int (List.length spawn_results));
                                          ("results", `List spawn_results);
                                        ])
              in
              let spawn_error =
                match spawn_result_json with
                | Some (`Assoc fields) -> (
                    match List.assoc_opt "error" fields with
                    | Some (`String e) when String.trim e <> "" -> Some e
                    | _ -> None)
                | _ -> None
              in
              match spawn_error with
              | Some e -> (false, json_error e)
              | None ->
                  let turn_json_result =
                    match turn_kind_opt with
                    | None -> Ok None
                    | Some turn_kind ->
                        record_session_turn_json ~config:ctx.config ~session_id
                          ~actor ~turn_kind ~message:base_message
                          ~target_agent ~task_title ~task_description
                          ~task_priority
                        |> Result.map Option.some
                  in
                  match turn_json_result with
                  | Error e -> (false, json_error e)
                  | Ok turn_json ->
                      let vote_result_json =
                        match get_string_opt args "vote_topic" with
                        | None -> None
                        | Some vote_topic ->
                            let vote_options = get_string_list args "vote_options" in
                            if List.length vote_options < 2 then
                              Some
                                (`Assoc
                                  [
                                    ("error", `String "vote_options requires at least 2 items");
                                  ])
                            else
                              let required_votes = get_int args "vote_required_votes" 2 in
                              let vote_create_msg =
                                Room.vote_create ctx.config ~proposer:actor
                                  ~topic:vote_topic ~options:vote_options
                                  ~required_votes
                              in
                              let vote_id = extract_vote_id vote_create_msg in
                              Team_session_store.append_event ctx.config session_id
                                ~event_type:"team_vote_created"
                                ~detail:
                                  (`Assoc
                                    [
                                      ("actor", `String actor);
                                      ("topic", `String vote_topic);
                                      ("required_votes", `Int required_votes);
                                      ("options", `List (List.map (fun o -> `String o) vote_options));
                                      ("vote_id", Option.fold ~none:`Null ~some:(fun s -> `String s) vote_id);
                                      ("result", `String vote_create_msg);
                                      ("ts_iso", `String (Types.now_iso ()));
                                    ]);
                              let cast_json =
                                match (vote_id, get_string_opt args "vote_choice") with
                                | Some vid, Some choice ->
                                    let cast_msg =
                                      Room.vote_cast ctx.config ~agent_name:actor
                                        ~vote_id:vid ~choice
                                    in
                                    Team_session_store.append_event ctx.config session_id
                                      ~event_type:"team_vote_cast"
                                      ~detail:
                                        (`Assoc
                                          [
                                            ("actor", `String actor);
                                            ("vote_id", `String vid);
                                            ("choice", `String choice);
                                            ("result", `String cast_msg);
                                            ("ts_iso", `String (Types.now_iso ()));
                                          ]);
                                    Some (`Assoc [ ("vote_id", `String vid); ("choice", `String choice); ("result", `String cast_msg) ])
                                | _ -> None
                              in
                              Some
                                (`Assoc
                                  [
                                    ("created", `String vote_create_msg);
                                    ("vote_id", Option.fold ~none:`Null ~some:(fun s -> `String s) vote_id);
                                    ("cast", Option.fold ~none:`Null ~some:(fun j -> j) cast_json);
                                  ])
                      in
                      let vote_error =
                        match vote_result_json with
                        | Some (`Assoc fields) -> (
                            match List.assoc_opt "error" fields with
                            | Some (`String e) when String.trim e <> "" -> Some e
                            | _ -> None)
                        | _ -> None
                      in
                      match vote_error with
                      | Some e -> (false, json_error e)
                      | None ->
                          let run_json =
                            match get_string_opt args "run_task_id" with
                            | None -> None
                            | Some run_task_id ->
                                let run_agent = actor in
                                let init_json =
                                  match
                                    Run_eio.init ctx.config ~task_id:run_task_id
                                      ~agent_name:(Some run_agent)
                                  with
                                  | Ok run -> `Assoc [ ("status", `String "initialized"); ("run", Run_eio.run_record_to_json run) ]
                                  | Error e -> `Assoc [ ("status", `String "init_failed"); ("error", `String e) ]
                                in
                                let note_json =
                                  match get_string_opt args "run_note" with
                                  | None -> `Null
                                  | Some note -> (
                                      match Run_eio.append_log ctx.config ~task_id:run_task_id ~note with
                                      | Ok entry -> `Assoc [ ("status", `String "ok"); ("entry", Run_eio.log_entry_to_json entry) ]
                                      | Error e -> `Assoc [ ("status", `String "error"); ("message", `String e) ])
                                in
                                let deliverable_json =
                                  match get_string_opt args "run_deliverable" with
                                  | None -> `Null
                                  | Some content -> (
                                      match
                                        Run_eio.set_deliverable ctx.config
                                          ~task_id:run_task_id ~content
                                      with
                                      | Ok run ->
                                          Team_session_store.append_event ctx.config
                                            session_id
                                            ~event_type:"team_run_deliverable"
                                            ~detail:
                                              (`Assoc
                                                [
                                                  ("actor", `String actor);
                                                  ("run_task_id", `String run_task_id);
                                                  ("deliverable_preview", `String (truncate_for_event content));
                                                  ("ts_iso", `String (Types.now_iso ()));
                                                ]);
                                          `Assoc [ ("status", `String "ok"); ("run", Run_eio.run_record_to_json run) ]
                                      | Error e ->
                                          `Assoc [ ("status", `String "error"); ("message", `String e) ])
                                in
                                Some
                                  (`Assoc
                                    [
                                      ("task_id", `String run_task_id);
                                      ("init", init_json);
                                      ("note", note_json);
                                      ("deliverable", deliverable_json);
                                    ])
                          in
                          let response =
                            `Assoc
                              [
                                ("session_id", `String session_id);
                                ("turn", Option.value ~default:`Null turn_json);
                                ("spawn", Option.fold ~none:`Null ~some:(fun j -> j) spawn_result_json);
                                ("vote", Option.fold ~none:`Null ~some:(fun j -> j) vote_result_json);
                                ("run", Option.fold ~none:`Null ~some:(fun j -> j) run_json);
                              ]
                          in
                          (true, json_ok [ ("result", response) ]))

let handle_finalize ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let reason = get_string args "reason" "finalize" in
          let _wait_timeout_sec = get_int args "wait_timeout_sec" 45 in
          let generate_report = get_bool args "generate_report" true in
          let generate_proof = get_bool args "generate_proof" true in
          let proof_level = parse_proof_level args in
          match
            Team_session_engine_eio.finalize_session ~config:ctx.config ~session_id
              ~final_status:Team_session_types.Interrupted ~reason
              ~generate_report
          with
          | None -> (false, json_error ("team session not found: " ^ session_id))
          | Some finalized_session ->
              let terminal_status =
                Team_session_types.status_to_string finalized_session.status
              in
              let status_json =
                Team_session_engine_eio.session_status_json ctx.config
                  finalized_session
              in
                  let report_json =
                    if generate_report then
                      match
                        Team_session_engine_eio.generate_report ~config:ctx.config
                          ~session_id ~force_regenerate:false
                      with
                      | Ok json ->
                          `Assoc [ ("status", `String "ok"); ("result", json) ]
                      | Error e ->
                          `Assoc
                            [ ("status", `String "error"); ("message", `String e) ]
                    else
                      `Null
                  in
                  let report_error =
                    match report_json with
                    | `Assoc fields -> (
                        match List.assoc_opt "status" fields with
                        | Some (`String "error") -> (
                            match List.assoc_opt "message" fields with
                            | Some (`String msg) -> Some msg
                            | _ -> Some "report generation failed")
                        | _ -> None)
                    | _ -> None
                  in
                  (match report_error with
                  | Some e -> (false, json_error e)
                  | None ->
                      let proof_json =
                        if generate_proof then
                          match
                            Team_session_engine_eio.prove_session
                              ~config:ctx.config ~session_id ~proof_level
                              ~generate_report_if_missing:generate_report
                          with
                          | Ok json ->
                              `Assoc [ ("status", `String "ok"); ("result", json) ]
                          | Error e ->
                              `Assoc
                                [
                                  ("status", `String "error");
                                  ("message", `String e);
                                ]
                        else
                          `Null
                      in
                      let proof_error =
                        match proof_json with
                        | `Assoc fields -> (
                            match List.assoc_opt "status" fields with
                            | Some (`String "error") -> (
                                match List.assoc_opt "message" fields with
                                | Some (`String msg) -> Some msg
                                | _ -> Some "proof generation failed")
                            | _ -> None)
                        | _ -> None
                      in
                      match proof_error with
                      | Some e -> (false, json_error e)
                      | None ->
                          let payload =
                            `Assoc
                              [
                                ("session_id", `String session_id);
                                ("terminal_status", `String terminal_status);
                                ("status", `String terminal_status);
                                ("status_detail", status_json);
                                ("report", report_json);
                                ("proof", proof_json);
                              ]
                          in
                          ( true,
                            json_ok
                              [
                                ("result", payload);
                              ] )))

let handle_events ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let event_types = get_string_list args "event_types" in
          let limit = get_int args "limit" 200 in
          let after_ts = get_float_opt args "after_ts" in
          (match
             Team_session_engine_eio.list_events ~config:ctx.config ~session_id
               ~event_types ~limit ~after_ts
           with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_prove ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let generate_report_if_missing =
            get_bool args "generate_report_if_missing" true
          in
          let proof_level = parse_proof_level args in
          (match
             Team_session_engine_eio.prove_session ~config:ctx.config ~session_id
               ~proof_level
               ~generate_report_if_missing
           with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_team_session_start" -> Some (handle_start ctx args)
  | "masc_team_session_step" -> Some (handle_step ctx args)
  | "masc_team_session_status" -> Some (handle_status ctx args)
  | "masc_team_session_finalize" -> Some (handle_finalize ctx args)
  | "masc_team_session_stop" -> Some (handle_stop ctx args)
  | "masc_team_session_report" -> Some (handle_report ctx args)
  | "masc_team_session_list" -> Some (handle_list ctx args)
  | "masc_team_session_compare" -> Some (handle_compare ctx args)
  | "masc_team_session_turn" -> Some (handle_turn ctx args)
  | "masc_team_session_events" -> Some (handle_events ctx args)
  | "masc_team_session_prove" -> Some (handle_prove ctx args)
  | _ -> None

let schemas : tool_schema list =
  [
    {
      name = "masc_team_session_start";
      description =
        "Start a long-running team collaboration session with periodic checkpoints and final report artifacts.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "goal",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Session goal (required)");
                      ] );
                  ( "operation_id",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "description",
                          `String
                            "Optional managed CPv2 operation id to attach this team session to. When provided, the operation detachment_session_id is updated to this session." );
                      ] );
                  ( "duration_seconds",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String
                            "Session duration in seconds (default: 3600)" );
                      ] );
                  ( "duration_minutes",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String
                            "Session duration in minutes (used when duration_seconds is omitted)" );
                      ] );
                  ( "execution_scope",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "observe_only";
                              `String "limited_code_change";
                            ] );
                      ] );
                  ( "checkpoint_interval_sec",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String "Checkpoint interval in seconds (default: 60)"
                        );
                      ] );
                  ( "min_agents",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String "Minimum expected participating agents" );
                      ] );
                  ( "orchestration_mode",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "manual";
                              `String "assist";
                              `String "auto";
                            ] );
                      ] );
	                  ( "communication_mode",
	                    `Assoc
	                      [
	                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "off";
                              `String "broadcast";
                              `String "portal";
	                              `String "hybrid";
	                            ] );
	                      ] );
	                  ( "scale_profile",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ("enum", `List [ `String "standard"; `String "local64" ]);
	                      ] );
	                  ( "control_profile",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ("enum", `List [ `String "flat"; `String "hierarchical_quality_v1" ]);
	                      ] );
	                  ( "model_cascade",
	                    `Assoc
	                      [
	                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ( "fallback_policy",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "none";
                              `String "cascade_then_task";
                              `String "task_only";
                              `String "local_first_conditional";
                              `String "strict_local_only";
                              `String "cloud_first";
                            ] );
                      ] );
                  ( "instruction_profile",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "standard"; `String "strict" ]);
                      ] );
                  ( "alert_channel",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [ `String "broadcast"; `String "board"; `String "both" ]
                        );
                      ] );
                  ( "auto_resume",
                    `Assoc
                      [
                        ("type", `String "boolean");
                        ( "description",
                          `String "Recover and resume after process restart" );
                      ] );
                  ( "report_formats",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ( "agents",
                    `Assoc
                      [
                        ("type", `String "array");
                        ( "items",
                          `Assoc
                            [
                              ( "oneOf",
                                `List
                                  [
                                    `Assoc [ ("type", `String "string") ];
                                    `Assoc
                                      [
                                        ("type", `String "object");
                                        ( "properties",
                                          `Assoc
                                            [
                                              ("name", `Assoc [ ("type", `String "string") ]);
                                            ] );
                                      ];
                                  ] );
                            ] );
                      ] );
                ] );
            ("required", `List [ `String "goal" ]);
          ];
    };
    {
      name = "masc_team_session_status";
      description = "Get the current status and progress summary for a team session.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc [ ("session_id", `Assoc [ ("type", `String "string") ]) ]
            );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_step";
      description =
        "Canonical team-session write entrypoint: record a note/broadcast/portal/task/checkpoint turn, optionally spawn workers, and optionally attach vote/run evidence.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ( "turn_kind",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "note";
                              `String "broadcast";
                              `String "portal";
                              `String "task";
                              `String "checkpoint";
                            ] );
                      ] );
                  ( "actor",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "description",
                          `String
                            "Optional explicit actor. If provided, it must match the authenticated caller." );
                      ] );
                  ("message", `Assoc [ ("type", `String "string") ]);
                  ("target_agent", `Assoc [ ("type", `String "string") ]);
                  ("task_title", `Assoc [ ("type", `String "string") ]);
                  ("task_description", `Assoc [ ("type", `String "string") ]);
                  ("task_priority", `Assoc [ ("type", `String "integer") ]);
	                  ("spawn_agent", `Assoc [ ("type", `String "string") ]);
	                  ("spawn_model", `Assoc [ ("type", `String "string") ]);
	                  ("spawn_role", `Assoc [ ("type", `String "string") ]);
	                  ( "worker_class",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "manager";
	                              `String "executor";
	                              `String "scout";
	                              `String "librarian";
	                              `String "metacog";
	                            ] );
	                      ] );
	                  ("parent_actor", `Assoc [ ("type", `String "string") ]);
	                  ( "capsule_mode",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "fresh";
	                              `String "inherit";
	                              `String "capsule";
	                            ] );
	                      ] );
	                  ("runtime_pool", `Assoc [ ("type", `String "string") ]);
	                  ("lane_id", `Assoc [ ("type", `String "string") ]);
	                  ( "control_domain",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "execution";
	                              `String "quality";
	                              `String "knowledge";
	                              `String "runtime";
	                              `String "meta";
	                            ] );
	                      ] );
	                  ("supervisor_actor", `Assoc [ ("type", `String "string") ]);
	                  ( "model_tier",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ("enum", `List [ `String "35b"; `String "27b"; `String "9b" ]);
	                      ] );
	                  ( "task_profile",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "extract";
	                              `String "normalize";
	                              `String "summarize";
	                              `String "verify";
	                              `String "decide";
	                              `String "synthesize";
	                            ] );
	                      ] );
	                  ( "risk_level",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "low";
	                              `String "medium";
	                              `String "high";
	                            ] );
	                      ] );
	                  ("routing_confidence", `Assoc [ ("type", `String "number") ]);
	                  ("routing_reason", `Assoc [ ("type", `String "string") ]);
	                  ("spawn_selection_note", `Assoc [ ("type", `String "string") ]);
	                  ("spawn_prompt", `Assoc [ ("type", `String "string") ]);
	                  ("spawn_timeout_seconds", `Assoc [ ("type", `String "integer") ]);
                  ( "spawn_batch",
                    `Assoc
                      [
                        ("type", `String "array");
                        ( "items",
                          `Assoc
                            [
                              ("type", `String "object");
                              ( "properties",
                                `Assoc
	                                  [
	                                    ("spawn_agent", `Assoc [ ("type", `String "string") ]);
	                                    ("spawn_model", `Assoc [ ("type", `String "string") ]);
	                                    ("spawn_role", `Assoc [ ("type", `String "string") ]);
	                                    ( "worker_class",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "manager";
	                                                `String "executor";
	                                                `String "scout";
	                                                `String "librarian";
	                                                `String "metacog";
	                                              ] );
	                                        ] );
	                                    ("parent_actor", `Assoc [ ("type", `String "string") ]);
	                                    ( "capsule_mode",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "fresh";
	                                                `String "inherit";
	                                                `String "capsule";
	                                              ] );
	                                        ] );
	                                    ("runtime_pool", `Assoc [ ("type", `String "string") ]);
	                                    ("lane_id", `Assoc [ ("type", `String "string") ]);
	                                    ( "control_domain",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "execution";
	                                                `String "quality";
	                                                `String "knowledge";
	                                                `String "runtime";
	                                                `String "meta";
	                                              ] );
	                                        ] );
	                                    ("supervisor_actor", `Assoc [ ("type", `String "string") ]);
	                                    ( "model_tier",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ("enum", `List [ `String "35b"; `String "27b"; `String "9b" ]);
	                                        ] );
	                                    ( "task_profile",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "extract";
	                                                `String "normalize";
	                                                `String "summarize";
	                                                `String "verify";
	                                                `String "decide";
	                                                `String "synthesize";
	                                              ] );
	                                        ] );
	                                    ( "risk_level",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "low";
	                                                `String "medium";
	                                                `String "high";
	                                              ] );
	                                        ] );
	                                    ("routing_confidence", `Assoc [ ("type", `String "number") ]);
	                                    ("routing_reason", `Assoc [ ("type", `String "string") ]);
	                                    ( "spawn_selection_note",
	                                      `Assoc [ ("type", `String "string") ] );
	                                    ("spawn_prompt", `Assoc [ ("type", `String "string") ]);
                                    ( "spawn_timeout_seconds",
                                      `Assoc [ ("type", `String "integer") ] );
                                  ] );
                              ( "required",
                                `List
                                  [
                                    `String "spawn_agent";
                                    `String "spawn_prompt";
                                  ] );
                            ] );
                      ] );
                  ("vote_topic", `Assoc [ ("type", `String "string") ]);
                  ( "vote_options",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ("vote_required_votes", `Assoc [ ("type", `String "integer") ]);
                  ("vote_choice", `Assoc [ ("type", `String "string") ]);
                  ("run_task_id", `Assoc [ ("type", `String "string") ]);
                  ("run_note", `Assoc [ ("type", `String "string") ]);
                  ("run_deliverable", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_finalize";
      description =
        "Stop session, wait for terminal status, then optionally generate report and proof in one command.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("reason", `Assoc [ ("type", `String "string") ]);
                  ("wait_timeout_sec", `Assoc [ ("type", `String "integer") ]);
                  ("generate_report", `Assoc [ ("type", `String "boolean") ]);
                  ("generate_proof", `Assoc [ ("type", `String "boolean") ]);
                  ( "proof_level",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "standard"; `String "strong" ]);
                      ] );
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_stop";
      description =
        "Request stop for a team session and optionally generate report artifacts.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("reason", `Assoc [ ("type", `String "string") ]);
                  ("generate_report", `Assoc [ ("type", `String "boolean") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_report";
      description = "Generate (or regenerate) report artifacts for a team session.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("force_regenerate", `Assoc [ ("type", `String "boolean") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_list";
      description =
        "List recent team sessions with optional status filter and health/cascade summary.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("status", `Assoc [ ("type", `String "string") ]);
                  ( "limit",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ("description", `String "Max sessions to return (default: 20)");
                      ] );
                ] );
          ];
    };
    {
      name = "masc_team_session_compare";
      description =
        "Compare two team sessions and return throughput/policy/communication deltas.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("base_session_id", `Assoc [ ("type", `String "string") ]);
                  ("target_session_id", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "base_session_id"; `String "target_session_id" ]);
          ];
    };
    {
      name = "masc_team_session_turn";
      description =
        "Legacy compatibility entrypoint for plain team-session turn recording only; use masc_team_session_step for all new team-session writes.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ( "turn_kind",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "note";
                              `String "broadcast";
                              `String "portal";
                              `String "task";
                              `String "checkpoint";
                            ] );
                      ] );
                  ("message", `Assoc [ ("type", `String "string") ]);
                  ("target_agent", `Assoc [ ("type", `String "string") ]);
                  ("task_title", `Assoc [ ("type", `String "string") ]);
                  ("task_description", `Assoc [ ("type", `String "string") ]);
                  ("task_priority", `Assoc [ ("type", `String "integer") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_events";
      description =
        "Read team session event timeline with optional event type and timestamp filters.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ( "event_types",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ("after_ts", `Assoc [ ("type", `String "number") ]);
                  ("limit", `Assoc [ ("type", `String "integer") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_prove";
      description =
        "Generate verifiable proof artifacts (proof.json/proof.md) for a team session based on timeline evidence.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ( "generate_report_if_missing",
                    `Assoc [ ("type", `String "boolean") ] );
                  ( "proof_level",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "standard"; `String "strong" ]);
                      ] );
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
  ]
