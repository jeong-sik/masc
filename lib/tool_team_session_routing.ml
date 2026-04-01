(** Routing, spawn spec parsing, model inference, and worker management
    for team session step execution. *)

let int_opt_to_json = Json_util.int_opt_to_json
let float_opt_to_json = Json_util.float_opt_to_json

let truncate_for_event ?(max_len = 320) (s : string) =
  if String.length s <= max_len then
    s
  else
    String.sub s 0 max_len ^ "..."

let derived_local_runtime_actor ~session_id ~prompt =
  let digest = Digest.string (session_id ^ "\n" ^ prompt) |> Digest.to_hex in
  Printf.sprintf "local-%s" (String.sub digest 0 8)

let normalize_spawn_agent agent_name =
  let normalized = String.lowercase_ascii (String.trim agent_name) in
  if normalized = "" then "default" else normalized

let is_local_spawn_agent agent_name =
  match normalize_spawn_agent agent_name with
  | "default" | "llama" -> true
  | _ -> false

let legacy_spawn_fields = [ "spawn_agent"; "spawn_model"; "model_tier" ]

let find_present_json_key keys json =
  List.find_opt (fun key -> Yojson.Safe.Util.member key json <> `Null) keys

let legacy_spawn_field_error ?batch_index field =
  match batch_index with
  | Some index ->
      Printf.sprintf
        "spawn_batch[%d].%s is no longer supported in masc_team_session_step; \
         use spawn_prompt, spawn_role, worker_class, and worker_size"
        index field
  | None ->
      Printf.sprintf
        "%s is no longer supported in masc_team_session_step; use spawn_prompt, \
         spawn_role, worker_class, and worker_size"
        field

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

type spawn_spec = Tool_team_session_step.spawn_spec = {
  spawn_agent : string;
  spawn_prompt : string;
  spawn_model : string option;
  spawn_model_explicit : bool;
  spawn_role : string option;
  execution_scope : Team_session_types.execution_scope option;
  thinking_enabled : bool option;
  thinking_budget : int option;
  max_turns : int option;
  worker_class : Team_session_types.worker_class option;
  worker_size : Team_session_types.worker_size option;
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

type prepared_spawn = Tool_team_session_step.prepared_spawn = {
  worker_run_id : string;
  spec : spawn_spec;
  runtime_actor_name : string option;
  runtime_model_label : string;
  runtime_lease : Local_runtime_pool.lease option;
  assigned_runtime : string option;
  mutable lease_released : bool;
}

let trim_opt = function
  | None -> None
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed

let env_trim_opt name = Sys.getenv_opt name |> trim_opt

let default_worker_size_for_class = function
  | Some Team_session_types.Worker_manager ->
      Some Team_session_types.Worker_xlg
  | Some Team_session_types.Worker_executor ->
      Some Team_session_types.Worker_lg
  | Some Team_session_types.Worker_scout
  | Some Team_session_types.Worker_librarian ->
      Some Team_session_types.Worker_sm
  | Some Team_session_types.Worker_metacog ->
      Some Team_session_types.Worker_lg
  | None -> Some Team_session_types.Worker_lg

let effective_execution_scope_of_spec spec =
  Some
    (Team_session_types.effective_execution_scope
       ~worker_class:spec.worker_class spec.execution_scope)

let explicit_worker_size_of_spec (spec : spawn_spec) =
  match spec.worker_size with
  | Some _ as size -> size
  | None ->
      Option.bind spec.model_tier Team_session_types.worker_size_of_model_tier

let worker_size_of_spec (spec : spawn_spec) =
  match explicit_worker_size_of_spec spec with
  | Some _ as size -> size
  | None -> default_worker_size_for_class spec.worker_class

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

(** [contains_size_token_ci haystack token] checks that [token] appears in
    [haystack] as a word-boundary-delimited token, preventing false positives
    like "109b" matching "9b". Boundaries: start/end of string, or any
    non-alphanumeric/non-underscore character. *)
let contains_size_token_ci haystack token =
  let h = String.lowercase_ascii haystack in
  let t = String.lowercase_ascii token in
  let h_len = String.length h in
  let t_len = String.length t in
  let is_alnum c =
    (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_'
  in
  let rec loop idx =
    if idx + t_len > h_len then false
    else if String.sub h idx t_len = t then
      let before_ok = idx = 0 || not (is_alnum (String.get h (idx - 1))) in
      let after_ok =
        idx + t_len >= h_len || not (is_alnum (String.get h (idx + t_len)))
      in
      if before_ok && after_ok then true else loop (idx + 1)
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

let explicit_lead_model () = Env_config.TeamSession.model_35b_opt ()
let explicit_middle_model () = Env_config.TeamSession.model_27b_opt ()
let explicit_worker_model () = Env_config.TeamSession.model_9b_opt ()

let inferred_lead_model () =
  match explicit_lead_model () with
  | Some _ as explicit -> explicit
  | None -> (
      match env_trim_opt "LLAMA_SWARM_MODEL" with
      | Some _ as env_model -> env_model
      | None ->
          runtime_inventory_models ()
          |> List.find_opt (fun model -> contains_size_token_ci model "35b"))

let inferred_middle_model () =
  match explicit_middle_model () with
  | Some _ as explicit -> explicit
  | None ->
      runtime_inventory_models ()
      |> List.find_opt (fun model -> contains_size_token_ci model "27b")

let inferred_worker_model () =
  match explicit_worker_model () with
  | Some _ as explicit -> explicit
  | None ->
      runtime_inventory_models ()
      |> List.find_opt (fun model -> contains_size_token_ci model "9b")

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
      | _ when contains_size_token_ci model_name "35b" ->
          Some Team_session_types.Tier_35b
      | _ when contains_size_token_ci model_name "27b" ->
          Some Team_session_types.Tier_27b
      | _ when contains_size_token_ci model_name "9b" ->
          Some Team_session_types.Tier_9b
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
  Env_config.TeamSession.router_judge_enabled ()

let router_judge_timeout_sec () =
  Env_config.TeamSession.router_judge_timeout_sec ()

let router_judge_confidence_threshold () =
  Env_config.TeamSession.router_judge_confidence_threshold ()

let router_judge_model () =
  match Env_config.TeamSession.router_judge_model_opt () with
  | Some _ as explicit -> explicit
  | None -> inferred_lead_model ()

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
        |> Option.value ~default:"model_judge"
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

let model_judge_routing ~spawn_prompt ~spawn_role ~worker_class =
  match router_judge_model () with
  | None -> None
  | Some _judge_model ->
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
      (match
        Oas_worker.run_named ~cascade_name:(Env_config.Model_defaults.routing_cascade ())
          ~system_prompt:"You are a routing judge for a hybrid swarm. Output only JSON."
          ~goal:prompt ~max_turns:1
          ~temperature:0.0 ~max_tokens:220
          ()
      with
      | Ok result -> (
          try
            Yojson.Safe.from_string (Oas_response.text_of_response result.Oas_worker.response)
            |> parse_routing_decision_json
          with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None)
      | Error _ -> None)

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
  if not (is_local_spawn_agent spec.spawn_agent) then
    spec
  else
    let explicit_tier =
      match spec.worker_size with
      | Some size -> Team_session_types.model_tier_of_worker_size size
      | None -> (
          match spec.model_tier with
          | Some tier -> Some tier
          | None -> infer_model_tier_from_model_name spec.spawn_model)
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
             || Option.is_some spec.worker_size
          then
            decision
          else
            (match model_judge_routing ~spawn_prompt:spec.spawn_prompt
                     ~spawn_role:spec.spawn_role ~worker_class:spec.worker_class with
            | Some model -> model
            | None ->
                {
                  decision with
                  model_tier = Team_session_types.Tier_35b;
                  risk_level = Team_session_types.Risk_high;
                  reason = decision.reason ^ "; fallback:uncertain->35b";
                  escalated = true;
                })
      | None -> (
          match model_judge_routing ~spawn_prompt:spec.spawn_prompt
                   ~spawn_role:spec.spawn_role ~worker_class:spec.worker_class with
          | Some model -> model
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
    let worker_size =
      match spec.worker_size with
      | Some _ as explicit -> explicit
      | None -> Team_session_types.worker_size_of_model_tier model_tier
    in
    {
      spec with
      spawn_agent = normalize_spawn_agent spec.spawn_agent;
      spawn_model;
      model_tier = Some model_tier;
      worker_size;
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
          match spec.worker_size with
          | Some worker_size ->
              Team_session_types.model_tier_of_worker_size worker_size
          | None -> (
              match (spec.model_tier_explicit, spec.model_tier) with
              | true, Some explicit -> Some explicit
              | _ -> Some (controller_target_tier_of_spec ~control_domain spec))
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
