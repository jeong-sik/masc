(** Model observability helpers for keeper status detail. *)

let nonempty_trimmed raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None else Some trimmed

let json_string_list_member json key =
  match Yojson.Safe.Util.member key json with
  | `List items ->
      items
      |> List.filter_map Yojson.Safe.Util.to_string_option
      |> List.filter_map nonempty_trimmed
  | _ -> []

let assoc_string_opt key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> nonempty_trimmed value
  | _ -> None

let assoc_int_opt key fields =
  match List.assoc_opt key fields with
  | Some (`Int value) -> Some value
  | Some (`Intlit value) -> int_of_string_opt value
  | _ -> None

let assoc_bool_opt key fields =
  match List.assoc_opt key fields with
  | Some (`Bool value) -> Some value
  | _ -> None

let json_string_opt_member json key =
  match json with
  | `Assoc _ ->
      (match Yojson.Safe.Util.member key json with
       | `String value -> nonempty_trimmed value
       | _ -> None)
  | _ -> None

let latest_metrics_json ~metrics_store ~metrics_path ~tail_bytes =
  let lines =
    let dated = Dated_jsonl.read_recent_lines metrics_store 8 in
    if dated <> []
    then dated
    else
      Keeper_memory.read_file_tail_lines
        metrics_path
        ~max_bytes:tail_bytes
        ~max_lines:8
  in
  let parsed, _ =
    Fs_compat.parse_jsonl_lines ~source:"keeper_metrics_latest" lines
  in
  match
    List.rev parsed
    |> List.find_opt (fun json ->
      match Yojson.Safe.Util.member "cascade" json with
      | `Assoc _ -> true
      | _ -> false)
  with
  | Some json -> Some json
  | None ->
      (match List.rev parsed with
       | json :: _ -> Some json
       | [] -> None)

let lightweight_runtime_contract_json ~runtime_blocker_class =
  let proof_note =
    "Provider/model identity is owned by OAS. MASC status exposes only \
     control-plane signals."
  in
  `Assoc
    [ "source", `String "none"
    ; "verified", `Bool false
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

let attempt_summary_json latest_cascade =
  match latest_cascade with
  | None ->
      `Assoc
        [ ( "summary"
          , `String "No recent cascade observation for current keeper config." )
        ; "attempts_observed", `Null
        ; "selected_index", `Null
        ; "fallback_hops", `Null
        ; "fallback_applied", `Bool false
        ]
  | Some cascade ->
      let attempts_observed =
        match Yojson.Safe.Util.member "attempts" cascade with
        | `List attempts -> List.length attempts
        | _ -> 0
      in
      let selected_index =
        match Yojson.Safe.Util.member "selected_index" cascade with
        | `Int value -> Some value
        | `Intlit value -> int_of_string_opt value
        | _ -> None
      in
      let fallback_hops =
        match Yojson.Safe.Util.member "fallback_hops" cascade with
        | `Int value -> Some value
        | `Intlit value -> int_of_string_opt value
        | _ -> None
      in
      let fallback_applied =
        match Yojson.Safe.Util.member "fallback_applied" cascade with
        | `Bool value -> value
        | _ -> false
      in
      let selected_position = Option.map (fun idx -> idx + 1) selected_index in
      let summary =
        match fallback_applied, fallback_hops, selected_position with
        | true, Some hops, Some pos ->
            Printf.sprintf
              "%d attempt(s); fallback after %d hop(s); selected candidate index %d."
              attempts_observed
              hops
              pos
        | false, _, Some 1 ->
            Printf.sprintf
              "%d attempt(s); selected first healthy candidate."
              attempts_observed
        | false, _, Some pos ->
            Printf.sprintf
              "%d attempt(s); selected candidate index %d without fallback."
              attempts_observed
              pos
        | _ -> "Cascade observation is present but incomplete."
      in
      `Assoc
        [ "summary", `String summary
        ; "attempts_observed", `Int attempts_observed
        ; "selected_index", Json_util.int_opt_to_json selected_index
        ; "fallback_hops", Json_util.int_opt_to_json fallback_hops
        ; "fallback_applied", `Bool fallback_applied
        ]

let latest_cascade_for_current_config ~current_cascade_name latest_metrics =
  let latest_cascade =
    match latest_metrics with
    | Some metrics ->
        (match Yojson.Safe.Util.member "cascade" metrics with
         | `Assoc _ as cascade -> Some cascade
         | _ -> None)
    | None -> None
  in
  match latest_cascade with
  | None -> None
  | Some cascade ->
      let cascade_name_matches =
        match json_string_opt_member cascade "cascade_name" with
        | Some observed_name -> String.equal observed_name current_cascade_name
        | None -> true
      in
      if cascade_name_matches then Some cascade else None

let model_observability_json ~current_cascade_name ~runtime_blocker_fields latest_metrics =
  let latest_cascade =
    latest_cascade_for_current_config ~current_cascade_name latest_metrics
  in
  let runtime_blocker_class =
    assoc_string_opt "runtime_blocker_class" runtime_blocker_fields
  in
  let cascade_name =
    Option.value ~default:"" (nonempty_trimmed current_cascade_name)
  in
  `Assoc
    [ ( "cascade_name"
      , if cascade_name = "" then `Null else `String cascade_name )
    ; "recent_turn_observation", `Bool (Option.is_some latest_cascade)
    ; "configured_labels", `List []
    ; "resolved_candidates", `List []
    ; "selected_model", `Null
    ; "attempt_summary", attempt_summary_json latest_cascade
    ; ( "runtime_contract"
      , lightweight_runtime_contract_json ~runtime_blocker_class )
    ]
