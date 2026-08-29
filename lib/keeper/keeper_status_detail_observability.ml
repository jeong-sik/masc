(** Model observability helpers for keeper status detail. *)

let nonempty_trimmed raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None else Some trimmed

let assoc_string_opt key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> nonempty_trimmed value
  | _ -> None

let latest_metrics_json ~metrics_store =
  let lines = Dated_jsonl.read_recent_lines metrics_store 8 in
  let parsed, _ =
    Fs_compat.parse_jsonl_lines ~source:"keeper_metrics_latest" lines
  in
  match
    List.rev parsed
    |> List.find_opt (fun json ->
      match
        Keeper_metrics_record.kind_of_json json,
        Json_util.assoc_member_opt "runtime" json
      with
      | Some Keeper_metrics_record.Turn, Some (`Assoc _) -> true
      | Some Keeper_metrics_record.Turn, _
      | Some Keeper_metrics_record.Heartbeat, _
      | None, _ -> false)
  with
  | Some json -> Some json
  | None -> None

let first_some candidates =
  List.find_map Fun.id candidates

let selected_model_of_runtime_trust runtime_trust =
  let top_level =
    first_some
      [ (Json_util.assoc_string_opt "selected_model" runtime_trust
         |> Option.map (fun model -> model, "runtime_trust.selected_model"))
      ]
  in
  match top_level with
  | Some _ as value -> value
  | None ->
      Option.bind
        (Json_util.assoc_member_opt "execution" runtime_trust)
        (fun execution ->
           Json_util.assoc_string_opt "provider_selected_model" execution
           |> Option.map (fun model ->
             model, "runtime_trust.execution.provider_selected_model"))

let lightweight_runtime_contract_json ~runtime_blocker_class ~selected_model
    ~runtime_verified =
  let source =
    match selected_model with
    | Some (_, source) -> source
    | None -> "none"
  in
  let proof_note =
    match runtime_verified, selected_model with
    | true, Some _ ->
        "Scoped runtime observation is present; selected model label remains \
         AGENT_CORE-owned."
    | false, Some _ ->
        "Selected model label is available, but no scoped runtime observation \
         verified it. Concrete provider identity remains AGENT_CORE-owned."
    | true, None ->
        "Scoped runtime observation is present. Provider/model identity is owned \
         by AGENT_CORE."
    | false, None ->
        "Provider/model identity is owned by AGENT_CORE. MASC status exposes only \
         runtime signals."
  in
  `Assoc
    [ "source", `String source
    ; "verified", `Bool runtime_verified
    ; "provider_reachable", `Null
    ; "actual_model_id", `Null
    ; "actual_slots", `Null
    ; "actual_ctx", `Null
    ; "chat_completion_compatible", `Null
    ; "runtime_blocker", Json_util.string_opt_to_json runtime_blocker_class
    ; "note", `String proof_note
    ]

let attempt_summary_json ?selected_model latest_runtime =
  match latest_runtime with
  | None ->
      let summary =
        match selected_model with
        | Some (_, source) ->
            Printf.sprintf "Runtime selected model observed from %s." source
        | None -> "No recent runtime observation for current keeper config."
      in
      `Assoc
        [ ( "summary", `String summary )
        ; "attempts_observed", `Null
        ]
  | Some runtime ->
      let attempts_observed =
        match Json_util.assoc_member_opt "attempts" runtime with
        | Some (`List attempts) -> List.length attempts
        | _ -> 0
      in
      let summary =
        match selected_model with
        | Some (_, source) ->
            Printf.sprintf
              "%d attempt(s); selected model observed from %s."
              attempts_observed
              source
        | None -> "Runtime observation is present but incomplete."
      in
      `Assoc
        [ "summary", `String summary
        ; "attempts_observed", `Int attempts_observed
        ]

type runtime_observation_scope =
  | Runtime_observation_absent
  | Runtime_observation_matched
  | Runtime_observation_missing_runtime_id
  | Runtime_observation_mismatched

let runtime_observation_scope_to_string = function
  | Runtime_observation_absent -> "absent"
  | Runtime_observation_matched -> "matched"
  | Runtime_observation_missing_runtime_id -> "missing_runtime_id"
  | Runtime_observation_mismatched -> "mismatched_runtime_id"

let latest_runtime_for_current_config ~current_runtime_id latest_metrics =
  let latest_runtime =
    match latest_metrics with
    | Some metrics ->
        (match Json_util.assoc_member_opt "runtime" metrics with
         | Some (`Assoc _ as runtime) -> Some runtime
         | _ -> None)
    | None -> None
  in
  match latest_runtime with
  | None -> None, Runtime_observation_absent
  | Some runtime ->
      let runtime_id_matches =
        let observed_runtime_id = Json_util.assoc_string_opt "runtime_id" runtime in
        match observed_runtime_id with
        | Some observed_name -> String.equal observed_name current_runtime_id
        | None -> false
      in
      if runtime_id_matches then Some runtime, Runtime_observation_matched
      else
        let scope =
          match Json_util.assoc_string_opt "runtime_id" runtime with
          | Some _ -> Runtime_observation_mismatched
          | None -> Runtime_observation_missing_runtime_id
        in
        None, scope

let model_observability_json ~current_runtime_id ~runtime_blocker_fields
    ~runtime_trust latest_metrics =
  let latest_runtime, runtime_observation_scope =
    latest_runtime_for_current_config ~current_runtime_id latest_metrics
  in
  let selected_model = selected_model_of_runtime_trust runtime_trust in
  let runtime_verified = Option.is_some latest_runtime in
  let runtime_blocker_class =
    assoc_string_opt "runtime_blocker_class" runtime_blocker_fields
  in
  let runtime_id =
    Option.value ~default:"" (nonempty_trimmed current_runtime_id)
  in
  `Assoc
    [ ( "runtime_id"
      , if runtime_id = "" then `Null else `String runtime_id )
    ; ( "recent_turn_observation"
      , `Bool runtime_verified )
    ; ( "runtime_observation_scope"
      , `String (runtime_observation_scope_to_string runtime_observation_scope) )
    ; "resolved_candidates", `List []
    ; ( "selected_model"
      , Json_util.string_opt_to_json (Option.map fst selected_model) )
    ; "attempt_summary", attempt_summary_json ?selected_model latest_runtime
    ; ( "runtime_contract"
      , lightweight_runtime_contract_json ~runtime_blocker_class ~selected_model
          ~runtime_verified )
    ]
