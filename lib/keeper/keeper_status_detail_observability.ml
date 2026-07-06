(** Model observability helpers for keeper status detail. *)

let nonempty_trimmed raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None else Some trimmed

let assoc_string_opt key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> nonempty_trimmed value
  | _ -> None

let latest_metrics_json ~metrics_store ~metrics_path ~tail_bytes =
  let lines =
    let dated = Dated_jsonl.read_recent_lines metrics_store 8 in
    if dated <> []
    then dated
    else
      (match
         Keeper_memory.read_file_tail_lines_result metrics_path
           ~max_bytes:tail_bytes
           ~max_lines:8
       with
       | Ok lines -> lines
       | Error exn_class ->
           Keeper_memory.record_memory_recall_read_error
             ~site:"keeper_status_detail_observability" metrics_path exn_class;
           [])
  in
  let parsed, _ =
    Fs_compat.parse_jsonl_lines ~source:"keeper_metrics_latest" lines
  in
  match
    List.rev parsed
    |> List.find_opt (fun json ->
      match Json_util.assoc_member_opt "runtime" json with
      | Some (`Assoc _) -> true
      | _ -> false)
  with
  | Some json -> Some json
  | None ->
      (match List.rev parsed with
       | json :: _ -> Some json
       | [] -> None)

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
         OAS-owned."
    | false, Some _ ->
        "Selected model label is available, but no scoped runtime observation \
         verified it. Concrete provider identity remains OAS-owned."
    | true, None ->
        "Scoped runtime observation is present. Provider/model identity is owned \
         by OAS."
    | false, None ->
        "Provider/model identity is owned by OAS. MASC status exposes only \
         control-plane signals."
  in
  `Assoc
    [ "source", `String source
    ; "verified", `Bool runtime_verified
    ; "provider_scope", `Null
    ; "provider_reachable", `Null
    ; "healthy_runtime_count", `Null
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
        ; "selected_index", `Null
        ; "fallback_hops", `Null
        ; "fallback_applied", `Bool false
        ]
  | Some runtime ->
      let attempts_observed =
        match Json_util.assoc_member_opt "attempts" runtime with
        | Some (`List attempts) -> List.length attempts
        | _ -> 0
      in
      let selected_index =
        match Json_util.assoc_member_opt "selected_index" runtime with
        | Some (`Int value) -> Some value
        | Some (`Intlit value) -> int_of_string_opt value
        | _ -> None
      in
      let fallback_hops =
        match Json_util.assoc_member_opt "fallback_hops" runtime with
        | Some (`Int value) -> Some value
        | Some (`Intlit value) -> int_of_string_opt value
        | _ -> None
      in
      let fallback_applied =
        match Json_util.assoc_member_opt "fallback_applied" runtime with
        | Some (`Bool value) -> value
        | _ -> false
      in
      let selected_position = Option.map (fun idx -> idx + 1) selected_index in
      let summary =
        match fallback_applied, fallback_hops, selected_position, selected_model with
        | true, Some hops, Some pos, _ ->
            Printf.sprintf
              "%d attempt(s); fallback after %d hop(s); selected candidate index %d."
              attempts_observed
              hops
              pos
        | false, _, Some 1, _ ->
            Printf.sprintf
              "%d attempt(s); selected first healthy candidate."
              attempts_observed
        | false, _, Some pos, _ ->
            Printf.sprintf
              "%d attempt(s); selected candidate index %d without fallback."
              attempts_observed
              pos
        | _, _, _, Some (_, source) ->
            Printf.sprintf
              "%d attempt(s); selected model observed from %s."
              attempts_observed
              source
        | _ -> "Runtime observation is present but incomplete."
      in
      `Assoc
        [ "summary", `String summary
        ; "attempts_observed", `Int attempts_observed
        ; "selected_index", Json_util.int_opt_to_json selected_index
        ; "fallback_hops", Json_util.int_opt_to_json fallback_hops
        ; "fallback_applied", `Bool fallback_applied
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
    ; "configured_labels", `List []
    ; "resolved_candidates", `List []
    ; ( "selected_model"
      , Json_util.string_opt_to_json (Option.map fst selected_model) )
    ; "attempt_summary", attempt_summary_json ?selected_model latest_runtime
    ; ( "runtime_contract"
      , lightweight_runtime_contract_json ~runtime_blocker_class ~selected_model
          ~runtime_verified )
    ]
