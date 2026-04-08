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
  if normalized = "" then begin
    Log.Spawn.debug "normalize_spawn_agent: empty agent_name → fallback \"default\"";
    "default"
  end else normalized

let is_local_spawn_agent agent_name =
  match normalize_spawn_agent agent_name with
  | "default" -> true
  | "llama" -> true
  | _ -> false

let legacy_spawn_fields = [ "spawn_agent"; "spawn_model" ]

let find_present_json_key keys json =
  List.find_opt (fun key -> Yojson.Safe.Util.member key json <> `Null) keys

let legacy_spawn_field_error ?batch_index field =
  match batch_index with
  | Some index ->
      Printf.sprintf
        "spawn_batch[%d].%s is no longer supported in masc_team_session_step; \
         use spawn_prompt, spawn_role, and worker_class"
        index field
  | None ->
      Printf.sprintf
        "%s is no longer supported in masc_team_session_step; use spawn_prompt, \
         spawn_role, and worker_class"
        field

type routing_decision = {
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
  parent_actor : string option;
  capsule_mode : Team_session_types.capsule_mode option;
  runtime_pool : string option;
  lane_id : string option;
  control_domain : Team_session_types.control_domain option;
  supervisor_actor : string option;
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

let effective_execution_scope_of_spec spec =
  Some
    (Team_session_types.effective_execution_scope
       ~worker_class:spec.worker_class spec.execution_scope)

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

let normalized_spawn_text ~spawn_prompt ~spawn_role =
  String.concat "\n"
    ([ spawn_prompt ]
    @
    match spawn_role with
    | Some role -> [ role ]
    | None -> [])
  |> String.lowercase_ascii

(** {1 Heuristic Keyword Classification}

    WARNING: Non-deterministic boundary.
    These keyword lists map free-text prompts to task profiles via substring
    matching. The same semantic intent expressed with different words can
    produce different classifications. This is an inherent limitation of
    keyword heuristics — RFC-0001 Phase 1 will wrap results in [Uncertain.t].

    Until then, all keyword-based decisions carry implicit confidence ~0.78
    and should be treated as advisory, not authoritative. *)

(** Profile-to-keyword mapping. Each group associates a task profile with
    keywords that suggest it. Order matters: first match wins when multiple
    profiles match (see [keyword_matches]). *)
let profile_keyword_groups : (Team_session_types.task_profile * string list) list =
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

let keyword_matches text =
  List.filter_map
    (fun (profile, keywords) ->
      if contains_any_ci text keywords then Some profile else None)
    profile_keyword_groups

(** Keywords that escalate risk to [Risk_high] regardless of base profile risk.
    Same heuristic caveat as [profile_keyword_groups] above. *)
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
  if contains_any_ci text high_risk_keywords then begin
    let escalated = min_risk base Team_session_types.Risk_high in
    Log.Spawn.debug "classify_risk: heuristic escalation base=%s → %s (keyword match in prompt)"
      (Team_session_types.risk_level_to_string base)
      (Team_session_types.risk_level_to_string escalated);
    escalated
  end else base

let heuristic_routing ~spawn_prompt ~spawn_role ~worker_class ~task_profile
    ~risk_level ~routing_confidence ~routing_reason =
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
  match (task_profile, risk_level) with
  | Some task_profile, Some risk_level ->
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
          "Classify the worker task for a swarm router.\n\
           Return strict JSON only with keys: task_profile, risk_level, confidence, reason, escalate_if.\n\
           task_profile must be one of [\"extract\",\"normalize\",\"summarize\",\"verify\",\"decide\",\"synthesize\"].\n\
           risk_level must be one of [\"low\",\"medium\",\"high\"].\n\
           worker_class=%s\n\
           spawn_role=%s\n\
           worker_prompt=%S\n"
          worker_class_text role_text spawn_prompt
      in
      (match
        Masc_oas_bridge.run_safe ~timeout_s:180.0 (fun () ->
          Oas_worker.run_named ~cascade_name:(Env_config.Model_defaults.routing_cascade ())
            ~system_prompt:"You are a routing judge for a hybrid swarm. Output only JSON."
            ~goal:prompt ~max_turns:1
            ~temperature:Oas_worker_cascade.deterministic_temperature ~max_tokens:220
            ()
        )
      with
      | Ok result -> (
          try
            Yojson.Safe.from_string (Oas_response.text_of_response result.Oas_worker.response)
            |> parse_routing_decision_json
          with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None)
      | Error _ -> None)

let routing_summary_line (decision : routing_decision) =
  Printf.sprintf
    "[routing] profile=%s risk=%s confidence=%s reason=%s judge=%b escalated=%b"
    (Team_session_types.task_profile_to_string decision.task_profile)
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

(* Explicit spawn_model takes precedence; otherwise default to the
   inferred lead model from environment/runtime configuration. *)
let finalize_routing_decision ~spawn_model ~(decision : routing_decision) =
  let resolved_model =
    match trim_opt spawn_model with
    | Some _ as explicit -> explicit
    | None -> inferred_lead_model ()
  in
  (resolved_model, decision.escalated, decision.reason)

let resolve_routing_for_spec (spec : spawn_spec) =
  if not (is_local_spawn_agent spec.spawn_agent) then
    spec
  else
    let heuristic =
      heuristic_routing ~spawn_prompt:spec.spawn_prompt ~spawn_role:spec.spawn_role
        ~worker_class:spec.worker_class ~task_profile:spec.task_profile
        ~risk_level:spec.risk_level
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
          then
            decision
          else
            (match model_judge_routing ~spawn_prompt:spec.spawn_prompt
                     ~spawn_role:spec.spawn_role ~worker_class:spec.worker_class with
            | Some judge_decision -> judge_decision
            | None ->
                {
                  decision with
                  risk_level = Team_session_types.Risk_high;
                  reason = decision.reason ^ "; fallback:uncertain";
                  escalated = true;
                })
      | None -> (
          match model_judge_routing ~spawn_prompt:spec.spawn_prompt
                   ~spawn_role:spec.spawn_role ~worker_class:spec.worker_class with
          | Some judge_decision -> judge_decision
          | None ->
              {
                task_profile =
                  Option.value ~default:Team_session_types.Profile_synthesize
                    spec.task_profile;
                risk_level =
                  Option.value ~default:Team_session_types.Risk_high spec.risk_level;
                confidence = Some 0.0;
                reason = Option.value ~default:"fallback:ambiguous" spec.routing_reason;
                judge_used = false;
                escalate_if =
                  [ "worker failure"; "schema mismatch"; "context pressure"; "evidence conflict" ];
                escalated = true;
              })
    in
    let spawn_model, routing_escalated, routing_reason =
      finalize_routing_decision ~spawn_model:spec.spawn_model ~decision
    in
    let routing_confidence =
      match spec.routing_confidence with
      | Some _ as explicit -> explicit
      | None -> decision.confidence
    in
    let routing_note =
      routing_summary_line { decision with reason = routing_reason; escalated = routing_escalated }
    in
    {
      spec with
      spawn_agent = normalize_spawn_agent spec.spawn_agent;
      spawn_model;
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
        let spawn_model =
          match (spec.spawn_model_explicit, trim_opt spec.spawn_model) with
          | true, (Some _ as explicit) -> explicit
          | _ -> inferred_lead_model ()
        in
        {
          spec with
          spawn_model;
          lane_id;
          control_domain;
          supervisor_actor;
        })
      specs
