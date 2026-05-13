(** Cascade_error_classify — masc_internal_error type, error conversion, codex CLI preflight.

    Extracted from oas_worker_named.ml (God file decomposition).
    Defines the [masc_internal_error] variant type, JSON serialization,
    SDK error conversion, error classification, and codex CLI prompt
    preflight checks.

    @since God file decomposition *)

open Result.Syntax

type cascade_name = Keeper_cascade_profile.runtime_name

let cascade_name_of_string raw = Keeper_cascade_profile.Runtime_name raw
let cascade_name_to_string = Keeper_cascade_profile.runtime_name_to_string

type provider_rejection = {
  reason : string;
}

type masc_internal_error =
  | Cascade_exhausted of {
      cascade_name : cascade_name;
      reason : Keeper_types.cascade_exhaustion_reason;
    }
  | Resumable_cli_session of {
      cascade_name : cascade_name;
      detail : string;
      exit_code : int option;
    }
  | No_tool_capable_provider of {
      cascade_name : cascade_name;
      configured_labels : string list;
      required_tool_names : string list;
      provider_rejections : provider_rejection list;
    }
  | Accept_rejected of {
      scope : string;
      model : string option;
      reason : string;
    }
  | Admission_queue_timeout of {
      keeper_name : string;
      cascade_name : cascade_name;
      wait_sec : float;
    }
  | Admission_queue_rejected of {
      keeper_name : string;
      reason : string;
    }
  | Turn_timeout of {
      elapsed_sec : float;
    }
  | Oas_timeout_budget of {
      budget_sec : float;
      keeper_turn_timeout_sec : float;
      estimated_input_tokens : int;
      source : string;
      remaining_turn_budget_sec : float option;
      min_required_sec : float;
      phase : string;
    }
  | Ambiguous_post_commit of {
      is_timeout : bool;
      tools : string list;
      original_error : string;
    }

let masc_internal_error_prefix = "[masc_oas_error] "

let string_list_json values =
  `List (List.map (fun value -> `String value) values)

let string_list_of_assoc key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`List values) ->
          values
          |> List.filter_map (function
               | `String value -> Some value
               | _ -> None)
      | _ -> [])
  | _ -> []

let provider_rejection_of_json = function
  | `Assoc fields ->
      let field name =
        match List.assoc_opt name fields with
        | Some (`String value) -> Some value
        | _ -> None
      in
      (match field "reason" with
       | Some reason ->
           Some { reason }
       | _ -> None)
  | _ -> None

let provider_rejections_of_assoc key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`List values) -> List.filter_map provider_rejection_of_json values
      | _ -> [])
  | _ -> []

let provider_rejection_reasons_of_assoc key json =
  string_list_of_assoc key json
  |> List.map (fun reason -> { reason })

let provider_rejection_reasons rejections =
  rejections
  |> List.map (fun r -> String.trim r.reason)
  |> List.filter (fun reason -> reason <> "")
  |> Json_util.dedupe_keep_order

let string_opt_of_assoc key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) -> Some value
      | _ -> None)
  | _ -> None

let masc_internal_error_to_json = function
  | Cascade_exhausted { cascade_name; reason } ->
    let cascade_name = cascade_name_to_string cascade_name in
    `Assoc
      [
        ("kind", `String "cascade_exhausted");
        ("cascade_name", `String cascade_name);
        ("reason", Keeper_types.cascade_exhaustion_reason_to_json reason);
      ]
  | Resumable_cli_session { cascade_name; detail; exit_code } ->
    let cascade_name = cascade_name_to_string cascade_name in
    `Assoc
      [
        ("kind", `String "resumable_cli_session");
        ("cascade_name", `String cascade_name);
        ("detail", `String detail);
        ("exit_code", Json_util.int_opt_to_json exit_code);
      ]
  | No_tool_capable_provider
      {
        cascade_name;
        configured_labels;
        required_tool_names;
        provider_rejections;
      } ->
    let cascade_name = cascade_name_to_string cascade_name in
    let rejection_reasons = provider_rejection_reasons provider_rejections in
    `Assoc
      [
        ("kind", `String "no_tool_capable_provider");
        ("cascade_name", `String cascade_name);
        ("configured_candidate_count", `Int (List.length configured_labels));
        ("required_tool_names", string_list_json required_tool_names);
        ("rejected_candidate_count", `Int (List.length provider_rejections));
        ("rejection_reasons", string_list_json rejection_reasons);
      ]
  | Accept_rejected { scope; model; reason } ->
    `Assoc
      [
        ("kind", `String "accept_rejected");
        ("scope", `String scope);
        ("model", Json_util.string_opt_to_json model);
        ("reason", `String reason);
      ]
  | Admission_queue_timeout { keeper_name; cascade_name; wait_sec } ->
    let cascade_name = cascade_name_to_string cascade_name in
    `Assoc
      [
        ("kind", `String "admission_queue_timeout");
        ("keeper_name", `String keeper_name);
        ("cascade_name", `String cascade_name);
        ("wait_sec", `Float wait_sec);
      ]
  | Admission_queue_rejected { keeper_name; reason } ->
    `Assoc
      [
        ("kind", `String "admission_queue_rejected");
        ("keeper_name", `String keeper_name);
        ("reason", `String reason);
      ]
  | Turn_timeout { elapsed_sec } ->
    `Assoc
      [
        ("kind", `String "turn_timeout");
        ("elapsed_sec", `Float elapsed_sec);
      ]
  | Oas_timeout_budget
      {
        budget_sec;
        keeper_turn_timeout_sec;
        estimated_input_tokens;
        source;
        remaining_turn_budget_sec;
        min_required_sec;
        phase;
      } ->
    `Assoc
      [
        ("kind", `String "oas_timeout_budget");
        ("budget_sec", `Float budget_sec);
        ("keeper_turn_timeout_sec", `Float keeper_turn_timeout_sec);
        ("estimated_input_tokens", `Int estimated_input_tokens);
        ("source", `String source);
        ( "remaining_turn_budget_sec",
          Json_util.float_opt_to_json remaining_turn_budget_sec );
        ("min_required_sec", `Float min_required_sec);
        ("phase", `String phase);
      ]
  | Ambiguous_post_commit { is_timeout; tools; original_error } ->
    `Assoc
      [
        ("kind", `String "ambiguous_post_commit");
        ("is_timeout", `Bool is_timeout);
        ("tools", string_list_json tools);
        ("original_error", `String original_error);
      ]

let summarize_list ?(empty = "none") values =
  match values with
  | [] -> empty
  | _ -> String.concat ", " values

let summarize_provider_rejections rejections =
  match provider_rejection_reasons rejections with
  | [] -> "none"
  | reasons -> String.concat "; " reasons

let summary_of_masc_internal_error = function
  | No_tool_capable_provider
      {
        cascade_name;
        configured_labels;
        required_tool_names;
        provider_rejections;
      } ->
      let cascade_name = cascade_name_to_string cascade_name in
      Some
        (Printf.sprintf
           "No tool-capable provider for cascade %s; required_tools=[%s]; rejected_candidate_count=%d; rejection_reasons=[%s]; configured_candidate_count=%d"
           cascade_name
           (summarize_list required_tool_names)
           (List.length provider_rejections)
           (summarize_provider_rejections provider_rejections)
           (List.length configured_labels))
  | Oas_timeout_budget
      {
        budget_sec;
        keeper_turn_timeout_sec;
        estimated_input_tokens;
        source;
        remaining_turn_budget_sec;
        min_required_sec;
        phase;
      } ->
      let remaining =
        match remaining_turn_budget_sec with
        | Some value -> Printf.sprintf "%.1fs" value
        | None -> "unknown"
      in
      Some
        (Printf.sprintf
           "OAS timeout budget exhausted; phase=%s; source=%s; budget=%.1fs; remaining=%s; min_required=%.1fs; estimated_input_tokens=%d; keeper_turn_timeout=%.1fs"
           phase source budget_sec remaining min_required_sec
           estimated_input_tokens keeper_turn_timeout_sec)
  (* Variants without a custom long-form summary: callers fall back to
     [kind_of_masc_internal_error] / the JSON payload.  Enumerated
     explicitly so adding a new [masc_internal_error] variant forces
     a decision on whether it deserves a long-form summary string. *)
  | Cascade_exhausted _
  | Resumable_cli_session _
  | Accept_rejected _
  | Admission_queue_timeout _
  | Admission_queue_rejected _
  | Turn_timeout _
  | Ambiguous_post_commit _ -> None

(* #9933: classify emitted [masc_oas_error] payloads by kind so
   dashboards and Grafana alerts can watch the fleet-wide rate per
   error class (cascade_exhausted vs oas_timeout_budget vs
   ambiguous_post_commit, etc.) rather than reading the free-form
   BDI blocker string.  125 [oas_timeout_budget] events accumulated
   across 9 keepers in 24h without an aggregate signal — this
   counter is the per-kind surface.

   Emit point is this constructor so all 14 call sites of
   [sdk_error_of_masc_internal_error] are covered automatically,
   without changing their signatures or threading [keeper_name]
   through callers that do not have it readily.  A follow-up PR
   can add a [keeper] label once every construction site has the
   name in scope. *)
let masc_oas_error_total_metric = "masc_oas_error_total"

let cross_cascade_fallback_metric = "masc_cross_cascade_fallback_total"

let () =
  Prometheus.register_counter
    ~name:masc_oas_error_total_metric
    ~help:
      "Total MASC-internal errors emitted as Agent_sdk.Error.Internal \
       payloads, classified by structured error kind. Labels: \
       kind (cascade_exhausted | resumable_cli_session | \
       no_tool_capable_provider | accept_rejected | \
       admission_queue_timeout | admission_queue_rejected | \
       turn_timeout | oas_timeout_budget | ambiguous_post_commit), \
       cascade_name (originating cascade or \"unknown\" for \
       cascade-less variants)."
    ();
  Prometheus.register_counter
    ~name:cross_cascade_fallback_metric
    ~help:
      "Total times a keeper turn could not find a tool-capable \
       provider in its own cascade and was driven by an upper layer \
       to a different cascade. Labels: from_cascade (cascade the \
       keeper was configured for), to_cascade (cascade that \
       supplied the working candidate)."
    ()

let kind_of_masc_internal_error = function
  | Cascade_exhausted _ -> "cascade_exhausted"
  | Resumable_cli_session _ -> "resumable_cli_session"
  | No_tool_capable_provider _ -> "no_tool_capable_provider"
  | Accept_rejected _ -> "accept_rejected"
  | Admission_queue_timeout _ -> "admission_queue_timeout"
  | Admission_queue_rejected _ -> "admission_queue_rejected"
  | Turn_timeout _ -> "turn_timeout"
  | Oas_timeout_budget _ -> "oas_timeout_budget"
  | Ambiguous_post_commit _ -> "ambiguous_post_commit"

(** #10285: which cascade emitted this error.

    Pre-fix [masc_oas_error_total] only carried a [kind] label, so the
    97 [resumable_cli_session] events observed in 10000 logs flattened
    into a single counter even though they were unevenly distributed
    across 5 cascades (governance_judge=32, kimi_cli_keeper=8,
    keeper_unified=6, tool_use_strict=5, local_with_kimi_coding_with_glm=1).
    Operators couldn't tell which cascade was the dominant offender —
    a critical signal because cascade demotion / model-order edits
    are per-cascade actions, not global ones.

    Variants that carry [cascade_name] in their payload return it
    directly.  The five variants that don't ([Accept_rejected],
    [Admission_queue_rejected], [Turn_timeout], [Oas_timeout_budget],
    [Ambiguous_post_commit]) emit the ["unknown"] sentinel — they
    fire outside cascade context so a synthetic value would be
    misleading.  An empty-string [cascade_name] in a cascade-aware
    variant also collapses to ["unknown"] so the label always carries
    a non-empty value (Prometheus exporters reject empty labels in
    some configurations and Grafana group-bys lose the row). *)
let cascade_name_of_masc_internal_error = function
  | Cascade_exhausted { cascade_name; _ }
  | Resumable_cli_session { cascade_name; _ }
  | No_tool_capable_provider { cascade_name; _ }
  | Admission_queue_timeout { cascade_name; _ } ->
      let cascade_name = cascade_name_to_string cascade_name in
      if String.equal (String.trim cascade_name) "" then "unknown"
      else cascade_name
  | Accept_rejected _
  | Admission_queue_rejected _
  | Turn_timeout _
  | Oas_timeout_budget _
  | Ambiguous_post_commit _ -> "unknown"

let sdk_error_of_masc_internal_error err =
  Prometheus.inc_counter masc_oas_error_total_metric
    ~labels:
      [
        ("kind", kind_of_masc_internal_error err);
        ("cascade_name", cascade_name_of_masc_internal_error err);
      ]
    ();
  Agent_sdk.Error.Internal
    (masc_internal_error_prefix ^ Yojson.Safe.to_string (masc_internal_error_to_json err))

let admission_wait_timeout_error
    ~(keeper_name : string)
    ~(cascade_name : cascade_name)
    ~(priority : Llm_provider.Request_priority.t)
    (wait_ms : int) =
  let wait_sec = float_of_int wait_ms /. 1000.0 in
  let cascade_name_string = cascade_name_to_string cascade_name in
  let msg =
    Printf.sprintf
      "Admission queue wait timeout after %.1fs (wait_ms=%d, keeper=%s, cascade=%s, priority=%s)"
      wait_sec wait_ms keeper_name cascade_name_string
      (Llm_provider.Request_priority.to_string priority)
  in
  Log.Misc.warn "%s" msg;
  Error
    (sdk_error_of_masc_internal_error
       (Admission_queue_timeout { keeper_name; cascade_name; wait_sec }))

let parse_masc_internal_error_json (json : Yojson.Safe.t) :
    masc_internal_error option =
  let int_opt_of_assoc key = function
    | `Assoc fields -> (
        match List.assoc_opt key fields with
        | Some (`Int value) -> Some value
        | Some (`Intlit value) -> int_of_string_opt value
        | _ -> None)
    | _ -> None
  in
  let float_opt_of_assoc key = function
    | `Assoc fields -> (
        match List.assoc_opt key fields with
        | Some (`Float value) -> Some value
        | Some (`Int value) -> Some (float_of_int value)
        | Some (`Intlit value) ->
            Option.map float_of_int (int_of_string_opt value)
        | _ -> None)
    | _ -> None
  in
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "kind" fields with
      | Some (`String "cascade_exhausted") -> (
          match string_opt_of_assoc "cascade_name" json with
          | Some cascade_name ->
            let reason =
              match List.assoc_opt "reason" (match json with `Assoc fields -> fields | _ -> []) with
              | Some json_val ->
                  (match Keeper_types.cascade_exhaustion_reason_of_json json_val with
                   | Some r -> r
                   | None -> Other_detail "unknown_cascade_reason")
              | None -> Other_detail "missing_reason_field"
            in
            Some
              (Cascade_exhausted
                 {
                   cascade_name = cascade_name_of_string cascade_name;
                   reason;
                 })
          | None -> None)
      | Some (`String "resumable_cli_session") -> (
          match string_opt_of_assoc "cascade_name" json, string_opt_of_assoc "detail" json with
          | Some cascade_name, Some detail ->
            Some
              (Resumable_cli_session
                 {
                   cascade_name = cascade_name_of_string cascade_name;
                   detail;
                   exit_code = int_opt_of_assoc "exit_code" json;
                 })
          | _ -> None)
      | Some (`String "no_tool_capable_provider") -> (
          match string_opt_of_assoc "cascade_name" json with
          | Some cascade_name ->
            Some
              (No_tool_capable_provider
                 {
                   cascade_name = cascade_name_of_string cascade_name;
                   configured_labels =
                     string_list_of_assoc "configured_labels" json;
                   required_tool_names =
                     string_list_of_assoc "required_tool_names" json;
                   provider_rejections =
                     (match
                        provider_rejections_of_assoc "provider_rejections" json
                      with
                      | [] ->
                          provider_rejection_reasons_of_assoc
                            "rejection_reasons" json
                      | provider_rejections -> provider_rejections);
                 })
          | None -> None)
      | Some (`String "accept_rejected") -> (
          match string_opt_of_assoc "scope" json, string_opt_of_assoc "reason" json with
          | Some scope, Some reason ->
            Some
              (Accept_rejected
                 {
                   scope;
                   model = string_opt_of_assoc "model" json;
                   reason;
                 })
          | _ -> None)
      | Some (`String "admission_queue_timeout") -> (
          match string_opt_of_assoc "keeper_name" json,
                string_opt_of_assoc "cascade_name" json
          with
          | Some keeper_name, Some cascade_name ->
            let wait_sec =
              match json with
              | `Assoc fields -> (
                  match List.assoc_opt "wait_sec" fields with
                  | Some (`Float v) -> v
                  | _ -> 0.0)
              | _ -> 0.0
            in
            Some
              (Admission_queue_timeout
                 {
                   keeper_name;
                   cascade_name = cascade_name_of_string cascade_name;
                   wait_sec;
                 })
          | _ -> None)
      | Some (`String "admission_queue_rejected") -> (
          match string_opt_of_assoc "keeper_name" json,
                string_opt_of_assoc "reason" json
          with
          | Some keeper_name, Some reason ->
            Some (Admission_queue_rejected { keeper_name; reason })
          | _ -> None)
      | Some (`String "turn_timeout") -> (
          match json with
          | `Assoc fields -> (
              match List.assoc_opt "elapsed_sec" fields with
              | Some (`Float v) ->
                Some (Turn_timeout { elapsed_sec = v })
              | _ -> None)
          | _ -> None)
      | Some (`String "oas_timeout_budget") -> (
          match json with
          | `Assoc fields -> (
              match
                List.assoc_opt "budget_sec" fields,
                List.assoc_opt "keeper_turn_timeout_sec" fields,
                List.assoc_opt "estimated_input_tokens" fields,
                List.assoc_opt "source" fields
              with
              | Some (`Float budget_sec),
                Some (`Float keeper_turn_timeout_sec),
                Some (`Int estimated_input_tokens),
                Some (`String source) ->
                  Some
                    (Oas_timeout_budget
                       {
                         budget_sec;
                         keeper_turn_timeout_sec;
                         estimated_input_tokens;
                         source;
                         remaining_turn_budget_sec =
                           float_opt_of_assoc
                             "remaining_turn_budget_sec" json;
                         min_required_sec =
                           Option.value ~default:0.0
                             (float_opt_of_assoc "min_required_sec" json);
                         phase =
                           Option.value ~default:"unknown"
                             (string_opt_of_assoc "phase" json);
                       })
              | _ -> None)
          | _ -> None)
      | Some (`String "ambiguous_post_commit") -> (
          match string_opt_of_assoc "original_error" json with
          | Some original_error ->
            let is_timeout =
              match json with
              | `Assoc fields -> (
                  match List.assoc_opt "is_timeout" fields with
                  | Some (`Bool b) -> b
                  | _ -> false)
              | _ -> false
            in
            let tools =
              match json with
              | `Assoc fields -> (
                  match List.assoc_opt "tools" fields with
                  | Some (`List values) ->
                    values
                    |> List.filter_map (function
                         | `String value -> Some value
                         | _ -> None)
                  | _ -> [])
              | _ -> []
            in
            Some (Ambiguous_post_commit { is_timeout; tools; original_error })
          | _ -> None)
      | _ -> None)
  | _ -> None

let classify_masc_internal_error_of_string (raw : string) :
    masc_internal_error option =
  let prefix = masc_internal_error_prefix in
  let prefix_len = String.length prefix in
  let raw_len = String.length raw in
  let rec find_prefix start =
    if start + prefix_len > raw_len then None
    else if String.sub raw start prefix_len = prefix then Some start
    else find_prefix (start + 1)
  in
  match find_prefix 0 with
  | None -> None
  | Some prefix_start ->
    let payload_start = prefix_start + prefix_len in
    let payload = String.sub raw payload_start (raw_len - payload_start) in
    (try parse_masc_internal_error_json (Yojson.Safe.from_string payload)
     with Yojson.Json_error _ -> None)

let classify_masc_internal_error (err : Agent_sdk.Error.sdk_error) :
    masc_internal_error option =
  match err with
  | Agent_sdk.Error.Internal msg when String.starts_with ~prefix:masc_internal_error_prefix msg ->
    (try parse_masc_internal_error_json (Yojson.Safe.from_string
         (String.sub msg
            (String.length masc_internal_error_prefix)
            (String.length msg - String.length masc_internal_error_prefix)))
     with Yojson.Json_error _ -> None)
  | _ -> None

let config_for_label
    ~(name : string)
    ~(model_label : string)
    ~(system_prompt : string)
    ~(tools : Agent_sdk.Tool.t list)
    ~(max_turns : int)
    ~(max_tokens : int)
    ?(max_input_tokens : int option)
    ?(max_cost_usd : float option)
    ~(temperature : float)
    ?(max_idle_turns = 3)
    ?stream_idle_timeout_s
    ?guardrails
    ?hooks
    ?context_reducer
    ?memory
    ?tool_retry_policy
    ?enable_thinking
    ?compact_ratio
    ?contract
    ?approval
    ~(description : string option)
    () : (Cascade_runner.config, Agent_sdk.Error.sdk_error) result =
  let* provider =
    Cascade_runner.resolve_provider_config_of_label model_label
    |> Result.map_error Cascade_runner.label_resolution_error_to_sdk_error
  in
  Ok
    {
      (Cascade_runner.default_config ~name ~provider_cfg:provider
         ~system_prompt ~tools)
      with
      max_turns;
      max_tokens;
      max_input_tokens;
      max_cost_usd;
      temperature;
      max_idle_turns;
      stream_idle_timeout_s;
      guardrails;
      hooks;
      context_reducer;
      memory;
      tool_retry_policy;
      enable_thinking;
      contract;
      description;
      compact_ratio;
      approval;
    }

let codex_cli_prompt_arg_limit_bytes = 512 * 1024
let codex_cli_min_retry_tokens = 4_096

type codex_cli_prompt_preflight = {
  prompt_bytes : int;
  prompt_tokens : int;
  context_window_tokens : int;
  retry_limit_tokens : int;
  hits_argv_limit : bool;
  hits_context_window : bool;
}

let codex_cli_prompt_bytes_to_token_limit ~prompt_bytes ~prompt_tokens =
  if prompt_bytes <= 0 then
    prompt_tokens
  else
    Int64.(
      div
        (mul (of_int (Stdlib.max 1 prompt_tokens))
           (of_int codex_cli_prompt_arg_limit_bytes))
        (of_int prompt_bytes)
      |> to_int)

let codex_cli_prompt_preflight ~(config : Cascade_runner.config) ~(goal : string)
    : codex_cli_prompt_preflight option =
  (* RFC-0058 §2.4 — dispatch by adapter capability flag
     ([tool_policy.argv_prompt_preflight]), never by provider variant.
     argv/context-window preflight currently applies only to the
     [codex exec] subprocess transport (single-argv-vector prompt).
     Adding a new vendor that needs the same preflight is now a TOML/
     adapter registry change, not a code change here. *)
  let requires_preflight =
    match Provider_adapter.adapter_of_provider_config config.provider_cfg with
    | Some adapter -> adapter.tool_policy.argv_prompt_preflight
    | None -> false
  in
  if not requires_preflight then None
  else
    let messages =
      Agent_sdk.Agent_turn.prepare_messages
        ~messages:(config.initial_messages @ [ Agent_sdk.Types.user_msg goal ])
        ~context_reducer:config.context_reducer
        ~tiered_memory:None
        ~turn_params:Agent_sdk.Hooks.default_turn_params
        ()
    in
    let req_config =
      match String.trim config.system_prompt with
      | "" -> config.provider_cfg
      | _ ->
        { config.provider_cfg with
          system_prompt = Some config.system_prompt;
        }
    in
    let system_prompt =
      Llm_provider.Cli_common_prompt.system_prompt_of ~req_config messages
    in
    let prompt =
      messages
      |> Llm_provider.Cli_common_prompt.non_system_messages
      |> Llm_provider.Cli_common_prompt.prompt_of_messages
      |> fun prompt ->
      Llm_provider.Cli_common_prompt.prompt_with_system_prompt
        ~prompt ~system_prompt
    in
    let prompt_bytes = String.length prompt in
    let prompt_tokens =
      max 1 (Agent_sdk.Context_reducer.estimate_char_tokens prompt)
    in
    let context_window_tokens =
      Agent_sdk.Provider.resolve_max_context_tokens
        ~fallback:Cascade_runtime.fallback_context_window
        (Some config.provider)
    in
    let hits_argv_limit = prompt_bytes > codex_cli_prompt_arg_limit_bytes in
    let hits_context_window = prompt_tokens > context_window_tokens in
    if not hits_argv_limit && not hits_context_window then
      None
    else
      let retry_limit_tokens =
        let byte_limit =
          codex_cli_prompt_bytes_to_token_limit ~prompt_bytes ~prompt_tokens
        in
        let limit =
          if hits_argv_limit then byte_limit else prompt_tokens
          |> fun limit ->
          if hits_context_window then min context_window_tokens limit else limit
        in
        max codex_cli_min_retry_tokens (min prompt_tokens limit)
      in
      Some
        {
          prompt_bytes;
          prompt_tokens;
          context_window_tokens;
          retry_limit_tokens;
          hits_argv_limit;
          hits_context_window;
        }

let codex_cli_preflight_error ~(scope : string)
    ~(provider_cfg : Llm_provider.Provider_config.t)
    (preflight : codex_cli_prompt_preflight) =
  Log.Misc.warn
    "codex_cli prompt preflight rejected spawn (scope=%s, model=%s, prompt_bytes=%d, prompt_tokens=%d, retry_limit=%d, context_window=%d, argv_limit=%b, context_limit=%b)"
    scope provider_cfg.model_id preflight.prompt_bytes
    preflight.prompt_tokens preflight.retry_limit_tokens
    preflight.context_window_tokens preflight.hits_argv_limit
    preflight.hits_context_window;
  Agent_sdk.Error.Agent
    (Agent_sdk.Error.TokenBudgetExceeded
       {
         kind = "Input";
         used = preflight.prompt_tokens;
         limit = preflight.retry_limit_tokens;
       })

let with_codex_cli_preflight ~(scope : string) ~(config : Cascade_runner.config)
    ~(goal : string) (run : unit -> ('a, Agent_sdk.Error.sdk_error) result)
    : ('a, Agent_sdk.Error.sdk_error) result =
  match codex_cli_prompt_preflight ~config ~goal with
  | Some preflight ->
    Error (codex_cli_preflight_error ~scope ~provider_cfg:config.provider_cfg preflight)
  | None -> run ()
